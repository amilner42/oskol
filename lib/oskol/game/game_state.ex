defmodule Oskol.Game.GameState do
  @moduledoc """
  Represents the complete state of a multiplayer poker roguelike game.
  """

  alias Oskol.Game.{PlayerState, ShopCard, ShopState}
  alias Oskol.Poker.{Card, SkillTree}

  @type t :: %__MODULE__{
          round_number: pos_integer(),
          player_names: %{player_id() => String.t()},
          players: %{player_id() => PlayerState.t()},
          phase: phase(),
          game_status: game_status(),
          last_hand_results: %{player_id() => hand_result()} | nil,
          round_hand_history: list(%{player_id() => hand_result()}),
          winner_id: player_id() | nil,
          last_round_winner_id: player_id() | nil,
          shop_state: ShopState.t() | nil,
          shop_rounds: non_neg_integer(),
          initial_lives: pos_integer(),
          hands_per_round: pos_integer(),
          discards_per_round: pos_integer(),
          dev_codes: [String.t()]
        }

  @type phase :: :playing | :round_end

  @type game_status :: :active | :game_over
  @type player_id :: String.t()
  @type hand_result :: %{
          hand: list(Card.t()),
          hand_type: Poker.hand_type(),
          score: pos_integer(),
          score_breakdown: Oskol.Poker.Score.score_result(),
          disabled_ranks: [Card.rank()],
          disabled_suits: [Card.suit()],
          enhancements_disabled: boolean()
        }

  @hands_per_round 4
  @discards_per_round 3

  defstruct round_number: 1,
            player_names: %{},
            players: %{},
            phase: :playing,
            game_status: :active,
            last_hand_results: nil,
            round_hand_history: [],
            winner_id: nil,
            last_round_winner_id: nil,
            shop_state: nil,
            shop_rounds: 2,
            initial_lives: 3,
            hands_per_round: @hands_per_round,
            discards_per_round: @discards_per_round,
            dev_codes: []

  @doc """
  Creates a new game state with the given player_names map (player_id => player_name),
  initial_lives for each player, shop_rounds configuration, and optional dev_codes.
  """
  @spec new(%{player_id() => String.t()}, pos_integer(), non_neg_integer(), [String.t()]) :: t()
  def new(player_names, initial_lives \\ 3, shop_rounds \\ 2, dev_codes \\ [])
      when is_map(player_names) and map_size(player_names) == 2 do
    # Check for dev codes that modify game settings
    hands_per_round = if "1HAND" in dev_codes, do: 1, else: @hands_per_round

    players =
      player_names
      |> Map.keys()
      |> Enum.map(fn player_id ->
        player = PlayerState.new(player_id, initial_lives, dev_codes)
        # Also need to set hands_remaining on player state
        {player_id, %{player | hands_remaining: hands_per_round}}
      end)
      |> Map.new()

    %__MODULE__{
      round_number: 1,
      player_names: player_names,
      players: players,
      phase: :playing,
      game_status: :active,
      shop_rounds: shop_rounds,
      initial_lives: initial_lives,
      hands_per_round: hands_per_round,
      discards_per_round: @discards_per_round,
      dev_codes: dev_codes
    }
  end

  @doc """
  Player locks in their hand choice.
  If both players have now locked in, transitions to :hand_results phase and calculates scores.

  Returns `{new_state, events}` where events are event descriptions as tuples `{type, player_id, data}`.
  """
  @spec player_lock_in_hand(t(), player_id(), list(Card.t())) :: {t(), list()}
  def player_lock_in_hand(%__MODULE__{} = game_state, player_id, hand) do
    # Get card IDs from the locked-in hand
    locked_card_ids = Enum.map(hand, & &1.id)

    updated_players =
      Map.update!(game_state.players, player_id, fn player ->
        # Reveal any face-down cards that are being locked in
        player_with_revealed = PlayerState.reveal_cards(player, locked_card_ids)
        %{player_with_revealed | locked_in_hand: hand}
      end)

    game_state = %{game_state | players: updated_players}

    lock_in_event = {:hand_locked_in, player_id, %{cards: hand}}

    # Check if both players have locked in
    if both_players_locked_in?(game_state) do
      {new_state, cascade_events} = process_locked_hands(game_state)
      {new_state, [lock_in_event | cascade_events]}
    else
      {game_state, [lock_in_event]}
    end
  end

  @doc """
  Checks if both players have locked in their hands.
  """
  @spec both_players_locked_in?(t()) :: boolean()
  def both_players_locked_in?(%__MODULE__{players: players}) do
    players
    |> Map.values()
    |> Enum.all?(fn player -> player.locked_in_hand != nil end)
  end

  @doc """
  Player discards cards and draws new ones.
  Decrements discards_remaining.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec player_discard_cards(t(), player_id(), list(Card.t())) ::
          {:ok, t(), list()} | {:error, :no_discards_remaining | :invalid_discard_count}
  def player_discard_cards(%__MODULE__{} = game_state, player_id, cards) do
    player = game_state.players[player_id]

    cond do
      player.discards_remaining == 0 ->
        {:error, :no_discards_remaining}

      length(cards) == 0 or length(cards) > 5 ->
        {:error, :invalid_discard_count}

      true ->
        # Discard and draw new cards
        alias Oskol.Game.CardPiles

        # Calculate how many cards to draw to get back to target hand size (8)
        # Normally, we draw the same number we discarded to maintain hand size
        # But with supply chain, we cap the draw at 4 cards per discard
        target_hand_size = 8
        current_hand_size = length(player.card_piles.hand_pile)
        hand_size_after_discard = current_hand_size - length(cards)
        cards_needed = target_hand_size - hand_size_after_discard

        cards_to_draw =
          if player.supply_chain_limited do
            # Supply Chain limits draw to at most 4 cards
            min(cards_needed, 4)
          else
            cards_needed
          end

        # Discard cards and draw new ones (respecting supply chain limit)
        new_card_piles =
          player.card_piles
          |> CardPiles.discard_cards(cards)
          |> CardPiles.draw_cards(cards_to_draw)

        # Determine which cards are new (drawn to replace discarded ones)
        new_cards = new_card_piles.hand_pile -- player.card_piles.hand_pile

        # If player is scrambled, randomly mark some new cards as face-down (1-in-5 chance each)
        face_down_ids = scramble_cards(new_cards, player.scrambled)

        updated_player = %{
          player
          | card_piles: new_card_piles,
            discards_remaining: player.discards_remaining - 1
        }

        # Add face-down cards to player state
        updated_player =
          if face_down_ids != [] do
            PlayerState.add_face_down_cards(updated_player, face_down_ids)
          else
            updated_player
          end

        updated_players = Map.put(game_state.players, player_id, updated_player)

        events = [
          {:cards_discarded, player_id,
           %{
             cards_discarded: cards,
             discards_remaining: updated_player.discards_remaining
           }},
          {:cards_drawn, player_id,
           %{
             cards: new_cards,
             reason: :after_discard,
             hand_size: length(new_card_piles.hand_pile),
             face_down_ids: face_down_ids
           }}
        ]

        {:ok, %{game_state | players: updated_players}, events}
    end
  end

  # Processes locked-in hands: scores them, updates scores, draws new cards, and continues to next hand.
  # Stores results in last_hand_results for LiveViews to display.
  # If this was the last hand of the round, transitions to :round_end phase.
  # Returns {new_state, events}
  @spec process_locked_hands(t()) :: {t(), list()}
  defp process_locked_hands(%__MODULE__{} = game_state) do
    alias Oskol.Game.CardPiles

    events = []

    # Calculate scores for each player's locked-in hand
    hand_results =
      Map.new(game_state.players, fn {player_id, player_state} ->
        hand = player_state.locked_in_hand
        evaluation = Oskol.Poker.evaluate_hand(hand)

        # Get card debuffs (disabled ranks/suits and enhancement disabling)
        card_debuffs = PlayerState.get_card_debuffs(player_state)

        score_result =
          Oskol.Poker.score_hand(
            evaluation,
            player_state.skill_tree,
            player_state.active_debuffs,
            card_debuffs
          )

        result = %{
          hand: hand,
          hand_type: evaluation.hand_type,
          score: score_result.total_score,
          score_breakdown: score_result,
          # Store debuffs that were active when scoring (for UI display during animation)
          disabled_ranks: player_state.disabled_ranks,
          disabled_suits: player_state.disabled_suits,
          enhancements_disabled: player_state.enhancements_disabled
        }

        {player_id, result}
      end)

    # Emit hands_revealed event
    events = [{:hands_revealed, nil, %{results: hand_results}} | events]

    # Update player scores, discard played cards, draw new cards, clear locked hands, decrement hands_remaining
    # Also collect cards_drawn events for each player
    {updated_players, draw_events} =
      Enum.map_reduce(game_state.players, [], fn {player_id, player_state}, acc_events ->
        result = hand_results[player_id]
        played_hand = player_state.locked_in_hand
        # Discard the played cards and draw new ones
        old_hand = player_state.card_piles.hand_pile
        new_card_piles = CardPiles.replace_cards(player_state.card_piles, played_hand)
        new_cards = new_card_piles.hand_pile -- old_hand

        # If player is scrambled, randomly mark some new cards as face-down (1-in-5 chance each)
        face_down_ids = scramble_cards(new_cards, player_state.scrambled)

        updated_player = %{
          player_state
          | current_round_score: player_state.current_round_score + result.score,
            card_piles: new_card_piles,
            locked_in_hand: nil,
            hands_remaining: player_state.hands_remaining - 1
        }

        # Add face-down cards to player state
        updated_player =
          if face_down_ids != [] do
            PlayerState.add_face_down_cards(updated_player, face_down_ids)
          else
            updated_player
          end

        # Create cards_drawn event for this player
        draw_event =
          {:cards_drawn, player_id,
           %{
             cards: new_cards,
             reason: :after_hand_played,
             hand_size: length(new_card_piles.hand_pile),
             face_down_ids: face_down_ids
           }}

        {{player_id, updated_player}, [draw_event | acc_events]}
      end)

    updated_players = Map.new(updated_players)
    events = draw_events ++ events

    # Check if round is over (all players have 0 hands remaining)
    round_over =
      updated_players
      |> Map.values()
      |> Enum.all?(fn player -> player.hands_remaining == 0 end)

    if round_over do
      # Round is over - determine round winner via head-to-head scoring
      [player1_id, player2_id] = Map.keys(updated_players)
      player1 = updated_players[player1_id]
      player2 = updated_players[player2_id]
      score1 = player1.current_round_score
      score2 = player2.current_round_score

      # Determine round winner (nil if tie)
      round_winner_id =
        cond do
          score1 > score2 -> player1_id
          score2 > score1 -> player2_id
          true -> nil
        end

      # Deduct life from loser only (or no one if tie)
      {players_with_updated_lives, life_events} =
        if round_winner_id do
          # There is a winner - deduct life from loser
          loser_id = if round_winner_id == player1_id, do: player2_id, else: player1_id
          loser = updated_players[loser_id]
          lives_before = loser.lives
          new_lives = max(loser.lives - 1, 0)
          updated_loser = %{loser | lives: new_lives}

          # Emit player_eliminated event if player died
          elimination_events =
            if lives_before > 0 and new_lives == 0 do
              [{:player_eliminated, loser_id, %{final_score: loser.current_round_score}}]
            else
              []
            end

          updated_map = Map.put(updated_players, loser_id, updated_loser)
          {updated_map, elimination_events}
        else
          # Tie - no one loses life
          {updated_players, []}
        end

      events = life_events ++ events

      # Emit round_completed event
      player_results =
        Map.new(players_with_updated_lives, fn {player_id, player_state} ->
          is_winner =
            cond do
              round_winner_id == player_id -> true
              round_winner_id == nil -> nil
              true -> false
            end

          {player_id,
           %{
             score: player_state.current_round_score,
             is_round_winner: is_winner,
             lives: player_state.lives
           }}
        end)

      round_event =
        {:round_completed, nil,
         %{
           round_number: game_state.round_number,
           winner_id: round_winner_id,
           player_results: player_results
         }}

      events = [round_event | events]

      # Check for game over condition
      player_lives = players_with_updated_lives |> Map.values() |> Enum.map(& &1.lives)
      any_player_dead = Enum.any?(player_lives, &(&1 == 0))

      if any_player_dead do
        # Game over - determine winner
        winner_id = determine_winner(players_with_updated_lives)

        # Emit game_ended event
        game_end_event =
          {:game_ended, nil,
           %{
             winner_id: winner_id,
             final_round: game_state.round_number,
             final_lives: Map.new(players_with_updated_lives, fn {pid, ps} -> {pid, ps.lives} end)
           }}

        events = [game_end_event | events]

        # Clear debuffs and scrambler effects now that round is complete
        players_cleared =
          Map.new(players_with_updated_lives, fn {pid, ps} ->
            ps |> PlayerState.clear_debuffs() |> PlayerState.clear_scrambler() |> then(&{pid, &1})
          end)

        new_state = %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_cleared,
            round_hand_history: game_state.round_hand_history ++ [hand_results],
            game_status: :game_over,
            winner_id: winner_id
        }

        {new_state, Enum.reverse(events)}
      else
        # Round over but game continues - initialize shop if shop_rounds > 0
        [player1_id, player2_id] = Map.keys(players_with_updated_lives)

        # Clear debuffs and scrambler effects now that round is complete
        players_cleared =
          Map.new(players_with_updated_lives, fn {pid, ps} ->
            ps |> PlayerState.clear_debuffs() |> PlayerState.clear_scrambler() |> then(&{pid, &1})
          end)

        # Initialize shop state based on round winner and shop_rounds configuration
        # Build player lives map for destroy phase calculation
        player_lives =
          Map.new(players_cleared, fn {pid, ps} -> {pid, ps.lives} end)

        shop_state =
          if game_state.shop_rounds > 0 do
            if round_winner_id == nil do
              # Tie - pass both player IDs and mark as tie
              ShopState.new(
                player1_id,
                player2_id,
                true,
                game_state.shop_rounds,
                game_state.dev_codes,
                player_lives
              )
            else
              # Determine loser
              loser_id = if round_winner_id == player1_id, do: player2_id, else: player1_id

              ShopState.new(
                round_winner_id,
                loser_id,
                false,
                game_state.shop_rounds,
                game_state.dev_codes,
                player_lives
              )
            end
          else
            # No shop configured
            nil
          end

        new_state = %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_cleared,
            round_hand_history: game_state.round_hand_history ++ [hand_results],
            last_round_winner_id: round_winner_id,
            shop_state: shop_state
        }

        {new_state, Enum.reverse(events)}
      end
    else
      # Round not over yet - continue playing
      new_state = %{
        game_state
        | phase: :playing,
          last_hand_results: hand_results,
          players: updated_players,
          round_hand_history: game_state.round_hand_history ++ [hand_results]
      }

      {new_state, Enum.reverse(events)}
    end
  end

  @doc """
  Player makes a pick in the current shop round.
  Advances to next shop round if both players have picked.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec make_shop_pick(t(), player_id(), non_neg_integer()) ::
          {:ok, t(), list()} | {:error, atom()}
  def make_shop_pick(%__MODULE__{shop_state: shop_state} = game_state, player_id, card_index)
      when shop_state != nil do
    case ShopState.make_pick(shop_state, player_id, card_index) do
      {:ok, updated_shop_state, selected_card} ->
        # Apply the card effect based on card type
        {updated_players, card_type, card_details} =
          apply_shop_card(game_state.players, player_id, selected_card)

        pick_event =
          {:shop_pick_made, player_id,
           %{
             shop_round: updated_shop_state.current_round,
             card_type: card_type,
             card_details: card_details,
             card_index: card_index
           }}

        # Check if both players have picked
        if ShopState.both_players_picked?(updated_shop_state) do
          # Check if shop is complete (all rounds done)
          if ShopState.shop_complete?(updated_shop_state) do
            # Shop complete - keep shop_state but mark it as done
            new_state = %{game_state | shop_state: updated_shop_state, players: updated_players}
            {:ok, new_state, [pick_event]}
          else
            # Advance to next shop round
            next_shop_state = ShopState.advance_round(updated_shop_state)
            new_state = %{game_state | shop_state: next_shop_state, players: updated_players}

            round_event =
              {:shop_round_advanced, nil, %{shop_round: next_shop_state.current_round}}

            {:ok, new_state, [pick_event, round_event]}
          end
        else
          # Waiting for other player to pick
          new_state = %{game_state | shop_state: updated_shop_state, players: updated_players}
          {:ok, new_state, [pick_event]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def make_shop_pick(_, _, _), do: {:error, :no_shop_active}

  # Applies a shop card effect to the players.
  # Returns {updated_players, card_type, card_details} for event logging.
  defp apply_shop_card(players, player_id, %ShopCard{type: :level_up, subtype: hand_type}) do
    updated_players =
      Map.update!(players, player_id, fn player ->
        updated_skill_tree = SkillTree.upgrade(player.skill_tree, hand_type, 1)
        %{player | skill_tree: updated_skill_tree}
      end)

    {updated_players, :level_up, %{hand_type: hand_type}}
  end

  defp apply_shop_card(players, player_id, %ShopCard{type: :denial, subtype: hand_type}) do
    # Denial cards affect the OPPONENT
    opponent_id = players |> Map.keys() |> Enum.find(&(&1 != player_id))

    updated_players =
      Map.update!(players, opponent_id, fn opponent ->
        PlayerState.add_denial_debuff(opponent, hand_type)
      end)

    {updated_players, :action,
     %{
       action_type: :denial,
       target_hand: hand_type,
       target_player: opponent_id
     }}
  end

  defp apply_shop_card(players, player_id, %ShopCard{type: :sabotage, subtype: :scrambler}) do
    # Scrambler affects the OPPONENT
    opponent_id = players |> Map.keys() |> Enum.find(&(&1 != player_id))

    updated_players =
      Map.update!(players, opponent_id, fn opponent ->
        PlayerState.set_scrambled(opponent, true)
      end)

    {updated_players, :action,
     %{
       action_type: :scrambler,
       target_player: opponent_id
     }}
  end

  defp apply_shop_card(players, player_id, %ShopCard{type: :sabotage, subtype: :static}) do
    # STATIC disables all enhancements on opponent's cards
    opponent_id = players |> Map.keys() |> Enum.find(&(&1 != player_id))

    updated_players =
      Map.update!(players, opponent_id, fn opponent ->
        PlayerState.disable_enhancements(opponent)
      end)

    {updated_players, :action,
     %{
       action_type: :static,
       target_player: opponent_id
     }}
  end

  defp apply_shop_card(players, player_id, %ShopCard{type: :sabotage, subtype: :supply_chain}) do
    # SUPPLY CHAIN limits opponent to drawing at most 4 cards when discarding
    opponent_id = players |> Map.keys() |> Enum.find(&(&1 != player_id))

    updated_players =
      Map.update!(players, opponent_id, fn opponent ->
        PlayerState.set_supply_chain_limited(opponent, true)
      end)

    {updated_players, :action,
     %{
       action_type: :supply_chain,
       target_player: opponent_id
     }}
  end

  defp apply_shop_card(players, _player_id, %ShopCard{type: :sabotage, subtype: :plus_bomb}) do
    # PLUS BOMB requires a selection phase - don't apply anything yet
    # This is handled separately like deck_builder
    {players, :action, %{action_type: :plus_bomb, requires_selection: true}}
  end

  defp apply_shop_card(players, _player_id, %ShopCard{type: :deck_builder, subtype: subtype}) do
    # Deck builder cards don't apply any effect immediately
    # The effect is applied when the player confirms their card selection
    {players, :deck_builder, %{card_type: subtype}}
  end

  @doc """
  Confirms a deck builder pick. This is the first step of the two-phase deck builder flow.
  Marks the card as picked, generates 8 selection cards, and stores them in shop_state.
  Does NOT complete the pick (turn does not switch yet).

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec confirm_deck_builder_pick(t(), player_id(), non_neg_integer()) ::
          {:ok, t(), list()} | {:error, atom()}
  def confirm_deck_builder_pick(
        %__MODULE__{shop_state: shop_state} = game_state,
        player_id,
        card_index
      )
      when shop_state != nil do
    # Validate it's player's turn
    unless ShopState.can_pick?(shop_state, player_id) do
      {:error, :not_your_turn}
    else
      # Validate it's a deck builder card
      case Enum.at(shop_state.available_cards, card_index) do
        %ShopCard{type: :deck_builder} = shop_card ->
          # Mark card as picked (but don't complete the pick yet)
          case ShopState.mark_card_picked(shop_state, card_index) do
            {:ok, updated_shop_state} ->
              # Generate 8 cards to choose from
              player = game_state.players[player_id]

              all_deck_cards =
                player.card_piles.draw_pile ++
                  player.card_piles.hand_pile ++ player.card_piles.discard_pile

              available_cards =
                ShopCard.generate_selection_cards(shop_card, all_deck_cards)

              # Store in pending_deck_builder
              pending = %{
                player_id: player_id,
                shop_card_index: card_index,
                deck_builder_card: shop_card,
                available_cards: available_cards
              }

              updated_shop_state = %{updated_shop_state | pending_deck_builder: pending}
              new_state = %{game_state | shop_state: updated_shop_state}

              event =
                {:deck_builder_confirmed, player_id,
                 %{
                   shop_round: updated_shop_state.current_round,
                   card_type: shop_card.subtype,
                   card_index: card_index
                 }}

              {:ok, new_state, [event]}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, :not_a_deck_builder_card}
      end
    end
  end

  def confirm_deck_builder_pick(_, _, _), do: {:error, :no_shop_active}

  @doc """
  Completes a pending deck builder selection by applying the effect to the selected card.
  This is the second step of the two-phase deck builder flow.
  Completes the pick (turn switches if needed).

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec complete_deck_builder_selection(t(), player_id(), String.t() | list(String.t())) ::
          {:ok, t(), list()} | {:error, atom()}
  def complete_deck_builder_selection(
        %__MODULE__{shop_state: shop_state} = game_state,
        player_id,
        selected_card_id_or_ids
      )
      when shop_state != nil and shop_state.pending_deck_builder != nil do
    pending = shop_state.pending_deck_builder

    # Validate this is the right player
    unless pending.player_id == player_id do
      {:error, :not_your_pending_selection}
    else
      # Handle both single card and multiple cards based on max_selection
      is_multi_select = ShopCard.max_selection(pending.deck_builder_card) > 1

      selected_card_ids =
        if is_list(selected_card_id_or_ids),
          do: selected_card_id_or_ids,
          else: [selected_card_id_or_ids]

      # Validate all selected cards are in the available cards
      selected_cards =
        Enum.map(selected_card_ids, fn id ->
          Enum.find(pending.available_cards, fn card -> card.id == id end)
        end)

      if Enum.any?(selected_cards, &is_nil/1) do
        {:error, :invalid_card_selection}
      else
        # For :remove_card and suit changes, apply multiple changes; for others, use single card
        {updated_players, card_details} =
          if is_multi_select do
            # Apply to all selected cards
            updated_players =
              Enum.reduce(selected_cards, game_state.players, fn card, acc_players ->
                {new_players, _} =
                  apply_deck_builder_card(acc_players, player_id, pending.deck_builder_card, card)

                new_players
              end)

            detail_type =
              case pending.deck_builder_card.subtype do
                :remove_card ->
                  :remove_card

                :change_suit ->
                  :change_suit

                :increase_rank ->
                  :increase_rank
              end

            {updated_players, %{type: detail_type, card_ids: selected_card_ids}}
          else
            # Single card application
            apply_deck_builder_card(
              game_state.players,
              player_id,
              pending.deck_builder_card,
              hd(selected_cards)
            )
          end

        # Complete the pick (mark first_pick_made or second_pick_made)
        case ShopState.complete_pick(shop_state, player_id) do
          {:ok, updated_shop_state} ->
            # Clear pending_deck_builder
            updated_shop_state = %{updated_shop_state | pending_deck_builder: nil}

            deck_builder_event =
              {:deck_builder_applied, player_id,
               %{
                 deck_builder_type: pending.deck_builder_card.subtype,
                 card_details: card_details,
                 selected_card_id: hd(selected_card_ids)
               }}

            # Check if both players have picked
            if ShopState.both_players_picked?(updated_shop_state) do
              if ShopState.shop_complete?(updated_shop_state) do
                new_state = %{
                  game_state
                  | shop_state: updated_shop_state,
                    players: updated_players
                }

                {:ok, new_state, [deck_builder_event]}
              else
                next_shop_state = ShopState.advance_round(updated_shop_state)

                new_state = %{
                  game_state
                  | shop_state: next_shop_state,
                    players: updated_players
                }

                round_event =
                  {:shop_round_advanced, nil, %{shop_round: next_shop_state.current_round}}

                {:ok, new_state, [deck_builder_event, round_event]}
              end
            else
              new_state = %{
                game_state
                | shop_state: updated_shop_state,
                  players: updated_players
              }

              {:ok, new_state, [deck_builder_event]}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def complete_deck_builder_selection(_, _, _), do: {:error, :no_pending_selection}

  @doc """
  Skips a pending deck builder selection without applying any effect.
  Completes the pick (turn switches if needed).

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec skip_deck_builder_selection(t(), player_id()) :: {:ok, t(), list()} | {:error, atom()}
  def skip_deck_builder_selection(
        %__MODULE__{shop_state: shop_state} = game_state,
        player_id
      )
      when shop_state != nil and shop_state.pending_deck_builder != nil do
    pending = shop_state.pending_deck_builder

    # Validate this is the right player
    unless pending.player_id == player_id do
      {:error, :not_your_pending_selection}
    else
      # Complete the pick without applying any effect
      case ShopState.complete_pick(shop_state, player_id) do
        {:ok, updated_shop_state} ->
          # Clear pending_deck_builder
          updated_shop_state = %{updated_shop_state | pending_deck_builder: nil}

          skip_event =
            {:deck_builder_skipped, player_id,
             %{deck_builder_type: pending.deck_builder_card.type}}

          # Check if both players have picked
          if ShopState.both_players_picked?(updated_shop_state) do
            if ShopState.shop_complete?(updated_shop_state) do
              new_state = %{game_state | shop_state: updated_shop_state}
              {:ok, new_state, [skip_event]}
            else
              next_shop_state = ShopState.advance_round(updated_shop_state)
              new_state = %{game_state | shop_state: next_shop_state}

              round_event =
                {:shop_round_advanced, nil, %{shop_round: next_shop_state.current_round}}

              {:ok, new_state, [skip_event, round_event]}
            end
          else
            new_state = %{game_state | shop_state: updated_shop_state}
            {:ok, new_state, [skip_event]}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def skip_deck_builder_selection(_, _), do: {:error, :no_pending_selection}

  @doc """
  Confirms a plus bomb pick. This is the first step of the two-phase plus bomb flow.
  Marks the card as picked, generates 8 random cards for selection, and stores them in shop_state.
  Does NOT complete the pick (turn does not switch yet).

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec confirm_plus_bomb_pick(t(), player_id(), non_neg_integer()) ::
          {:ok, t(), list()} | {:error, atom()}
  def confirm_plus_bomb_pick(
        %__MODULE__{shop_state: shop_state} = game_state,
        player_id,
        card_index
      )
      when shop_state != nil do
    # Validate it's player's turn
    unless ShopState.can_pick?(shop_state, player_id) do
      {:error, :not_your_turn}
    else
      # Validate it's a plus_bomb action card
      case Enum.at(shop_state.available_cards, card_index) do
        %ShopCard{type: :sabotage, subtype: :plus_bomb} ->
          # Mark card as picked (but don't complete the pick yet)
          case ShopState.mark_card_picked(shop_state, card_index) do
            {:ok, updated_shop_state} ->
              # Generate 8 random cards for selection
              available_cards = generate_plus_bomb_cards()

              # Store in pending_plus_bomb
              pending = %{
                player_id: player_id,
                shop_card_index: card_index,
                available_cards: available_cards
              }

              updated_shop_state = %{updated_shop_state | pending_plus_bomb: pending}
              new_state = %{game_state | shop_state: updated_shop_state}

              event =
                {:plus_bomb_confirmed, player_id,
                 %{
                   shop_round: updated_shop_state.current_round,
                   card_index: card_index
                 }}

              {:ok, new_state, [event]}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, :not_a_plus_bomb_card}
      end
    end
  end

  def confirm_plus_bomb_pick(_, _, _), do: {:error, :no_shop_active}

  @doc """
  Completes a pending plus bomb selection by applying the effect to the opponent.
  The selected card's rank AND suit will disable matching cards for the opponent next round.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec complete_plus_bomb_selection(t(), player_id(), String.t()) ::
          {:ok, t(), list()} | {:error, atom()}
  def complete_plus_bomb_selection(
        %__MODULE__{shop_state: shop_state} = game_state,
        player_id,
        selected_card_id
      )
      when shop_state != nil and shop_state.pending_plus_bomb != nil do
    pending = shop_state.pending_plus_bomb

    # Validate this is the right player
    unless pending.player_id == player_id do
      {:error, :not_your_pending_selection}
    else
      # Find the selected card
      selected_card =
        Enum.find(pending.available_cards, fn card -> card.id == selected_card_id end)

      if selected_card == nil do
        {:error, :invalid_card_selection}
      else
        # Apply the plus bomb debuff to the OPPONENT
        opponent_id = game_state.players |> Map.keys() |> Enum.find(&(&1 != player_id))

        updated_players =
          Map.update!(game_state.players, opponent_id, fn opponent ->
            PlayerState.add_plus_bomb_debuff(opponent, selected_card.rank, selected_card.suit)
          end)

        # Complete the pick
        case ShopState.complete_pick(shop_state, player_id) do
          {:ok, updated_shop_state} ->
            # Clear pending_plus_bomb
            updated_shop_state = %{updated_shop_state | pending_plus_bomb: nil}

            plus_bomb_event =
              {:plus_bomb_applied, player_id,
               %{
                 selected_rank: selected_card.rank,
                 selected_suit: selected_card.suit,
                 target_player: opponent_id
               }}

            # Check if both players have picked
            if ShopState.both_players_picked?(updated_shop_state) do
              if ShopState.shop_complete?(updated_shop_state) do
                new_state = %{
                  game_state
                  | shop_state: updated_shop_state,
                    players: updated_players
                }

                {:ok, new_state, [plus_bomb_event]}
              else
                next_shop_state = ShopState.advance_round(updated_shop_state)

                new_state = %{
                  game_state
                  | shop_state: next_shop_state,
                    players: updated_players
                }

                round_event =
                  {:shop_round_advanced, nil, %{shop_round: next_shop_state.current_round}}

                {:ok, new_state, [plus_bomb_event, round_event]}
              end
            else
              new_state = %{
                game_state
                | shop_state: updated_shop_state,
                  players: updated_players
              }

              {:ok, new_state, [plus_bomb_event]}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def complete_plus_bomb_selection(_, _, _), do: {:error, :no_pending_selection}

  @doc """
  Destroys a shop card during the destroy phase.
  Only the player who is behind in lives can destroy cards.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec destroy_shop_card(t(), player_id(), non_neg_integer()) ::
          {:ok, t(), list()} | {:error, atom()}
  def destroy_shop_card(%__MODULE__{shop_state: shop_state} = game_state, player_id, card_index)
      when shop_state != nil do
    case ShopState.destroy_card(shop_state, player_id, card_index) do
      {:ok, updated_shop_state} ->
        # Get the destroyed card name for the event
        destroyed_card = Enum.at(shop_state.available_cards, card_index)

        event =
          {:shop_card_destroyed, player_id,
           %{
             card_index: card_index,
             card_type: destroyed_card.type,
             card_subtype: destroyed_card.subtype,
             destroys_remaining: ShopState.destroys_remaining(updated_shop_state)
           }}

        new_state = %{game_state | shop_state: updated_shop_state}
        {:ok, new_state, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def destroy_shop_card(_, _, _), do: {:error, :no_shop_active}

  @doc """
  Completes the destroy phase, allowing normal shop picking to begin.
  Can be called even if not all destroys have been used.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec complete_destroy_phase(t(), player_id()) ::
          {:ok, t(), list()} | {:error, atom()}
  def complete_destroy_phase(%__MODULE__{shop_state: shop_state} = game_state, player_id)
      when shop_state != nil do
    case ShopState.complete_destroy_phase(shop_state, player_id) do
      {:ok, updated_shop_state} ->
        event =
          {:destroy_phase_complete, player_id,
           %{
             cards_destroyed: length(updated_shop_state.destroyed_card_indices)
           }}

        new_state = %{game_state | shop_state: updated_shop_state}
        {:ok, new_state, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete_destroy_phase(_, _), do: {:error, :no_shop_active}

  # Generates 8 random cards for plus bomb selection
  defp generate_plus_bomb_cards do
    ranks = Enum.to_list(2..14)
    suits = [:hearts, :diamonds, :clubs, :spades]

    # Generate 8 unique random cards
    all_combinations =
      for rank <- ranks, suit <- suits do
        {rank, suit}
      end

    all_combinations
    |> Enum.shuffle()
    |> Enum.take(8)
    |> Enum.map(fn {rank, suit} -> Card.new(rank, suit) end)
  end

  # Helper to apply deck builder card effects
  defp apply_deck_builder_card(players, player_id, deck_builder_card, selected_card) do
    case deck_builder_card.subtype do
      subtype when subtype in [:bonus_chips, :bonus_mult] ->
        # Apply enhancement to the selected card
        amount = deck_builder_card.metadata.amount

        enhancement =
          case subtype do
            :bonus_chips -> {:bonus_chips, amount}
            :bonus_mult -> {:bonus_mult, amount}
          end

        {apply_enhancement(players, player_id, selected_card.id, enhancement),
         %{type: :enhancement, enhancement: enhancement, card_id: selected_card.id}}

      :add_card ->
        # Add the selected card to player's deck
        {apply_add_card(players, player_id, selected_card),
         %{type: :add_card, card: selected_card}}

      :remove_card ->
        # Remove the selected card from player's deck
        {apply_remove_card(players, player_id, selected_card.id),
         %{type: :remove_card, card_id: selected_card.id}}

      :change_suit ->
        # Change the suit of the selected card
        new_suit = deck_builder_card.metadata.suit

        {apply_suit_change(players, player_id, selected_card.id, new_suit),
         %{type: :change_suit, suit: new_suit, card_id: selected_card.id}}

      :increase_rank ->
        # Increase the rank of the selected card by 1 (max 14)
        {apply_rank_increase(players, player_id, selected_card.id),
         %{type: :increase_rank, card_id: selected_card.id}}
    end
  end

  defp apply_enhancement(players, player_id, card_id, enhancement) do
    Map.update!(players, player_id, fn player ->
      # Find and enhance the card in any pile
      updated_card_piles = enhance_card_in_piles(player.card_piles, card_id, enhancement)
      %{player | card_piles: updated_card_piles}
    end)
  end

  defp enhance_card_in_piles(card_piles, card_id, enhancement) do
    alias Oskol.Game.CardPiles

    %CardPiles{
      draw_pile: enhance_card_in_list(card_piles.draw_pile, card_id, enhancement),
      hand_pile: enhance_card_in_list(card_piles.hand_pile, card_id, enhancement),
      discard_pile: enhance_card_in_list(card_piles.discard_pile, card_id, enhancement)
    }
  end

  defp enhance_card_in_list(cards, card_id, enhancement) do
    Enum.map(cards, fn card ->
      if card.id == card_id do
        Card.enhance(card, enhancement)
      else
        card
      end
    end)
  end

  defp apply_add_card(players, player_id, new_card) do
    alias Oskol.Game.CardPiles

    Map.update!(players, player_id, fn player ->
      # Add card to discard pile (will get shuffled in naturally)
      updated_card_piles = %{
        player.card_piles
        | discard_pile: [new_card | player.card_piles.discard_pile]
      }

      %{player | card_piles: updated_card_piles}
    end)
  end

  defp apply_remove_card(players, player_id, card_id) do
    alias Oskol.Game.CardPiles

    Map.update!(players, player_id, fn player ->
      # Remove card from all piles
      updated_card_piles = %CardPiles{
        draw_pile: Enum.reject(player.card_piles.draw_pile, fn c -> c.id == card_id end),
        hand_pile: Enum.reject(player.card_piles.hand_pile, fn c -> c.id == card_id end),
        discard_pile: Enum.reject(player.card_piles.discard_pile, fn c -> c.id == card_id end)
      }

      %{player | card_piles: updated_card_piles}
    end)
  end

  defp apply_suit_change(players, player_id, card_id, new_suit) do
    alias Oskol.Game.CardPiles

    Map.update!(players, player_id, fn player ->
      # Change suit of the card in any pile
      updated_card_piles = change_suit_in_piles(player.card_piles, card_id, new_suit)
      %{player | card_piles: updated_card_piles}
    end)
  end

  defp change_suit_in_piles(card_piles, card_id, new_suit) do
    alias Oskol.Game.CardPiles

    %CardPiles{
      draw_pile: change_suit_in_list(card_piles.draw_pile, card_id, new_suit),
      hand_pile: change_suit_in_list(card_piles.hand_pile, card_id, new_suit),
      discard_pile: change_suit_in_list(card_piles.discard_pile, card_id, new_suit)
    }
  end

  defp change_suit_in_list(cards, card_id, new_suit) do
    Enum.map(cards, fn card ->
      if card.id == card_id do
        %{card | suit: new_suit}
      else
        card
      end
    end)
  end

  defp apply_rank_increase(players, player_id, card_id) do
    alias Oskol.Game.CardPiles

    Map.update!(players, player_id, fn player ->
      # Increase rank of the card in any pile
      updated_card_piles = increase_rank_in_piles(player.card_piles, card_id)
      %{player | card_piles: updated_card_piles}
    end)
  end

  defp increase_rank_in_piles(card_piles, card_id) do
    alias Oskol.Game.CardPiles

    %CardPiles{
      draw_pile: increase_rank_in_list(card_piles.draw_pile, card_id),
      hand_pile: increase_rank_in_list(card_piles.hand_pile, card_id),
      discard_pile: increase_rank_in_list(card_piles.discard_pile, card_id)
    }
  end

  defp increase_rank_in_list(cards, card_id) do
    Enum.map(cards, fn card ->
      if card.id == card_id do
        # Increase rank by 1, but cap at 14 (Ace)
        new_rank = min(card.rank + 1, 14)
        %{card | rank: new_rank}
      else
        card
      end
    end)
  end

  @doc """
  Marks a player as ready for the next round (from the shop).
  If both players are ready, automatically advances to the next round.
  Only advances if game is not over.

  Returns `{new_state, events}`.
  """
  @spec mark_ready_for_next_round(t(), player_id()) :: {t(), list()}
  def mark_ready_for_next_round(%__MODULE__{phase: :round_end} = game_state, player_id) do
    updated_players =
      Map.update!(game_state.players, player_id, fn player ->
        %{player | ready_for_next_round: true}
      end)

    game_state = %{game_state | players: updated_players}

    ready_event = {:player_ready, player_id, %{}}

    # Check if both players are ready and game is not over
    if both_players_ready_for_next_round?(game_state) and game_state.game_status != :game_over do
      {new_state, round_events} = advance_round(game_state)
      {new_state, [ready_event | round_events]}
    else
      {game_state, [ready_event]}
    end
  end

  @doc """
  Checks if both players are ready for the next round.
  """
  @spec both_players_ready_for_next_round?(t()) :: boolean()
  def both_players_ready_for_next_round?(%__MODULE__{players: players}) do
    players
    |> Map.values()
    |> Enum.all?(fn player -> player.ready_for_next_round end)
  end

  # Advances to the next round.
  # Lives have already been deducted in process_locked_hands/1.
  # Resets player states, increments round number.
  # Shuffles player decks.
  # Returns {new_state, events}
  @spec advance_round(t()) :: {t(), list()}
  defp advance_round(%__MODULE__{} = game_state) do
    alias Oskol.Game.CardPiles

    next_round = game_state.round_number + 1

    # Shuffle decks and reset for next round, collecting cards_drawn events
    {updated_players, draw_events} =
      Enum.map_reduce(game_state.players, [], fn {player_id, player_state}, acc_events ->
        # Shuffle deck: collect all cards and redistribute
        all_cards =
          player_state.card_piles.hand_pile ++
            player_state.card_piles.draw_pile ++ player_state.card_piles.discard_pile

        shuffled_cards = Enum.shuffle(all_cards)

        # Draw 8 cards into hand, rest goes to draw pile
        {hand_cards, draw_cards} = Enum.split(shuffled_cards, 8)

        new_card_piles = %CardPiles{
          hand_pile: hand_cards,
          draw_pile: draw_cards,
          discard_pile: []
        }

        # Apply scrambler to initial hand cards if player is scrambled
        face_down_ids = scramble_cards(hand_cards, player_state.scrambled)

        # Reset for new round with shuffled deck (lives already updated)
        # Keep the scrambled state but add the face_down_card_ids for initial draw
        # Pass hands_per_round from game_state to support dev codes like 1HAND
        updated_player =
          player_state
          |> PlayerState.reset_for_new_round(game_state.hands_per_round)
          |> Map.put(:card_piles, new_card_piles)
          |> PlayerState.add_face_down_cards(face_down_ids)

        # Create cards_drawn event for new hand
        draw_event =
          {:cards_drawn, player_id,
           %{
             cards: hand_cards,
             reason: :round_start,
             hand_size: 8
           }}

        {{player_id, updated_player}, [draw_event | acc_events]}
      end)

    updated_players = Map.new(updated_players)

    # Create round_started event
    round_event =
      {:round_started, nil,
       %{
         round_number: next_round,
         hands_remaining: 4,
         discards_remaining: 3
       }}

    events = [round_event | draw_events]

    new_state = %{
      game_state
      | round_number: next_round,
        players: updated_players,
        phase: :playing,
        last_hand_results: nil,
        round_hand_history: [],
        shop_state: nil
    }

    {new_state, events}
  end

  # Randomly selects cards to be face-down based on scrambler effect
  # Each card has a 1-in-5 chance of being face-down
  # Returns list of card IDs that should be face-down
  @spec scramble_cards([Card.t()], boolean()) :: [String.t()]
  defp scramble_cards(_cards, false), do: []

  defp scramble_cards(cards, true) do
    cards
    |> Enum.filter(fn _card -> :rand.uniform(5) == 1 end)
    |> Enum.map(& &1.id)
  end

  # Determines the winner when game is over
  # If one player has more lives, they win
  # If both have 0 lives, the player with higher current_round_score wins
  @spec determine_winner(%{player_id() => PlayerState.t()}) :: player_id()
  defp determine_winner(players) do
    players
    |> Enum.sort_by(
      fn {_player_id, player_state} ->
        {player_state.lives, player_state.current_round_score}
      end,
      :desc
    )
    |> List.first()
    |> elem(0)
  end
end
