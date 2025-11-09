defmodule Oskol.Poker.Hand do
  @moduledoc """
  Identifies poker hand types from cards.
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
  """
  @spec evaluate(list(Card.t())) :: evaluation()
  def evaluate(hand) when is_list(hand) and length(hand) >= 1 and length(hand) <= 5 do
    {hand_type, scoring_cards} =
      check_straight_flush(hand) ||
        check_four_of_a_kind(hand) ||
        check_full_house(hand) ||
        check_flush(hand) ||
        check_straight(hand) ||
        check_three_of_a_kind(hand) ||
        check_two_pair(hand) ||
        check_pair(hand) ||
        check_high_card(hand)

    %{
      hand_type: hand_type,
      played_cards: hand,
      scoring_cards: scoring_cards
    }
  end

  # Private hand check functions - each returns {hand_type, scoring_cards} or nil

  defp check_straight_flush(hand) do
    if length(hand) == 5 and is_flush?(hand) and is_straight?(hand) do
      {:straight_flush, hand}
    end
  end

  defp check_four_of_a_kind(hand) do
    if length(hand) >= 4 and has_min_count?(hand, 4) do
      {:four_of_a_kind, get_cards_by_min_count(hand, 4)}
    end
  end

  defp check_full_house(hand) do
    if length(hand) == 5 and rank_counts(hand) |> Map.values() |> Enum.sort() == [2, 3] do
      {:full_house, hand}
    end
  end

  defp check_flush(hand) do
    if is_flush?(hand) do
      {:flush, hand}
    end
  end

  defp check_straight(hand) do
    if is_straight?(hand) do
      {:straight, hand}
    end
  end

  defp check_three_of_a_kind(hand) do
    if length(hand) >= 3 and has_count?(hand, 3) do
      {:three_of_a_kind, get_cards_by_count(hand, 3)}
    end
  end

  defp check_two_pair(hand) do
    if length(hand) >= 4 and rank_counts(hand) |> Map.values() |> Enum.count(&(&1 == 2)) == 2 do
      {:two_pair, get_cards_by_count(hand, 2)}
    end
  end

  defp check_pair(hand) do
    if length(hand) >= 2 and has_count?(hand, 2) do
      {:pair, get_cards_by_count(hand, 2)}
    end
  end

  defp check_high_card(hand) do
    {:high_card, [Enum.max_by(hand, & &1.rank)]}
  end

  # Private helper functions

  defp is_flush?(hand) do
    length(hand) == 5 and
      Enum.map(hand, & &1.suit) |> Enum.uniq() |> length() == 1
  end

  defp is_straight?(hand) do
    if length(hand) != 5 do
      false
    else
      ranks = Enum.map(hand, & &1.rank) |> Enum.sort()

      # Check for regular straight
      regular_straight =
        Enum.chunk_every(ranks, 2, 1, :discard)
        |> Enum.all?(fn [a, b] -> b - a == 1 end)

      # Check for ace-low straight (A-2-3-4-5, where Ace = 14)
      ace_low_straight = ranks == [2, 3, 4, 5, 14]

      regular_straight or ace_low_straight
    end
  end

  defp has_count?(hand, count) do
    rank_counts(hand) |> Map.values() |> Enum.member?(count)
  end

  defp has_min_count?(hand, min_count) do
    rank_counts(hand) |> Map.values() |> Enum.any?(&(&1 >= min_count))
  end

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

  defp get_cards_by_min_count(hand, min_count) do
    counts = rank_counts(hand)

    Enum.filter(hand, fn card ->
      Map.get(counts, card.rank) >= min_count
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
