import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import poker/card.{type Card, type Rank, type Suit}
import poker/hand.{type HandType}
import poker/deck

/// Player ID is a string identifier
pub type PlayerId =
  String

/// Player status - active or eliminated
pub type PlayerStatus {
  Active
  Eliminated
}

/// Card piles - represents a player's deck, hand, and discard pile
pub type CardPiles {
  CardPiles(
    deck: List(Card),
    hand: List(Card),
    discard: List(Card),
  )
}

/// Player state - all info for a single player
pub type Player {
  Player(
    player_id: PlayerId,
    lives: Int,
    card_piles: CardPiles,
    skill_tree: Dict(HandType, Int),
    hands_remaining: Int,
    discards_remaining: Int,
    current_round_score: Int,
    locked_in_hand: Option(List(Card)),
    status: PlayerStatus,
    active_debuffs: List(HandType),
    scrambled: Bool,
    face_down_card_ids: List(String),
    disabled_ranks: List(Rank),
    disabled_suits: List(Suit),
    enhancements_disabled: Bool,
    supply_chain_limited: Bool,
  )
}

/// Creates a new player with initial settings and a shuffled deck
pub fn new(
  player_id: PlayerId,
  initial_lives: Int,
  hands_per_round: Int,
  discards_per_round: Int,
  shuffled_deck: List(Card),
) -> Player {
  // Create initial skill tree with all hands at level 1
  let skill_tree =
    dict.from_list([
      #(hand.HighCard, 1),
      #(hand.Pair, 1),
      #(hand.TwoPair, 1),
      #(hand.ThreeOfAKind, 1),
      #(hand.Straight, 1),
      #(hand.Flush, 1),
      #(hand.FullHouse, 1),
      #(hand.FourOfAKind, 1),
      #(hand.StraightFlush, 1),
    ])

  // Draw initial hand (8 cards)
  let #(initial_hand, remaining_deck) = deck.draw_cards(shuffled_deck, 8)
  let card_piles = CardPiles(deck: remaining_deck, hand: initial_hand, discard: [])

  // Note: No scrambling on initial creation since scrambled starts as False
  Player(
    player_id: player_id,
    lives: initial_lives,
    card_piles: card_piles,
    skill_tree: skill_tree,
    hands_remaining: hands_per_round,
    discards_remaining: discards_per_round,
    current_round_score: 0,
    locked_in_hand: None,
    status: Active,
    active_debuffs: [],
    scrambled: False,
    face_down_card_ids: [],
    disabled_ranks: [],
    disabled_suits: [],
    enhancements_disabled: False,
    supply_chain_limited: False,
  )
}

/// Helper function to randomly select ~20% of cards to be face-down (scrambler effect)
/// Returns the list of card IDs that should be face-down
fn scramble_cards(cards: List(Card)) -> List(String) {
  // Filter cards with ~20% probability (1 in 5)
  list.filter_map(cards, fn(card) {
    let random_value = int.random(5)  // Returns 0-4
    case random_value == 0 {
      True -> Ok(card.id)  // ~20% chance: add to face_down list
      False -> Error(Nil)  // ~80% chance: skip
    }
  })
}

/// Check if player has locked in a hand
pub fn has_locked_in(player: Player) -> Bool {
  case player.locked_in_hand {
    Some(_) -> True
    None -> False
  }
}

/// Lock in a hand for the player
pub fn lock_in_hand(player: Player, hand: List(Card)) -> Player {
  Player(..player, locked_in_hand: Some(hand), hands_remaining: player.hands_remaining - 1)
}

/// Reset player for next hand within the same round
/// This discards the locked in cards, draws new ones, and updates the score
pub fn reset_for_next_hand(player: Player, score_to_add: Int) -> Player {
  case player.locked_in_hand {
    None -> player  // No locked in hand, nothing to do
    Some(locked_hand) -> {
      // Remove locked in cards from hand
      let new_hand =
        list.filter(player.card_piles.hand, fn(c) {
          !list.contains(locked_hand, c)
        })

      // Add locked in cards to discard pile
      let new_discard = list.append(player.card_piles.discard, locked_hand)

      // Draw replacement cards
      let num_to_draw = list.length(locked_hand)
      let #(drawn_cards, new_deck) =
        deck.draw_cards(player.card_piles.deck, num_to_draw)

      // Add drawn cards to hand
      let final_hand = list.append(new_hand, drawn_cards)

      let new_piles =
        CardPiles(deck: new_deck, hand: final_hand, discard: new_discard)

      // Apply scrambler effect if active (1 in 5 cards become face-down)
      let new_face_down_ids = case player.scrambled {
        True -> {
          let scrambled_ids = scramble_cards(drawn_cards)
          list.append(player.face_down_card_ids, scrambled_ids)
        }
        False -> player.face_down_card_ids
      }

      Player(
        ..player,
        card_piles: new_piles,
        current_round_score: player.current_round_score + score_to_add,
        locked_in_hand: None,
        face_down_card_ids: new_face_down_ids,
      )
    }
  }
}

/// Reset player for a new round
/// - Shuffles all cards (hand + deck + discard) into a new deck
/// - Resets hands_remaining and discards_remaining
/// - Preserves: lives, skill_tree, sabotage effects, deck enhancements
pub fn reset_for_new_round(player: Player, hands_per_round: Int, discards_per_round: Int) -> Player {
  // Combine all cards from hand, deck, and discard pile
  let all_cards =
    list.append(player.card_piles.hand, player.card_piles.deck)
    |> list.append(player.card_piles.discard)

  // Shuffle the combined deck
  let shuffled_deck = list.shuffle(all_cards)

  // Draw new hand of 8 cards
  let #(new_hand, remaining_deck) = deck.draw_cards(shuffled_deck, 8)

  // Create new card piles
  let new_piles = CardPiles(
    deck: remaining_deck,
    hand: new_hand,
    discard: [],
  )

  // Apply scrambler effect if active (1 in 5 cards become face-down)
  let new_face_down_ids = case player.scrambled {
    True -> scramble_cards(new_hand)
    False -> []
  }

  Player(
    ..player,
    card_piles: new_piles,
    hands_remaining: hands_per_round,
    discards_remaining: discards_per_round,
    current_round_score: 0,
    locked_in_hand: None,
    face_down_card_ids: new_face_down_ids,
    // NOTE: Spread operator ..player preserves all other fields including:
    // - lives (never reset)
    // - skill_tree (level upgrades persist)
    // - sabotage effects (cleared only when shop starts, see end_round() in state.gleam)
    // - deck enhancements (persist through shuffles)
  )
}

/// Clear sabotage effects after they've lasted for 1 round
/// Called at the END of a round before transitioning to the next
pub fn clear_sabotage(player: Player) -> Player {
  Player(
    ..player,
    active_debuffs: [],
    scrambled: False,
    face_down_card_ids: [],
    disabled_ranks: [],
    disabled_suits: [],
    enhancements_disabled: False,
    supply_chain_limited: False,
  )
}

/// Deduct a life from the player
pub fn lose_life(player: Player) -> Player {
  let new_lives = player.lives - 1
  let new_status = case new_lives <= 0 {
    True -> Eliminated
    False -> player.status
  }
  Player(..player, lives: new_lives, status: new_status)
}

/// Upgrade a hand type in the player's skill tree
pub fn upgrade_hand(player: Player, hand_type: HandType, levels: Int) -> Player {
  let new_skill_tree =
    dict.upsert(player.skill_tree, hand_type, fn(existing) {
      case existing {
        Some(current_level) -> current_level + levels
        None -> 1 + levels
      }
    })
  Player(..player, skill_tree: new_skill_tree)
}

/// Discard cards from hand and draw replacements
pub fn discard_and_draw(
  player: Player,
  cards_to_discard: List(Card),
) -> Result(Player, String) {
  // Check if player has discards remaining
  case player.discards_remaining > 0 {
    False -> Error("No discards remaining")
    True -> {
      // Remove cards from hand
      let new_hand =
        list.filter(player.card_piles.hand, fn(c) {
          !list.contains(cards_to_discard, c)
        })

      // Add to discard pile
      let new_discard = list.append(player.card_piles.discard, cards_to_discard)

      // Draw replacement cards
      let num_to_draw = list.length(cards_to_discard)
      let #(drawn_cards, new_deck) =
        deck.draw_cards(player.card_piles.deck, num_to_draw)

      // Add drawn cards to hand
      let final_hand = list.append(new_hand, drawn_cards)

      let new_piles =
        CardPiles(deck: new_deck, hand: final_hand, discard: new_discard)

      // Apply scrambler effect if active (1 in 5 cards become face-down)
      let new_face_down_ids = case player.scrambled {
        True -> {
          let scrambled_ids = scramble_cards(drawn_cards)
          list.append(player.face_down_card_ids, scrambled_ids)
        }
        False -> player.face_down_card_ids
      }

      Ok(Player(
        ..player,
        card_piles: new_piles,
        discards_remaining: player.discards_remaining - 1,
        face_down_card_ids: new_face_down_ids,
      ))
    }
  }
}

/// Get the current hand
pub fn get_hand(player: Player) -> List(Card) {
  player.card_piles.hand
}

/// Draw cards at the start of a new round
/// NOTE: This function appears to be unused - reset_for_new_round handles round starts
pub fn draw_initial_hand(player: Player) -> Player {
  let #(drawn_cards, new_deck) = deck.draw_cards(player.card_piles.deck, 8)
  let new_piles =
    CardPiles(..player.card_piles, hand: drawn_cards, deck: new_deck)

  // Apply scrambler effect if active (1 in 5 cards become face-down)
  let new_face_down_ids = case player.scrambled {
    True -> scramble_cards(drawn_cards)
    False -> []
  }

  Player(..player, card_piles: new_piles, face_down_card_ids: new_face_down_ids)
}

/// Apply an enhancement to specific cards by their IDs
/// Searches through all card piles (hand, deck, discard) and applies the enhancement
pub fn apply_enhancements_to_cards(
  player: Player,
  card_ids: List(String),
  enhancement: card.Enhancement,
) -> Player {
  // Helper function to apply enhancement to a single card if its ID matches
  let apply_to_card = fn(c: Card) -> Card {
    case list.contains(card_ids, c.id) {
      True -> {
        // Apply or stack enhancement based on existing enhancement
        let new_enhancement = case c.enhancement {
          None -> Some(enhancement)
          Some(existing) -> {
            // Stack enhancements if both are the same type
            case existing, enhancement {
              card.BonusChips(existing_chips), card.BonusChips(new_chips) ->
                Some(card.BonusChips(existing_chips + new_chips))
              card.BonusMult(existing_mult), card.BonusMult(new_mult) ->
                Some(card.BonusMult(existing_mult + new_mult))
              // If different types, replace with new enhancement
              _, _ -> Some(enhancement)
            }
          }
        }
        card.Card(..c, enhancement: new_enhancement)
      }
      False -> c
    }
  }

  // Apply to all cards in all piles
  let new_hand = list.map(player.card_piles.hand, apply_to_card)
  let new_deck = list.map(player.card_piles.deck, apply_to_card)
  let new_discard = list.map(player.card_piles.discard, apply_to_card)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)

  Player(..player, card_piles: new_piles)
}

/// Add new cards to the player's deck permanently
/// Cards are added to the deck pile (not the hand)
pub fn add_cards_to_deck(player: Player, cards: List(Card)) -> Player {
  let new_deck = list.append(player.card_piles.deck, cards)
  let new_piles = CardPiles(..player.card_piles, deck: new_deck)
  Player(..player, card_piles: new_piles)
}

/// Remove specific cards from the player's deck by their IDs
/// Searches through all card piles (hand, deck, discard) and removes matching cards
pub fn remove_cards_from_deck(player: Player, card_ids: List(String)) -> Player {
  // Helper function to filter out cards by ID
  let filter_card = fn(c: Card) -> Bool {
    !list.contains(card_ids, c.id)
  }

  // Remove from all piles
  let new_hand = list.filter(player.card_piles.hand, filter_card)
  let new_deck = list.filter(player.card_piles.deck, filter_card)
  let new_discard = list.filter(player.card_piles.discard, filter_card)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)

  Player(..player, card_piles: new_piles)
}

/// Change the suit of specific cards by their IDs
pub fn change_cards_suit(
  player: Player,
  card_ids: List(String),
  new_suit: Suit,
) -> Player {
  let change_suit = fn(c: Card) -> Card {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, suit: new_suit)
      False -> c
    }
  }

  // Apply to all cards in all piles
  let new_hand = list.map(player.card_piles.hand, change_suit)
  let new_deck = list.map(player.card_piles.deck, change_suit)
  let new_discard = list.map(player.card_piles.discard, change_suit)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)
  Player(..player, card_piles: new_piles)
}

/// Increase the rank of specific cards by their IDs
pub fn promote_cards(
  player: Player,
  card_ids: List(String),
) -> Player {
  let promote = fn(c: Card) -> Card {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, rank: card.next_rank(c.rank))
      False -> c
    }
  }

  // Apply to all cards in all piles
  let new_hand = list.map(player.card_piles.hand, promote)
  let new_deck = list.map(player.card_piles.deck, promote)
  let new_discard = list.map(player.card_piles.discard, promote)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)
  Player(..player, card_piles: new_piles)
}
