//// Hand evaluation: the best five-card hand out of up to seven cards.
////
//// A `Strength` compares as a list: category first, then the ranks that
//// break ties in the order the rules weigh them (the quads rank before the
//// kicker, the higher pair before the lower, ...).

import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/string
import poker/card.{type Card}

pub type Category {
  HighCard
  Pair
  TwoPair
  Trips
  Straight
  Flush
  FullHouse
  Quads
  StraightFlush
}

pub type Strength {
  Strength(category: Category, ranks: List(Int))
}

fn category_value(c: Category) -> Int {
  case c {
    HighCard -> 0
    Pair -> 1
    TwoPair -> 2
    Trips -> 3
    Straight -> 4
    Flush -> 5
    FullHouse -> 6
    Quads -> 7
    StraightFlush -> 8
  }
}

pub fn compare(a: Strength, b: Strength) -> Order {
  case int.compare(category_value(a.category), category_value(b.category)) {
    order.Eq -> compare_ranks(a.ranks, b.ranks)
    other -> other
  }
}

fn compare_ranks(a: List(Int), b: List(Int)) -> Order {
  case a, b {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [x, ..xs], [y, ..ys] ->
      case int.compare(x, y) {
        order.Eq -> compare_ranks(xs, ys)
        other -> other
      }
  }
}

/// The best five-card hand from five to seven cards.
pub fn best(cards: List(Card)) -> Strength {
  let assert Ok(strength) =
    list.combinations(cards, 5)
    |> list.map(five)
    |> list.reduce(fn(a, b) {
      case compare(a, b) {
        order.Lt -> b
        _ -> a
      }
    })
  strength
}

/// Evaluate exactly five cards.
pub fn five(cards: List(Card)) -> Strength {
  let ranks =
    list.map(cards, fn(c) { c.rank })
    |> list.sort(fn(a, b) { int.compare(b, a) })
  let flush = case cards {
    [first, ..rest] -> list.all(rest, fn(c) { c.suit == first.suit })
    [] -> False
  }
  let straight_high = straight_high(ranks)
  // Ranks grouped by count, highest count first, then highest rank
  let groups =
    ranks
    |> list.unique
    |> list.map(fn(r) { #(list.count(ranks, fn(x) { x == r }), r) })
    |> list.sort(fn(a, b) {
      case int.compare(b.0, a.0) {
        order.Eq -> int.compare(b.1, a.1)
        other -> other
      }
    })
  let ordered = list.map(groups, fn(g) { g.1 })
  case groups, flush, straight_high {
    _, True, Ok(high) -> Strength(StraightFlush, [high])
    [#(4, _), ..], _, _ -> Strength(Quads, ordered)
    [#(3, _), #(2, _)], _, _ -> Strength(FullHouse, ordered)
    _, True, _ -> Strength(Flush, ranks)
    _, _, Ok(high) -> Strength(Straight, [high])
    [#(3, _), ..], _, _ -> Strength(Trips, ordered)
    [#(2, _), #(2, _), ..], _, _ -> Strength(TwoPair, ordered)
    [#(2, _), ..], _, _ -> Strength(Pair, ordered)
    _, _, _ -> Strength(HighCard, ranks)
  }
}

/// The top card of a straight in these (descending) ranks, if any. An ace
/// plays low in A-2-3-4-5.
fn straight_high(desc: List(Int)) -> Result(Int, Nil) {
  case desc {
    [14, 5, 4, 3, 2] -> Ok(5)
    [a, b, c, d, e] if a == b + 1 && b == c + 1 && c == d + 1 && d == e + 1 ->
      Ok(a)
    _ -> Error(Nil)
  }
}

pub fn category_name(category: Category) -> String {
  case category {
    HighCard -> "high card"
    Pair -> "a pair"
    TwoPair -> "two pair"
    Trips -> "three of a kind"
    Straight -> "a straight"
    Flush -> "a flush"
    FullHouse -> "a full house"
    Quads -> "four of a kind"
    StraightFlush -> "a straight flush"
  }
}

/// "two pair, kings and fours", "a straight, nine high".
pub fn describe(strength: Strength) -> String {
  let name = category_name(strength.category)
  case strength.category, strength.ranks {
    StraightFlush, [14] -> "a royal flush"
    StraightFlush, [high, ..] -> name <> ", " <> card.rank_name(high) <> " high"
    Straight, [high, ..] -> name <> ", " <> card.rank_name(high) <> " high"
    Flush, [high, ..] -> name <> ", " <> card.rank_name(high) <> " high"
    Quads, [r, ..] -> name <> ", " <> card.plural(r)
    FullHouse, [t, p] ->
      name <> ", " <> card.plural(t) <> " full of " <> card.plural(p)
    Trips, [r, ..] -> name <> ", " <> card.plural(r)
    TwoPair, [h, l, ..] ->
      name <> ", " <> card.plural(h) <> " and " <> card.plural(l)
    Pair, [r, ..] -> name <> " of " <> card.plural(r)
    HighCard, [r, ..] -> card.rank_name(r) |> string.capitalise <> " high"
    _, _ -> name
  }
}
