//// Shop card generation using two-level weighted randomization.
//// Level 1: sample the category split (e.g. 5 research + 3 logistics).
//// Level 2: sample cards within each category from a weighted pool.
//// All randomness comes from the game's seeded Rng.

import gamekit/rng.{type Rng}
import gleam/int
import gleam/list
import gleam/order
import tilt/poker/hand
import tilt/shop/card.{type CardKind, type ShopCard, ShopCard}

/// Category split weights: #(first_count, second_count) => weight.
/// A 1-3-5-3-1 bell curve centred on a 4-4 split.
const category_distributions = [
  #(#(6, 2), 1),
  #(#(5, 3), 3),
  #(#(4, 4), 5),
  #(#(3, 5), 3),
  #(#(2, 6), 1),
]

fn repeat(kinds: List(CardKind), times: Int) -> List(CardKind) {
  list.range(1, times) |> list.flat_map(fn(_) { kinds })
}

fn deck_builder_pool() -> List(CardKind) {
  list.flatten([
    repeat([card.fortify_kind()], 4),
    repeat([card.amplify_kind()], 4),
    repeat([card.supply_drop_kind()], 4),
    repeat([card.discharge_kind()], 4),
    repeat([card.promote_kind()], 4),
    card.camo_kinds(),
  ])
}

fn split(rng: Rng) -> #(#(Int, Int), Rng) {
  case rng.weighted(rng, category_distributions) {
    Ok(result) -> result
    Error(_) -> #(#(4, 4), rng)
  }
}

fn sample_sorted(
  rng: Rng,
  pool: List(CardKind),
  count: Int,
) -> #(List(CardKind), Rng) {
  let #(picked, rng) = rng.sample(rng, pool, count)
  #(list.sort(picked, compare_kinds), rng)
}

/// Generate 16 shop cards: 8 arsenal (research + logistics) and 8 actions
/// (sabotage + counter). Ids embed the round so they are unique per game.
pub fn generate_shop_cards(rng: Rng, round: Int) -> #(List(ShopCard), Rng) {
  let #(#(research_count, logistics_count), rng) = split(rng)
  let #(research, rng) =
    sample_sorted(rng, repeat(card.level_up_kinds(), 3), research_count)
  let #(logistics, rng) =
    sample_sorted(rng, deck_builder_pool(), logistics_count)
  let #(#(sabotage_count, counter_count), rng) = split(rng)
  let #(sabotage, rng) =
    sample_sorted(rng, repeat(card.sabotage_kinds(), 4), sabotage_count)
  let #(counters, rng) =
    sample_sorted(rng, repeat(card.denial_kinds(), 3), counter_count)

  let kinds = list.flatten([research, logistics, sabotage, counters])
  let cards =
    list.index_map(kinds, fn(kind, index) {
      ShopCard(
        id: "shop-" <> int.to_string(round) <> "-" <> int.to_string(index),
        kind: kind,
      )
    })
  #(cards, rng)
}

/// Sort order: research, logistics, sabotage, counter; hand types ascending.
pub fn compare_shop_cards(a: ShopCard, b: ShopCard) -> order.Order {
  compare_kinds(a.kind, b.kind)
}

pub fn compare_kinds(a: CardKind, b: CardKind) -> order.Order {
  int.compare(kind_order(a), kind_order(b))
}

fn kind_order(kind: CardKind) -> Int {
  case kind {
    card.Research(card.LevelUp(ht)) -> hand_order(ht)
    card.Logistics(l) -> 10 + logistics_order(l)
    card.Sabotage(s) -> 20 + sabotage_order(s)
    card.Counter(card.Denial(ht)) -> 30 + hand_order(ht)
  }
}

fn logistics_order(l: card.LogisticsCard) -> Int {
  case l {
    card.Fortify(_, _) -> 0
    card.Amplify(_, _) -> 1
    card.SupplyDrop(_) -> 2
    card.Discharge(_) -> 3
    card.Camo(_, _) -> 4
    card.Promote(_) -> 5
  }
}

fn sabotage_order(s: card.SabotageCard) -> Int {
  case s {
    card.Scrambler -> 0
    card.PlusBomb(_) -> 1
    card.StaticField -> 2
    card.SupplyChain -> 3
  }
}

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
