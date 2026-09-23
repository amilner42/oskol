//// Real puzzle payloads, for the client's tests.
////
//// The wire between the server and the puzzle page is frozen
//// (`puzzles-wire`), and the Elm side decodes it strictly. So the Elm suite
//// is given the server's own bytes rather than a hand-written copy of them:
//// `mix oskol.fixtures payloads` writes these into `assets/tests`, and a
//// decoder that drifts from what is actually sent fails there.
////
//// The same idea as `gamekit/fixture`, and for the same reason: the two
//// sides of a frozen contract should be tested against one artefact, not
//// against two people's readings of a document.

import backgammon/analysis
import backgammon/board.{type Board, Black, Point, White}
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/puzzles.{type Stored, Stored} as _
import oskol/handlers/puzzles as handler
import oskol/puzzles.{
  type Answer, type Kind, type Probs, type Question, Candidate, Centered,
  CubeAnswer, Double, DoublePass, Move, MoveAnswer, Mover, Outcome, Probs,
  Question, Take,
}
import oskol/puzzles/tree

/// One payload per shape a page has to draw, named: exactly what
/// `GET /papi/puzzles/:id` answers for each.
pub fn samples() -> List(#(String, String)) {
  ["move", "doubles", "double", "take"]
  |> list.map(fn(name) { #(name, rendered(stored_sample(name))) })
}

/// The row behind a sample, as an extraction would have written it: what a
/// test seeds so the server answers from the database and not from here.
/// `old` is the `move` position as a review from before `all_results`
/// stored it: two candidates and nothing else, so a play outside them is
/// an honest unknown.
pub fn stored_sample(name: String) -> Stored {
  case name {
    "doubles" -> move_puzzle("fixdbl01", doubles_board(), #(3, 3))
    "double" -> cube_puzzle(Double)
    "take" -> cube_puzzle(Take)
    "old" -> old_move_puzzle("fixold01", hit_board(), #(6, 4))
    _ -> move_puzzle("fixmove1", hit_board(), #(6, 4))
  }
}

/// What `POST /papi/puzzles/:id/attempts` answers a guest, one per shape a
/// reveal has to draw: a checker play that passes, holds, misses and one
/// the stored answer cannot grade; a double and a take answered right and
/// wrong. And the three shapes a schedule takes for an account, which the
/// same endpoint carries in place of `null`.
pub fn reveals() -> List(#(String, String)) {
  let move = stored_sample("move")
  let old = stored_sample("old")
  let due = 1_800_000_000_000
  [
    #("move_pass", attempted(move, moves_to(move, 1), None)),
    #("move_hold", attempted(move, moves_to(move, 2), None)),
    #("move_fail", attempted(move, moves_to(move, 3), None)),
    #("move_unknown", attempted(old, moves_to(move, 3), None)),
    #("double_pass", attempted(stored_sample("double"), [], Some(1))),
    #("double_fail", attempted(stored_sample("double"), [], Some(-1))),
    #("take_pass", attempted(stored_sample("take"), [], Some(-1))),
    // A coin flip: taking and passing are within 0.02 of each other, so
    // either answer holds.
    #("take_hold", attempted(close_take(), [], Some(1))),
    #("schedule_amendable", handler.schedule_json(2, 3, due, True, False)),
    #("schedule_self_grade", handler.schedule_json(3, 3, due, False, True)),
    #("schedule_settled", handler.schedule_json(1, 1, due, False, False)),
  ]
}

fn attempted(
  stored: Stored,
  moves: List(#(String, String, Int)),
  band: Option(Int),
) -> String {
  case
    handler.attempt_body(stored, handler.Attempted(moves, band, "fixture-key"))
  {
    Ok(body) -> body
    Error(_) -> "{\"ok\":false}"
  }
}

/// The path through the turn that leaves the board the candidate of that
/// rank leaves -- what the page sends after walking there. The candidates
/// are ranked by the terminals' order, so every rank up to the number of
/// legal plays has one.
fn moves_to(stored: Stored, rank: Int) -> List(#(String, String, Int)) {
  case
    puzzles.question_from_json(stored.question_json),
    puzzles.answer_from_json(stored.answer_json)
  {
    Ok(question), Ok(MoveAnswer(candidates: candidates, ..)) ->
      case
        list.find(candidates, fn(c) { c.rank == rank }),
        question.dice,
        tree.from_engine(question.board)
      {
        Ok(candidate), Some(roll), Ok(b) ->
          case tree.build(b, tree.dice_of(roll), 100_000) {
            Ok(t) -> path_to(t, tree.root_id, [], candidate.board)
            Error(_) -> []
          }
        _, _, _ -> []
      }
    _, _ -> []
  }
}

fn path_to(
  t: tree.Tree,
  id: String,
  so_far: List(#(String, String, Int)),
  target: List(Int),
) -> List(#(String, String, Int)) {
  case tree.node_by_id(t, id) {
    None -> []
    Some(n) ->
      case n.children {
        [] ->
          case analysis.encode(n.board, White) == target {
            True -> list.reverse(so_far)
            False -> []
          }
        children ->
          list.find_map(children, fn(c) {
            case
              path_to(
                t,
                c.node,
                [#(board.loc_id(c.from), board.loc_id(c.to), c.die), ..so_far],
                target,
              )
            {
              [] -> Error(Nil)
              found -> Ok(found)
            }
          })
          |> result.unwrap([])
      }
  }
}

fn rendered(stored: Stored) -> String {
  case handler.puzzle_body(stored) {
    Ok(body) -> body
    Error(_) -> "{\"ok\":false}"
  }
}

fn stored(id: String, question: Question, answer: Answer) -> Stored {
  Stored(
    id: id,
    kind: puzzles.kind_name(question.kind),
    question_json: json.to_string(puzzles.question_json(question)),
    answer_json: json.to_string(puzzles.answer_json(answer)),
  )
}

// ---------- The positions ----------

/// White to play 6-4 with two runners on 13 and a blot on 7 to hit: a hit,
/// a bear-in, and two orders that reach one node.
fn hit_board() -> Board {
  place([
    #(White, 13, 2),
    #(White, 4, 4),
    #(White, 5, 4),
    #(White, 6, 5),
    #(Black, 1, 2),
    #(Black, 2, 2),
    #(Black, 7, 1),
    #(Black, 17, 3),
    #(Black, 18, 3),
    #(Black, 20, 2),
    #(Black, 21, 2),
  ])
}

/// 3-3 with the home board shut, so two runners walk 13/10/7/4 and every
/// order of the fours threes merges: the shape only doubles give.
fn doubles_board() -> Board {
  place([
    #(White, 13, 2),
    #(White, 4, 4),
    #(White, 5, 4),
    #(White, 6, 5),
    #(Black, 1, 2),
    #(Black, 2, 2),
    #(Black, 3, 2),
    #(Black, 20, 3),
    #(Black, 22, 3),
    #(Black, 24, 3),
  ])
}

fn place(entries: List(#(board.Color, Int, Int))) -> Board {
  let #(checkers, _) =
    list.fold(entries, #([], #(0, 0)), fn(acc, entry) {
      let #(placed, #(w, b)) = acc
      let #(color, point, n) = entry
      let start = case color {
        White -> w
        Black -> b
      }
      let ids =
        list.range(1, n)
        |> list.map(fn(i) {
          #(board.prefix(color) <> int.to_string(start + i), #(
            color,
            Point(point),
          ))
        })
      let counts = case color {
        White -> #(w + n, b)
        Black -> #(w, b + n)
      }
      #(list.append(placed, ids), counts)
    })
  board.Board(checkers: dict.from_list(checkers))
}

// ---------- The puzzles ----------

fn move_puzzle(id: String, b: Board, roll: #(Int, Int)) -> Stored {
  let question =
    Question(
      kind: Move,
      board: analysis.encode(b, White),
      dice: Some(roll),
      cube_value: 1,
      cube_owner: Centered,
      away_mover: 3,
      away_opponent: 5,
      crawford: False,
      jacoby: False,
    )
  stored(id, question, move_answer(b, roll))
}

/// Costs made up, boards real. The answer never reaches the page, so a
/// fixture only has to be well formed -- but the boards are the ones this
/// position's own legal plays leave, so an attempt made against the fixture
/// grades exactly as a real one would.
fn move_answer(b: Board, roll: #(Int, Int)) -> Answer {
  let boards = terminals(b, roll)
  let costs = list.index_map(boards, fn(_, i) { int.to_float(i) *. 0.07 })
  let pairs = list.zip(boards, costs)
  MoveAnswer(
    outcomes: list.map(pairs, fn(pair) {
      Outcome(board: pair.0, equity_lost: pair.1)
    }),
    complete: True,
    n_legal: list.length(boards),
    candidates: list.index_map(pairs, fn(pair, i) {
      Candidate(
        rank: i + 1,
        notation: "play " <> int.to_string(i + 1),
        equity: 0.42 -. pair.1,
        equity_lost: pair.1,
        board: pair.0,
        probs: probs(),
      )
    })
      |> list.take(5),
  )
}

/// The boards every legal way of playing this roll leaves.
fn terminals(b: Board, roll: #(Int, Int)) -> List(List(Int)) {
  case tree.build(b, tree.dice_of(roll), 100_000) {
    Error(_) -> []
    Ok(t) ->
      t.nodes
      |> list.filter(fn(n) { n.children == [] })
      |> list.map(fn(n) { analysis.encode(n.board, White) })
  }
}

/// The same position as `move` graded by an engine asked for five moves and
/// nothing else: two candidates stand for the whole answer, so an attempt
/// that leaves any other board is unknown.
fn old_move_puzzle(id: String, b: Board, roll: #(Int, Int)) -> Stored {
  let whole = move_puzzle(id, b, roll)
  case puzzles.answer_from_json(whole.answer_json) {
    Ok(MoveAnswer(candidates: candidates, ..)) -> {
      let kept = list.take(candidates, 2)
      Stored(
        ..whole,
        answer_json: json.to_string(
          puzzles.answer_json(MoveAnswer(
            outcomes: list.map(kept, fn(c) {
              Outcome(board: c.board, equity_lost: c.equity_lost)
            }),
            complete: False,
            n_legal: list.length(candidates),
            candidates: kept,
          )),
        ),
      )
    }
    _ -> whole
  }
}

fn cube_puzzle(kind: Kind) -> Stored {
  let question =
    Question(
      kind: kind,
      board: analysis.encode(hit_board(), White),
      dice: None,
      cube_value: 2,
      cube_owner: Mover,
      away_mover: 3,
      away_opponent: 5,
      crawford: False,
      jacoby: False,
    )
  let id = case kind {
    Take -> "fixtake1"
    _ -> "fixdoub1"
  }
  stored(
    id,
    question,
    // A genuine double-and-pass, and the numbers have to say so: taking
    // pays the doubler 1.12 where passing pays them the point, so the
    // responder passes (DP - DT = -0.12, a plain pass) and the doubler
    // doubles (min(DT, DP) - ND = +0.69, a big double). A label that its
    // own equities contradict would make a fixture that grades the
    // opposite of what it claims to be.
    CubeAnswer(
      no_double: 0.31,
      double_take: 1.12,
      double_pass: 1.0,
      probs: Some(probs()),
      optimal: DoublePass,
      too_good: False,
    ),
  )
}

/// The same take with the numbers a hair apart: the engine's band is zero
/// and the reveal says too close to call.
fn close_take() -> Stored {
  let Stored(id: _, kind: kind, question_json: question, answer_json: _) =
    cube_puzzle(Take)
  Stored(
    id: "fixtakec",
    kind: kind,
    question_json: question,
    answer_json: json.to_string(
      puzzles.answer_json(CubeAnswer(
        no_double: 0.31,
        double_take: 1.01,
        double_pass: 1.0,
        probs: Some(probs()),
        optimal: DoublePass,
        too_good: False,
      )),
    ),
  )
}

fn probs() -> Probs {
  Probs(0.55, 0.12, 0.01, 0.1, 0.01)
}
