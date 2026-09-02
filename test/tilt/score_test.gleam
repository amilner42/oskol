import gleam/dict
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
