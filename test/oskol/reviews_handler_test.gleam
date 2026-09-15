//// Post-game reviews on stub capabilities: when a room asks for one, what
//// the queue's job does with the engine's answer, and what the page reads.
//// Games are real (seeded backgammon, replayed from their logs); the
//// engine, the queue and the table are stubs.

import backgammon/engine as bg_engine
import backgammon/game as backgammon
import gamekit/clock
import gamekit/conformance
import gamekit/event
import gamekit/game
import gamekit/instance
import gamekit/rng.{type Rng}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/analysis.{
  type GameLog, type Stored, AnalysisCaps, Done, Failed, GameLog, LogEntry,
  Pending, Stored,
} as caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/reviews

// ---------- A real game, as the database holds it ----------

/// A seeded single game played at random (never resigning) to the end,
/// with its log as `game_actions` rows.
fn finished_log(seed: Int) -> GameLog {
  played_log("single", seed, 3000)
}

fn played_log(format: String, seed: Int, steps: Int) -> GameLog {
  let seats = [game.Seat("p1", "Alice"), game.Seat("p2", "Bob")]
  let assert Ok(running) =
    instance.begin(backgammon.game(), format, [], seats, seed, clock.NoClock, 0)
  let entries = play(running, rng.seed(seed), steps, [])
  GameLog(
    slug: "backgammon",
    format: format,
    selections: [],
    clock: "none",
    seed: seed,
    seats: [#("p1", "Alice"), #("p2", "Bob")],
    entries: entries,
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

fn turn_count(log: GameLog, number: Int) -> Int {
  let assert Ok(games) = reviews.games(log)
  let assert Ok(g) = list.find(games, fn(g) { g.number == number })
  list.length(g.turns)
}

/// An engine answer with `n` turns: every move doubtful, no cube, a little
/// luck, the shape of the engine's README.
fn engine_answer(n: Int) -> String {
  let candidate = fn(rank, diff) {
    "{\"rank\":"
    <> int.to_string(rank)
    <> ",\"notation\":\"8/5 6/5\",\"board\":[],\"equity\":0.1,\"cubeless_equity\":0.1,\"equity_diff\":"
    <> diff
    <> ",\"probs\":{\"win\":0.5,\"gammon_win\":0.1,\"backgammon_win\":0,\"gammon_loss\":0.1,\"backgammon_loss\":0}}"
  }
  let turn = fn(i) {
    "{\"index\":"
    <> int.to_string(i)
    <> ",\"player\":0,\"dice\":[3,1],\"cube\":null,\"move\":{\"played\":"
    <> candidate(2, "-0.05")
    <> ",\"best\":"
    <> candidate(1, "0.0")
    <> ",\"top\":["
    <> candidate(1, "0")
    <> ","
    <> candidate(2, "-0.05")
    <> "],\"n_legal\":9,\"forced\":false,\"error\":0.05,\"grade\":\"doubtful\",\"eval_level\":\"2-ply\"},\"luck\":{\"luck\":0.25,\"actual_equity\":0.3,\"average_equity\":0.05,\"level_label\":\"3-ply\"}}"
  }
  let totals =
    "{\"moves\":{\"decisions\":3,\"forced\":1,\"error\":0.15,\"grades\":{\"doubtful\":3}},\"cube\":{\"decisions\":0,\"error\":0.0,\"mistakes\":{}},\"luck\":0.5,\"error\":0.15,\"pr\":25.0}"
  "{\"levels\":{\"moves\":\"2ply\",\"cube\":\"3ply\"},\"turns\":["
  <> string.join(list.map(list.range(0, n - 1), turn), ",")
  <> "],\"players\":["
  <> totals
  <> ","
  <> totals
  <> "]}"
}

// ---------- Recording what the stubs were asked ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

fn record(key: String, value: String) -> Nil {
  let _ = put(key, [value, ..recorded(key)])
  Nil
}

fn recorded(key: String) -> List(String) {
  case decode.run(get(key), decode.list(decode.string)) {
    Ok(values) -> values
    Error(_) -> []
  }
}

fn forget(key: String) -> Nil {
  let _ = put(key, [])
  Nil
}

fn status_name(status: caps.Status) -> String {
  case status {
    Pending -> "pending"
    Done -> "done"
    Failed -> "failed"
  }
}

/// Analysis caps over one room: its log, what is stored, and an engine
/// that answers `answer` to every request. Saves and enqueues are recorded.
fn with_analysis(
  log: GameLog,
  stored: List(Stored),
  answer: fn(String) -> Result(String, String),
) -> Ctx {
  forget("saves")
  forget("enqueued")
  forget("requests")
  Ctx(
    ..fakes.ctx(),
    analysis: AnalysisCaps(
      log: fn(id) {
        case id {
          "123456" -> Some(log)
          _ -> None
        }
      },
      stored: fn(_) { stored },
      save: fn(_, number, status, attempts, response, _error) {
        record(
          "saves",
          int.to_string(number)
            <> ":"
            <> status_name(status)
            <> ":"
            <> int.to_string(attempts)
            <> ":"
            <> case response {
            Some(_) -> "body"
            None -> "none"
          },
        )
      },
      enqueue: fn(id) { record("enqueued", id) },
      review: fn(body) {
        record("requests", body)
        answer(body)
      },
    ),
  )
}

fn no_engine(_body: String) -> Result(String, String) {
  panic as "the engine should not be asked"
}

// ---------- When the room asks ----------

pub fn a_won_backgammon_game_asks_for_a_review_test() {
  let won = event.Custom("game_won", json.object([]))
  assert reviews.game_ended("backgammon", [won])
  assert reviews.game_ended("backgammon", [event.PhaseChanged("game_over")])
  assert !reviews.game_ended("backgammon", [])
  assert !reviews.game_ended("backgammon", [event.Message("hello")])
  // No engine for other games
  assert !reviews.game_ended("poker", [won, event.PhaseChanged("game_over")])
}

// ---------- The queue's job ----------

pub fn a_finished_game_is_reviewed_and_stored_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx = with_analysis(log, [], fn(_) { Ok(engine_answer(n)) })
  assert reviews.run(ctx, "123456") == None
  // Marked pending before the call, done with the body after, in order
  assert list.reverse(recorded("saves"))
    == ["1:pending:0:none", "1:done:1:body"]
  let assert [request] = recorded("requests")
  assert string.contains(request, "\"turns\":[{\"player\":")
  assert string.contains(request, "\"move_level\":\"2ply\"")
}

pub fn a_failed_call_is_recorded_and_retried_with_backoff_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [], fn(_) { Error("HTTP 503") })
  assert reviews.run(ctx, "123456") == Some(30_000)
  assert list.reverse(recorded("saves"))
    == ["1:pending:0:none", "1:failed:1:none"]
  // The second failure waits longer
  let ctx =
    with_analysis(log, [Stored(1, Failed, 1, None)], fn(_) { Error("timeout") })
  assert reviews.run(ctx, "123456") == Some(120_000)
  // The third is the last: failed for good, no retry
  let ctx =
    with_analysis(log, [Stored(1, Failed, 2, None)], fn(_) { Error("timeout") })
  assert reviews.run(ctx, "123456") == None
  assert list.reverse(recorded("saves"))
    == ["1:pending:2:none", "1:failed:3:none"]
}

pub fn an_answer_that_does_not_read_is_a_failure_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [], fn(_) { Ok("{\"detail\":\"nope\"}") })
  assert reviews.run(ctx, "123456") == Some(30_000)
  assert list.reverse(recorded("saves"))
    == ["1:pending:0:none", "1:failed:1:none"]
}

pub fn a_game_done_or_given_up_is_never_run_again_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [Stored(1, Done, 1, Some("{}"))], no_engine)
  assert reviews.run(ctx, "123456") == None
  let ctx = with_analysis(log, [Stored(1, Failed, 3, None)], no_engine)
  assert reviews.run(ctx, "123456") == None
  assert recorded("saves") == []
}

pub fn a_game_still_being_played_is_not_reviewed_test() {
  let log = played_log("single", 4, 20)
  let ctx = with_analysis(log, [], no_engine)
  assert reviews.run(ctx, "123456") == None
}

pub fn every_game_of_a_match_is_reviewed_on_its_own_test() {
  let log = played_log("match3", 2, 3000)
  let assert Ok(games) = reviews.games(log)
  assert list.length(games) >= 2
  let ctx =
    with_analysis(log, [], fn(body) {
      // Each request is one game: its first turn is an opening position
      assert string.contains(
        body,
        "\"board\":[0,-2,0,0,0,0,5,0,3,0,0,0,-5,5,0,0,0,-3,0,-5,0,0,0,0,2,0]",
      )
      Error("down")
    })
  let _ = reviews.run(ctx, "123456")
  let owed =
    list.filter(games, fn(g) { g.finished && g.turns != [] }) |> list.length
  assert list.length(recorded("requests")) == owed
}

// ---------- GET .../reviews ----------

pub fn a_done_review_reads_turn_by_turn_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx =
    with_analysis(log, [Stored(1, Done, 1, Some(engine_answer(n)))], no_engine)
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.starts_with(body, "{\"ok\":true,\"players\":[{\"seat\":0,")
  assert string.contains(body, "\"name\":\"Alice\",\"color\":\"white\"")
  assert string.contains(body, "\"game_number\":1,\"status\":\"done\"")
  // Per player: PR, error, every grade and mistake named even at zero
  assert string.contains(body, "\"pr\":25.0")
  assert string.contains(
    body,
    "\"grades\":{\"best\":0,\"ok\":0,\"doubtful\":3,\"bad\":0,\"very_bad\":0}",
  )
  assert string.contains(
    body,
    "\"mistakes\":{\"missed_double\":0,\"wrong_double\":0,\"wrong_take\":0,\"wrong_pass\":0}",
  )
  // Per turn: the grade, what was played against the best, equity lost
  assert string.contains(body, "\"number\":1,\"log_index\":")
  assert string.contains(body, "\"grade\":\"doubtful\",\"equity_lost\":0.05")
  assert string.contains(body, "\"notation\":\"8/5 6/5\"")
  assert string.contains(body, "\"luck\":0.25")
  // Nothing owed: nothing queued
  assert recorded("enqueued") == []
}

pub fn a_game_with_no_review_yet_is_queued_and_pending_test() {
  // A game finished before reviews existed: the first request asks
  let ctx = with_analysis(finished_log(4), [], no_engine)
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.contains(body, "\"game_number\":1,\"status\":\"pending\"")
  assert string.contains(body, "\"review\":null")
  assert recorded("enqueued") == ["123456"]
}

pub fn a_review_that_gave_up_says_failed_and_is_not_queued_test() {
  let ctx =
    with_analysis(finished_log(4), [Stored(1, Failed, 3, None)], no_engine)
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.contains(body, "\"status\":\"failed\"")
  assert recorded("enqueued") == []
}

pub fn a_retry_still_to_come_is_pending_test() {
  let ctx =
    with_analysis(finished_log(4), [Stored(1, Failed, 1, None)], no_engine)
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.contains(body, "\"status\":\"pending\"")
  // Queued again; the queue itself holds a room that waits on a retry
  assert recorded("enqueued") == ["123456"]
}

pub fn a_review_for_another_game_is_not_rendered_test() {
  // A stored answer with the wrong number of turns is not this game's
  let ctx =
    with_analysis(
      finished_log(4),
      [Stored(1, Done, 1, Some(engine_answer(1)))],
      no_engine,
    )
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.contains(body, "\"status\":\"failed\"")
}

pub fn a_game_being_played_says_playing_test() {
  let ctx = with_analysis(played_log("single", 4, 20), [], no_engine)
  let assert Ok(body) = reviews.reviews_json(ctx, "backgammon", "123456")
  assert string.contains(body, "\"status\":\"playing\"")
  assert recorded("enqueued") == []
}

pub fn only_backgammon_rooms_have_reviews_test() {
  let ctx = with_analysis(finished_log(4), [], no_engine)
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, "poker", "123456")
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, "backgammon", "999999")
  // A code that is a poker room, asked for as backgammon
  let poker = GameLog(..finished_log(4), slug: "poker")
  let ctx = with_analysis(poker, [], no_engine)
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, "backgammon", "123456")
}
