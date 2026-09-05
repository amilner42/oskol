//// Project chess state into the generic Scene. Full information: both
//// viewers and spectators see the whole board.
////
//// Zones are one per square, named "<rank>:<file>" ("8:a" .. "1:h") and
//// emitted rank 8 first, so the generic renderer's strip grouping draws
//// eight rank strips stacked like a board. Tokens keep their ids for the
//// whole game; a promoted pawn keeps its id and its glyph changes.

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

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  scene.Scene(
    game: slug,
    phase: phase_name(state),
    viewer: viewer,
    players: list.map(state.seats, fn(seat) { player_info(state, seat.0) }),
    zones: square_zones(state),
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

fn square_zones(state: GameState) -> List(Zone) {
  list.range(7, 0)
  |> list.flat_map(fn(rank) {
    list.range(0, 7)
    |> list.map(fn(file) {
      let sq = board.square(file, rank)
      let tokens = case
        board.piece_at(state.position, sq),
        dict.get(state.tokens, sq)
      {
        Some(piece), Ok(id) -> [piece_token(id, piece)]
        _, _ -> []
      }
      scene.zone(engine.zone_id(sq), scene.Stack, tokens)
    })
  })
}

fn piece_token(id: String, piece: board.Piece) -> scene.Token {
  scene.token(id, "piece")
  |> scene.with_props([#("glyph", json.string(glyph(piece)))])
}

/// Unicode chess glyphs carry both the piece and its color, so the generic
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
