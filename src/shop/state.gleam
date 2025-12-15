import shop/card as shop_card
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import poker/card.{type Card}

pub type PlayerId =
  String

/// Pending deck builder selection state
pub type PendingDeckBuilder {
  PendingDeckBuilder(
    player_id: PlayerId,
    shop_card_id: String,
    deck_builder_card: shop_card.ShopCard,
    available_cards: List(Card),
  )
}

/// Pending plus bomb selection state
pub type PendingPlusBomb {
  PendingPlusBomb(
    player_id: PlayerId,
    shop_card_id: String,
    available_cards: List(Card),
  )
}

pub type ShopState {
  ShopState(
    total_rounds: Int,
    current_round: Int,
    first_picker_id: PlayerId,
    second_picker_id: PlayerId,
    first_pick_made: Bool,
    second_pick_made: Bool,
    available_cards: List(shop_card.ShopCard),
    picked_card_ids: List(String),
    // Pending selections (multi-step shop picks)
    pending_deck_builder: Option(PendingDeckBuilder),
    pending_plus_bomb: Option(PendingPlusBomb),
    // Destroy phase fields
    destroy_phase_complete: Bool,
    destroyer_id: Option(PlayerId),
    destroys_allowed: Int,
    destroyed_card_ids: List(String),
  )
}

pub type ShopError {
  DestroyPhaseNotComplete
  CardNotFound
  CardAlreadyPicked
  CardDestroyed
  NotYourTurn
  DestroyPhaseComplete
  NotDestroyer
  NoDestroysRemaining
  CardAlreadyDestroyed
  AlreadyComplete
}

/// Creates a new shop state
/// - winner_id: Player who won the last round (picks first)
/// - loser_id: Player who lost the last round (picks second)
/// - round_was_tie: If true, randomly assign who picks first
/// - total_rounds: Number of shop rounds (1-3)
/// - available_cards: The pool of shop cards
/// - player_lives: Map of player_id => lives for destroy phase calculation
pub fn new(
  winner_id: PlayerId,
  loser_id: PlayerId,
  round_was_tie: Bool,
  total_rounds: Int,
  available_cards: List(shop_card.ShopCard),
  player_lives: Dict(PlayerId, Int),
) -> ShopState {
  // If tie, randomly pick who goes first (simplified - caller should randomize)
  let #(first_player, second_player) = case round_was_tie {
    True -> #(winner_id, loser_id)
    // Could add randomization here, but Elixir bridge will handle it
    False -> #(winner_id, loser_id)
  }

  // Calculate destroy phase based on life difference
  let #(destroyer_id, destroys_allowed, destroy_phase_complete) =
    calculate_destroy_phase(player_lives)

  ShopState(
    total_rounds: total_rounds,
    current_round: 1,
    first_picker_id: first_player,
    second_picker_id: second_player,
    first_pick_made: False,
    second_pick_made: False,
    available_cards: available_cards,
    picked_card_ids: [],
    pending_deck_builder: None,
    pending_plus_bomb: None,
    destroy_phase_complete: destroy_phase_complete,
    destroyer_id: destroyer_id,
    destroys_allowed: destroys_allowed,
    destroyed_card_ids: [],
  )
}

/// Calculate destroy phase from player lives
fn calculate_destroy_phase(
  player_lives: Dict(PlayerId, Int),
) -> #(Option(PlayerId), Int, Bool) {
  let player_list = dict.to_list(player_lives)

  case player_list {
    [#(p1_id, p1_lives), #(p2_id, p2_lives)] ->
      case p1_lives < p2_lives {
        True -> #(Some(p1_id), p2_lives - p1_lives, False)
        False ->
          case p2_lives < p1_lives {
            True -> #(Some(p2_id), p1_lives - p2_lives, False)
            False -> #(None, 0, True)
          }
      }
    _ -> #(None, 0, True)
  }
}

// ===== Query Functions =====

/// Returns true if both players have picked in the current round
pub fn both_players_picked(shop_state: ShopState) -> Bool {
  shop_state.first_pick_made && shop_state.second_pick_made
}

/// Returns true if all shop rounds are complete
pub fn shop_complete(shop_state: ShopState) -> Bool {
  shop_state.current_round == shop_state.total_rounds
  && both_players_picked(shop_state)
}

/// Returns true if it's the given player's turn to pick
pub fn can_pick(shop_state: ShopState, player_id: PlayerId) -> Bool {
  case shop_state.destroy_phase_complete {
    False -> False
    True ->
      case
        !shop_state.first_pick_made
        && shop_state.first_picker_id == player_id
      {
        True -> True
        False ->
          shop_state.first_pick_made
          && !shop_state.second_pick_made
          && shop_state.second_picker_id == player_id
      }
  }
}

// ===== Pick Functions =====

/// Records a player's pick in the current round
/// Returns the selected shop card along with the updated shop state
pub fn make_pick(
  shop_state: ShopState,
  player_id: PlayerId,
  card_id: String,
) -> Result(#(ShopState, shop_card.ShopCard), ShopError) {
  // Validate destroy phase
  case shop_state.destroy_phase_complete {
    False -> Error(DestroyPhaseNotComplete)
    True -> {
      // Check if card already picked
      case list.contains(shop_state.picked_card_ids, card_id) {
        True -> Error(CardAlreadyPicked)
        False -> {
          // Check if card destroyed
          case list.contains(shop_state.destroyed_card_ids, card_id) {
            True -> Error(CardDestroyed)
            False -> {
              // Find the selected card by ID
              case list.find(shop_state.available_cards, fn(c) { shop_card.id(c) == card_id }) {
                Error(Nil) -> Error(CardNotFound)
                Ok(selected_card) ->
                  process_pick(shop_state, player_id, card_id, selected_card)
              }
            }
          }
        }
      }
    }
  }
}

fn process_pick(
  shop_state: ShopState,
  player_id: PlayerId,
  card_id: String,
  selected_card: shop_card.ShopCard,
) -> Result(#(ShopState, shop_card.ShopCard), ShopError) {
  case
    !shop_state.first_pick_made && player_id == shop_state.first_picker_id
  {
    True -> {
      let updated_state =
        ShopState(
          ..shop_state,
          first_pick_made: True,
          picked_card_ids: [card_id, ..shop_state.picked_card_ids],
        )
      Ok(#(updated_state, selected_card))
    }
    False ->
      case
        shop_state.first_pick_made
        && !shop_state.second_pick_made
        && player_id == shop_state.second_picker_id
      {
        True -> {
          let updated_state =
            ShopState(
              ..shop_state,
              second_pick_made: True,
              picked_card_ids: [card_id, ..shop_state.picked_card_ids],
            )
          // Advance to next round if both players picked and more rounds remain
          let final_state = advance_round(updated_state)
          Ok(#(final_state, selected_card))
        }
        False -> Error(NotYourTurn)
      }
  }
}

/// Marks a card as picked without completing the pick
/// Used for deck builders which need two-phase commitment
pub fn mark_card_picked(
  shop_state: ShopState,
  card_id: String,
) -> Result(ShopState, ShopError) {
  // Verify card exists
  case list.find(shop_state.available_cards, fn(c) { shop_card.id(c) == card_id }) {
    Error(Nil) -> Error(CardNotFound)
    Ok(_) ->
      case list.contains(shop_state.picked_card_ids, card_id) {
        True -> Error(CardAlreadyPicked)
        False -> {
          let updated_state =
            ShopState(
              ..shop_state,
              picked_card_ids: [card_id, ..shop_state.picked_card_ids],
            )
          Ok(updated_state)
        }
      }
  }
}

/// Completes a pending pick by marking first_pick_made or second_pick_made
/// Used after deck builder selection is confirmed
pub fn complete_pick(
  shop_state: ShopState,
  player_id: PlayerId,
) -> Result(ShopState, ShopError) {
  case
    !shop_state.first_pick_made && player_id == shop_state.first_picker_id
  {
    True -> {
      let updated_state = ShopState(..shop_state, first_pick_made: True)
      Ok(updated_state)
    }
    False ->
      case
        shop_state.first_pick_made
        && !shop_state.second_pick_made
        && player_id == shop_state.second_picker_id
      {
        True -> {
          let updated_state = ShopState(..shop_state, second_pick_made: True)
          // Advance to next round if both players picked and more rounds remain
          let final_state = advance_round(updated_state)
          Ok(final_state)
        }
        False -> Error(NotYourTurn)
      }
  }
}

// ===== Round Management =====

/// Advances to the next shop round
/// Should be called after both players have picked
pub fn advance_round(shop_state: ShopState) -> ShopState {
  case shop_state.current_round < shop_state.total_rounds {
    True ->
      ShopState(
        ..shop_state,
        current_round: shop_state.current_round + 1,
        first_pick_made: False,
        second_pick_made: False,
        pending_deck_builder: None,
        pending_plus_bomb: None,
      )
    False -> shop_state
  }
}

// ===== Destroy Phase Functions =====

/// Returns true if the destroy phase is still active
pub fn in_destroy_phase(shop_state: ShopState) -> Bool {
  !shop_state.destroy_phase_complete
}

/// Returns true if the given player can destroy cards
pub fn can_destroy(shop_state: ShopState, player_id: PlayerId) -> Bool {
  !shop_state.destroy_phase_complete
  && shop_state.destroyer_id == Some(player_id)
  && list.length(shop_state.destroyed_card_ids) < shop_state.destroys_allowed
}

/// Returns how many more cards the destroyer can destroy
pub fn destroys_remaining(shop_state: ShopState) -> Int {
  let used = list.length(shop_state.destroyed_card_ids)
  case shop_state.destroys_allowed > used {
    True -> shop_state.destroys_allowed - used
    False -> 0
  }
}

/// Destroys a card with the given ID
/// Auto-completes the destroy phase when all destroys are used
pub fn destroy_card(
  shop_state: ShopState,
  player_id: PlayerId,
  card_id: String,
) -> Result(ShopState, ShopError) {
  case shop_state.destroy_phase_complete {
    True -> Error(DestroyPhaseComplete)
    False ->
      case shop_state.destroyer_id {
        Some(destroyer) if destroyer == player_id -> {
          let destroyed_count = list.length(shop_state.destroyed_card_ids)
          case destroyed_count >= shop_state.destroys_allowed {
            True -> Error(NoDestroysRemaining)
            False -> {
              // Verify card exists
              case list.find(shop_state.available_cards, fn(c) { shop_card.id(c) == card_id }) {
                Error(Nil) -> Error(CardNotFound)
                Ok(_) ->
                  case list.contains(shop_state.destroyed_card_ids, card_id) {
                    True -> Error(CardAlreadyDestroyed)
                    False -> {
                      let new_destroyed = [card_id, ..shop_state.destroyed_card_ids]
                      let all_destroys_used =
                        list.length(new_destroyed) >= shop_state.destroys_allowed

                      let updated_state =
                        ShopState(
                          ..shop_state,
                          destroyed_card_ids: new_destroyed,
                          destroy_phase_complete: all_destroys_used,
                        )
                      Ok(updated_state)
                    }
                  }
              }
            }
          }
        }
        _ -> Error(NotDestroyer)
      }
  }
}

/// Completes the destroy phase
/// Can be called even if not all destroys have been used
pub fn complete_destroy_phase(
  shop_state: ShopState,
  player_id: PlayerId,
) -> Result(ShopState, ShopError) {
  case shop_state.destroy_phase_complete {
    True -> Error(AlreadyComplete)
    False ->
      case shop_state.destroyer_id {
        Some(destroyer) if destroyer == player_id -> {
          let updated_state = ShopState(..shop_state, destroy_phase_complete: True)
          Ok(updated_state)
        }
        _ -> Error(NotDestroyer)
      }
  }
}

/// Returns true if a card has been destroyed
pub fn card_destroyed(shop_state: ShopState, card_id: String) -> Bool {
  list.contains(shop_state.destroyed_card_ids, card_id)
}

/// Returns true if a card is unavailable (picked or destroyed)
pub fn card_unavailable(shop_state: ShopState, card_id: String) -> Bool {
  list.contains(shop_state.picked_card_ids, card_id)
  || list.contains(shop_state.destroyed_card_ids, card_id)
}

// ===== Deck Builder / Plus Bomb Multi-Step Functions =====

/// Confirms a deck builder pick - marks card as pending and provides player hand for selection
/// The pick is not complete until complete_deck_builder_selection is called
pub fn confirm_deck_builder_pick(
  shop_state: ShopState,
  player_id: PlayerId,
  card_id: String,
  player_hand: List(Card),
) -> Result(ShopState, ShopError) {
  // Validate player can pick
  case can_pick(shop_state, player_id) {
    False -> Error(NotYourTurn)
    True -> {
      // Find the shop card
      case list.find(shop_state.available_cards, fn(c) { shop_card.id(c) == card_id }) {
        Error(_) -> Error(CardNotFound)
        Ok(selected_card) -> {
          // Verify it's a deck builder card
          case selected_card.kind {
            shop_card.Logistics(_) -> {
              // Mark card as picked (reserves it)
              case mark_card_picked(shop_state, card_id) {
                Error(e) -> Error(e)
                Ok(updated_state) -> {
                  // Shuffle player's entire deck and take 8 cards for selection
                  let all_cards = player_hand
                  let shuffled_cards = list.shuffle(all_cards)
                  let available_cards = list.take(shuffled_cards, 8)

                  // Create pending state
                  let pending =
                    PendingDeckBuilder(
                      player_id: player_id,
                      shop_card_id: card_id,
                      deck_builder_card: selected_card,
                      available_cards: available_cards,
                    )

                  let final_state =
                    ShopState(..updated_state, pending_deck_builder: Some(pending))
                  Ok(final_state)
                }
              }
            }
            _ -> Error(CardNotFound)
          }
        }
      }
    }
  }
}

/// Completes a deck builder selection - applies the effect and marks pick as complete
/// Returns the updated shop state and the pending deck builder info for the engine to process
pub fn complete_deck_builder_selection(
  shop_state: ShopState,
  player_id: PlayerId,
) -> Result(#(ShopState, PendingDeckBuilder), ShopError) {
  // Verify there's a pending deck builder for this player
  case shop_state.pending_deck_builder {
    None -> Error(NotYourTurn)
    Some(pending) if pending.player_id == player_id -> {
      // Clear pending state
      let cleared_state = ShopState(..shop_state, pending_deck_builder: None)

      // Mark pick as complete
      case complete_pick(cleared_state, player_id) {
        Ok(updated_state) -> Ok(#(updated_state, pending))
        Error(e) -> Error(e)
      }
    }
    Some(_) -> Error(NotYourTurn)
  }
}

/// Confirms a plus bomb pick - marks card as pending and provides player hand for selection
/// The pick is not complete until complete_plus_bomb_selection is called
pub fn confirm_plus_bomb_pick(
  shop_state: ShopState,
  player_id: PlayerId,
  card_id: String,
  player_hand: List(Card),
) -> Result(ShopState, ShopError) {
  // Validate player can pick
  case can_pick(shop_state, player_id) {
    False -> Error(NotYourTurn)
    True -> {
      // Find the shop card
      case list.find(shop_state.available_cards, fn(c) { shop_card.id(c) == card_id }) {
        Error(_) -> Error(CardNotFound)
        Ok(selected_card) -> {
          // Verify it's a plus bomb card
          case selected_card.kind {
            shop_card.Sabotage(shop_card.PlusBomb(_)) -> {
              // Mark card as picked (reserves it)
              case mark_card_picked(shop_state, card_id) {
                Error(e) -> Error(e)
                Ok(updated_state) -> {
                  // Shuffle player's entire deck and take 8 cards for selection
                  let all_cards = player_hand
                  let shuffled_cards = list.shuffle(all_cards)
                  let available_cards = list.take(shuffled_cards, 8)

                  // Create pending state
                  let pending =
                    PendingPlusBomb(
                      player_id: player_id,
                      shop_card_id: card_id,
                      available_cards: available_cards,
                    )

                  let final_state =
                    ShopState(..updated_state, pending_plus_bomb: Some(pending))
                  Ok(final_state)
                }
              }
            }
            _ -> Error(CardNotFound)
          }
        }
      }
    }
  }
}

/// Completes a plus bomb selection - applies the effect and marks pick as complete
/// For now, just clears pending state and completes the pick
/// The actual opponent card modification should be handled by the game engine
pub fn complete_plus_bomb_selection(
  shop_state: ShopState,
  player_id: PlayerId,
) -> Result(ShopState, ShopError) {
  // Verify there's a pending plus bomb for this player
  case shop_state.pending_plus_bomb {
    None -> Error(NotYourTurn)
    Some(pending) if pending.player_id == player_id -> {
      // Clear pending state
      let cleared_state = ShopState(..shop_state, pending_plus_bomb: None)

      // Mark pick as complete
      complete_pick(cleared_state, player_id)
    }
    Some(_) -> Error(NotYourTurn)
  }
}

