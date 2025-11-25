defmodule Oskol.Poker.ScoreTest do
  use ExUnit.Case, async: true

  alias Oskol.Poker.{Score, Hand, Card, SkillTree}

  defp assert_score(hand, skill_tree, expected_hand_type, expected_chips, expected_mult) do
    evaluation = Hand.evaluate(hand)
    result = Score.calculate(evaluation, skill_tree)

    assert result.hand_type == expected_hand_type
    assert result.total_chips == expected_chips
    assert result.total_multiplier == expected_mult
    assert result.total_score == expected_chips * expected_mult
  end

  describe "calculate/2 - level 1 base scores" do
    test "correctly scores high card" do
      assert_score(
        [
          Card.new(2, :spades),
          Card.new(5, :hearts),
          Card.new(9, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new(),
        :high_card,
        125 + 11,
        1
      )
    end

    test "correctly scores pair" do
      assert_score(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new(),
        :pair,
        140 + 7 + 7,
        1
      )
    end

    test "correctly scores two pair" do
      assert_score(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(3, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new(),
        :two_pair,
        105 + 7 + 7 + 3 + 3,
        2
      )
    end

    test "correctly scores three of a kind" do
      assert_score(
        [
          Card.new(9, :spades),
          Card.new(9, :hearts),
          Card.new(9, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new(),
        :three_of_a_kind,
        130 + 9 + 9 + 9,
        2
      )
    end

    test "correctly scores straight" do
      assert_score(
        [
          Card.new(5, :spades),
          Card.new(6, :hearts),
          Card.new(7, :clubs),
          Card.new(8, :diamonds),
          Card.new(9, :spades)
        ],
        SkillTree.new(),
        :straight,
        70 + 5 + 6 + 7 + 8 + 9,
        4
      )
    end

    test "correctly scores flush" do
      assert_score(
        [
          Card.new(2, :hearts),
          Card.new(5, :hearts),
          Card.new(8, :hearts),
          Card.new(11, :hearts),
          Card.new(14, :hearts)
        ],
        SkillTree.new(),
        :flush,
        70 + 2 + 5 + 8 + 10 + 11,
        4
      )
    end

    test "correctly scores full house" do
      assert_score(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(7, :clubs),
          Card.new(3, :diamonds),
          Card.new(3, :spades)
        ],
        SkillTree.new(),
        :full_house,
        70 + 7 + 7 + 7 + 3 + 3,
        5
      )
    end

    test "correctly scores four of a kind" do
      assert_score(
        [
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new(),
        :four_of_a_kind,
        50 + 5 + 5 + 5 + 5,
        12
      )
    end

    test "correctly scores five of a kind as four of a kind with all cards scoring" do
      # If we allow modifying the deck, this could happen
      assert_score(
        [
          Card.new(5, :spades),
          Card.new(5, :spades),
          Card.new(5, :hearts),
          Card.new(5, :clubs),
          Card.new(5, :diamonds)
        ],
        SkillTree.new(),
        :four_of_a_kind,
        50 + 5 + 5 + 5 + 5 + 5,
        12
      )
    end

    test "correctly scores straight flush" do
      assert_score(
        [
          Card.new(5, :diamonds),
          Card.new(6, :diamonds),
          Card.new(7, :diamonds),
          Card.new(8, :diamonds),
          Card.new(9, :diamonds)
        ],
        SkillTree.new(),
        :straight_flush,
        95 + 5 + 6 + 7 + 8 + 9,
        12
      )
    end
  end

  describe "calculate/2 - with level upgrades" do
    test "correctly scores high card at level 10" do
      assert_score(
        [
          Card.new(2, :spades),
          Card.new(5, :hearts),
          Card.new(9, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new() |> SkillTree.upgrade(:high_card, 9),
        :high_card,
        125 + 9 * 10 + 11,
        1 + 9 * 1
      )
    end

    test "correctly scores pair at level 3" do
      assert_score(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new() |> SkillTree.upgrade(:pair, 2),
        :pair,
        140 + 2 * 10 + 7 + 7,
        1 + 2 * 1
      )
    end

    test "correctly scores straight flush at level 5" do
      assert_score(
        [
          Card.new(5, :diamonds),
          Card.new(6, :diamonds),
          Card.new(7, :diamonds),
          Card.new(8, :diamonds),
          Card.new(9, :diamonds)
        ],
        SkillTree.new() |> SkillTree.upgrade(:straight_flush, 4),
        :straight_flush,
        95 + 4 * 20 + 5 + 6 + 7 + 8 + 9,
        12 + 4 * 2
      )
    end
  end

  describe "calculate/2 - mixed skill tree levels" do
    test "correctly scores ignoring upgrades from other hands" do
      assert_score(
        [
          Card.new(7, :spades),
          Card.new(7, :hearts),
          Card.new(3, :clubs),
          Card.new(11, :diamonds),
          Card.new(14, :spades)
        ],
        SkillTree.new()
        |> SkillTree.upgrade(:high_card, 2)
        |> SkillTree.upgrade(:pair, 2)
        |> SkillTree.upgrade(:two_pair, 5)
        |> SkillTree.upgrade(:flush, 5)
        |> SkillTree.upgrade(:straight_flush, 10),
        :pair,
        140 + 2 * 10 + 7 + 7,
        1 + 2 * 1
      )
    end
  end
end
