defmodule Oskol.Game.ShopState do
  @moduledoc """
  Manages the simple multi-round shop where winner picks first, loser picks second.
  Each round both players pick from the same pool of upgrades.
  """

  alias Oskol.Game.{PlayerState, ActionCard, DeckBuilderCard}
  alias Oskol.Poker.Card

  @type player_id :: PlayerState.player_id()

  @type hand_type ::
          :high_card
          | :pair
          | :two_pair
          | :three_of_a_kind
          | :straight
          | :flush
          | :full_house
          | :four_of_a_kind
          | :straight_flush

  @type shop_card ::
          {:level_up, hand_type()} | {:action, ActionCard.t()} | {:deck_builder, DeckBuilderCard.t()}

  @type pending_deck_builder :: %{
          player_id: player_id(),
          shop_card_index: non_neg_integer(),
          deck_builder_card: DeckBuilderCard.t(),
          available_cards: [Card.t()]
        }

  @all_hand_types [
    :high_card,
    :pair,
    :two_pair,
    :three_of_a_kind,
    :straight,
    :flush,
    :full_house,
    :four_of_a_kind,
    :straight_flush
  ]

  @type t :: %__MODULE__{
          total_rounds: pos_integer(),
          current_round: pos_integer(),
          first_picker_id: player_id(),
          second_picker_id: player_id(),
          first_pick_made: boolean(),
          second_pick_made: boolean(),
          available_cards: [shop_card()],
          picked_card_indices: [non_neg_integer()],
          pending_deck_builder: pending_deck_builder() | nil
        }

  defstruct total_rounds: 1,
            current_round: 1,
            first_picker_id: nil,
            second_picker_id: nil,
            first_pick_made: false,
            second_pick_made: false,
            available_cards: [],
            picked_card_indices: [],
            pending_deck_builder: nil

  @doc """
  Creates a new shop state.

  ## Parameters
  - winner_id: The player who won the last round (picks first)
  - loser_id: The player who lost the last round (picks second)
  - round_was_tie: If true, randomly assign who picks first
  - total_rounds: Number of upgrade rounds (1-3)
  """
  @spec new(player_id(), player_id(), boolean(), pos_integer()) :: t()
  def new(winner_id, loser_id, round_was_tie, total_rounds) do
    # If tie, randomly pick who goes first
    {first_player, second_player} =
      if round_was_tie do
        if :rand.uniform(2) == 1 do
          {winner_id, loser_id}
        else
          {loser_id, winner_id}
        end
      else
        {winner_id, loser_id}
      end

    %__MODULE__{
      total_rounds: total_rounds,
      current_round: 1,
      first_picker_id: first_player,
      second_picker_id: second_player,
      first_pick_made: false,
      second_pick_made: false,
      available_cards: generate_random_shop_cards(),
      picked_card_indices: []
    }
  end

  # Generates a random pool of 12 shop cards: 3 level ups + 3 action cards + 6 deck builders.
  # For level ups: triples all 9 hand types (27), shuffles, takes 3
  # For action cards: triples all 9 denial cards (27), shuffles, takes 3
  # For deck builders: shuffles all 8 deck builder cards, takes 6
  # Then shuffles all 12 together
  @spec generate_random_shop_cards() :: [shop_card()]
  defp generate_random_shop_cards do
    # Generate 3 random level up cards
    level_ups =
      @all_hand_types
      |> List.duplicate(3)
      |> List.flatten()
      |> Enum.shuffle()
      |> Enum.take(3)
      |> Enum.map(fn hand_type -> {:level_up, hand_type} end)

    # Generate 3 random action cards
    action_cards =
      ActionCard.generate_random_action_cards(3)
      |> Enum.map(fn card -> {:action, card} end)

    # Generate 6 random deck builder cards
    deck_builder_cards =
      DeckBuilderCard.generate_random_deck_builder_cards(6)
      |> Enum.map(fn card -> {:deck_builder, card} end)

    # Combine and shuffle all 12 cards
    (level_ups ++ action_cards ++ deck_builder_cards)
    |> Enum.shuffle()
  end

  @doc """
  Returns true if both players have made their picks in the current round.
  """
  @spec both_players_picked?(t()) :: boolean()
  def both_players_picked?(%__MODULE__{} = shop_state) do
    shop_state.first_pick_made and shop_state.second_pick_made
  end

  @doc """
  Returns true if all shop rounds are complete.
  """
  @spec shop_complete?(t()) :: boolean()
  def shop_complete?(%__MODULE__{} = shop_state) do
    shop_state.current_round == shop_state.total_rounds and both_players_picked?(shop_state)
  end

  @doc """
  Records a player's pick in the current round.
  Returns the selected shop card along with the updated shop state.
  """
  @spec make_pick(t(), player_id(), non_neg_integer()) ::
          {:ok, t(), shop_card()} | {:error, atom()}
  def make_pick(%__MODULE__{} = shop_state, player_id, card_index) do
    cond do
      card_index < 0 or card_index >= length(shop_state.available_cards) ->
        {:error, :invalid_card_index}

      card_index in shop_state.picked_card_indices ->
        {:error, :card_already_picked}

      not shop_state.first_pick_made and player_id == shop_state.first_picker_id ->
        selected_card = Enum.at(shop_state.available_cards, card_index)

        updated_state = %{
          shop_state
          | first_pick_made: true,
            picked_card_indices: [card_index | shop_state.picked_card_indices]
        }

        {:ok, updated_state, selected_card}

      shop_state.first_pick_made and not shop_state.second_pick_made and
          player_id == shop_state.second_picker_id ->
        selected_card = Enum.at(shop_state.available_cards, card_index)

        updated_state = %{
          shop_state
          | second_pick_made: true,
            picked_card_indices: [card_index | shop_state.picked_card_indices]
        }

        {:ok, updated_state, selected_card}

      true ->
        {:error, :not_your_turn}
    end
  end

  @doc """
  Marks a card as picked without completing the pick.
  Used for deck builders which need two-phase commitment.
  """
  @spec mark_card_picked(t(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def mark_card_picked(%__MODULE__{} = shop_state, card_index) do
    cond do
      card_index < 0 or card_index >= length(shop_state.available_cards) ->
        {:error, :invalid_card_index}

      card_index in shop_state.picked_card_indices ->
        {:error, :card_already_picked}

      true ->
        updated_state = %{
          shop_state
          | picked_card_indices: [card_index | shop_state.picked_card_indices]
        }

        {:ok, updated_state}
    end
  end

  @doc """
  Completes a pending pick by marking first_pick_made or second_pick_made.
  Used after deck builder selection is confirmed.
  """
  @spec complete_pick(t(), player_id()) :: {:ok, t()} | {:error, atom()}
  def complete_pick(%__MODULE__{} = shop_state, player_id) do
    cond do
      not shop_state.first_pick_made and player_id == shop_state.first_picker_id ->
        updated_state = %{shop_state | first_pick_made: true}
        {:ok, updated_state}

      shop_state.first_pick_made and not shop_state.second_pick_made and
          player_id == shop_state.second_picker_id ->
        updated_state = %{shop_state | second_pick_made: true}
        {:ok, updated_state}

      true ->
        {:error, :not_your_turn}
    end
  end

  @doc """
  Checks if it's the given player's turn to pick (and they haven't picked yet).
  """
  @spec can_pick?(t(), player_id()) :: boolean()
  def can_pick?(%__MODULE__{} = shop_state, player_id) do
    cond do
      not shop_state.first_pick_made and shop_state.first_picker_id == player_id ->
        true

      shop_state.first_pick_made and not shop_state.second_pick_made and
          shop_state.second_picker_id == player_id ->
        true

      true ->
        false
    end
  end

  @doc """
  Advances to the next shop round.
  Should be called after both players have picked.
  Keeps the same card pool and picked cards - only resets pick flags.
  """
  @spec advance_round(t()) :: t()
  def advance_round(%__MODULE__{current_round: round, total_rounds: total} = shop_state)
      when round < total do
    %{
      shop_state
      | current_round: round + 1,
        first_pick_made: false,
        second_pick_made: false,
        pending_deck_builder: nil
    }
  end

  def advance_round(%__MODULE__{} = shop_state) do
    # Already at final round, can't advance
    shop_state
  end
end
