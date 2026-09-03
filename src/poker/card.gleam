//// Playing cards for poker. Ranks run 2..14 (ace high); the evaluator
//// treats the ace as low for a wheel straight.

import gamekit/rng.{type Rng}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/string

pub type Suit {
  Clubs
  Diamonds
  Hearts
  Spades
}

pub type Card {
  /// `id` is opaque: the card's position in this hand's shuffled deck.
  Card(id: String, rank: Int, suit: Suit)
}

pub const suits = [Clubs, Diamonds, Hearts, Spades]

/// A fresh shuffled deck whose ids carry the hand number.
pub fn shuffled_deck(hand_number: Int, rng: Rng) -> #(List(Card), Rng) {
  let faces =
    list.flat_map(suits, fn(suit) {
      list.map(list.range(2, 14), fn(rank) { #(rank, suit) })
    })
  let #(shuffled, rng) = rng.shuffle(rng, faces)
  let cards =
    list.index_map(shuffled, fn(face, i) {
      Card(
        id: "h" <> int.to_string(hand_number) <> "-" <> int.to_string(i + 1),
        rank: face.0,
        suit: face.1,
      )
    })
  #(cards, rng)
}

/// Short code such as "AS" or "10H".
pub fn code(card: Card) -> String {
  rank_code(card.rank) <> suit_code(card.suit)
}

pub fn rank_code(rank: Int) -> String {
  case rank {
    14 -> "A"
    13 -> "K"
    12 -> "Q"
    11 -> "J"
    n -> int.to_string(n)
  }
}

pub fn rank_name(rank: Int) -> String {
  case rank {
    14 -> "ace"
    13 -> "king"
    12 -> "queen"
    11 -> "jack"
    10 -> "ten"
    9 -> "nine"
    8 -> "eight"
    7 -> "seven"
    6 -> "six"
    5 -> "five"
    4 -> "four"
    3 -> "three"
    _ -> "two"
  }
}

pub fn plural(rank: Int) -> String {
  case rank {
    6 -> "sixes"
    n -> rank_name(n) <> "s"
  }
}

pub fn suit_code(suit: Suit) -> String {
  case suit {
    Clubs -> "C"
    Diamonds -> "D"
    Hearts -> "H"
    Spades -> "S"
  }
}

pub fn suit_name(suit: Suit) -> String {
  case suit {
    Clubs -> "clubs"
    Diamonds -> "diamonds"
    Hearts -> "hearts"
    Spades -> "spades"
  }
}

/// Parse a code such as "AS" or "10H" (tests and tooling).
pub fn parse(text: String) -> Result(Card, Nil) {
  let #(rank_text, suit_text) = case text {
    "10" <> s -> #("10", s)
    _ -> #(string.slice(text, 0, 1), string.slice(text, 1, 1))
  }
  let rank = case rank_text {
    "A" -> Ok(14)
    "K" -> Ok(13)
    "Q" -> Ok(12)
    "J" -> Ok(11)
    other -> int.parse(other)
  }
  let suit = case suit_text {
    "C" -> Ok(Clubs)
    "D" -> Ok(Diamonds)
    "H" -> Ok(Hearts)
    "S" -> Ok(Spades)
    _ -> Error(Nil)
  }
  case rank, suit {
    Ok(r), Ok(s) if r >= 2 && r <= 14 -> Ok(Card(id: text, rank: r, suit: s))
    _, _ -> Error(Nil)
  }
}

/// Token props for a face-up card.
pub fn props(card: Card) -> List(#(String, Json)) {
  [
    #("code", json.string(code(card))),
    #("rank", json.int(card.rank)),
    #("suit", json.string(suit_name(card.suit))),
  ]
}

pub fn to_json(card: Card) -> Json {
  json.object([#("id", json.string(card.id)), ..props(card)])
}
