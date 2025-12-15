import game/event_log.{
  ActionError, CardsDiscarded, GameOver, HandLockedIn, HandUpgraded,
  HandsResolved, RoundEnded,
}
import game/player.{type PlayerId}
import game/state.{type GameState}
import game/view
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import poker/card.{type Card}
import poker/deck
import poker/hand.{type HandType}
import shop/card as shop_card
import shop/state as shop_state
import utils/uuid

// Re-export view types for Elixir
pub type PlayerView =
  view.PlayerView

/// Game actions - all possible player moves
pub type GameAction {
  // Gameplay actions
  LockInHand(player_id: PlayerId, hand: List(Card))
  DiscardCards(player_id: PlayerId, cards: List(Card))
  UpgradeHand(player_id: PlayerId, hand_type: HandType, levels: Int)
  MarkReadyForRematch(player_id: PlayerId)
  ClearAnimation(player_id: PlayerId)

  // Shop actions
  MakeShopPick(player_id: PlayerId, card_id: String)
  DestroyShopCard(player_id: PlayerId, card_id: String)
  CompleteDestroyPhase(player_id: PlayerId)

  // Multi-step shop actions
  ConfirmDeckBuilderPick(player_id: PlayerId, card_id: String)
  CompleteDeckBuilderSelection(
    player_id: PlayerId,
    selected_card_ids: List(String),
  )
  ConfirmPlusBombPick(player_id: PlayerId, card_id: String)
  CompletePlusBombSelection(player_id: PlayerId, opponent_card_id: String)
}

/// Re-export GameEvent from event_log
pub type GameEvent =
  event_log.GameEvent

/// Result of applying an action
pub type EngineResult {
  EngineResult(state: GameState, events: List(GameEvent))
}

/// Convert state.HandResult to event_log.HandResult
fn convert_hand_result(result: state.HandResult) -> event_log.HandResult {
  event_log.HandResult(
    hand: result.hand,
    hand_type: result.hand_type,
    score: result.score,
    total_chips: result.total_chips,
    total_multiplier: result.total_multiplier,
  )
}

/// Convert a dict of state.HandResult to event_log.HandResult
fn convert_hand_results(
  results: dict.Dict(PlayerId, state.HandResult),
) -> dict.Dict(PlayerId, event_log.HandResult) {
  dict.map_values(results, fn(_id, result) { convert_hand_result(result) })
}

/// Main entry point: apply an action to the game state
pub fn apply_action(state: GameState, action: GameAction) -> EngineResult {
  let result = case action {
    LockInHand(player_id, hand) -> handle_lock_in(state, player_id, hand)
    DiscardCards(player_id, cards) -> handle_discard(state, player_id, cards)
    UpgradeHand(player_id, hand_type, levels) ->
      handle_upgrade_hand(state, player_id, hand_type, levels)
    MarkReadyForRematch(player_id) -> handle_mark_ready(state, player_id)
    ClearAnimation(_player_id) -> handle_clear_animation(state)

    // Shop actions
    MakeShopPick(player_id, card_id) ->
      handle_make_shop_pick(state, player_id, card_id)
    DestroyShopCard(player_id, card_id) ->
      handle_destroy_shop_card(state, player_id, card_id)
    CompleteDestroyPhase(player_id) ->
      handle_complete_destroy_phase(state, player_id)

    // Multi-step shop actions
    ConfirmDeckBuilderPick(player_id, card_id) ->
      handle_confirm_deck_builder_pick(state, player_id, card_id)
    CompleteDeckBuilderSelection(player_id, selected_card_ids) ->
      handle_complete_deck_builder_selection(
        state,
        player_id,
        selected_card_ids,
      )
    ConfirmPlusBombPick(player_id, card_id) ->
      handle_confirm_plus_bomb_pick(state, player_id, card_id)
    CompletePlusBombSelection(player_id, opponent_card_id) ->
      handle_complete_plus_bomb_selection(state, player_id, opponent_card_id)
  }

  // Append events to the event log
  let updated_log = event_log.append_many(result.state.event_log, result.events)
  let updated_state = state.GameState(..result.state, event_log: updated_log)

  EngineResult(state: updated_state, events: result.events)
}

/// Handle locking in a hand
fn handle_lock_in(
  state: GameState,
  player_id: PlayerId,
  hand: List(Card),
) -> EngineResult {
  case state.player_lock_in_hand(state, player_id, hand) {
    Error(msg) -> EngineResult(state: state, events: [ActionError(msg)])
    Ok(new_state) -> {
      let events = [HandLockedIn(player_id, hand)]

      // Check if both players locked in
      case new_state.last_hand_results {
        Some(results) -> {
          let round_over = case new_state.phase {
            state.RoundEnd -> True
            _ -> False
          }

          let event_results = convert_hand_results(results)
          let resolve_events = [HandsResolved(event_results, round_over)]

          // Check for round end events
          case new_state.phase {
            state.RoundEnd -> {
              let loser_events = case new_state.last_round_winner_id {
                None -> [RoundEnded([], True)]
                Some(_winner) -> {
                  let loser_id =
                    dict.keys(new_state.players)
                    |> list.find(fn(id) {
                      Some(id) != new_state.last_round_winner_id
                    })
                    |> result.map(fn(id) { [id] })
                    |> result.unwrap([])

                  [RoundEnded(loser_id, False)]
                }
              }

              case new_state.game_status {
                state.GameOver ->
                  case new_state.winner_id {
                    Some(winner) ->
                      EngineResult(
                        state: new_state,
                        events: list.flatten([
                          events,
                          resolve_events,
                          loser_events,
                          [GameOver(winner)],
                        ]),
                      )
                    None ->
                      EngineResult(
                        state: new_state,
                        events: list.flatten([
                          events,
                          resolve_events,
                          loser_events,
                        ]),
                      )
                  }
                _ ->
                  EngineResult(
                    state: new_state,
                    events: list.flatten([events, resolve_events, loser_events]),
                  )
              }
            }
            _ ->
              EngineResult(
                state: new_state,
                events: list.append(events, resolve_events),
              )
          }
        }
        None -> EngineResult(state: new_state, events: events)
      }
    }
  }
}

/// Handle discarding cards
fn handle_discard(
  state: GameState,
  player_id: PlayerId,
  cards: List(Card),
) -> EngineResult {
  case dict.get(state.players, player_id) {
    Error(_) ->
      EngineResult(state: state, events: [ActionError("Player not found")])
    Ok(p) -> {
      case player.discard_and_draw(p, cards) {
        Error(msg) -> EngineResult(state: state, events: [ActionError(msg)])
        Ok(updated_player) -> {
          // Calculate drawn cards (new cards that weren't in hand before)
          let old_hand_size = list.length(p.card_piles.hand)
          let new_hand = updated_player.card_piles.hand
          let cards_discarded_count = list.length(cards)

          // Just use the last N cards drawn as the "new" cards
          let drawn_cards =
            list.drop(new_hand, old_hand_size - cards_discarded_count)

          let new_players =
            dict.insert(state.players, player_id, updated_player)
          // Clear last_hand_results on new player action (animation should only show once)
          let new_state =
            state.GameState(
              ..state,
              players: new_players,
              last_hand_results: None,
            )

          EngineResult(state: new_state, events: [
            CardsDiscarded(player_id, cards, drawn_cards),
          ])
        }
      }
    }
  }
}

/// Handle marking player as ready for next round/rematch
fn handle_mark_ready(state: GameState, player_id: PlayerId) -> EngineResult {
  case state.mark_ready_for_next_round(state, player_id) {
    Error(msg) -> EngineResult(state: state, events: [ActionError(msg)])
    Ok(new_state) ->
      EngineResult(state: new_state, events: [event_log.PlayerReady(player_id)])
  }
}

/// Handle clearing animation state (called when Elm animation completes)
fn handle_clear_animation(state: GameState) -> EngineResult {
  let cleared_state = state.GameState(..state, last_hand_results: None)
  EngineResult(state: cleared_state, events: [])
}

/// Handle upgrading a hand
fn handle_upgrade_hand(
  state: GameState,
  player_id: PlayerId,
  hand_type: HandType,
  levels: Int,
) -> EngineResult {
  case dict.get(state.players, player_id) {
    Error(_) ->
      EngineResult(state: state, events: [ActionError("Player not found")])
    Ok(p) -> {
      let updated_player = player.upgrade_hand(p, hand_type, levels)
      let new_level = case dict.get(updated_player.skill_tree, hand_type) {
        Ok(level) -> level
        Error(_) -> 1
      }

      let new_players = dict.insert(state.players, player_id, updated_player)
      let new_state = state.GameState(..state, players: new_players)

      EngineResult(state: new_state, events: [
        HandUpgraded(player_id, hand_type, new_level),
      ])
    }
  }
}

// ========== SHOP ACTION HANDLERS ==========

fn handle_make_shop_pick(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      case shop_state.make_pick(shop, player_id, card_id) {
        Error(err) -> {
          let msg = shop_error_to_string(err)
          EngineResult(state: state, events: [ActionError(msg)])
        }
        Ok(#(updated_shop, selected_card)) -> {
          // Apply card effects based on card type
          let state_with_effects = case selected_card.kind {
            // Sabotage cards - apply debuffs to opponent
            shop_card.Sabotage(sabotage_type) -> {
              // Get opponent player ID
              let all_player_ids = dict.keys(state.players)
              case list.find(all_player_ids, fn(id) { id != player_id }) {
                Error(_) -> state
                // Can't find opponent, shouldn't happen
                Ok(opponent_id) -> {
                  // Get opponent player
                  case dict.get(state.players, opponent_id) {
                    Error(_) -> state
                    // Opponent not found, shouldn't happen
                    Ok(opponent) -> {
                      // Apply sabotage effect to opponent
                      let updated_opponent = case sabotage_type {
                        shop_card.Scrambler ->
                          player.Player(..opponent, scrambled: True)
                        shop_card.StaticField ->
                          player.Player(..opponent, enhancements_disabled: True)
                        shop_card.SupplyChain ->
                          player.Player(..opponent, supply_chain_limited: True)
                        shop_card.PlusBomb(_) ->
                          // Plus Bomb requires card selection, will be handled in CompletePlusBombSelection
                          opponent
                      }

                      // Update opponent in state
                      let updated_players =
                        dict.insert(
                          state.players,
                          opponent_id,
                          updated_opponent,
                        )
                      state.GameState(..state, players: updated_players)
                    }
                  }
                }
              }
            }

            // Research cards - level up player's hand types
            shop_card.Research(shop_card.LevelUp(hand_type)) -> {
              case dict.get(state.players, player_id) {
                Error(_) -> state
                // Player not found, shouldn't happen
                Ok(current_player) -> {
                  let upgraded_player =
                    player.upgrade_hand(current_player, hand_type, 1)
                  let updated_players =
                    dict.insert(state.players, player_id, upgraded_player)
                  state.GameState(..state, players: updated_players)
                }
              }
            }

            // Counter cards - block opponent's hand types
            shop_card.Counter(shop_card.Denial(hand_type)) -> {
              // Get opponent player ID
              let all_player_ids = dict.keys(state.players)
              case list.find(all_player_ids, fn(id) { id != player_id }) {
                Error(_) -> state
                // Can't find opponent, shouldn't happen
                Ok(opponent_id) -> {
                  // Get opponent player
                  case dict.get(state.players, opponent_id) {
                    Error(_) -> state
                    // Opponent not found, shouldn't happen
                    Ok(opponent) -> {
                      // Add hand type to opponent's active debuffs
                      let updated_debuffs = [
                        hand_type,
                        ..opponent.active_debuffs
                      ]
                      let updated_opponent =
                        player.Player(
                          ..opponent,
                          active_debuffs: updated_debuffs,
                        )

                      // Update opponent in state
                      let updated_players =
                        dict.insert(
                          state.players,
                          opponent_id,
                          updated_opponent,
                        )
                      state.GameState(..state, players: updated_players)
                    }
                  }
                }
              }
            }

            // Logistics cards require card selection, will be handled in CompleteDeckBuilderSelection
            shop_card.Logistics(_) -> state
          }

          let new_state =
            state.GameState(
              ..state_with_effects,
              shop_state: Some(updated_shop),
            )
          // Check if shop is complete and auto-ready players if so
          let final_state = check_shop_completion_and_auto_ready(new_state)
          // TODO: Add shop event to event log when we add shop events
          EngineResult(state: final_state, events: [])
        }
      }
    }
  }
}

fn handle_destroy_shop_card(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      case shop_state.destroy_card(shop, player_id, card_id) {
        Error(err) -> {
          let msg = shop_error_to_string(err)
          EngineResult(state: state, events: [ActionError(msg)])
        }
        Ok(updated_shop) -> {
          let new_state =
            state.GameState(..state, shop_state: Some(updated_shop))
          EngineResult(state: new_state, events: [])
        }
      }
    }
  }
}

fn handle_complete_destroy_phase(
  state: GameState,
  player_id: PlayerId,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      case shop_state.complete_destroy_phase(shop, player_id) {
        Error(err) -> {
          let msg = shop_error_to_string(err)
          EngineResult(state: state, events: [ActionError(msg)])
        }
        Ok(updated_shop) -> {
          let new_state =
            state.GameState(..state, shop_state: Some(updated_shop))
          EngineResult(state: new_state, events: [])
        }
      }
    }
  }
}

// Multi-step shop handlers

fn handle_confirm_deck_builder_pick(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      // Get player's all cards (hand + deck + discard = 52 cards)
      case dict.get(state.players, player_id) {
        Error(_) ->
          EngineResult(state: state, events: [ActionError("Player not found")])
        Ok(player_state) -> {
          let player_all_cards = player.get_all_cards(player_state)

          case
            shop_state.confirm_deck_builder_pick(
              shop,
              player_id,
              card_id,
              player_all_cards,
            )
          {
            Error(err) -> {
              let msg = shop_error_to_string(err)
              EngineResult(state: state, events: [ActionError(msg)])
            }
            Ok(updated_shop) -> {
              let new_state =
                state.GameState(..state, shop_state: Some(updated_shop))
              EngineResult(state: new_state, events: [])
            }
          }
        }
      }
    }
  }
}

fn handle_complete_deck_builder_selection(
  state: GameState,
  player_id: PlayerId,
  selected_card_ids: List(String),
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      case shop_state.complete_deck_builder_selection(shop, player_id) {
        Error(err) -> {
          let msg = shop_error_to_string(err)
          EngineResult(state: state, events: [ActionError(msg)])
        }
        Ok(#(updated_shop, pending)) -> {
          // Apply the deck builder effects to the player's cards
          let state_with_enhancements = case
            dict.get(state.players, player_id)
          {
            Error(_) -> state
            // Player not found, shouldn't happen
            Ok(current_player) -> {
              // Extract the enhancement from the shop card
              let updated_player = case pending.deck_builder_card.kind {
                shop_card.Logistics(logistics_type) -> {
                  case logistics_type {
                    shop_card.Fortify(amount, _) ->
                      player.apply_enhancements_to_cards(
                        current_player,
                        selected_card_ids,
                        card.BonusChips(amount),
                      )
                    shop_card.Amplify(amount, _) ->
                      player.apply_enhancements_to_cards(
                        current_player,
                        selected_card_ids,
                        card.BonusMult(amount),
                      )
                    shop_card.SupplyDrop(_) -> {
                      // Create new cards from the selected card IDs
                      // The selected_card_ids point to cards from pending.available_cards
                      let cards_to_add =
                        list.filter_map(pending.available_cards, fn(c) {
                          case list.contains(selected_card_ids, c.id) {
                            True -> {
                              // Create a new card with the same rank and suit but new ID
                              let new_card =
                                card.Card(
                                  id: uuid.generate(),
                                  rank: c.rank,
                                  suit: c.suit,
                                  enhancement: None,
                                )
                              Ok(new_card)
                            }
                            False -> Error(Nil)
                          }
                        })
                      player.add_cards_to_deck(current_player, cards_to_add)
                    }
                    shop_card.Discharge(_) -> {
                      // Remove the selected cards from the deck
                      player.remove_cards_from_deck(
                        current_player,
                        selected_card_ids,
                      )
                    }
                    shop_card.Camo(target_suit, _) -> {
                      // Change the suit of the selected cards
                      player.change_cards_suit(
                        current_player,
                        selected_card_ids,
                        target_suit,
                      )
                    }
                    shop_card.Promote(_) -> {
                      // Increase the rank of the selected cards
                      player.promote_cards(current_player, selected_card_ids)
                    }
                  }
                }
                _ -> current_player
                // Not a logistics card, shouldn't happen
              }

              // Update player in state
              let updated_players =
                dict.insert(state.players, player_id, updated_player)
              state.GameState(..state, players: updated_players)
            }
          }

          let new_state =
            state.GameState(
              ..state_with_enhancements,
              shop_state: Some(updated_shop),
            )
          // Check if shop is complete and auto-ready players if so
          let final_state = check_shop_completion_and_auto_ready(new_state)
          EngineResult(state: final_state, events: [])
        }
      }
    }
  }
}

fn handle_confirm_plus_bomb_pick(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      // Get opponent's all cards (hand + deck + discard = 52 cards)
      // Find opponent player ID
      let all_player_ids = dict.keys(state.players)
      case list.find(all_player_ids, fn(id) { id != player_id }) {
        Error(_) ->
          EngineResult(state: state, events: [ActionError("Opponent not found")])
        Ok(opponent_id) -> {
          case dict.get(state.players, opponent_id) {
            Error(_) ->
              EngineResult(state: state, events: [
                ActionError("Opponent not found"),
              ])
            Ok(opponent) -> {
              let opponent_all_cards = player.get_all_cards(opponent)

              case
                shop_state.confirm_plus_bomb_pick(
                  shop,
                  player_id,
                  card_id,
                  opponent_all_cards,
                )
              {
                Error(err) -> {
                  let msg = shop_error_to_string(err)
                  EngineResult(state: state, events: [ActionError(msg)])
                }
                Ok(updated_shop) -> {
                  let new_state =
                    state.GameState(..state, shop_state: Some(updated_shop))
                  EngineResult(state: new_state, events: [])
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_complete_plus_bomb_selection(
  state: GameState,
  player_id: PlayerId,
  selected_card_id: String,
) -> EngineResult {
  case state.shop_state {
    None -> EngineResult(state: state, events: [ActionError("No active shop")])
    Some(shop) -> {
      case shop_state.complete_plus_bomb_selection(shop, player_id) {
        Error(err) -> {
          let msg = shop_error_to_string(err)
          EngineResult(state: state, events: [ActionError(msg)])
        }
        Ok(updated_shop) -> {
          // Get the pending plus bomb info to find the selected card
          let state_with_debuff = case shop.pending_plus_bomb {
            Some(pending) -> {
              // Find the selected card from available_cards
              case
                list.find(pending.available_cards, fn(c) {
                  c.id == selected_card_id
                })
              {
                Ok(selected_card) -> {
                  // Get opponent ID
                  let all_player_ids = dict.keys(state.players)
                  case list.find(all_player_ids, fn(id) { id != player_id }) {
                    Ok(opponent_id) -> {
                      // Get opponent player
                      case dict.get(state.players, opponent_id) {
                        Ok(opponent) -> {
                          // Add rank and suit to opponent's disabled lists
                          let updated_opponent =
                            player.Player(
                              ..opponent,
                              disabled_ranks: [
                                selected_card.rank,
                                ..opponent.disabled_ranks
                              ],
                              disabled_suits: [
                                selected_card.suit,
                                ..opponent.disabled_suits
                              ],
                            )
                          let updated_players =
                            dict.insert(
                              state.players,
                              opponent_id,
                              updated_opponent,
                            )
                          state.GameState(..state, players: updated_players)
                        }
                        Error(_) -> state
                      }
                    }
                    Error(_) -> state
                  }
                }
                Error(_) -> state
              }
            }
            None -> state
          }

          let new_state =
            state.GameState(..state_with_debuff, shop_state: Some(updated_shop))
          // Check if shop is complete and auto-ready players if so
          let final_state = check_shop_completion_and_auto_ready(new_state)
          EngineResult(state: final_state, events: [])
        }
      }
    }
  }
}

/// Helper to check if shop is complete and auto-advance to next round
fn check_shop_completion_and_auto_ready(state: GameState) -> GameState {
  case state.shop_state {
    None -> state
    Some(shop) -> {
      case shop_state.shop_complete(shop) {
        False -> state
        True -> {
          // Shop is complete - start next round automatically
          case state.start_new_round(state) {
            Ok(new_state) -> new_state
            Error(_) -> state
            // Shouldn't happen, but return original state on error
          }
        }
      }
    }
  }
}

fn shop_error_to_string(err: shop_state.ShopError) -> String {
  case err {
    shop_state.DestroyPhaseNotComplete -> "Destroy phase not complete"
    shop_state.CardNotFound -> "Card not found"
    shop_state.CardAlreadyPicked -> "Card already picked"
    shop_state.CardDestroyed -> "Card destroyed"
    shop_state.NotYourTurn -> "Not your turn"
    shop_state.DestroyPhaseComplete -> "Destroy phase already complete"
    shop_state.NotDestroyer -> "Not the destroyer"
    shop_state.NoDestroysRemaining -> "No destroys remaining"
    shop_state.CardAlreadyDestroyed -> "Card already destroyed"
    shop_state.AlreadyComplete -> "Already complete"
  }
}

/// Initialize a new game with player names
/// Creates and shuffles a deck for each player internally
pub fn new_game(
  player_names: dict.Dict(PlayerId, String),
  initial_lives: Int,
  hands_per_round: Int,
  discards_per_round: Int,
  shop_rounds: Int,
) -> GameState {
  // Create player states for all players
  let players =
    player_names
    |> dict.keys
    |> list.map(fn(player_id) {
      // Create and shuffle a deck for each player
      let shuffled_deck = deck.create_and_shuffle_standard_deck()

      let p =
        player.new(
          player_id,
          initial_lives,
          hands_per_round,
          discards_per_round,
          shuffled_deck,
        )
      #(player_id, p)
    })
    |> dict.from_list

  state.GameState(
    round_number: 1,
    player_names: player_names,
    players: players,
    phase: state.Playing,
    game_status: state.GameActive,
    last_hand_results: None,
    round_hand_history: [],
    winner_id: None,
    last_round_winner_id: None,
    initial_lives: initial_lives,
    hands_per_round: hands_per_round,
    discards_per_round: discards_per_round,
    shop_rounds: shop_rounds,
    event_log: event_log.new(),
    shop_state: None,
  )
}

/// Get the player-specific view for rendering
/// This is what gets sent to Elm - minimal, clean, typed
pub fn get_player_view(state: GameState, player_id: PlayerId) -> PlayerView {
  view.get_player_view(state, player_id)
}
