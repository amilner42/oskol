//// The practice home's one endpoint of its own:
////
////   GET /papi/puzzles/random     TRY ONE -- a puzzle for a stranger
////
//// A stranger with no games behind them has no mistakes to practice, so
//// the home offers one puzzle from the public pool. Not any puzzle: one
//// whose best move stands clear, so that a first taste is a fair question
//// and not a coin toss between two plays the engine could barely tell
//// apart. A checker play qualifies when the second-best play gives up
//// 0.02 or more against the best (the site's own "doubtful" line); a cube
//// question when the engine's call is a big one either way (0.08 or more
//// of margin: the outer bands of the five-band scale). Only a complete
//// answer is offered, because a stranger's first answer must be gradable.
////
//// Everything here is a read: nothing is written, started or scheduled,
//// and nothing about who is asking changes the answer.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/caps/puzzles.{type Stored} as _
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError, NotFound}
import oskol/puzzles.{type Answer, type Question, CubeAnswer, MoveAnswer}
import oskol/puzzles/grade

/// How many of the pool are looked at for one that stands clear. Most do,
/// so a sample this size finds one whenever the pool holds any.
pub const sample_size = 40

/// What the home says while the pool has nothing to offer.
pub const empty_pool_message = "There are no puzzles yet. Play a game, and the mistakes the engine finds in it become the first."

/// A random puzzle whose answer stands clear, as a session lists one --
/// id, kind and the question -- or a 404 that says so honestly.
pub fn random_json(ctx: Ctx) -> Result(String, ApiError) {
  use stored <- result.try(random(ctx))
  use question <- result.try(question_of(stored))
  Ok(
    envelope.ok([
      #("id", json.string(stored.id)),
      #("kind", json.string(puzzles.kind_name(question.kind))),
      #("prompt", json.string(puzzles.prompt(question))),
    ]),
  )
}

/// The first of the sample that stands clear. The sample is already in a
/// random order, so the first that qualifies is a random one that does.
pub fn random(ctx: Ctx) -> Result(Stored, ApiError) {
  ctx.puzzles.sample(sample_size)
  |> list.find(clear)
  |> result.replace_error(NotFound(empty_pool_message))
}

/// Does this puzzle's best answer stand clear of the rest? A stored row
/// that does not read as a puzzle at all never does.
pub fn clear(stored: Stored) -> Bool {
  case question_of(stored), puzzles.answer_from_json(stored.answer_json) {
    Ok(question), Ok(answer) -> clear_answer(question, answer)
    _, _ -> False
  }
}

/// The rule itself, on the typed answer: a checker play whose runner-up
/// is a mistake, a cube whose call is a big one -- and complete either way.
pub fn clear_answer(question: Question, answer: Answer) -> Bool {
  case puzzles.complete(answer), answer {
    False, _ -> False
    True, MoveAnswer(candidates: candidates, ..) ->
      case runner_up(candidates) {
        Ok(second) -> puzzles.is_mistake(second.equity_lost)
        // A forced play, or an answer with one candidate written down:
        // nothing to choose between, so nothing to ask.
        Error(Nil) -> False
      }
    True, CubeAnswer(..) ->
      case grade.engine_band(question.kind, answer) {
        Some(band) -> int.absolute_value(band) == 2
        None -> False
      }
  }
}

/// The second-ranked candidate: what the best play is measured against.
fn runner_up(
  candidates: List(puzzles.Candidate),
) -> Result(puzzles.Candidate, Nil) {
  list.find(candidates, fn(c) { c.rank == 2 })
}

fn question_of(stored: Stored) -> Result(Question, ApiError) {
  puzzles.question_from_json(stored.question_json)
  |> result.map_error(fn(_) { NotFound(empty_pool_message) })
}
