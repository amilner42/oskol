//// Shared helpers for the go tests.

import gamekit/game.{Seat}
import gamekit/rng
import gleam/dict
import gleam/int
import gleam/list
import gleam/set
import go/board
import go/game as go
import go/state.{type GameState}

pub fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

/// A fresh game on the given format ("9x9", "13x13", "19x19").
pub fn new_game(format: String) -> GameState {
  let assert Ok(f) = game.find_format(go.info(), format)
  let assert Ok(s) = go.init(game.default_config(f), seats(), rng.seed(1))
  s
}

/// A mid-game state standing on a hand-built board with the given color to
/// move. History holds only this position; ko and superko tests inject any
/// further forbidden positions themselves.
pub fn mid_game(rows: List(String), to_move: board.Color) -> GameState {
  let b = board.from_rows(rows)
  let base = case b.size {
    13 -> new_game("13x13")
    19 -> new_game("19x19")
    _ -> new_game("9x9")
  }
  let occupied =
    list.range(0, b.size * b.size - 1)
    |> list.filter(fn(p) {
      case board.stone_at(b, p) {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  let ids =
    occupied
    |> list.index_fold(dict.new(), fn(ids, point, i) {
      dict.insert(ids, point, "s" <> int.to_string(i + 1))
    })
  state.GameState(
    ..base,
    board: b,
    phase: state.Playing(to_move),
    history: set.insert(set.new(), board.canonical(b)),
    stone_ids: ids,
    move_number: dict.size(ids),
  )
}
