defmodule Oskol.Game.ShopState do
  @moduledoc """
  Manages the simple multi-round shop where winner picks first, loser picks second.
  Each round both players pick from the same pool of upgrades.
  """

  alias Oskol.Game.{PlayerState, ShopCard}
  alias Oskol.Poker.Card

  @type player_id :: PlayerState.player_id()

  @type shop_card :: ShopCard.t()

  @type pending_deck_builder :: %{
          player_id: player_id(),
          shop_card_index: non_neg_integer(),
          deck_builder_card: ShopCard.t(),
          available_cards: [Card.t()]
        }

  @type pending_plus_bomb :: %{
          player_id: player_id(),
          shop_card_index: non_neg_integer(),
          available_cards: [Card.t()]
        }

  @type t :: %__MODULE__{
          total_rounds: pos_integer(),
          current_round: pos_integer(),
          first_picker_id: player_id(),
          second_picker_id: player_id(),
          first_pick_made: boolean(),
          second_pick_made: boolean(),
          available_cards: [shop_card()],
          picked_card_indices: [non_neg_integer()],
          pending_deck_builder: pending_deck_builder() | nil,
          pending_plus_bomb: pending_plus_bomb() | nil
        }

  defstruct total_rounds: 1,
            current_round: 1,
            first_picker_id: nil,
            second_picker_id: nil,
            first_pick_made: false,
            second_pick_made: false,
            available_cards: [],
            picked_card_indices: [],
            pending_deck_builder: nil,
            pending_plus_bomb: nil

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

  # Arsenal distribution weights: {research_count, logistics_count} => weight
  # Higher weight = more likely to be selected
  @arsenal_distributions %{
    {6, 2} => 2,
    {5, 3} => 3,
    {4, 4} => 3,
    {3, 5} => 2,
    {2, 6} => 1
  }

  # Action distribution weights: {sabotage_count, counter_count} => weight
  # Fixed 50-50 split for now
  @action_distributions %{
    {4, 4} => 1
  }

  # Generates a pool of 16 shop cards using two-level randomization:
  # Level 1: Decide category split (e.g., 5 research + 3 logistics)
  # Level 2: Randomize within each category with proper weights
  #
  # Top 8: ARSENAL (Research + Logistics)
  # Bottom 8: ACTIONS (Sabotage + Counters, 50-50 split)
  #
  # Cards are sorted by category for consistency.
  # Dev codes can force specific cards to appear.
  @spec generate_random_shop_cards([String.t()]) :: [shop_card()]
  defp generate_random_shop_cards(dev_codes) do
    # Level 1: Sample arsenal distribution (research vs logistics split)
    {research_count, logistics_count} = sample_from_distribution(@arsenal_distributions)

    # Level 2: Generate cards within each category
    research_cards =
      ShopCard.generate_random_level_ups(research_count)
      |> Enum.sort_by(&card_sort_key/1)

    logistics_cards =
      ShopCard.generate_random_deck_builders(logistics_count)
      |> Enum.sort_by(&card_sort_key/1)

    # Level 1: Sample action distribution (sabotage vs counter split)
    {sabotage_count, counter_count} = sample_from_distribution(@action_distributions)

    # Level 2: Generate cards within each category
    sabotage_cards =
      ShopCard.generate_random_sabotage_cards(sabotage_count, dev_codes)
      |> Enum.sort_by(&card_sort_key/1)

    counter_cards =
      ShopCard.generate_random_denial_cards(counter_count)
      |> Enum.sort_by(&card_sort_key/1)

    # Combine in order: research, logistics, sabotage, counters (8 arsenal + 8 actions)
    research_cards ++ logistics_cards ++ sabotage_cards ++ counter_cards
  end

  # Samples a single item from a weighted distribution map
  # Map format: %{item => weight, ...}
  # Returns the selected item
  @spec sample_from_distribution(%{any() => pos_integer()}) :: any()
  defp sample_from_distribution(distribution) when map_size(distribution) > 0 do
    # Create a list of {item, weight} tuples
    items_with_weights = Enum.to_list(distribution)

    # Calculate total weight
    total_weight = Enum.reduce(items_with_weights, 0, fn {_item, weight}, acc -> acc + weight end)

    # Generate random number in range [1, total_weight]
    random_value = :rand.uniform(total_weight)

    # Find the item that corresponds to this random value
    {selected_item, _weight} =
      Enum.reduce_while(items_with_weights, {nil, 0}, fn {item, weight}, {_current_item, cumulative} ->
        new_cumulative = cumulative + weight

        if random_value <= new_cumulative do
          {:halt, {item, weight}}
        else
          {:cont, {item, new_cumulative}}
        end
      end)

    selected_item
  end

  # Sort key for shop cards - unified sorting across all card types
  defp card_sort_key(%ShopCard{type: :level_up, subtype: hand}), do: {0, hand_type_order(hand)}
  defp card_sort_key(%ShopCard{type: :deck_builder, subtype: :bonus_chips}), do: {1, 0}
  defp card_sort_key(%ShopCard{type: :deck_builder, subtype: :bonus_mult}), do: {1, 1}
  defp card_sort_key(%ShopCard{type: :deck_builder, subtype: :add_card}), do: {1, 2}
  defp card_sort_key(%ShopCard{type: :deck_builder, subtype: :remove_card}), do: {1, 3}

  defp card_sort_key(%ShopCard{
         type: :deck_builder,
         subtype: :change_suit,
         metadata: %{suit: :hearts}
       }),
       do: {1, 4}

  defp card_sort_key(%ShopCard{
         type: :deck_builder,
         subtype: :change_suit,
         metadata: %{suit: :diamonds}
       }),
       do: {1, 5}

  defp card_sort_key(%ShopCard{
         type: :deck_builder,
         subtype: :change_suit,
         metadata: %{suit: :clubs}
       }),
       do: {1, 6}

  defp card_sort_key(%ShopCard{
         type: :deck_builder,
         subtype: :change_suit,
         metadata: %{suit: :spades}
       }),
       do: {1, 7}

  defp card_sort_key(%ShopCard{type: :deck_builder, subtype: :increase_rank}), do: {1, 8}

  # Sabotage cards (scrambler, plus_bomb, static, supply_chain)
  defp card_sort_key(%ShopCard{type: :sabotage, subtype: :scrambler}), do: {2, 0}
  defp card_sort_key(%ShopCard{type: :sabotage, subtype: :plus_bomb}), do: {2, 1}
  defp card_sort_key(%ShopCard{type: :sabotage, subtype: :static}), do: {2, 2}
  defp card_sort_key(%ShopCard{type: :sabotage, subtype: :supply_chain}), do: {2, 3}

  # Denial cards (sorted by hand type)
  defp card_sort_key(%ShopCard{type: :denial, subtype: hand}), do: {3, hand_type_order(hand)}

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
        pending_deck_builder: nil,
        pending_plus_bomb: nil
    }
  end

  def advance_round(%__MODULE__{} = shop_state) do
    # Already at final round, can't advance
    shop_state
  end
end
