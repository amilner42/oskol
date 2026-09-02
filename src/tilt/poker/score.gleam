import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import tilt/poker/card.{type Card, type Rank, type Suit}
import tilt/poker/hand.{type Evaluation, type HandType}

/// Base stats for a hand type
pub type BaseStats {
  BaseStats(chips: Int, multiplier: Int)
}

/// Skill tree - maps hand types to their levels
pub type SkillTree =
  Dict(HandType, Int)

/// Card debuffs that can disable cards or enhancements
pub type CardDebuffs {
  CardDebuffs(
    disabled_ranks: List(Rank),
    disabled_suits: List(Suit),
    enhancements_disabled: Bool,
  )
}

/// Per-card breakdown for scoring
pub type CardBreakdown {
  CardBreakdown(
    card: Card,
    chip_value: Int,
    bonus_chips: Int,
    bonus_mult: Int,
    disabled: Bool,
  )
}

// NOTE: We also have view.CardBreakdown which is identical in structure
// This allows poker/score to be independent of game/view

/// Complete scoring result
pub type ScoreResult {
  ScoreResult(
    hand_type: HandType,
    base_chips: Int,
    base_multiplier: Int,
    card_breakdowns: List(CardBreakdown),
    total_chips: Int,
    total_multiplier: Int,
    total_score: Int,
  )
}

/// Base hand scores (level 1)
fn base_hand_scores() -> Dict(HandType, BaseStats) {
  dict.from_list([
    #(hand.HighCard, BaseStats(125, 1)),
    #(hand.Pair, BaseStats(140, 1)),
    #(hand.TwoPair, BaseStats(105, 2)),
    #(hand.ThreeOfAKind, BaseStats(130, 2)),
    #(hand.Straight, BaseStats(70, 4)),
    #(hand.Flush, BaseStats(70, 4)),
    #(hand.FullHouse, BaseStats(70, 5)),
    #(hand.FourOfAKind, BaseStats(50, 12)),
    #(hand.StraightFlush, BaseStats(95, 12)),
  ])
}

/// Upgrade bonuses per level
fn upgrade_bonuses() -> Dict(HandType, BaseStats) {
  dict.from_list([
    #(hand.HighCard, BaseStats(10, 1)),
    #(hand.Pair, BaseStats(10, 1)),
    #(hand.TwoPair, BaseStats(10, 1)),
    #(hand.ThreeOfAKind, BaseStats(10, 1)),
    #(hand.Straight, BaseStats(10, 1)),
    #(hand.Flush, BaseStats(10, 1)),
    #(hand.FullHouse, BaseStats(10, 1)),
    #(hand.FourOfAKind, BaseStats(20, 2)),
    #(hand.StraightFlush, BaseStats(20, 2)),
  ])
}

/// Returns empty card debuffs
pub fn default_card_debuffs() -> CardDebuffs {
  CardDebuffs(
    disabled_ranks: [],
    disabled_suits: [],
    enhancements_disabled: False,
  )
}

/// Creates a new skill tree with all hands at level 1
pub fn new_skill_tree() -> SkillTree {
  dict.from_list([
    #(hand.HighCard, 1),
    #(hand.Pair, 1),
    #(hand.TwoPair, 1),
    #(hand.ThreeOfAKind, 1),
    #(hand.Straight, 1),
    #(hand.Flush, 1),
    #(hand.FullHouse, 1),
    #(hand.FourOfAKind, 1),
    #(hand.StraightFlush, 1),
  ])
}

/// Upgrades a hand type in the skill tree
pub fn upgrade_skill_tree(
  skill_tree: SkillTree,
  hand_type: HandType,
  levels: Int,
) -> SkillTree {
  dict.upsert(skill_tree, hand_type, fn(existing) {
    case existing {
      option.Some(current_level) -> current_level + levels
      option.None -> 1 + levels
    }
  })
}

/// Calculates stats at a specific level (for preview/shop)
pub fn stats_at_level(hand_type: HandType, level: Int) -> BaseStats {
  let base = case dict.get(base_hand_scores(), hand_type) {
    Ok(stats) -> stats
    Error(_) -> BaseStats(0, 0)
  }

  let upgrade = case dict.get(upgrade_bonuses(), hand_type) {
    Ok(stats) -> stats
    Error(_) -> BaseStats(0, 0)
  }

  let bonus_multiplier = int.max(0, level - 1)

  BaseStats(
    chips: base.chips + bonus_multiplier * upgrade.chips,
    multiplier: base.multiplier + bonus_multiplier * upgrade.multiplier,
  )
}

/// Main scoring function - calculates score with skill tree and debuffs
pub fn calculate(
  evaluation: Evaluation,
  skill_tree: SkillTree,
  active_debuffs: List(HandType),
  card_debuffs: CardDebuffs,
) -> ScoreResult {
  let hand.Evaluation(hand_type, _played_cards, scoring_cards) = evaluation

  // Check if hand type is denied (debuffed)
  case list.contains(active_debuffs, hand_type) {
    True ->
      ScoreResult(
        hand_type: hand_type,
        base_chips: 0,
        base_multiplier: 0,
        card_breakdowns: [],
        total_chips: 0,
        total_multiplier: 0,
        total_score: 0,
      )
    False -> {
      // Get level for this hand type
      let level = case dict.get(skill_tree, hand_type) {
        Ok(l) -> l
        Error(_) -> 1
      }

      // Calculate base stats with level bonuses
      let stats = stats_at_level(hand_type, level)

      // Build per-card breakdowns
      let card_breakdowns =
        list.map(scoring_cards, fn(c) { build_card_breakdown(c, card_debuffs) })

      // Calculate totals
      let card_value_sum =
        list.fold(card_breakdowns, 0, fn(sum, breakdown) {
          sum + breakdown.chip_value + breakdown.bonus_chips
        })

      let enhancement_multiplier =
        list.fold(card_breakdowns, 0, fn(sum, breakdown) {
          sum + breakdown.bonus_mult
        })

      let total_chips = stats.chips + card_value_sum
      let total_multiplier = stats.multiplier + enhancement_multiplier
      let total_score = total_chips * total_multiplier

      ScoreResult(
        hand_type: hand_type,
        base_chips: stats.chips,
        base_multiplier: stats.multiplier,
        card_breakdowns: card_breakdowns,
        total_chips: total_chips,
        total_multiplier: total_multiplier,
        total_score: total_score,
      )
    }
  }
}

// Helper: builds card breakdown considering debuffs
fn build_card_breakdown(c: Card, debuffs: CardDebuffs) -> CardBreakdown {
  let card_disabled =
    list.contains(debuffs.disabled_ranks, c.rank)
    || list.contains(debuffs.disabled_suits, c.suit)

  case card_disabled {
    True ->
      CardBreakdown(
        card: c,
        chip_value: 0,
        bonus_chips: 0,
        bonus_mult: 0,
        disabled: True,
      )
    False -> {
      let base_value = card.rank_value(c.rank)

      // Check enhancements
      let #(bonus_chips, bonus_mult) = case debuffs.enhancements_disabled {
        True -> #(0, 0)
        False ->
          case c.enhancement {
            option.Some(card.BonusChips(chips)) -> #(chips, 0)
            option.Some(card.BonusMult(mult)) -> #(0, mult)
            option.None -> #(0, 0)
          }
      }

      CardBreakdown(
        card: c,
        chip_value: base_value,
        bonus_chips: bonus_chips,
        bonus_mult: bonus_mult,
        disabled: False,
      )
    }
  }
}
