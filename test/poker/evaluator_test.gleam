//// Hand evaluation on spelled-out cards: every category, the tiebreaks
//// that matter, and the best five out of seven.

import gleam/list
import gleam/order
import gleam/string
import poker/card
import poker/evaluator.{
  Flush, FullHouse, HighCard, Pair, Quads, Straight, StraightFlush, Trips,
  TwoPair,
}

fn cards(text: String) -> List(card.Card) {
  string.split(text, " ")
  |> list.map(fn(code) {
    let assert Ok(c) = card.parse(code)
    c
  })
}

fn best(text: String) -> evaluator.Strength {
  evaluator.best(cards(text))
}

fn beats(a: String, b: String) -> Bool {
  evaluator.compare(best(a), best(b)) == order.Gt
}

fn ties(a: String, b: String) -> Bool {
  evaluator.compare(best(a), best(b)) == order.Eq
}

pub fn every_category_is_recognised_test() {
  assert best("AS KS QS JS 10S").category == StraightFlush
  assert best("9H 8H 7H 6H 5H").category == StraightFlush
  assert best("7C 7D 7H 7S 2D").category == Quads
  assert best("KC KD KH 4S 4D").category == FullHouse
  assert best("AD 9D 7D 4D 2D").category == Flush
  assert best("10C 9D 8H 7S 6D").category == Straight
  assert best("QC QD QH 8S 2D").category == Trips
  assert best("JC JD 5H 5S 2D").category == TwoPair
  assert best("9C 9D KH 5S 2D").category == Pair
  assert best("AC JD 9H 5S 2D").category == HighCard
}

pub fn the_wheel_is_a_five_high_straight_test() {
  let wheel = best("AS 2D 3C 4H 5S")
  assert wheel == evaluator.Strength(Straight, [5])
  assert beats("6S 5D 4C 3H 2S", "AS 2D 3C 4H 5S")
  assert best("AS 2S 3S 4S 5S") == evaluator.Strength(StraightFlush, [5])
}

pub fn kickers_break_ties_test() {
  assert beats("AS AD KC 5H 2S", "AH AC QC 5D 2D")
  assert beats("KS KD KC 5H 2S", "QS QD QC AH 2S")
  assert beats("JC JD 5H 5S 9D", "JS JH 4H 4S AD")
  assert beats("JC JD 5H 5S 9D", "JS JH 5C 5D 8D")
  assert beats("AD 9D 7D 4D 3D", "AH 9H 7H 4H 2H")
  assert beats("AC JD 9H 5S 2D", "AD JC 9S 4H 2S")
  assert ties("AC JD 9H 5S 2D", "AD JC 9S 5H 2S")
}

pub fn categories_rank_in_order_test() {
  let hands = [
    "AC JD 9H 5S 2D",
    "9C 9D KH 5S 2D",
    "JC JD 5H 5S 2D",
    "QC QD QH 8S 2D",
    "10C 9D 8H 7S 6D",
    "AD 9D 7D 4D 2D",
    "KC KD KH 4S 4D",
    "7C 7D 7H 7S 2D",
    "9H 8H 7H 6H 5H",
  ]
  list.window_by_2(hands)
  |> list.each(fn(pair) {
    assert beats(pair.1, pair.0)
  })
}

pub fn the_best_five_of_seven_is_found_test() {
  // A board flush beats the pocket pair; the higher hole card plays
  let a = best("AS KS 2S 5S 9S 9D 9H")
  assert a.category == Flush
  assert a.ranks == [14, 13, 9, 5, 2]
  // Trips on the board with a pocket pair make a full house
  assert best("QS QD 7C 7D 7H 2S 3S").category == FullHouse
  // Two pair on the board: the better kicker wins
  assert beats("AS 3D KC KD 8C 8H 2S", "QS 3H KC KD 8C 8H 2S")
  // Counterfeited: the board's two pair with an ace kicker plays
  assert ties("5S 3D KC KD 8C 8H AS", "4S 2H KC KD 8C 8H AD")
}

pub fn flushes_rank_by_their_highest_card_test() {
  assert beats("AD 9D 7D 4D 2D", "KH QH JH 9H 2H")
  assert beats("AD 9D 7D 4D 2D", "KS QS JS 10S 2S")
}

pub fn board_quads_go_to_the_best_kicker_test() {
  // Quads on the board: the ace kicker outkicks the king
  assert beats("9C 9D 9H 9S 5D AC 2H", "9C 9D 9H 9S 5D KC QH")
  // Neither hole card beats the board's own kicker: the board plays, a tie
  assert ties("9C 9D 9H 9S KD 4C 2H", "9C 9D 9H 9S KD 3S 2S")
}

pub fn full_houses_compare_trips_first_then_the_pair_test() {
  // Kings full of fours beats queens full of aces
  assert beats("KC KD KH 4S 4D", "QC QD QH AS AD")
  // Same trips: the pair decides
  assert beats("KC KD KH 5S 5D", "KS KH KD 4S 4D")
}

pub fn a_straight_flush_beats_quads_test() {
  assert beats("9H 8H 7H 6H 5H", "AC AD AH AS KD")
  assert best("6H 5H 4H 3H 2H AC AD").category == StraightFlush
}

pub fn seven_cards_pick_the_strongest_five_test() {
  // A six-high straight is preferred to the wheel hiding in the same seven
  assert best("AS 2D 3C 4H 5S 6D 9C") == evaluator.Strength(Straight, [6])
  // The steel wheel beats the plain seven-high straight in the same seven
  assert best("AS 2S 3S 4S 5S 6D 7D") == evaluator.Strength(StraightFlush, [5])
  // Quads are chosen over the full house the same seven could make
  assert best("AC AD AH AS KD KC KH") == evaluator.Strength(Quads, [14, 13])
}

pub fn descriptions_read_naturally_test() {
  assert evaluator.describe(best("AS KS QS JS 10S")) == "a royal flush"
  assert evaluator.describe(best("9H 8H 7H 6H 5H"))
    == "a straight flush, nine high"
  assert evaluator.describe(best("7C 7D 7H 7S 2D")) == "four of a kind, sevens"
  assert evaluator.describe(best("KC KD KH 4S 4D"))
    == "a full house, kings full of fours"
  assert evaluator.describe(best("AD 9D 7D 4D 2D")) == "a flush, ace high"
  assert evaluator.describe(best("10C 9D 8H 7S 6D")) == "a straight, ten high"
  assert evaluator.describe(best("QC QD QH 8S 2D")) == "three of a kind, queens"
  assert evaluator.describe(best("JC JD 5H 5S 2D"))
    == "two pair, jacks and fives"
  assert evaluator.describe(best("6C 6D KH 5S 2D")) == "a pair of sixes"
  assert evaluator.describe(best("AC JD 9H 5S 2D")) == "Ace high"
}
