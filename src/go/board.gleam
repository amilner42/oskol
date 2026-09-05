//// Go board rules: placement, capture, suicide, Tromp-Taylor scoring.
////
//// Points are integer indices `row * size + col`. The board is a dict of
//// occupied points; everything here is pure and knows nothing about turns,
//// players or history (superko lives in `go/state`).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

pub type Color {
  Black
  White
}

pub type Board {
  Board(size: Int, stones: Dict(Int, Color))
}

pub type PlaceError {
  Occupied
  Suicide
}

pub fn new(size: Int) -> Board {
  Board(size: size, stones: dict.new())
}

pub fn opponent(color: Color) -> Color {
  case color {
    Black -> White
    White -> Black
  }
}

pub fn color_name(color: Color) -> String {
  case color {
    Black -> "black"
    White -> "white"
  }
}

pub fn index(board: Board, col: Int, row: Int) -> Int {
  row * board.size + col
}

pub fn col_row(board: Board, point: Int) -> #(Int, Int) {
  #(point % board.size, point / board.size)
}

/// The stable id of an intersection: `p<col>-<row>`, zero-based.
pub fn point_id(board: Board, point: Int) -> String {
  let #(col, row) = col_row(board, point)
  "p" <> int.to_string(col) <> "-" <> int.to_string(row)
}

/// Parse a `p<col>-<row>` id back to an index.
pub fn parse_point(board: Board, id: String) -> Result(Int, Nil) {
  use rest <- result.try(case string.starts_with(id, "p") {
    True -> Ok(string.drop_start(id, 1))
    False -> Error(Nil)
  })
  case string.split(rest, "-") {
    [c, r] -> {
      use col <- result.try(int.parse(c))
      use row <- result.try(int.parse(r))
      case col >= 0 && col < board.size && row >= 0 && row < board.size {
        True -> Ok(index(board, col, row))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

pub fn stone_at(board: Board, point: Int) -> Result(Color, Nil) {
  dict.get(board.stones, point)
}

pub fn neighbors(board: Board, point: Int) -> List(Int) {
  let #(col, row) = col_row(board, point)
  [#(col - 1, row), #(col + 1, row), #(col, row - 1), #(col, row + 1)]
  |> list.filter_map(fn(p) {
    case p.0 >= 0 && p.0 < board.size && p.1 >= 0 && p.1 < board.size {
      True -> Ok(index(board, p.0, p.1))
      False -> Error(Nil)
    }
  })
}

/// The connected group of same-colored stones containing `point`, and the
/// number of distinct liberties it has.
pub fn group(board: Board, point: Int) -> #(Set(Int), Int) {
  case stone_at(board, point) {
    Error(_) -> #(set.new(), 0)
    Ok(color) -> {
      let #(stones, liberties) =
        flood(board, color, [point], set.new(), set.new())
      #(stones, set.size(liberties))
    }
  }
}

fn flood(
  board: Board,
  color: Color,
  frontier: List(Int),
  stones: Set(Int),
  liberties: Set(Int),
) -> #(Set(Int), Set(Int)) {
  case frontier {
    [] -> #(stones, liberties)
    [point, ..rest] ->
      case set.contains(stones, point) {
        True -> flood(board, color, rest, stones, liberties)
        False -> {
          let stones = set.insert(stones, point)
          let #(frontier, liberties) =
            list.fold(neighbors(board, point), #(rest, liberties), fn(acc, n) {
              let #(frontier, liberties) = acc
              case stone_at(board, n) {
                Ok(c) if c == color -> #([n, ..frontier], liberties)
                Ok(_) -> #(frontier, liberties)
                Error(_) -> #(frontier, set.insert(liberties, n))
              }
            })
          flood(board, color, frontier, stones, liberties)
        }
      }
  }
}

/// Place a stone: occupy the point, remove opponent groups left without
/// liberties, then reject the move as suicide when the placed stone's own
/// group still has none. Captures happen first, so capturing into a spot
/// that would otherwise be suicide is legal. Returns the captured points,
/// sorted ascending.
pub fn place(
  board: Board,
  point: Int,
  color: Color,
) -> Result(#(Board, List(Int)), PlaceError) {
  case stone_at(board, point) {
    Ok(_) -> Error(Occupied)
    Error(_) -> {
      let with_stone =
        Board(..board, stones: dict.insert(board.stones, point, color))
      let captured =
        neighbors(board, point)
        |> list.fold(set.new(), fn(captured, n) {
          case stone_at(with_stone, n) {
            Ok(c) if c != color ->
              case set.contains(captured, n) {
                True -> captured
                False -> {
                  let #(stones, liberties) = group(with_stone, n)
                  case liberties {
                    0 -> set.union(captured, stones)
                    _ -> captured
                  }
                }
              }
            _ -> captured
          }
        })
      let next =
        Board(
          ..board,
          stones: set.fold(captured, with_stone.stones, fn(stones, p) {
              dict.delete(stones, p)
            })
            |> dict.insert(point, color),
        )
      let #(_, liberties) = group(next, point)
      case liberties {
        0 -> Error(Suicide)
        _ -> Ok(#(next, set.to_list(captured) |> list.sort(int.compare)))
      }
    }
  }
}

/// Empty points where `color` may legally place a stone, before any superko
/// consideration (that filter belongs to `go/state`, which owns the history).
pub fn placeable_points(board: Board, color: Color) -> List(Int) {
  list.range(0, board.size * board.size - 1)
  |> list.filter(fn(point) {
    case place(board, point, color) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

/// The whole-board position as a canonical string: one character per point
/// in index order (`.` empty, `b` black, `w` white). Used as the superko key:
/// exact, collision-free and cheap at these board sizes, unlike a hash.
pub fn canonical(board: Board) -> String {
  list.range(0, board.size * board.size - 1)
  |> list.map(fn(point) {
    case stone_at(board, point) {
      Ok(Black) -> "b"
      Ok(White) -> "w"
      Error(_) -> "."
    }
  })
  |> string.concat
}

pub fn stone_count(board: Board, color: Color) -> Int {
  dict.fold(board.stones, 0, fn(count, _, c) {
    case c == color {
      True -> count + 1
      False -> count
    }
  })
}

/// Tromp-Taylor area score, `#(black, white)`: stones on the board plus
/// empty points that reach only that color. An empty region touching both
/// colors (or neither, as on an empty board) counts for no one. Komi is not
/// applied here.
pub fn score(board: Board) -> #(Int, Int) {
  let all = list.range(0, board.size * board.size - 1)
  let empties = list.filter(all, fn(p) { stone_at(board, p) == Error(Nil) })
  let #(black_territory, white_territory, _) =
    list.fold(empties, #(0, 0, set.new()), fn(acc, point) {
      let #(black, white, seen) = acc
      case set.contains(seen, point) {
        True -> acc
        False -> {
          let #(region, touches_black, touches_white) =
            empty_region(board, [point], set.new(), False, False)
          let seen = set.union(seen, region)
          case touches_black, touches_white {
            True, False -> #(black + set.size(region), white, seen)
            False, True -> #(black, white + set.size(region), seen)
            _, _ -> #(black, white, seen)
          }
        }
      }
    })
  #(
    stone_count(board, Black) + black_territory,
    stone_count(board, White) + white_territory,
  )
}

fn empty_region(
  board: Board,
  frontier: List(Int),
  region: Set(Int),
  touches_black: Bool,
  touches_white: Bool,
) -> #(Set(Int), Bool, Bool) {
  case frontier {
    [] -> #(region, touches_black, touches_white)
    [point, ..rest] ->
      case set.contains(region, point) {
        True -> empty_region(board, rest, region, touches_black, touches_white)
        False -> {
          let region = set.insert(region, point)
          let #(frontier, touches_black, touches_white) =
            list.fold(
              neighbors(board, point),
              #(rest, touches_black, touches_white),
              fn(acc, n) {
                let #(frontier, black, white) = acc
                case stone_at(board, n) {
                  Ok(Black) -> #(frontier, True, white)
                  Ok(White) -> #(frontier, black, True)
                  Error(_) -> #([n, ..frontier], black, white)
                }
              },
            )
          empty_region(board, frontier, region, touches_black, touches_white)
        }
      }
  }
}

/// Build a board from row strings for tests: `.` empty, `b` black, `w` white.
pub fn from_rows(rows: List(String)) -> Board {
  let size = list.length(rows)
  let stones =
    rows
    |> list.index_fold(dict.new(), fn(stones, row_text, row) {
      string.to_graphemes(row_text)
      |> list.index_fold(stones, fn(stones, char, col) {
        case char {
          "b" -> dict.insert(stones, row * size + col, Black)
          "w" -> dict.insert(stones, row * size + col, White)
          _ -> stones
        }
      })
    })
  Board(size: size, stones: stones)
}
