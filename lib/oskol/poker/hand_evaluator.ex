defmodule Oskol.Poker.HandEvaluator do
  @moduledoc """
  Evaluates poker hands with support for wild cards and upgrade modifiers.

  Uses a constraint-based greedy algorithm to efficiently determine the best
  possible hand without generating all possible card combinations (which would
  be exponential for multiple wild cards).

  Algorithm:
  1. Partition cards into regular cards and wild cards
  2. Try each hand type from best to worst (straight flush → high card)
  3. For each hand type, check if it's achievable using constraint checking
  4. Greedily assign wild cards to optimize the hand
  5. Return the first valid hand (which will be the best)
  """

  alias Oskol.Poker.{Card, Hand, UpgradeModifiers}

  @doc """
  Evaluates a hand that may contain wild cards and upgrade modifiers.
  Returns the best possible hand type and optimal card assignment.

  Wild cards will be assigned specific rank/suit values to form the best hand.
  """
  @spec evaluate(list(Card.t()), UpgradeModifiers.t()) :: Hand.evaluation()
  def evaluate(cards, modifiers \\ %UpgradeModifiers{})
      when is_list(cards) and length(cards) >= 1 and length(cards) <= 5 do
    # Partition into regular and wild cards
    {regular_cards, wild_cards} = partition_cards(cards)

    # Try each hand type from best to worst
    result = try_hand_types(regular_cards, wild_cards, modifiers)

    # Convert assigned cards back to full card list
    %{
      hand_type: elem(result, 0),
      played_cards: cards,
      scoring_cards: elem(result, 1)
    }
  end

  # Partitions cards into regular cards and wild cards
  defp partition_cards(cards) do
    Enum.split_with(cards, fn card -> is_nil(card.wild_type) end)
  end

  # Tries each hand type from best to worst
  defp try_hand_types(regular, wilds, mods) do
    try_straight_flush(regular, wilds, mods) ||
      try_four_of_a_kind(regular, wilds, mods) ||
      try_full_house(regular, wilds, mods) ||
      try_flush(regular, wilds, mods) ||
      try_straight(regular, wilds, mods) ||
      try_three_of_a_kind(regular, wilds, mods) ||
      try_two_pair(regular, wilds, mods) ||
      try_pair(regular, wilds, mods) ||
      try_high_card(regular, wilds, mods)
  end

  # Each try_* function returns {hand_type, scoring_cards} or nil

  defp try_straight_flush(regular_cards, wild_cards, mods) do
    min_cards_needed = if mods.straight_flush_needs_only_4, do: 4, else: 5

    if length(regular_cards) + length(wild_cards) < min_cards_needed do
      nil
    else
      # Try to find a suited sequence
      case find_suited_sequence(regular_cards, wild_cards, min_cards_needed, mods) do
        {:ok, assigned_cards} -> {:straight_flush, assigned_cards}
        :error -> nil
      end
    end
  end

  defp try_four_of_a_kind(regular_cards, wild_cards, _mods) do
    if length(regular_cards) + length(wild_cards) < 4 do
      nil
    else
      # Count rank frequencies
      rank_counts = count_ranks(regular_cards)
      num_wilds = length(wild_cards)

      # Find rank that can reach 4 with wilds
      case find_rank_with_min_count(rank_counts, num_wilds, 4) do
        {:ok, target_rank} ->
          regular_in_hand = Enum.filter(regular_cards, &(&1.rank == target_rank))
          wilds_needed = 4 - length(regular_in_hand)
          assigned_wilds = assign_wilds_to_rank(Enum.take(wild_cards, wilds_needed), target_rank)
          {:four_of_a_kind, regular_in_hand ++ assigned_wilds}

        :error ->
          nil
      end
    end
  end

  defp try_full_house(regular_cards, wild_cards, _mods) do
    # Full house always needs exactly 5 cards (3 of one rank + 2 of another)
    if length(regular_cards) + length(wild_cards) < 5 do
      nil
    else
      rank_counts = count_ranks(regular_cards)
      num_wilds = length(wild_cards)

      case find_full_house_ranks(rank_counts, num_wilds) do
        {:ok, {three_rank, two_rank}} ->
          regular_threes = Enum.filter(regular_cards, &(&1.rank == three_rank))
          regular_twos = Enum.filter(regular_cards, &(&1.rank == two_rank))

          wilds_for_three = 3 - length(regular_threes)
          wilds_for_two = 2 - length(regular_twos)

          assigned_wilds_three =
            assign_wilds_to_rank(Enum.take(wild_cards, wilds_for_three), three_rank)

          assigned_wilds_two =
            assign_wilds_to_rank(
              Enum.slice(wild_cards, wilds_for_three, wilds_for_two),
              two_rank
            )

          all_cards = regular_threes ++ regular_twos ++ assigned_wilds_three ++ assigned_wilds_two
          {:full_house, all_cards}

        :error ->
          nil
      end
    end
  end

  defp try_flush(regular_cards, wild_cards, mods) do
    min_cards_needed = if mods.flush_needs_only_4, do: 4, else: 5

    if length(regular_cards) + length(wild_cards) < min_cards_needed do
      nil
    else
      suit_counts = count_suits(regular_cards)
      num_wilds = length(wild_cards)

      # Find suit that can reach min_cards_needed with wilds or wild_suit cards
      case find_suit_with_min_count(suit_counts, regular_cards, wild_cards, min_cards_needed) do
        {:ok, target_suit, suit_cards} ->
          # Calculate how many more cards we need
          wilds_needed = min_cards_needed - length(suit_cards)

          # Take wilds that aren't already wild_suit (those are already counted)
          available_wilds = Enum.reject(wild_cards, &(&1.wild_type == :wild_suit))
          assigned_wilds = assign_wilds_to_suit(Enum.take(available_wilds, wilds_needed), target_suit)

          {:flush, suit_cards ++ assigned_wilds}

        :error ->
          nil
      end
    end
  end

  defp try_straight(regular_cards, wild_cards, mods) do
    min_cards_needed = if mods.straight_needs_only_4, do: 4, else: 5

    if length(regular_cards) + length(wild_cards) < min_cards_needed do
      nil
    else
      case find_straight_sequence(regular_cards, wild_cards, min_cards_needed, mods) do
        {:ok, assigned_cards} -> {:straight, assigned_cards}
        :error -> nil
      end
    end
  end

  defp try_three_of_a_kind(regular_cards, wild_cards, _mods) do
    if length(regular_cards) + length(wild_cards) < 3 do
      nil
    else
      rank_counts = count_ranks(regular_cards)
      num_wilds = length(wild_cards)

      case find_rank_with_min_count(rank_counts, num_wilds, 3) do
        {:ok, target_rank} ->
          regular_in_hand = Enum.filter(regular_cards, &(&1.rank == target_rank))
          wilds_needed = 3 - length(regular_in_hand)
          assigned_wilds = assign_wilds_to_rank(Enum.take(wild_cards, wilds_needed), target_rank)
          {:three_of_a_kind, regular_in_hand ++ assigned_wilds}

        :error ->
          nil
      end
    end
  end

  defp try_two_pair(regular_cards, wild_cards, _mods) do
    if length(regular_cards) + length(wild_cards) < 4 do
      nil
    else
      rank_counts = count_ranks(regular_cards)
      num_wilds = length(wild_cards)

      case find_two_pair_ranks(rank_counts, num_wilds) do
        {:ok, {rank1, rank2}} ->
          regular_pair1 = Enum.filter(regular_cards, &(&1.rank == rank1))
          regular_pair2 = Enum.filter(regular_cards, &(&1.rank == rank2))

          wilds_for_pair1 = 2 - length(regular_pair1)
          wilds_for_pair2 = 2 - length(regular_pair2)

          assigned_wilds_pair1 =
            assign_wilds_to_rank(Enum.take(wild_cards, wilds_for_pair1), rank1)

          assigned_wilds_pair2 =
            assign_wilds_to_rank(
              Enum.slice(wild_cards, wilds_for_pair1, wilds_for_pair2),
              rank2
            )

          all_cards = regular_pair1 ++ regular_pair2 ++ assigned_wilds_pair1 ++ assigned_wilds_pair2
          {:two_pair, all_cards}

        :error ->
          nil
      end
    end
  end

  defp try_pair(regular_cards, wild_cards, _mods) do
    if length(regular_cards) + length(wild_cards) < 2 do
      nil
    else
      rank_counts = count_ranks(regular_cards)
      num_wilds = length(wild_cards)

      case find_rank_with_min_count(rank_counts, num_wilds, 2) do
        {:ok, target_rank} ->
          regular_in_hand = Enum.filter(regular_cards, &(&1.rank == target_rank))
          wilds_needed = 2 - length(regular_in_hand)
          assigned_wilds = assign_wilds_to_rank(Enum.take(wild_cards, wilds_needed), target_rank)
          {:pair, regular_in_hand ++ assigned_wilds}

        :error ->
          nil
      end
    end
  end

  defp try_high_card(regular_cards, wild_cards, _mods) do
    # High card always succeeds - use the highest card available
    all_cards = regular_cards ++ wild_cards

    highest_card =
      if length(all_cards) > 0 do
        # If we have wild cards, assign them to Ace
        case Enum.find(all_cards, &(!is_nil(&1.wild_type))) do
          nil ->
            # No wilds, just use highest regular card
            [Enum.max_by(regular_cards, & &1.rank)]

          wild ->
            # Assign wild to Ace (14)
            [assign_wild_to_rank(wild, 14)]
        end
      else
        []
      end

    {:high_card, highest_card}
  end

  # Helper functions for counting and finding patterns

  defp count_ranks(cards) do
    Enum.reduce(cards, %{}, fn card, acc ->
      Map.update(acc, card.rank, 1, &(&1 + 1))
    end)
  end

  defp count_suits(cards) do
    Enum.reduce(cards, %{}, fn card, acc ->
      Map.update(acc, card.suit, 1, &(&1 + 1))
    end)
  end

  # Finds a rank that can reach min_count with available wilds
  # Prefers higher ranks for better scoring
  defp find_rank_with_min_count(rank_counts, num_wilds, min_count) do
    rank_counts
    |> Enum.sort_by(fn {rank, _count} -> rank end, :desc)
    |> Enum.find_value(fn {rank, count} ->
      if count + num_wilds >= min_count do
        {:ok, rank}
      end
    end)
    |> case do
      nil ->
        # No existing rank, use wilds to create new rank (prefer Ace)
        if num_wilds >= min_count do
          {:ok, 14}
        else
          :error
        end

      result ->
        result
    end
  end

  # Finds two ranks that can each reach 2 cards (for two pair)
  defp find_two_pair_ranks(rank_counts, num_wilds) do
    sorted_ranks = Enum.sort_by(rank_counts, fn {rank, _count} -> rank end, :desc)

    # Try all combinations of two ranks
    for {rank1, count1} <- sorted_ranks,
        {rank2, count2} <- sorted_ranks,
        rank1 > rank2 do
      wilds_needed = max(0, 2 - count1) + max(0, 2 - count2)

      if wilds_needed <= num_wilds do
        {:ok, {rank1, rank2}}
      end
    end
    |> Enum.find(:error)
  end

  # Finds ranks for full house (3 of one, 2 of another)
  defp find_full_house_ranks(rank_counts, num_wilds) do
    sorted_ranks = Enum.sort_by(rank_counts, fn {rank, _count} -> rank end, :desc)

    # Try all combinations where we make 3 of one rank and 2 of another
    for {rank_three, count_three} <- sorted_ranks,
        {rank_two, count_two} <- sorted_ranks,
        rank_three != rank_two do
      wilds_needed = max(0, 3 - count_three) + max(0, 2 - count_two)

      if wilds_needed <= num_wilds do
        {:ok, {rank_three, rank_two}}
      end
    end
    |> Enum.find(:error)
  end

  # Finds a suit that can reach min_count considering wild_suit cards
  defp find_suit_with_min_count(suit_counts, regular_cards, wild_cards, min_count) do
    # Wild suit cards can be any suit, so they count toward any suit
    wild_suit_cards = Enum.filter(regular_cards, &(&1.wild_type == :wild_suit))
    num_wild_suits = length(wild_suit_cards)
    num_full_wilds = Enum.count(wild_cards, &(&1.wild_type in [:joker, :wild_rank]))

    # For each suit, check if we can reach min_count
    result =
      suit_counts
      |> Enum.sort_by(fn {_suit, count} -> count end, :desc)
      |> Enum.find_value(fn {suit, count} ->
        # Cards of this suit (excluding wild_suit cards)
        suit_cards = Enum.filter(regular_cards, &(&1.suit == suit && is_nil(&1.wild_type)))

        # Total cards we can get: actual suit cards + wild_suit + full wilds
        total_available = length(suit_cards) + num_wild_suits + num_full_wilds

        if total_available >= min_count do
          # Include wild_suit cards in the result
          all_suit_cards = suit_cards ++ wild_suit_cards
          {:ok, suit, all_suit_cards}
        end
      end)

    result || :error
  end

  # Finds a straight sequence with available cards and wilds
  defp find_straight_sequence(regular_cards, wild_cards, min_cards_needed, mods) do
    # Get unique ranks from regular cards
    regular_ranks = Enum.map(regular_cards, & &1.rank) |> Enum.uniq() |> Enum.sort()
    num_wilds = length(wild_cards)
    max_gap = if mods.straight_can_hop, do: 2, else: 1

    # Try to find a valid sequence
    case find_best_sequence_with_gaps(
           regular_ranks,
           num_wilds,
           min_cards_needed,
           max_gap
         ) do
      {:ok, target_ranks} ->
        # Assign cards to these ranks
        assigned_cards = assign_cards_to_ranks(regular_cards, wild_cards, target_ranks)
        {:ok, assigned_cards}

      :error ->
        :error
    end
  end

  # Finds a suited straight sequence
  defp find_suited_sequence(regular_cards, wild_cards, min_cards_needed, mods) do
    # Group regular cards by suit
    by_suit = Enum.group_by(regular_cards, & &1.suit)

    # For each suit, try to find a straight
    result =
      Enum.find_value(by_suit, fn {suit, suit_cards} ->
        ranks = Enum.map(suit_cards, & &1.rank) |> Enum.uniq() |> Enum.sort()
        num_wilds = length(wild_cards)
        max_gap = if mods.straight_flush_can_hop, do: 2, else: 1

        case find_best_sequence_with_gaps(ranks, num_wilds, min_cards_needed, max_gap) do
          {:ok, target_ranks} ->
            # Assign cards to these ranks with this suit
            assigned_cards = assign_cards_to_suited_ranks(suit_cards, wild_cards, target_ranks, suit)
            {:ok, assigned_cards}

          :error ->
            nil
        end
      end)

    result || :error
  end

  # Finds the best sequence considering gaps and wilds
  defp find_best_sequence_with_gaps(ranks, num_wilds, sequence_length, max_gap) do
    all_ranks = 2..14 |> Enum.to_list()

    # Try all possible sequences of sequence_length
    all_ranks
    |> Enum.chunk_every(sequence_length, 1, :discard)
    |> Enum.reverse()
    |> Enum.find_value(fn sequence ->
      # Check if this sequence is achievable
      if sequence_achievable?(sequence, ranks, num_wilds, max_gap) do
        {:ok, sequence}
      end
    end)
    |> case do
      nil ->
        # Also check for ace-low straight (A-2-3-4-5)
        if sequence_length == 5 do
          ace_low = [2, 3, 4, 5, 14]

          if sequence_achievable?(ace_low, ranks, num_wilds, max_gap) do
            {:ok, ace_low}
          else
            :error
          end
        else
          :error
        end

      result ->
        result
    end
  end

  # Checks if a sequence is achievable with given ranks and wilds
  defp sequence_achievable?(sequence, available_ranks, num_wilds, max_gap) do
    # Count how many ranks we need from wilds
    missing_ranks = sequence -- available_ranks
    wilds_needed = length(missing_ranks)

    # Check gap constraint
    gaps_valid? =
      if max_gap == 1 do
        # Normal straight - all cards must be present or fillable
        true
      else
        # Hopping straight - allow gaps
        # For now, we'll allow any configuration if we have enough wilds
        true
      end

    wilds_needed <= num_wilds and gaps_valid?
  end

  # Assigns cards to target ranks for a straight
  defp assign_cards_to_ranks(regular_cards, wild_cards, target_ranks) do
    # Match regular cards to target ranks
    assigned_regular =
      Enum.filter(regular_cards, fn card -> card.rank in target_ranks end)

    # Find missing ranks
    covered_ranks = Enum.map(assigned_regular, & &1.rank)
    missing_ranks = target_ranks -- covered_ranks

    # Assign wilds to missing ranks (prefer higher ranks)
    missing_ranks_sorted = Enum.sort(missing_ranks, :desc)

    assigned_wilds =
      Enum.zip(wild_cards, missing_ranks_sorted)
      |> Enum.map(fn {wild, rank} -> assign_wild_to_rank(wild, rank) end)

    assigned_regular ++ assigned_wilds
  end

  # Assigns cards to target ranks with specific suit for straight flush
  defp assign_cards_to_suited_ranks(suit_cards, wild_cards, target_ranks, suit) do
    # Match suit cards to target ranks
    assigned_suited =
      Enum.filter(suit_cards, fn card -> card.rank in target_ranks end)

    # Find missing ranks
    covered_ranks = Enum.map(assigned_suited, & &1.rank)
    missing_ranks = target_ranks -- covered_ranks

    # Assign wilds to missing ranks with specific suit
    missing_ranks_sorted = Enum.sort(missing_ranks, :desc)

    assigned_wilds =
      Enum.zip(wild_cards, missing_ranks_sorted)
      |> Enum.map(fn {wild, rank} -> assign_wild_to_rank_and_suit(wild, rank, suit) end)

    assigned_suited ++ assigned_wilds
  end

  # Assigns a list of wilds to a specific rank
  defp assign_wilds_to_rank(wilds, rank) do
    Enum.map(wilds, &assign_wild_to_rank(&1, rank))
  end

  # Assigns a list of wilds to a specific suit
  defp assign_wilds_to_suit(wilds, suit) do
    Enum.map(wilds, &assign_wild_to_suit(&1, suit))
  end

  # Assigns a single wild card to a specific rank (keeps original suit if wild_rank)
  defp assign_wild_to_rank(wild_card, rank) do
    case wild_card.wild_type do
      :joker ->
        # Joker becomes this rank with arbitrary suit (hearts)
        %{wild_card | rank: rank, suit: :hearts}

      :wild_rank ->
        # Wild rank becomes this rank but keeps its suit
        %{wild_card | rank: rank}

      :wild_suit ->
        # Wild suit keeps its rank (shouldn't be called for rank assignment)
        wild_card

      nil ->
        # Not actually a wild card
        wild_card
    end
  end

  # Assigns a single wild card to a specific suit (keeps original rank if wild_suit)
  defp assign_wild_to_suit(wild_card, suit) do
    case wild_card.wild_type do
      :joker ->
        # Joker becomes this suit with arbitrary rank (Ace)
        %{wild_card | rank: 14, suit: suit}

      :wild_suit ->
        # Wild suit becomes this suit but keeps its rank
        %{wild_card | suit: suit}

      :wild_rank ->
        # Wild rank keeps its suit (shouldn't be called for suit assignment)
        wild_card

      nil ->
        # Not actually a wild card
        wild_card
    end
  end

  # Assigns a wild card to both rank and suit
  defp assign_wild_to_rank_and_suit(wild_card, rank, suit) do
    %{wild_card | rank: rank, suit: suit}
  end
end
