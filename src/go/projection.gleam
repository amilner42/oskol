//// Project go state into the generic Scene.
////
//// Go has no hidden information: every viewer sees the same board. The
//// board is one Grid zone holding a token for every intersection: stones
//// keep the id they were placed with ("s<n>", the move number, which is
//// public), empty points carry their stable point id ("p<col>-<row>") so
//// the `place` schema can offer them as candidates.

import gamekit/scene.{type Scene, type Viewer, type Zone}
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import go/board
import go/engine
import go/state.{type GameState}

pub const slug = "go"

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  scene.Scene(
    game: slug,
    phase: phase_name(state),
    viewer: viewer,
    players: list.map(state.order, fn(id) { player_info(state, id) }),
    zones: [board_zone(state)],
    data: [
      #("to_move", json.nullable(state.to_move(state), json.string)),
      #("size", json.int(state.config.size)),
      #("komi", json.float(state.komi(state))),
      #("passes", json.int(state.passes)),
      #("winner_id", case state.phase {
        state.Finished(color) -> json.string(state.player_of(state, color))
        _ -> json.null()
      }),
      #("score", case state.final_score2 {
        Some(#(black2, white2)) ->
          json.object([
            #("black", json.float(state.score2_to_float(black2))),
            #("white", json.float(state.score2_to_float(white2))),
          ])
        None -> json.null()
      }),
    ],
  )
}

pub fn phase_name(state: GameState) -> String {
  case state.phase {
    state.Playing(_) -> "playing"
    state.Finished(_) -> "game_over"
  }
}

fn player_info(state: GameState, id: String) -> scene.PlayerInfo {
  let color = case state.color_of(state, id) {
    Ok(c) -> c
    Error(_) -> board.Black
  }
  scene.player(id, state.name_of(state, id))
  |> scene.counter("stones", board.stone_count(state.board, color))
  |> scene.counter("captures", state.captured_by(state, id))
  |> scene.flag("to_move", state.to_move(state) == Some(id))
  |> scene.player_data("color", json.string(board.color_name(color)))
}

/// One token per intersection, in row-major order (deterministic: never
/// serialised from a dict walk).
fn board_zone(state: GameState) -> Zone {
  let size = state.config.size
  let tokens =
    list.range(0, size * size - 1)
    |> list.map(fn(point) {
      let #(col, row) = board.col_row(state.board, point)
      case board.stone_at(state.board, point) {
        Ok(color) -> {
          let id = case dict.get(state.stone_ids, point) {
            Ok(id) -> id
            Error(_) -> board.point_id(state.board, point)
          }
          scene.token(id, "stone")
          |> scene.at(col, row)
          |> scene.with_props([
            #("color", json.string(board.color_name(color))),
            #("last", json.bool(state.last_point == Some(point))),
          ])
        }
        Error(_) ->
          scene.token(board.point_id(state.board, point), "point")
          |> scene.at(col, row)
          |> scene.with_props([#("color", json.string("#c8a05f"))])
      }
    })
  scene.zone(engine.board_zone, scene.Grid(size, size), tokens)
}
