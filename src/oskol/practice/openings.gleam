//// The positions of the two opening decks, and what the engine is asked
//// about each. Pure: nothing here reads, writes or asks anybody.
////
//// **Openings** are the fifteen rolls a game can open with (a double is
//// rolled again), from the starting position. **Replies** are the other
//// player's first roll, all twenty-one, after each opening has been played
//// the way the engine plays it: 315 positions. One opening play per roll,
//// the best, because a reply is only worth drilling against a position the
//// player will actually meet -- and the engine's best is what a strong
//// opponent plays.
////
//// Every position is money play with the Jacoby rule and the cube in the
//// middle, which is what unlimited play here is: the position a player
//// meets at the start of every game of a session.

import backgammon/analysis.{type Position, type Turn, Position, Turn}
import backgammon/board.{White}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/caps/puzzles.{type NewPuzzle, NewPuzzle}
import oskol/puzzles as puzzle
import oskol/puzzles/extract
import oskol/puzzles/tree
import oskol/reviews/report

pub const jacoby = True

/// The fifteen opening rolls, higher die first, in the order the deck
/// introduces them: 2-1, 3-1, 3-2, 4-1 ... 6-5.
pub fn opening_rolls() -> List(#(Int, Int)) {
  list.range(2, 6)
  |> list.flat_map(fn(high) {
    list.range(1, high - 1) |> list.map(fn(low) { #(high, low) })
  })
}

/// All twenty-one rolls, higher die first: the fifteen and the six doubles,
/// each double after the rolls of its own number (2-1, 1-1, 2-2 ...).
pub fn all_rolls() -> List(#(Int, Int)) {
  list.range(1, 6)
  |> list.flat_map(fn(high) {
    list.range(1, high) |> list.map(fn(low) { #(high, low) })
  })
}

/// The starting position, from the side of the player on roll.
pub fn start() -> List(Int) {
  analysis.encode(board.initial(), White)
}

/// The position a reply is played from: the board the opening left, from
/// the opener's side as the engine writes it, turned round to the side of
/// the player now on roll.
pub fn after(opening_board: List(Int)) -> List(Int) {
  puzzle.flip(opening_board)
}

fn position(board: List(Int)) -> Position {
  Position(
    board: board,
    cube_value: 1,
    cube_owner: "centered",
    away1: 0,
    away2: 0,
    crawford: False,
  )
}

/// The question a position and roll ask: what a deck's puzzle is keyed on,
/// and so what makes the build idempotent.
pub fn question(board: List(Int), roll: #(Int, Int)) -> puzzle.Question {
  puzzle.question_of(puzzle.Move, position(board), Some(roll), jacoby)
}

/// A turn the engine can grade: the position and roll, and any legal play
/// of it (the engine grades every legal play whatever was "played"; one has
/// to be named). Error when the board does not read as one, or the roll
/// could play nothing, neither of which the opening can do.
pub fn turn(board: List(Int), roll: #(Int, Int)) -> Result(Turn, String) {
  use from <- result.try(
    tree.from_engine(board)
    |> result.replace_error("That is not a board"),
  )
  use first <- result.try(
    board.sequences(from, White, tree.dice_of(roll))
    |> list.first
    |> result.replace_error("That roll plays nothing"),
  )
  let played =
    list.fold(first, from, fn(so_far, move) {
      let #(next, _, _) = board.apply_move(so_far, White, move)
      next
    })
  Ok(Turn(
    player: 0,
    player_id: "",
    position: position(board),
    double: None,
    dice: Some(roll),
    played: Some(analysis.encode(played, White)),
    log_index: 0,
    entry: None,
    double_entry: None,
    answer_entry: None,
  ))
}

/// The request for some turns of one board's rolls, each with its place:
/// an opening is its game's first turn (index 0, whose luck is measured as
/// an opening's), a reply its second.
pub fn request(turns: List(#(Int, Turn))) -> String {
  json.to_string(analysis.turns_request(turns, jacoby, None, None))
}

/// The engine's answer to one turn, as a puzzle -- or why it cannot be
/// trusted to be one. A deck's answer has to be complete (a result for
/// every legal play, a board on every candidate), because a player's
/// answer is graded against it and there is no game behind it to ask
/// again from.
pub fn answer(graded: report.TurnReview) -> Result(puzzle.Answer, String) {
  case graded.move {
    Some(report.Moved(played, _best, top, results, n_legal, _forced, _, _)) -> {
      case n_legal > 0 && list.length(results) == n_legal {
        False -> Error("the engine did not send every legal play")
        True ->
          case list.all(top, fn(c) { c.board != [] }) && top != [] {
            False -> Error("a candidate came back without its board")
            True -> {
              let assert puzzle.MoveAnswer(outcomes, complete, n, candidates) =
                extract.move_answer(played, top, results, n_legal)
              // The top five only. The play named in the request was any
              // legal one, and is nobody's: it has no place in a reveal.
              Ok(puzzle.MoveAnswer(
                outcomes,
                complete,
                n,
                list.filter(candidates, fn(c) { c.rank <= 5 }),
              ))
            }
          }
      }
    }
    _ -> Error("the engine graded no checker play")
  }
}

/// The best play's board, from the mover's side: what a reply is played
/// against.
pub fn best_board(answer: puzzle.Answer) -> Result(List(Int), Nil) {
  case answer {
    puzzle.MoveAnswer(candidates: candidates, ..) ->
      candidates
      |> list.sort(fn(a, b) { int.compare(a.rank, b.rank) })
      |> list.first
      |> result.map(fn(c) { c.board })
    _ -> Error(Nil)
  }
}

/// A puzzle ready to write.
pub fn new_puzzle(
  question: puzzle.Question,
  answer: puzzle.Answer,
  levels: option.Option(report.Levels),
) -> NewPuzzle {
  let by = case levels {
    Some(report.Levels(moves, cube)) ->
      puzzle.EvaluatedBy(Some(moves), Some(cube))
    None -> puzzle.EvaluatedBy(None, None)
  }
  NewPuzzle(
    key: puzzle.key(question),
    ids: puzzle.ids(question),
    kind: puzzle.kind_name(question.kind),
    question_json: json.to_string(puzzle.question_json(question)),
    answer_json: json.to_string(puzzle.answer_json(answer)),
    evaluated_by_json: json.to_string(puzzle.evaluated_by_json(by)),
    complete: puzzle.complete(answer),
  )
}

/// Where a position comes in its deck. Openings in roll order; replies
/// grouped by the opening they answer, so a player meets one opening's
/// replies together, each group in roll order.
pub fn opening_position(opening: Int) -> Int {
  opening
}

pub fn reply_position(opening: Int, reply: Int) -> Int {
  opening * 100 + reply
}

/// A roll as a player writes it.
pub fn roll_name(roll: #(Int, Int)) -> String {
  int.to_string(roll.0) <> "-" <> int.to_string(roll.1)
}
