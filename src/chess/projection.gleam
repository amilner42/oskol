//// Project chess state into the generic Scene. Full information: both
//// viewers and spectators see the whole board.
////
//// The board is one 8x8 Grid zone. Tokens are the pieces, positioned by
//// square with row 0 at the top from White's side (a8 = column 0, row 0),
//// and keep their ids for the whole game; a promoted pawn keeps its id and
//// its face changes. The scene declares `grid_style: "checker"` so the
//// generic renderer paints the light/dark square pattern (the colors ride
//// along in `checker_colors`); the bespoke view draws its own board.

import chess/board.{type Color, Black, White}
import chess/engine
import chess/state.{type GameState}
import gamekit/scene.{type Scene, type Viewer, type Zone}
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub const slug = "chess"

/// The two square colors, light then dark: calm blues from the multicade
/// palette (any game using `grid_style: "checker"` can hint its own pair).
pub const checker_colors = ["#dce8f2", "#8fb4d2"]

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  scene.Scene(
    game: slug,
    phase: phase_name(state),
    viewer: viewer,
    players: list.map(state.seats, fn(seat) { player_info(state, seat.0) }),
    zones: [board_zone(state)],
    data: [
      #("to_move", json.nullable(state.to_move(state), json.string)),
      #("in_check", json.bool(in_check_now(state))),
      #("halfmove_clock", json.int(state.position.halfmove)),
      #("ply", json.int(state.ply)),
      #("last_move", case state.last_move {
        Some(#(from, to)) ->
          json.preprocessed_array([
            json.string(board.square_name(from)),
            json.string(board.square_name(to)),
          ])
        None -> json.null()
      }),
      #("result", result_json(state)),
      // Rendering hints for the generic renderer: a checkered board with
      // these two square colors (light, dark).
      #("grid_style", json.string("checker")),
      #("checker_colors", json.array(checker_colors, json.string)),
    ],
  )
}

pub fn phase_name(state: GameState) -> String {
  case state.phase {
    state.Playing -> "playing"
    _ -> "game_over"
  }
}

fn in_check_now(state: GameState) -> Bool {
  state.phase == state.Playing && board.in_check(state.position)
}

fn result_json(state: GameState) -> json.Json {
  case state.phase {
    state.Playing -> json.null()
    state.WonBy(color, reason) ->
      json.object([
        #("winner_id", json.string(state.player_of(state, color))),
        #("reason", json.string(state.reason_name(reason))),
      ])
    state.Drawn(reason) ->
      json.object([
        #("winner_id", json.null()),
        #("reason", json.string(state.reason_name(reason))),
      ])
  }
}

fn player_info(state: GameState, id: String) -> scene.PlayerInfo {
  let color = case state.color_of(state, id) {
    Ok(c) -> c
    Error(_) -> White
  }
  scene.player(id, state.name_of(state, id))
  |> scene.counter("material", material(state, color))
  |> scene.flag("to_move", state.to_move(state) == Some(id))
  |> scene.flag(
    "in_check",
    in_check_now(state) && state.position.to_move == color,
  )
  |> scene.player_data("color", json.string(board.color_name(color)))
}

/// Standard point count of the pieces this color still has on the board.
fn material(state: GameState, color: Color) -> Int {
  dict.to_list(state.position.board)
  |> list.filter(fn(entry) { { entry.1 }.color == color })
  |> list.fold(0, fn(acc, entry) {
    acc
    + case { entry.1 }.kind {
      board.Pawn -> 1
      board.Knight | board.Bishop -> 3
      board.Rook -> 5
      board.Queen -> 9
      board.King -> 0
    }
  })
}

/// One token per piece, in square order (deterministic: a range walk, never
/// a bare dict walk). a8 is column 0 row 0; a1 is column 0 row 7.
fn board_zone(state: GameState) -> Zone {
  let tokens =
    list.range(0, 63)
    |> list.filter_map(fn(sq) {
      case board.piece_at(state.position, sq), dict.get(state.tokens, sq) {
        Some(piece), Ok(id) -> Ok(piece_token(id, piece, sq))
        _, _ -> Error(Nil)
      }
    })
  scene.zone(engine.board_zone, scene.Grid(8, 8), tokens)
}

fn piece_token(id: String, piece: board.Piece, sq: Int) -> scene.Token {
  scene.token(id, "piece")
  |> scene.at(board.file(sq), 7 - board.rank(sq))
  |> scene.with_props([
    #("glyph", json.string(glyph(piece))),
    #("piece", json.string(board.color_name(piece.color))),
    #("kind", json.string(engine.kind_name(piece.kind))),
  ])
}

/// Unicode chess glyphs carry both the piece and its color, so a text
/// renderer's token label is the piece itself.
fn glyph(piece: board.Piece) -> String {
  case piece.color, piece.kind {
    White, board.King -> "♔"
    White, board.Queen -> "♕"
    White, board.Rook -> "♖"
    White, board.Bishop -> "♗"
    White, board.Knight -> "♘"
    White, board.Pawn -> "♙"
    Black, board.King -> "♚"
    Black, board.Queen -> "♛"
    Black, board.Rook -> "♜"
    Black, board.Bishop -> "♝"
    Black, board.Knight -> "♞"
    Black, board.Pawn -> "♟"
  }
}

/// Kept for tests: a compact text row of the board, rank 8 to rank 1.
pub fn board_text(state: GameState) -> String {
  list.range(7, 0)
  |> list.map(fn(rank) {
    list.range(0, 7)
    |> list.map(fn(file) {
      case board.piece_at(state.position, board.square(file, rank)) {
        Some(piece) -> board.piece_letter(piece)
        None -> "."
      }
    })
    |> string.concat
  })
  |> string.join("/")
  <> " "
  <> int.to_string(state.ply)
}
