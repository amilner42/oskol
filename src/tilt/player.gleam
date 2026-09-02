import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import tilt/poker/card.{type Card, type Rank, type Suit}
import tilt/poker/deck
import tilt/poker/hand.{type HandType}

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
  CardPiles(deck: List(Card), hand: List(Card), discard: List(Card))
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

pub const hand_size = 8

/// Creates a new player from an already shuffled deck and draws the first hand.
pub fn new(
  player_id: PlayerId,
  initial_lives: Int,
  hands_per_round: Int,
  discards_per_round: Int,
  shuffled_deck: List(Card),
) -> Player {
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

  let #(initial_hand, remaining_deck) =
    deck.draw_cards(shuffled_deck, hand_size)
  let card_piles =
    CardPiles(deck: remaining_deck, hand: initial_hand, discard: [])

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

/// Scrambler effect: each drawn card has a 1-in-5 chance of being face-down.
fn scramble_cards(cards: List(Card), rng: Rng) -> #(List(String), Rng) {
  list.fold(cards, #([], rng), fn(acc, c) {
    let #(ids, rng) = acc
    let #(hit, rng) = rng.chance(rng, 1, 5)
    case hit {
      True -> #(list.append(ids, [c.id]), rng)
      False -> #(ids, rng)
    }
  })
}

pub fn has_locked_in(player: Player) -> Bool {
  case player.locked_in_hand {
    Some(_) -> True
    None -> False
  }
}

/// Lock in a hand for the player
pub fn lock_in_hand(player: Player, hand: List(Card)) -> Player {
  Player(
    ..player,
    locked_in_hand: Some(hand),
    hands_remaining: player.hands_remaining - 1,
  )
}

/// Cards in hand matching the given ids, in hand order. Errors if any id is
/// not in the hand.
pub fn cards_in_hand(
  player: Player,
  card_ids: List(String),
) -> Result(List(Card), String) {
  let found =
    list.filter(player.card_piles.hand, fn(c) { list.contains(card_ids, c.id) })
  case list.length(found) == list.length(list.unique(card_ids)) {
    True -> Ok(found)
    False -> Error("Card not in hand")
  }
}

/// How many cards to draw to refill the hand, honouring Supply Chain.
fn draw_count(player: Player, hand_after_removal: Int) -> Int {
  let needed = int.max(0, hand_size - hand_after_removal)
  case player.supply_chain_limited {
    True -> int.min(needed, 4)
    False -> needed
  }
}

/// Remove `removed` from the hand into the discard pile and draw replacements.
/// When the deck runs dry the discard pile is shuffled back in, so a hand can
/// only fall short of eight when the whole deck is smaller than that.
/// Returns the drawn cards so callers can emit events.
fn replace_cards(
  player: Player,
  removed: List(Card),
  rng: Rng,
) -> #(Player, List(Card), Rng) {
  let removed_ids = list.map(removed, fn(c) { c.id })
  let kept =
    list.filter(player.card_piles.hand, fn(c) {
      !list.contains(removed_ids, c.id)
    })
  let discard = list.append(player.card_piles.discard, removed)
  let #(drawn, new_deck, new_discard, rng) =
    draw_with_reshuffle(
      player.card_piles.deck,
      discard,
      draw_count(player, list.length(kept)),
      rng,
    )
  let #(face_down, rng) = case player.scrambled {
    True -> {
      let #(ids, rng) = scramble_cards(drawn, rng)
      #(list.append(player.face_down_card_ids, ids), rng)
    }
    False -> #(player.face_down_card_ids, rng)
  }
  let piles =
    CardPiles(
      deck: new_deck,
      hand: list.append(kept, drawn),
      discard: new_discard,
    )
  #(
    Player(..player, card_piles: piles, face_down_card_ids: face_down),
    drawn,
    rng,
  )
}

/// Draw `count` cards, reshuffling the discard pile into the deck if needed.
fn draw_with_reshuffle(
  deck: List(Card),
  discard: List(Card),
  count: Int,
  rng: Rng,
) -> #(List(Card), List(Card), List(Card), Rng) {
  let #(drawn, remaining) = deck.draw_cards(deck, count)
  let short = count - list.length(drawn)
  case short > 0 && discard != [] {
    True -> {
      let #(reshuffled, rng) = rng.shuffle(rng, discard)
      let #(more, remaining) = deck.draw_cards(reshuffled, short)
      #(list.append(drawn, more), remaining, [], rng)
    }
    False -> #(drawn, remaining, discard, rng)
  }
}

/// After a hand resolves: discard the played cards, draw replacements, bank
/// the score.
pub fn reset_for_next_hand(
  player: Player,
  score_to_add: Int,
  rng: Rng,
) -> #(Player, List(Card), Rng) {
  case player.locked_in_hand {
    None -> #(player, [], rng)
    Some(locked_hand) -> {
      let #(p, drawn, rng) = replace_cards(player, locked_hand, rng)
      #(
        Player(
          ..p,
          current_round_score: p.current_round_score + score_to_add,
          locked_in_hand: None,
        ),
        drawn,
        rng,
      )
    }
  }
}

/// Discard cards from hand and draw replacements. Returns the drawn cards.
pub fn discard_and_draw(
  player: Player,
  cards_to_discard: List(Card),
  rng: Rng,
) -> Result(#(Player, List(Card), Rng), String) {
  case player.discards_remaining > 0 {
    False -> Error("No discards remaining")
    True -> {
      let #(p, drawn, rng) = replace_cards(player, cards_to_discard, rng)
      Ok(#(
        Player(..p, discards_remaining: p.discards_remaining - 1),
        drawn,
        rng,
      ))
    }
  }
}

/// New round: shuffle every card back into the deck and draw a fresh hand.
/// Preserves lives, skill tree, sabotage effects and deck enhancements.
pub fn reset_for_new_round(
  player: Player,
  hands_per_round: Int,
  discards_per_round: Int,
  rng: Rng,
) -> #(Player, Rng) {
  let all_cards = get_all_cards(player)
  let #(shuffled_deck, rng) = rng.shuffle(rng, all_cards)
  let #(new_hand, remaining_deck) = deck.draw_cards(shuffled_deck, hand_size)
  let new_piles = CardPiles(deck: remaining_deck, hand: new_hand, discard: [])
  let #(face_down, rng) = case player.scrambled {
    True -> scramble_cards(new_hand, rng)
    False -> #([], rng)
  }
  #(
    Player(
      ..player,
      card_piles: new_piles,
      hands_remaining: hands_per_round,
      discards_remaining: discards_per_round,
      current_round_score: 0,
      locked_in_hand: None,
      face_down_card_ids: face_down,
    ),
    rng,
  )
}

/// Clear sabotage effects. They last exactly one round.
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

pub fn lose_life(player: Player) -> Player {
  let new_lives = player.lives - 1
  let new_status = case new_lives <= 0 {
    True -> Eliminated
    False -> player.status
  }
  Player(..player, lives: new_lives, status: new_status)
}

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

pub fn skill_level(player: Player, hand_type: HandType) -> Int {
  case dict.get(player.skill_tree, hand_type) {
    Ok(level) -> level
    Error(_) -> 1
  }
}

pub fn get_hand(player: Player) -> List(Card) {
  player.card_piles.hand
}

/// All cards in every pile (hand + deck + discard)
pub fn get_all_cards(player: Player) -> List(Card) {
  list.append(player.card_piles.hand, player.card_piles.deck)
  |> list.append(player.card_piles.discard)
}

fn map_all_cards(player: Player, f: fn(Card) -> Card) -> Player {
  let piles =
    CardPiles(
      hand: list.map(player.card_piles.hand, f),
      deck: list.map(player.card_piles.deck, f),
      discard: list.map(player.card_piles.discard, f),
    )
  Player(..player, card_piles: piles)
}

/// Apply (or stack) an enhancement on the given cards wherever they are.
pub fn apply_enhancements_to_cards(
  player: Player,
  card_ids: List(String),
  enhancement: card.Enhancement,
) -> Player {
  map_all_cards(player, fn(c) {
    case list.contains(card_ids, c.id) {
      True -> {
        let new_enhancement = case c.enhancement {
          None -> Some(enhancement)
          Some(existing) ->
            case existing, enhancement {
              card.BonusChips(a), card.BonusChips(b) ->
                Some(card.BonusChips(a + b))
              card.BonusMult(a), card.BonusMult(b) ->
                Some(card.BonusMult(a + b))
              _, _ -> Some(enhancement)
            }
        }
        card.Card(..c, enhancement: new_enhancement)
      }
      False -> c
    }
  })
}

/// Add new cards to the deck pile permanently
pub fn add_cards_to_deck(player: Player, cards: List(Card)) -> Player {
  let new_deck = list.append(player.card_piles.deck, cards)
  Player(..player, card_piles: CardPiles(..player.card_piles, deck: new_deck))
}

/// Remove cards by id from every pile
pub fn remove_cards_from_deck(player: Player, card_ids: List(String)) -> Player {
  let keep = fn(c: Card) -> Bool { !list.contains(card_ids, c.id) }
  let piles =
    CardPiles(
      hand: list.filter(player.card_piles.hand, keep),
      deck: list.filter(player.card_piles.deck, keep),
      discard: list.filter(player.card_piles.discard, keep),
    )
  Player(..player, card_piles: piles)
}

pub fn change_cards_suit(
  player: Player,
  card_ids: List(String),
  new_suit: Suit,
) -> Player {
  map_all_cards(player, fn(c) {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, suit: new_suit)
      False -> c
    }
  })
}

pub fn promote_cards(player: Player, card_ids: List(String)) -> Player {
  map_all_cards(player, fn(c) {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, rank: card.next_rank(c.rank))
      False -> c
    }
  })
}
