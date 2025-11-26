defmodule Oskol.Poker.Hand do
  @moduledoc """
  Identifies poker hand types from cards.
  Supports jokers as wildcards that can substitute for any rank/suit.
  """

  alias Oskol.Poker.Card

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

  @type evaluation :: %{
          hand_type: hand_type(),
          played_cards: list(Card.t()),
          scoring_cards: list(Card.t())
        }

  @doc """
  Evaluates a poker hand (1-5 cards) and returns the hand type, played cards, and scoring cards.
  Scoring cards are the subset of played cards that contribute to the hand type.
  Jokers act as wildcards and can substitute for any rank/suit to make the best hand.
  """
  @spec evaluate(list(Card.t())) :: evaluation()
  def evaluate(hand) when is_list(hand) and length(hand) >= 1 and length(hand) <= 5 do
    {jokers, regular} = Enum.split_with(hand, &Card.joker?/1)
    num_jokers = length(jokers)

    {hand_type, scoring_cards} =
      check_straight_flush(regular, jokers, num_jokers) ||
        check_four_of_a_kind(regular, jokers, num_jokers) ||
        check_full_house(regular, jokers, num_jokers) ||
        check_flush(regular, jokers, num_jokers) ||
        check_straight(regular, jokers, num_jokers) ||
        check_three_of_a_kind(regular, jokers, num_jokers) ||
        check_two_pair(regular, jokers, num_jokers) ||
        check_pair(regular, jokers, num_jokers) ||
        check_high_card(regular, jokers, num_jokers)

    %{
      hand_type: hand_type,
      played_cards: hand,
      scoring_cards: scoring_cards
    }
  end

  # Private hand check functions - each returns {hand_type, scoring_cards} or nil

  defp check_straight_flush(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      # For straight flush, we need both straight and flush with jokers filling gaps
      # Group regular cards by suit
      suits = Enum.group_by(regular, & &1.suit)

      # Find if any suit can form a straight flush with joker help
      result =
        Enum.find_value(suits, fn {_suit, suited_cards} ->
          cards_needed = 5 - length(suited_cards)

          if cards_needed <= num_jokers do
            # Check if these suited cards + jokers can form a straight
            if can_make_straight_with_jokers?(suited_cards, cards_needed) do
              suited_cards ++ Enum.take(jokers, cards_needed)
            end
          end
        end)

      if result do
        {:straight_flush, result}
      end
    end
  end

  defp check_four_of_a_kind(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards >= 4 do
      counts = rank_counts(regular)
      max_count = counts |> Map.values() |> Enum.max(fn -> 0 end)

      if max_count + num_jokers >= 4 do
        # Find the rank with the most cards
        {best_rank, _} = Enum.max_by(counts, fn {_rank, count} -> count end, fn -> {nil, 0} end)

        matching_cards = Enum.filter(regular, fn card -> card.rank == best_rank end)
        jokers_needed = max(0, 4 - length(matching_cards))

        {:four_of_a_kind, matching_cards ++ Enum.take(jokers, jokers_needed)}
      end
    end
  end

  defp check_full_house(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      counts = rank_counts(regular)
      sorted_counts = counts |> Map.values() |> Enum.sort(:desc)

      # We need a 3-of-a-kind and a pair (3 + 2 = 5)
      # With jokers, check if we can reach this
      case sorted_counts do
        # Natural full house
        [3, 2] ->
          {:full_house, regular}

        # Three of a kind + single + joker -> full house
        [3, 1, 1] when num_jokers >= 1 ->
          {:full_house, regular ++ Enum.take(jokers, 1)}

        # Three of a kind + jokers to make pair
        [3, 1] when num_jokers >= 1 ->
          {:full_house, regular ++ Enum.take(jokers, 1)}

        [3] when num_jokers >= 2 ->
          {:full_house, regular ++ Enum.take(jokers, 2)}

        # Two pair + joker -> full house (joker makes one pair into three)
        [2, 2, 1] when num_jokers >= 1 ->
          {:full_house, regular ++ Enum.take(jokers, 1)}

        [2, 2] when num_jokers >= 1 ->
          {:full_house, regular ++ Enum.take(jokers, 1)}

        # Pair + singles + jokers
        [2, 1, 1] when num_jokers >= 1 ->
          # 2 + 1 joker = 3, need 2 more for pair = 1 + 1 joker (but only 1 joker left)
          # Actually: we have 4 regular cards + 1 joker = 5
          # Best: make the pair into 3, and one single stays single... that's not full house
          # OR: make one single into a pair with the remaining... no, only 1 joker
          # This can't make full house with just 1 joker
          nil

        [2, 1, 1] when num_jokers >= 2 ->
          # Pair + 2 jokers = 4 of a kind, not full house path
          # But we could: pair becomes 3 (1 joker), single becomes pair (1 joker)
          {:full_house, regular ++ Enum.take(jokers, 2)}

        [2, 1] when num_jokers >= 2 ->
          # 3 regular + 2 jokers
          # pair + joker = 3, single + joker = pair
          {:full_house, regular ++ Enum.take(jokers, 2)}

        [2] when num_jokers >= 3 ->
          # pair + 3 jokers: pair+1joker=3, 2 jokers = pair
          {:full_house, regular ++ Enum.take(jokers, 3)}

        # Singles + jokers
        [1, 1, 1] when num_jokers >= 2 ->
          # 3 singles + 2 jokers = 5 cards
          # Best: one single + 2 jokers = 3, other 2 singles = 2... but they're different ranks
          # This can't make full house
          nil

        [1, 1] when num_jokers >= 3 ->
          # 2 singles + 3 jokers
          # one single + 2 jokers = 3, other single + 1 joker = pair
          {:full_house, regular ++ Enum.take(jokers, 3)}

        [1] when num_jokers >= 4 ->
          # 1 single + 4 jokers
          # single + 2 jokers = 3, 2 jokers = pair
          {:full_house, regular ++ Enum.take(jokers, 4)}

        [] when num_jokers >= 5 ->
          # 5 jokers = full house (3 + 2 of anything)
          {:full_house, Enum.take(jokers, 5)}

        _ ->
          nil
      end
    end
  end

  defp check_flush(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      # Group by suit and find if any suit can reach 5 with jokers
      suits = Enum.group_by(regular, & &1.suit)

      result =
        Enum.find_value(suits, fn {_suit, suited_cards} ->
          cards_needed = 5 - length(suited_cards)

          if cards_needed <= num_jokers do
            suited_cards ++ Enum.take(jokers, cards_needed)
          end
        end)

      # Also check if all jokers (5 jokers = flush)
      result =
        result ||
          if length(regular) == 0 and num_jokers == 5 do
            jokers
          end

      if result do
        {:flush, result}
      end
    end
  end

  defp check_straight(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      if can_make_straight_with_jokers?(regular, num_jokers) do
        {:straight, regular ++ jokers}
      end
    end
  end

  defp check_three_of_a_kind(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards >= 3 do
      counts = rank_counts(regular)
      max_count = counts |> Map.values() |> Enum.max(fn -> 0 end)

      if max_count + num_jokers >= 3 do
        # Find the best rank to make three of a kind
        {best_rank, best_count} =
          Enum.max_by(counts, fn {_rank, count} -> count end, fn -> {nil, 0} end)

        if best_count > 0 do
          matching_cards = Enum.filter(regular, fn card -> card.rank == best_rank end)
          jokers_needed = max(0, 3 - length(matching_cards))
          {:three_of_a_kind, matching_cards ++ Enum.take(jokers, jokers_needed)}
        else
          # All jokers
          {:three_of_a_kind, Enum.take(jokers, 3)}
        end
      end
    end
  end

  defp check_two_pair(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards >= 4 do
      counts = rank_counts(regular)
      pairs = counts |> Enum.filter(fn {_rank, count} -> count >= 2 end) |> length()
      singles = counts |> Enum.filter(fn {_rank, count} -> count == 1 end)

      cond do
        # Natural two pair
        pairs >= 2 ->
          pair_cards = get_cards_by_count(regular, 2)
          {:two_pair, pair_cards}

        # One pair + joker can make second pair from a single
        pairs == 1 and length(singles) >= 1 and num_jokers >= 1 ->
          pair_cards = get_cards_by_count(regular, 2)
          # Pick highest single to pair with joker
          {best_single_rank, _} = Enum.max_by(singles, fn {rank, _} -> rank end)
          single_card = Enum.find(regular, fn c -> c.rank == best_single_rank end)
          {:two_pair, pair_cards ++ [single_card] ++ Enum.take(jokers, 1)}

        # One pair + 2 jokers (jokers form second pair)
        pairs == 1 and num_jokers >= 2 ->
          pair_cards = get_cards_by_count(regular, 2)
          {:two_pair, pair_cards ++ Enum.take(jokers, 2)}

        # No pairs, but 2+ singles and 2+ jokers
        pairs == 0 and length(singles) >= 2 and num_jokers >= 2 ->
          # Two highest singles each get a joker
          sorted_singles = Enum.sort_by(singles, fn {rank, _} -> rank end, :desc)
          [{rank1, _}, {rank2, _} | _] = sorted_singles
          card1 = Enum.find(regular, fn c -> c.rank == rank1 end)
          card2 = Enum.find(regular, fn c -> c.rank == rank2 end)
          {:two_pair, [card1, card2] ++ Enum.take(jokers, 2)}

        # One single + 3 jokers
        pairs == 0 and length(singles) >= 1 and num_jokers >= 3 ->
          {best_rank, _} = Enum.max_by(singles, fn {rank, _} -> rank end)
          single_card = Enum.find(regular, fn c -> c.rank == best_rank end)
          {:two_pair, [single_card] ++ Enum.take(jokers, 3)}

        # 4+ jokers
        num_jokers >= 4 ->
          {:two_pair, Enum.take(jokers, 4)}

        true ->
          nil
      end
    end
  end

  defp check_pair(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards >= 2 do
      counts = rank_counts(regular)
      has_pair = counts |> Map.values() |> Enum.any?(&(&1 >= 2))

      cond do
        # Natural pair
        has_pair ->
          {:pair, get_cards_by_count(regular, 2)}

        # Single + joker = pair
        length(regular) >= 1 and num_jokers >= 1 ->
          # Pick the highest card to pair with
          best_card = Enum.max_by(regular, & &1.rank)
          {:pair, [best_card] ++ Enum.take(jokers, 1)}

        # Two jokers = pair
        num_jokers >= 2 ->
          {:pair, Enum.take(jokers, 2)}

        true ->
          nil
      end
    end
  end

  defp check_high_card(regular, jokers, _num_jokers) do
    # High card always succeeds - pick highest regular card, or a joker if no regular cards
    if length(regular) > 0 do
      {:high_card, [Enum.max_by(regular, & &1.rank)]}
    else
      {:high_card, Enum.take(jokers, 1)}
    end
  end

  # Helper: Check if cards + jokers can form a straight
  defp can_make_straight_with_jokers?(cards, num_jokers) do
    if length(cards) + num_jokers < 5 do
      false
    else
      ranks = cards |> Enum.map(& &1.rank) |> Enum.uniq() |> Enum.sort()

      # Check all possible 5-card straight windows
      straight_windows = [
        [2, 3, 4, 5, 6],
        [3, 4, 5, 6, 7],
        [4, 5, 6, 7, 8],
        [5, 6, 7, 8, 9],
        [6, 7, 8, 9, 10],
        [7, 8, 9, 10, 11],
        [8, 9, 10, 11, 12],
        [9, 10, 11, 12, 13],
        [10, 11, 12, 13, 14],
        # Ace-low straight
        [2, 3, 4, 5, 14]
      ]

      Enum.any?(straight_windows, fn window ->
        # Count how many cards we have that fit this window
        matching = Enum.count(ranks, fn r -> r in window end)
        # Gaps that jokers need to fill
        gaps = 5 - matching
        gaps <= num_jokers
      end)
    end
  end

  # Private helper functions

  defp rank_counts(hand) do
    Enum.reduce(hand, %{}, fn card, acc ->
      Map.update(acc, card.rank, 1, &(&1 + 1))
    end)
  end

  defp get_cards_by_count(hand, count) do
    counts = rank_counts(hand)

    Enum.filter(hand, fn card ->
      Map.get(counts, card.rank) == count
    end)
  end

  @doc """
  Returns a human-readable name for a hand type.
  """
  @spec hand_type_name(hand_type()) :: String.t()
  def hand_type_name(:high_card), do: "High Card"
  def hand_type_name(:pair), do: "Pair"
  def hand_type_name(:two_pair), do: "Two Pair"
  def hand_type_name(:three_of_a_kind), do: "Three of a Kind"
  def hand_type_name(:straight), do: "Straight"
  def hand_type_name(:flush), do: "Flush"
  def hand_type_name(:full_house), do: "Full House"
  def hand_type_name(:four_of_a_kind), do: "Four of a Kind"
  def hand_type_name(:straight_flush), do: "Straight Flush"
end
