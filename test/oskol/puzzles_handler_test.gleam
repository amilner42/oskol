//// The puzzle endpoints on stub capabilities.
////
//// The positions and the rules are real (a board, a roll, the move tree the
//// handler itself builds); the rows, the deck and the clock are a little
//// database in the process dictionary, so every branch -- who may see a
//// memory line, what a retry does, what an override replaces -- is checked
//// without a repo.

import backgammon/analysis
import backgammon/board.{type Board, Black, Point, White}
import backgammon/positions
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oskol/caps/analysis as analysis_caps
import oskol/caps/practice.{
  type Card, type Graded, type Outcome, Active, Again, Card, Graded, Known, New,
  Partial, Pass, Suspended, UnknownCard,
}
import oskol/caps/puzzles as puzzles_caps
import oskol/caps/records as records_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/core/session.{Session}
import oskol/fakes
import oskol/handlers/puzzles as handler
import oskol/puzzles.{
  type Answer, type Kind, type Probs, type Question, Candidate, CubeAnswer,
  Double, DoublePass, Move, MoveAnswer, Outcome as Result_, Probs, Question,
  Take,
}
import oskol/puzzles/tree

const now = 1_700_000_000_000

const day = 86_400_000

// ---------- The little database ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

@external(erlang, "erlang", "put")
fn put_attempts(key: String, value: List(puzzles_caps.Attempt)) -> Dynamic

@external(erlang, "erlang", "get")
fn get_attempts(key: String) -> List(puzzles_caps.Attempt)

@external(erlang, "erlang", "put")
fn put_cards(key: String, value: List(#(String, Card))) -> Dynamic

@external(erlang, "erlang", "get")
fn get_cards(key: String) -> List(#(String, Card))

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

fn reset() -> Nil {
  let _ = put("deck", [])
  let _ = put("records", [])
  let _ = put("turns", [])
  let _ = put("built", [])
  let _ = put("wrote", [])
  let _ = put("hits", [])
  let _ = put_trees("moves:big", [])
  let _ = put_attempts("attempts", [])
  let _ = put_cards("cards", [])
  Nil
}

// ---------- Puzzles to be asked ----------

/// White to play 6-4 with two runners on 13 and a blot on 7 to hit: three
/// ways to play it, which is enough for a pass, a hold and a miss.
fn hit_board() -> Board {
  positions.setup([
    #(White, Point(13), 2),
    #(White, Point(4), 4),
    #(White, Point(5), 4),
    #(White, Point(6), 5),
    #(Black, Point(1), 2),
    #(Black, Point(2), 2),
    #(Black, Point(7), 1),
    #(Black, Point(17), 3),
    #(Black, Point(18), 3),
    #(Black, Point(20), 2),
    #(Black, Point(21), 2),
  ])
}

fn move_question() -> Question {
  Question(
    kind: Move,
    board: analysis.encode(hit_board(), White),
    dice: Some(#(6, 4)),
    cube_value: 1,
    cube_owner: puzzles.Centered,
    away_mover: 3,
    away_opponent: 5,
    crawford: False,
    jacoby: False,
  )
}

fn probs() -> Probs {
  Probs(0.55, 0.12, 0.01, 0.1, 0.01)
}

/// The boards the three ways of playing 6-4 leave, best first: hit and run,
/// hit and hide, run and run.
fn move_outcomes() -> List(List(Int)) {
  let t = built()
  t.nodes
  |> list.filter(fn(n) { n.children == [] })
  |> list.map(fn(n) { analysis.encode(n.board, White) })
}

fn built() -> tree.Tree {
  let assert Ok(t) = tree.build(hit_board(), [6, 4], 1000)
  t
}

/// An answer the engine costed completely: every legal play, with the three
/// costs a pass, a hold and a miss need.
fn move_answer() -> Answer {
  let boards = move_outcomes()
  let costs = [0.0, 0.05, 0.4]
  MoveAnswer(
    outcomes: list.map(list.zip(boards, costs), fn(pair) {
      Result_(board: pair.0, equity_lost: pair.1)
    }),
    complete: True,
    n_legal: list.length(boards),
    candidates: list.index_map(list.zip(boards, costs), fn(pair, i) {
      Candidate(
        rank: i + 1,
        notation: "play " <> int.to_string(i + 1),
        equity: 0.5 -. pair.1,
        equity_lost: pair.1,
        board: pair.0,
        probs: probs(),
      )
    }),
  )
}

/// An old review: five plays described and nothing else, so an answer
/// outside them cannot be graded.
fn old_move_answer() -> Answer {
  let assert [best, ..] = move_outcomes()
  MoveAnswer(
    outcomes: [Result_(board: best, equity_lost: 0.0)],
    complete: False,
    n_legal: 3,
    candidates: [Candidate(1, "13/7*/3", 0.5, 0.0, best, probs())],
  )
}

fn cube_question(kind: Kind) -> Question {
  Question(
    kind: kind,
    board: analysis.encode(hit_board(), White),
    dice: None,
    cube_value: 1,
    cube_owner: puzzles.Mover,
    away_mover: 3,
    away_opponent: 5,
    crawford: False,
    jacoby: False,
  )
}

/// A clear double that the other side should pass: doubling is worth a
/// whole point more than playing on, and taking would cost the responder
/// more than passing.
fn cube_answer() -> Answer {
  CubeAnswer(
    no_double: 0.0,
    double_take: 1.4,
    double_pass: 1.0,
    probs: Some(probs()),
    optimal: DoublePass,
    too_good: False,
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

// ---------- The context ----------

fn ctx_with(rows: List(puzzles_caps.Stored)) -> Ctx {
  let base = fakes.ctx()
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(
      ..puzzles_caps.stub(),
      get: fn(id) {
        list.find(rows, fn(row) { row.id == id }) |> option.from_result
      },
      put_attempt: fn(puzzle_id, uid, key, answer, verdict) {
        case
          list.find(get_attempts("attempts"), fn(a) {
            a.puzzle_id == puzzle_id && a.user_id == uid && a.key == key
          })
        {
          Ok(existing) -> puzzles_caps.Attempt(..existing, fresh: False)
          Error(_) -> {
            record_call("wrote", puzzle_id <> ":" <> key <> ":" <> verdict)
            let row =
              puzzles_caps.Attempt(
                id: list.length(get_attempts("attempts")) + 1,
                puzzle_id: puzzle_id,
                user_id: uid,
                key: key,
                verdict: verdict,
                outcome: None,
                scheduled: False,
                review_id: None,
                schedule_json: "",
                fresh: True,
              )
            let _ = put_attempts("attempts", [row, ..get_attempts("attempts")])
            let _ = answer
            row
          }
        }
      },
      attempt: fn(puzzle_id, uid, key) {
        list.find(get_attempts("attempts"), fn(a) {
          a.puzzle_id == puzzle_id && a.user_id == uid && a.key == key
        })
        |> option.from_result
      },
      settle_attempt: fn(id, scheduled, review_id, outcome, schedule) {
        let _ =
          put_attempts(
            "attempts",
            list.map(get_attempts("attempts"), fn(a) {
              case a.id == id {
                False -> a
                True ->
                  puzzles_caps.Attempt(
                    ..a,
                    scheduled: scheduled,
                    review_id: option.or(review_id, a.review_id),
                    outcome: option.or(outcome, a.outcome),
                    schedule_json: case schedule {
                      "" -> a.schedule_json
                      text -> text
                    },
                  )
              }
            }),
          )
        Nil
      },
    ),
    practice: practice.PracticeCaps(
      ..practice.stub(),
      cards: fn(uid, keys) {
        list.filter_map(keys, fn(key) {
          list.find(get_cards("cards"), fn(c) { c.0 == held(uid, key) })
          |> result.map(fn(c) { c.1 })
        })
      },
      start: fn(uid, keys) {
        record_call("deck", "start:" <> string.join(keys, ","))
        list.each(keys, fn(key) { move_card(held(uid, key), Active, 0, now) })
        list.length(keys)
      },
      review: fn(uid, key, outcome) {
        record_call("deck", "review:" <> key <> ":" <> outcome_name(outcome))
        Ok(apply_outcome(held(uid, key), outcome))
      },
      amend: fn(uid, key, review_id, outcome) {
        record_call(
          "deck",
          "amend:"
            <> key
            <> ":"
            <> int.to_string(review_id)
            <> ":"
            <> outcome_name(outcome),
        )
        // A correction is applied to the level the card had *before* the
        // review it supersedes, which is what "replaces, never stacks"
        // means.
        case list.find(get_cards("cards"), fn(c) { c.0 == held(uid, key) }) {
          Error(_) -> Error(UnknownCard)
          Ok(#(_, card)) -> {
            let before = superseded_level(held(uid, key))
            move_card(held(uid, key), card.status, before, now)
            Ok(apply_outcome(held(uid, key), outcome))
          }
        }
      },
      defer_until: fn(uid, key, until) {
        record_call("deck", "defer:" <> key)
        case list.find(get_cards("cards"), fn(c) { c.0 == held(uid, key) }) {
          Error(_) -> Error(UnknownCard)
          Ok(#(_, card)) -> {
            move_card(held(uid, key), card.status, card.level, until)
            Ok(Graded(card.level, card.level, until, 0))
          }
        }
      },
      suspend: fn(uid, keys) {
        record_call("deck", "suspend:" <> string.join(keys, ","))
        list.each(keys, fn(key) {
          case list.find(get_cards("cards"), fn(c) { c.0 == held(uid, key) }) {
            Ok(#(_, card)) ->
              move_card(held(uid, key), Suspended, card.level, card.due_ms)
            Error(_) -> Nil
          }
        })
        list.length(keys)
      },
    ),
  )
}

/// The level a correction is applied to: the one the card had before the
/// review being corrected. The fake keeps it beside the card.
fn superseded_level(key: String) -> Int {
  case decode.run(get("before:" <> key), decode.int) {
    Ok(level) -> level
    Error(_) -> 0
  }
}

fn apply_outcome(key: String, outcome: Outcome) -> Graded {
  let assert Ok(#(_, card)) =
    list.find(get_cards("cards"), fn(c) { c.0 == key })
  let _ = put("before:" <> key, card.level)
  let after = case outcome {
    Pass -> card.level + 1
    Partial -> card.level
    // A miss goes back to the start, whatever level it had.
    Again -> 0
    practice.Fail -> int.max(0, card.level - 1)
    Known -> 7
  }
  let due = now + { after + 1 } * day
  move_card(key, Active, after, due)
  Graded(
    level_before: card.level,
    level_after: after,
    due_ms: due,
    review_id: 42,
  )
}

fn move_card(key: String, status: practice.Status, level: Int, due: Int) -> Nil {
  let rest = list.filter(get_cards("cards"), fn(c) { c.0 != key })
  let _ =
    put_cards("cards", [
      #(
        key,
        Card(
          key: key,
          tags: [],
          content_json: "{}",
          level: level,
          due_ms: due,
          reps: 0,
          lapses: 0,
          status: status,
        ),
      ),
      ..rest
    ])
  Nil
}

fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Pass -> "pass"
    Partial -> "partial"
    Again -> "again"
    Known -> "known"
    practice.Fail -> "fail"
  }
}

/// One deck's card, named the way the real one is: an account and a key.
fn held(uid: String, key: String) -> String {
  uid <> "|" <> key
}

fn deck_holds(key: String, status: practice.Status, level: Int, due: Int) -> Nil {
  deck_holds_for("u1", key, status, level, due)
}

fn deck_holds_for(
  uid: String,
  key: String,
  status: practice.Status,
  level: Int,
  due: Int,
) -> Nil {
  move_card(held(uid, key), status, level, due)
}

fn guest(id: String) -> session.Session {
  Session(guest_id: Some(id), user_id: None)
}

fn account(id: String) -> session.Session {
  Session(guest_id: Some("g-" <> id), user_id: Some(id))
}

// ---------- Reading the payloads back ----------

fn field(body: String, name: String) -> Dynamic {
  let assert Ok(value) = json.parse(body, decode.at([name], decode.dynamic))
  value
}

fn text_at(body: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.string))
  value
}

fn int_at(body: String, path: List(String)) -> Int {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.int))
  value
}

fn bool_at(body: String, path: List(String)) -> Bool {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.bool))
  value
}

fn is_null(body: String, name: String) -> Bool {
  decode.run(field(body, name), decode.optional(decode.dynamic)) == Ok(None)
}

// ---------- GET /papi/puzzles/:id ----------

pub fn a_move_puzzle_carries_its_question_and_its_moves_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = handler.puzzle_json(ctx, "p1")
  assert text_at(body, ["id"]) == "p1"
  assert text_at(body, ["kind"]) == "move"
  assert text_at(body, ["prompt"]) == "White to play 6-4. What's your play?"
  assert int_at(body, ["question", "score", "mover_away"]) == 3
  assert text_at(body, ["question", "cube", "owner"]) == "center"
  // The mover is White, and the board is numbered from their side.
  assert int_at(body, ["question", "board", "white", "bar"]) == 0
  assert text_at(body, ["tree", "root"]) == tree.root_id
  // And the answer is nowhere in it.
  assert !string.contains(body, "equity")
  assert !string.contains(body, "outcomes")
  assert !string.contains(body, "candidates")
}

pub fn a_double_puzzle_has_no_dice_and_no_tree_test() {
  reset()
  let ctx = ctx_with([stored("d1", cube_question(Double), cube_answer())])
  let assert Ok(body) = handler.puzzle_json(ctx, "d1")
  assert text_at(body, ["kind"]) == "double"
  assert text_at(body, ["prompt"]) == "Double?"
  assert is_null(body, "tree")
  assert is_null(body, "question") == False
  assert decode.run(
      field(body, "question"),
      decode.at(["dice"], decode.optional(decode.dynamic)),
    )
    == Ok(None)
}

/// A take is stored from the doubler's side and asked of the responder, so
/// the board is turned around before it is shown: what the responder sees
/// is their own checkers running 24 -> 1, and a cube the *opponent* owns.
pub fn a_take_puzzle_is_shown_from_the_responders_side_test() {
  reset()
  let ctx = ctx_with([stored("t1", cube_question(Take), cube_answer())])
  let assert Ok(body) = handler.puzzle_json(ctx, "t1")
  assert text_at(body, ["kind"]) == "take"
  assert text_at(body, ["prompt"]) == "Take?"
  // The doubler held the cube; from the responder's side the opponent does.
  assert text_at(body, ["question", "cube", "owner"]) == "opponent"
  // And the away scores swap with the sides.
  assert int_at(body, ["question", "score", "mover_away"]) == 5
  assert int_at(body, ["question", "score", "opponent_away"]) == 3
  // The board really is the other way round: the doubler's two runners on
  // 13 are the opponent's now, on point 12 as the responder numbers them.
  let assert Ok(black) =
    json.parse(
      body,
      decode.at(
        ["question", "board", "black", "points"],
        decode.list(decode.int),
      ),
    )
  assert list.drop(black, 11) |> list.first == Ok(2)
}

pub fn an_unknown_puzzle_is_a_404_test() {
  reset()
  let ctx = ctx_with([])
  assert handler.puzzle_json(ctx, "nope")
    == Error(error.NotFound(handler.not_found_message))
}

/// A tree is worked out once and kept, because it is a pure function of a
/// question that is never rewritten.
pub fn a_tree_is_only_built_once_test() {
  reset()
  let base = ctx_with([stored("p1", move_question(), move_answer())])
  let ctx =
    Ctx(
      ..base,
      puzzles: puzzles_caps.PuzzlesCaps(
        ..base.puzzles,
        cached_tree: fn(id) {
          case recorded("kept") {
            [text, ..] -> {
              record_call("hits", id)
              Some(text)
            }
            [] -> None
          }
        },
        keep_tree: fn(_id, text) {
          let _ = put("kept", [text])
          Nil
        },
      ),
    )
  let assert Ok(first) = handler.puzzle_json(ctx, "p1")
  let assert Ok(again) = handler.puzzle_json(ctx, "p1")
  assert first == again
  assert recorded("hits") == ["p1"]
}

// ---------- POST /papi/puzzles/:id/attempts ----------

/// The path a tree walk takes to one of the three ways of playing 6-4.
fn path_to(index: Int) -> List(#(String, String, Int)) {
  let t = built()
  let assert Ok(root) = list.find(t.nodes, fn(n) { n.id == tree.root_id })
  let terminals = t.nodes |> list.filter(fn(n) { n.children == [] })
  let assert Ok(wanted) = list.drop(terminals, index) |> list.first
  let assert Ok(path) = find_path(t, root, wanted.id, [])
  path
}

fn find_path(
  t: tree.Tree,
  from: tree.Node,
  wanted: String,
  so_far: List(#(String, String, Int)),
) -> Result(List(#(String, String, Int)), Nil) {
  case from.id == wanted {
    True -> Ok(list.reverse(so_far))
    False ->
      list.fold(from.children, Error(Nil), fn(found, child) {
        case found {
          Ok(_) -> found
          Error(_) ->
            case list.find(t.nodes, fn(n) { n.id == child.node }) {
              Error(_) -> Error(Nil)
              Ok(next) ->
                find_path(t, next, wanted, [
                  #(board.loc_id(child.from), board.loc_id(child.to), child.die),
                  ..so_far
                ])
            }
        }
      })
  }
}

fn attempt(
  ctx: Ctx,
  session: session.Session,
  id: String,
  moves: List(#(String, String, Int)),
  key: String,
) -> Result(String, error.ApiError) {
  handler.attempt_json(
    ctx,
    session,
    id,
    handler.Attempted(moves: moves, band: None, key: key),
    now,
  )
}

fn band_attempt(
  ctx: Ctx,
  session: session.Session,
  id: String,
  band: Int,
  key: String,
) -> Result(String, error.ApiError) {
  handler.attempt_json(
    ctx,
    session,
    id,
    handler.Attempted(moves: [], band: Some(band), key: key),
    now,
  )
}

pub fn the_three_verdicts_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(best) = attempt(ctx, guest("g1"), "p1", path_to(0), "k1")
  assert text_at(best, ["verdict"]) == "pass"
  let assert Ok(middle) = attempt(ctx, guest("g1"), "p1", path_to(1), "k2")
  assert text_at(middle, ["verdict"]) == "hold"
  let assert Ok(worst) = attempt(ctx, guest("g1"), "p1", path_to(2), "k3")
  assert text_at(worst, ["verdict"]) == "fail"
}

/// The reveal: what they played, the best, and the top five -- and never
/// the sixth, which is only ever somebody's own mistake.
pub fn an_attempt_reveals_the_answer_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, guest("g1"), "p1", path_to(1), "k1")
  assert int_at(body, ["yours", "rank"]) == 2
  assert int_at(body, ["best", "rank"]) == 1
  assert text_at(body, ["best", "notation"]) == "play 1"
  assert int_at(body, ["yours", "position", "white", "bar"]) == 0
  assert is_null(body, "cube")
  // The play they made really is the one the reveal describes.
  let assert Ok(landed) =
    json.parse(body, decode.at(["yours", "landed"], decode.list(decode.int)))
  assert landed != []
}

/// A play outside a five-candidate answer cannot be graded, so nobody is
/// told they were wrong: the best is shown, the verdict is unknown, and the
/// player is asked to grade themselves.
pub fn a_play_an_old_answer_cannot_grade_is_unknown_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), old_move_answer())])
  let assert Ok(body) = attempt(ctx, guest("g1"), "p1", path_to(2), "k1")
  assert text_at(body, ["verdict"]) == "unknown"
  assert is_null(body, "yours")
  assert int_at(body, ["best", "rank"]) == 1
}

pub fn an_illegal_path_is_refused_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  // A move that is not a child of the root.
  assert attempt(ctx, guest("g1"), "p1", [#("13", "1", 6)], "k1")
    == Error(error.validation_failed(handler.bad_move_message))
  // A move that is not a move at all.
  assert attempt(ctx, guest("g1"), "p1", [#("", "", 0)], "k2")
    == Error(error.validation_failed(handler.bad_move_message))
}

/// Half a turn is not an answer: PLAY is offered where nothing more can be
/// played, and only there.
pub fn an_unfinished_turn_is_refused_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert [first, ..] = path_to(0)
  assert attempt(ctx, guest("g1"), "p1", [first], "k1")
    == Error(error.validation_failed(handler.bad_move_message))
  // And the empty path, on a roll that can be played, is refused too.
  assert attempt(ctx, guest("g1"), "p1", [], "k2")
    == Error(error.validation_failed(handler.bad_move_message))
}

pub fn a_cube_answer_is_graded_on_the_five_band_scale_test() {
  reset()
  let ctx =
    ctx_with([
      stored("d1", cube_question(Double), cube_answer()),
      stored("t1", cube_question(Take), cube_answer()),
    ])
  // Doubling is worth min(1.4, 1.0) - 0.0 = 1.0 more than not doubling: a
  // big double.
  let assert Ok(body) = band_attempt(ctx, guest("g1"), "d1", 2, "k1")
  assert text_at(body, ["verdict"]) == "pass"
  assert int_at(body, ["cube", "band"]) == 2
  assert bool_at(body, ["cube", "too_good"]) == False
  // Taking pays the doubler 1.4 where passing pays 1.0, so the responder
  // passes, and passes big.
  let assert Ok(take) = band_attempt(ctx, guest("g1"), "t1", -2, "k2")
  assert text_at(take, ["verdict"]) == "pass"
  assert int_at(take, ["cube", "band"]) == -2
  // One band out holds, two miss.
  let assert Ok(near) = band_attempt(ctx, guest("g1"), "t1", -1, "k3")
  assert text_at(near, ["verdict"]) == "hold"
  let assert Ok(far) = band_attempt(ctx, guest("g1"), "t1", 0, "k4")
  assert text_at(far, ["verdict"]) == "fail"
}

/// Both kinds, every band: the engine's own band comes back, and the
/// verdict is the distance from it. The whole matrix is checked over the
/// equities in puzzles_grade_test; this is the same rule reached through
/// the endpoint.
pub fn every_band_is_graded_through_the_endpoint_test() {
  reset()
  let ctx =
    ctx_with([
      stored("d1", cube_question(Double), cube_answer()),
      stored("t1", cube_question(Take), cube_answer()),
    ])
  // Doubling is worth a whole point more than playing on (+2); taking pays
  // the doubler 1.4 where passing pays 1.0, so the responder passes (-2).
  list.each([#("d1", 2), #("t1", -2)], fn(side) {
    let #(id, engine) = side
    list.each([-2, -1, 0, 1, 2], fn(band) {
      let key = id <> int.to_string(band)
      let assert Ok(body) = band_attempt(ctx, guest("g1"), id, band, key)
      assert int_at(body, ["cube", "band"]) == engine
      let wanted = case band - engine {
        0 -> "pass"
        1 | -1 -> "hold"
        _ -> "fail"
      }
      assert text_at(body, ["verdict"]) == wanted
    })
  })
}

/// Too good to double: the engine says no double because playing on is
/// worth more than the point a pass would hand over. The reveal says so, so
/// a page can explain why the answer is "no double" without the player
/// thinking the position is weak.
pub fn a_too_good_position_says_so_test() {
  reset()
  let too_good =
    CubeAnswer(
      no_double: 1.4,
      double_take: 0.9,
      double_pass: 1.0,
      probs: Some(probs()),
      optimal: puzzles.NoDouble,
      too_good: True,
    )
  let ctx = ctx_with([stored("d1", cube_question(Double), too_good)])
  // min(0.9, 1.0) - 1.4 = -0.5: a big no double.
  let assert Ok(body) = band_attempt(ctx, guest("g1"), "d1", -2, "k1")
  assert text_at(body, ["verdict"]) == "pass"
  assert int_at(body, ["cube", "band"]) == -2
  assert bool_at(body, ["cube", "too_good"]) == True
  // And doubling it anyway is four bands out.
  let assert Ok(wrong) = band_attempt(ctx, guest("g1"), "d1", 2, "k2")
  assert text_at(wrong, ["verdict"]) == "fail"
}

pub fn a_band_outside_the_scale_is_refused_test() {
  reset()
  let ctx = ctx_with([stored("d1", cube_question(Double), cube_answer())])
  assert band_attempt(ctx, guest("g1"), "d1", 3, "k1")
    == Error(error.validation_failed(handler.bad_band_message))
  assert band_attempt(ctx, guest("g1"), "d1", -3, "k2")
    == Error(error.validation_failed(handler.bad_band_message))
  assert handler.attempt_json(
      ctx,
      guest("g1"),
      "d1",
      handler.Attempted(moves: [], band: None, key: "k3"),
      now,
    )
    == Error(error.validation_failed(handler.bad_band_message))
}

// ---------- What it does to a deck ----------

pub fn a_guest_is_graded_and_nothing_is_written_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, guest("g1"), "p1", path_to(0), "k1")
  assert text_at(body, ["verdict"]) == "pass"
  assert is_null(body, "schedule")
  assert recorded("wrote") == []
  assert recorded("deck") == []
}

pub fn a_puzzle_outside_the_deck_is_graded_and_forgotten_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert text_at(body, ["verdict"]) == "pass"
  assert is_null(body, "schedule")
  assert recorded("wrote") == []
}

pub fn a_due_card_moves_up_a_level_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert int_at(body, ["schedule", "level_before"]) == 2
  assert int_at(body, ["schedule", "level_after"]) == 3
  assert bool_at(body, ["schedule", "amendable"]) == True
  assert bool_at(body, ["schedule", "self_grade"]) == False
  assert int_at(body, ["schedule", "due"]) > now
  assert recorded("deck") == ["review:p1:pass"]
}

/// A miss goes back to the start, whatever level it had, and comes back
/// tomorrow.
pub fn a_miss_goes_back_to_the_start_test() {
  reset()
  deck_holds("p1", Active, 5, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(2), "k1")
  assert text_at(body, ["verdict"]) == "fail"
  assert int_at(body, ["schedule", "level_after"]) == 0
  assert recorded("deck") == ["review:p1:again"]
}

pub fn a_hold_keeps_its_level_test() {
  reset()
  deck_holds("p1", Active, 4, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(1), "k1")
  assert int_at(body, ["schedule", "level_after"]) == 4
  assert recorded("deck") == ["review:p1:partial"]
}

/// A card nobody has seen is introduced by being answered.
pub fn a_new_card_is_started_by_being_answered_test() {
  reset()
  deck_holds("p1", New, 0, now + 10 * day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert int_at(body, ["schedule", "level_after"]) == 1
  assert recorded("deck") == ["review:p1:pass", "start:p1"]
}

/// The same key twice is one attempt: the same answer comes back and the
/// ladder does not move again.
pub fn a_retried_key_changes_nothing_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(first) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  let assert Ok(again) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert first == again
  assert recorded("deck") == ["review:p1:pass"]
  assert recorded("wrote") == ["p1:k1:pass"]
}

/// A second tab, with its own key, while the card has already been
/// answered: graded and revealed, and the ladder stands where the first
/// answer left it.
pub fn a_second_answer_at_the_same_opportunity_changes_nothing_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(_) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  let assert Ok(second) = attempt(ctx, account("u1"), "p1", path_to(2), "k2")
  assert text_at(second, ["verdict"]) == "fail"
  assert int_at(second, ["schedule", "level_before"]) == 3
  assert int_at(second, ["schedule", "level_after"]) == 3
  assert bool_at(second, ["schedule", "amendable"]) == False
  assert recorded("deck") == ["review:p1:pass"]
}

/// A card that has been put aside is graded like any other and the deck is
/// not touched.
pub fn a_suspended_card_is_graded_and_left_alone_test() {
  reset()
  deck_holds("p1", Suspended, 3, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert text_at(body, ["verdict"]) == "pass"
  assert is_null(body, "schedule")
  assert recorded("deck") == []
}

/// An answer the engine cannot grade schedules nothing automatically: the
/// card waits until tomorrow rather than sitting due in front of new
/// material, and the player is asked to grade themselves.
pub fn an_unknown_answer_waits_until_tomorrow_test() {
  reset()
  deck_holds("p1", Active, 3, now - day)
  let ctx = ctx_with([stored("p1", move_question(), old_move_answer())])
  let assert Ok(body) = attempt(ctx, account("u1"), "p1", path_to(2), "k1")
  assert text_at(body, ["verdict"]) == "unknown"
  assert bool_at(body, ["schedule", "self_grade"]) == True
  assert bool_at(body, ["schedule", "amendable"]) == False
  assert int_at(body, ["schedule", "level_after"]) == 3
  assert int_at(body, ["schedule", "due"]) == now + day
  assert recorded("deck") == ["defer:p1"]
}

pub fn a_signed_in_answer_needs_a_key_test() {
  reset()
  deck_holds("p1", Active, 0, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  assert attempt(ctx, account("u1"), "p1", path_to(0), "")
    == Error(error.validation_failed(handler.no_key_message))
}

// ---------- The override ----------

fn override(
  ctx: Ctx,
  session: session.Session,
  id: String,
  key: String,
  outcome: String,
) -> Result(String, error.ApiError) {
  handler.outcome_json(ctx, session, id, key, outcome)
}

/// SOONER after a pass lands at level 0 once: the correction replaces the
/// review rather than stacking on it, so a pass followed by a miss is a
/// miss, not "a level up and then one down".
pub fn an_override_replaces_the_review_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(graded) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert int_at(graded, ["schedule", "level_after"]) == 3
  let assert Ok(body) = override(ctx, account("u1"), "p1", "k1", "sooner")
  assert int_at(body, ["schedule", "level_before"]) == 2
  assert int_at(body, ["schedule", "level_after"]) == 0
  assert recorded("deck") == ["amend:p1:42:again", "review:p1:pass"]
  // And a second thought corrects the same row again, never the correction.
  let assert Ok(twice) = override(ctx, account("u1"), "p1", "k1", "knew_it")
  assert int_at(twice, ["schedule", "level_after"]) == 7
  let assert [newest, ..] = recorded("deck")
  assert newest == "amend:p1:42:known"
}

pub fn got_it_keeps_the_engines_own_grade_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(_) = attempt(ctx, account("u1"), "p1", path_to(1), "k1")
  let assert Ok(_) = override(ctx, account("u1"), "p1", "k1", "got_it")
  let assert [newest, ..] = recorded("deck")
  assert newest == "amend:p1:42:partial"
}

/// An answer the engine could not grade has no review to correct, so the
/// player's own word is the first one -- and it holds the level rather than
/// moving it up, because nothing checked the claim.
pub fn a_self_grade_writes_the_first_review_test() {
  reset()
  deck_holds("p1", Active, 3, now - day)
  let ctx = ctx_with([stored("p1", move_question(), old_move_answer())])
  let assert Ok(graded) = attempt(ctx, account("u1"), "p1", path_to(2), "k1")
  assert bool_at(graded, ["schedule", "self_grade"]) == True
  let assert Ok(body) = override(ctx, account("u1"), "p1", "k1", "got_it")
  assert int_at(body, ["schedule", "level_after"]) == 3
  let assert [newest, ..] = recorded("deck")
  assert newest == "review:p1:partial"
  // SOONER on the same answer is still a miss, and KNEW IT still the top.
  let assert Ok(sooner) = override(ctx, account("u1"), "p1", "k1", "sooner")
  assert int_at(sooner, ["schedule", "level_after"]) == 0
}

/// An answer that never had an opportunity has nothing to grade, and the
/// override may not invent one. The card was not due, so the attempt
/// scheduled nothing and said `self_grade: false`.
pub fn a_self_grade_on_an_answer_that_had_no_opportunity_is_refused_test() {
  reset()
  deck_holds("p1", Active, 3, now + 5 * day)
  let ctx = ctx_with([stored("p1", move_question(), old_move_answer())])
  let assert Ok(graded) = attempt(ctx, account("u1"), "p1", path_to(2), "k1")
  assert text_at(graded, ["verdict"]) == "unknown"
  assert bool_at(graded, ["schedule", "self_grade"]) == False
  assert bool_at(graded, ["schedule", "amendable"]) == False
  assert override(ctx, account("u1"), "p1", "k1", "got_it")
    == Error(error.Conflict(
      "nothing_to_amend",
      handler.nothing_to_amend_message,
    ))
  assert recorded("deck") == []
}

/// NEVER is a deck action, not a correction: it puts the card aside, and
/// there is nothing left to say about when it comes back.
pub fn never_puts_the_card_aside_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(graded) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  let assert Ok(body) = override(ctx, account("u1"), "p1", "k1", "never")
  let assert [newest, ..] = recorded("deck")
  assert newest == "suspend:p1"
  // The answer's own schedule stands: suspending is something done to the
  // card, not a correction of what the answer reported.
  assert int_at(body, ["schedule", "level_after"])
    == int_at(graded, ["schedule", "level_after"])
  // So a retry of that answer is still the same reply.
  let assert Ok(again) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert again == graded
  // And there is nothing left to override.
  assert override(ctx, account("u1"), "p1", "k1", "sooner")
    == Error(error.Conflict(
      "nothing_to_amend",
      handler.nothing_to_amend_message,
    ))
  // Pressing it twice is the same action and answers the same way.
  let assert Ok(twice) = override(ctx, account("u1"), "p1", "k1", "never")
  assert twice == body
}

/// A key is a uuid the browser made up, and it means something only inside
/// the account that sent it. Somebody else's key names nothing here, so it
/// cannot reach their attempt -- and an override of it is not refused with
/// "not yours", which would confirm it exists; it simply is not there.
pub fn a_key_only_means_something_in_its_own_account_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(mine) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert int_at(mine, ["schedule", "level_after"]) == 3

  // The same key from another account is another attempt entirely: it is
  // graded on its own, and it does not touch the first one.
  deck_holds_for("u2", "p1", Active, 0, now - day)
  let assert Ok(theirs) = attempt(ctx, account("u2"), "p1", path_to(2), "k1")
  assert text_at(theirs, ["verdict"]) == "fail"
  assert list.length(get_attempts("attempts")) == 2

  // And neither can override the other's.
  assert override(ctx, account("u2"), "p1", "k1", "sooner")
    != Error(error.Forbidden(handler.not_yours_message))
  let assert Ok(ours) = override(ctx, account("u1"), "p1", "k1", "sooner")
  assert int_at(ours, ["schedule", "level_after"]) == 0
}

/// A browser that is not signed in has no attempt of its own anywhere, and
/// is told so without being told whether anybody else's exists.
pub fn an_override_from_a_guest_is_refused_test() {
  reset()
  deck_holds("p1", Active, 2, now - day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(_) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert override(ctx, guest("g1"), "p1", "k1", "sooner")
    == Error(error.Forbidden(handler.not_yours_message))
  assert override(ctx, session.anonymous(), "p1", "k1", "sooner")
    == Error(error.Forbidden(handler.not_yours_message))
}

pub fn an_override_with_nothing_to_amend_is_a_conflict_test() {
  reset()
  // The card was not due, so the attempt scheduled nothing and there is no
  // review to correct.
  deck_holds("p1", Active, 2, now + 5 * day)
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Ok(_) = attempt(ctx, account("u1"), "p1", path_to(0), "k1")
  assert override(ctx, account("u1"), "p1", "k1", "sooner")
    == Error(error.Conflict(
      "nothing_to_amend",
      handler.nothing_to_amend_message,
    ))
}

pub fn an_override_of_an_attempt_that_is_not_there_is_a_404_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  assert override(ctx, account("u1"), "p1", "never-sent", "sooner")
    == Error(error.NotFound(handler.not_found_message))
}

pub fn an_override_that_is_not_one_of_the_four_is_refused_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  let assert Error(refusal) = override(ctx, account("u1"), "p1", "k1", "maybe")
  assert error.status(refusal) == 422
}

// ---------- GET /papi/puzzles/:id/mine ----------

fn setup_with(
  seats: List(#(String, String, String, String)),
) -> records_caps.Setup {
  records_caps.Setup(
    slug: "backgammon",
    format: "match3",
    clock: "none",
    seed: 7,
    seats: seats,
    finished: True,
    records_stale: False,
  )
}

fn source_room(
  seats: List(#(String, String, String, String)),
  player_id: String,
) -> puzzles_caps.SourceRoom {
  puzzles_caps.SourceRoom(
    source: puzzles_caps.Source(
      id: 1,
      puzzle_id: "p1",
      kind: "move",
      game_id: "000011",
      game_number: 2,
      turn: 3,
      seat: 0,
      player_id: player_id,
      played: "24/23 13/11",
      equity_lost: 0.14,
      grade: "bad",
      date: "2026-09-12",
      question_json: "",
    ),
    slug: "backgammon",
    seats: seats,
  )
}

const two_seats = [
  #("p1", "Arie", "guest-a", ""),
  #("p2", "Charlie", "guest-c", ""),
]

fn mine_ctx(rooms: List(puzzles_caps.SourceRoom)) -> Ctx {
  let base = ctx_with([stored("p1", move_question(), move_answer())])
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(..base.puzzles, mine: fn(_, _, _) {
      rooms
    }),
    records: records_caps.RecordsCaps(
      ..records_caps.stub(),
      // Only this game's row is ever read: a match's other games have
      // nothing to say about who won this one.
      entries_of: fn(_, number) {
        record_call("records", int.to_string(number))
        case number {
          2 ->
            Some(
              "[{\"kind\":\"turn\"},{\"kind\":\"game_over\",\"number\":2,\"winner\":\"p2\",\"points\":2}]",
            )
          _ -> None
        }
      },
      numbers: fn(_) { [1, 2] },
      setup: fn(_) { Some(setup_with(two_seats)) },
    ),
    analysis: analysis_caps.AnalysisCaps(
      ..analysis_caps.stub(),
      // And only this turn of the review: a report is hundreds of
      // kilobytes and the answer is three integers.
      report_turn: fn(_, _, turn) {
        record_call("turns", int.to_string(turn))
        case turn {
          3 -> Some("{\"entry\":5,\"double_entry\":4,\"answer_entry\":6}")
          // A double nobody offered has no line of its own.
          4 -> Some("{\"entry\":9,\"double_entry\":null,\"answer_entry\":null}")
          _ -> None
        }
      },
    ),
  )
}

/// The player who made the mistake: their own move, what it cost, and the
/// moment in the replay it came from.
pub fn the_mover_sees_their_own_mistake_test() {
  reset()
  let ctx = mine_ctx([source_room(two_seats, "p1")])
  let assert Ok(body) = handler.mine_json(ctx, guest("guest-a"), "p1")
  assert text_at(body, ["who"]) == "you"
  assert text_at(body, ["played"]) == "24/23 13/11"
  assert text_at(body, ["grade"]) == "bad"
  assert text_at(body, ["date"]) == "2026-09-12"
  // Turn 3 is record line 5, and a step is the line after the one before
  // it, so step 6.
  assert text_at(body, ["replay"]) == "/backgammon/000011/replay?game=2&step=6"
  // They lost that game, by two points.
  assert bool_at(body, ["result", "won"]) == False
  assert int_at(body, ["result", "points"]) == 2
}

/// The person it was made against sees it too, by name -- it is their game
/// as much as anyone's.
pub fn the_opponent_sees_whose_mistake_it_was_test() {
  reset()
  let ctx = mine_ctx([source_room(two_seats, "p1")])
  let assert Ok(body) = handler.mine_json(ctx, guest("guest-c"), "p1")
  assert text_at(body, ["who"]) == "Arie"
  assert bool_at(body, ["result", "won"]) == True
}

/// A seat an account owns answers to the account, from any browser, and the
/// guest sitting on it holds nothing.
pub fn an_owned_seat_answers_to_its_account_test() {
  reset()
  let seats = [
    #("p1", "Arie", "old-guest", "user-1"),
    #("p2", "Charlie", "guest-c", ""),
  ]
  let ctx = mine_ctx([source_room(seats, "p1")])
  let assert Ok(body) =
    handler.mine_json(
      ctx,
      Session(guest_id: Some("some-other-browser"), user_id: Some("user-1")),
      "p1",
    )
  assert text_at(body, ["who"]) == "you"
  // And the browser whose guest used to hold it holds nothing now.
  assert handler.mine_json(ctx, guest("old-guest"), "p1")
    == Error(error.NotFound(handler.no_memory_message))
}

pub fn a_stranger_gets_no_memory_line_test() {
  reset()
  let ctx = mine_ctx([source_room(two_seats, "p1")])
  assert handler.mine_json(ctx, guest("nobody"), "p1")
    == Error(error.NotFound(handler.no_memory_message))
  assert handler.mine_json(ctx, session.anonymous(), "p1")
    == Error(error.NotFound(handler.no_memory_message))
  // A puzzle nobody here played is the same answer.
  let empty = mine_ctx([])
  assert handler.mine_json(empty, guest("guest-a"), "p1")
    == Error(error.NotFound(handler.no_memory_message))
}

/// A cube decision points at the line the cube was turned on, not the one
/// the checkers moved on.
pub fn a_cube_mistake_points_at_its_own_line_test() {
  reset()
  let room = source_room(two_seats, "p1")
  let cube =
    puzzles_caps.SourceRoom(
      ..room,
      source: puzzles_caps.Source(..room.source, kind: "double"),
    )
  let ctx = mine_ctx([cube])
  let assert Ok(body) = handler.mine_json(ctx, guest("guest-a"), "p1")
  assert text_at(body, ["replay"]) == "/backgammon/000011/replay?game=2&step=5"
}

// ---------- GET /papi/games/:slug/rooms/:id/puzzles?game=n ----------

fn game_ctx(sources: List(puzzles_caps.Source)) -> Ctx {
  let base = ctx_with([])
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(..base.puzzles, game_sources: fn(_, _) {
      sources
    }),
    records: records_caps.RecordsCaps(
      ..records_caps.stub(),
      setup: fn(_) { Some(setup_with(two_seats)) },
      numbers: fn(_) { [1, 2] },
    ),
  )
}

fn source(
  puzzle_id: String,
  kind: String,
  player_id: String,
  turn: Int,
  question: Question,
) -> puzzles_caps.Source {
  puzzles_caps.Source(
    id: turn,
    puzzle_id: puzzle_id,
    kind: kind,
    game_id: "000011",
    game_number: 2,
    turn: turn,
    seat: 0,
    player_id: player_id,
    played: "13/7",
    equity_lost: 0.1,
    grade: "bad",
    date: "2026-09-12",
    question_json: json.to_string(puzzles.question_json(question)),
  )
}

pub fn a_games_puzzles_are_the_seats_own_test() {
  reset()
  let ctx =
    game_ctx([
      source("a1", "move", "p1", 3, move_question()),
      source("b1", "double", "p2", 4, cube_question(Double)),
      source("c1", "take", "p1", 6, cube_question(Take)),
      // A decision no puzzle was written for.
      source("", "move", "p1", 8, move_question()),
    ])
  let assert Ok(body) =
    handler.game_puzzles_json(ctx, guest("guest-a"), "backgammon", "000011", 2)
  assert int_at(body, ["game"]) == 2
  let assert Ok(ids) =
    json.parse(body, decode.at(["puzzles"], decode.list(id_decoder())))
  assert ids
    == [
      #("a1", "move", "White to play 6-4. What's your play?", False),
      #("c1", "take", "Take?", False),
    ]
  // The other seat sees their own, and only theirs.
  let assert Ok(theirs) =
    handler.game_puzzles_json(ctx, guest("guest-c"), "backgammon", "000011", 2)
  let assert Ok(their_ids) =
    json.parse(theirs, decode.at(["puzzles"], decode.list(id_decoder())))
  assert list.map(their_ids, fn(p) { p.0 }) == ["b1"]
}

fn id_decoder() -> decode.Decoder(#(String, String, String, Bool)) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use prompt <- decode.field("prompt", decode.string)
  use due <- decode.field("due", decode.bool)
  decode.success(#(id, kind, prompt, due))
}

pub fn a_spectator_gets_no_games_puzzles_test() {
  reset()
  let ctx = game_ctx([source("a1", "move", "p1", 3, move_question())])
  assert handler.game_puzzles_json(
      ctx,
      guest("nobody"),
      "backgammon",
      "000011",
      2,
    )
    == Error(error.NotFound(handler.no_game_message))
}

pub fn a_game_the_room_never_played_is_a_404_test() {
  reset()
  let ctx = game_ctx([source("a1", "move", "p1", 3, move_question())])
  assert handler.game_puzzles_json(
      ctx,
      guest("guest-a"),
      "backgammon",
      "000011",
      9,
    )
    == Error(error.NotFound(handler.no_game_message))
  // And a slug that is not this room's game.
  assert handler.game_puzzles_json(ctx, guest("guest-a"), "chess", "000011", 2)
    == Error(error.NotFound(handler.no_game_message))
}

// ---------- The level-at-a-time fallback ----------

pub fn a_tree_level_answers_for_a_node_this_puzzle_minted_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  // The ids come from the puzzle's own answer, which is the only place a
  // page ever gets one.
  let assert Ok(shown) = handler.puzzle_json(ctx, "p1")
  let assert Ok(child) =
    json.parse(
      shown,
      decode.at(
        ["tree", "nodes", tree.root_id, "children"],
        decode.list(decode.at(["node"], decode.string)),
      ),
    )
  let assert [first, ..] = child
  let assert Ok(body) = handler.tree_node_json(ctx, "p1", first)
  assert text_at(body, ["node"]) == first
  assert bool_at(body, ["tree", "terminal"]) == False
  let assert Ok(children) =
    json.parse(
      body,
      decode.at(["tree", "children"], decode.list(decode.dynamic)),
    )
  assert list.length(children) == 2
  // And the root itself is a node like any other.
  let assert Ok(root) = handler.tree_node_json(ctx, "p1", tree.root_id)
  assert bool_at(root, ["tree", "terminal"]) == False
}

/// An id this puzzle never minted is nothing at all. There is no board in
/// an id to be made up, so nothing a caller sends can put the server to
/// work on a position of their choosing.
pub fn a_node_id_from_nowhere_is_refused_test() {
  reset()
  let ctx = ctx_with([stored("p1", move_question(), move_answer())])
  assert handler.tree_node_json(ctx, "p1", "made-up")
    == Error(error.NotFound(handler.not_found_message))
  assert handler.tree_node_json(ctx, "p1", "")
    == Error(error.NotFound(handler.not_found_message))
  // A node id that is real in some other puzzle is not real in this one:
  // the lookup is scoped to the tree that minted it.
  assert handler.tree_node_json(ctx, "nosuchpz", tree.root_id)
    == Error(error.NotFound(handler.not_found_message))
  // A cube puzzle has no tree to walk.
  let cube = ctx_with([stored("d1", cube_question(Double), cube_answer())])
  assert handler.tree_node_json(cube, "d1", tree.root_id)
    == Error(error.NotFound(handler.not_found_message))
}

/// A turn too big to send whole is worked out once and kept, and every
/// level after that is a lookup in it -- never a fresh search, and never
/// one a stranger can ask for on a board of their own choosing.
pub fn a_lazy_puzzle_is_built_once_and_walked_test() {
  reset()
  let ctx = lazy_ctx()
  let assert Ok(shown) = handler.puzzle_json(ctx, "big")
  // The root alone, and it says so.
  assert bool_at(shown, ["tree", "lazy"]) == True
  let assert Ok(ids) =
    json.parse(
      shown,
      decode.at(["tree", "nodes"], decode.dict(decode.string, decode.dynamic)),
    )
  assert dict.size(ids) == 1
  // Built once: the second look, and every level, reads the store.
  assert recorded("built") == ["big"]
  let assert Ok(children) =
    json.parse(
      shown,
      decode.at(
        ["tree", "nodes", tree.root_id, "children"],
        decode.list(decode.at(["node"], decode.string)),
      ),
    )
  let assert [first, ..] = children
  let assert Ok(_) = handler.tree_node_json(ctx, "big", first)
  let assert Ok(_) = handler.tree_node_json(ctx, "big", first)
  assert recorded("built") == ["big"]
}

/// The spread-out double-ones the tree contract was frozen against: too
/// big for the wire, and kept so the page can walk it.
fn lazy_ctx() -> Ctx {
  let spread =
    positions.setup(
      list.append(
        list.range(10, 24) |> list.map(fn(p) { #(White, Point(p), 1) }),
        [
          #(Black, Point(1), 4),
          #(Black, Point(2), 4),
          #(Black, Point(3), 4),
          #(Black, Point(4), 3),
        ],
      ),
    )
  let question =
    Question(
      ..move_question(),
      board: analysis.encode(spread, White),
      dice: Some(#(1, 1)),
    )
  let base = ctx_with([stored("big", question, move_answer())])
  Ctx(
    ..base,
    puzzles: puzzles_caps.PuzzlesCaps(
      ..base.puzzles,
      cached_moves: fn(id) {
        case get_trees("moves:" <> id) {
          [whole, ..] -> Some(whole)
          [] -> None
        }
      },
      keep_moves: fn(id, whole) {
        record_call("built", id)
        let _ = put_trees("moves:" <> id, [whole])
        Nil
      },
    ),
  )
}

@external(erlang, "erlang", "put")
fn put_trees(key: String, value: List(tree.Tree)) -> Dynamic

@external(erlang, "erlang", "get")
fn get_trees(key: String) -> List(tree.Tree)
