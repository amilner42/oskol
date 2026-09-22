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
import gleam/option.{None, Some}
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
pub fn stored_sample(name: String) -> Stored {
  case name {
    "doubles" -> move_puzzle("fixdbl01", doubles_board(), #(3, 3))
    "double" -> cube_puzzle(Double)
    "take" -> cube_puzzle(Take)
    _ -> move_puzzle("fixmove1", hit_board(), #(6, 4))
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
    CubeAnswer(
      no_double: 0.31,
      double_take: 0.84,
      double_pass: 1.0,
      probs: Some(probs()),
      optimal: DoublePass,
      too_good: False,
    ),
  )
}

fn probs() -> Probs {
  Probs(0.55, 0.12, 0.01, 0.1, 0.01)
}
