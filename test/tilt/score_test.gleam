import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import tilt/poker/card.{Card}
import tilt/poker/hand
import tilt/poker/score

fn plain(rank, suit) {
  Card(id: card.code(rank, suit), rank: rank, suit: suit, enhancement: None)
}

pub fn pair_at_level_one_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let result =
    score.calculate(
      hand.evaluate(cards),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  // base 140 chips + 5 + 5, multiplier 1
  assert result.total_chips == 150
  assert result.total_multiplier == 1
  assert result.total_score == 150
}

pub fn level_up_adds_chips_and_multiplier_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let tree = score.upgrade_skill_tree(score.new_skill_tree(), hand.Pair, 1)
  let result =
    score.calculate(
      hand.evaluate(cards),
      tree,
      [],
      score.default_card_debuffs(),
    )
  // level 2: 150 base + 10 card chips, multiplier 2
  assert result.total_chips == 160
  assert result.total_multiplier == 2
  assert result.total_score == 320
}

pub fn denied_hand_type_scores_zero_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let result =
    score.calculate(
      hand.evaluate(cards),
      score.new_skill_tree(),
      [hand.Pair],
      score.default_card_debuffs(),
    )
  assert result.total_score == 0
}

pub fn enhancements_add_to_totals_test() {
  let boosted =
    Card(
      id: "AS",
      rank: card.Ace,
      suit: card.Spades,
      enhancement: Some(card.BonusMult(3)),
    )
  let result =
    score.calculate(
      hand.evaluate([boosted]),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  // high card 125 + 14 chips, multiplier 1 + 3
  assert result.total_chips == 139
  assert result.total_multiplier == 4
}

pub fn static_field_disables_enhancements_test() {
  let boosted =
    Card(
      id: "AS",
      rank: card.Ace,
      suit: card.Spades,
      enhancement: Some(card.BonusChips(40)),
    )
  let debuffs =
    score.CardDebuffs(
      disabled_ranks: [],
      disabled_suits: [],
      enhancements_disabled: True,
    )
  let result =
    score.calculate(
      hand.evaluate([boosted]),
      score.new_skill_tree(),
      [],
      debuffs,
    )
  assert result.total_chips == 139
}

pub fn plus_bomb_disables_matching_cards_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let debuffs =
    score.CardDebuffs(
      disabled_ranks: [card.Five],
      disabled_suits: [],
      enhancements_disabled: False,
    )
  let result =
    score.calculate(hand.evaluate(cards), score.new_skill_tree(), [], debuffs)
  // pair base 140, both fives disabled
  assert result.total_chips == 140
  let _ = dict.new()
  Nil
}

// ---------- More scoring rules ----------

pub fn straight_scores_all_five_cards_test() {
  let cards = [
    plain(card.Five, card.Hearts),
    plain(card.Six, card.Clubs),
    plain(card.Seven, card.Spades),
    plain(card.Eight, card.Hearts),
    plain(card.Nine, card.Diamonds),
  ]
  let result =
    score.calculate(
      hand.evaluate(cards),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  // base 70 + (5+6+7+8+9) = 105, multiplier 4
  assert result.total_chips == 105
  assert result.total_multiplier == 4
  assert result.total_score == 420
}

pub fn face_cards_and_aces_have_the_right_chip_values_test() {
  let result = fn(rank) {
    score.calculate(
      hand.evaluate([plain(rank, card.Spades)]),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  }
  assert result(card.Jack).total_chips == 125 + 11
  assert result(card.Queen).total_chips == 125 + 12
  assert result(card.King).total_chips == 125 + 13
  assert result(card.Ace).total_chips == 125 + 14
  assert result(card.Two).total_chips == 125 + 2
}

pub fn kickers_do_not_add_chips_test() {
  let cards = [
    plain(card.Five, card.Hearts),
    plain(card.Five, card.Clubs),
    plain(card.Ace, card.Spades),
  ]
  let result =
    score.calculate(
      hand.evaluate(cards),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  assert result.total_chips == 150
  assert list.length(result.card_breakdowns) == 2
}

pub fn disabled_suit_zeroes_matching_cards_but_keeps_the_hand_type_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let debuffs =
    score.CardDebuffs(
      disabled_ranks: [],
      disabled_suits: [card.Hearts],
      enhancements_disabled: False,
    )
  let result =
    score.calculate(hand.evaluate(cards), score.new_skill_tree(), [], debuffs)
  assert result.hand_type == hand.Pair
  assert result.total_chips == 145
  let assert [hearts, clubs] = result.card_breakdowns
  assert hearts.disabled && hearts.chip_value == 0
  assert clubs.disabled == False && clubs.chip_value == 5
}

pub fn disabled_card_loses_its_enhancement_too_test() {
  let boosted =
    Card(
      id: "5H",
      rank: card.Five,
      suit: card.Hearts,
      enhancement: Some(card.BonusMult(3)),
    )
  let debuffs =
    score.CardDebuffs(
      disabled_ranks: [card.Five],
      disabled_suits: [],
      enhancements_disabled: False,
    )
  let result =
    score.calculate(
      hand.evaluate([boosted]),
      score.new_skill_tree(),
      [],
      debuffs,
    )
  assert result.total_multiplier == 1
}

pub fn chips_and_mult_enhancements_combine_test() {
  let a =
    Card(
      id: "5H",
      rank: card.Five,
      suit: card.Hearts,
      enhancement: Some(card.BonusChips(40)),
    )
  let b =
    Card(
      id: "5C",
      rank: card.Five,
      suit: card.Clubs,
      enhancement: Some(card.BonusMult(2)),
    )
  let result =
    score.calculate(
      hand.evaluate([a, b]),
      score.new_skill_tree(),
      [],
      score.default_card_debuffs(),
    )
  // 140 + 5 + 5 + 40 chips, 1 + 2 mult
  assert result.total_chips == 190
  assert result.total_multiplier == 3
  assert result.total_score == 570
}

pub fn four_of_a_kind_upgrades_by_twenty_and_two_test() {
  assert score.stats_at_level(hand.FourOfAKind, 1) == score.BaseStats(50, 12)
  assert score.stats_at_level(hand.FourOfAKind, 3) == score.BaseStats(90, 16)
  assert score.stats_at_level(hand.StraightFlush, 2) == score.BaseStats(115, 14)
  assert score.stats_at_level(hand.HighCard, 5) == score.BaseStats(165, 5)
}

pub fn denied_hand_has_no_breakdown_test() {
  let cards = [plain(card.Five, card.Hearts), plain(card.Five, card.Clubs)]
  let result =
    score.calculate(
      hand.evaluate(cards),
      score.new_skill_tree(),
      [hand.Pair, hand.Flush],
      score.default_card_debuffs(),
    )
  assert result.card_breakdowns == []
  assert result.total_multiplier == 0
  // Other hand types are unaffected
  let high =
    score.calculate(
      hand.evaluate([plain(card.Ace, card.Spades)]),
      score.new_skill_tree(),
      [hand.Pair],
      score.default_card_debuffs(),
    )
  assert high.total_score == 139
}
