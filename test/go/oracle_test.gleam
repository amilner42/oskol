//// An independent scoring oracle, written from the Tromp-Taylor definition
//// on raw stones: a point scores for a color when it is that color's stone,
//// or empty and every stone it reaches (through empty points) is that
//// color. Computed point by point with its own search, unlike the engine's
//// region-based scorer, and cross-checked on named and generated boards.

import gamekit/rng
import gleam/list
import gleam/set.{type Set}
import go/board.{type Board, Black, White}

fn oracle_score(b: Board) -> #(Int, Int) {
  list.range(0, b.size * b.size - 1)
  |> list.fold(#(0, 0), fn(acc, point) {
    case board.stone_at(b, point) {
      Ok(Black) -> #(acc.0 + 1, acc.1)
      Ok(White) -> #(acc.0, acc.1 + 1)
      Error(_) -> {
        let #(reaches_black, reaches_white) =
          reaches(b, [point], set.new(), False, False)
        case reaches_black, reaches_white {
          True, False -> #(acc.0 + 1, acc.1)
          False, True -> #(acc.0, acc.1 + 1)
          _, _ -> acc
        }
      }
    }
  })
}

fn reaches(
  b: Board,
  frontier: List(Int),
  seen: Set(Int),
  black: Bool,
  white: Bool,
) -> #(Bool, Bool) {
  case frontier {
    [] -> #(black, white)
    [point, ..rest] ->
      case set.contains(seen, point) {
        True -> reaches(b, rest, seen, black, white)
        False -> {
          let seen = set.insert(seen, point)
          let #(frontier, black, white) =
            list.fold(
              board.neighbors(b, point),
              #(rest, black, white),
              fn(acc, n) {
                case board.stone_at(b, n) {
                  Ok(Black) -> #(acc.0, True, acc.2)
                  Ok(White) -> #(acc.0, acc.1, True)
                  Error(_) -> #([n, ..acc.0], acc.1, acc.2)
                }
              },
            )
          reaches(b, frontier, seen, black, white)
        }
      }
  }
}

pub fn oracle_agrees_on_named_boards_test() {
  let named = [
    #(board.new(9), #(0, 0)),
    #(board.from_rows(["...", ".b.", "..."]), #(9, 0)),
    #(board.from_rows(["..bw.", "..bw.", "..bw.", "..bw.", "..bw."]), #(15, 10)),
    #(board.from_rows([".b.w.", ".b.w.", ".b.w.", ".b.w.", ".b.w."]), #(10, 10)),
    #(board.from_rows(["bbbbb", "bw.wb", "bw.wb", "bwwwb", "bbbbb"]), #(16, 7)),
  ]
  list.each(named, fn(case_) {
    assert board.score(case_.0) == case_.1
    assert oracle_score(case_.0) == case_.1
  })
}

/// A board built by a stream of random placements (random point, random
/// color) through the real placement rules, so captures shape it.
fn random_board(seed: Int, size: Int, moves: Int) -> Board {
  let #(b, _) =
    list.range(1, moves)
    |> list.fold(#(board.new(size), rng.seed(seed)), fn(acc, _) {
      let #(b, r) = acc
      let #(point, r) = rng.int(r, size * size)
      let #(coin, r) = rng.int(r, 2)
      let color = case coin {
        0 -> Black
        _ -> White
      }
      case board.place(b, point, color) {
        Ok(#(next, _)) -> #(next, r)
        Error(_) -> #(b, r)
      }
    })
  b
}

pub fn oracle_agrees_with_the_engine_on_generated_boards_test() {
  list.each(list.range(1, 150), fn(seed) {
    let #(moves, _) = rng.int(rng.seed(seed * 31), 120)
    let b = random_board(seed, 9, 10 + moves)
    let engine = board.score(b)
    let oracle = oracle_score(b)
    assert engine == oracle
    // Areas never exceed the board.
    assert engine.0 + engine.1 <= 81
  })
  list.each(list.range(1, 25), fn(seed) {
    let b = random_board(seed, 13, 160)
    assert board.score(b) == oracle_score(b)
  })
  list.each(list.range(1, 8), fn(seed) {
    let b = random_board(seed, 19, 300)
    assert board.score(b) == oracle_score(b)
  })
}
