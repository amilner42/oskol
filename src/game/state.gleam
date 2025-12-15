import game/event_log.{type EventLog}
import game/player.{type Player, type PlayerId}
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import poker/card.{type Card}
import poker/hand.{type HandType}
import poker/score
import shop/generator as shop_gen
import shop/state.{type ShopState} as shop_state

/// Game phase - what stage of the game we're in
pub type Phase {
  Playing
  RoundEnd
}

/// Game status - is the game still active or over?
pub type GameStatus {
  GameActive
  GameOver
}

/// Result of a hand being played
pub type HandResult {
  HandResult(
    hand: List(Card),
    hand_type: HandType,
    score: Int,
    total_chips: Int,
    total_multiplier: Int,
  )
}

/// Complete game state
pub type GameState {
  GameState(
    round_number: Int,
    player_names: Dict(PlayerId, String),
    players: Dict(PlayerId, Player),
    phase: Phase,
    game_status: GameStatus,
    last_hand_results: Option(Dict(PlayerId, HandResult)),
    round_hand_history: List(Dict(PlayerId, HandResult)),
    winner_id: Option(PlayerId),
    last_round_winner_id: Option(PlayerId),
    initial_lives: Int,
    hands_per_round: Int,
    discards_per_round: Int,
    shop_rounds: Int,
    event_log: EventLog,
    shop_state: Option(ShopState),
  )
}

// Note: Use engine.new_game() to create a new game
// This module only contains state manipulation functions

/// Check if both players have locked in their hands
pub fn both_players_locked_in(state: GameState) -> Bool {
  state.players
  |> dict.values
  |> list.all(player.has_locked_in)
}

/// Check if both players are ready for next round/rematch
pub fn both_players_ready_for_next_round(state: GameState) -> Bool {
  state.players
  |> dict.values
  |> list.all(fn(p) { p.ready_for_next_round })
}

/// Mark a player as ready for next round/rematch
pub fn mark_ready_for_next_round(
  state: GameState,
  player_id: PlayerId,
) -> Result(GameState, String) {
  case dict.get(state.players, player_id) {
    Error(_) -> Error("Player not found")
    Ok(p) -> {
      let updated_player = player.mark_ready_for_next_round(p)
      let updated_players =
        dict.insert(state.players, player_id, updated_player)
      Ok(GameState(..state, players: updated_players))
    }
  }
}

/// Lock in a hand for a player
pub fn player_lock_in_hand(
  state: GameState,
  player_id: PlayerId,
  hand: List(Card),
) -> Result(GameState, String) {
  case dict.get(state.players, player_id) {
    Error(_) -> Error("Player not found")
    Ok(p) -> {
      // Check if player already locked in
      case player.has_locked_in(p) {
        True -> Error("Player already locked in")
        False -> {
          // Lock in the hand
          let updated_player = player.lock_in_hand(p, hand)
          let updated_players =
            dict.insert(state.players, player_id, updated_player)

          // Clear last_hand_results on new player action (animation should only show once)
          let new_state =
            GameState(
              ..state,
              players: updated_players,
              last_hand_results: None,
            )

          // Check if both players locked in
          case both_players_locked_in(new_state) {
            True -> resolve_hands(new_state)
            False -> Ok(new_state)
          }
        }
      }
    }
  }
}

/// Resolve the locked-in hands and calculate scores
fn resolve_hands(state: GameState) -> Result(GameState, String) {
  // Get all players
  let player_ids = dict.keys(state.players)

  // Calculate scores for each player
  let hand_results =
    player_ids
    |> list.map(fn(player_id) {
      case dict.get(state.players, player_id) {
        Ok(p) -> {
          case p.locked_in_hand {
            Some(hand) -> {
              // Evaluate the hand
              let evaluation = hand.evaluate(hand)

              // Calculate score with player's skill tree and debuffs
              let card_debuffs =
                score.CardDebuffs(
                  disabled_ranks: p.disabled_ranks,
                  disabled_suits: p.disabled_suits,
                  enhancements_disabled: p.enhancements_disabled,
                )

              let score_result =
                score.calculate(
                  evaluation,
                  p.skill_tree,
                  p.active_debuffs,
                  card_debuffs,
                )

              let result =
                HandResult(
                  hand: hand,
                  hand_type: score_result.hand_type,
                  score: score_result.total_score,
                  total_chips: score_result.total_chips,
                  total_multiplier: score_result.total_multiplier,
                )

              #(player_id, result)
            }
            None -> {
              // Player didn't lock in (shouldn't happen)
              let result =
                HandResult(
                  hand: [],
                  hand_type: hand.HighCard,
                  score: 0,
                  total_chips: 0,
                  total_multiplier: 0,
                )
              #(player_id, result)
            }
          }
        }
        Error(_) -> {
          // Player not found (shouldn't happen)
          let result =
            HandResult(
              hand: [],
              hand_type: hand.HighCard,
              score: 0,
              total_chips: 0,
              total_multiplier: 0,
            )
          #(player_id, result)
        }
      }
    })
    |> dict.from_list

  // Update round hand history
  let new_history = [hand_results, ..state.round_hand_history]

  // Reset players for next hand (discard played cards, draw new ones, update scores)
  let reset_players =
    state.players
    |> dict.map_values(fn(player_id, p) {
      // Get the score for this player from hand_results
      let score_to_add = case dict.get(hand_results, player_id) {
        Ok(result) -> result.score
        Error(_) -> 0
      }
      player.reset_for_next_hand(p, score_to_add)
    })

  // Check if round is over (all players out of hands)
  let round_over =
    reset_players
    |> dict.values
    |> list.all(fn(p) { p.hands_remaining == 0 })

  case round_over {
    True -> {
      // End the round
      let state_with_results =
        GameState(
          ..state,
          players: reset_players,
          last_hand_results: Some(hand_results),
          round_hand_history: new_history,
          phase: RoundEnd,
        )
      end_round(state_with_results)
    }
    False ->
      Ok(
        GameState(
          ..state,
          players: reset_players,
          last_hand_results: Some(hand_results),
          round_hand_history: new_history,
        ),
      )
  }
}

/// End the current round and determine who loses a life
fn end_round(state: GameState) -> Result(GameState, String) {
  // Calculate total scores for the round
  let round_scores =
    state.round_hand_history
    |> list.fold(dict.new(), fn(acc, hand_results) {
      hand_results
      |> dict.to_list
      |> list.fold(acc, fn(acc2, entry) {
        let #(player_id, result) = entry
        dict.upsert(acc2, player_id, fn(existing) {
          case existing {
            Some(score) -> score + result.score
            None -> result.score
          }
        })
      })
    })

  // Find the player(s) with the lowest score
  let scores_list = dict.to_list(round_scores)
  let min_score =
    scores_list
    |> list.map(fn(entry) {
      let #(_id, score) = entry
      score
    })
    |> list.reduce(fn(a, b) {
      case a < b {
        True -> a
        False -> b
      }
    })

  case min_score {
    Error(_) -> Error("No scores found")
    Ok(lowest) -> {
      // Find all players with the lowest score (could be a tie)
      let losers =
        scores_list
        |> list.filter(fn(entry) {
          let #(_id, score) = entry
          score == lowest
        })
        |> list.map(fn(entry) {
          let #(player_id, _) = entry
          player_id
        })

      // Check if it's a tie
      let is_tie = list.length(losers) > 1

      // Deduct lives from losers (only if not a tie)
      let updated_players = case is_tie {
        True -> state.players
        False ->
          state.players
          |> dict.map_values(fn(player_id, p) {
            case list.contains(losers, player_id) {
              True -> player.lose_life(p)
              False -> p
            }
          })
      }

      // Check if game is over (any player eliminated)
      let game_over =
        updated_players
        |> dict.values
        |> list.any(fn(p) { p.status == player.Eliminated })

      let winner_id = case game_over {
        True -> {
          // Find the surviving player
          updated_players
          |> dict.to_list
          |> list.find(fn(entry) {
            let #(_id, p) = entry
            p.status == player.Active
          })
          |> result.map(fn(entry) {
            let #(player_id, _) = entry
            player_id
          })
          |> option.from_result
        }
        False -> None
      }

      let new_status = case game_over {
        True -> GameOver
        False -> GameActive
      }

      // Store the round winner for shop creation
      let round_winner_id = case is_tie {
        True -> None
        False ->
          list.first(losers)
          |> option.from_result
          |> option.map(fn(loser_id) {
            // Winner is the other player
            dict.keys(state.players)
            |> list.find(fn(id) { id != loser_id })
            |> result.unwrap("")
          })
      }

      // Clear temporary debuffs from previous shop round (if any) before creating new shop
      // Debuffs last exactly 1 round: applied in shop → active next round → cleared when new shop starts
      let players_with_cleared_debuffs = case game_over {
        True -> updated_players
        // Game over, no need to clear
        False -> {
          // Always clear debuffs before shop if game is active
          io.println("🧹 CLEARING previous round debuffs before shop")
          updated_players
          |> dict.map_values(fn(_id, p) { player.clear_sabotage(p) })
        }
      }

      // Create shop after EVERY round if game is still active
      // shop_rounds parameter controls how many pick rounds happen INSIDE each shop (1-3)
      let shop = case game_over {
        True -> {
          io.println("🏁 GAME OVER - No shop created")
          None
        }
        False -> {
          io.println(
            "✅ CREATING SHOP at end of round "
            <> int.to_string(state.round_number)
            <> " (shop_rounds="
            <> int.to_string(state.shop_rounds)
            <> " picks inside shop)",
          )

          // Generate shop cards
          let shop_cards = shop_gen.generate_shop_cards()

          // Get player IDs
          let player_ids = dict.keys(updated_players)
          let assert Ok(p1_id) = list.first(player_ids)
          let assert Ok(p2_id) = player_ids |> list.drop(1) |> list.first

          // Determine winner and loser for shop pick order
          let #(winner_id, loser_id, was_tie) = case round_winner_id {
            Some(winner) ->
              case winner == p1_id {
                True -> #(p1_id, p2_id, False)
                False -> #(p2_id, p1_id, False)
              }
            None -> #(p1_id, p2_id, True)
            // Tie
          }

          // Build player lives map from cleared players
          let player_lives =
            players_with_cleared_debuffs
            |> dict.map_values(fn(_id, p) { p.lives })

          // Create shop state
          // shop_rounds parameter = number of pick rounds inside this shop
          Some(shop_state.new(
            winner_id,
            loser_id,
            was_tie,
            state.shop_rounds,
            shop_cards,
            player_lives,
          ))
        }
      }

      let state_after_shop_check =
        GameState(
          ..state,
          players: players_with_cleared_debuffs,
          game_status: new_status,
          winner_id: winner_id,
          last_round_winner_id: round_winner_id,
          shop_state: shop,
        )

      // Shop is always created if game is active, so we only need to check game_over
      case game_over {
        True -> Ok(state_after_shop_check)
        // Game over, stay in RoundEnd to show results
        False -> Ok(state_after_shop_check)
        // Shop created, stay in RoundEnd until shop completes
      }
    }
  }
}

/// Start a new round (called after shop is complete or when there's no shop)
pub fn start_new_round(state: GameState) -> Result(GameState, String) {
  let new_round_number = state.round_number + 1

  io.println(
    "🔄 START_NEW_ROUND: advancing from round "
    <> int.to_string(state.round_number)
    <> " to "
    <> int.to_string(new_round_number),
  )

  // Reset players for the new round (shuffle deck, reset discards)
  // NOTE: Debuffs are NOT cleared here - they persist from shop phase
  // Debuffs are only cleared when a new shop starts (see end_round)
  let reset_players =
    state.players
    |> dict.map_values(fn(_id, p) {
      player.reset_for_new_round(
        p,
        state.hands_per_round,
        state.discards_per_round,
      )
    })

  // Always clear shop and start Playing phase
  // Shop was already created in end_round if needed
  Ok(
    GameState(
      ..state,
      round_number: new_round_number,
      players: reset_players,
      phase: Playing,
      shop_state: None,
      // Clear shop
      last_hand_results: None,
      round_hand_history: [],
      last_round_winner_id: None,
    ),
  )
}
