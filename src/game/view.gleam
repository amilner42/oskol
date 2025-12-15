import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import poker/card.{type Card, type Suit}
import poker/hand.{type HandType}
import game/state.{type GameState}
import shop/card as shop_card
import shop/state as shop_state

// ========== PLAYER VIEW ADT ==========
// This is what gets sent to Elm - clean, minimal, typed

pub type PlayerView {
  // Before game starts
  LobbyView(LobbyData)

  // During gameplay
  PlayingView(PlayingData)

  // Between rounds (showing scores, who lost life)
  RoundEndView(RoundEndData)

  // Shop phase (between rounds, both players see everything)
  ShopView(ShopData)

  // Game finished
  GameOverView(GameOverData)
}

// ========== LOBBY DATA ==========

pub type LobbyData {
  LobbyData(
    your_name: String,
    opponent_name: Option(String),
    ready_to_start: Bool,
  )
}

// ========== PLAYING DATA ==========

pub type PlayingData {
  PlayingData(
    // Your state
    your_hand: List(Card),
    your_draw_pile: List(Card),
    your_lives: Int,
    your_hands_remaining: Int,
    your_discards_remaining: Int,
    your_current_score: Int,
    your_locked_in_hand: Option(List(Card)),
    your_face_down_card_ids: List(String),
    your_disabled_ranks: List(Int),
    your_disabled_suits: List(Suit),
    your_enhancements_disabled: Bool,
    your_active_debuffs: List(HandType),
    your_scrambled: Bool,
    your_supply_chain_limited: Bool,

    // Opponent state (both players see each other's hands AND effects!)
    opponent_name: String,
    opponent_hand: List(Card),
    opponent_lives: Int,
    opponent_hands_remaining: Int,
    opponent_discards_remaining: Int,
    opponent_current_score: Int,
    opponent_locked_in_hand: Option(List(Card)),
    opponent_face_down_card_ids: List(String),
    opponent_disabled_ranks: List(Int),
    opponent_disabled_suits: List(Suit),
    opponent_enhancements_disabled: Bool,
    opponent_active_debuffs: List(HandType),
    opponent_scrambled: Bool,
    opponent_supply_chain_limited: Bool,

    // Round info
    round_number: Int,

    // Game configuration
    hands_per_round: Int,
    discards_per_round: Int,
    initial_lives: Int,
  )
}

// ========== ROUND END DATA ==========

pub type RoundEndData {
  RoundEndData(
    // Your result
    your_name: String,
    your_hand_result: Option(HandResult),
    your_lives: Int,
    your_lost_life: Bool,

    // Opponent result
    opponent_name: String,
    opponent_hand_result: Option(HandResult),
    opponent_lives: Int,
    opponent_lost_life: Bool,

    // Round info
    round_number: Int,
    was_tie: Bool,
  )
}

pub type HandResult {
  HandResult(
    hand: List(Card),
    hand_type: String,
    score: Int,
    chips: Int,
    multiplier: Int,
  )
}

// ========== SHOP DATA ==========

pub type ShopData {
  ShopData(
    // Shop state (both players see everything - no hidden info!)
    shop_state: shop_state.ShopState,
    available_cards: List(shop_card.ShopCard),

    // Player info
    your_player_id: String,
    your_name: String,
    your_lives: Int,
    your_skill_tree: SkillTree,

    opponent_player_id: String,
    opponent_name: String,
    opponent_lives: Int,
    opponent_skill_tree: SkillTree,

    // Shop config
    current_round: Int,
    total_rounds: Int,
    initial_lives: Int,
  )
}

pub type SkillTree {
  SkillTree(
    high_card: Int,
    pair: Int,
    two_pair: Int,
    three_of_a_kind: Int,
    straight: Int,
    flush: Int,
    full_house: Int,
    four_of_a_kind: Int,
    straight_flush: Int,
  )
}

// ========== GAME OVER DATA ==========

pub type GameOverData {
  GameOverData(
    your_name: String,
    opponent_name: String,
    winner_name: String,
    you_won: Bool,
    your_final_lives: Int,
    opponent_final_lives: Int,
  )
}

// ========== VIEW GENERATOR ==========

/// Get the view for a specific player
/// This is the ONLY function Elixir should call to get UI data
pub fn get_player_view(state: GameState, player_id: String) -> PlayerView {
  // Check if shop is active first (overrides all other views)
  case state.shop_state {
    Some(shop) -> build_shop_view(state, shop, player_id)
    None ->
      case state.game_status {
        state.GameOver -> build_game_over_view(state, player_id)
        state.GameActive -> {
          case state.phase {
            state.Playing -> build_playing_view(state, player_id)
            state.RoundEnd -> build_round_end_view(state, player_id)
          }
        }
      }
  }
}

// ========== PLAYING VIEW BUILDER ==========

fn build_playing_view(state: GameState, player_id: String) -> PlayerView {
  // Get player and opponent
  let assert Ok(player) = dict.get(state.players, player_id)
  let opponent_id = get_opponent_id(state, player_id)
  let assert Ok(opponent) = dict.get(state.players, opponent_id)

  // Get opponent name
  let assert Ok(opponent_name) = dict.get(state.player_names, opponent_id)

  PlayingView(PlayingData(
    // Your state
    your_hand: player.card_piles.hand,
    your_draw_pile: player.card_piles.deck,
    your_lives: player.lives,
    your_hands_remaining: player.hands_remaining,
    your_discards_remaining: player.discards_remaining,
    your_current_score: player.current_round_score,
    your_locked_in_hand: player.locked_in_hand,
    your_face_down_card_ids: player.face_down_card_ids,
    your_disabled_ranks: list.map(player.disabled_ranks, card.rank_value),
    your_disabled_suits: player.disabled_suits,
    your_enhancements_disabled: player.enhancements_disabled,
    your_active_debuffs: player.active_debuffs,
    your_scrambled: player.scrambled,
    your_supply_chain_limited: player.supply_chain_limited,

    // Opponent state (both players see each other's hands AND effects!)
    opponent_name: opponent_name,
    opponent_hand: opponent.card_piles.hand,
    opponent_lives: opponent.lives,
    opponent_hands_remaining: opponent.hands_remaining,
    opponent_discards_remaining: opponent.discards_remaining,
    opponent_current_score: opponent.current_round_score,
    opponent_locked_in_hand: opponent.locked_in_hand,
    opponent_face_down_card_ids: opponent.face_down_card_ids,
    opponent_disabled_ranks: list.map(opponent.disabled_ranks, card.rank_value),
    opponent_disabled_suits: opponent.disabled_suits,
    opponent_enhancements_disabled: opponent.enhancements_disabled,
    opponent_active_debuffs: opponent.active_debuffs,
    opponent_scrambled: opponent.scrambled,
    opponent_supply_chain_limited: opponent.supply_chain_limited,

    // Round info
    round_number: state.round_number,

    // Game configuration
    hands_per_round: state.hands_per_round,
    discards_per_round: state.discards_per_round,
    initial_lives: state.initial_lives,
  ))
}

// ========== ROUND END VIEW BUILDER ==========

fn build_round_end_view(state: GameState, player_id: String) -> PlayerView {
  // Get player and opponent
  let assert Ok(player) = dict.get(state.players, player_id)
  let opponent_id = get_opponent_id(state, player_id)
  let assert Ok(opponent) = dict.get(state.players, opponent_id)

  // Get names
  let assert Ok(your_name) = dict.get(state.player_names, player_id)
  let assert Ok(opponent_name) = dict.get(state.player_names, opponent_id)

  // Get hand results from last_hand_results
  let your_hand_result = case state.last_hand_results {
    None -> None
    Some(results) -> case dict.get(results, player_id) {
      Ok(result) -> Some(HandResult(
        hand: result.hand,
        hand_type: hand_type_to_string(result.hand_type),
        score: result.score,
        chips: result.total_chips,
        multiplier: result.total_multiplier,
      ))
      Error(_) -> None
    }
  }

  let opponent_hand_result = case state.last_hand_results {
    None -> None
    Some(results) -> case dict.get(results, opponent_id) {
      Ok(result) -> Some(HandResult(
        hand: result.hand,
        hand_type: hand_type_to_string(result.hand_type),
        score: result.score,
        chips: result.total_chips,
        multiplier: result.total_multiplier,
      ))
      Error(_) -> None
    }
  }

  // Determine who lost life (compare last round winner)
  let your_lost_life = case state.last_round_winner_id {
    None -> False  // Tie, no one lost
    Some(winner_id) -> winner_id != player_id
  }

  let opponent_lost_life = case state.last_round_winner_id {
    None -> False  // Tie, no one lost
    Some(winner_id) -> winner_id != opponent_id
  }

  RoundEndView(RoundEndData(
    your_name: your_name,
    your_hand_result: your_hand_result,
    your_lives: player.lives,
    your_lost_life: your_lost_life,

    opponent_name: opponent_name,
    opponent_hand_result: opponent_hand_result,
    opponent_lives: opponent.lives,
    opponent_lost_life: opponent_lost_life,

    round_number: state.round_number,
    was_tie: case state.last_round_winner_id {
      None -> True
      Some(_) -> False
    },
  ))
}

// ========== SHOP VIEW BUILDER ==========

fn build_shop_view(state: GameState, shop: shop_state.ShopState, player_id: String) -> PlayerView {
  // Get player and opponent
  let assert Ok(player) = dict.get(state.players, player_id)
  let opponent_id = get_opponent_id(state, player_id)
  let assert Ok(opponent) = dict.get(state.players, opponent_id)

  // Get names
  let assert Ok(your_name) = dict.get(state.player_names, player_id)
  let assert Ok(opponent_name) = dict.get(state.player_names, opponent_id)

  ShopView(ShopData(
    shop_state: shop,
    available_cards: shop.available_cards,

    your_player_id: player_id,
    your_name: your_name,
    your_lives: player.lives,
    your_skill_tree: build_skill_tree(player.skill_tree),

    opponent_player_id: opponent_id,
    opponent_name: opponent_name,
    opponent_lives: opponent.lives,
    opponent_skill_tree: build_skill_tree(opponent.skill_tree),

    current_round: shop.current_round,
    total_rounds: shop.total_rounds,
    initial_lives: state.initial_lives,
  ))
}

// ========== SKILL TREE BUILDER ==========

fn build_skill_tree(skill_tree_dict: dict.Dict(HandType, Int)) -> SkillTree {
  let get_level = fn(hand_type) {
    case dict.get(skill_tree_dict, hand_type) {
      Ok(level) -> level
      Error(_) -> 1  // Default level is 1
    }
  }

  SkillTree(
    high_card: get_level(hand.HighCard),
    pair: get_level(hand.Pair),
    two_pair: get_level(hand.TwoPair),
    three_of_a_kind: get_level(hand.ThreeOfAKind),
    straight: get_level(hand.Straight),
    flush: get_level(hand.Flush),
    full_house: get_level(hand.FullHouse),
    four_of_a_kind: get_level(hand.FourOfAKind),
    straight_flush: get_level(hand.StraightFlush),
  )
}

// ========== GAME OVER VIEW BUILDER ==========

fn build_game_over_view(state: GameState, player_id: String) -> PlayerView {
  // Get player and opponent
  let assert Ok(player) = dict.get(state.players, player_id)
  let opponent_id = get_opponent_id(state, player_id)
  let assert Ok(opponent) = dict.get(state.players, opponent_id)

  // Get names
  let assert Ok(your_name) = dict.get(state.player_names, player_id)
  let assert Ok(opponent_name) = dict.get(state.player_names, opponent_id)

  // Get winner
  let assert Some(winner_id) = state.winner_id
  let assert Ok(winner_name) = dict.get(state.player_names, winner_id)
  let you_won = winner_id == player_id

  GameOverView(GameOverData(
    your_name: your_name,
    opponent_name: opponent_name,
    winner_name: winner_name,
    you_won: you_won,
    your_final_lives: player.lives,
    opponent_final_lives: opponent.lives,
  ))
}

// ========== HELPER FUNCTIONS ==========

fn get_opponent_id(state: GameState, player_id: String) -> String {
  let all_player_ids = dict.keys(state.players)
  let assert Ok(opponent_id) = list.find(all_player_ids, fn(id) { id != player_id })
  opponent_id
}

fn hand_type_to_string(hand_type: HandType) -> String {
  case hand_type {
    hand.HighCard -> "high_card"
    hand.Pair -> "pair"
    hand.TwoPair -> "two_pair"
    hand.ThreeOfAKind -> "three_of_a_kind"
    hand.Straight -> "straight"
    hand.Flush -> "flush"
    hand.FullHouse -> "full_house"
    hand.FourOfAKind -> "four_of_a_kind"
    hand.StraightFlush -> "straight_flush"
  }
}
