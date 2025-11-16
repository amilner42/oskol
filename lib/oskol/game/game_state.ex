defmodule Oskol.Game.GameState do
  @moduledoc """
  Represents the complete state of a multiplayer poker roguelike game.
  """

  alias Oskol.Game.{PlayerState, ShopState}
  alias Oskol.Poker.Card

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
          shop_rounds: non_neg_integer()
        }

  @type phase :: :playing | :round_end

  @type game_status :: :active | :game_over
  @type player_id :: String.t()
  @type hand_result :: %{
          hand: list(Card.t()),
          hand_type: Poker.hand_type(),
          score: pos_integer()
        }

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
            shop_rounds: 2

  @doc """
  Creates a new game state with the given player_names map (player_id => player_name),
  initial_lives for each player, and shop_rounds configuration.
  """
  @spec new(%{player_id() => String.t()}, pos_integer(), non_neg_integer()) :: t()
  def new(player_names, initial_lives \\ 3, shop_rounds \\ 2)
      when is_map(player_names) and map_size(player_names) == 2 do
    players =
      player_names
      |> Map.keys()
      |> Enum.map(fn player_id -> {player_id, PlayerState.new(player_id, initial_lives)} end)
      |> Map.new()

    %__MODULE__{
      round_number: 1,
      player_names: player_names,
      players: players,
      phase: :playing,
      game_status: :active,
      shop_rounds: shop_rounds
    }
  end

  @doc """
  Player locks in their hand choice.
  If both players have now locked in, transitions to :hand_results phase and calculates scores.

  Returns `{new_state, events}` where events are event descriptions as tuples `{type, player_id, data}`.
  """
  @spec player_lock_in_hand(t(), player_id(), list(Card.t())) :: {t(), list()}
  def player_lock_in_hand(%__MODULE__{} = game_state, player_id, hand) do
    updated_players =
      Map.update!(game_state.players, player_id, fn player ->
        %{player | locked_in_hand: hand}
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
  Player unlocks their hand choice, allowing them to select a different hand.
  Only works if both players haven't locked in yet.

  Returns `{:ok, new_state, events}` on success or `{:error, reason}` on failure.
  """
  @spec player_unlock_hand(t(), player_id()) ::
          {:ok, t(), list()} | {:error, :cannot_unlock}
  def player_unlock_hand(%__MODULE__{} = game_state, player_id) do
    # Can only unlock if both players haven't locked in yet
    if both_players_locked_in?(game_state) do
      {:error, :cannot_unlock}
    else
      updated_players =
        Map.update!(game_state.players, player_id, fn player ->
          %{player | locked_in_hand: nil}
        end)

      event = {:hand_unlocked, player_id, %{}}
      {:ok, %{game_state | players: updated_players}, [event]}
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

        new_card_piles = CardPiles.replace_cards(player.card_piles, cards)

        # Determine which cards are new (drawn to replace discarded ones)
        new_cards = new_card_piles.hand_pile -- player.card_piles.hand_pile

        updated_player = %{
          player
          | card_piles: new_card_piles,
            discards_remaining: player.discards_remaining - 1
        }

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
             hand_size: length(new_card_piles.hand_pile)
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
        score_result = Oskol.Poker.score_hand(evaluation, player_state.skill_tree)

        result = %{
          hand: hand,
          hand_type: evaluation.hand_type,
          score: score_result.total_score
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

        updated_player = %{
          player_state
          | current_round_score: player_state.current_round_score + result.score,
            card_piles: new_card_piles,
            locked_in_hand: nil,
            hands_remaining: player_state.hands_remaining - 1
        }

        # Create cards_drawn event for this player
        draw_event =
          {:cards_drawn, player_id,
           %{
             cards: new_cards,
             reason: :after_hand_played,
             hand_size: length(new_card_piles.hand_pile)
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
             final_lives:
               Map.new(players_with_updated_lives, fn {pid, ps} -> {pid, ps.lives} end)
           }}

        events = [game_end_event | events]

        new_state = %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_with_updated_lives,
            round_hand_history: game_state.round_hand_history ++ [hand_results],
            game_status: :game_over,
            winner_id: winner_id
        }

        {new_state, Enum.reverse(events)}
      else
        # Round over but game continues - initialize shop if shop_rounds > 0
        [player1_id, player2_id] = Map.keys(players_with_updated_lives)

        # Initialize shop state based on round winner and shop_rounds configuration
        shop_state =
          if game_state.shop_rounds > 0 do
            if round_winner_id == nil do
              # Tie - pass both player IDs and mark as tie
              ShopState.new(player1_id, player2_id, true, game_state.shop_rounds)
            else
              # Determine loser
              loser_id = if round_winner_id == player1_id, do: player2_id, else: player1_id
              ShopState.new(round_winner_id, loser_id, false, game_state.shop_rounds)
            end
          else
            # No shop configured
            nil
          end

        new_state = %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_with_updated_lives,
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
  @spec make_shop_pick(t(), player_id()) :: {:ok, t(), list()} | {:error, atom()}
  def make_shop_pick(%__MODULE__{shop_state: shop_state} = game_state, player_id)
      when shop_state != nil do
    case ShopState.make_pick(shop_state, player_id) do
      {:ok, updated_shop_state} ->
        # TODO: In the future, this will actually apply the picked upgrade
        pick_event =
          {:shop_pick_made, player_id, %{shop_round: updated_shop_state.current_round}}

        # Check if both players have picked
        if ShopState.both_players_picked?(updated_shop_state) do
          # Check if shop is complete (all rounds done)
          if ShopState.shop_complete?(updated_shop_state) do
            # Shop complete - keep shop_state but mark it as done
            new_state = %{game_state | shop_state: updated_shop_state}
            {:ok, new_state, [pick_event]}
          else
            # Advance to next shop round
            next_shop_state = ShopState.advance_round(updated_shop_state)
            new_state = %{game_state | shop_state: next_shop_state}

            round_event =
              {:shop_round_advanced, nil, %{shop_round: next_shop_state.current_round}}

            {:ok, new_state, [pick_event, round_event]}
          end
        else
          # Waiting for other player to pick
          new_state = %{game_state | shop_state: updated_shop_state}
          {:ok, new_state, [pick_event]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def make_shop_pick(_, _), do: {:error, :no_shop_active}

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

        # Reset for new round with shuffled deck (lives already updated)
        updated_player =
          player_state
          |> PlayerState.reset_for_new_round()
          |> Map.put(:card_piles, new_card_piles)

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
