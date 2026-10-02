//// Asking the engine about a set-up position: what is free (a stored key),
//// what is charged and to whom, what is refused before anything is asked,
//// and what an answer must hold before it is written. On stubs: every
//// capability a branch should not reach panics.

import backgammon/analysis
import backgammon/board.{type Board, Black, White}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/analysis/setup.{type Setup, Double, Match, Move, Setup}
import oskol/caps/analysis as analysis_caps
import oskol/caps/auth.{type LimitBucket}
import oskol/caps/puzzles as puzzles_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/envelope
import oskol/core/error
import oskol/core/session.{type Session, Session}
import oskol/handlers/analysis as handler
import oskol/handlers/puzzles as puzzle_page
import oskol/practice/openings
import oskol/puzzles.{
  type Answer, type Question, Candidate, CubeAnswer, DoublePass, MoveAnswer,
  Outcome, Probs,
}
import oskol/puzzles/tree

import oskol/fakes

// ---------- A little memory of calls ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

fn record(key: String, value: String) -> Nil {
  let _ = put(key, list.append(recorded(key), [value]))
  Nil
}

fn recorded(key: String) -> List(String) {
  case decode.run(get(key), decode.list(decode.string)) {
    Ok(values) -> values
    Error(_) -> []
  }
}

fn reset() -> Nil {
  list.each(["allow", "buckets", "submit", "stored", "pictures"], fn(k) {
    put(k, [])
  })
}

// ---------- Positions ----------

fn opening(roll: #(Int, Int)) -> Setup {
  let b = board.initial()
  Setup(
    points: list.range(1, 24)
      |> list.map(fn(p) {
        board.count(b, White, board.Point(p))
        - board.count(b, Black, board.Point(p))
      }),
    white_bar: 0,
    black_bar: 0,
    to_play: White,
    ask: Move(roll),
    cube_value: 1,
    cube_owner: None,
    match: None,
  )
}

fn body(s: Setup) -> String {
  json.to_string(setup.to_json(s))
}

fn guest() -> Session {
  Session(guest_id: Some("g1"), user_id: None)
}

fn account() -> Session {
  Session(guest_id: Some("g1"), user_id: Some("u1"))
}

fn budget() -> analysis_caps.AskBudget {
  analysis_caps.AskBudget(
    guest_hour: 10,
    guest_day: 30,
    user_hour: 30,
    user_day: 150,
    global_day: 600,
  )
}

// ---------- Contexts ----------

/// Nothing stored, the asker free, every budget open: the calls are
/// written down.
fn fresh_ctx() -> Ctx {
  reset()
  let base = fakes.ctx()
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(..base.puzzles, by_key: fn(_) { None }),
    analysis: analysis_caps.AnalysisCaps(
      ..base.analysis,
      ask_budget: budget,
      asking: fn(_) { analysis_caps.Free },
      allow_ask: fn(buckets: List(LimitBucket)) {
        record("allow", "allow")
        list.each(buckets, fn(b) {
          record("buckets", b.key <> "=" <> int.to_string(b.limit))
        })
        Ok(Nil)
      },
      submit: fn(ask: analysis_caps.Ask) {
        record("submit", ask.key)
        analysis_caps.Asked
      },
    ),
  )
}

fn with_asking(ctx: Ctx, state: analysis_caps.Asker) -> Ctx {
  Ctx(
    ..ctx,
    analysis: analysis_caps.AnalysisCaps(..ctx.analysis, asking: fn(_) { state }),
  )
}

fn stored(id: String, question: Question, answer: Answer) -> puzzles_caps.Stored {
  puzzles_caps.Stored(
    id: id,
    kind: puzzles.kind_name(question.kind),
    question_json: json.to_string(puzzles.question_json(question)),
    answer_json: json.to_string(puzzles.answer_json(answer)),
  )
}

const levels_json = "{\"levels\":{\"moves\":\"4ply\",\"cube\":\"4ply\"}}"

/// A context whose store holds this puzzle under its key, and nothing that
/// asks or charges.
fn holding(row: puzzles_caps.Stored, question: Question, complete: Bool) -> Ctx {
  reset()
  let base = fakes.ctx()
  let key = puzzles.key(question)
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(..base.puzzles, by_key: fn(k) {
      case k == key {
        True -> Some(puzzles_caps.Keyed(row, complete, levels_json))
        False -> None
      }
    }),
  )
}

fn status_of(text: String) -> String {
  let assert Ok(s) = json.parse(text, decode.at(["status"], decode.string))
  s
}

// ---------- The answers the engine gives ----------

fn probs_json() -> Json {
  json.object([
    #("win", json.float(0.52)),
    #("gammon_win", json.float(0.14)),
    #("backgammon_win", json.float(0.01)),
    #("gammon_loss", json.float(0.12)),
    #("backgammon_loss", json.float(0.01)),
  ])
}

/// The boards every legal play of this roll leaves, from the mover's side.
fn legal_boards(b: Board, roll: #(Int, Int)) -> List(List(Int)) {
  let assert Ok(t) = tree.build(b, tree.dice_of(roll), 100_000)
  t.nodes
  |> list.filter(fn(n) { n.children == [] })
  |> list.map(fn(n) { analysis.encode(n.board, White) })
}

/// The engine's answer to one checker play: the first legal play best, each
/// later one a little worse, with `results` cut to `sent` of them.
fn move_response(boards: List(List(Int)), sent: Int) -> String {
  let candidate = fn(b: List(Int), i: Int) {
    json.object([
      #("rank", json.int(i + 1)),
      #("notation", json.string("play " <> int.to_string(i + 1))),
      #("equity", json.float(0.05 -. 0.02 *. int.to_float(i))),
      #("equity_diff", json.float(0.0 -. 0.02 *. int.to_float(i))),
      #("probs", probs_json()),
      #("board", json.array(b, json.int)),
    ])
  }
  let candidates = list.index_map(boards, candidate)
  let assert [best, ..] = candidates
  response(
    json.object([
      #("index", json.int(1)),
      #("player", json.int(0)),
      #(
        "move",
        json.object([
          #("played", best),
          #("best", best),
          #("top", json.preprocessed_array(list.take(candidates, 5))),
          #(
            "results",
            json.array(
              list.index_map(boards, fn(b, i) { #(b, i) }) |> list.take(sent),
              fn(pair) {
                json.object([
                  #("board", json.array(pair.0, json.int)),
                  #(
                    "equity_diff",
                    json.float(0.0 -. 0.02 *. int.to_float(pair.1)),
                  ),
                ])
              },
            ),
          ),
          #("n_legal", json.int(list.length(boards))),
          #("forced", json.bool(False)),
          #("error", json.float(0.0)),
          #("grade", json.string("best")),
        ]),
      ),
    ]),
  )
}

fn cube_response(with_probs: Bool) -> String {
  let analysis =
    json.object(
      list.flatten([
        [
          #("optimal_action", json.string("double_pass")),
          #("equity_nd", json.float(0.6)),
          #("equity_dt", json.float(1.4)),
          #("equity_dp", json.float(1.0)),
        ],
        case with_probs {
          True -> [#("probs", probs_json())]
          False -> []
        },
      ]),
    )
  response(
    json.object([
      #("index", json.int(1)),
      #("player", json.int(0)),
      #(
        "cube",
        json.object([
          #("action", json.string("no_double")),
          #("analysis", analysis),
          #(
            "doubler",
            json.object([
              #("error", json.float(0.4)),
              #("grade", json.string("very_bad")),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

fn response(turn: Json) -> String {
  let totals =
    json.object([
      #(
        "moves",
        json.object([
          #("decisions", json.int(1)),
          #("forced", json.int(0)),
          #("error", json.float(0.0)),
          #("grades", json.object([])),
        ]),
      ),
      #(
        "cube",
        json.object([
          #("decisions", json.int(0)),
          #("error", json.float(0.0)),
          #("mistakes", json.object([])),
        ]),
      ),
      #("luck", json.float(0.0)),
      #("error", json.float(0.0)),
      #("pr", json.float(0.0)),
    ])
  json.to_string(
    json.object([
      #(
        "levels",
        json.object([
          #("moves", json.string("4ply")),
          #("cube", json.string("4ply")),
        ]),
      ),
      #("turns", json.preprocessed_array([turn])),
      #("players", json.preprocessed_array([totals, totals])),
    ]),
  )
}

/// The context `store` writes through: the puzzle it is handed is kept.
fn storing_ctx() -> Ctx {
  reset()
  let base = fakes.ctx()
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(
      ..base.puzzles,
      store_one: fn(p: puzzles_caps.NewPuzzle, origin: String) {
        record("stored", origin <> ":" <> p.key)
        let _ = put("new_puzzle", p)
        Ok(p.ids |> list.first |> option.from_result |> option.unwrap(""))
      },
      pictures_one: fn(id) { record("pictures", id) },
    ),
  )
}

@external(erlang, "erlang", "get")
fn kept_puzzle(key: String) -> puzzles_caps.NewPuzzle

fn ask_of(s: Setup) -> analysis_caps.Ask {
  let assert Ok(handler.ToAsk(ask)) =
    handler.prepare(fresh_ctx(), guest(), body(s))
  ask
}

// ---------- The cache ----------

pub fn a_stored_key_is_answered_with_no_ask_and_no_charge_test() {
  let s = opening(#(3, 1))
  let q = setup.question(s)
  let boards = legal_boards(board.initial(), #(3, 1))
  let answer = complete_move_answer(boards)
  let row = stored("abcdefgh", q, answer)
  // `holding` arranges no asker, no budget and no submit: reaching any of
  // them panics.
  let ctx = holding(row, q, True)
  let assert Ok(handler.Cached(key, _)) = handler.prepare(ctx, guest(), body(s))
  assert key == puzzles.key(q)
  let assert Ok(#(200, text)) = handler.ask_json(ctx, guest(), body(s))
  assert status_of(text) == "done"
  assert recorded("allow") == []
  let assert Ok(id) =
    json.parse(text, decode.at(["puzzle", "id"], decode.string))
  assert id == "abcdefgh"
  let assert Ok(n) =
    json.parse(text, decode.at(["reveal", "n_legal"], decode.int))
  assert n == list.length(boards)
  let assert Ok(level) =
    json.parse(text, decode.at(["reveal", "levels", "moves"], decode.string))
  assert level == "4ply"
}

pub fn a_flipped_setup_is_the_same_key_test() {
  let s = opening(#(3, 1))
  let q = setup.question(s)
  let ctx = holding(stored("abcdefgh", q, complete_move_answer([])), q, True)
  let assert Ok(handler.Cached(_, _)) =
    handler.prepare(ctx, guest(), body(setup.flip(s)))
}

pub fn an_incomplete_row_is_asked_again_test() {
  let s = opening(#(3, 1))
  let q = setup.question(s)
  let base = holding(stored("abcdefgh", q, complete_move_answer([])), q, False)
  let fresh = fresh_ctx()
  let ctx = Ctx(..fresh, puzzles: base.puzzles)
  let assert Ok(handler.ToAsk(_)) = handler.prepare(ctx, guest(), body(s))
  assert recorded("allow") == ["allow"]
}

// ---------- A new key ----------

pub fn a_new_key_reserves_then_asks_what_openings_would_test() {
  let s = opening(#(3, 1))
  let ctx = fresh_ctx()
  let assert Ok(handler.ToAsk(ask)) = handler.prepare(ctx, guest(), body(s))
  assert recorded("allow") == ["allow"]
  assert recorded("buckets")
    == [
      "analysis:guest:g1:hour=10",
      "analysis:guest:g1:day=30",
      "analysis:global:day=600",
    ]
  let q = openings.question(openings.start(), #(3, 1))
  assert ask.key == puzzles.key(q)
  assert ask.kind == "move"
  assert ask.ids == puzzles.ids(q)
  let assert Ok(turn) = openings.turn(openings.start(), #(3, 1))
  // The same turn, at the same place a game's own grade puts it.
  assert ask.request_body
    == json.to_string(analysis.turns_request(
      [#(1, turn)],
      openings.jacoby,
      None,
      None,
    ))
  assert string.contains(ask.request_body, "\"all_results\":true")
}

pub fn an_account_is_charged_as_itself_test() {
  let ctx = fresh_ctx()
  let assert Ok(_) = handler.prepare(ctx, account(), body(opening(#(6, 5))))
  assert recorded("buckets")
    == [
      "analysis:user:u1:hour=30",
      "analysis:user:u1:day=150",
      "analysis:global:day=600",
    ]
}

pub fn a_new_key_is_handed_to_the_asker_and_pending_test() {
  let s = opening(#(4, 2))
  let ctx = fresh_ctx()
  let assert Ok(#(202, text)) = handler.ask_json(ctx, guest(), body(s))
  assert status_of(text) == "pending"
  assert recorded("submit") == [puzzles.key(setup.question(s))]
}

pub fn a_key_in_hand_joins_it_free_test() {
  let ctx = fresh_ctx() |> with_asking(analysis_caps.Asked)
  let assert Ok(#(202, text)) =
    handler.ask_json(ctx, guest(), body(opening(#(4, 2))))
  assert status_of(text) == "pending"
  assert recorded("allow") == []
  assert recorded("submit") == []
}

// ---------- Refusals ----------

pub fn a_spent_budget_is_429_with_the_wait_test() {
  let base = fresh_ctx()
  let ctx =
    Ctx(
      ..base,
      analysis: analysis_caps.AnalysisCaps(..base.analysis, allow_ask: fn(_) {
        Error(analysis_caps.Refused("analysis:guest:g1:hour", 840))
      }),
    )
  let assert Error(err) = handler.ask_json(ctx, guest(), body(opening(#(3, 1))))
  assert error.status(err) == 429
  assert error.code(err) == "rate_limited"
  assert error.message(err)
    == "Guests can analyze 10 positions an hour. Sign in for more, or try again in 14 minutes."
  assert error.retry_after_s(err) == Some(840)
  let assert #(429, text) = envelope.error(err)
  let assert Ok(840) =
    json.parse(text, decode.at(["error", "retry_after_s"], decode.int))
  assert recorded("submit") == []
}

pub fn the_budget_sentences_name_whose_and_how_long_test() {
  let m = fn(key, seconds) {
    error.message(handler.limited(budget(), analysis_caps.Refused(key, seconds)))
  }
  assert m("analysis:user:u1:day", 5 * 3600 - 10)
    == "You can analyze 150 positions a day. Try again in 5 hours."
  assert m("analysis:user:u1:hour", 30)
    == "You can analyze 30 positions an hour. Try again in a minute."
  assert m("analysis:global:day", 3600)
    == "The engine has analyzed all it can today. Try again in an hour."
  assert m("analysis:guest:g1:day", 7200)
    == "Guests can analyze 30 positions a day. Sign in for more, or try again in 2 hours."
}

pub fn a_full_line_is_429_and_charges_nothing_test() {
  let ctx = fresh_ctx() |> with_asking(analysis_caps.Full)
  let assert Error(err) = handler.ask_json(ctx, guest(), body(opening(#(3, 1))))
  assert error.status(err) == 429
  assert error.message(err) == handler.busy_message
  assert recorded("allow") == []
}

pub fn a_sleeping_engine_is_503_and_charges_nothing_test() {
  let ctx = fresh_ctx() |> with_asking(analysis_caps.Down(42))
  let assert Error(err) = handler.ask_json(ctx, guest(), body(opening(#(3, 1))))
  assert error.status(err) == 503
  assert error.code(err) == "engine_down"
  assert error.message(err) == "The engine is asleep. Try again in a minute."
  assert error.retry_after_s(err) == Some(42)
  assert recorded("allow") == []
}

pub fn a_roll_that_plays_nothing_is_409_and_asks_nothing_test() {
  // White's checker on the bar against a closed board: nothing enters.
  let closed =
    Setup(
      points: [
        -3, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -2, -2, -2, -2,
        -2, -2,
      ],
      white_bar: 1,
      black_bar: 0,
      to_play: White,
      ask: Move(#(6, 4)),
      cube_value: 1,
      cube_owner: None,
      match: None,
    )
  // Nothing about the store or the asker is arranged: reaching them panics.
  let assert Error(err) = handler.ask_json(fakes.ctx(), guest(), body(closed))
  assert error.status(err) == 409
  assert error.code(err) == "dances"
  assert error.message(err) == "6-4 cannot be played from here"
}

pub fn a_double_nobody_could_offer_is_422_test() {
  let s =
    Setup(
      ..opening(#(3, 1)),
      ask: Double,
      cube_value: 2,
      cube_owner: Some(Black),
    )
  let assert Error(err) = handler.ask_json(fakes.ctx(), guest(), body(s))
  assert error.status(err) == 422
  assert error.message(err) == setup.cube_owned_message(Black)
}

pub fn a_crawford_double_is_422_test() {
  let s =
    Setup(
      ..opening(#(3, 1)),
      ask: Double,
      match: Some(Match(length: 5, white: 4, black: 2, crawford: True)),
    )
  let assert Error(err) = handler.ask_json(fakes.ctx(), guest(), body(s))
  assert error.status(err) == 422
  assert error.message(err) == setup.crawford_double_message
}

pub fn no_roll_and_no_position_are_422_test() {
  let assert Error(err) =
    handler.ask_json(fakes.ctx(), guest(), body(opening(setup.no_roll)))
  assert error.message(err) == setup.no_roll_message
  let assert Error(err) =
    handler.ask_json(fakes.ctx(), guest(), "{\"points\":3}")
  assert error.status(err) == 422
  assert error.message(err) == handler.not_a_position_message
}

// ---------- Keeping the answer ----------

pub fn a_complete_answer_is_written_as_an_analysis_puzzle_test() {
  let s = opening(#(3, 1))
  let ask = ask_of(s)
  let boards = legal_boards(board.initial(), #(3, 1))
  let ctx = storing_ctx()
  let assert Ok(id) =
    handler.store(ctx, ask, move_response(boards, list.length(boards)))
  assert recorded("stored") == ["analysis:" <> ask.key]
  assert recorded("pictures") == [id]
  let kept = kept_puzzle("new_puzzle")
  assert kept.complete
  assert kept.kind == "move"
  assert kept.question_json == ask.question_json
  let assert Ok(MoveAnswer(n_legal: n, candidates: candidates, ..)) =
    puzzles.answer_from_json(kept.answer_json)
  assert n == list.length(boards)
  assert list.length(candidates) == int.min(5, list.length(boards))
  assert string.contains(kept.evaluated_by_json, "4ply")
}

pub fn an_answer_short_of_every_legal_play_writes_nothing_test() {
  let ask = ask_of(opening(#(3, 1)))
  let boards = legal_boards(board.initial(), #(3, 1))
  let ctx = storing_ctx()
  let assert Error(_) =
    handler.store(ctx, ask, move_response(boards, list.length(boards) - 1))
  assert recorded("stored") == []
  assert recorded("pictures") == []
}

pub fn a_cube_answer_needs_its_chances_test() {
  let s = Setup(..opening(#(3, 1)), ask: Double)
  let ask = ask_of(s)
  assert ask.kind == "double"
  let ctx = storing_ctx()
  let assert Error(_) = handler.store(ctx, ask, cube_response(False))
  assert recorded("stored") == []
  let assert Ok(_) = handler.store(ctx, ask, cube_response(True))
  assert recorded("stored") == ["analysis:" <> ask.key]
  let assert Ok(CubeAnswer(optimal: DoublePass, ..)) =
    puzzles.answer_from_json(kept_puzzle("new_puzzle").answer_json)
}

pub fn garbage_from_the_engine_writes_nothing_test() {
  let ask = ask_of(opening(#(3, 1)))
  let ctx = storing_ctx()
  let assert Error(_) = handler.store(ctx, ask, "{\"detail\":\"nope\"}")
  assert recorded("stored") == []
}

// ---------- GET /papi/analysis/:key ----------

pub fn the_status_follows_the_row_then_the_asker_test() {
  let s = opening(#(3, 1))
  let q = setup.question(s)
  let key = puzzles.key(q)
  let row = stored("abcdefgh", q, complete_move_answer([]))
  let ctx = holding(row, q, True)
  // A complete row is done whatever the asker remembers.
  let assert Ok(text) =
    handler.status_json(ctx, key, Some(analysis_caps.JobPending))
  assert status_of(text) == "done"
  let nothing = holding(row, q, True)
  let other = "0000"
  let assert Ok(text) =
    handler.status_json(nothing, other, Some(analysis_caps.JobPending))
  assert status_of(text) == "pending"
  let assert Ok(text) =
    handler.status_json(
      nothing,
      other,
      Some(analysis_caps.JobFailed(handler.engine_down_message)),
    )
  assert status_of(text) == "failed"
  let assert Ok(message) =
    json.parse(text, decode.at(["message"], decode.string))
  assert message == handler.engine_down_message
  let assert Error(err) = handler.status_json(nothing, other, None)
  assert error.status(err) == 404
}

// ---------- One reveal, two renderers ----------

fn complete_move_answer(boards: List(List(Int))) -> Answer {
  let boards = case boards {
    [] -> legal_boards(board.initial(), #(3, 1))
    _ -> boards
  }
  let probs = Probs(0.52, 0.14, 0.01, 0.12, 0.01)
  let costs = list.index_map(boards, fn(_, i) { 0.02 *. int.to_float(i) })
  MoveAnswer(
    outcomes: list.map(list.zip(boards, costs), fn(p) {
      Outcome(board: p.0, equity_lost: p.1)
    }),
    complete: True,
    n_legal: list.length(boards),
    candidates: list.zip(boards, costs)
      |> list.take(5)
      |> list.index_map(fn(p, i) {
        Candidate(
          rank: i + 1,
          notation: "play " <> int.to_string(i + 1),
          equity: 0.05 -. p.1,
          equity_lost: p.1,
          board: p.0,
          probs: probs,
        )
      }),
  )
}

/// The first legal path through the turn's tree: a whole play.
fn first_path(b: Board, roll: #(Int, Int)) -> List(#(String, String, Int)) {
  let assert Ok(t) = tree.build(b, tree.dice_of(roll), 100_000)
  walk(t, tree.root_id, [])
}

fn walk(
  t: tree.Tree,
  id: String,
  so_far: List(#(String, String, Int)),
) -> List(#(String, String, Int)) {
  let assert Some(node) = tree.node_by_id(t, id)
  case node.children {
    [] -> list.reverse(so_far)
    [c, ..] ->
      walk(t, c.node, [
        #(board.loc_id(c.from), board.loc_id(c.to), c.die),
        ..so_far
      ])
  }
}

fn field_of(text: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(text, decode.at(path, decode.dynamic))
  string.inspect(value)
}

pub fn the_reveal_is_the_attempts_own_rendering_test() {
  let q = openings.question(openings.start(), #(3, 1))
  let row = stored("abcdefgh", q, complete_move_answer([]))
  let assert Ok(reveal) = puzzle_page.reveal_json(row, levels_json)
  let reveal = json.to_string(reveal)
  let assert Ok(attempt) =
    puzzle_page.attempt_body(
      row,
      puzzle_page.Attempted(
        moves: first_path(board.initial(), #(3, 1)),
        band: None,
        key: "k",
      ),
    )
  list.each(["best", "top", "cube"], fn(name) {
    assert field_of(reveal, [name]) == field_of(attempt, [name])
  })
}

pub fn a_cube_reveal_is_the_attempts_own_rendering_test() {
  let q =
    puzzles.question_of(
      puzzles.Double,
      analysis.Position(
        board: analysis.encode(board.initial(), White),
        cube_value: 1,
        cube_owner: "centered",
        away1: 0,
        away2: 0,
        crawford: False,
      ),
      None,
      True,
    )
  let answer =
    CubeAnswer(
      no_double: 0.6,
      double_take: 1.4,
      double_pass: 1.0,
      probs: Some(Probs(0.7, 0.2, 0.01, 0.05, 0.0)),
      optimal: DoublePass,
      too_good: False,
    )
  let row = stored("cubecube", q, answer)
  let assert Ok(reveal) = puzzle_page.reveal_json(row, "{\"levels\":null}")
  let reveal = json.to_string(reveal)
  let assert Ok(attempt) =
    puzzle_page.attempt_body(
      row,
      puzzle_page.Attempted(moves: [], band: Some(1), key: "k"),
    )
  list.each(["best", "top", "cube"], fn(name) {
    assert field_of(reveal, [name]) == field_of(attempt, [name])
  })
  assert field_of(reveal, ["n_legal"]) == field_of(reveal, ["levels"])
}
