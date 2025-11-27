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
          {:level_up, hand_type()}
          | {:action, ActionCard.t()}
          | {:deck_builder, DeckBuilderCard.t()}

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
  - dev_codes: Optional list of dev codes for forcing specific cards
  """
  @spec new(player_id(), player_id(), boolean(), pos_integer(), [String.t()]) :: t()
  def new(winner_id, loser_id, round_was_tie, total_rounds, dev_codes \\ []) do
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
      available_cards: generate_random_shop_cards(dev_codes),
      picked_card_indices: []
    }
  end

  # Generates a pool of 12 shop cards: 4 level ups + 4 deck builders + 4 action cards.
  # Cards are sorted by category (level ups first, then deck builders, then actions)
  # and within each category they are sorted for consistency.
  # Dev codes can force specific cards to appear.
  @spec generate_random_shop_cards([String.t()]) :: [shop_card()]
  defp generate_random_shop_cards(dev_codes) do
    # Generate 4 random level up cards with weighted frequencies (sorted by hand type)
    # Frequencies: High Card (4), Pair (4), Two Pair (3), Three Kind (3),
    #              Straight (2), Flush (2), Full House (2), Four Kind (1), Straight Flush (1)
    level_up_pool =
      [
        List.duplicate(:high_card, 4),
        List.duplicate(:pair, 4),
        List.duplicate(:two_pair, 3),
        List.duplicate(:three_of_a_kind, 3),
        List.duplicate(:straight, 2),
        List.duplicate(:flush, 2),
        List.duplicate(:full_house, 2),
        List.duplicate(:four_of_a_kind, 1),
        List.duplicate(:straight_flush, 1)
      ]
      |> List.flatten()

    level_ups =
      level_up_pool
      |> Enum.shuffle()
      |> Enum.take(4)
      |> Enum.sort_by(&hand_type_order/1)
      |> Enum.map(fn hand_type -> {:level_up, hand_type} end)

    # Generate 4 deck builder cards (sorted by type)
    deck_builder_cards =
      DeckBuilderCard.generate_random_deck_builder_cards(4)
      |> Enum.sort_by(&deck_builder_sort_key/1)
      |> Enum.map(fn card -> {:deck_builder, card} end)

    # Generate 4 random action cards (sorted by target_hand)
    # Check for dev codes that force specific action cards
    action_cards =
      if "SHOP_FORCE_SCRAMBLER" in dev_codes do
        # Force a scrambler card to be in the first action slot
        scrambler = ActionCard.scrambler_card()
        other_actions = ActionCard.generate_random_action_cards(3)
        [scrambler | other_actions]
      else
        ActionCard.generate_random_action_cards(4)
      end
      |> Enum.sort_by(&action_card_sort_key/1)
      |> Enum.map(fn card -> {:action, card} end)

    # Combine in order: level ups, deck builders, actions
    level_ups ++ deck_builder_cards ++ action_cards
  end

  # Sort key for action cards (scramblers first, then by target_hand)
  defp action_card_sort_key(%ActionCard{type: :scrambler}), do: {0, 0}

  defp action_card_sort_key(%ActionCard{type: :denial, target_hand: hand}),
    do: {1, hand_type_order(hand)}

  # Sort key for hand types (high card to straight flush)
  defp hand_type_order(:high_card), do: 0
  defp hand_type_order(:pair), do: 1
  defp hand_type_order(:two_pair), do: 2
  defp hand_type_order(:three_of_a_kind), do: 3
  defp hand_type_order(:straight), do: 4
  defp hand_type_order(:flush), do: 5
  defp hand_type_order(:full_house), do: 6
  defp hand_type_order(:four_of_a_kind), do: 7
  defp hand_type_order(:straight_flush), do: 8

  # Sort key for deck builder cards (chips, mult, add, remove, suit changes)
  defp deck_builder_sort_key(%DeckBuilderCard{type: :bonus_chips}), do: 0
  defp deck_builder_sort_key(%DeckBuilderCard{type: :bonus_mult}), do: 1
  defp deck_builder_sort_key(%DeckBuilderCard{type: :add_card}), do: 2
  defp deck_builder_sort_key(%DeckBuilderCard{type: :remove_card}), do: 3
  defp deck_builder_sort_key(%DeckBuilderCard{type: :change_suit_hearts}), do: 4
  defp deck_builder_sort_key(%DeckBuilderCard{type: :change_suit_diamonds}), do: 5
  defp deck_builder_sort_key(%DeckBuilderCard{type: :change_suit_clubs}), do: 6
  defp deck_builder_sort_key(%DeckBuilderCard{type: :change_suit_spades}), do: 7
  defp deck_builder_sort_key(%DeckBuilderCard{type: :increase_rank}), do: 8

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
