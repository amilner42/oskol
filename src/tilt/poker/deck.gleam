import gleam/list
import tilt/poker/card.{type Card, type Rank, type Suit}

/// All possible ranks
pub fn all_ranks() -> List(Rank) {
  [
    card.Two,
    card.Three,
    card.Four,
    card.Five,
    card.Six,
    card.Seven,
    card.Eight,
    card.Nine,
    card.Ten,
    card.Jack,
    card.Queen,
    card.King,
    card.Ace,
  ]
}

/// All possible suits
pub fn all_suits() -> List(Suit) {
  [card.Hearts, card.Diamonds, card.Clubs, card.Spades]
}

/// Creates a standard 52-card deck with deterministic ids ("AS", "10H"...).
pub fn create_standard_deck() -> List(Card) {
  list.flat_map(all_suits(), fn(suit) {
    list.map(all_ranks(), fn(rank) {
      card.new(card.code(rank, suit), rank, suit)
    })
  })
}

/// Draw N cards from the deck
pub fn draw_cards(deck: List(Card), count: Int) -> #(List(Card), List(Card)) {
  let drawn = list.take(deck, count)
  let remaining = list.drop(deck, count)
  #(drawn, remaining)
}

/// Return cards to the deck (to the bottom)
pub fn return_to_deck(deck: List(Card), cards: List(Card)) -> List(Card) {
  list.append(deck, cards)
}
