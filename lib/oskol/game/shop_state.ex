defmodule Oskol.Game.ShopState do
  @moduledoc """
  Manages the simple multi-round shop where winner picks first, loser picks second.
  Each round both players pick from the same pool of upgrades.
  """

  alias Oskol.Game.{PlayerState, ShopCard}
  alias Oskol.Poker.Card
  alias Oskol.Utils.WeightedRandom

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
          pending_plus_bomb: pending_plus_bomb() | nil,
          # Destroy phase fields
          destroy_phase_complete: boolean(),
          destroyer_id: player_id() | nil,
          destroys_allowed: non_neg_integer(),
          destroyed_card_indices: [non_neg_integer()]
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
            pending_plus_bomb: nil,
            # Destroy phase fields
            destroy_phase_complete: true,
            destroyer_id: nil,
            destroys_allowed: 0,
            destroyed_card_indices: []

  @doc """
  Creates a new shop state.

  ## Parameters
  - winner_id: The player who won the last round (picks first)
  - loser_id: The player who lost the last round (picks second)
  - round_was_tie: If true, randomly assign who picks first
  - total_rounds: Number of upgrade rounds (1-3)
  - dev_codes: Optional list of dev codes for forcing specific cards
  - player_lives: Optional map of %{player_id => lives} for destroy phase calculation
  """
  @spec new(player_id(), player_id(), boolean(), pos_integer(), [String.t()], map()) :: t()
  def new(winner_id, loser_id, round_was_tie, total_rounds, dev_codes \\ [], player_lives \\ %{}) do
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

    # Calculate destroy phase based on life difference
    # The player who is behind in lives can destroy cards equal to the difference
    # This is independent of who won the round - whoever has fewer lives gets to destroy
    {destroyer_id, destroys_allowed, destroy_phase_complete} =
      if map_size(player_lives) == 2 do
        [{player1_id, player1_lives}, {player2_id, player2_lives}] = Map.to_list(player_lives)

        cond do
          player1_lives < player2_lives ->
            # Player 1 is behind - they get to destroy cards
            {player1_id, player2_lives - player1_lives, false}

          player2_lives < player1_lives ->
            # Player 2 is behind - they get to destroy cards
            {player2_id, player1_lives - player2_lives, false}

          true ->
            # Lives are equal - no destroy phase
            {nil, 0, true}
        end
      else
        # No life info provided - skip destroy phase
        {nil, 0, true}
      end

    %__MODULE__{
      total_rounds: total_rounds,
      current_round: 1,
      first_picker_id: first_player,
      second_picker_id: second_player,
      first_pick_made: false,
      second_pick_made: false,
      available_cards: generate_random_shop_cards(dev_codes),
      picked_card_indices: [],
      # Destroy phase
      destroy_phase_complete: destroy_phase_complete,
      destroyer_id: destroyer_id,
      destroys_allowed: destroys_allowed,
      destroyed_card_indices: []
    }
  end

  # Centralized shop card probability tree
  # For each card slot, we:
  # 1. Sample a branch (e.g., Research vs Logistics) using branch weights
  # 2. Sample a specific card from that branch using card weights
  @shop_probabilities %{
    arsenal: %{
      branches: %{
        research: %{
          weight: 1,
          cards: %{
            high_card: 1,
            pair: 1,
            two_pair: 1,
            three_of_a_kind: 1,
            straight: 1,
            flush: 1,
            full_house: 1,
            four_of_a_kind: 1,
            straight_flush: 1
          }
        },
        logistics: %{
          weight: 1,
          cards: %{
            bonus_chips: 4,
            bonus_mult: 4,
            add_card: 4,
            remove_card: 4,
            change_suit_hearts: 1,
            change_suit_diamonds: 1,
            change_suit_clubs: 1,
            change_suit_spades: 1,
            increase_rank: 4
          }
        }
      }
    },
    actions: %{
      branches: %{
        sabotage: %{
          weight: 1,
          cards: %{
            scrambler: 1,
            plus_bomb: 1,
            static: 1,
            supply_chain: 1
          }
        },
        counter: %{
          weight: 1,
          cards: %{
            high_card: 1,
            pair: 1,
            two_pair: 1,
            three_of_a_kind: 1,
            straight: 1,
            flush: 1,
            full_house: 1,
            four_of_a_kind: 1,
            straight_flush: 1
          }
        }
      }
    }
  }

  # Generates a pool of 16 shop cards using hierarchical probability tree:
  # For each card slot:
  #   1. Sample branch (e.g., Research vs Logistics) using branch weights
  #   2. Sample specific card from that branch using card weights
  #
  # Top 8: ARSENAL (Research + Logistics branches)
  # Bottom 8: ACTIONS (Sabotage + Counter branches)
  #
  # Cards are sorted by category for consistency.
  # Dev codes can force specific cards to appear.
  @spec generate_random_shop_cards([String.t()]) :: [shop_card()]
  defp generate_random_shop_cards(dev_codes) do
    arsenal_config = @shop_probabilities.arsenal
    actions_config = @shop_probabilities.actions

    # Generate 8 Arsenal cards (each independently samples branch then card)
    arsenal_cards =
      Enum.map(1..8, fn _ -> sample_card_from_tree(arsenal_config) end)
      |> Enum.sort_by(&card_sort_key/1)

    # Generate 8 Action cards (each independently samples branch then card)
    # Handle dev codes for forced sabotage cards
    action_cards =
      Enum.map(1..8, fn _ -> sample_card_from_tree(actions_config) end)
      |> apply_dev_code_overrides(dev_codes)
      |> Enum.sort_by(&card_sort_key/1)

    arsenal_cards ++ action_cards
  end

  # Samples a single card from a probability tree
  # Tree structure: %{branches: %{branch_name => %{weight: w, cards: %{card => weight}}}}
  @spec sample_card_from_tree(%{branches: map()}) :: shop_card()
  defp sample_card_from_tree(%{branches: branches}) do
    # Step 1: Sample which branch (e.g., research vs logistics)
    branch_weights = Map.new(branches, fn {name, config} -> {name, config.weight} end)
    branch_name = WeightedRandom.sample(branch_weights)

    # Step 2: Sample which card from that branch
    branch_config = branches[branch_name]
    card_key = WeightedRandom.sample(branch_config.cards)

    # Step 3: Convert card key to ShopCard struct
    card_key_to_shop_card(branch_name, card_key)
  end

  # Converts a branch name and card key to a ShopCard struct
  @spec card_key_to_shop_card(atom(), atom()) :: shop_card()
  defp card_key_to_shop_card(:research, hand_type),
    do: %ShopCard{type: :level_up, subtype: hand_type}

  defp card_key_to_shop_card(:logistics, :bonus_chips),
    do: %ShopCard{
      type: :deck_builder,
      subtype: :bonus_chips,
      metadata: %{amount: 40, max_cards: 1}
    }

  defp card_key_to_shop_card(:logistics, :bonus_mult),
    do: %ShopCard{type: :deck_builder, subtype: :bonus_mult, metadata: %{amount: 1, max_cards: 1}}

  defp card_key_to_shop_card(:logistics, :add_card),
    do: %ShopCard{type: :deck_builder, subtype: :add_card, metadata: %{max_cards: 1}}

  defp card_key_to_shop_card(:logistics, :remove_card),
    do: %ShopCard{type: :deck_builder, subtype: :remove_card, metadata: %{max_cards: 2}}

  defp card_key_to_shop_card(:logistics, :change_suit_hearts),
    do: %ShopCard{
      type: :deck_builder,
      subtype: :change_suit,
      metadata: %{suit: :hearts, max_cards: 3}
    }

  defp card_key_to_shop_card(:logistics, :change_suit_diamonds),
    do: %ShopCard{
      type: :deck_builder,
      subtype: :change_suit,
      metadata: %{suit: :diamonds, max_cards: 3}
    }

  defp card_key_to_shop_card(:logistics, :change_suit_clubs),
    do: %ShopCard{
      type: :deck_builder,
      subtype: :change_suit,
      metadata: %{suit: :clubs, max_cards: 3}
    }

  defp card_key_to_shop_card(:logistics, :change_suit_spades),
    do: %ShopCard{
      type: :deck_builder,
      subtype: :change_suit,
      metadata: %{suit: :spades, max_cards: 3}
    }

  defp card_key_to_shop_card(:logistics, :increase_rank),
    do: %ShopCard{type: :deck_builder, subtype: :increase_rank, metadata: %{max_cards: 2}}

  defp card_key_to_shop_card(:sabotage, :scrambler), do: ShopCard.scrambler_card()

  defp card_key_to_shop_card(:sabotage, :plus_bomb),
    do: %ShopCard{type: :sabotage, subtype: :plus_bomb, metadata: %{max_cards: 1}}

  defp card_key_to_shop_card(:sabotage, :static), do: ShopCard.static_card()
  defp card_key_to_shop_card(:sabotage, :supply_chain), do: ShopCard.supply_chain_card()

  defp card_key_to_shop_card(:counter, hand_type),
    do: %ShopCard{type: :denial, subtype: hand_type}

  # Apply dev code overrides to force specific sabotage cards
  @spec apply_dev_code_overrides([shop_card()], [String.t()]) :: [shop_card()]
  defp apply_dev_code_overrides(cards, dev_codes) do
    forced_cards = []

    forced_cards =
      if "SHOP_FORCE_SCRAMBLER" in dev_codes do
        [ShopCard.scrambler_card() | forced_cards]
      else
        forced_cards
      end

    forced_cards =
      if "SHOP_FORCE_PLUS_BOMB" in dev_codes do
        [ShopCard.plus_bomb_card() | forced_cards]
      else
        forced_cards
      end

    forced_cards =
      if "SHOP_FORCE_STATIC" in dev_codes do
        [ShopCard.static_card() | forced_cards]
      else
        forced_cards
      end

    forced_cards =
      if "SHOP_FORCE_SUPPLY_CHAIN" in dev_codes do
        [ShopCard.supply_chain_card() | forced_cards]
      else
        forced_cards
      end

    if length(forced_cards) > 0 do
      # Replace first N cards with forced cards
      remaining_cards = Enum.drop(cards, length(forced_cards))
      forced_cards ++ remaining_cards
    else
      cards
    end
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
      # Destroy phase must be complete before picking
      not shop_state.destroy_phase_complete ->
        {:error, :destroy_phase_not_complete}

      card_index < 0 or card_index >= length(shop_state.available_cards) ->
        {:error, :invalid_card_index}

      card_index in shop_state.picked_card_indices ->
        {:error, :card_already_picked}

      card_index in shop_state.destroyed_card_indices ->
        {:error, :card_destroyed}

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
  Destroy phase must be complete before anyone can pick.
  """
  @spec can_pick?(t(), player_id()) :: boolean()
  def can_pick?(%__MODULE__{} = shop_state, player_id) do
    # Can't pick if destroy phase is still active
    if not shop_state.destroy_phase_complete do
      false
    else
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

  # ===== Destroy Phase Functions =====

  @doc """
  Returns true if the destroy phase is still active (not complete).
  """
  @spec in_destroy_phase?(t()) :: boolean()
  def in_destroy_phase?(%__MODULE__{destroy_phase_complete: complete}), do: not complete

  @doc """
  Returns true if the given player can destroy cards.
  """
  @spec can_destroy?(t(), player_id()) :: boolean()
  def can_destroy?(%__MODULE__{} = shop_state, player_id) do
    not shop_state.destroy_phase_complete and
      shop_state.destroyer_id == player_id and
      length(shop_state.destroyed_card_indices) < shop_state.destroys_allowed
  end

  @doc """
  Returns how many more cards the destroyer can destroy.
  """
  @spec destroys_remaining(t()) :: non_neg_integer()
  def destroys_remaining(%__MODULE__{} = shop_state) do
    max(0, shop_state.destroys_allowed - length(shop_state.destroyed_card_indices))
  end

  @doc """
  Destroys a card at the given index. The destroyed card cannot be picked by either player.
  Auto-completes the destroy phase when all destroys are used.
  """
  @spec destroy_card(t(), player_id(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def destroy_card(%__MODULE__{} = shop_state, player_id, card_index) do
    cond do
      shop_state.destroy_phase_complete ->
        {:error, :destroy_phase_complete}

      shop_state.destroyer_id != player_id ->
        {:error, :not_destroyer}

      length(shop_state.destroyed_card_indices) >= shop_state.destroys_allowed ->
        {:error, :no_destroys_remaining}

      card_index < 0 or card_index >= length(shop_state.available_cards) ->
        {:error, :invalid_card_index}

      card_index in shop_state.destroyed_card_indices ->
        {:error, :card_already_destroyed}

      true ->
        new_destroyed = [card_index | shop_state.destroyed_card_indices]
        # Auto-complete destroy phase when all destroys are used
        all_destroys_used = length(new_destroyed) >= shop_state.destroys_allowed

        updated_state = %{
          shop_state
          | destroyed_card_indices: new_destroyed,
            destroy_phase_complete: all_destroys_used
        }

        {:ok, updated_state}
    end
  end

  @doc """
  Completes the destroy phase, allowing normal picking to begin.
  Can be called even if not all destroys have been used (player chooses to skip remaining).
  """
  @spec complete_destroy_phase(t(), player_id()) :: {:ok, t()} | {:error, atom()}
  def complete_destroy_phase(%__MODULE__{} = shop_state, player_id) do
    cond do
      shop_state.destroy_phase_complete ->
        {:error, :already_complete}

      shop_state.destroyer_id != player_id ->
        {:error, :not_destroyer}

      true ->
        updated_state = %{shop_state | destroy_phase_complete: true}
        {:ok, updated_state}
    end
  end

  @doc """
  Returns true if a card at the given index has been destroyed.
  """
  @spec card_destroyed?(t(), non_neg_integer()) :: boolean()
  def card_destroyed?(%__MODULE__{destroyed_card_indices: destroyed}, card_index) do
    card_index in destroyed
  end

  @doc """
  Checks if a card is unavailable (either picked or destroyed).
  """
  @spec card_unavailable?(t(), non_neg_integer()) :: boolean()
  def card_unavailable?(%__MODULE__{} = shop_state, card_index) do
    card_index in shop_state.picked_card_indices or
      card_index in shop_state.destroyed_card_indices
  end
end
