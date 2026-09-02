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

// ---------- Edge cases ----------

pub fn ace_low_straight_test() {
  let e =
    hand.evaluate([
      c(card.Ace, card.Hearts),
      c(card.Two, card.Clubs),
      c(card.Three, card.Spades),
      c(card.Four, card.Hearts),
      c(card.Five, card.Diamonds),
    ])
  assert e.hand_type == hand.Straight
}

pub fn ace_high_straight_test() {
  let e =
    hand.evaluate([
      c(card.Ten, card.Hearts),
      c(card.Jack, card.Clubs),
      c(card.Queen, card.Spades),
      c(card.King, card.Hearts),
      c(card.Ace, card.Diamonds),
    ])
  assert e.hand_type == hand.Straight
}

pub fn ace_low_straight_flush_test() {
  let e =
    hand.evaluate([
      c(card.Ace, card.Clubs),
      c(card.Two, card.Clubs),
      c(card.Three, card.Clubs),
      c(card.Four, card.Clubs),
      c(card.Five, card.Clubs),
    ])
  assert e.hand_type == hand.StraightFlush
}

pub fn wraparound_is_not_a_straight_test() {
  let e =
    hand.evaluate([
      c(card.Queen, card.Hearts),
      c(card.King, card.Clubs),
      c(card.Ace, card.Spades),
      c(card.Two, card.Hearts),
      c(card.Three, card.Diamonds),
    ])
  assert e.hand_type == hand.HighCard
}

pub fn four_card_flush_is_not_a_flush_test() {
  let e =
    hand.evaluate([
      c(card.Two, card.Hearts),
      c(card.Six, card.Hearts),
      c(card.Nine, card.Hearts),
      c(card.Jack, card.Hearts),
    ])
  assert e.hand_type == hand.HighCard
  assert list.map(e.scoring_cards, fn(x) { x.rank }) == [card.Jack]
}

pub fn only_the_pair_scores_in_a_five_card_pair_test() {
  let e =
    hand.evaluate([
      c(card.Nine, card.Hearts),
      c(card.Nine, card.Clubs),
      c(card.Two, card.Spades),
      c(card.Five, card.Hearts),
      c(card.King, card.Diamonds),
    ])
  assert e.hand_type == hand.Pair
  assert list.map(e.scoring_cards, fn(x) { x.rank }) == [card.Nine, card.Nine]
}

pub fn two_pair_ignores_the_kicker_test() {
  let e =
    hand.evaluate([
      c(card.Nine, card.Hearts),
      c(card.Nine, card.Clubs),
      c(card.Two, card.Spades),
      c(card.Two, card.Hearts),
      c(card.King, card.Diamonds),
    ])
  assert e.hand_type == hand.TwoPair
  assert list.length(e.scoring_cards) == 4
}

pub fn four_of_a_kind_ignores_the_kicker_test() {
  let e =
    hand.evaluate([
      c(card.Seven, card.Hearts),
      c(card.Seven, card.Clubs),
      c(card.Seven, card.Spades),
      c(card.Seven, card.Diamonds),
      c(card.King, card.Diamonds),
    ])
  assert e.hand_type == hand.FourOfAKind
  assert list.map(e.scoring_cards, fn(x) { x.rank })
    == [card.Seven, card.Seven, card.Seven, card.Seven]
}

pub fn three_of_a_kind_with_kickers_test() {
  let e =
    hand.evaluate([
      c(card.Four, card.Hearts),
      c(card.Four, card.Clubs),
      c(card.Four, card.Spades),
      c(card.Nine, card.Diamonds),
      c(card.King, card.Diamonds),
    ])
  assert e.hand_type == hand.ThreeOfAKind
  assert list.length(e.scoring_cards) == 3
}

pub fn full_house_beats_three_of_a_kind_and_flush_test() {
  // 3 + 2 in one suit would be impossible; check ranking order via a full house
  let e =
    hand.evaluate([
      c(card.Four, card.Hearts),
      c(card.Four, card.Clubs),
      c(card.Four, card.Spades),
      c(card.Nine, card.Diamonds),
      c(card.Nine, card.Hearts),
    ])
  assert e.hand_type == hand.FullHouse
  assert list.length(e.scoring_cards) == 5
}

pub fn straight_with_mixed_suits_is_not_a_flush_test() {
  let e =
    hand.evaluate([
      c(card.Six, card.Hearts),
      c(card.Seven, card.Hearts),
      c(card.Eight, card.Hearts),
      c(card.Nine, card.Hearts),
      c(card.Ten, card.Clubs),
    ])
  assert e.hand_type == hand.Straight
}

pub fn high_card_scores_only_the_highest_test() {
  let e =
    hand.evaluate([
      c(card.Two, card.Hearts),
      c(card.Ace, card.Clubs),
      c(card.Nine, card.Spades),
    ])
  assert list.map(e.scoring_cards, fn(x) { x.rank }) == [card.Ace]
}

pub fn evaluation_ignores_card_order_test() {
  let a =
    hand.evaluate([
      c(card.Five, card.Hearts),
      c(card.Five, card.Clubs),
      c(card.King, card.Spades),
    ])
  let b =
    hand.evaluate([
      c(card.King, card.Spades),
      c(card.Five, card.Clubs),
      c(card.Five, card.Hearts),
    ])
  assert a.hand_type == b.hand_type
  assert list.length(a.scoring_cards) == list.length(b.scoring_cards)
}
