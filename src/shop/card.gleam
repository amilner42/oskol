import poker/card.{type Suit}
import poker/hand.{type HandType}
import utils/uuid

/// Research cards (level up hand types)
pub type ResearchCard {
  LevelUp(hand_type: HandType)
}

/// Counter cards (block opponent's hand types)
pub type CounterCard {
  Denial(hand_type: HandType)
}

/// Logistics cards (deck building)
pub type LogisticsCard {
  Fortify(amount: Int, max_cards: Int)  // Add bonus chips to cards
  Amplify(amount: Int, max_cards: Int)  // Add bonus mult to cards
  SupplyDrop(max_cards: Int)  // Add new cards to deck
  Discharge(max_cards: Int)  // Remove cards from deck
  Camo(suit: Suit, max_cards: Int)  // Change cards to a suit
  Promote(max_cards: Int)  // Increase rank of cards
}

/// Sabotage cards (offensive debuffs)
pub type SabotageCard {
  Scrambler  // Cards drawn have chance to be face-down
  PlusBomb(max_cards: Int)  // Disable rank/suit scoring
  StaticField  // Disable enhancements
  SupplyChain  // Limit card draws
}

/// Card kind - category-specific card details
pub type CardKind {
  Research(ResearchCard)
  Counter(CounterCard)
  Logistics(LogisticsCard)
  Sabotage(SabotageCard)
}

/// Shop card - ID at top level with kind for category-specific details
pub type ShopCard {
  ShopCard(id: String, kind: CardKind)
}

// ===== Card Creation Functions =====

/// Returns all level up cards (one for each hand type)
pub fn all_level_up_cards() -> List(ShopCard) {
  [
    ShopCard(uuid.generate(), Research(LevelUp(hand.HighCard))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.Pair))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.TwoPair))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.ThreeOfAKind))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.Straight))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.Flush))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.FullHouse))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.FourOfAKind))),
    ShopCard(uuid.generate(), Research(LevelUp(hand.StraightFlush))),
  ]
}

/// Returns all denial cards (one for each hand type)
pub fn all_denial_cards() -> List(ShopCard) {
  [
    ShopCard(uuid.generate(), Counter(Denial(hand.HighCard))),
    ShopCard(uuid.generate(), Counter(Denial(hand.Pair))),
    ShopCard(uuid.generate(), Counter(Denial(hand.TwoPair))),
    ShopCard(uuid.generate(), Counter(Denial(hand.ThreeOfAKind))),
    ShopCard(uuid.generate(), Counter(Denial(hand.Straight))),
    ShopCard(uuid.generate(), Counter(Denial(hand.Flush))),
    ShopCard(uuid.generate(), Counter(Denial(hand.FullHouse))),
    ShopCard(uuid.generate(), Counter(Denial(hand.FourOfAKind))),
    ShopCard(uuid.generate(), Counter(Denial(hand.StraightFlush))),
  ]
}

/// Returns all deck builder cards
pub fn all_deck_builder_cards() -> List(ShopCard) {
  [
    ShopCard(uuid.generate(), Logistics(Fortify(40, 2))),
    ShopCard(uuid.generate(), Logistics(Amplify(1, 2))),
    ShopCard(uuid.generate(), Logistics(SupplyDrop(1))),
    ShopCard(uuid.generate(), Logistics(Discharge(2))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Hearts, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Diamonds, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Clubs, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Spades, 3))),
    ShopCard(uuid.generate(), Logistics(Promote(2))),
  ]
}

/// Returns all camo cards (one for each suit)
pub fn all_camo_cards() -> List(ShopCard) {
  [
    ShopCard(uuid.generate(), Logistics(Camo(card.Hearts, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Diamonds, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Clubs, 3))),
    ShopCard(uuid.generate(), Logistics(Camo(card.Spades, 3))),
  ]
}

/// DeckBuilder card constructors
pub fn bonus_chips_card() -> ShopCard {
  ShopCard(uuid.generate(), Logistics(Fortify(40, 2)))
}

pub fn bonus_mult_card() -> ShopCard {
  ShopCard(uuid.generate(), Logistics(Amplify(1, 2)))
}

pub fn add_card_card() -> ShopCard {
  ShopCard(uuid.generate(), Logistics(SupplyDrop(1)))
}

pub fn remove_card_card() -> ShopCard {
  ShopCard(uuid.generate(), Logistics(Discharge(2)))
}

pub fn increase_rank_card() -> ShopCard {
  ShopCard(uuid.generate(), Logistics(Promote(2)))
}

/// Sabotage card constructors
pub fn scrambler_card() -> ShopCard {
  ShopCard(uuid.generate(), Sabotage(Scrambler))
}

pub fn plus_bomb_card() -> ShopCard {
  ShopCard(uuid.generate(), Sabotage(PlusBomb(1)))
}

pub fn static_card() -> ShopCard {
  ShopCard(uuid.generate(), Sabotage(StaticField))
}

pub fn supply_chain_card() -> ShopCard {
  ShopCard(uuid.generate(), Sabotage(SupplyChain))
}

// ===== Helper Functions =====

/// Returns the ID of a shop card
pub fn id(card: ShopCard) -> String {
  card.id
}

/// Returns the name of a shop card
pub fn name(card: ShopCard) -> String {
  case card.kind {
    Research(inner) -> research_card_name(inner)
    Counter(inner) -> counter_card_name(inner)
    Logistics(inner) -> logistics_card_name(inner)
    Sabotage(inner) -> sabotage_card_name(inner)
  }
}

fn research_card_name(card: ResearchCard) -> String {
  case card {
    LevelUp(hand_type) -> format_hand_name(hand_type)
  }
}

fn counter_card_name(card: CounterCard) -> String {
  case card {
    Denial(hand_type) -> format_hand_name(hand_type)
  }
}

fn logistics_card_name(card: LogisticsCard) -> String {
  case card {
    Fortify(_, _) -> "Fortify"
    Amplify(_, _) -> "Amplify"
    SupplyDrop(_) -> "Supply Drop"
    Discharge(_) -> "Discharge"
    Camo(card.Hearts, _) -> "Camo ♥"
    Camo(card.Diamonds, _) -> "Camo ♦"
    Camo(card.Clubs, _) -> "Camo ♣"
    Camo(card.Spades, _) -> "Camo ♠"
    Promote(_) -> "Promote"
  }
}

fn sabotage_card_name(card: SabotageCard) -> String {
  case card {
    Scrambler -> "Scrambler"
    PlusBomb(_) -> "Napalm Strikes"
    StaticField -> "Static Field"
    SupplyChain -> "Supply Chain"
  }
}

/// Returns the description of a shop card
pub fn description(card: ShopCard) -> String {
  case card.kind {
    Research(inner) -> research_card_description(inner)
    Counter(inner) -> counter_card_description(inner)
    Logistics(inner) -> logistics_card_description(inner)
    Sabotage(inner) -> sabotage_card_description(inner)
  }
}

fn research_card_description(card: ResearchCard) -> String {
  case card {
    LevelUp(hand_type) ->
      "Upgrade " <> format_hand_name(hand_type) <> " - increases chips and multiplier"
  }
}

fn counter_card_description(card: CounterCard) -> String {
  case card {
    Denial(hand_type) ->
      "Opponent's " <> format_hand_name(hand_type) <> " scores 0 next round"
  }
}

fn logistics_card_description(card: LogisticsCard) -> String {
  case card {
    Fortify(amt, _) ->
      "Add +" <> int_to_string(amt) <> " chips to a card in your deck"
    Amplify(amt, _) ->
      "Add +" <> int_to_string(amt) <> " multiplier to a card in your deck"
    SupplyDrop(_) -> "Add a new card to your deck"
    Discharge(max_cards) ->
      "Remove up to " <> int_to_string(max_cards) <> " cards from your deck"
    Camo(_, max_cards) ->
      "Change up to " <> int_to_string(max_cards) <> " cards to the selected suit"
    Promote(max_cards) ->
      "Increase rank of up to " <> int_to_string(max_cards) <> " cards by 1 (max rank is Ace)"
  }
}

fn sabotage_card_description(card: SabotageCard) -> String {
  case card {
    Scrambler ->
      "Opponent's drawn cards have 1-in-5 chance of being face-down next round"
    PlusBomb(_) ->
      "Pick a card - opponent's matching rank/suit won't score"
    StaticField -> "Opponent's card enhancements disabled next round"
    SupplyChain -> "Opponent draws at most 4 cards when discarding next round"
  }
}

/// Returns the max number of cards that can be selected for this shop card
pub fn max_selection(card: ShopCard) -> Int {
  case card.kind {
    Research(_) -> 0
    Counter(_) -> 0
    Logistics(inner) -> logistics_card_max_selection(inner)
    Sabotage(inner) -> sabotage_card_max_selection(inner)
  }
}

fn logistics_card_max_selection(card: LogisticsCard) -> Int {
  case card {
    Fortify(_, max) -> max
    Amplify(_, max) -> max
    SupplyDrop(max) -> max
    Discharge(max) -> max
    Camo(_, max) -> max
    Promote(max) -> max
  }
}

fn sabotage_card_max_selection(card: SabotageCard) -> Int {
  case card {
    Scrambler -> 0
    PlusBomb(max) -> max
    StaticField -> 0
    SupplyChain -> 0
  }
}

/// Returns true if this card requires card selection
pub fn requires_selection(card: ShopCard) -> Bool {
  case card.kind {
    Research(_) -> False
    Counter(_) -> False
    Logistics(_) -> True
    Sabotage(inner) -> sabotage_card_requires_selection(inner)
  }
}

fn sabotage_card_requires_selection(card: SabotageCard) -> Bool {
  case card {
    PlusBomb(_) -> True
    _ -> False
  }
}

/// Formats a hand type name for display
fn format_hand_name(hand_type: HandType) -> String {
  case hand_type {
    hand.HighCard -> "High Card"
    hand.Pair -> "Pair"
    hand.TwoPair -> "Two Pair"
    hand.ThreeOfAKind -> "3 of a Kind"
    hand.Straight -> "Straight"
    hand.Flush -> "Flush"
    hand.FullHouse -> "Full House"
    hand.FourOfAKind -> "4 of a Kind"
    hand.StraightFlush -> "Str. Flush"
  }
}

/// Converts an integer to a string (basic implementation)
fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "10"
    20 -> "20"
    30 -> "30"
    40 -> "40"
    50 -> "50"
    _ -> "?"
  }
}
