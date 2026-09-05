//// Test helpers: build game states from FEN and pick moves by name.

import chess/board.{type Move, Move}
import chess/fen
import chess/state.{type GameState}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub const white = "p1"

pub const black = "p2"

pub fn seats() -> List(#(String, String)) {
  [#(white, "Alice"), #(black, "Bob")]
}

/// A game state at an arbitrary FEN position, with generated token ids.
pub fn state_from(fen_text: String) -> GameState {
  let position = fen.load(fen_text)
  let tokens =
    dict.to_list(position.board)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.index_map(fn(entry, i) { #(entry.0, "t" <> int.to_string(i)) })
    |> dict.from_list
  state.GameState(
    seats: seats(),
    position: position,
    tokens: tokens,
    repetition: dict.from_list([#(board.key(position), 1)]),
    last_move: None,
    ply: 0,
    phase: state.Playing,
  )
}

/// A move written as "e2e4" or "e7e8q".
pub fn mv(text: String) -> Move {
  let assert Ok(from) = board.parse_square(gleam_slice(text, 0, 2))
  let assert Ok(to) = board.parse_square(gleam_slice(text, 2, 2))
  let promotion = case gleam_slice(text, 4, 1) {
    "q" -> Some(board.Queen)
    "r" -> Some(board.Rook)
    "b" -> Some(board.Bishop)
    "n" -> Some(board.Knight)
    _ -> None
  }
  Move(from, to, promotion)
}

fn gleam_slice(text: String, at: Int, length: Int) -> String {
  string.slice(text, at, length)
}

/// The legal moves of the side to move at a FEN.
pub fn moves_at(fen_text: String) -> List(Move) {
  board.legal_moves(fen.load(fen_text))
}

pub fn has_move(moves: List(Move), text: String) -> Bool {
  list.contains(moves, mv(text))
}

/// Squares a piece may move from, as ints (for pin tests).
pub fn froms(moves: List(Move)) -> List(Int) {
  list.map(moves, fn(m) { m.from }) |> list.unique
}
