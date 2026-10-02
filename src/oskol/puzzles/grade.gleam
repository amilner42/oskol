//// Was that answer right? One rule, in one place, for the guest trying a
//// shared link and the account whose ladder moves on the result.
////
//// **A checker play is graded by where it leaves the board**, never by its
//// notation: the engine sent a result for every legal play, so an attempt
//// is looked up among them and costs exactly what it costs. Under 0.02
//// lost passes and 0.02 or more misses -- the site's own line between an
//// ok play and a doubtful one, the bands the replay already prints and the
//// threshold a puzzle is made at. There is no "close": a play the replay
//// would mark `?!` is a mistake, and there is a whole tier of the player's
//// own dubious moves to fix. A play the stored answer has no
//// result for is `Unknown`: old reviews kept only the five the engine
//// described, and telling somebody they were wrong on evidence we do not
//// have would be a lie. They grade themselves instead.
////
//// **A cube decision is graded by how far off the scale it was.** The three
//// equities are always the *doubler's* payoff, whichever side is being
//// asked, so both questions are read off the same numbers:
////
////   * the doubler compares doubling with not doubling. Doubling is worth
////     whatever the other side will let them have -- `min(DT, DP)` -- so the
////     margin is `min(DT, DP) - ND`, and a positive margin means double.
////   * the responder compares passing with taking, and picks whichever pays
////     the doubler *less*. The margin is `DP - DT`, and a positive margin
////     means take: taking is right exactly when it costs the doubler less
////     than the point a pass hands over.
////
//// A margin becomes one of five bands -- big (0.08 and up), plain (0.02 and
//// up), or borderline -- on either side of zero, numbered -2..+2, with +1
//// and +2 always the aggressive answer (double, take). The right side
//// passes and the wrong side misses. Borderline (band 0) is too close to
//// call: either side passes and neither gave anything up, since under 0.02
//// is inside the 4-ply engine's own noise on a cube decision. Outside it,
//// what the wrong side gave up is the margin itself (`cube_cost`).
////
//// The margins are `puzzles.double_margin` and `puzzles.take_margin`, the
//// very ones the cube call is read off (`puzzles.cube_call`), so a band and
//// the call beside it can never disagree about which side is right.

import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import oskol/puzzles.{
  type Answer, type Candidate, type Kind, CubeAnswer, Double, Move, MoveAnswer,
  Take,
}

/// How an answer went. `Unknown` is not a miss: it is "we cannot say".
pub type Verdict {
  Pass
  /// Legacy: grading produced it for a play that gave up 0.02 to 0.08
  /// until 2026-10-01, and never does now. It is still read off the
  /// `puzzle_attempts` rows written before then, because a retried key
  /// reports what its own attempt reported.
  Hold
  Fail
  Unknown
}

pub fn verdict_name(verdict: Verdict) -> String {
  case verdict {
    Pass -> "pass"
    Hold -> "hold"
    Fail -> "fail"
    Unknown -> "unknown"
  }
}

/// Within this of the best play, an answer is right. The same number as
/// `puzzles.mistake_threshold`: a pass is exactly a play that is not a
/// mistake.
pub const pass_within = 0.02

/// The margins that separate the five bands.
pub const big_margin = 0.08

pub const plain_margin = 0.02

/// Floats arrive rounded to two or three places, so a comparison that means
/// "0.02 or more" is made with a hair of room -- the same slack, and in the
/// same direction, as `puzzles.is_mistake`, because a pass is exactly a
/// play that is not a mistake. A band's own number belongs to the band it
/// opens: 0.02 lost is a doubtful play, not a right one.
const slack = 0.000001

// ---------- A checker play ----------

/// What a play cost, by the board it leaves: the engine's own result for it
/// when the answer holds every legal play, else the top candidate that
/// leaves that board, else nothing at all.
pub fn move_cost(answer: Answer, board: List(Int)) -> Option(Float) {
  case answer {
    MoveAnswer(outcomes: outcomes, candidates: candidates, ..) ->
      case list.find(outcomes, fn(o) { o.board == board }) {
        Ok(outcome) -> Some(outcome.equity_lost)
        Error(_) ->
          case list.find(candidates, fn(c) { c.board == board }) {
            Ok(candidate) -> Some(candidate.equity_lost)
            Error(_) -> None
          }
      }
    CubeAnswer(..) -> None
  }
}

/// A play's verdict from what it cost: right under 0.02, a miss from there
/// on.
pub fn move_verdict(cost: Option(Float)) -> Verdict {
  case cost {
    None -> Unknown
    Some(lost) ->
      case lost <. pass_within -. slack {
        True -> Pass
        False -> Fail
      }
  }
}

/// The band an answer's cost falls in, by the names the replay grades a
/// move with (`report.grade_names`): "best", "ok" (under 0.02), "doubtful"
/// (under 0.08), "bad" (under 0.16), "very_bad"; "unknown" when nothing
/// says what it cost. The same edges, with the same slack, as the verdict.
pub fn band_name(cost: Option(Float)) -> String {
  case cost {
    None -> "unknown"
    Some(lost) ->
      case
        lost <. slack,
        lost <. pass_within -. slack,
        lost <. big_margin -. slack,
        lost <. very_bad_from -. slack
      {
        True, _, _, _ -> "best"
        False, True, _, _ -> "ok"
        False, False, True, _ -> "doubtful"
        False, False, False, True -> "bad"
        False, False, False, False -> "very_bad"
      }
  }
}

/// Where a bad play ends and a very bad one starts.
const very_bad_from = 0.16

/// Where a play stands among all the legal ones: 1 for the best, counting
/// up. Read off the stored results, which is the only place every play is.
/// `None` when the answer does not hold that play at all.
pub fn move_rank(answer: Answer, board: List(Int)) -> Option(Int) {
  case answer {
    MoveAnswer(outcomes: outcomes, candidates: candidates, ..) ->
      case list.find(candidates, fn(c) { c.board == board }) {
        // A described candidate carries the engine's own rank; nothing
        // computed here may disagree with what the reveal prints.
        Ok(candidate) -> Some(candidate.rank)
        Error(_) ->
          case list.find(outcomes, fn(o) { o.board == board }) {
            Error(_) -> None
            Ok(mine) ->
              Some(
                1
                + list.count(outcomes, fn(o) {
                  o.equity_lost <. mine.equity_lost -. slack
                }),
              )
          }
      }
    CubeAnswer(..) -> None
  }
}

/// The five plays a reveal may show. The stored candidates are the engine's
/// top five *and*, when it fell outside them, the move the source game
/// played -- which is somebody's mistake and belongs to their memory line,
/// not to a public page.
pub fn top_five(answer: Answer) -> List(Candidate) {
  case answer {
    MoveAnswer(candidates: candidates, ..) ->
      list.filter(candidates, fn(c) { c.rank <= 5 })
    CubeAnswer(..) -> []
  }
}

pub fn best(answer: Answer) -> Option(Candidate) {
  top_five(answer)
  |> list.find(fn(c) { c.rank == 1 })
  |> option.from_result
}

// ---------- The cube ----------

/// The bands, -2..+2. `+1` and `+2` are always the aggressive answer: for
/// the doubler, double and big double; for the responder, take and big take.
/// The engine's verdict lands on one of the five; the player answers with a
/// side only, as at the table: double or not, take or pass.
pub const bands = [-2, -1, 0, 1, 2]

/// An answer is a side: positive for double or take, negative for no
/// double or pass. Zero is the engine's "too close to call", which is not
/// something a player can do with a cube.
pub fn band_in_range(band: Int) -> Bool {
  band >= -2 && band <= 2 && band != 0
}

/// How far the engine says this side should lean, from the three equities
/// it worked out for the doubler.
pub fn engine_band(kind: Kind, answer: Answer) -> Option(Int) {
  margin(kind, answer) |> option.map(band_of)
}

/// The margin for the side being asked, positive for the aggressive answer.
fn margin(kind: Kind, answer: Answer) -> Option(Float) {
  case answer {
    CubeAnswer(no_double: nd, double_take: dt, double_pass: dp, ..) ->
      case kind {
        Double -> Some(puzzles.double_margin(nd, dt, dp))
        Take -> Some(puzzles.take_margin(dt, dp))
        Move -> None
      }
    MoveAnswer(..) -> None
  }
}

/// What a side gave up: nothing on the side the margin leans to, the whole
/// margin on the other -- except inside band 0, where the call is too close
/// to call and both sides are equally right: nothing either way. The 4-ply
/// cube equities are not good to 0.02, so a reveal that called one side
/// "best" and the other merely "ok" over a margin of 0.003 would be grading
/// the engine's noise.
pub fn cube_cost(kind: Kind, answer: Answer, answered: Int) -> Option(Float) {
  use m <- option.map(margin(kind, answer))
  case band_of(m) == 0 || { answered > 0 } == { m >. 0.0 } {
    True -> 0.0
    False -> float.absolute_value(m)
  }
}

/// The margin as one of the five bands.
pub fn band_of(margin: Float) -> Int {
  let size = float.absolute_value(margin)
  case size <. plain_margin -. slack, size <. big_margin -. slack {
    True, _ -> 0
    False, True -> sign(margin)
    False, False -> 2 * sign(margin)
  }
}

fn sign(margin: Float) -> Int {
  case margin >. 0.0 {
    True -> 1
    False -> -1
  }
}

/// The verdict for a side against the engine's band: the right side
/// passes, the wrong side misses, and when the engine calls it too close
/// (within 0.02 either way) either side passes -- nobody fails a coin flip,
/// and giving up under 0.02 is not a mistake.
pub fn cube_verdict(answered: Int, engine: Int) -> Verdict {
  case engine == 0, { answered > 0 } == { engine > 0 } {
    True, _ -> Pass
    False, True -> Pass
    False, False -> Fail
  }
}
