//// The one grading rule: what a checker play costs, and how far off a cube
//// answer was.
////
//// The cube matrix is the whole table -- all twenty-five (answer, engine)
//// pairs -- for the doubler and for the responder alike, because the two
//// are read off the same three equities and a sign the wrong way round
//// would tell half the players the opposite of the truth.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import oskol/core/raw
import oskol/puzzles.{
  Candidate, CubeAnswer, Double, DoublePass, DoubleTake, Move, MoveAnswer,
  NoDouble, Outcome, Probs, Take,
}
import oskol/puzzles/fixture
import oskol/puzzles/grade.{Fail, Pass, Unknown}
import oskol/reviews/report

fn probs() -> puzzles.Probs {
  Probs(0.5, 0.1, 0.01, 0.1, 0.01)
}

/// A complete answer: the engine costed every legal play.
fn complete(costs: List(#(List(Int), Float))) -> puzzles.Answer {
  MoveAnswer(
    outcomes: list.map(costs, fn(c) { Outcome(board: c.0, equity_lost: c.1) }),
    complete: True,
    n_legal: list.length(costs),
    candidates: [
      Candidate(1, "13/7 13/9", 0.5, 0.0, first_board(costs), probs()),
    ],
  )
}

fn first_board(costs: List(#(List(Int), Float))) -> List(Int) {
  case costs {
    [first, ..] -> first.0
    [] -> []
  }
}

// ---------- A checker play ----------

pub fn a_play_within_a_fiftieth_passes_test() {
  let answer = complete([#([1], 0.0), #([2], 0.019), #([3], 0.02)])
  assert grade.move_verdict(grade.move_cost(answer, [1])) == Pass
  assert grade.move_verdict(grade.move_cost(answer, [2])) == Pass
  // The band is "under 0.02", and 0.02 itself is the next one: a mistake by
  // the site's own definition cannot be a pass.
  assert grade.move_verdict(grade.move_cost(answer, [3])) == Fail
}

/// There is no "close": a play the replay would mark `?!` is a miss, the
/// very thing the dubious tier is made of.
pub fn a_dubious_play_is_a_miss_test() {
  let answer =
    complete([#([1], 0.0), #([2], 0.05), #([3], 0.079), #([4], 0.08)])
  assert grade.move_verdict(grade.move_cost(answer, [2])) == Fail
  assert grade.move_verdict(grade.move_cost(answer, [3])) == Fail
  assert grade.move_verdict(grade.move_cost(answer, [4])) == Fail
}

/// The band an answer fell in, at every edge, by the names the replay
/// grades a move with.
pub fn the_band_of_a_cost_test() {
  assert grade.band_name(None) == "unknown"
  assert grade.band_name(Some(0.0)) == "best"
  assert grade.band_name(Some(0.001)) == "ok"
  assert grade.band_name(Some(0.019)) == "ok"
  assert grade.band_name(Some(0.02)) == "doubtful"
  assert grade.band_name(Some(0.079)) == "doubtful"
  assert grade.band_name(Some(0.08)) == "bad"
  assert grade.band_name(Some(0.159)) == "bad"
  assert grade.band_name(Some(0.16)) == "very_bad"
  assert grade.band_name(Some(1.2)) == "very_bad"
  // Every name a cost can have is one the replay grades with.
  list.each([0.0, 0.01, 0.05, 0.1, 0.5], fn(cost) {
    assert list.contains(report.grade_names, grade.band_name(Some(cost)))
  })
}

/// The verdict and the band say the same thing: a pass is best or ok, a
/// miss is doubtful or worse.
pub fn the_verdict_and_the_band_agree_test() {
  list.each([0.0, 0.019, 0.02, 0.079, 0.08, 0.159, 0.16, 0.9], fn(cost) {
    let band = grade.band_name(Some(cost))
    assert case grade.move_verdict(Some(cost)) {
      Pass -> band == "best" || band == "ok"
      _ -> band != "best" && band != "ok"
    }
  })
}

/// The bands are the engine's own: every graded play in the seeded match
/// (twelve games the real engine graded) falls in the band it was named.
pub fn the_band_agrees_with_the_engine_test() {
  let assert Ok(bytes) = read_file("priv/dev/rooms/821900.json")
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert Ok(answers) =
    json.parse(
      text,
      decode.at(
        ["reviews"],
        decode.list({
          use response <- decode.field("response", decode.dynamic)
          decode.success(response)
        }),
      ),
    )
  let graded =
    list.flat_map(answers, fn(answer) {
      let assert Ok(review) = report.parse(raw.text(answer))
      list.filter_map(review.turns, fn(turn) {
        case turn.move {
          Some(report.Moved(forced: False, error: error, grade: name, ..)) ->
            Ok(#(error, name))
          _ -> Error(Nil)
        }
      })
    })
  assert list.length(graded) > 100
  list.each(graded, fn(pair) {
    assert grade.band_name(Some(pair.0)) == pair.1
  })
}

@external(erlang, "oskol_test_files", "read")
fn read_file(path: String) -> Result(BitArray, Dynamic)

pub fn a_play_the_answer_never_heard_of_is_unknown_test() {
  let answer = complete([#([1], 0.0), #([2], 0.05)])
  assert grade.move_cost(answer, [9]) == None
  assert grade.move_verdict(grade.move_cost(answer, [9])) == Unknown
}

/// An old review kept five plays and no more. A play among them is graded
/// exactly; anything else is honestly unknown rather than wrong.
pub fn an_old_five_candidate_answer_grades_what_it_can_test() {
  let answer =
    MoveAnswer(
      outcomes: [Outcome([1], 0.0), Outcome([2], 0.3)],
      complete: False,
      n_legal: 17,
      candidates: [
        Candidate(1, "8/5 6/5", 0.4, 0.0, [1], probs()),
        Candidate(2, "24/21 13/11", 0.1, 0.3, [2], probs()),
      ],
    )
  assert grade.move_verdict(grade.move_cost(answer, [1])) == Pass
  assert grade.move_verdict(grade.move_cost(answer, [2])) == Fail
  assert grade.move_verdict(grade.move_cost(answer, [7])) == Unknown
}

/// Where a play stands among every legal one. A play the engine described
/// keeps the rank the engine gave it; one it only costed is ranked by what
/// it cost, which is the same ordering.
pub fn a_play_is_ranked_among_every_legal_one_test() {
  let answer = complete([#([1], 0.0), #([2], 0.05), #([3], 0.02), #([4], 0.4)])
  assert grade.move_rank(answer, [1]) == Some(1)
  assert grade.move_rank(answer, [3]) == Some(2)
  assert grade.move_rank(answer, [2]) == Some(3)
  assert grade.move_rank(answer, [4]) == Some(4)
  assert grade.move_rank(answer, [9]) == None
}

/// A reveal shows the engine's top five and never the sixth, because a
/// sixth candidate is only ever there because it is the move somebody
/// played -- which is their memory line, not a public page.
pub fn the_reveal_shows_five_plays_at_most_test() {
  let answer =
    MoveAnswer(
      outcomes: [],
      complete: False,
      n_legal: 20,
      candidates: list.map([1, 2, 3, 4, 5, 11], fn(rank) {
        Candidate(
          rank,
          "play " <> int.to_string(rank),
          0.0,
          0.0,
          [rank],
          probs(),
        )
      }),
    )
  assert list.map(grade.top_five(answer), fn(c) { c.rank }) == [1, 2, 3, 4, 5]
  assert option.map(grade.best(answer), fn(c) { c.rank }) == Some(1)
}

// ---------- The cube ----------

/// The five bands off a margin, on the boundaries.
pub fn a_margin_becomes_one_of_five_bands_test() {
  assert grade.band_of(0.5) == 2
  assert grade.band_of(0.08) == 2
  assert grade.band_of(0.079) == 1
  assert grade.band_of(0.02) == 1
  assert grade.band_of(0.019) == 0
  assert grade.band_of(0.0) == 0
  assert grade.band_of(-0.019) == 0
  assert grade.band_of(-0.02) == -1
  assert grade.band_of(-0.079) == -1
  assert grade.band_of(-0.08) == -2
  assert grade.band_of(-0.5) == -2
}

/// A cube answer whose equities put the engine on a named band. All three
/// are the doubler's payoff, whichever side is asked.
fn cube(nd: Float, dt: Float, dp: Float) -> puzzles.Answer {
  CubeAnswer(
    no_double: nd,
    double_take: dt,
    double_pass: dp,
    probs: Some(probs()),
    optimal: puzzles.cube_call(nd, dt, dp),
    too_good: puzzles.too_good(nd, dp),
  )
}

/// One answer per band, for the side being asked. These are the positions
/// the matrix below is run over.
fn doubler_at(band: Int) -> puzzles.Answer {
  case band {
    2 -> cube(0.0, 0.2, 1.0)
    1 -> cube(0.0, 0.05, 1.0)
    0 -> cube(0.0, 0.01, 1.0)
    -1 -> cube(0.1, 0.05, 1.0)
    _ -> cube(0.5, 0.05, 1.0)
  }
}

fn responder_at(band: Int) -> puzzles.Answer {
  case band {
    // Taking pays the doubler half a point where passing pays them a whole
    // one, so the responder takes and it is not close.
    2 -> cube(0.0, 0.5, 1.0)
    1 -> cube(0.0, 0.95, 1.0)
    0 -> cube(0.0, 0.99, 1.0)
    // Taking pays the doubler *more* than passing does: the sign that
    // matters, and the one an inverted margin would get backwards.
    -1 -> cube(0.0, 1.05, 1.0)
    _ -> cube(0.0, 1.5, 1.0)
  }
}

pub fn the_engine_band_reads_off_the_equities_test() {
  list.each(grade.bands, fn(band) {
    assert grade.engine_band(Double, doubler_at(band)) == Some(band)
    assert grade.engine_band(Take, responder_at(band)) == Some(band)
  })
  // A checker question has no cube band, and a cube question has no
  // checker answer.
  assert grade.engine_band(Move, doubler_at(0)) == None
  assert grade.engine_band(Double, complete([#([1], 0.0)])) == None
}

/// Taking pays the doubler more than passing would, so the responder should
/// pass -- and the scale says so, on the negative side. This is the one
/// place a sign could be inverted without any other test noticing.
pub fn taking_that_pays_the_doubler_more_is_a_pass_test() {
  let answer = responder_at(-2)
  assert grade.engine_band(Take, answer) == Some(-2)
  // The same position asked of the doubler: doubling is worth min(DT, DP),
  // which is the pass, and that is a whole point better than not doubling.
  assert grade.engine_band(Double, answer) == Some(2)
  // Answering "take" against a big pass is the wrong side and misses;
  // answering "pass" is the right side and passes, however big.
  assert grade.cube_verdict(1, -2) == Fail
  assert grade.cube_verdict(-1, -2) == Pass
}

/// Both sides against every band, for the doubler and the responder: the
/// right side passes, the wrong side misses, and a coin flip passes either
/// way. What the side gave up agrees: nothing on the right side, the
/// margin on the wrong one, and its band says the verdict again.
pub fn the_whole_cube_matrix_test() {
  list.each([-1, 1], fn(answered) {
    list.each(grade.bands, fn(engine) {
      let wanted = case engine == 0, { answered > 0 } == { engine > 0 } {
        True, _ -> Pass
        False, True -> Pass
        False, False -> Fail
      }
      let assert Some(doubler) = grade.engine_band(Double, doubler_at(engine))
      let assert Some(responder) = grade.engine_band(Take, responder_at(engine))
      assert grade.cube_verdict(answered, doubler) == wanted
      assert grade.cube_verdict(answered, responder) == wanted
      list.each(
        [#(Double, doubler_at(engine)), #(Take, responder_at(engine))],
        fn(asked) {
          let assert Some(cost) = grade.cube_cost(asked.0, asked.1, answered)
          let band = grade.band_name(Some(cost))
          assert case wanted {
            Pass -> band == "best" || band == "ok"
            _ -> band != "best" && band != "ok"
          }
        },
      )
    })
  })
}

/// What a cube answer gave up, in numbers: at band +1 (a margin of 0.05
/// for the doubler) doubling costs nothing and not doubling 0.05; at band
/// 0 neither side gave anything up.
pub fn what_a_cube_answer_gave_up_test() {
  let assert Some(cost) = grade.cube_cost(Double, doubler_at(1), 1)
  assert cost == 0.0
  assert grade.band_name(Some(cost)) == "best"
  let assert Some(cost) = grade.cube_cost(Double, doubler_at(1), -1)
  assert float.loosely_equals(cost, 0.05, 0.000001)
  assert grade.band_name(Some(cost)) == "doubtful"
  let assert Some(cost) = grade.cube_cost(Double, doubler_at(0), -1)
  assert cost == 0.0
  assert grade.band_name(Some(cost)) == "best"
  let assert Some(cost) = grade.cube_cost(Take, responder_at(-2), 1)
  assert grade.band_name(Some(cost)) == "very_bad"
  assert grade.cube_cost(Move, doubler_at(1), 1) == None
}

/// Too close to call is correct either way: inside 0.02, on either side of
/// the line, both answers pass, cost nothing and read "best" -- for the
/// doubler and for the responder. 0.021 is the control: a plain call, where
/// the side against it misses and gives up the margin.
pub fn too_close_to_call_is_right_either_way_test() {
  // The margin each side is asked about, as the equities that make it.
  let doubler = fn(m: Float) { cube(0.2, 0.2 +. m, 1.0) }
  let responder = fn(m: Float) { cube(0.0, 1.0 -. m, 1.0) }
  list.each([0.003, -0.003, 0.019, -0.019, 0.0], fn(m) {
    list.each([#(Double, doubler(m)), #(Take, responder(m))], fn(asked) {
      let assert Some(engine) = grade.engine_band(asked.0, asked.1)
      assert engine == 0
      list.each([1, -1], fn(answered) {
        assert grade.cube_verdict(answered, engine) == Pass
        assert grade.cube_cost(asked.0, asked.1, answered) == Some(0.0)
        assert grade.band_name(grade.cube_cost(asked.0, asked.1, answered))
          == "best"
      })
    })
  })
  list.each([0.021, -0.021], fn(m) {
    list.each([#(Double, doubler(m)), #(Take, responder(m))], fn(asked) {
      let assert Some(engine) = grade.engine_band(asked.0, asked.1)
      let right = case m >. 0.0 {
        True -> 1
        False -> -1
      }
      assert engine == right
      assert grade.cube_verdict(right, engine) == Pass
      assert grade.cube_cost(asked.0, asked.1, right) == Some(0.0)
      assert grade.cube_verdict(-right, engine) == Fail
      let assert Some(cost) = grade.cube_cost(asked.0, asked.1, -right)
      assert float.loosely_equals(cost, 0.021, 0.000001)
      assert grade.band_name(Some(cost)) == "doubtful"
    })
  })
}

/// The cube call, read off the three equities and nothing else: double iff
/// min(DT, DP) > ND, take iff DT <= DP, too good iff ND > DP. At, just
/// above and just below each line, for each of the four calls.
pub fn the_cube_call_reads_off_the_equities_test() {
  // No double / double: the line is min(DT, DP) = ND.
  assert puzzles.cube_call(0.221, 0.224, 1.0) == DoubleTake
  assert puzzles.cube_call(0.224, 0.221, 1.0) == NoDouble
  assert puzzles.cube_call(0.5, 0.5, 1.0) == NoDouble
  assert puzzles.cube_call(0.5, 0.501, 1.0) == DoubleTake
  assert puzzles.cube_call(0.5, 0.499, 1.0) == NoDouble
  // Take / pass, with the double clear: the line is DT = DP.
  assert puzzles.cube_call(0.5, 1.0, 1.0) == DoubleTake
  assert puzzles.cube_call(0.5, 0.999, 1.0) == DoubleTake
  assert puzzles.cube_call(0.5, 1.001, 1.0) == DoublePass
  // Double/pass against no double: doubling is worth the point, so the
  // line is DP = ND.
  assert puzzles.cube_call(0.999, 1.4, 1.0) == DoublePass
  assert puzzles.cube_call(1.0, 1.4, 1.0) == NoDouble
  // Too good: the line is ND = DP, and too good is always a no double.
  assert puzzles.too_good(1.001, 1.0)
  assert puzzles.cube_call(1.001, 1.4, 1.0) == NoDouble
  assert !puzzles.too_good(1.0, 1.0)
  assert !puzzles.too_good(0.999, 1.0)
  // The take is the responder's own, whatever the doubler should do.
  assert puzzles.takes(1.0, 1.0)
  assert puzzles.takes(0.999, 1.0)
  assert !puzzles.takes(1.001, 1.0)
  // And the margins are the grade's: a call is a double exactly when the
  // doubler's band is on the positive side or a positive band 0.
  assert puzzles.double_margin(0.221, 0.224, 1.0) >. 0.0
  assert grade.engine_band(Double, cube(0.221, 0.224, 1.0)) == Some(0)
}

/// The rule in the player's words: nobody fails a coin flip, and a plain
/// or a big double are one answer at the table.
pub fn the_briefs_examples_test() {
  // Either side when the engine said too close to call passes: the wrong
  // one gives up under 0.02, which is not a mistake...
  assert grade.cube_verdict(1, 0) == Pass
  assert grade.cube_verdict(-1, 0) == Pass
  // ...band +1 passes a double and fails no double, band -2 the reverse...
  assert grade.cube_verdict(1, 1) == Pass
  assert grade.cube_verdict(-1, 1) == Fail
  assert grade.cube_verdict(-1, -2) == Pass
  assert grade.cube_verdict(1, -2) == Fail
  // ...Double when it said No double misses.
  assert grade.cube_verdict(1, -1) == Fail
  // Double against a big double passes: the size is the reveal's to show.
  assert grade.cube_verdict(1, 2) == Pass
}

pub fn a_band_outside_the_scale_is_refused_test() {
  assert list.all([-2, -1, 1, 2], grade.band_in_range)
  // Too close to call is the engine's word, not an answer.
  assert !grade.band_in_range(0)
  assert !grade.band_in_range(3)
  assert !grade.band_in_range(-3)
}

/// Too good to double: the engine says no double and playing on is worth
/// more than the point a pass would hand over. A page says so in words; the
/// scale is unaffected.
pub fn too_good_is_still_a_no_double_test() {
  let answer = cube(1.4, 0.9, 1.0)
  assert grade.engine_band(Double, answer) == Some(-2)
  let assert CubeAnswer(too_good: too_good, optimal: optimal, ..) = answer
  assert optimal == NoDouble
  assert too_good
  let _ = DoubleTake
  let _ = DoublePass
}

/// Every fixture the client's tests are built on has to be a real answer:
/// the word the engine puts on a cube decision and the three equities it
/// put it on must agree. A fixture labelled "double and pass" whose numbers
/// say "big take" would grade the opposite of what it claims to be, and a
/// page built against it would look right and be wrong.
pub fn every_fixture_means_what_it_says_test() {
  list.each(fixture.samples(), fn(sample) {
    let #(name, _) = sample
    let stored = fixture.stored_sample(name)
    case puzzles.answer_from_json(stored.answer_json) {
      Ok(CubeAnswer(nd, dt, dp, _, optimal, too_good) as answer) -> {
        // The doubler's own call, read off the equities: doubling is worth
        // whatever the other side will allow, min(DT, DP).
        let doubling = float.min(dt, dp)
        let wanted = case doubling <=. nd, dt >. dp {
          True, _ -> NoDouble
          False, True -> DoublePass
          False, False -> DoubleTake
        }
        assert optimal == wanted
        // And the scale agrees with the word: a pass is on the negative
        // side for the responder, a take on the positive.
        let assert Some(band) = grade.engine_band(Take, answer)
        assert case wanted {
          DoublePass -> band < 0
          DoubleTake -> band > 0
          _ -> True
        }
        assert too_good == puzzles.too_good(nd, dp)
      }
      _ -> Nil
    }
  })
}
