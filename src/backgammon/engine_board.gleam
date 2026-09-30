//// Oskol's board and match state as the analysis engine takes them.
////
//// The engine speaks one board format: 26 ints from the perspective of the
//// player on roll. Indexes 1..24 are points counted from the mover's side
//// (their checkers positive, the opponent's negative; they move 24 -> 1
//// and bear off past 1), 25 is the mover's bar and 0 the opponent's bar.
//// Borne-off checkers are not stored. Oskol numbers points so that White
//// moves 24 -> 1, so for White a point keeps its number and for Black
//// point p is index 25 - p.
////
//// Both bars are plain counts, never negative: that is bgsage's own
//// format (`board[0]` "opponent checkers on bar (>= 0)"), and the boards
//// the engine generates for a played move say so -- a hit shows up as +1
//// at index 0. The service's README and doc (2026-09) say index 0 is
//// negative; they are wrong, and a `played` board signed that way is
//// never in the engine's legal list, so the whole review 422s. (The
//// single-position routes `/moves` and `/cube` validate the board the
//// wrong way round and reject a positive index 0 outright, which is why
//// `backgammon/bot` asks its questions through `/review` instead.)
////
//// This is the whole of what the engine needs to be told about a position,
//// and it is pure: the post-game review builds a request out of it
//// (`backgammon/analysis`) and the bot asks about one turn with it
//// (`backgammon/bot`), and neither has to know about the other.

import backgammon/board.{type Board, type Color, Black, Point, White}
import backgammon/record
import backgammon/state.{type GameState}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type Position {
  Position(
    board: List(Int),
    cube_value: Int,
    /// "centered", "player" (the mover owns it) or "opponent".
    cube_owner: String,
    /// Points the mover and the opponent still need; both 0 in a money
    /// game (unlimited play).
    away1: Int,
    away2: Int,
    crawford: Bool,
  )
}

/// The engine's 26-int board for `mover`, who is on roll.
pub fn encode(b: Board, mover: Color) -> List(Int) {
  let opponent = board.opponent(mover)
  let points =
    list.range(1, 24)
    |> list.map(fn(index) {
      let point = oskol_point(mover, index)
      board.count(b, mover, Point(point))
      - board.count(b, opponent, Point(point))
    })
  list.flatten([
    [board.on_bar(b, opponent)],
    points,
    [board.on_bar(b, mover)],
  ])
}

/// The engine's board read back into Oskol's, the way the record keeps a
/// position: each colour's checkers on points 1..24, on the bar and borne
/// off, and its pip count, `#(white, black)`. `mover` is the player the
/// board is drawn for (the one on roll). The inverse of `encode`, for the
/// boards the engine sends back (a candidate move's result); Error when the
/// list is not a board.
pub fn decode(
  engine_board: List(Int),
  mover: Color,
) -> Result(#(record.Side, record.Side), Nil) {
  case engine_board {
    [opponent_bar, ..rest] ->
      case list.length(rest) == 25 {
        False -> Error(Nil)
        True -> {
          let points = list.take(rest, 24)
          let mover_bar = list.drop(rest, 24) |> list.first |> result.unwrap(0)
          // Oskol point p (1..24) holds what engine index `index_of(p)` does.
          let at = fn(p: Int) {
            list.drop(points, engine_index(mover, p) - 1)
            |> list.first
            |> result.unwrap(0)
          }
          let counts = fn(sign: Int) {
            list.range(1, 24)
            |> list.map(fn(p) { int.max(0, sign * at(p)) })
          }
          let side = fn(color: Color, counts: List(Int), bar: Int) {
            let on_points = int.sum(counts)
            record.Side(
              points: counts,
              bar: bar,
              off: 15 - on_points - bar,
              pips: 25
                * bar
                + int.sum(
                list.index_map(counts, fn(n, i) {
                  n * board.pip_distance(color, i + 1)
                }),
              ),
            )
          }
          let mine = side(mover, counts(1), mover_bar)
          let theirs = side(board.opponent(mover), counts(-1), opponent_bar)
          Ok(case mover {
            White -> #(mine, theirs)
            Black -> #(theirs, mine)
          })
        }
      }
    [] -> Error(Nil)
  }
}

/// Where the mover's checkers landed going from one engine board to
/// another: every Oskol point that gained checkers of theirs, once per
/// checker it gained, low point first -- the record's `landed` for a move
/// the engine proposes. Checkers borne off land nowhere.
pub fn landings(from: List(Int), to: List(Int), mover: Color) -> List(Int) {
  list.range(1, 24)
  |> list.flat_map(fn(index) {
    let before = int.max(0, nth(from, index))
    let after = int.max(0, nth(to, index))
    list.repeat(oskol_point(mover, index), int.max(0, after - before))
  })
  |> list.sort(int.compare)
}

fn nth(values: List(Int), index: Int) -> Int {
  list.drop(values, index) |> list.first |> result.unwrap(0)
}

/// The engine index 1..24 of Oskol point `p` for this mover.
fn engine_index(mover: Color, p: Int) -> Int {
  case mover {
    White -> p
    Black -> 25 - p
  }
}

/// The Oskol point behind engine index 1..24 for this mover.
fn oskol_point(mover: Color, index: Int) -> Int {
  case mover {
    White -> index
    Black -> 25 - index
  }
}

/// The position `mover` is on roll in: the board as it stood when the turn
/// began (never a staged move), the cube and the match score.
pub fn position(s: GameState, mover: Color) -> Position {
  let mover_id = state.player_of(s, mover)
  let opponent_id = state.player_of(s, board.opponent(mover))
  let target = s.config.target
  let #(away1, away2) = case target > 0 {
    True -> #(
      target - state.score_of(s, mover_id),
      target - state.score_of(s, opponent_id),
    )
    False -> #(0, 0)
  }
  let owner = case s.cube_owner {
    None -> "centered"
    Some(color) if color == mover -> "player"
    Some(_) -> "opponent"
  }
  Position(
    board: encode(s.turn_board, mover),
    cube_value: s.cube_value,
    cube_owner: owner,
    away1: away1,
    away2: away2,
    crawford: s.crawford,
  )
}

/// Could the engine grade a double here? It will not take one it thinks
/// illegal: in the Crawford game, on a cube the opponent owns, or on a
/// dead cube (a match where the cube already covers what the doubler
/// needs). Oskol lets that last one be offered; it is the one difference.
pub fn engine_can_double(p: Position) -> Bool {
  let money = p.away1 == 0 && p.away2 == 0
  !p.crawford
  && p.cube_owner != "opponent"
  && { money || p.cube_value < p.away1 }
}

/// Which seat this player sits in: 0 is the first seat (White). The engine
/// names the player on roll by seat index, and a turn asked one at a time
/// (`backgammon/bot`) needs the same number a whole review's turn carries.
pub fn seat_index(s: GameState, player_id: String) -> Int {
  s.order
  |> list.index_map(fn(id, i) { #(id, i) })
  |> list.find(fn(entry) { entry.0 == player_id })
  |> result.map(fn(entry) { entry.1 })
  |> result.unwrap(0)
}
