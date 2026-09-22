//// Post-game reviews on stub capabilities: when a room asks for one, what
//// the queue's job does with the engine's answer, and what the page reads.
//// Games are real (seeded backgammon, replayed from their logs); the
//// engine, the queue and the table are stubs.

import backgammon/analysis as bg_analysis
import backgammon/board
import backgammon/engine as bg_engine
import backgammon/game as backgammon
import backgammon/record
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
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/analysis.{
  type GameLog, type Stored, AnalysisCaps, Done, Failed, GameLog, LogEntry,
  Pending, Stored,
} as caps
import oskol/caps/puzzles as puzzles_caps
import oskol/caps/records as records_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/reviews
import oskol/reviews/report
import oskol/rooms/errors

// ---------- A real game, as the database holds it ----------

/// A seeded single game played at random (never resigning) to the end,
/// with its log as `game_actions` rows.
fn finished_log(seed: Int) -> GameLog {
  played_log("single", seed, 3000)
}

fn played_log(format: String, seed: Int, steps: Int) -> GameLog {
  let seats = [game.Seat("p1", "Alice"), game.Seat("p2", "Bob")]
  let assert Ok(running) =
    instance.begin(backgammon.game(), format, seats, seed, clock.NoClock, 0)
  let entries = play(running, rng.seed(seed), steps, [])
  GameLog(
    slug: "backgammon",
    format: format,
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

// ---------- The room, as the database holds it ----------

/// The `games` row behind `finished_log`: a finished backgammon room whose
/// two seats are held by the guests g1 and g2.
fn setup_of(log: GameLog) -> records_caps.Setup {
  records_caps.Setup(
    slug: log.slug,
    format: log.format,
    clock: log.clock,
    seed: log.seed,
    seats: list.index_map(log.seats, fn(seat, index) {
      #(
        seat.0,
        seat.1,
        case index {
          0 -> "g1"
          _ -> "g2"
        },
        "",
      )
    }),
    finished: True,
    records_stale: False,
  )
}

// ---------- Recording what the stubs were asked ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

/// The process dictionary, read back at the type it was written at: the
/// stubs below are a little database, so what a write puts there a read
/// finds. Every key is written before it is read.
/// A review row as the little database holds it: the row, and the rendered
/// page beside it (its own column, fetched on its own).
pub type Row =
  #(Stored, Option(String))

@external(erlang, "erlang", "put")
fn put_rows(key: String, value: List(Row)) -> Dynamic

@external(erlang, "erlang", "get")
fn get_rows(key: String) -> List(Row)

@external(erlang, "erlang", "put")
fn put_ints(key: String, value: List(Int)) -> Dynamic

@external(erlang, "erlang", "get")
fn get_ints(key: String) -> List(Int)

@external(erlang, "erlang", "put")
fn put_records(key: String, value: List(#(Int, String))) -> Dynamic

@external(erlang, "erlang", "get")
fn get_records(key: String) -> List(#(Int, String))

fn record_call(key: String, value: String) -> Nil {
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

/// A context over one room at code "123456": its log, the review rows and
/// the record rows it has, and an engine that answers `answer` to every
/// request. Saves land in the little database, so a read that follows a
/// write sees it. Saves, queueings, engine calls and replays are all
/// recorded.
fn with_analysis(
  log: GameLog,
  stored: List(Row),
  answer: fn(String) -> Result(String, String),
) -> Ctx {
  forget("saves")
  forget("enqueued")
  forget("requests")
  forget("replays")
  forget("backfills")
  forget("extractions")
  forget("extraction_failures")
  let _ = put_ints("extracted", [])
  let _ = put_rows("rows", stored)
  let _ = put_records("records", [])
  Ctx(
    ..fakes.ctx(),
    analysis: AnalysisCaps(
      ..caps.stub(),
      log: fn(id) {
        record_call("replays", id)
        case id {
          "123456" -> Some(log)
          _ -> None
        }
      },
      stored: fn(_) { list.map(get_rows("rows"), fn(row) { row.0 }) },
      ratings: fn(_) { panic as "reviews must not read ratings" },
      summaries: fn(_) {
        list.map(get_rows("rows"), fn(row) {
          Stored(..row.0, response_json: None)
        })
      },
      report: fn(_, number) {
        case
          list.find(get_rows("rows"), fn(row) {
            { row.0 }.game_number == number
          })
        {
          Ok(row) -> row.1
          Error(_) -> None
        }
      },
      save: fn(_, number, save: caps.Save) {
        record_call(
          "saves",
          int.to_string(number)
            <> ":"
            <> status_name(save.status)
            <> ":"
            <> int.to_string(save.attempts)
            <> ":"
            <> case save.response_json {
            Some(_) -> "body"
            None -> "none"
          }
            <> ":"
            <> case save.report_json {
            Some(_) -> "page"
            None -> "none"
          },
        )
        let row = #(
          Stored(
            game_number: number,
            status: save.status,
            attempts: save.attempts,
            response_json: save.response_json,
            answered: save.response_json != None,
            rendered: save.report_json != None,
            turns: save.turns,
          ),
          save.report_json,
        )
        let _ =
          put_rows(
            "rows",
            list.append(
              list.filter(get_rows("rows"), fn(r) {
                { r.0 }.game_number != number
              }),
              [row],
            ),
          )
        Nil
      },
      backfill_turns: fn(_, number, turns) {
        record_call(
          "backfills",
          int.to_string(number) <> ":" <> int.to_string(turns),
        )
        let _ =
          put_rows(
            "rows",
            list.map(get_rows("rows"), fn(row) {
              case { row.0 }.game_number == number {
                True -> #(Stored(..row.0, turns: turns), row.1)
                False -> row
              }
            }),
          )
        Nil
      },
      enqueue: fn(id) { record_call("enqueued", id) },
      review: fn(body) {
        record_call("requests", body)
        answer(body)
      },
    ),
    puzzles: puzzles_caps.PuzzlesCaps(
      ..puzzles_caps.stub(),
      unextracted: fn(_) {
        // A graded game whose puzzles have not been written yet: the rows
        // the sweep's partial index answers with.
        get_rows("rows")
        |> list.filter(fn(row) {
          { row.0 }.status == Done && { row.0 }.response_json != None
        })
        |> list.map(fn(row) { { row.0 }.game_number })
        |> list.filter(fn(number) {
          !list.contains(get_ints("extracted"), number)
        })
      },
      store: fn(_, number, puzzles, sources) {
        record_call(
          "extractions",
          int.to_string(number)
            <> ":"
            <> int.to_string(list.length(puzzles))
            <> ":"
            <> int.to_string(list.length(sources)),
        )
        let _ = put_ints("extracted", [number, ..get_ints("extracted")])
        Ok(Nil)
      },
      // The review job hands a graded game's mistakes to the decks that
      // own them. No seat here belongs to an account, so there is nothing
      // to hand over and nothing else of the deck's is ever reached.
      deck_pending: fn(_, _) { [] },
      failed: fn(_, number, reason) {
        record_call(
          "extraction_failures",
          int.to_string(number) <> ":" <> reason,
        )
        // Charged and, once the budget is spent, marked: the fake settles
        // it at once, which is what the sweep sees after the third try.
        let _ = put_ints("extracted", [number, ..get_ints("extracted")])
        Nil
      },
    ),
    records: records_caps.RecordsCaps(
      ..records_caps.stub(),
      setup: fn(id) {
        case id {
          "123456" -> Some(setup_of(log))
          _ -> None
        }
      },
      stored: fn(_) {
        list.map(get_records("records"), fn(row) {
          records_caps.StoredRecord(row.0, row.1)
        })
      },
      numbers: fn(_) { list.map(get_records("records"), fn(row) { row.0 }) },
      save: fn(_, rows: List(#(Int, String)), _, _) {
        let held = get_records("records")
        let fresh =
          list.filter(rows, fn(row) {
            !list.any(held, fn(kept) { kept.0 == row.0 })
          })
        let _ = put_records("records", list.append(held, fresh))
        Nil
      },
    ),
  )
}

fn no_engine(_body: String) -> Result(String, String) {
  panic as "the engine should not be asked"
}

/// The same room, with a write path that refuses. Extraction is a bonus on
/// top of a review that is already stored, so nothing about the review may
/// change when it fails.
fn with_failing_extraction(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    puzzles: puzzles_caps.PuzzlesCaps(..ctx.puzzles, store: fn(_, _, _, _) {
      record_call("extractions", "refused")
      Error("the database said no")
    }),
  )
}

/// A room whose puzzle capability is not there at all: touch it and the
/// test dies. What a read must be able to do.
fn with_no_puzzle_writes(ctx: Ctx) -> Ctx {
  Ctx(..ctx, puzzles: puzzles_caps.stub())
}

// ---------- Puzzles, written where the pre-move boards are ----------

pub fn a_reviewed_game_writes_its_puzzles_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx = with_analysis(log, [], fn(_) { Ok(engine_answer(n)) })
  assert reviews.run(ctx, "123456") == None
  // One extraction, for game 1, with a source for every mistake the engine
  // found. Every move in this answer is doubtful, so every turn that was
  // not a dance is one.
  let assert [extraction] = recorded("extractions")
  assert string.starts_with(extraction, "1:")
  assert !string.ends_with(extraction, ":0")
}

pub fn a_rerun_writes_no_puzzles_again_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx = with_analysis(log, [], fn(_) { Ok(engine_answer(n)) })
  assert reviews.run(ctx, "123456") == None
  // The engine is not asked again, and neither is the write path: the
  // marker the first extraction left is what says so.
  assert reviews.run(without_the_engine(ctx), "123456") == None
  assert list.length(recorded("extractions")) == 1
}

pub fn a_graded_game_whose_puzzles_were_lost_is_extracted_without_the_engine_test() {
  // A crash between the answer landing and the extraction, or a game
  // graded before puzzles existed: the sweep queues the room and the job
  // reads the answer already stored.
  let log = finished_log(4)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  assert reviews.run(ctx, "123456") == None
  assert recorded("requests") == []
  let assert [extraction] = recorded("extractions")
  assert string.starts_with(extraction, "1:")
  // Nothing about the stored review moved: it was already done and
  // rendered.
  assert recorded("saves") == []
}

pub fn an_extraction_that_fails_leaves_the_review_alone_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx =
    with_failing_extraction(
      with_analysis(log, [], fn(_) { Ok(engine_answer(n)) }),
    )
  assert reviews.run(ctx, "123456") == None
  assert recorded("extractions") == ["refused"]
  // The review landed exactly as it would have.
  assert list.reverse(recorded("saves"))
    == ["1:pending:1:none:none", "1:done:1:body:page"]
  let assert Ok(body) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  assert string.contains(body, "\"status\":\"done\"")
  // And the game is still owed its puzzles, for the sweep to come back to.
  assert ctx.puzzles.unextracted("123456") == [1]
}

pub fn a_read_never_writes_puzzles_test() {
  // Reading a review is open to anyone with the link. It may still settle
  // a room it finds unrendered -- that is what it has always done -- but
  // it must not write a puzzle, spend an extraction attempt, or race the
  // queue's job on the same game.
  let log = finished_log(4)
  let body = engine_answer(turn_count(log, 1))
  let unrendered = #(
    Stored(
      game_number: 1,
      status: Done,
      attempts: 1,
      response_json: Some(body),
      answered: True,
      rendered: False,
      turns: turn_count(log, 1),
    ),
    None,
  )
  let ctx = with_no_puzzle_writes(with_analysis(log, [unrendered], no_engine))
  let assert Ok(page) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  assert string.contains(page, "\"status\":\"done\"")
  // The read rendered the answer, as it always did, and nothing else.
  assert list.reverse(recorded("saves")) == ["1:done:1:body:page"]
}

pub fn a_game_that_can_never_be_extracted_is_given_up_on_test() {
  // A stored answer whose turn count no longer matches the game -- an old
  // row whose turns were re-derived under it. The review is already
  // rendered, so nothing else would ever take this game off the sweep's
  // list: every try has to be charged and said out loud.
  let log = finished_log(4)
  let wrong = #(
    Stored(
      game_number: 1,
      status: Done,
      attempts: 1,
      // One turn, where the game has dozens.
      response_json: Some(engine_answer(1)),
      answered: True,
      rendered: True,
      turns: turn_count(log, 1),
    ),
    Some("a page from before"),
  )
  let ctx = with_analysis(log, [wrong], no_engine)
  assert reviews.run(ctx, "123456") == None
  let assert [failure] = recorded("extraction_failures")
  assert string.starts_with(failure, "1:")
  assert recorded("extractions") == []
  // Charged, so the sweep stops coming back for it.
  assert ctx.puzzles.unextracted("123456") == []
  // And the rendered review is left exactly as it was.
  assert recorded("saves") == []
}

/// The same room with the engine out of reach: what the sweep sees on a
/// second visit, where everything that needs the engine is already done.
fn without_the_engine(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    analysis: AnalysisCaps(..ctx.analysis, review: fn(_) {
      panic as "the engine should not be asked again"
    }),
  )
}

pub fn recovery_of_a_crashed_final_attempt_exposes_failure_without_more_engine_work_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [owed(log, 1, Pending, 3)], no_engine)
  assert reviews.run(ctx, "123456") == None
  assert recorded("requests") == []
  assert recorded("saves") == ["1:failed:3:none:none"]
  let assert Ok(body) =
    reviews.reviews_json(
      without_the_log(ctx),
      fakes.no_guest(),
      "backgammon",
      "123456",
    )
  assert string.contains(body, "\"status\":\"failed\"")
}

pub fn settled_index_and_detail_read_neither_log_nor_record_bodies_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  // One legacy backfill establishes the stored rows.
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  let ctx = without_the_log(ctx)
  let ctx =
    Ctx(
      ..ctx,
      records: records_caps.RecordsCaps(
        ..ctx.records,
        // Playing more ordinary turns in the next game does not change this.
        setup: fn(_) {
          Some(records_caps.Setup(..setup_of(log), finished: False))
        },
        stored: fn(_) {
          panic as "an index/detail read loaded all record bodies"
        },
      ),
    )
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  let assert Ok(_) =
    reviews.review_json(ctx, fakes.no_guest(), "backgammon", "123456", 1)
}

/// The same room, with its log out of reach: a read of a room whose games
/// are all written down must not touch the action log at all.
fn without_the_log(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    analysis: AnalysisCaps(..ctx.analysis, log: fn(_) {
      panic as "a read must not replay the log"
    }),
  )
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
  // Marked pending before the call, done with the body and the page the
  // page will read after, in order
  assert list.reverse(recorded("saves"))
    == ["1:pending:1:none:none", "1:done:1:body:page"]
  let assert [request] = recorded("requests")
  assert string.contains(request, "\"turns\":[{\"player\":")
  // The depth is the engine's default (4-ply), never set from here
  assert !string.contains(request, "_level")
  assert string.contains(request, "\"top_moves\":5")
  // The game's record went down in the same pass: the replay was paid for
  // once and both things it produced were kept.
  let assert [#(1, entries)] = get_records("records")
  assert string.starts_with(entries, "[")
}

pub fn a_failed_call_is_recorded_and_retried_with_backoff_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [], fn(_) { Error("HTTP 503") })
  assert reviews.run(ctx, "123456") == Some(30_000)
  assert list.reverse(recorded("saves"))
    == ["1:pending:1:none:none", "1:failed:1:none:none"]
  // The second failure waits longer
  let ctx =
    with_analysis(log, [owed(log, 1, Failed, 1)], fn(_) { Error("timeout") })
  assert reviews.run(ctx, "123456") == Some(120_000)
  // The third is the last: failed for good, no retry
  let ctx =
    with_analysis(log, [owed(log, 1, Failed, 2)], fn(_) { Error("timeout") })
  assert reviews.run(ctx, "123456") == None
  assert list.reverse(recorded("saves"))
    == ["1:pending:3:none:none", "1:failed:3:none:none"]
}

pub fn an_answer_that_does_not_read_is_a_failure_test() {
  let log = finished_log(4)
  let ctx = with_analysis(log, [], fn(_) { Ok("{\"detail\":\"nope\"}") })
  assert reviews.run(ctx, "123456") == Some(30_000)
  assert list.reverse(recorded("saves"))
    == ["1:pending:1:none:none", "1:failed:1:none:none"]
}

pub fn a_game_done_or_given_up_is_never_run_again_test() {
  let log = finished_log(4)
  let _n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  assert reviews.run(ctx, "123456") == None
  let ctx = with_analysis(log, [owed(log, 1, Failed, 3)], no_engine)
  assert reviews.run(ctx, "123456") == None
  assert recorded("saves") == []
}

pub fn a_legacy_turn_count_backfill_changes_no_other_review_state_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let #(row, page) = owed(log, 1, Failed, 3)
  let legacy = #(Stored(..row, turns: 0), page)
  let ctx = with_analysis(log, [legacy], no_engine)

  assert reviews.run(ctx, "123456") == None
  assert recorded("saves") == []
  assert recorded("backfills") == ["1:" <> int.to_string(n)]
  let assert [#(Stored(status: Failed, attempts: 3, turns: turns, ..), _)] =
    get_rows("rows")
  assert turns == n
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
  // Every finished game of the match has its record row
  let finished = list.filter(games, fn(g) { g.finished }) |> list.length
  assert list.length(get_records("records")) == finished
}

// ---------- Rows, as they stand once a room is settled ----------

/// A review row the engine has not answered.
fn owed(log: GameLog, number: Int, status: caps.Status, attempts: Int) -> Row {
  #(
    Stored(
      game_number: number,
      status: status,
      attempts: attempts,
      response_json: None,
      answered: False,
      rendered: False,
      turns: list.length(game_number(log, number).turns),
    ),
    None,
  )
}

/// A review row as it stands once the engine has answered and the answer
/// has been rendered: what every read is served out of.
fn answered(log: GameLog, number: Int) -> Row {
  let g = game_number(log, number)
  let n = list.length(g.turns)
  let body = engine_answer(n)
  #(
    Stored(
      game_number: number,
      status: Done,
      attempts: 1,
      response_json: Some(body),
      answered: True,
      rendered: True,
      turns: n,
    ),
    Some(page_of(body, g.turns)),
  )
}

fn game_number(log: GameLog, number: Int) -> bg_analysis.GameTurns {
  let assert Ok(games) = reviews.games(log)
  let assert Ok(g) = list.find(games, fn(g) { g.number == number })
  g
}

/// An engine answer for these turns whose every candidate is the move that
/// was played, board and all.
fn answer_for(turns: List(bg_analysis.Turn)) -> String {
  let candidate = fn(rank, board) {
    "{\"rank\":"
    <> int.to_string(rank)
    <> ",\"notation\":\"8/5 6/5\",\"board\":"
    <> board
    <> ",\"equity\":0.1,\"equity_diff\":0,\"probs\":{\"win\":0.5,\"gammon_win\":0.1,\"backgammon_win\":0,\"gammon_loss\":0.1,\"backgammon_loss\":0}}"
  }
  let turn = fn(t: bg_analysis.Turn, i) {
    let board =
      json.to_string(json.array(option.unwrap(t.played, []), json.int))
    "{\"index\":"
    <> int.to_string(i)
    <> ",\"cube\":null,\"move\":{\"played\":"
    <> candidate(1, board)
    <> ",\"best\":"
    <> candidate(1, board)
    <> ",\"top\":["
    <> candidate(1, board)
    <> "],\"n_legal\":9,\"forced\":false,\"error\":0,\"grade\":\"best\"},\"luck\":null}"
  }
  let totals =
    "{\"moves\":{\"decisions\":3,\"forced\":1,\"error\":0,\"grades\":{}},\"cube\":{\"decisions\":0,\"error\":0,\"mistakes\":{}},\"luck\":0,\"error\":0,\"pr\":0}"
  "{\"turns\":["
  <> string.join(list.index_map(turns, turn), ",")
  <> "],\"players\":["
  <> totals
  <> ","
  <> totals
  <> "]}"
}

/// The page a done review is stored as, built the one way it is ever built.
fn page_of(body: String, turns: List(bg_analysis.Turn)) -> String {
  let assert Ok(review) = report.parse(body)
  let seats = [
    report.Seat("p1", "Alice", "white"),
    report.Seat("p2", "Bob", "black"),
  ]
  let assert Ok(page) = report.to_json(review, turns, seats)
  json.to_string(page)
}

// ---------- GET .../reviews: the index ----------

pub fn the_index_names_the_games_and_nothing_else_test() {
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  // The first read writes the record rows down; from then on nothing is
  // replayed, however often it is asked for.
  let assert Ok(body) =
    reviews.reviews_json(
      without_the_log(ctx),
      fakes.guest("g1"),
      "backgammon",
      "123456",
    )
  assert string.starts_with(body, "{\"ok\":true,\"players\":[{\"seat\":0,")
  assert string.contains(body, "\"name\":\"Alice\",\"color\":\"white\"")
  assert string.contains(
    body,
    "\"games\":[{\"game_number\":1,\"status\":\"done\",\"turns\":"
      <> int.to_string(n)
      <> "}]",
  )
  // The analysis itself is not in it: that is what the per-game read is for
  assert !string.contains(body, "\"review\"")
  // Small enough to ask for as often as a page likes
  assert string.length(body) < 400
  assert recorded("enqueued") == []
}

pub fn a_read_of_a_settled_room_replays_nothing_test() {
  // The whole point: a room whose games are written down answers out of
  // rows, and the action log is never touched. The stub panics if it is.
  let log = finished_log(4)
  let _n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  assert list.length(recorded("replays")) == 1
  let settled = without_the_log(ctx)
  let assert Ok(_) =
    reviews.reviews_json(settled, fakes.guest("g1"), "backgammon", "123456")
  let assert Ok(_) =
    reviews.review_json(settled, fakes.guest("g1"), "backgammon", "123456", 1)
  let assert Ok(_) =
    reviews.reviews_json(settled, fakes.guest("g1"), "backgammon", "123456")
  assert recorded("enqueued") == []
}

// ---------- GET .../reviews/:game_number: one game ----------

pub fn a_done_review_reads_turn_by_turn_test() {
  let log = finished_log(4)
  let _n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  let assert Ok(body) =
    reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert string.starts_with(
    body,
    "{\"ok\":true,\"game_number\":1,\"status\":\"done\",\"turns\":",
  )
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
  // The depth the engine searched at rides along for the page
  assert string.contains(
    body,
    "\"levels\":{\"moves\":\"2ply\",\"cube\":\"3ply\"},\"timing_ms\":null",
  )
  assert recorded("enqueued") == []
}

pub fn a_turn_names_its_record_lines_and_its_moves_positions_test() {
  // An answer whose candidates carry the board each turn really left: the
  // page gets that board as a position it can draw, the checkers it
  // landed, and the record lines each verdict is about.
  let log = finished_log(4)
  let assert Ok([g]) = reviews.games(log)
  let n = list.length(g.turns)
  let body = answer_for(g.turns)
  let row = #(
    Stored(
      game_number: 1,
      status: Done,
      attempts: 1,
      response_json: Some(body),
      answered: True,
      rendered: True,
      turns: n,
    ),
    Some(page_of(body, g.turns)),
  )
  let ctx = with_analysis(log, [row], no_engine)
  let assert Ok(body) =
    reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert string.contains(
    body,
    "\"entry\":0,\"double_entry\":null,\"answer_entry\":null",
  )
  let assert [first, ..] = g.turns
  let assert Some(played) = first.played
  let assert Ok(#(white, black)) = bg_analysis.decode(played, board.White)
  assert string.contains(
    body,
    "\"position\":"
      <> json.to_string(
      json.object([
        #("white", record.side_to_json(white)),
        #("black", record.side_to_json(black)),
      ]),
    )
      <> ",\"landed\":"
      <> json.to_string(json.array(
      bg_analysis.landings(first.position.board, played, board.White),
      json.int,
    )),
  )
}

pub fn a_game_the_room_does_not_have_is_not_there_test() {
  let log = finished_log(4)
  let _n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine)
  let assert Error(error.NotFound(_)) =
    reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 7)
}

pub fn the_depth_the_engine_searched_at_is_read_either_way_test() {
  // The engine has written the move level as "move" (with a luck level
  // beside it) and as "moves"; both are the same answer to a page.
  let log = finished_log(4)
  let n = turn_count(log, 1)
  let with_levels = fn(levels: String) {
    string.replace(
      engine_answer(n),
      "{\"levels\":{\"moves\":\"2ply\",\"cube\":\"3ply\"}",
      "{\"levels\":" <> levels,
    )
  }
  // The row is written by the queue, so this is the queue writing it: the
  // engine answers, and what it said is rendered once and kept.
  let rendered = fn(levels: String) {
    let ctx = with_analysis(log, [], fn(_) { Ok(with_levels(levels)) })
    assert reviews.run(ctx, "123456") == None
    let assert Ok(body) =
      reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
    string.contains(body, "\"levels\":{\"moves\":\"4ply\",\"cube\":\"4ply\"}")
  }
  assert rendered("{\"move\":\"4ply\",\"cube\":\"4ply\",\"luck\":\"3ply\"}")
  assert rendered("{\"moves\":\"4ply\",\"cube\":\"4ply\"}")
  // Nothing the page can name is simply not there
  let ctx =
    with_analysis(log, [], fn(_) { Ok(with_levels("{\"cube\":\"4ply\"}")) })
  assert reviews.run(ctx, "123456") == None
  let assert Ok(body) =
    reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert string.contains(body, "\"levels\":null")
}

// ---------- The statuses a read can name ----------

pub fn a_game_with_no_review_yet_is_pending_and_queues_nothing_test() {
  // A game finished before the pipeline existed. Reading it says pending
  // and puts nobody to work, however many people read it: an analysis is
  // asked for when a game ends, and by `mix oskol.analyse` for the games
  // that ended before there was anything to ask.
  let ctx = with_analysis(finished_log(4), [], no_engine)
  let assert Ok(body) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  assert string.contains(body, "\"game_number\":1,\"status\":\"pending\"")
  let assert Ok(one) =
    reviews.review_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert string.contains(one, "\"status\":\"pending\",\"turns\":0")
  assert string.contains(one, "\"review\":null")
  assert recorded("enqueued") == []
  // ...and a stranger's read, and a read with no guest at all, do no more
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.guest("stranger"), "backgammon", "123456")
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  assert recorded("enqueued") == []
}

pub fn a_review_that_gave_up_says_failed_test() {
  let ctx =
    with_analysis(
      finished_log(4),
      [owed(finished_log(4), 1, Failed, 3)],
      no_engine,
    )
  let assert Ok(body) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  assert string.contains(body, "\"status\":\"failed\"")
  assert recorded("enqueued") == []
}

pub fn a_retry_still_to_come_is_pending_test() {
  let ctx =
    with_analysis(
      finished_log(4),
      [owed(finished_log(4), 1, Failed, 1)],
      no_engine,
    )
  let assert Ok(body) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  assert string.contains(body, "\"status\":\"pending\"")
  // The queue holds a room that waits on a retry; a read adds nothing
  assert recorded("enqueued") == []
}

pub fn an_answer_that_is_not_this_games_is_given_up_on_once_test() {
  // A stored answer with the wrong number of turns is not this game's. It
  // is settled as failed the first time a read notices, rather than being
  // taken apart again on every read after.
  let ctx =
    with_analysis(
      finished_log(4),
      [
        #(
          Stored(
            game_number: 1,
            status: Done,
            attempts: 1,
            response_json: Some(engine_answer(1)),
            answered: True,
            rendered: False,
            turns: 0,
          ),
          None,
        ),
      ],
      no_engine,
    )
  let assert Ok(body) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
  assert string.contains(body, "\"status\":\"failed\"")
  // Settled: the next read does not go near the log
  let assert Ok(again) =
    reviews.reviews_json(
      without_the_log(ctx),
      fakes.guest("g1"),
      "backgammon",
      "123456",
    )
  assert string.contains(again, "\"status\":\"failed\"")
}

// ---------- POST .../reviews/retry ----------

/// Room caps with a seat: the guest "g1" holds p1's seat at a live
/// backgammon room.
fn seated(ctx: Ctx) -> Ctx {
  let assert Ok(game) =
    instance.start(
      backgammon.game(),
      "single",
      [game.Seat("p1", "Alice"), game.Seat("p2", "Bob")],
      4,
      clock.NoClock,
      0,
    )
  let ctx =
    ctx
    |> fakes.with_room(Some(fakes.room()), None)
    |> fakes.with_slug(Some("backgammon"))
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      seated_game: fn(_, guest_id, user_id) {
        case guest_id, user_id {
          Some("g1"), _ | _, Some("u1") -> Ok(#("p1", game))
          _, _ -> Error(errors.NoSeat)
        }
      },
      game: fn(_) { Ok(game) },
    ),
  )
}

pub fn a_review_that_gave_up_is_tried_again_for_a_seat_test() {
  let ctx =
    with_analysis(
      finished_log(4),
      [owed(finished_log(4), 1, Failed, 3)],
      no_engine,
    )
    |> seated
  let assert Ok(body) =
    reviews.retry_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  // A fresh set of attempts, and the room queued
  assert recorded("saves") == ["1:pending:0:none:none"]
  assert recorded("enqueued") == ["123456"]
  // And it answers the index, as GET does
  assert string.contains(body, "\"games\":[{\"game_number\":1,")
  assert !string.contains(body, "\"review\"")
}

pub fn a_retry_checks_a_stopped_rooms_stored_seat_without_rehydrating_test() {
  // `with_analysis` starts with room capabilities that panic. The retry
  // still authenticates g1 from the game row's seats and queues the failed
  // review; it must not look a room up just to do that.
  let ctx =
    with_analysis(
      finished_log(4),
      [owed(finished_log(4), 1, Failed, 3)],
      no_engine,
    )
  let assert Ok(_) =
    reviews.retry_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert recorded("saves") == ["1:pending:0:none:none"]
  assert recorded("enqueued") == ["123456"]
}

pub fn a_retry_leaves_every_other_review_alone_test() {
  let log = finished_log(4)
  let _n = turn_count(log, 1)
  let ctx = with_analysis(log, [answered(log, 1)], no_engine) |> seated
  let assert Ok(body) =
    reviews.retry_json(ctx, fakes.guest("g1"), "backgammon", "123456", 1)
  assert string.contains(body, "\"status\":\"done\"")
  // A game the room does not have
  let assert Ok(_) =
    reviews.retry_json(ctx, fakes.guest("g1"), "backgammon", "123456", 7)
  assert recorded("saves") == []
  assert recorded("enqueued") == []
}

pub fn only_a_seat_may_ask_for_a_retry_test() {
  let ctx =
    with_analysis(
      finished_log(4),
      [owed(finished_log(4), 1, Failed, 3)],
      no_engine,
    )
    |> seated
  let assert Error(error.NotFound(_)) =
    reviews.retry_json(ctx, fakes.guest("stranger"), "backgammon", "123456", 1)
  let assert Error(error.NotFound(_)) =
    reviews.retry_json(ctx, fakes.no_guest(), "backgammon", "123456", 1)
  assert recorded("saves") == []
}

// ---------- Rooms that have no reviews ----------

pub fn anyone_with_the_room_reads_its_reviews_test() {
  // A replay does not ask its reader who they are: a review reads back what
  // was on the board for both players and any spectator. Only a retry,
  // which spends engine time on demand, needs the reader to be holding one
  // of the room's seats.
  let ctx = with_analysis(finished_log(4), [], no_engine) |> seated
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.guest("stranger"), "backgammon", "123456")
  let assert Ok(_) =
    reviews.reviews_json(ctx, fakes.no_guest(), "backgammon", "123456")
  let assert Error(error.NotFound(_)) =
    reviews.retry_json(ctx, fakes.guest("stranger"), "backgammon", "123456", 1)
}

pub fn only_backgammon_rooms_have_reviews_test() {
  let ctx = with_analysis(finished_log(4), [], no_engine)
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "poker", "123456")
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "999999")
  // A code that is a poker room, asked for as backgammon
  let poker = GameLog(..finished_log(4), slug: "poker")
  let ctx = with_analysis(poker, [], no_engine)
  let assert Error(error.NotFound(_)) =
    reviews.reviews_json(ctx, fakes.guest("g1"), "backgammon", "123456")
}
