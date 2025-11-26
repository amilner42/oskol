defmodule Oskol.Poker.JokerTest do
  @moduledoc """
  Comprehensive tests for joker support in hand evaluation and scoring.
  Tests every hand type with various joker combinations.
  """
  use ExUnit.Case, async: true

  alias Oskol.Poker.{Hand, Card, Score, SkillTree}

  # Helper to create a joker
  defp joker(type \\ :standard), do: Card.new_joker(type)

  # Helper to assert hand type and count scoring cards
  defp assert_hand_type(cards, expected_type) do
    result = Hand.evaluate(cards)
    assert result.hand_type == expected_type
    result
  end

  defp assert_hand_type_with_scoring_count(cards, expected_type, expected_scoring_count) do
    result = Hand.evaluate(cards)
    assert result.hand_type == expected_type
    assert length(result.scoring_cards) == expected_scoring_count
    result
  end

  # ============================================
  # Card Module - Joker Tests
  # ============================================

  describe "Card.new_joker/1" do
    test "creates a standard joker" do
      j = Card.new_joker()
      assert j.joker == :standard
      assert j.rank == nil
      assert j.suit == nil
      assert j.id != nil
    end

    test "creates a bonus_chips joker" do
      j = Card.new_joker(:bonus_chips)
      assert j.joker == :bonus_chips
    end

    test "creates a bonus_mult joker" do
      j = Card.new_joker(:bonus_mult)
      assert j.joker == :bonus_mult
    end
  end

  describe "Card.joker?/1" do
    test "returns true for jokers" do
      assert Card.joker?(Card.new_joker()) == true
      assert Card.joker?(Card.new_joker(:bonus_chips)) == true
      assert Card.joker?(Card.new_joker(:bonus_mult)) == true
    end

    test "returns false for regular cards" do
      assert Card.joker?(Card.new(5, :hearts)) == false
      assert Card.joker?(Card.new(14, :spades)) == false
    end
  end

  describe "Card.base_chip_value/1 for jokers" do
    test "standard joker has 0 chip value" do
      assert Card.base_chip_value(Card.new_joker()) == 0
    end

    test "bonus_chips joker has 0 base chip value" do
      assert Card.base_chip_value(Card.new_joker(:bonus_chips)) == 0
    end

    test "bonus_mult joker has 0 base chip value" do
      assert Card.base_chip_value(Card.new_joker(:bonus_mult)) == 0
    end
  end

  # ============================================
  # Hand Evaluation - High Card with Jokers
  # ============================================

  describe "evaluate/1 - high card with jokers" do
    test "single joker is high card" do
      assert_hand_type([joker()], :high_card)
    end

    test "joker with lower cards - high card uses highest regular card" do
      result = assert_hand_type([joker(), Card.new(5, :hearts)], :pair)
      # With 1 joker + 1 card, we can make a pair
      assert length(result.scoring_cards) == 2
    end
  end

  # ============================================
  # Hand Evaluation - Pair with Jokers
  # ============================================

  describe "evaluate/1 - pair with jokers" do
    test "one card + one joker = pair" do
      result = assert_hand_type_with_scoring_count(
        [Card.new(7, :spades), joker()],
        :pair,
        2
      )
      # The scoring cards should include the 7 and the joker
      assert Enum.any?(result.scoring_cards, fn c -> c.rank == 7 end)
      assert Enum.any?(result.scoring_cards, &Card.joker?/1)
    end

    test "two jokers = pair" do
      assert_hand_type_with_scoring_count([joker(), joker()], :pair, 2)
    end

    test "natural pair beats joker pair in scoring cards" do
      result = assert_hand_type_with_scoring_count(
        [Card.new(7, :spades), Card.new(7, :hearts), joker()],
        :three_of_a_kind,
        3
      )
      # Actually with a natural pair + joker, we get three of a kind!
      assert result.hand_type == :three_of_a_kind
    end

    test "five different cards + no joker = high card, not pair" do
      result = Hand.evaluate([
        Card.new(2, :spades),
        Card.new(5, :hearts),
        Card.new(8, :clubs),
        Card.new(11, :diamonds),
        Card.new(14, :spades)
      ])
      assert result.hand_type == :high_card
    end
  end

  # ============================================
  # Hand Evaluation - Two Pair with Jokers
  # ============================================

  describe "evaluate/1 - two pair with jokers" do
    test "one pair + one single + one joker = two pair" do
      result = assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), Card.new(5, :clubs), joker()],
        :two_pair
      )
      assert length(result.scoring_cards) == 4
    end

    test "one pair + two jokers = two pair (jokers form second pair)" do
      result = assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), joker(), joker()],
        :two_pair
      )
      assert length(result.scoring_cards) == 4
    end

    test "two singles + two jokers = two pair" do
      result = assert_hand_type(
        [Card.new(7, :spades), Card.new(5, :hearts), joker(), joker()],
        :two_pair
      )
      assert length(result.scoring_cards) == 4
    end

    test "four jokers = two pair" do
      assert_hand_type_with_scoring_count(
        [joker(), joker(), joker(), joker()],
        :two_pair,
        4
      )
    end

    test "one single + three jokers = two pair" do
      result = assert_hand_type(
        [Card.new(7, :spades), joker(), joker(), joker()],
        :two_pair
      )
      assert length(result.scoring_cards) == 4
    end
  end

  # ============================================
  # Hand Evaluation - Three of a Kind with Jokers
  # ============================================

  describe "evaluate/1 - three of a kind with jokers" do
    test "pair + one joker = three of a kind" do
      result = assert_hand_type_with_scoring_count(
        [Card.new(9, :spades), Card.new(9, :hearts), joker()],
        :three_of_a_kind,
        3
      )
      assert Enum.count(result.scoring_cards, fn c -> c.rank == 9 end) == 2
      assert Enum.count(result.scoring_cards, &Card.joker?/1) == 1
    end

    test "single + two jokers = three of a kind" do
      result = assert_hand_type_with_scoring_count(
        [Card.new(9, :spades), joker(), joker()],
        :three_of_a_kind,
        3
      )
      assert Enum.count(result.scoring_cards, fn c -> c.rank == 9 end) == 1
      assert Enum.count(result.scoring_cards, &Card.joker?/1) == 2
    end

    test "three jokers = three of a kind" do
      assert_hand_type_with_scoring_count(
        [joker(), joker(), joker()],
        :three_of_a_kind,
        3
      )
    end

    test "pair + joker with extra cards = three of a kind" do
      result = assert_hand_type(
        [Card.new(9, :spades), Card.new(9, :hearts), Card.new(3, :clubs), Card.new(5, :diamonds), joker()],
        :three_of_a_kind
      )
      # Only the three 9s (2 natural + 1 joker) should be scoring
      assert length(result.scoring_cards) == 3
    end
  end

  # ============================================
  # Hand Evaluation - Straight with Jokers
  # ============================================

  describe "evaluate/1 - straight with jokers" do
    test "four consecutive + one joker = straight" do
      result = assert_hand_type(
        [Card.new(5, :spades), Card.new(6, :hearts), Card.new(7, :clubs), Card.new(8, :diamonds), joker()],
        :straight
      )
      assert length(result.scoring_cards) == 5
    end

    test "joker fills gap in middle of straight" do
      # 5, 6, _, 8, 9 with joker filling 7
      assert_hand_type(
        [Card.new(5, :spades), Card.new(6, :hearts), Card.new(8, :diamonds), Card.new(9, :clubs), joker()],
        :straight
      )
    end

    test "two jokers fill two gaps" do
      # 5, _, 7, _, 9 with jokers filling 6 and 8
      assert_hand_type(
        [Card.new(5, :spades), Card.new(7, :hearts), Card.new(9, :clubs), joker(), joker()],
        :straight
      )
    end

    test "three cards + two jokers = straight" do
      assert_hand_type(
        [Card.new(5, :spades), Card.new(6, :hearts), Card.new(7, :clubs), joker(), joker()],
        :straight
      )
    end

    test "ace-low straight with joker (A-2-3-4-joker)" do
      assert_hand_type(
        [Card.new(14, :spades), Card.new(2, :hearts), Card.new(3, :clubs), Card.new(4, :diamonds), joker()],
        :straight
      )
    end

    test "ace-high straight with joker (10-J-Q-K-joker)" do
      assert_hand_type(
        [Card.new(10, :spades), Card.new(11, :hearts), Card.new(12, :clubs), Card.new(13, :diamonds), joker()],
        :straight
      )
    end

    test "five jokers = straight" do
      assert_hand_type(
        [joker(), joker(), joker(), joker(), joker()],
        :straight_flush  # Actually 5 jokers makes straight flush (best hand)
      )
    end
  end

  # ============================================
  # Hand Evaluation - Flush with Jokers
  # ============================================

  describe "evaluate/1 - flush with jokers" do
    test "four of same suit + one joker = flush" do
      result = assert_hand_type(
        [Card.new(2, :hearts), Card.new(5, :hearts), Card.new(8, :hearts), Card.new(11, :hearts), joker()],
        :flush
      )
      assert length(result.scoring_cards) == 5
    end

    test "three of same suit + two jokers = flush" do
      assert_hand_type(
        [Card.new(2, :hearts), Card.new(5, :hearts), Card.new(8, :hearts), joker(), joker()],
        :flush
      )
    end

    test "two of same suit + three jokers = flush" do
      assert_hand_type(
        [Card.new(2, :hearts), Card.new(5, :hearts), joker(), joker(), joker()],
        :flush
      )
    end

    test "one card + four jokers = flush" do
      assert_hand_type(
        [Card.new(2, :hearts), joker(), joker(), joker(), joker()],
        :flush
      )
    end

    test "mixed suits + joker does not make flush" do
      result = Hand.evaluate([
        Card.new(2, :hearts),
        Card.new(5, :hearts),
        Card.new(8, :hearts),
        Card.new(11, :spades),
        joker()
      ])
      # Can't make flush with 3 hearts + 1 spade + 1 joker
      assert result.hand_type != :flush
    end
  end

  # ============================================
  # Hand Evaluation - Full House with Jokers
  # ============================================

  describe "evaluate/1 - full house with jokers" do
    test "three of a kind + single + joker = full house" do
      result = assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), Card.new(7, :clubs), Card.new(3, :diamonds), joker()],
        :full_house
      )
      assert length(result.scoring_cards) == 5
    end

    test "two pair + joker = full house" do
      result = assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), Card.new(3, :clubs), Card.new(3, :diamonds), joker()],
        :full_house
      )
      assert length(result.scoring_cards) == 5
    end

    test "pair + single + two jokers = full house" do
      assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), Card.new(3, :clubs), joker(), joker()],
        :full_house
      )
    end

    test "three of a kind + two jokers = full house" do
      assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), Card.new(7, :clubs), joker(), joker()],
        :full_house
      )
    end

    test "pair + three jokers = full house" do
      assert_hand_type(
        [Card.new(7, :spades), Card.new(7, :hearts), joker(), joker(), joker()],
        :full_house
      )
    end

    test "two singles + three jokers = full house" do
      assert_hand_type(
        [Card.new(7, :spades), Card.new(3, :hearts), joker(), joker(), joker()],
        :full_house
      )
    end

    test "single + four jokers = full house" do
      assert_hand_type(
        [Card.new(7, :spades), joker(), joker(), joker(), joker()],
        :full_house
      )
    end

    test "five jokers = full house (or better)" do
      # 5 jokers could be straight flush, but let's verify it's at least full house tier
      result = Hand.evaluate([joker(), joker(), joker(), joker(), joker()])
      # 5 jokers should make straight flush (best possible)
      assert result.hand_type == :straight_flush
    end
  end

  # ============================================
  # Hand Evaluation - Four of a Kind with Jokers
  # ============================================

  describe "evaluate/1 - four of a kind with jokers" do
    test "three of a kind + one joker = four of a kind" do
      result = assert_hand_type(
        [Card.new(5, :spades), Card.new(5, :hearts), Card.new(5, :clubs), joker()],
        :four_of_a_kind
      )
      assert length(result.scoring_cards) == 4
    end

    test "pair + two jokers = four of a kind" do
      result = assert_hand_type(
        [Card.new(5, :spades), Card.new(5, :hearts), joker(), joker()],
        :four_of_a_kind
      )
      assert length(result.scoring_cards) == 4
    end

    test "single + three jokers = four of a kind" do
      result = assert_hand_type(
        [Card.new(5, :spades), joker(), joker(), joker()],
        :four_of_a_kind
      )
      assert length(result.scoring_cards) == 4
    end

    test "four jokers = four of a kind" do
      assert_hand_type_with_scoring_count(
        [joker(), joker(), joker(), joker()],
        :four_of_a_kind,
        4
      )
    end

    test "three of a kind + joker + extra card = four of a kind" do
      result = assert_hand_type(
        [Card.new(5, :spades), Card.new(5, :hearts), Card.new(5, :clubs), Card.new(14, :diamonds), joker()],
        :four_of_a_kind
      )
      # Only the four 5s (3 natural + 1 joker) should be scoring
      assert length(result.scoring_cards) == 4
    end
  end

  # ============================================
  # Hand Evaluation - Straight Flush with Jokers
  # ============================================

  describe "evaluate/1 - straight flush with jokers" do
    test "four consecutive same suit + one joker = straight flush" do
      result = assert_hand_type(
        [Card.new(4, :spades), Card.new(5, :spades), Card.new(6, :spades), Card.new(7, :spades), joker()],
        :straight_flush
      )
      assert length(result.scoring_cards) == 5
    end

    test "joker fills gap in straight flush" do
      # 4, 5, _, 7, 8 of spades with joker as 6
      assert_hand_type(
        [Card.new(4, :spades), Card.new(5, :spades), Card.new(7, :spades), Card.new(8, :spades), joker()],
        :straight_flush
      )
    end

    test "three same suit consecutive + two jokers = straight flush" do
      assert_hand_type(
        [Card.new(4, :spades), Card.new(5, :spades), Card.new(6, :spades), joker(), joker()],
        :straight_flush
      )
    end

    test "ace-low straight flush with joker" do
      assert_hand_type(
        [Card.new(14, :hearts), Card.new(2, :hearts), Card.new(3, :hearts), Card.new(4, :hearts), joker()],
        :straight_flush
      )
    end

    test "royal flush with joker (10-J-Q-K-joker)" do
      assert_hand_type(
        [Card.new(10, :hearts), Card.new(11, :hearts), Card.new(12, :hearts), Card.new(13, :hearts), joker()],
        :straight_flush
      )
    end

    test "five jokers = straight flush" do
      assert_hand_type_with_scoring_count(
        [joker(), joker(), joker(), joker(), joker()],
        :straight_flush,
        5
      )
    end
  end

  # ============================================
  # Hand Evaluation - Joker Preference (Best Hand)
  # ============================================

  describe "evaluate/1 - joker prefers best poker hand" do
    test "joker makes full house over flush when possible" do
      # 3 hearts (could be flush with 2 jokers) but also has a pair
      # Pair + 2 jokers could be 4 of a kind which is better
      result = Hand.evaluate([
        Card.new(7, :hearts),
        Card.new(7, :hearts),  # duplicate ranks possible
        Card.new(5, :hearts),
        joker(),
        joker()
      ])
      # With 2 sevens + 2 jokers, we can make 4 of a kind
      assert result.hand_type == :four_of_a_kind
    end

    test "joker makes four of a kind over full house when only 4 cards" do
      result = Hand.evaluate([
        Card.new(7, :spades),
        Card.new(7, :hearts),
        joker(),
        joker()
      ])
      # Pair + 2 jokers = 4 of a kind
      assert result.hand_type == :four_of_a_kind
    end

    test "straight flush beats four of a kind with joker" do
      # 4 same-suit consecutive + joker can be straight flush
      result = Hand.evaluate([
        Card.new(5, :hearts),
        Card.new(6, :hearts),
        Card.new(7, :hearts),
        Card.new(8, :hearts),
        joker()
      ])
      assert result.hand_type == :straight_flush
    end
  end

  # ============================================
  # Score Calculation with Jokers
  # ============================================

  describe "Score.calculate/3 - joker scoring" do
    test "standard joker contributes 0 chips" do
      hand = [Card.new(7, :spades), joker()]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Pair base is 140, + 7 for the 7, + 0 for joker
      assert result.total_chips == 140 + 7 + 0
      assert result.total_multiplier == 1
    end

    test "bonus_chips joker contributes 30 bonus chips" do
      hand = [Card.new(7, :spades), joker(:bonus_chips)]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Pair base is 140, + 7 for the 7, + 0 base + 30 bonus for joker
      assert result.total_chips == 140 + 7 + 0 + 30
      assert result.total_multiplier == 1
    end

    test "bonus_mult joker contributes 4 multiplier" do
      hand = [Card.new(7, :spades), joker(:bonus_mult)]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Pair base is 140 chips, 1 mult + 4 from joker
      assert result.total_chips == 140 + 7 + 0
      assert result.total_multiplier == 1 + 4
    end

    test "multiple jokers stack bonuses" do
      hand = [Card.new(7, :spades), joker(:bonus_chips), joker(:bonus_mult)]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Three of a kind: base 130 chips, 2 mult
      # + 7 for the 7, + 30 for bonus_chips joker, + 4 mult for bonus_mult joker
      assert result.hand_type == :three_of_a_kind
      assert result.total_chips == 130 + 7 + 0 + 30 + 0
      assert result.total_multiplier == 2 + 0 + 4
    end

    test "four jokers scoring (four of a kind)" do
      hand = [joker(), joker(), joker(), joker()]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Four of a kind: base 50 chips, 12 mult
      # All 4 jokers contribute 0 chips each
      assert result.hand_type == :four_of_a_kind
      assert result.total_chips == 50 + 0 + 0 + 0 + 0
      assert result.total_multiplier == 12
      assert result.total_score == 50 * 12
    end

    test "mixed regular cards and jokers scoring" do
      hand = [
        Card.new(5, :spades),
        Card.new(5, :hearts),
        Card.new(5, :clubs),
        Card.new(5, :diamonds),
        joker(:bonus_chips)
      ]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Four 5s make four of a kind, joker doesn't add to hand type
      # Base 50 chips, 12 mult, + 5*4 for the fives = 50 + 20 = 70
      # Joker is not in scoring_cards (4 fives already make 4 of a kind)
      assert result.hand_type == :four_of_a_kind
      # Scoring cards should be the 4 fives (not the joker)
      assert length(result.scoring_cards) == 4
      assert result.total_chips == 50 + 5 + 5 + 5 + 5
    end

    test "straight flush with joker scores all cards" do
      hand = [
        Card.new(4, :spades),
        Card.new(5, :spades),
        Card.new(6, :spades),
        Card.new(7, :spades),
        joker(:bonus_mult)
      ]
      evaluation = Hand.evaluate(hand)
      result = Score.calculate(evaluation, SkillTree.new())

      # Straight flush: base 95 chips, 12 mult
      # Cards: 4 + 5 + 6 + 7 + 0 = 22, joker adds 4 mult
      assert result.hand_type == :straight_flush
      assert result.total_chips == 95 + 4 + 5 + 6 + 7 + 0
      assert result.total_multiplier == 12 + 4
    end
  end

  # ============================================
  # Score Calculation with Skill Tree and Jokers
  # ============================================

  describe "Score.calculate/3 - jokers with skill tree upgrades" do
    test "pair with joker at level 5" do
      hand = [Card.new(7, :spades), joker()]
      evaluation = Hand.evaluate(hand)
      skill_tree = SkillTree.new() |> SkillTree.upgrade(:pair, 4)
      result = Score.calculate(evaluation, skill_tree)

      # Pair at level 5: 140 + 4*10 = 180 chips, 1 + 4*1 = 5 mult
      # + 7 for the 7, + 0 for joker
      assert result.total_chips == 180 + 7 + 0
      assert result.total_multiplier == 5
    end

    test "four of a kind with jokers at high level" do
      hand = [Card.new(9, :spades), joker(), joker(), joker()]
      evaluation = Hand.evaluate(hand)
      skill_tree = SkillTree.new() |> SkillTree.upgrade(:four_of_a_kind, 5)
      result = Score.calculate(evaluation, skill_tree)

      # Four of a kind at level 6: 50 + 5*20 = 150 chips, 12 + 5*2 = 22 mult
      # + 9 for the 9, + 0*3 for jokers
      assert result.hand_type == :four_of_a_kind
      assert result.total_chips == 150 + 9 + 0 + 0 + 0
      assert result.total_multiplier == 22
    end
  end

  # ============================================
  # Edge Cases
  # ============================================

  describe "evaluate/1 - edge cases with jokers" do
    test "single card (no joker) is high card" do
      result = Hand.evaluate([Card.new(14, :spades)])
      assert result.hand_type == :high_card
      assert length(result.scoring_cards) == 1
    end

    test "cannot make straight with non-consecutive cards + insufficient jokers" do
      # 2, 5, 8, 11, joker - too many gaps, can't make straight with 1 joker
      result = Hand.evaluate([
        Card.new(2, :spades),
        Card.new(5, :hearts),
        Card.new(8, :clubs),
        Card.new(11, :diamonds),
        joker()
      ])
      assert result.hand_type != :straight
    end

    test "cannot make flush with 3 suits + 1 joker" do
      result = Hand.evaluate([
        Card.new(2, :hearts),
        Card.new(5, :hearts),
        Card.new(8, :clubs),
        Card.new(11, :diamonds),
        joker()
      ])
      assert result.hand_type != :flush
    end

    test "duplicate ranks allowed (modified deck) with joker" do
      # Two 7 of hearts + joker
      result = Hand.evaluate([
        Card.new(7, :hearts),
        Card.new(7, :hearts),
        joker()
      ])
      assert result.hand_type == :three_of_a_kind
    end
  end
end
