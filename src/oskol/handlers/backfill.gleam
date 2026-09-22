//// The puzzles backfill: games graded before the engine sent every legal
//// result are asked again, so their puzzles can grade any attempt and
//// their post-take plays are judged on the right cube.
////
//// The one sanctioned re-ask. Reading never spends engine time; this is
//// an operator's task (`mix oskol.puzzles.backfill`, dry run by default),
//// one game at a time, with the review queue off for the run. Elixir
//// walks the rooms and prints; every decision is here:
////
//// - which stored answers are old: `old_contract`, read off the response
////   itself (a move without `results`), never off a marker;
//// - what the fresh answer must hold before it is trusted: `trusted`, and
////   a game whose answer falls short is quarantined with the reason, its
////   row charged to the limit so it is not asked again until an operator
////   `reset`s it;
//// - what a re-ask writes: the fresh answer and its page over the old,
////   with the game's puzzles reopened in the same write (`replace`), then
////   the puzzles through the same `extracted` a fresh review uses. One
////   write, so a crash leaves either the old answer, still old and found
////   by the next run, or the fresh one visibly owed its puzzles, which
////   the sweep extracts -- never a fresh answer whose puzzles are silently
////   the old ones, and never an old answer the live sweep is invited to
////   extract again.
////
//// A game the engine does not answer is charged one attempt, like any
//// retry, and left for the next run; three spent and it is skipped, and
//// says so. Nothing here fails the row the page reads: a `done` game keeps
//// its answer and its page through every failure.

import backgammon/analysis.{type GameTurns}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/analysis.{type Stored, Done, Save} as _
import oskol/caps/puzzles.{type Written}
import oskol/core/ctx.{type Ctx}
import oskol/handlers/reviews
import oskol/puzzles/extract
import oskol/reviews/report.{type Review, Moved}

/// A room replayed once, held by the caller between games.
pub opaque type Room {
  Room(games: List(GameTurns), seats: List(report.Seat))
}

/// A graded game whose stored answer predates `all_results`.
pub type Candidate {
  Candidate(
    number: Int,
    turns: Int,
    /// Engine calls charged to the row so far. At `reviews.max_attempts`
    /// the game is skipped until `reset`.
    attempts: Int,
    /// The depth the stored answer was graded at; the fresh one is asked
    /// at the same.
    levels: Option(report.Levels),
  )
}

/// What one room holds for the backfill: the replay, the games to ask
/// again, and the game numbers whose stored answer could not be read at
/// all (a `done` row that is neither old nor new: left alone, and named).
pub type Found {
  Found(room: Room, candidates: List(Candidate), unreadable: List(Int))
}

pub type Outcome {
  /// The engine answered and the row, its page and its puzzles are from the
  /// fresh answer. `engine_ms` is the engine's own timing when it says;
  /// `written` is what the extraction stored, or why it could not (the row
  /// is then owed its puzzles and the sweep will try, within its budget).
  Reasked(engine_ms: Option(Int), written: Result(Written, String))
  /// The engine answered but the answer cannot be trusted: nothing but the
  /// charge was written. `reason` is one of the codes `trusted` names.
  Quarantined(reason: String, turn: Option(Int))
  /// The engine did not answer. Charged; tried again on the next run.
  EngineFailed(reason: String)
  /// The candidate names a game the replay does not have.
  NotInReplay
}

/// Was this answer graded before the engine sent every legal result? Any
/// checker play without them says so; a dance and a cube-only turn say
/// nothing either way.
pub fn old_contract(review: Review) -> Bool {
  list.any(review.turns, fn(turn) {
    case turn.move {
      Some(move) -> extract.before_results(move)
      None -> False
    }
  })
}

/// Replay the room and say which of its graded games are old. Error when
/// it is not a started backgammon room or its log does not replay.
pub fn candidates(ctx: Ctx, game_id: String) -> Result(Found, String) {
  case reviews.replayed_room(ctx, game_id) {
    None -> Error("not a started backgammon room, or its log does not replay")
    // The rows as the replay read them: `settle` may have rendered one
    // since, but rendering changes nothing this reads.
    Some(#(games, seats, stored)) -> {
      let #(found, unreadable) =
        list.fold(stored, #([], []), fn(acc, row) {
          case candidate(row, games) {
            Ok(Some(c)) -> #([c, ..acc.0], acc.1)
            Ok(None) -> acc
            Error(Nil) -> #(acc.0, [row.game_number, ..acc.1])
          }
        })
      Ok(Found(
        room: Room(games, seats),
        candidates: list.reverse(found),
        unreadable: list.reverse(unreadable),
      ))
    }
  }
}

/// Ok(Some) for an old answer, Ok(None) for a row that is not a `done`
/// answer or is already new, Error for a `done` answer that does not read.
fn candidate(
  row: Stored,
  games: List(GameTurns),
) -> Result(Option(Candidate), Nil) {
  case row.status, row.response_json {
    Done, Some(body) ->
      case report.parse(body) {
        Error(_) -> Error(Nil)
        Ok(review) ->
          case old_contract(review), game(games, row.game_number) {
            True, Ok(g) if g.finished && g.turns != [] ->
              Ok(
                Some(Candidate(
                  number: row.game_number,
                  turns: list.length(g.turns),
                  attempts: row.attempts,
                  levels: review.levels,
                )),
              )
            _, _ -> Ok(None)
          }
      }
    _, _ -> Ok(None)
  }
}

/// May this candidate be asked now? Three engine calls charged and it
/// waits for an operator.
pub fn spent(c: Candidate) -> Bool {
  c.attempts >= reviews.max_attempts
}

/// Ask the engine about one old game again and settle everything that
/// depends on its answer.
pub fn reask(ctx: Ctx, game_id: String, room: Room, c: Candidate) -> Outcome {
  case game(room.games, c.number) {
    Error(Nil) -> NotInReplay
    Ok(g) -> {
      let attempts = c.attempts + 1
      let #(move_level, cube_level) = case c.levels {
        Some(report.Levels(moves, cube)) -> #(Some(moves), Some(cube))
        None -> #(None, None)
      }
      let body =
        json.to_string(analysis.request_json_at(g, move_level, cube_level))
      case ctx.analysis.review(body) {
        Error(reason) -> {
          ctx.analysis.charge(game_id, c.number, attempts, Some(reason))
          EngineFailed(reason)
        }
        Ok(response) ->
          case reviews.rendered(response, g, room.seats) {
            Error(reason) -> quarantine(ctx, game_id, c.number, reason, None)
            Ok(#(review, page)) ->
              case trusted(review, g) {
                Error(#(reason, turn)) ->
                  quarantine(ctx, game_id, c.number, reason, Some(turn))
                Ok(Nil) -> {
                  ctx.analysis.replace(
                    game_id,
                    c.number,
                    Save(
                      Done,
                      attempts,
                      Some(response),
                      None,
                      Some(page),
                      list.length(g.turns),
                    ),
                  )
                  Reasked(
                    review.timing_ms,
                    reviews.extracted(ctx, game_id, g, room.seats, review),
                  )
                }
              }
          }
      }
    }
  }
}

/// An answer that cannot be trusted is not stored, and is not asked for
/// again until an operator has looked: the same request to the same engine
/// gives the same answer.
fn quarantine(
  ctx: Ctx,
  game_id: String,
  number: Int,
  reason: String,
  turn: Option(Int),
) -> Outcome {
  ctx.analysis.charge(
    game_id,
    number,
    reviews.max_attempts,
    Some("quarantined: " <> reason),
  )
  Quarantined(reason, turn)
}

/// Let the games whose tries are spent be asked again: how many were.
pub fn reset(ctx: Ctx, game_id: String) -> Result(Int, String) {
  use found <- result.try(candidates(ctx, game_id))
  found.candidates
  |> list.filter(spent)
  |> list.map(fn(c) { ctx.analysis.charge(game_id, c.number, 0, None) })
  |> list.length
  |> Ok
}

/// The reasons an answer is quarantined for.
pub const turns_mismatch = "turns_mismatch"

pub const results_missing = "results_missing"

pub const candidate_board_missing = "candidate_board_missing"

pub const cube_probs_missing = "cube_probs_missing"

/// Does the fresh answer hold everything a complete puzzle needs? One
/// result per legal play and a board on every described candidate for
/// each checker play; the chances on every cube verdict. The first turn
/// that falls short names the reason (and the turn, counting from 1).
/// Nothing is guessed at: an answer that falls short is not stored.
pub fn trusted(review: Review, g: GameTurns) -> Result(Nil, #(String, Int)) {
  use pairs <- result.try(
    list.strict_zip(g.turns, review.turns)
    |> result.replace_error(#(turns_mismatch, 0)),
  )
  pairs
  |> list.index_map(fn(pair, i) { #(pair.0, pair.1, i + 1) })
  |> list.try_each(fn(entry) {
    let #(turn, graded, number) = entry
    let danced = analysis.danced(turn)
    use _ <- result.try(case graded.move, turn.dice {
      Some(Moved(played, best, top, results, n_legal, ..)), Some(_) if !danced -> {
        use _ <- result.try(
          case n_legal > 0 && list.length(results) == n_legal {
            True -> Ok(Nil)
            False -> Error(#(results_missing, number))
          },
        )
        case list.all([played, best, ..top], fn(c) { c.board != [] }) {
          True -> Ok(Nil)
          False -> Error(#(candidate_board_missing, number))
        }
      }
      _, _ -> Ok(Nil)
    })
    case graded.cube {
      Some(report.CubeReview(probs: None, ..)) ->
        Error(#(cube_probs_missing, number))
      _ -> Ok(Nil)
    }
  })
}

fn game(games: List(GameTurns), number: Int) -> Result(GameTurns, Nil) {
  list.find(games, fn(g) { g.number == number })
}
