defmodule Oskol.Poker.Hand do
  @moduledoc """
  Identifies poker hand types from cards.
  Supports jokers as wildcards that can substitute for any rank/suit.
  When jokers are used, their `acts_as` field is set to show what card they represent.
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
  When jokers are used, their `acts_as` field is set to indicate what card they represent.
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
      suits = Enum.group_by(regular, & &1.suit)

      result =
        Enum.find_value(suits, fn {suit, suited_cards} ->
          cards_needed = 5 - length(suited_cards)

          if cards_needed <= num_jokers do
            case find_straight_window(suited_cards, cards_needed) do
              nil ->
                nil

              window ->
                # Find missing ranks in the window
                present_ranks = MapSet.new(Enum.map(suited_cards, & &1.rank))
                missing_ranks = Enum.reject(window, &(&1 in present_ranks))

                # Set acts_as on jokers to fill missing ranks
                mutated_jokers =
                  jokers
                  |> Enum.take(cards_needed)
                  |> Enum.zip(missing_ranks)
                  |> Enum.map(fn {joker, rank} -> Card.set_acts_as(joker, rank, suit) end)

                suited_cards ++ mutated_jokers
            end
          end
        end)

      # Handle 5 jokers - make a royal flush
      result =
        result ||
          if length(regular) == 0 and num_jokers == 5 do
            window = [10, 11, 12, 13, 14]

            Enum.zip(jokers, window)
            |> Enum.map(fn {joker, rank} -> Card.set_acts_as(joker, rank, :spades) end)
          end

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
        {best_rank, _} = Enum.max_by(counts, fn {_rank, count} -> count end, fn -> {nil, 0} end)

        if best_rank do
          matching_cards = Enum.filter(regular, fn card -> card.rank == best_rank end)
          # Use suit of first matching card for jokers
          first_suit = hd(matching_cards).suit
          jokers_needed = max(0, 4 - length(matching_cards))

          mutated_jokers =
            jokers
            |> Enum.take(jokers_needed)
            |> Enum.map(fn joker -> Card.set_acts_as(joker, best_rank, first_suit) end)

          {:four_of_a_kind, matching_cards ++ mutated_jokers}
        else
          # All jokers - make four aces
          mutated_jokers =
            jokers
            |> Enum.take(4)
            |> Enum.zip([:spades, :hearts, :clubs, :diamonds])
            |> Enum.map(fn {joker, suit} -> Card.set_acts_as(joker, 14, suit) end)

          {:four_of_a_kind, mutated_jokers}
        end
      end
    end
  end

  defp check_full_house(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      counts = rank_counts(regular)
      sorted_counts = counts |> Map.values() |> Enum.sort(:desc)

      case sorted_counts do
        [3, 2] ->
          {:full_house, regular}

        [3, 1, 1] when num_jokers >= 1 ->
          # Joker pairs with one of the singles
          {triple_rank, _} = Enum.find(counts, fn {_r, c} -> c == 3 end)
          first_single = regular |> Enum.find(fn c -> c.rank != triple_rank end)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, first_single.rank, first_single.suit) end)

          {:full_house, regular ++ mutated_jokers}

        [3, 1] when num_jokers >= 1 ->
          single = Enum.find(regular, fn c -> rank_counts(regular)[c.rank] == 1 end)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, single.rank, single.suit) end)

          {:full_house, regular ++ mutated_jokers}

        [3] when num_jokers >= 2 ->
          {triple_rank, _} = Enum.find(counts, fn {_r, c} -> c == 3 end)
          # Pick a different rank for the pair (use Kings if triple is Aces, else Aces)
          pair_rank = if triple_rank == 14, do: 13, else: 14

          mutated_jokers =
            jokers
            |> Enum.take(2)
            |> Enum.zip([:spades, :hearts])
            |> Enum.map(fn {j, suit} -> Card.set_acts_as(j, pair_rank, suit) end)

          {:full_house, regular ++ mutated_jokers}

        [2, 2, 1] when num_jokers >= 1 ->
          # Joker makes one pair into triple
          {higher_pair_rank, _} =
            counts
            |> Enum.filter(fn {_r, c} -> c == 2 end)
            |> Enum.max_by(fn {r, _} -> r end)

          first_of_pair = Enum.find(regular, fn c -> c.rank == higher_pair_rank end)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, higher_pair_rank, first_of_pair.suit) end)

          {:full_house, regular ++ mutated_jokers}

        [2, 2] when num_jokers >= 1 ->
          {higher_pair_rank, _} =
            counts
            |> Enum.filter(fn {_r, c} -> c == 2 end)
            |> Enum.max_by(fn {r, _} -> r end)

          first_of_pair = Enum.find(regular, fn c -> c.rank == higher_pair_rank end)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, higher_pair_rank, first_of_pair.suit) end)

          {:full_house, regular ++ mutated_jokers}

        [2, 1, 1] when num_jokers >= 1 ->
          nil

        [2, 1, 1] when num_jokers >= 2 ->
          # One joker extends pair to triple, one joker pairs with a single
          {pair_rank, _} = Enum.find(counts, fn {_r, c} -> c == 2 end)
          first_of_pair = Enum.find(regular, fn c -> c.rank == pair_rank end)
          first_single = Enum.find(regular, fn c -> rank_counts(regular)[c.rank] == 1 end)

          [j1, j2 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, pair_rank, first_of_pair.suit),
            Card.set_acts_as(j2, first_single.rank, first_single.suit)
          ]

          {:full_house, regular ++ mutated_jokers}

        [2, 1] when num_jokers >= 2 ->
          {pair_rank, _} = Enum.find(counts, fn {_r, c} -> c == 2 end)
          first_of_pair = Enum.find(regular, fn c -> c.rank == pair_rank end)
          single = Enum.find(regular, fn c -> rank_counts(regular)[c.rank] == 1 end)

          [j1, j2 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, pair_rank, first_of_pair.suit),
            Card.set_acts_as(j2, single.rank, single.suit)
          ]

          {:full_house, regular ++ mutated_jokers}

        [2] when num_jokers >= 3 ->
          {pair_rank, _} = Enum.find(counts, fn {_r, c} -> c == 2 end)
          first_of_pair = Enum.find(regular, fn c -> c.rank == pair_rank end)
          other_rank = if pair_rank == 14, do: 13, else: 14

          [j1, j2, j3 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, pair_rank, first_of_pair.suit),
            Card.set_acts_as(j2, other_rank, :spades),
            Card.set_acts_as(j3, other_rank, :hearts)
          ]

          {:full_house, regular ++ mutated_jokers}

        [1, 1, 1] when num_jokers >= 2 ->
          nil

        [1, 1] when num_jokers >= 3 ->
          [c1, c2 | _] = Enum.sort_by(regular, & &1.rank, :desc)
          [j1, j2, j3 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, c1.rank, c1.suit),
            Card.set_acts_as(j2, c1.rank, c1.suit),
            Card.set_acts_as(j3, c2.rank, c2.suit)
          ]

          {:full_house, regular ++ mutated_jokers}

        [1] when num_jokers >= 4 ->
          [card] = regular
          other_rank = if card.rank == 14, do: 13, else: 14
          [j1, j2, j3, j4 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, card.rank, card.suit),
            Card.set_acts_as(j2, card.rank, card.suit),
            Card.set_acts_as(j3, other_rank, :spades),
            Card.set_acts_as(j4, other_rank, :hearts)
          ]

          {:full_house, regular ++ mutated_jokers}

        [] when num_jokers >= 5 ->
          [j1, j2, j3, j4, j5 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, 14, :spades),
            Card.set_acts_as(j2, 14, :hearts),
            Card.set_acts_as(j3, 14, :clubs),
            Card.set_acts_as(j4, 13, :spades),
            Card.set_acts_as(j5, 13, :hearts)
          ]

          {:full_house, mutated_jokers}

        _ ->
          nil
      end
    end
  end

  defp check_flush(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      suits = Enum.group_by(regular, & &1.suit)

      result =
        Enum.find_value(suits, fn {suit, suited_cards} ->
          cards_needed = 5 - length(suited_cards)

          if cards_needed <= num_jokers do
            # Use high ranks for jokers that don't conflict with existing cards
            existing_ranks = MapSet.new(Enum.map(suited_cards, & &1.rank))
            available_ranks = Enum.reject(14..2, &(&1 in existing_ranks)) |> Enum.take(cards_needed)

            mutated_jokers =
              jokers
              |> Enum.take(cards_needed)
              |> Enum.zip(available_ranks)
              |> Enum.map(fn {joker, rank} -> Card.set_acts_as(joker, rank, suit) end)

            suited_cards ++ mutated_jokers
          end
        end)

      result =
        result ||
          if length(regular) == 0 and num_jokers == 5 do
            jokers
            |> Enum.zip([14, 13, 12, 11, 10])
            |> Enum.map(fn {joker, rank} -> Card.set_acts_as(joker, rank, :spades) end)
          end

      if result do
        {:flush, result}
      end
    end
  end

  defp check_straight(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards == 5 do
      case find_straight_window(regular, num_jokers) do
        nil ->
          nil

        window ->
          present_ranks = MapSet.new(Enum.map(regular, & &1.rank))
          missing_ranks = Enum.reject(window, &(&1 in present_ranks))
          first_suit = if length(regular) > 0, do: hd(regular).suit, else: :spades

          mutated_jokers =
            jokers
            |> Enum.zip(missing_ranks)
            |> Enum.map(fn {joker, rank} -> Card.set_acts_as(joker, rank, first_suit) end)

          {:straight, regular ++ mutated_jokers}
      end
    end
  end

  defp check_three_of_a_kind(regular, jokers, num_jokers) do
    total_cards = length(regular) + num_jokers

    if total_cards >= 3 do
      counts = rank_counts(regular)
      max_count = counts |> Map.values() |> Enum.max(fn -> 0 end)

      if max_count + num_jokers >= 3 do
        {best_rank, best_count} =
          Enum.max_by(counts, fn {_rank, count} -> count end, fn -> {nil, 0} end)

        if best_count > 0 do
          matching_cards = Enum.filter(regular, fn card -> card.rank == best_rank end)
          first_suit = hd(matching_cards).suit
          jokers_needed = max(0, 3 - length(matching_cards))

          mutated_jokers =
            jokers
            |> Enum.take(jokers_needed)
            |> Enum.map(fn joker -> Card.set_acts_as(joker, best_rank, first_suit) end)

          {:three_of_a_kind, matching_cards ++ mutated_jokers}
        else
          mutated_jokers =
            jokers
            |> Enum.take(3)
            |> Enum.zip([:spades, :hearts, :clubs])
            |> Enum.map(fn {joker, suit} -> Card.set_acts_as(joker, 14, suit) end)

          {:three_of_a_kind, mutated_jokers}
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
        pairs >= 2 ->
          pair_cards = get_cards_by_count(regular, 2)
          {:two_pair, pair_cards}

        pairs == 1 and length(singles) >= 1 and num_jokers >= 1 ->
          pair_cards = get_cards_by_count(regular, 2)
          {best_single_rank, _} = Enum.max_by(singles, fn {rank, _} -> rank end)
          single_card = Enum.find(regular, fn c -> c.rank == best_single_rank end)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, best_single_rank, single_card.suit) end)

          {:two_pair, pair_cards ++ [single_card] ++ mutated_jokers}

        pairs == 1 and num_jokers >= 2 ->
          pair_cards = get_cards_by_count(regular, 2)
          {pair_rank, _} = Enum.find(counts, fn {_r, c} -> c == 2 end)
          other_rank = if pair_rank == 14, do: 13, else: 14

          mutated_jokers =
            jokers
            |> Enum.take(2)
            |> Enum.zip([:spades, :hearts])
            |> Enum.map(fn {j, suit} -> Card.set_acts_as(j, other_rank, suit) end)

          {:two_pair, pair_cards ++ mutated_jokers}

        pairs == 0 and length(singles) >= 2 and num_jokers >= 2 ->
          sorted_singles = Enum.sort_by(singles, fn {rank, _} -> rank end, :desc)
          [{rank1, _}, {rank2, _} | _] = sorted_singles
          card1 = Enum.find(regular, fn c -> c.rank == rank1 end)
          card2 = Enum.find(regular, fn c -> c.rank == rank2 end)

          [j1, j2 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, rank1, card1.suit),
            Card.set_acts_as(j2, rank2, card2.suit)
          ]

          {:two_pair, [card1, card2] ++ mutated_jokers}

        pairs == 0 and length(singles) >= 1 and num_jokers >= 3 ->
          {best_rank, _} = Enum.max_by(singles, fn {rank, _} -> rank end)
          single_card = Enum.find(regular, fn c -> c.rank == best_rank end)
          other_rank = if best_rank == 14, do: 13, else: 14

          [j1, j2, j3 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, best_rank, single_card.suit),
            Card.set_acts_as(j2, other_rank, :spades),
            Card.set_acts_as(j3, other_rank, :hearts)
          ]

          {:two_pair, [single_card] ++ mutated_jokers}

        num_jokers >= 4 ->
          [j1, j2, j3, j4 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, 14, :spades),
            Card.set_acts_as(j2, 14, :hearts),
            Card.set_acts_as(j3, 13, :spades),
            Card.set_acts_as(j4, 13, :hearts)
          ]

          {:two_pair, mutated_jokers}

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
        has_pair ->
          {:pair, get_cards_by_count(regular, 2)}

        length(regular) >= 1 and num_jokers >= 1 ->
          best_card = Enum.max_by(regular, & &1.rank)

          mutated_jokers =
            jokers
            |> Enum.take(1)
            |> Enum.map(fn j -> Card.set_acts_as(j, best_card.rank, best_card.suit) end)

          {:pair, [best_card] ++ mutated_jokers}

        num_jokers >= 2 ->
          [j1, j2 | _] = jokers

          mutated_jokers = [
            Card.set_acts_as(j1, 14, :spades),
            Card.set_acts_as(j2, 14, :hearts)
          ]

          {:pair, mutated_jokers}

        true ->
          nil
      end
    end
  end

  defp check_high_card(regular, jokers, _num_jokers) do
    if length(regular) > 0 do
      {:high_card, [Enum.max_by(regular, & &1.rank)]}
    else
      # Single joker acts as Ace of spades
      mutated_joker = Card.set_acts_as(hd(jokers), 14, :spades)
      {:high_card, [mutated_joker]}
    end
  end

  # Helper: Find a straight window that can be made with the given cards + jokers
  defp find_straight_window(cards, num_jokers) do
    if length(cards) + num_jokers < 5 do
      nil
    else
      ranks = cards |> Enum.map(& &1.rank) |> Enum.uniq() |> MapSet.new()

      straight_windows = [
        [10, 11, 12, 13, 14],
        [9, 10, 11, 12, 13],
        [8, 9, 10, 11, 12],
        [7, 8, 9, 10, 11],
        [6, 7, 8, 9, 10],
        [5, 6, 7, 8, 9],
        [4, 5, 6, 7, 8],
        [3, 4, 5, 6, 7],
        [2, 3, 4, 5, 6],
        # Ace-low straight
        [2, 3, 4, 5, 14]
      ]

      Enum.find(straight_windows, fn window ->
        matching = Enum.count(window, fn r -> r in ranks end)
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
