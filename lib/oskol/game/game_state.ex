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
  """
  @spec player_lock_in_hand(t(), player_id(), list(Card.t())) :: t()
  def player_lock_in_hand(%__MODULE__{} = game_state, player_id, hand) do
    updated_players =
      Map.update!(game_state.players, player_id, fn player ->
        %{player | locked_in_hand: hand}
      end)

    game_state = %{game_state | players: updated_players}

    # Check if both players have locked in
    if both_players_locked_in?(game_state) do
      process_locked_hands(game_state)
    else
      game_state
    end
  end

  @doc """
  Player unlocks their hand choice, allowing them to select a different hand.
  Only works if both players haven't locked in yet.
  """
  @spec player_unlock_hand(t(), player_id()) :: {:ok, t()} | {:error, :cannot_unlock}
  def player_unlock_hand(%__MODULE__{} = game_state, player_id) do
    # Can only unlock if both players haven't locked in yet
    if both_players_locked_in?(game_state) do
      {:error, :cannot_unlock}
    else
      updated_players =
        Map.update!(game_state.players, player_id, fn player ->
          %{player | locked_in_hand: nil}
        end)

      {:ok, %{game_state | players: updated_players}}
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
  """
  @spec player_discard_cards(t(), player_id(), list(Card.t())) ::
          {:ok, t()} | {:error, :no_discards_remaining | :invalid_discard_count}
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

        updated_player = %{
          player
          | card_piles: new_card_piles,
            discards_remaining: player.discards_remaining - 1
        }

        updated_players = Map.put(game_state.players, player_id, updated_player)

        {:ok, %{game_state | players: updated_players}}
    end
  end

  # Processes locked-in hands: scores them, updates scores, draws new cards, and continues to next hand.
  # Stores results in last_hand_results for LiveViews to display.
  # If this was the last hand of the round, transitions to :round_end phase.
  @spec process_locked_hands(t()) :: t()
  defp process_locked_hands(%__MODULE__{} = game_state) do
    alias Oskol.Game.CardPiles

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

    # Update player scores, discard played cards, draw new cards, clear locked hands, decrement hands_remaining
    updated_players =
      Map.new(game_state.players, fn {player_id, player_state} ->
        result = hand_results[player_id]
        played_hand = player_state.locked_in_hand
        # Discard the played cards and draw new ones
        new_card_piles = CardPiles.replace_cards(player_state.card_piles, played_hand)

        updated_player = %{
          player_state
          | current_round_score: player_state.current_round_score + result.score,
            card_piles: new_card_piles,
            locked_in_hand: nil,
            hands_remaining: player_state.hands_remaining - 1
        }

        {player_id, updated_player}
      end)

    # Check if round is over (all players have 0 hands remaining)
    round_over =
      updated_players
      |> Map.values()
      |> Enum.all?(fn player -> player.hands_remaining == 0 end)

    if round_over do
      # Round is over - check blind targets and deduct lives
      players_with_updated_lives =
        Map.new(updated_players, fn {player_id, player_state} ->
          # Check if player hit the blind
          hit_blind = player_state.current_round_score >= game_state.blind_target

          # Deduct life if didn't hit blind
          new_lives =
            if hit_blind do
              player_state.lives
            else
              max(player_state.lives - 1, 0)
            end

          {player_id, %{player_state | lives: new_lives}}
        end)

      # Check for game over condition
      player_lives = players_with_updated_lives |> Map.values() |> Enum.map(& &1.lives)
      any_player_dead = Enum.any?(player_lives, &(&1 == 0))

      if any_player_dead do
        # Game over - determine winner
        winner_id = determine_winner(players_with_updated_lives)

        %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_with_updated_lives,
            round_hand_history: game_state.round_hand_history ++ [hand_results],
            game_status: :game_over,
            winner_id: winner_id
        }
      else
        # Round over but game continues
        %{
          game_state
          | phase: :round_end,
            last_hand_results: hand_results,
            players: players_with_updated_lives,
            round_hand_history: game_state.round_hand_history ++ [hand_results]
        }
      end
    else
      # Round not over yet - continue playing
      %{
        game_state
        | phase: :playing,
          last_hand_results: hand_results,
          players: updated_players,
          round_hand_history: game_state.round_hand_history ++ [hand_results]
      }
    end
  end

  @doc """
  Marks a player as ready for the next round (from the shop).
  If both players are ready, automatically advances to the next round.
  Only advances if game is not over.
  """
  @spec mark_ready_for_next_round(t(), player_id()) :: t()
  def mark_ready_for_next_round(%__MODULE__{phase: :round_end} = game_state, player_id) do
    updated_players =
      Map.update!(game_state.players, player_id, fn player ->
        %{player | ready_for_next_round: true}
      end)

    game_state = %{game_state | players: updated_players}

    # Check if both players are ready and game is not over
    if both_players_ready_for_next_round?(game_state) and game_state.game_status != :game_over do
      advance_round(game_state)
    else
      game_state
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
  @spec advance_round(t()) :: t()
  defp advance_round(%__MODULE__{} = game_state) do
    alias Oskol.Game.CardPiles

    # Shuffle decks and reset for next round
    updated_players =
      Map.new(game_state.players, fn {player_id, player_state} ->
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

        {player_id, updated_player}
      end)

    # Get next blind target from levels list
    next_round = game_state.round_number + 1
    blind_index = min(next_round - 1, length(@blind_levels) - 1)
    new_blind_target = Enum.at(@blind_levels, blind_index)

    %{
      game_state
      | round_number: next_round,
        blind_target: new_blind_target,
        players: updated_players,
        phase: :playing,
        last_hand_results: nil,
        round_hand_history: []
    }
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
