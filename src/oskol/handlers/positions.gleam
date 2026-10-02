//// Sharing a position out of a replay:
////
////     POST /papi/games/:slug/rooms/:id/positions  {game, step}
////       -> {ok, id, url}   url is "/puzzles/<id>"
////
//// **A shared replay step is a puzzle row**, the same link a position set
//// up on the analysis board shares: a page that unfurls with the board and
//// the question, names nobody, and can be played on the spot. The row is
//// written from what the game already left behind -- the record gives the
//// position, the dice, the cube and the score; the stored review gives the
//// engine's answer for that turn -- so **a share never spends engine
//// time**. A step the review has no answer for yet waits (`not_graded`);
//// nothing here can ask the engine anything.
////
//// **Who may share**: anyone who can read the replay, which is anyone with
//// the room's link (`handlers/record`: a record is every committed turn,
//// which both players and any spectator saw). No seat is asked for. What a
//// share adds to that is a puzzle row that names nobody and a link back to
//// the replay that link already opened.
////
//// **Nobody's practice.** A share writes no `puzzle_sources` row: it is not
//// anybody's mistake, so it enters no deck and no story can be minted on it
//// (`handlers/shares` mints only on a source the caller's seat made). A
//// mistake shared this way has the same question as the puzzle the review
//// job wrote for it, so it lands on that very row, which keeps its origin
//// and its sources. Origin "replay" keeps a new row out of TRY ONE.
////
//// Only rows are read: the room's setup, its finished games' records and
//// one game's stored review. No log is replayed and no room is woken.

import backgammon/analysis.{type Turn}
import backgammon/game as backgammon
import backgammon/record.{type Entry}
import gamekit/game
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/caps/analysis.{Done, Stored} as _analysis_caps
import oskol/caps/puzzles.{ReplayLink} as _puzzle_caps
import oskol/caps/records
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/handlers/record as record_page
import oskol/practice/openings
import oskol/puzzles.{type Answer, type Kind, type Question}
import oskol/puzzles/extract
import oskol/reviews/report.{type TurnReview}

/// What a shared replay step's puzzle row says about where it came from.
/// Never in TRY ONE (`Oskol.Puzzles.sample/1`).
pub const origin = "replay"

/// The only game with a review behind its replay.
const slug = "backgammon"

pub const bad_request_message = "Say which game and which step"

/// The step's game has no answer from the engine yet: the game is still
/// on the board, or its review is pending or failed.
pub const not_graded_code = "not_graded"

pub const not_graded_message = "This position will be shareable once the game is graded."

/// The stored answer for this step is short of something a puzzle needs:
/// every legal play (an answer from before the engine sent them all), or
/// the cube's chances.
pub const incomplete_code = "incomplete"

pub const incomplete_message = "This position's answer is incomplete; open it in the analysis board instead."

/// The step is no decision anyone could be asked about: the opening
/// position, a resignation, the result, a roll with one way to play it or
/// none, or a double the engine does not grade (a dead cube).
pub const no_decision_code = "no_decision"

pub const no_decision_message = "There is no decision to share at this step."

/// One step of one game of the room.
pub type Asked {
  Asked(game: Int, step: Int)
}

fn asked_decoder() -> decode.Decoder(Asked) {
  use game <- decode.field("game", decode.int)
  use step <- decode.field("step", decode.int)
  decode.success(Asked(game, step))
}

/// The whole POST: the body read, the step shared, the envelope.
pub fn share_json(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
  body_json: String,
) -> Result(String, ApiError) {
  use asked <- result.try(
    json.parse(body_json, asked_decoder())
    |> result.replace_error(error.validation_failed(bad_request_message)),
  )
  use id <- result.try(share(ctx, game_slug, game_id, asked.game, asked.step))
  Ok(
    envelope.ok([
      #("id", json.string(id)),
      #("url", json.string("/puzzles/" <> id)),
    ]),
  )
}

/// Share one step of one game: the id of the puzzle that stands for it.
pub fn share(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
  number: Int,
  step: Int,
) -> Result(String, ApiError) {
  let not_found = error.NotFound(record_page.not_found_message)
  use setup <- result.try(case game_slug == slug, ctx.records.setup(game_id) {
    True, Some(setup) if setup.slug == slug -> Ok(setup)
    _, _ -> Error(not_found)
  })
  use #(target, jacoby) <- result.try(
    rules(setup.format) |> result.replace_error(not_found),
  )
  let games = finished_games(ctx.records.stored(game_id))
  use entries <- result.try(game_entries(setup, games, number))
  use entry <- result.try(case step {
    // The position the game opened from: nobody has rolled.
    0 -> Error(no_decision())
    _ if step < 0 -> Error(not_found)
    _ ->
      list.drop(entries, step - 1)
      |> list.first
      |> result.replace_error(not_found)
  })
  use kind <- result.try(case entry {
    record.Turn(..) -> Ok(puzzles.Move)
    record.Double(..) -> Ok(puzzles.Double)
    record.Take(..) | record.Drop(..) -> Ok(puzzles.Take)
    record.Resign(..) | record.GameOver(..) -> Error(no_decision())
  })
  use graded <- result.try(review_of(ctx, game_id, number))
  let #(scores_before, crawford) = match_state(games, number, target)
  let turns =
    analysis.turns_from_record(
      entries,
      list.map(setup.seats, fn(s) { s.0 }),
      target,
      scores_before,
      crawford,
    )
  use pairs <- result.try(
    list.strict_zip(turns, graded.turns)
    // The answer is not this game's: the review job will have said so on
    // its row, and there is nothing here to share from.
    |> result.replace_error(not_graded()),
  )
  use #(question, answer) <- result.try(decision(pairs, kind, step - 1, jacoby))
  use id <- result.try(
    ctx.puzzles.store_one(
      openings.new_puzzle(question, answer, graded.levels),
      origin,
      Some(ReplayLink(slug: slug, id: game_id, game: number, step: step)),
    )
    |> result.map_error(error.Internal),
  )
  ctx.puzzles.pictures_one(id)
  Ok(id)
}

/// The match length and whether gammons need a turned cube, from the
/// room's format (`backgammon/game.info`).
fn rules(format: String) -> Result(#(Int, Bool), Nil) {
  backgammon.info().formats
  |> list.find(fn(f) { f.id == format })
  |> result.map(fn(f) {
    #(
      game.config_get(f.config, "target", 1),
      game.config_get(f.config, "jacoby", 0) == 1,
    )
  })
}

/// The room's finished games, by number, oldest first, each read back
/// into record lines. A row that does not read is left out.
fn finished_games(rows: List(records.StoredRecord)) -> List(#(Int, List(Entry))) {
  rows
  |> list.filter_map(fn(row) {
    json.parse(row.entries_json, decode.list(record.decoder()))
    |> result.map(fn(entries) { #(row.game_number, entries) })
    |> result.replace_error(Nil)
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

/// One finished game's lines. The game after the last one written down is
/// the one on the board (or one that has just ended and is not written
/// yet): it has no answer to share from, so it waits. Any other number
/// names nothing.
fn game_entries(
  setup: records.Setup,
  games: List(#(Int, List(Entry))),
  number: Int,
) -> Result(List(Entry), ApiError) {
  case list.key_find(games, number) {
    Ok(entries) -> Ok(entries)
    Error(_) -> {
      let next = list.length(games) + 1
      case number == next && { !setup.finished || setup.records_stale } {
        True -> Error(not_graded())
        False -> Error(error.NotFound(record_page.not_found_message))
      }
    }
  }
}

/// The score this game began at (the result line of the game before it)
/// and whether it is the Crawford game, by the rule the match applies
/// (`record.crawford_game`) over every game's starting score so far.
fn match_state(
  games: List(#(Int, List(Entry))),
  number: Int,
  target: Int,
) -> #(List(#(String, Int)), Bool) {
  let befores =
    games
    |> list.filter(fn(g) { g.0 < number })
    |> list.fold([[]], fn(befores, g) {
      list.append(befores, [scores_after(g.1, befores)])
    })
  let before = list.last(befores) |> result.unwrap([])
  #(before, record.crawford_game(target, befores))
}

fn scores_after(
  entries: List(Entry),
  befores: List(List(#(String, Int))),
) -> List(#(String, Int)) {
  let found =
    list.find_map(entries, fn(e) {
      case e {
        record.GameOver(scores: scores, ..) -> Ok(scores)
        _ -> Error(Nil)
      }
    })
  case found {
    Ok(scores) -> scores
    Error(_) -> list.last(befores) |> result.unwrap([])
  }
}

/// The game's stored answer, when the review is done.
fn review_of(
  ctx: Ctx,
  game_id: String,
  number: Int,
) -> Result(report.Review, ApiError) {
  case ctx.analysis.stored_one(game_id, number) {
    Some(Stored(status: Done, response_json: Some(text), ..)) ->
      report.parse(text) |> result.replace_error(not_graded())
    _ -> Error(not_graded())
  }
}

/// The question the step asks and the engine's answer to it, from the turn
/// whose line it is. A roll's line is the checker play on the board before
/// it; a double's, the doubler's call; a take's or a drop's, the answer to
/// the double. Each is the question `extract` asks of a mistake there
/// (`puzzles.question_of` on the same turn), so a mistake shared this way
/// is the puzzle already written for it.
fn decision(
  pairs: List(#(Turn, TurnReview)),
  kind: Kind,
  line: Int,
  jacoby: Bool,
) -> Result(#(Question, Answer), ApiError) {
  let on_line = fn(turn: Turn) {
    case kind {
      puzzles.Move -> turn.entry
      puzzles.Double -> turn.double_entry
      puzzles.Take -> turn.answer_entry
    }
    == Some(line)
  }
  use #(turn, graded) <- result.try(
    list.find(pairs, fn(pair) { on_line(pair.0) })
    // A double the engine does not grade was folded away (`settle`): no
    // turn names its line.
    |> result.replace_error(no_decision()),
  )
  case kind {
    puzzles.Move -> move_decision(turn, graded, jacoby)
    _ -> cube_decision(turn, graded, kind, jacoby)
  }
}

fn move_decision(
  turn: Turn,
  graded: TurnReview,
  jacoby: Bool,
) -> Result(#(Question, Answer), ApiError) {
  use _ <- result.try(case graded.move, analysis.danced(turn) {
    None, _ -> Error(not_graded())
    Some(report.Danced), _ | _, True -> Error(no_decision())
    Some(report.Moved(forced: True, ..)), _ -> Error(no_decision())
    Some(report.Moved(..)), False -> Ok(Nil)
  })
  // Every legal play and a board on every candidate, or nothing: the rule
  // the analysis board and the built sets trust an answer by. An answer
  // from before the engine sent every play -- and so a play after a take
  // graded on the old cube -- fails it.
  use answer <- result.try(
    openings.answer(graded) |> result.replace_error(incomplete()),
  )
  Ok(#(
    puzzles.question_of(puzzles.Move, turn.position, turn.dice, jacoby),
    answer,
  ))
}

fn cube_decision(
  turn: Turn,
  graded: TurnReview,
  kind: Kind,
  jacoby: Bool,
) -> Result(#(Question, Answer), ApiError) {
  case graded.cube {
    None -> Error(not_graded())
    Some(cube) ->
      case extract.cube_answer(cube) {
        puzzles.CubeAnswer(probs: Some(_), ..) as answer ->
          Ok(#(puzzles.question_of(kind, turn.position, None, jacoby), answer))
        _ -> Error(incomplete())
      }
  }
}

fn not_graded() -> ApiError {
  error.Conflict(not_graded_code, not_graded_message)
}

fn incomplete() -> ApiError {
  error.Conflict(incomplete_code, incomplete_message)
}

fn no_decision() -> ApiError {
  error.Conflict(no_decision_code, no_decision_message)
}
