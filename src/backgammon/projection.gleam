//// Project backgammon state into the generic Scene.

import backgammon/board.{type Color, Bar, Off, Point}
import backgammon/engine
import backgammon/state.{type GameState}
import gamekit/scene.{type Scene, type Viewer, type Zone}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}

pub const slug = "backgammon"

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  let viewer_id = scene.viewer_id(viewer)
  // Only the mover sees their staged moves; everyone else sees the board as
  // it was when the turn began.
  let is_mover = viewer_id != None && state.to_move(state) == viewer_id
  let state =
    state.GameState(..state, board: state.visible_board(state, viewer_id))
  scene.Scene(
    game: slug,
    phase: phase_name(state),
    viewer: viewer,
    players: list.map(state.order, fn(id) { player_info(state, id) }),
    zones: list.flatten([
      point_zones(state),
      player_zones(state),
      [dice_zone(state, is_mover), cube_zone(state)],
    ]),
    data: [
      #("to_move", json.nullable(state.to_move(state), json.string)),
      #("to_act", json.nullable(state.to_act(state), json.string)),
      #(
        "cube",
        json.object([
          #("value", json.int(state.cube_value)),
          #("owner", case state.cube_owner {
            Some(c) -> json.string(state.player_of(state, c))
            None -> json.null()
          }),
          #("enabled", json.bool(state.config.cube)),
          #("crawford", json.bool(state.crawford)),
          #("pending_from", case state.phase {
            state.Doubled(by) -> json.string(state.player_of(state, by))
            _ -> json.null()
          }),
        ]),
      ),
      #("unlimited", json.bool(state.unlimited(state))),
      #(
        "staged",
        json.int(case is_mover {
          True -> list.length(state.staged)
          False -> 0
        }),
      ),
      #(
        "turn_complete",
        json.bool(case viewer_id {
          Some(id) -> state.can_play(state, id)
          None -> False
        }),
      ),
      #(
        "dice",
        json.array(
          case state.phase, is_mover {
            // Which dice are used is part of the private staging
            state.Moving(_, _), False -> state.turn_dice(state)
            _, _ -> state.dice_left(state)
          },
          json.int,
        ),
      ),
      #("last_roll", json.array(state.last_roll, json.int)),
      #("target", json.int(state.config.target)),
      #("game_number", json.int(state.game_number)),
      #("winner_id", case state.phase {
        state.Finished(color) -> json.string(state.player_of(state, color))
        _ -> json.null()
      }),
    ],
  )
}

pub fn phase_name(state: GameState) -> String {
  case state.phase {
    state.Rolling(_) -> "rolling"
    state.Doubled(_) -> "doubled"
    state.Moving(_, _) -> "moving"
    state.Finished(_) -> "game_over"
  }
}

fn color_for(state: GameState, id: String) -> Color {
  case state.color_of(state, id) {
    Ok(c) -> c
    Error(_) -> board.White
  }
}

fn player_info(state: GameState, id: String) -> scene.PlayerInfo {
  let color = color_for(state, id)
  scene.player(id, state.name_of(state, id))
  |> scene.counter("pips", board.pip_count(state.board, color))
  |> scene.counter("off", board.borne_off(state.board, color))
  |> scene.counter("bar", board.on_bar(state.board, color))
  |> scene.counter("score", state.score_of(state, id))
  |> scene.flag("to_move", state.to_move(state) == Some(id))
  |> scene.flag("owns_cube", case state.cube_owner {
    Some(c) -> state.player_of(state, c) == id
    None -> False
  })
  |> scene.player_data("color", json.string(board.color_name(color)))
}

fn checker_token(id: String, color: Color) -> scene.Token {
  scene.token(id, "checker")
  |> scene.with_props([#("color", json.string(board.color_name(color)))])
}

fn point_zones(state: GameState) -> List(Zone) {
  list.range(1, 24)
  |> list.map(fn(p) {
    let tokens =
      list.append(
        list.map(
          board.checkers_at(state.board, board.White, Point(p)),
          checker_token(_, board.White),
        ),
        list.map(
          board.checkers_at(state.board, board.Black, Point(p)),
          checker_token(_, board.Black),
        ),
      )
    scene.zone("point:" <> int.to_string(p), scene.Stack, tokens)
  })
}

fn player_zones(state: GameState) -> List(Zone) {
  list.flat_map(state.order, fn(id) {
    let color = color_for(state, id)
    [
      scene.owned_zone(
        "bar:" <> id,
        id,
        scene.Stack,
        list.map(board.checkers_at(state.board, color, Bar), checker_token(
          _,
          color,
        )),
      ),
      scene.owned_zone(
        "off:" <> id,
        id,
        scene.Stack,
        list.map(board.checkers_at(state.board, color, Off), checker_token(
          _,
          color,
        )),
      ),
    ]
  })
}

fn dice_zone(state: GameState, is_mover: Bool) -> Zone {
  let rolled = state.last_roll
  let left = state.dice_left(state)
  let tokens = case state.phase {
    state.Moving(_, _) -> {
      // Every die of the roll (four for doubles); only the mover sees which
      // are used, since their moves are still private.
      let all = state.turn_dice(state)
      let unused = case is_mover {
        True -> left
        False -> all
      }
      mark_used(all, unused, 0, [])
    }
    _ -> list.index_map(rolled, fn(value, i) { die_token(i, value, True) })
  }
  scene.zone(engine.dice_zone, scene.Row, tokens)
}

fn mark_used(
  all: List(Int),
  left: List(Int),
  index: Int,
  acc: List(scene.Token),
) -> List(scene.Token) {
  case all {
    [] -> list.reverse(acc)
    [value, ..rest] ->
      case list.contains(left, value) {
        True ->
          mark_used(rest, remove_one(left, value), index + 1, [
            die_token(index, value, False),
            ..acc
          ])
        False ->
          mark_used(rest, left, index + 1, [
            die_token(index, value, True),
            ..acc
          ])
      }
  }
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

fn die_token(index: Int, value: Int, used: Bool) -> scene.Token {
  scene.token("die:" <> int.to_string(index), "die")
  |> scene.with_props([#("value", json.int(value)), #("used", json.bool(used))])
}

fn cube_zone(state: GameState) -> Zone {
  let owner = case state.cube_owner {
    Some(c) -> json.string(state.player_of(state, c))
    None -> json.null()
  }
  let token =
    scene.token("cube", "cube")
    |> scene.with_props([
      #("value", json.int(state.cube_value)),
      #("owner", owner),
    ])
  scene.zone("cube", scene.Row, case state.config.cube {
    True -> [token]
    False -> []
  })
}
