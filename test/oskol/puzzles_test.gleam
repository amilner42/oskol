//// What becomes a puzzle, and what one stores: controlled positions with a
//// hand-written engine answer beside them, so every rule the extraction
//// makes is asserted on a board somebody could draw.
////
//// The boards are real (built with the backgammon suite's own position
//// builder and encoded for the engine the way a review encodes them); the
//// engine's verdicts are written out here, because what is under test is
//// what Oskol does with them.

import backgammon/analysis
import backgammon/board.{type Board, type Color, Black, Point, White}
import backgammon/positions
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/puzzles as caps
import oskol/puzzles as puzzle
import oskol/puzzles/extract
import oskol/reviews/report
import oskol/rooms/code

// ---------- Boards ----------

/// A middle-game position: White has a checker back, Black an anchor.
fn a_board() -> Board {
  positions.setup([
    #(White, Point(24), 2),
    #(White, Point(13), 5),
    #(White, Point(8), 3),
    #(White, Point(6), 4),
    #(White, Point(4), 1),
    #(Black, Point(1), 2),
    #(Black, Point(12), 5),
    #(Black, Point(17), 3),
    #(Black, Point(19), 4),
    #(Black, Point(21), 1),
  ])
}

/// The same position with the colours and the board turned round: what
/// Black sees when White sees `a_board`. Encoded for its own mover it is
/// the same 26 ints, which is what makes it the same puzzle.
fn mirrored() -> Board {
  positions.setup([
    #(Black, Point(1), 2),
    #(Black, Point(12), 5),
    #(Black, Point(17), 3),
    #(Black, Point(19), 4),
    #(Black, Point(21), 1),
    #(White, Point(24), 2),
    #(White, Point(13), 5),
    #(White, Point(8), 3),
    #(White, Point(6), 4),
    #(White, Point(4), 1),
  ])
}

fn a_position(mover: Color) -> analysis.Position {
  analysis.Position(
    board: analysis.encode(a_board(), mover),
    cube_value: 1,
    cube_owner: "centered",
    away1: 0,
    away2: 0,
    crawford: False,
  )
}

// ---------- Turns and the engine's word on them ----------

fn a_turn(
  player: Int,
  position: analysis.Position,
  dice: Option(#(Int, Int)),
  double: Option(analysis.Answer),
) -> analysis.Turn {
  analysis.Turn(
    player: player,
    player_id: seat_id(player),
    position: position,
    double: double,
    dice: dice,
    played: option.map(dice, fn(_) { moved_board() }),
    log_index: 0,
    entry: Some(0),
    double_entry: None,
    answer_entry: None,
  )
}

fn seat_id(index: Int) -> String {
  case index {
    0 -> "p1"
    _ -> "p2"
  }
}

fn seats() -> List(report.Seat) {
  [report.Seat("p1", "Alice", "white"), report.Seat("p2", "Bob", "black")]
}

/// A board that is not the one the turn began on, so nothing here looks
/// like a dance.
fn moved_board() -> List(Int) {
  analysis.encode(
    positions.setup([
      #(White, Point(24), 2),
      #(White, Point(13), 4),
      #(White, Point(8), 4),
      #(White, Point(6), 4),
      #(White, Point(4), 1),
      #(Black, Point(1), 2),
      #(Black, Point(12), 5),
      #(Black, Point(17), 3),
      #(Black, Point(19), 4),
      #(Black, Point(21), 1),
    ]),
    White,
  )
}

fn candidate(rank: Int, diff: Float) -> report.Candidate {
  report.Candidate(
    rank: rank,
    notation: "13/8 13/11",
    equity: 0.1,
    equity_diff: diff,
    probs: probs(),
    board: moved_board(),
  )
}

fn probs() -> report.Probs {
  report.Probs(0.55, 0.12, 0.01, 0.1, 0.0)
}

/// The engine's word on a checker play: `error` given up, `n_legal` legal
/// plays, and `results` for all of them when the request asked for them.
fn a_move(
  error: Float,
  forced: Bool,
  n_legal: Int,
  results: List(report.MoveResult),
) -> report.MoveReview {
  report.Moved(
    played: candidate(2, 0.0 -. error),
    best: candidate(1, 0.0),
    top: [candidate(1, 0.0), candidate(2, 0.0 -. error)],
    results: results,
    n_legal: n_legal,
    forced: forced,
    error: error,
    grade: "bad",
  )
}

fn a_cube(
  action: String,
  response: Option(String),
  doubler_error: Float,
  taker_error: Option(Float),
) -> report.CubeReview {
  report.CubeReview(
    action: action,
    response: response,
    optimal: "Double/Take",
    no_double: 0.42,
    double_take: 0.61,
    double_pass: 1.0,
    probs: Some(probs()),
    doubler: report.Verdict(doubler_error, "bad", None),
    taker: option.map(taker_error, fn(e) {
      report.Verdict(e, "very_bad", Some("wrong_pass"))
    }),
  )
}

fn review(turns: List(report.TurnReview)) -> report.Review {
  report.Review(
    turns: turns,
    players: [],
    levels: Some(report.Levels("4ply", "4ply")),
    timing_ms: Some(1200),
  )
}

fn graded(
  move: Option(report.MoveReview),
  cube: Option(report.CubeReview),
) -> report.TurnReview {
  report.TurnReview(index: 0, cube: cube, move: move, luck: None)
}

fn game(number: Int, turns: List(analysis.Turn)) -> analysis.GameTurns {
  analysis.GameTurns(
    number: number,
    finished: True,
    jacoby: False,
    turns: turns,
  )
}

fn run(
  g: analysis.GameTurns,
  graded: List(report.TurnReview),
) -> #(List(caps.NewPuzzle), List(caps.NewSource)) {
  let assert Ok(found) = extract.from_review(g, seats(), review(graded))
  found
}

fn keys(puzzles: List(caps.NewPuzzle)) -> List(String) {
  list.map(puzzles, fn(p) { p.key })
}

// ---------- A checker play ----------

pub fn a_checker_mistake_is_a_move_puzzle_test() {
  let #(puzzles, sources) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  let assert [p] = puzzles
  assert p.kind == "move"
  let assert [first_id, ..] = p.ids
  assert string.length(first_id) == 8
  let assert [s] = sources
  assert s.kind == "move"
  assert s.seat == 0
  assert s.player_id == "p1"
  assert s.equity_lost == 0.05
  assert s.grade == "bad"
  assert s.skipped_reason == None
  assert s.key == Some(p.key)
  assert s.turn == 1
  assert s.game_number == 1
}

pub fn a_play_inside_the_band_is_no_puzzle_test() {
  let #(puzzles, sources) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.019, False, 12, [])), None),
    ])
  assert puzzles == []
  assert sources == []
}

pub fn the_threshold_itself_is_a_puzzle_test() {
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.02, False, 12, [])), None),
    ])
  assert list.length(puzzles) == 1
}

pub fn a_forced_play_is_no_puzzle_test() {
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.5, True, 1, [])), None),
    ])
  assert puzzles == []
}

pub fn a_danced_turn_is_no_puzzle_test() {
  // A roll that played nothing commits the board it began on.
  let position = a_position(White)
  let turn =
    analysis.Turn(
      ..a_turn(0, position, Some(#(6, 6)), None),
      played: Some(position.board),
    )
  let #(puzzles, _) =
    run(game(1, [turn]), [graded(Some(a_move(0.4, False, 1, [])), None)])
  assert puzzles == []
  let #(danced_puzzles, _) =
    run(game(1, [turn]), [graded(Some(report.Danced), None)])
  assert danced_puzzles == []
}

// ---------- The question ----------

pub fn reversed_dice_ask_one_question_test() {
  let one =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  let other =
    run(game(2, [a_turn(0, a_position(White), Some(#(4, 6)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  assert keys(one.0) == keys(other.0)
  assert string.contains(
    {
      let assert [p] = one.0
      p.question_json
    },
    "\"dice\":[6,4]",
  )
}

pub fn the_same_position_from_either_colour_is_one_puzzle_test() {
  // White to play in one game; in another, Black to play the position
  // turned round. Mover-relative, that is one board and one question.
  let white = a_position(White)
  let black =
    analysis.Position(..white, board: analysis.encode(mirrored(), Black))
  assert white.board == black.board
  let one =
    run(game(1, [a_turn(0, white, Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  let other =
    run(game(7, [a_turn(1, black, Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.09, False, 12, [])), None),
    ])
  assert keys(one.0) == keys(other.0)
  // Two sources, and the second one is the Black seat's.
  let assert [first] = one.1
  let assert [second] = other.1
  assert first.seat == 0
  assert second.seat == 1
  assert second.player_id == "p2"
  assert second.game_number == 7
}

pub fn each_cube_owner_asks_its_own_question_test() {
  let question = fn(owner) {
    puzzle.question_of(
      puzzle.Double,
      analysis.Position(..a_position(White), cube_owner: owner),
      None,
      False,
    )
  }
  let all =
    ["centered", "player", "opponent"]
    |> list.map(fn(owner) { puzzle.key(question(owner)) })
  assert list.unique(all) == all
  assert puzzle.question_of(
      puzzle.Double,
      analysis.Position(..a_position(White), cube_owner: "player"),
      None,
      False,
    ).cube_owner
    == puzzle.Mover
}

pub fn a_cube_question_carries_no_dice_test() {
  let q =
    puzzle.question_of(puzzle.Take, a_position(White), Some(#(6, 4)), False)
  assert q.dice == None
  assert string.contains(
    q |> puzzle.question_json |> json.to_string,
    "\"dice\":null",
  )
}

pub fn a_question_reads_back_as_it_was_written_test() {
  let q =
    puzzle.question_of(
      puzzle.Move,
      analysis.Position(
        ..a_position(White),
        cube_value: 4,
        cube_owner: "opponent",
        away1: 3,
        away2: 5,
        crawford: True,
      ),
      Some(#(3, 5)),
      True,
    )
  let assert Ok(read) =
    puzzle.question_from_json(json.to_string(puzzle.question_json(q)))
  assert read == q
  assert puzzle.key(read) == puzzle.key(q)
}

pub fn money_play_stores_no_score_test() {
  let q =
    puzzle.question_of(puzzle.Move, a_position(White), Some(#(3, 1)), True)
  assert string.contains(
    json.to_string(puzzle.question_json(q)),
    "\"score\":null",
  )
}

pub fn a_key_and_its_ids_are_the_same_every_time_test() {
  let q =
    puzzle.question_of(puzzle.Move, a_position(White), Some(#(3, 1)), False)
  assert puzzle.key(q) == puzzle.key(q)
  assert puzzle.ids(q) == puzzle.ids(q)
  assert list.length(puzzle.ids(q)) == 4
  list.each(puzzle.ids(q), fn(id) {
    assert string.length(id) == 8
    list.each(string.to_graphemes(id), fn(char) {
      assert string.contains(code.alphabet, char)
    })
  })
  assert list.unique(puzzle.ids(q)) == puzzle.ids(q)
}

pub fn a_board_turns_around_and_back_test() {
  let b = analysis.encode(a_board(), White)
  assert puzzle.flip(b) == analysis.encode(a_board(), Black)
  assert puzzle.flip(puzzle.flip(b)) == b
}

// ---------- The cube ----------

pub fn a_double_and_its_answer_are_two_puzzles_test() {
  let turn = a_turn(0, a_position(White), Some(#(6, 4)), Some(analysis.Took))
  let #(puzzles, sources) =
    run(game(1, [turn]), [
      graded(
        // The checker play of this turn is skipped: the engine graded it on
        // the cube as it stood before the take.
        Some(a_move(0.05, False, 12, [])),
        Some(a_cube("double", Some("take"), 0.04, Some(0.3))),
      ),
    ])
  assert list.sort(list.map(puzzles, fn(p) { p.kind }), string.compare)
    == ["double", "take"]
  let assert Ok(double) = list.find(sources, fn(s) { s.kind == "double" })
  let assert Ok(take) = list.find(sources, fn(s) { s.kind == "take" })
  // The doubler's decision is the mover's; the answer is the other side's.
  assert double.seat == 0
  assert double.played == "double"
  assert take.seat == 1
  assert take.player_id == "p2"
  assert take.played == "take"
  assert take.equity_lost == 0.3
  // One position, two questions: the boards match and the keys do not.
  let assert Ok(dq) = list.find(puzzles, fn(p) { p.kind == "double" })
  let assert Ok(tq) = list.find(puzzles, fn(p) { p.kind == "take" })
  assert dq.key != tq.key
  assert dq.answer_json == tq.answer_json
  assert string.contains(dq.answer_json, "\"double_take\":0.61")
  assert string.contains(dq.answer_json, "\"optimal\":\"double_take\"")
  assert string.contains(dq.answer_json, "\"too_good\":false")
}

pub fn a_take_nobody_was_offered_is_no_puzzle_test() {
  // The engine grades a taker on a turn where no double was offered; there
  // is nothing to ask anyone. On turn two, so the opening rule is not what
  // is doing the work.
  let turn = a_turn(0, a_position(White), Some(#(6, 4)), None)
  let #(puzzles, _) =
    run(game(1, [turn, turn]), [
      graded(None, None),
      graded(None, Some(a_cube("no_double", None, 0.0, Some(0.4)))),
    ])
  assert puzzles == []
}

pub fn the_opening_no_double_is_suppressed_test() {
  let turn = fn() { a_turn(0, a_position(White), Some(#(6, 4)), None) }
  let missed = fn() {
    graded(None, Some(a_cube("no_double", None, 0.09, None)))
  }
  // Turn one: the engine grades "no double" on the opening roll, and that
  // is nothing anybody could have done.
  let #(first_only, _) = run(game(1, [turn()]), [missed()])
  assert first_only == []
  // The same verdict on turn two is a real missed double.
  let #(later, sources) = run(game(1, [turn(), turn()]), [missed(), missed()])
  assert list.length(later) == 1
  let assert [s] = sources
  assert s.kind == "double"
  assert s.turn == 2
  assert s.played == "no_double"
}

pub fn the_crawford_game_asks_no_cube_question_test() {
  let crawford =
    analysis.Position(..a_position(White), away1: 1, away2: 3, crawford: True)
  let turn = a_turn(0, crawford, Some(#(6, 4)), None)
  let #(puzzles, _) =
    run(game(1, [turn, turn]), [
      graded(None, Some(a_cube("no_double", None, 0.4, None))),
      graded(None, Some(a_cube("no_double", None, 0.4, None))),
    ])
  assert puzzles == []
}

pub fn a_cube_the_mover_does_not_hold_asks_nothing_test() {
  let owned =
    analysis.Position(
      ..a_position(White),
      cube_owner: "opponent",
      cube_value: 2,
    )
  let turn = a_turn(0, owned, Some(#(6, 4)), None)
  let #(puzzles, _) =
    run(game(1, [turn, turn]), [
      graded(None, Some(a_cube("no_double", None, 0.4, None))),
      graded(None, Some(a_cube("no_double", None, 0.4, None))),
    ])
  assert puzzles == []
}

pub fn one_cube_question_survives_two_different_rolls_test() {
  // The same cube decision reached twice, each followed by a different
  // roll: the roll is not part of the question, so it is one puzzle.
  let first = a_turn(0, a_position(White), Some(#(6, 4)), None)
  let second = a_turn(0, a_position(White), Some(#(2, 1)), None)
  let missed = graded(None, Some(a_cube("no_double", None, 0.1, None)))
  let filler = graded(None, None)
  let #(puzzles, sources) =
    run(game(1, [first, first, second]), [filler, missed, missed])
  assert list.length(puzzles) == 1
  assert list.length(sources) == 2
  assert list.map(sources, fn(s) { s.turn }) == [2, 3]
}

// ---------- The answer ----------

pub fn every_legal_result_is_stored_when_the_engine_sends_them_test() {
  let results =
    list.range(1, 12)
    |> list.map(fn(i) {
      report.MoveResult(
        board: moved_board(),
        equity_diff: 0.0 -. int.to_float(i) /. 100.0,
      )
    })
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, results)), None),
    ])
  let assert [p] = puzzles
  assert string.contains(p.answer_json, "\"complete\":true")
  assert string.contains(p.answer_json, "\"n_legal\":12")
  let assert Ok(puzzle.MoveAnswer(outcomes, complete, n_legal, _)) =
    puzzle.answer_from_json(p.answer_json)
  assert complete
  assert n_legal == 12
  assert list.length(outcomes) == 12
  // The engine's diff is best-relative and negative; what is stored is what
  // the answer gave up.
  assert list.all(outcomes, fn(o) { o.equity_lost >=. 0.0 })
}

pub fn an_answer_without_results_says_it_is_incomplete_test() {
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  let assert [p] = puzzles
  let assert Ok(puzzle.MoveAnswer(outcomes, complete, n_legal, candidates)) =
    puzzle.answer_from_json(p.answer_json)
  assert !complete
  assert n_legal == 12
  // Only what the engine described: the two candidates it sent.
  assert list.length(outcomes) == 2
  assert list.length(candidates) == 2
}

pub fn a_played_move_outside_the_top_five_is_kept_test() {
  let move =
    report.Moved(
      played: candidate(9, -0.4),
      best: candidate(1, 0.0),
      top: list.map([1, 2, 3, 4, 5], fn(rank) {
        candidate(rank, 0.0 -. int.to_float(rank) /. 100.0)
      }),
      results: [],
      n_legal: 20,
      forced: False,
      error: 0.4,
      grade: "very_bad",
    )
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(move), None),
    ])
  let assert [p] = puzzles
  let assert Ok(puzzle.MoveAnswer(_, _, _, candidates)) =
    puzzle.answer_from_json(p.answer_json)
  assert list.map(candidates, fn(c) { c.rank }) == [1, 2, 3, 4, 5, 9]
}

pub fn a_best_move_played_is_listed_once_test() {
  let move =
    report.Moved(
      played: candidate(1, 0.0),
      best: candidate(1, 0.0),
      top: [candidate(1, 0.0), candidate(2, -0.05)],
      results: [],
      n_legal: 12,
      // A "best" play can still be a mistake when the engine's own error
      // says so; what matters here is that it is not listed twice.
      forced: False,
      error: 0.05,
      grade: "bad",
    )
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(move), None),
    ])
  let assert [p] = puzzles
  let assert Ok(puzzle.MoveAnswer(_, _, _, candidates)) =
    puzzle.answer_from_json(p.answer_json)
  assert list.map(candidates, fn(c) { c.rank }) == [1, 2]
}

pub fn too_good_is_read_off_the_equities_test() {
  let cube =
    report.CubeReview(
      ..a_cube("no_double", None, 0.2, None),
      optimal: "No Double",
      no_double: 1.4,
      double_pass: 1.0,
    )
  let #(puzzles, _) =
    run(
      game(1, [
        a_turn(0, a_position(White), Some(#(6, 4)), None),
        a_turn(0, a_position(White), Some(#(6, 4)), None),
      ]),
      [
        graded(None, None),
        graded(None, Some(cube)),
      ],
    )
  let assert [p] = puzzles
  assert string.contains(p.answer_json, "\"too_good\":true")
  assert string.contains(p.answer_json, "\"optimal\":\"no_double\"")
}

pub fn the_engine_that_answered_is_recorded_test() {
  let #(puzzles, _) =
    run(game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]), [
      graded(Some(a_move(0.05, False, 12, [])), None),
    ])
  let assert [p] = puzzles
  assert string.contains(p.evaluated_by_json, "\"moves\":\"4ply\"")
  assert string.contains(p.evaluated_by_json, "\"cube\":\"4ply\"")
}

// ---------- The engine's post-take blind spot ----------

pub fn a_checker_play_after_a_take_is_recorded_but_not_asked_test() {
  let #(puzzles, sources) =
    run(
      game(1, [
        a_turn(0, a_position(White), Some(#(6, 4)), Some(analysis.Took)),
      ]),
      [graded(Some(a_move(0.4, False, 12, [])), None)],
    )
  // Nothing to practise: the engine graded that play on the cube as it
  // stood before the double it followed.
  assert puzzles == []
  let assert [s] = sources
  assert s.kind == "move"
  assert s.key == None
  assert s.skipped_reason == Some(extract.post_take_reason)
  assert s.equity_lost == 0.4
}

pub fn a_checker_play_after_a_pass_is_an_ordinary_puzzle_test() {
  // A passed double ends the game; the turn that follows it in another
  // game is nobody's post-take play.
  let #(puzzles, sources) =
    run(
      game(1, [
        a_turn(0, a_position(White), Some(#(6, 4)), Some(analysis.Passed)),
      ]),
      [graded(Some(a_move(0.4, False, 12, [])), None)],
    )
  assert list.length(puzzles) == 1
  let assert [s] = sources
  assert s.skipped_reason == None
}

// ---------- Mismatched answers ----------

pub fn an_answer_for_another_game_is_refused_test() {
  let assert Error(_) =
    extract.from_review(
      game(1, [a_turn(0, a_position(White), Some(#(6, 4)), None)]),
      seats(),
      review([]),
    )
}
// ---------- Helpers ----------
