import gleam/list
import gleam/option.{None}
import tilt/poker/card.{type Rank, type Suit, Card}
import tilt/poker/hand

fn c(rank: Rank, suit: Suit) -> card.Card {
  Card(id: card.code(rank, suit), rank: rank, suit: suit, enhancement: None)
}

pub fn high_card_test() {
  let e = hand.evaluate([c(card.Two, card.Hearts), c(card.Nine, card.Spades)])
  assert e.hand_type == hand.HighCard
}

pub fn single_card_is_high_card_test() {
  let e = hand.evaluate([c(card.Ace, card.Hearts)])
  assert e.hand_type == hand.HighCard
  assert list.length(e.scoring_cards) == 1
}

pub fn pair_test() {
  let e =
    hand.evaluate([
      c(card.Five, card.Hearts),
      c(card.Five, card.Clubs),
      c(card.King, card.Spades),
    ])
  assert e.hand_type == hand.Pair
  assert list.length(e.scoring_cards) == 2
}

pub fn two_pair_test() {
  let e =
    hand.evaluate([
      c(card.Five, card.Hearts),
      c(card.Five, card.Clubs),
      c(card.King, card.Spades),
      c(card.King, card.Hearts),
    ])
  assert e.hand_type == hand.TwoPair
  assert list.length(e.scoring_cards) == 4
}

pub fn three_of_a_kind_test() {
  let e =
    hand.evaluate([
      c(card.Jack, card.Hearts),
      c(card.Jack, card.Clubs),
      c(card.Jack, card.Spades),
    ])
  assert e.hand_type == hand.ThreeOfAKind
}

pub fn straight_test() {
  let e =
    hand.evaluate([
      c(card.Five, card.Hearts),
      c(card.Six, card.Clubs),
      c(card.Seven, card.Spades),
      c(card.Eight, card.Hearts),
      c(card.Nine, card.Diamonds),
    ])
  assert e.hand_type == hand.Straight
  assert list.length(e.scoring_cards) == 5
}

pub fn flush_test() {
  let e =
    hand.evaluate([
      c(card.Two, card.Hearts),
      c(card.Six, card.Hearts),
      c(card.Nine, card.Hearts),
      c(card.Jack, card.Hearts),
      c(card.King, card.Hearts),
    ])
  assert e.hand_type == hand.Flush
}

pub fn full_house_test() {
  let e =
    hand.evaluate([
      c(card.Two, card.Hearts),
      c(card.Two, card.Spades),
      c(card.Nine, card.Hearts),
      c(card.Nine, card.Clubs),
      c(card.Nine, card.Diamonds),
    ])
  assert e.hand_type == hand.FullHouse
}

pub fn four_of_a_kind_test() {
  let e =
    hand.evaluate([
      c(card.Ace, card.Hearts),
      c(card.Ace, card.Spades),
      c(card.Ace, card.Clubs),
      c(card.Ace, card.Diamonds),
      c(card.Three, card.Diamonds),
    ])
  assert e.hand_type == hand.FourOfAKind
  assert list.length(e.scoring_cards) == 4
}

pub fn straight_flush_test() {
  let e =
    hand.evaluate([
      c(card.Nine, card.Spades),
      c(card.Ten, card.Spades),
      c(card.Jack, card.Spades),
      c(card.Queen, card.Spades),
      c(card.King, card.Spades),
    ])
  assert e.hand_type == hand.StraightFlush
}

pub fn four_card_run_is_not_a_straight_test() {
  let e =
    hand.evaluate([
      c(card.Five, card.Hearts),
      c(card.Six, card.Clubs),
      c(card.Seven, card.Spades),
      c(card.Eight, card.Hearts),
    ])
  assert e.hand_type == hand.HighCard
}
