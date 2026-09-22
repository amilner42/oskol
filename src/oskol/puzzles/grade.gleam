//// Was that answer right? One rule, in one place, for the guest trying a
//// shared link and the account whose ladder moves on the result.
////
//// **A checker play is graded by where it leaves the board**, never by its
//// notation: the engine sent a result for every legal play, so an attempt
//// is looked up among them and costs exactly what it costs. Within 0.02 of
//// the best passes, under 0.08 holds, worse misses -- the site's own bands,
//// the ones the replay already prints. A play the stored answer has no
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
//// and +2 always the aggressive answer (double, take). The grade is the
//// distance between the bands: the same band passes, one off holds, two or
//// more misses. So Double when the engine says Borderline holds; Double
//// when it says No double misses.

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

/// Within this of the best play, an answer is right.
pub const pass_within = 0.02

/// Up to this, it holds its level rather than passing or missing.
pub const hold_within = 0.08

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

/// A play's verdict from what it cost.
pub fn move_verdict(cost: Option(Float)) -> Verdict {
  case cost {
    None -> Unknown
    Some(lost) ->
      case lost <. pass_within -. slack, lost <. hold_within -. slack {
        True, _ -> Pass
        False, True -> Hold
        False, False -> Fail
      }
  }
}

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
pub const bands = [-2, -1, 0, 1, 2]

pub fn band_in_range(band: Int) -> Bool {
  band >= -2 && band <= 2
}

/// How far the engine says this side should lean, from the three equities
/// it worked out for the doubler.
pub fn engine_band(kind: Kind, answer: Answer) -> Option(Int) {
  case answer {
    CubeAnswer(no_double: nd, double_take: dt, double_pass: dp, ..) ->
      case kind {
        Double -> Some(band_of(float.min(dt, dp) -. nd))
        Take -> Some(band_of(dp -. dt))
        Move -> None
      }
    MoveAnswer(..) -> None
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

/// The verdict for an answer on the five-band scale: the same band passes,
/// one off holds, two or more misses.
pub fn cube_verdict(answered: Int, engine: Int) -> Verdict {
  case int_absolute(answered - engine) {
    0 -> Pass
    1 -> Hold
    _ -> Fail
  }
}

fn int_absolute(value: Int) -> Int {
  case value < 0 {
    True -> -value
    False -> value
  }
}
