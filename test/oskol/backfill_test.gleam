//// The puzzles backfill on stub capabilities: which stored answers are
//// old, what a fresh answer must hold to be trusted, which games of a
//// room are asked again, and what a re-ask writes -- in what order -- when
//// the engine answers, when its answer cannot be trusted, and when it does
//// not answer. Games are real (seeded backgammon, replayed from a log);
//// the engine and every row are stubs.

import backgammon/analysis
import backgammon/engine as bg_engine
import backgammon/game as backgammon
import gamekit/clock
import gamekit/conformance
import gamekit/game
import gamekit/instance
import gamekit/rng.{type Rng}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/analysis.{
  type GameLog, type Stored, AnalysisCaps, Done, GameLog, LogEntry, Pending,
  Stored,
} as caps
import oskol/caps/puzzles as puzzles_caps
import oskol/caps/records as records_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/fakes
import oskol/handlers/backfill
import oskol/handlers/reviews
import oskol/puzzles/extract
import oskol/reviews/report

// ---------- The predicate: is a stored answer old? ----------

fn candidate(board: List(Int)) -> report.Candidate {
  report.Candidate(
    rank: 1,
    notation: "8/5 6/5",
    equity: 0.1,
    equity_diff: 0.0,
    probs: report.Probs(0.5, 0.1, 0.0, 0.1, 0.0),
    board: board,
  )
}

fn moved(
  results: List(report.MoveResult),
  board: List(Int),
) -> report.MoveReview {
  report.Moved(
    played: candidate(board),
    best: candidate(board),
    top: [candidate(board)],
    results: results,
    n_legal: 2,
    forced: False,
    error: 0.0,
    grade: "best",
  )
}

fn turn(
  index: Int,
  move: Option(report.MoveReview),
  cube: Option(report.CubeReview),
) -> report.TurnReview {
  report.TurnReview(index: index, cube: cube, move: move, luck: None)
}

fn cube(probs: Option(report.Probs)) -> report.CubeReview {
  report.CubeReview(
    action: "no_double",
    response: None,
    optimal: "No Double",
    no_double: 0.3,
    double_take: 0.2,
    double_pass: 1.0,
    probs: probs,
    doubler: report.Verdict(0.0, "best", None),
    taker: None,
  )
}

fn review(turns: List(report.TurnReview)) -> report.Review {
  report.Review(
    turns: turns,
    players: [],
    levels: Some(report.Levels("4ply", "4ply")),
    timing_ms: Some(100),
  )
}

const board = [1, 2, 3]

fn two_results() -> List(report.MoveResult) {
  [report.MoveResult(board, 0.0), report.MoveResult(board, -0.1)]
}

pub fn a_move_without_results_is_old_test() {
  assert backfill.old_contract(review([turn(0, Some(moved([], board)), None)]))
}

pub fn a_move_with_results_is_new_test() {
  assert !backfill.old_contract(
    review([turn(0, Some(moved(two_results(), board)), None)]),
  )
}

pub fn one_old_move_among_new_ones_is_old_test() {
  assert backfill.old_contract(
    review([
      turn(0, Some(moved(two_results(), board)), None),
      turn(1, Some(moved([], board)), None),
    ]),
  )
}

pub fn a_dance_says_nothing_either_way_test() {
  // An old dance and a new dance decode the same; only a checker play
  // that was evaluated can say which engine graded it.
  assert !backfill.old_contract(review([turn(0, Some(report.Danced), None)]))
}

pub fn a_cube_only_turn_says_nothing_either_way_test() {
  assert !backfill.old_contract(
    review([
      turn(0, None, Some(cube(Some(report.Probs(0.5, 0.1, 0.0, 0.1, 0.0))))),
    ]),
  )
  assert !backfill.old_contract(review([turn(0, None, Some(cube(None)))]))
}

pub fn the_extraction_reads_an_old_move_the_same_way_test() {
  assert extract.before_results(moved([], board))
  assert !extract.before_results(moved(two_results(), board))
  assert !extract.before_results(report.Danced)
}

// ---------- A fresh answer that can be trusted ----------

fn a_game(turns: List(analysis.Turn)) -> analysis.GameTurns {
  analysis.GameTurns(number: 1, finished: True, jacoby: False, turns: turns)
}

fn a_turn(dice: Option(#(Int, Int)), played: Option(List(Int))) -> analysis.Turn {
  analysis.Turn(
    player: 0,
    player_id: "p1",
    position: analysis.Position(
      board: [0, 0, 0],
      cube_value: 1,
      cube_owner: "centered",
      away1: 0,
      away2: 0,
      crawford: False,
    ),
    double: None,
    dice: dice,
    played: played,
    log_index: 0,
    entry: Some(0),
    double_entry: None,
    answer_entry: None,
  )
}

fn played_turn() -> analysis.Turn {
  a_turn(Some(#(3, 1)), Some(board))
}

pub fn a_complete_answer_is_trusted_test() {
  let g = a_game([played_turn(), played_turn()])
  let probs = Some(report.Probs(0.5, 0.1, 0.0, 0.1, 0.0))
  assert backfill.trusted(
      review([
        turn(0, Some(moved(two_results(), board)), None),
        turn(1, Some(moved(two_results(), board)), Some(cube(probs))),
      ]),
      g,
    )
    == Ok(Nil)
}

pub fn results_that_do_not_cover_every_legal_play_are_not_trusted_test() {
  let g = a_game([played_turn(), played_turn()])
  assert backfill.trusted(
      review([
        turn(0, Some(moved(two_results(), board)), None),
        turn(1, Some(moved([report.MoveResult(board, 0.0)], board)), None),
      ]),
      g,
    )
    == Error(#(backfill.results_missing, 2))
}

pub fn a_candidate_without_its_board_is_not_trusted_test() {
  let g = a_game([played_turn()])
  assert backfill.trusted(
      review([turn(0, Some(moved(two_results(), [])), None)]),
      g,
    )
    == Error(#(backfill.candidate_board_missing, 1))
}

pub fn a_cube_verdict_without_its_chances_is_not_trusted_test() {
  let g = a_game([played_turn()])
  assert backfill.trusted(
      review([turn(0, Some(moved(two_results(), board)), Some(cube(None)))]),
      g,
    )
    == Error(#(backfill.cube_probs_missing, 1))
}

pub fn a_dance_and_a_cube_only_turn_need_no_results_test() {
  // A dance: the played board is the one the turn began on.
  let danced = a_turn(Some(#(6, 6)), Some([0, 0, 0]))
  let cube_only = a_turn(None, None)
  let g = a_game([danced, cube_only])
  let probs = Some(report.Probs(0.5, 0.1, 0.0, 0.1, 0.0))
  assert backfill.trusted(
      review([
        turn(0, Some(report.Danced), None),
        turn(1, None, Some(cube(probs))),
      ]),
      g,
    )
    == Ok(Nil)
}

pub fn an_answer_for_another_number_of_turns_is_not_trusted_test() {
  let g = a_game([played_turn()])
  assert backfill.trusted(review([]), g) == Error(#(backfill.turns_mismatch, 0))
}

// ---------- A real room, as the database holds it ----------

fn finished_log(seed: Int) -> GameLog {
  let seats = [game.Seat("p1", "Alice"), game.Seat("p2", "Bob")]
  let assert Ok(running) =
    instance.begin(backgammon.game(), "single", seats, seed, clock.NoClock, 0)
  let entries = play(running, rng.seed(seed), 3000, [])
  GameLog(
    slug: "backgammon",
    format: "single",
    clock: "none",
    seed: seed,
    seats: [#("p1", "Alice"), #("p2", "Bob")],
    entries: entries,
    record_generation: 0,
  )
}

fn play(running, chooser: Rng, left: Int, entries) {
  let s = instance.running_state(running)
  let choices =
    list.flat_map(["p1", "p2"], fn(id) {
      bg_engine.legal(s, id)
      |> list.filter(fn(schema) { schema.name != "resign" })
      |> list.map(fn(schema) { #(id, schema) })
    })
  let over = instance.running_outcome(running) != game.Ongoing
  case left == 0 || over, rng.pick(chooser, choices) {
    False, Ok(#(#(player_id, schema), chooser)) -> {
      let #(text, chooser) = conformance.build_action(schema, chooser)
      let assert Ok(raw) = conformance.parse(text)
      let at = list.length(entries) * 1000
      let assert Ok(#(next, _)) = instance.step(running, player_id, raw, at)
      play(next, chooser, left - 1, [
        LogEntry("action", Some(player_id), text, at),
        ..entries
      ])
    }
    _, _ -> list.reverse(entries)
  }
}

fn the_game(log: GameLog) -> analysis.GameTurns {
  let assert Ok([g]) = reviews.games(log)
  g
}

/// An engine answer for these turns: every candidate is the move that was
/// played, board and all, and -- when `complete` -- a result for each of
/// the `n_legal` plays. Every move is a mistake worth 0.05, so a complete
/// answer writes a puzzle per checker play.
fn answer_for(turns: List(analysis.Turn), complete: Bool) -> String {
  let n_legal = 3
  let candidate = fn(rank, board, diff) {
    "{\"rank\":"
    <> int.to_string(rank)
    <> ",\"notation\":\"8/5 6/5\",\"board\":"
    <> board
    <> ",\"equity\":0.1,\"equity_diff\":"
    <> diff
    <> ",\"probs\":{\"win\":0.5,\"gammon_win\":0.1,\"backgammon_win\":0,\"gammon_loss\":0.1,\"backgammon_loss\":0}}"
  }
  let turn = fn(t: analysis.Turn, i) {
    let board =
      json.to_string(json.array(option.unwrap(t.played, []), json.int))
    let move = case t.dice, analysis.danced(t) {
      None, _ -> "null"
      Some(_), True -> "{\"danced\":true,\"n_legal\":0}"
      Some(_), False ->
        "{\"played\":"
        <> candidate(2, board, "-0.05")
        <> ",\"best\":"
        <> candidate(1, board, "0")
        <> ",\"top\":["
        <> candidate(1, board, "0")
        <> ","
        <> candidate(2, board, "-0.05")
        <> "],"
        <> case complete {
          True ->
            "\"results\":["
            <> string.join(
              list.repeat(
                "{\"board\":" <> board <> ",\"equity_diff\":0}",
                n_legal,
              ),
              ",",
            )
            <> "],"
          False -> ""
        }
        <> "\"n_legal\":"
        <> int.to_string(n_legal)
        <> ",\"forced\":false,\"error\":0.05,\"grade\":\"doubtful\"}"
    }
    "{\"index\":"
    <> int.to_string(i)
    <> ",\"cube\":null,\"move\":"
    <> move
    <> ",\"luck\":null}"
  }
  let totals =
    "{\"moves\":{\"decisions\":3,\"forced\":1,\"error\":0,\"grades\":{}},\"cube\":{\"decisions\":0,\"error\":0,\"mistakes\":{}},\"luck\":0,\"error\":0,\"pr\":0}"
  "{\"levels\":{\"move\":\"4ply\",\"cube\":\"4ply\"},\"timing_ms\":4321,\"turns\":["
  <> string.join(list.index_map(turns, turn), ",")
  <> "],\"players\":["
  <> totals
  <> ","
  <> totals
  <> "]}"
}

fn row(
  number: Int,
  status: caps.Status,
  attempts: Int,
  body: Option(String),
  turns: Int,
) -> Stored {
  Stored(
    game_number: number,
    status: status,
    attempts: attempts,
    response_json: body,
    answered: body != None,
    rendered: True,
    turns: turns,
  )
}

// ---------- Recording what the stubs were asked ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

fn record_call(key: String, value: String) -> Nil {
  let _ = put(key, [value, ..newest_first(key)])
  Nil
}

fn newest_first(key: String) -> List(String) {
  case decode.run(get(key), decode.list(decode.string)) {
    Ok(values) -> values
    Error(_) -> []
  }
}

/// What the stubs were asked, in the order they were asked.
fn recorded(key: String) -> List(String) {
  list.reverse(newest_first(key))
}

/// A room whose log is `log`, whose review rows are `stored`, and whose
/// engine answers with `answer`. Every write records itself under "calls",
/// in order.
fn with_room(
  log: GameLog,
  stored: List(Stored),
  answer: fn(String) -> Result(String, String),
) -> Ctx {
  let _ = put("calls", [])
  Ctx(
    ..fakes.ctx(),
    analysis: AnalysisCaps(
      ..caps.stub(),
      log: fn(id) {
        case id {
          "123456" -> Some(log)
          _ -> None
        }
      },
      stored: fn(_) { stored },
      backfill_turns: fn(_, _, _) { Nil },
      replace: fn(_, number, save: caps.Save) {
        record_call(
          "calls",
          "replace "
            <> int.to_string(number)
            <> " attempts="
            <> int.to_string(save.attempts)
            <> case save.response_json, save.report_json {
            Some(_), Some(_) -> " with answer and page"
            _, _ -> " without"
          },
        )
      },
      charge: fn(_, number, attempts, error) {
        record_call(
          "calls",
          "charge "
            <> int.to_string(number)
            <> " attempts="
            <> int.to_string(attempts)
            <> " "
            <> option.unwrap(error, "-"),
        )
      },
      review: fn(body) {
        record_call("calls", "engine")
        answer(body)
      },
    ),
    puzzles: puzzles_caps.PuzzlesCaps(
      ..puzzles_caps.stub(),
      store: fn(_, number, puzzles, sources) {
        record_call(
          "calls",
          "store "
            <> int.to_string(number)
            <> " "
            <> int.to_string(list.length(puzzles))
            <> " puzzles "
            <> int.to_string(list.length(sources))
            <> " sources",
        )
        Ok(puzzles_caps.Written(list.length(puzzles), 1, list.length(sources)))
      },
    ),
    records: records_caps.RecordsCaps(
      ..records_caps.stub(),
      save: fn(_, _, _, _) { Nil },
    ),
  )
}

fn old_answer(log: GameLog) -> String {
  answer_for(the_game(log).turns, False)
}

fn fresh_answer(log: GameLog) -> String {
  answer_for(the_game(log).turns, True)
}

// ---------- Which games are asked again ----------

pub fn only_a_done_game_with_an_old_answer_is_a_candidate_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(
      log,
      [
        row(1, Done, 1, Some(old_answer(log)), turns),
        // The same game's rows under other numbers: not this room's games,
        // so never candidates however old.
        row(2, Done, 1, Some(fresh_answer(log)), turns),
        row(3, Pending, 1, None, turns),
        row(4, Done, 1, Some("not json"), turns),
      ],
      fn(_) { panic as "a dry run never asks the engine" },
    )
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  assert c.number == 1
  assert c.turns == turns
  assert c.attempts == 1
  assert c.levels == Some(report.Levels("4ply", "4ply"))
  assert found.unreadable == [4]
  assert recorded("calls") == []
}

pub fn a_new_answer_is_left_alone_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(log, [row(1, Done, 1, Some(fresh_answer(log)), turns)], fn(_) {
      panic as "nothing to ask"
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  assert found.candidates == []
}

pub fn a_game_whose_tries_are_spent_waits_for_a_reset_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(log, [row(1, Done, 3, Some(old_answer(log)), turns)], fn(_) {
      panic as "nothing to ask"
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  assert backfill.spent(c)
  assert backfill.reset(ctx, "123456") == Ok(1)
  assert recorded("calls") == ["charge 1 attempts=0 -"]
}

pub fn a_room_that_is_not_there_is_an_error_test() {
  let ctx = with_room(finished_log(3), [], fn(_) { panic as "nothing" })
  let assert Error(_) = backfill.candidates(ctx, "999999")
}

// ---------- What a re-ask writes ----------

pub fn a_reask_asks_at_the_stored_levels_with_every_result_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let _ = put("request", "")
  let ctx =
    with_room(log, [row(1, Done, 1, Some(old_answer(log)), turns)], fn(body) {
      let _ = put("request", body)
      Ok(fresh_answer(log))
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  let assert backfill.Reasked(Some(4321), Ok(written)) =
    backfill.reask(ctx, "123456", found.room, c)
  let assert Ok(request) = decode.run(get("request"), decode.string)
  assert string.contains(request, "\"all_results\":true")
  assert string.contains(request, "\"move_level\":\"4ply\"")
  assert string.contains(request, "\"cube_level\":\"4ply\"")
  // The fresh answer lands with the game reopened, then is extracted.
  assert recorded("calls")
    == [
      "engine",
      "replace 1 attempts=2 with answer and page",
      "store 1 "
        <> int.to_string(written.puzzles)
        <> " puzzles "
        <> int.to_string(written.sources)
        <> " sources",
    ]
  // Every checker play was a mistake, so every one is a puzzle now.
  let mistakes =
    the_game(log).turns
    |> list.filter(fn(t) { t.dice != None && !analysis.danced(t) })
    |> list.length
  assert written.puzzles > 0
  assert written.sources == mistakes
}

pub fn an_answer_that_cannot_be_trusted_is_quarantined_and_charged_to_the_limit_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(log, [row(1, Done, 1, Some(old_answer(log)), turns)], fn(_) {
      // The same old shape again: no results.
      Ok(old_answer(log))
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  assert backfill.reask(ctx, "123456", found.room, c)
    == backfill.Quarantined(backfill.results_missing, Some(1))
  assert recorded("calls")
    == ["engine", "charge 1 attempts=3 quarantined: results_missing"]
}

pub fn an_answer_that_does_not_render_is_quarantined_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(log, [row(1, Done, 1, Some(old_answer(log)), turns)], fn(_) {
      Ok("{\"turns\":[],\"players\":[]}")
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  let assert backfill.Quarantined(_, None) =
    backfill.reask(ctx, "123456", found.room, c)
  assert list.length(recorded("calls")) == 2
}

pub fn an_engine_failure_is_charged_once_and_nothing_else_moves_test() {
  let log = finished_log(3)
  let turns = list.length(the_game(log).turns)
  let ctx =
    with_room(log, [row(1, Done, 1, Some(old_answer(log)), turns)], fn(_) {
      Error("connection refused")
    })
  let assert Ok(found) = backfill.candidates(ctx, "123456")
  let assert [c] = found.candidates
  assert backfill.reask(ctx, "123456", found.room, c)
    == backfill.EngineFailed("connection refused")
  assert recorded("calls")
    == ["engine", "charge 1 attempts=2 connection refused"]
}
