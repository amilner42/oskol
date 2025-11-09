defmodule Oskol.Poker.HandTest do
  use ExUnit.Case, async: true

  alias Oskol.Poker.{Hand, Card}

  defp assert_correct_hand(cards, expected_hand_type) do
    assert_correct_hand(cards, expected_hand_type, cards)
  end

  defp assert_correct_hand(cards, expected_hand_type, expected_scoring_cards) do
    shuffled_hand = Enum.shuffle(cards)
    result = Hand.evaluate(shuffled_hand)

    assert result.hand_type == expected_hand_type
    assert_same_cards(result.played_cards, shuffled_hand)
    assert_same_cards(result.scoring_cards, expected_scoring_cards)
  end

  defp assert_same_cards(actual, expected) do
    sorted_actual = Enum.sort_by(actual, &{&1.rank, &1.suit})
    sorted_expected = Enum.sort_by(expected, &{&1.rank, &1.suit})
    assert sorted_actual == sorted_expected
  end

  describe "evaluate/1 - high card" do
    test "from 1 card" do
      assert_correct_hand([Card.new(14, :spades)], :high_card)
    end

    test "from 5 cards" do
      assert_correct_hand(
        [
          Card.new(2, :spades),
          Card.new(5, :hearts),
          Card.new(9, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        :high_card,
        [Card.new(14, :spades)]
      )
    end
  end

  describe "evaluate/1 - pair" do
    test "from 2 cards" do
      assert_correct_hand(
        [Card.new(7, :spades), Card.new(7, :hearts)],
        :pair
      )
    end

    test "from 5 cards" do
      assert_correct_hand(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        :pair,
        [Card.new(7, :spades), Card.new(7, :hearts)]
      )
    end
  end

  describe "evaluate/1 - two pair" do
    test "from 4 cards" do
      assert_correct_hand(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(3, :diamonds)
        ],
        :two_pair
      )
    end

    test "from 5 cards" do
      assert_correct_hand(
        [
          Card.new(14, :spades),
          Card.new(14, :hearts),
          Card.new(9, :clubs),
          Card.new(9, :diamonds),
          Card.new(2, :spades)
        ],
        :two_pair,
        [
          Card.new(14, :spades),
          Card.new(14, :hearts),
          Card.new(9, :clubs),
          Card.new(9, :diamonds)
        ]
      )
    end
  end

  describe "evaluate/1 - three of a kind" do
    test "from 3 cards" do
      assert_correct_hand(
        [Card.new(9, :spades), Card.new(9, :hearts), Card.new(9, :clubs)],
        :three_of_a_kind
      )
    end

    test "from 5 cards" do
      assert_correct_hand(
        [
          Card.new(9, :spades),
          Card.new(9, :hearts),
          Card.new(9, :clubs),
          Card.new(5, :diamonds),
          Card.new(2, :spades)
        ],
        :three_of_a_kind,
        [
          Card.new(9, :spades),
          Card.new(9, :hearts),
          Card.new(9, :clubs)
        ]
      )
    end
  end

  describe "evaluate/1 - straight" do
    test "detects straight" do
      assert_correct_hand(
        [
          Card.new(5, :spades),
          Card.new(6, :hearts),
          Card.new(7, :clubs),
          Card.new(8, :diamonds),
          Card.new(9, :spades)
        ],
        :straight
      )
    end

    test "detects ace-low straight (A-2-3-4-5)" do
      assert_correct_hand(
        [
          Card.new(14, :spades),
          Card.new(2, :hearts),
          Card.new(3, :clubs),
          Card.new(4, :diamonds),
          Card.new(5, :spades)
        ],
        :straight
      )
    end

    test "detects ace-high straight (10-J-Q-K-A)" do
      assert_correct_hand(
        [
          Card.new(10, :spades),
          Card.new(11, :hearts),
          Card.new(12, :clubs),
          Card.new(13, :diamonds),
          Card.new(14, :spades)
        ],
        :straight
      )
    end

    test "does not detect straight when ace is in the middle (K-A-2-3-4)" do
      hand = [
        Card.new(13, :spades),
        Card.new(14, :spades),
        Card.new(2, :hearts),
        Card.new(3, :clubs),
        Card.new(4, :diamonds)
      ]

      result = Hand.evaluate(hand)

      assert result.hand_type != :straight
    end
  end

  describe "evaluate/1 - flush" do
    test "detects flush with any suit" do
      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        assert_correct_hand(
          [
            Card.new(2, suit),
            Card.new(5, suit),
            Card.new(8, suit),
            Card.new(11, suit),
            Card.new(14, suit)
          ],
          :flush
        )
      end
    end

    test "does not detect flush with 4 cards of suit and 1 card with different suit" do
      hand = [
        Card.new(2, :hearts),
        Card.new(5, :hearts),
        Card.new(8, :hearts),
        Card.new(11, :hearts),
        Card.new(14, :spades)
      ]

      result = Hand.evaluate(hand)

      assert result.hand_type != :flush
    end

    test "detects flush and not 2 pair" do
      # If we allow modifying the deck, this could happen
      assert_correct_hand(
        [
          Card.new(2, :hearts),
          Card.new(2, :hearts),
          Card.new(8, :hearts),
          Card.new(8, :hearts),
          Card.new(10, :hearts)
        ],
        :flush
      )
    end

    test "detects flush and not three of a kind" do
      # If we allow modifying the deck, this could happen
      assert_correct_hand(
        [
          Card.new(2, :hearts),
          Card.new(2, :hearts),
          Card.new(2, :hearts),
          Card.new(8, :hearts),
          Card.new(10, :hearts)
        ],
        :flush
      )
    end
  end

  describe "evaluate/1 - full house" do
    test "detects full house" do
      assert_correct_hand(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(7, :clubs),
          Card.new(3, :diamonds),
          Card.new(3, :spades)
        ],
        :full_house
      )
    end

    test "does not detect full house with only three of a kind and no pair" do
      hand = [
        Card.new(7, :spades),
        Card.new(7, :hearts),
        Card.new(7, :clubs),
        Card.new(3, :diamonds)
      ]

      result = Hand.evaluate(hand)

      assert result.hand_type != :full_house
    end
  end

  describe "evaluate/1 - four of a kind" do
    test "from 4 cards" do
      assert_correct_hand(
        [
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds)
        ],
        :four_of_a_kind
      )
    end

    test "from 5 cards" do
      assert_correct_hand(
        [
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds),
          Card.new(14, :spades)
        ],
        :four_of_a_kind,
        [
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds)
        ]
      )
    end

    test "detects a 4 of a kind from a 5 of a kind, and scores all cards" do
      # If we allow modifying the deck, this could happen
      assert_correct_hand(
        [
          Card.new(5, :spades),
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds)
        ],
        :four_of_a_kind
      )
    end
  end

  describe "evaluate/1 - straight flush" do
    test "detects straight flush" do
      assert_correct_hand(
        [
          Card.new(4, :spades),
          Card.new(5, :spades),
          Card.new(6, :spades),
          Card.new(7, :spades),
          Card.new(8, :spades)
        ],
        :straight_flush
      )
    end

    test "detects ace-low straight flush (A-2-3-4-5)" do
      assert_correct_hand(
        [
          Card.new(14, :hearts),
          Card.new(2, :hearts),
          Card.new(3, :hearts),
          Card.new(4, :hearts),
          Card.new(5, :hearts)
        ],
        :straight_flush
      )
    end

    test "detects ace-high straight flush (10-J-Q-K-A)" do
      assert_correct_hand(
        [
          Card.new(10, :hearts),
          Card.new(11, :hearts),
          Card.new(12, :hearts),
          Card.new(13, :hearts),
          Card.new(14, :hearts)
        ],
        :straight_flush
      )
    end

    test "does not detect straight flush when ace is in the middle (K-A-2-3-4) " do
      hand = [
        Card.new(13, :spades),
        Card.new(14, :spades),
        Card.new(2, :spades),
        Card.new(3, :spades),
        Card.new(4, :spades)
      ]

      result = Hand.evaluate(hand)

      assert result.hand_type != :straight_flush
    end
  end

  describe "hand_type_name/1" do
    test "returns correct names for all hand types" do
      assert Hand.hand_type_name(:high_card) == "High Card"
      assert Hand.hand_type_name(:pair) == "Pair"
      assert Hand.hand_type_name(:two_pair) == "Two Pair"
      assert Hand.hand_type_name(:three_of_a_kind) == "Three of a Kind"
      assert Hand.hand_type_name(:straight) == "Straight"
      assert Hand.hand_type_name(:flush) == "Flush"
      assert Hand.hand_type_name(:full_house) == "Full House"
      assert Hand.hand_type_name(:four_of_a_kind) == "Four of a Kind"
      assert Hand.hand_type_name(:straight_flush) == "Straight Flush"
    end
  end
end
