/// Shop card generation using two-level weighted randomization
/// Level 1: Sample category distribution (e.g., 5 research + 3 logistics)
/// Level 2: Generate random cards within each category with their own weights
import shop/card.{
  type ShopCard, add_card_card, all_camo_cards, bonus_chips_card, bonus_mult_card,
  increase_rank_card, plus_bomb_card, remove_card_card, scrambler_card,
  static_card, supply_chain_card,
}
import gleam/int
import gleam/io
import gleam/list
import gleam/order
import poker/hand

// LEVEL 1 DISTRIBUTIONS

/// Category distribution weights: #{first_category_count, second_category_count} => weight
/// Normal distribution centered on 4-4 (50-50 split)
/// Pattern: 1-3-5-3-1 for normal distribution
/// Used for both arsenal (research vs logistics) and actions (sabotage vs counter)
const category_distributions = [
  #(#(6, 2), 1),
  #(#(5, 3), 3),
  #(#(4, 4), 5),
  #(#(3, 5), 3),
  #(#(2, 6), 1),
]

// WEIGHTED RANDOM SAMPLING

/// Samples a single item from a weighted list
/// Each item has an associated weight (positive integer)
/// Items with higher weights are more likely to be selected
fn weighted_sample(items: List(#(a, Int))) -> a {
  // Calculate total weight
  let total_weight =
    list.fold(items, 0, fn(acc, item) {
      let #(_, weight) = item
      acc + weight
    })

  // Generate random number in range [1, total_weight]
  let random_value = int.random(total_weight) + 1

  // Find the item that corresponds to this random value
  let #(selected, _) = find_weighted_item(items, random_value, 0)
  selected
}

/// Helper to find item corresponding to random value
fn find_weighted_item(
  items: List(#(a, Int)),
  random_value: Int,
  cumulative: Int,
) -> #(a, Int) {
  case items {
    [] -> panic as "weighted_sample: empty list"
    [#(item, weight), ..rest] -> {
      let new_cumulative = cumulative + weight
      case random_value <= new_cumulative {
        True -> #(item, weight)
        False -> find_weighted_item(rest, random_value, new_cumulative)
      }
    }
  }
}

// LEVEL 2 CARD GENERATION

/// Generate N unique cards by calling constructor N times (ensures unique UUIDs)
fn repeat_unique_cards(constructor: fn() -> ShopCard, count: Int) -> List(ShopCard) {
  list.range(0, count - 1)
  |> list.map(fn(_) { constructor() })
}

/// Generate N random level up cards (equal probability for each hand type)
fn generate_random_level_ups(count: Int) -> List(ShopCard) {
  card.all_level_up_cards()
  |> list.shuffle()
  |> list.take(count)
}

/// Generate N random deck builder cards with equal probability per card type
fn generate_random_deck_builders(count: Int) -> List(ShopCard) {
  // Each card type appears 4 times for equal probability
  // Camo naturally appears 4 times (one per suit), so others need 4 copies too
  let pool =
    list.flatten([
      repeat_unique_cards(bonus_chips_card, 4),
      // Fortify x4
      repeat_unique_cards(bonus_mult_card, 4),
      // Amplify x4
      repeat_unique_cards(add_card_card, 4),
      // Supply Drop x4
      repeat_unique_cards(remove_card_card, 4),
      // Discharge x4
      repeat_unique_cards(increase_rank_card, 4),
      // Promote x4
      all_camo_cards(),
      // Camo ♥♦♣♠ (4 variants)
    ])

  pool
  |> list.shuffle()
  |> list.take(count)
}

/// Generate N random sabotage cards with equal probability per card type
fn generate_random_sabotage(count: Int) -> List(ShopCard) {
  // Each sabotage type appears 4 times for equal probability
  // IMPORTANT: Use repeat_unique_cards() to generate unique UUIDs for each card
  let pool =
    list.flatten([
      repeat_unique_cards(scrambler_card, 4),
      // The Scrambler x4
      repeat_unique_cards(plus_bomb_card, 4),
      // Plus Bomb x4
      repeat_unique_cards(static_card, 4),
      // Static Field x4
      repeat_unique_cards(supply_chain_card, 4),
      // Supply Chain x4
    ])

  pool
  |> list.shuffle()
  |> list.take(count)
}

/// Generate N random denial cards with weighted distribution
fn generate_random_denial(count: Int) -> List(ShopCard) {
  card.all_denial_cards()
  |> list.shuffle()
  |> list.take(count)
}

// MAIN GENERATION FUNCTION

/// Generate 16 shop cards: 8 arsenal + 8 action cards
/// Uses two-level randomization to match original Elixir implementation
pub fn generate_shop_cards() -> List(ShopCard) {
  // LEVEL 1: Sample arsenal distribution (how many research vs logistics)
  let #(research_count, logistics_count) =
    weighted_sample(category_distributions)

  // LEVEL 2: Generate cards within each category
  let research_cards =
    generate_random_level_ups(research_count)
    |> list.sort(compare_shop_cards)

  let logistics_cards =
    generate_random_deck_builders(logistics_count)
    |> list.sort(compare_shop_cards)

  // LEVEL 1: Sample action distribution (how many sabotage vs counter)
  let #(sabotage_count, counter_count) = weighted_sample(category_distributions)

  // LEVEL 2: Generate cards within each category
  let sabotage_cards =
    generate_random_sabotage(sabotage_count)
    |> list.sort(compare_shop_cards)

  let counter_cards =
    generate_random_denial(counter_count)
    |> list.sort(compare_shop_cards)

  // Combine in order: research, logistics, sabotage, counters (8 arsenal + 8 actions)
  let all_cards =
    list.flatten([
      research_cards,
      logistics_cards,
      sabotage_cards,
      counter_cards,
    ])

  // Debug: Print all card IDs to verify uniqueness
  io.println("🎴 Generated shop cards with IDs:")
  all_cards
  |> list.each(fn(c) {
    io.println("  " <> card.name(c) <> " → " <> card.id(c))
  })

  all_cards
}

// SORTING FUNCTIONS

/// Compare two shop cards for sorting
/// Order: Research, Logistics, Sabotage, Counter
pub fn compare_shop_cards(a: ShopCard, b: ShopCard) -> order.Order {
  let card_order = fn(c: ShopCard) -> Int {
    case c.kind {
      // Research = 0-8
      card.Research(inner) -> research_order(inner)

      // Logistics = 10-15
      card.Logistics(inner) -> 10 + logistics_order(inner)

      // Sabotage = 20-23
      card.Sabotage(inner) -> 20 + sabotage_order(inner)

      // Counter = 30-38
      card.Counter(inner) -> 30 + counter_order(inner)
    }
  }

  int.compare(card_order(a), card_order(b))
}

fn research_order(card: card.ResearchCard) -> Int {
  case card {
    card.LevelUp(hand_type) -> hand_order(hand_type)
  }
}

fn counter_order(card: card.CounterCard) -> Int {
  case card {
    card.Denial(hand_type) -> hand_order(hand_type)
  }
}

fn logistics_order(card: card.LogisticsCard) -> Int {
  case card {
    card.Fortify(_, _) -> 0
    card.Amplify(_, _) -> 1
    card.SupplyDrop(_) -> 2
    card.Discharge(_) -> 3
    card.Camo(_, _) -> 4
    card.Promote(_) -> 5
  }
}

fn sabotage_order(card: card.SabotageCard) -> Int {
  case card {
    card.Scrambler -> 0
    card.PlusBomb(_) -> 1
    card.StaticField -> 2
    card.SupplyChain -> 3
  }
}

/// Returns ordering value for hand types
fn hand_order(hand_type: hand.HandType) -> Int {
  case hand_type {
    hand.HighCard -> 0
    hand.Pair -> 1
    hand.TwoPair -> 2
    hand.ThreeOfAKind -> 3
    hand.Straight -> 4
    hand.Flush -> 5
    hand.FullHouse -> 6
    hand.FourOfAKind -> 7
    hand.StraightFlush -> 8
  }
}
