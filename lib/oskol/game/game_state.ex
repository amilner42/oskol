defmodule Oskol.Game.GameState do
  @moduledoc """
  Represents the complete state of a multiplayer poker roguelike game.
  """

  alias Oskol.Game.PlayerState
  alias Oskol.Poker.Card

  @type t :: %__MODULE__{
          round_number: pos_integer(),
          blind_target: pos_integer(),
          player_names: %{player_id() => String.t()},
          players: %{player_id() => PlayerState.t()},
          phase: phase(),
          game_status: game_status(),
          last_hand_results: %{player_id() => hand_result()} | nil,
          round_hand_history: list(%{player_id() => hand_result()}),
          winner_id: player_id() | nil
        }

  @type phase :: :playing | :round_end

  # Blind levels progression (similar to Balatro)
  @blind_levels [
    300, 450, 600, 800, 1200, 1600, 2000, 3000, 4000, 5000,
    7500, 10000, 11000, 16500, 22000, 20000, 30000, 40000, 35000, 52500,
    70000, 50000, 75000, 100000
  ]
  @type game_status :: :active | :game_over
  @type player_id :: String.t()
  @type hand_result :: %{
          hand: list(Card.t()),
          hand_type: Poker.hand_type(),
          score: pos_integer()
        }

  defstruct round_number: 1,
            blind_target: 300,
            player_names: %{},
            players: %{},
            phase: :playing,
            game_status: :active,
            last_hand_results: nil,
            round_hand_history: [],
            winner_id: nil

  @doc """
  Creates a new game state with the given player_names map (player_id => player_name).
  """
  @spec new(%{player_id() => String.t()}) :: t()
  def new(player_names) when is_map(player_names) and map_size(player_names) == 2 do
    players =
      player_names
      |> Map.keys()
      |> Enum.map(fn player_id -> {player_id, PlayerState.new(player_id)} end)
      |> Map.new()

    %__MODULE__{
      round_number: 1,
      blind_target: 300,
      player_names: player_names,
      players: players,
      phase: :playing,
      game_status: :active
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
      # Round is over - check blind targets and deduct lives
      {players_with_updated_lives, life_events} =
        Enum.map_reduce(updated_players, [], fn {player_id, player_state}, acc_events ->
          # Check if player hit the blind
          hit_blind = player_state.current_round_score >= game_state.blind_target
          lives_before = player_state.lives

          # Deduct life if didn't hit blind
          new_lives =
            if hit_blind do
              player_state.lives
            else
              max(player_state.lives - 1, 0)
            end

          updated_player = %{player_state | lives: new_lives}

          # Emit player_eliminated event if player died
          new_events =
            if lives_before > 0 and new_lives == 0 do
              [{:player_eliminated, player_id, %{final_score: player_state.current_round_score}} | acc_events]
            else
              acc_events
            end

          {{player_id, updated_player}, new_events}
        end)

      players_with_updated_lives = Map.new(players_with_updated_lives)
      events = life_events ++ events

      # Emit round_completed event
      player_results =
        Map.new(players_with_updated_lives, fn {player_id, player_state} ->
          {player_id,
           %{
             score: player_state.current_round_score,
             passed: player_state.current_round_score >= game_state.blind_target,
             lives: player_state.lives
           }}
        end)

      round_event =
        {:round_completed, nil,
         %{
           round_number: game_state.round_number,
           blind_target: game_state.blind_target,
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
        # Round over but game continues
        new_state = %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_with_updated_lives,
            round_hand_history: game_state.round_hand_history ++ [hand_results]
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
  # Resets player states, increments round number, sets new blind target.
  # Shuffles player decks.
  # Returns {new_state, events}
  @spec advance_round(t()) :: {t(), list()}
  defp advance_round(%__MODULE__{} = game_state) do
    alias Oskol.Game.CardPiles

    # Get next blind target from levels list
    next_round = game_state.round_number + 1
    blind_index = min(next_round - 1, length(@blind_levels) - 1)
    new_blind_target = Enum.at(@blind_levels, blind_index)

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
         blind_target: new_blind_target,
         hands_remaining: 4,
         discards_remaining: 3
       }}

    events = [round_event | draw_events]

    new_state = %{
      game_state
      | round_number: next_round,
        blind_target: new_blind_target,
        players: updated_players,
        phase: :playing,
        last_hand_results: nil,
        round_hand_history: []
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
