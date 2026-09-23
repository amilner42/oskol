//// TRY ONE on stub capabilities: which puzzle stands clear enough to be a
//// stranger's first, what the endpoint answers, and the honest 404 while
//// the pool has nothing to offer. The pool itself is a stub that answers
//// what a test hands it; nothing here reaches a database.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/puzzles.{type Stored, PuzzlesCaps, Stored} as _
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/puzzles_hub as hub
import oskol/puzzles.{
  type Answer, type Candidate, type Probs, type Question, Candidate, Centered,
  CubeAnswer, Double, DoubleTake, Move, MoveAnswer, NoDouble, Outcome, Probs,
  Question, Take,
}

// ---------- Puzzles to choose from ----------

fn question(kind: puzzles.Kind) -> Question {
  Question(
    kind: kind,
    board: list.repeat(0, 26),
    dice: case kind {
      Move -> Some(#(6, 4))
      _ -> None
    },
    cube_value: 1,
    cube_owner: Centered,
    away_mover: 0,
    away_opponent: 0,
    crawford: False,
    jacoby: False,
  )
}

fn probs() -> Probs {
  Probs(
    win: 0.5,
    gammon_win: 0.1,
    backgammon_win: 0.0,
    gammon_loss: 0.1,
    backgammon_loss: 0.0,
  )
}

fn candidate(rank: Int, lost: Float) -> Candidate {
  Candidate(
    rank: rank,
    notation: "13/7 13/9",
    equity: 0.1 -. lost,
    equity_lost: lost,
    board: list.repeat(0, 26),
    probs: probs(),
  )
}

/// A checker play whose runner-up gives up `second`, complete.
fn move_answer(second: Float) -> Answer {
  MoveAnswer(
    outcomes: [
      Outcome(board: list.repeat(0, 26), equity_lost: 0.0),
      Outcome(board: list.repeat(1, 26), equity_lost: second),
      Outcome(board: list.repeat(2, 26), equity_lost: second +. 0.1),
    ],
    complete: True,
    n_legal: 3,
    candidates: [
      candidate(1, 0.0),
      candidate(2, second),
      candidate(3, second +. 0.1),
    ],
  )
}

/// A cube question with these three equities (the doubler's), complete.
fn cube_answer(nd: Float, dt: Float, dp: Float) -> Answer {
  CubeAnswer(
    no_double: nd,
    double_take: dt,
    double_pass: dp,
    probs: Some(probs()),
    optimal: case dt >. nd {
      True -> DoubleTake
      False -> NoDouble
    },
    too_good: False,
  )
}

fn stored(id: String, kind: puzzles.Kind, answer: Answer) -> Stored {
  Stored(
    id: id,
    kind: puzzles.kind_name(kind),
    question_json: json.to_string(puzzles.question_json(question(kind))),
    answer_json: json.to_string(puzzles.answer_json(answer)),
  )
}

/// A pool that answers these, in this order, and records how many were
/// asked for.
fn with_pool(ctx: Ctx, pool: List(Stored)) -> Ctx {
  Ctx(
    ..ctx,
    puzzles: PuzzlesCaps(..ctx.puzzles, sample: fn(n) {
      assert n == hub.sample_size
      list.take(pool, n)
    }),
  )
}

// ---------- The rule ----------

pub fn a_checker_play_stands_clear_when_the_runner_up_is_a_mistake_test() {
  // 0.02 is the site's doubtful line: at it, the second-best play is a
  // mistake and the best stands clear.
  assert hub.clear(stored("a", Move, move_answer(0.02)))
  assert hub.clear(stored("a", Move, move_answer(0.11)))
  // Under it, two plays the engine could barely tell apart: a coin toss,
  // not a first puzzle.
  assert !hub.clear(stored("a", Move, move_answer(0.019)))
  assert !hub.clear(stored("a", Move, move_answer(0.0)))
}

pub fn a_checker_play_with_nothing_to_choose_between_never_stands_clear_test() {
  // One legal play, one candidate: nothing to ask.
  let forced =
    MoveAnswer(
      outcomes: [Outcome(board: list.repeat(0, 26), equity_lost: 0.0)],
      complete: True,
      n_legal: 1,
      candidates: [candidate(1, 0.0)],
    )
  assert !hub.clear(stored("a", Move, forced))
}

pub fn an_incomplete_answer_never_stands_clear_test() {
  // An old five-candidate row could not grade a stranger's answer
  // outside its five, whatever its margin.
  let old =
    MoveAnswer(outcomes: [], complete: False, n_legal: 20, candidates: [
      candidate(1, 0.0),
      candidate(2, 0.2),
    ])
  assert !hub.clear(stored("a", Move, old))
  let no_probs =
    CubeAnswer(
      no_double: 0.5,
      double_take: 0.7,
      double_pass: 1.0,
      probs: None,
      optimal: DoubleTake,
      too_good: False,
    )
  assert !hub.clear(stored("a", Double, no_probs))
}

pub fn a_cube_stands_clear_only_on_a_big_call_test() {
  // The doubler's margin is min(DT, DP) - ND: 0.08 either way is the outer
  // band of the scale.
  assert hub.clear(stored("a", Double, cube_answer(0.5, 0.6, 1.0)))
  // A big no double.
  assert hub.clear(stored("a", Double, cube_answer(0.5, 0.4, 1.0)))
  // A plain double (0.05): one band in, not clear.
  assert !hub.clear(stored("a", Double, cube_answer(0.5, 0.55, 1.0)))
  // Borderline.
  assert !hub.clear(stored("a", Double, cube_answer(0.5, 0.51, 1.0)))
}

pub fn a_take_is_judged_on_the_responders_margin_test() {
  // DP - DT: positive means take. 1.0 - 0.6 = 0.4, a big take.
  assert hub.clear(stored("a", Take, cube_answer(0.5, 0.6, 1.0)))
  // A pass by 0.05: one band, not clear.
  assert !hub.clear(stored("a", Take, cube_answer(0.5, 1.05, 1.0)))
  // A big pass.
  assert hub.clear(stored("a", Take, cube_answer(0.5, 1.2, 1.0)))
}

pub fn a_row_that_does_not_read_as_a_puzzle_never_stands_clear_test() {
  assert !hub.clear(Stored(
    id: "bad",
    kind: "move",
    question_json: "{}",
    answer_json: "{}",
  ))
}

// ---------- The endpoint ----------

pub fn try_one_is_the_first_of_the_sample_that_stands_clear_test() {
  // The sample is already in the database's random order, so the first
  // that qualifies is a random one that does: here the second entry.
  let ctx =
    with_pool(fakes.ctx(), [
      stored("close", Move, move_answer(0.01)),
      stored("clear", Move, move_answer(0.05)),
      stored("also", Double, cube_answer(0.5, 0.6, 1.0)),
    ])
  let assert Ok(body) = hub.random_json(ctx)
  assert string.contains(body, "\"id\":\"clear\"")
  assert string.contains(body, "\"kind\":\"move\"")
  assert string.contains(
    body,
    "\"prompt\":\"White to play 6-4. What's your play?\"",
  )
  // Never the answer.
  assert !string.contains(body, "equity")
  assert !string.contains(body, "notation")
}

pub fn an_empty_pool_is_an_honest_404_test() {
  let assert Error(refusal) = hub.random_json(with_pool(fakes.ctx(), []))
  assert error.status(refusal) == 404
  assert error.message(refusal) == hub.empty_pool_message
}

pub fn a_pool_with_nothing_clear_in_it_is_the_same_404_test() {
  let ctx =
    with_pool(fakes.ctx(), [
      stored("close", Move, move_answer(0.01)),
      stored("plain", Double, cube_answer(0.5, 0.55, 1.0)),
    ])
  let assert Error(refusal) = hub.random_json(ctx)
  assert error.status(refusal) == 404
}
