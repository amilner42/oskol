import gleam/option.{type Option, None, Some}
import utils/uuid

/// Represents the suit of a playing card
pub type Suit {
  Hearts
  Diamonds
  Clubs
  Spades
}

/// Card rank - fully typed, no invalid ranks possible!
pub type Rank {
  Two
  Three
  Four
  Five
  Six
  Seven
  Eight
  Nine
  Ten
  Jack
  Queen
  King
  Ace
}

/// Card enhancement types
pub type Enhancement {
  BonusChips(Int)
  BonusMult(Int)
}

/// A playing card with UUID, rank, suit, and optional enhancement
/// ID is generated when the card is created for stable tracking across updates
pub type Card {
  Card(id: String, rank: Rank, suit: Suit, enhancement: Option(Enhancement))
}

/// Creates a simple card without enhancements
pub fn new(rank: Rank, suit: Suit) -> Card {
  Card(id: uuid.generate(), rank: rank, suit: suit, enhancement: None)
}

/// Creates a card with an enhancement
pub fn with_enhancement(rank: Rank, suit: Suit, enh: Enhancement) -> Card {
  Card(id: uuid.generate(), rank: rank, suit: suit, enhancement: Some(enh))
}

/// Returns a numeric value for rank (for comparison/sorting)
/// Also used for chip value: 2=2, 3=3, ..., Jack=11, Queen=12, King=13, Ace=14
pub fn rank_value(rank: Rank) -> Int {
  case rank {
    Two -> 2
    Three -> 3
    Four -> 4
    Five -> 5
    Six -> 6
    Seven -> 7
    Eight -> 8
    Nine -> 9
    Ten -> 10
    Jack -> 11
    Queen -> 12
    King -> 13
    Ace -> 14
  }
}

/// Returns the chip value including enhancement bonuses
/// Base chip value equals the rank value (Ace = 14)
pub fn chip_value(card: Card) -> Int {
  let base = rank_value(card.rank)
  case card.enhancement {
    Some(BonusChips(bonus)) -> base + bonus
    _ -> base
  }
}

/// Returns the multiplier bonus from enhancements
pub fn enhancement_multiplier(c: Card) -> Int {
  case c.enhancement {
    Some(BonusMult(mult)) -> mult
    _ -> 0
  }
}

/// Get the next rank (for Promote card). Circular progression: Ace wraps to Two.
pub fn next_rank(rank: Rank) -> Rank {
  case rank {
    Two -> Three
    Three -> Four
    Four -> Five
    Five -> Six
    Six -> Seven
    Seven -> Eight
    Eight -> Nine
    Nine -> Ten
    Ten -> Jack
    Jack -> Queen
    Queen -> King
    King -> Ace
    Ace -> Two
    // Circular: wraps back to Two
  }
}
