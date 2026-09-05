//// Go actions, events, legal schemas and clocks.

import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import go/state.{type GameState}

pub type Action {
  /// Place a stone on an empty intersection, by point id ("p<col>-<row>").
  Place(point: String)
  Pass
  Resign
}

pub const board_zone = "board"

fn custom(kind: String, fields: List(#(String, Json))) -> Event {
  event.Custom(kind, json.object(fields))
}

fn turn_started(state: GameState) -> List(Event) {
  case state.to_move(state) {
    Some(id) -> [custom("turn_started", [#("player_id", json.string(id))])]
    None -> []
  }
}

pub fn apply(
  state: GameState,
  player_id: String,
  action: Action,
) -> Result(#(GameState, List(Event)), String) {
  case action {
    Place(point_id) -> {
      use placed <- result.try(state.place(state, player_id, point_id))
      let next = placed.state
      let capture_events = case placed.captured_ids {
        [] -> []
        ids ->
          list.append(list.map(ids, event.destroyed(_, board_zone)), [
            custom("captured", [
              #("player_id", json.string(player_id)),
              #("stones", json.array(ids, json.string)),
            ]),
            event.CounterChanged(
              player_id,
              "captures",
              state.captured_by(state, player_id),
              state.captured_by(next, player_id),
            ),
          ])
      }
      Ok(#(
        next,
        list.flatten([
          [
            custom("stone_placed", [
              #("player_id", json.string(player_id)),
              #("point", json.string(point_id)),
              #("stone", json.string(placed.stone_id)),
            ]),
            event.created(placed.stone_id, board_zone),
          ],
          capture_events,
          turn_started(next),
        ]),
      ))
    }
    Pass -> {
      use #(next, end) <- result.try(state.pass(state, player_id))
      let passed = custom("passed", [#("player_id", json.string(player_id))])
      case end {
        Some(game_end) -> Ok(#(next, [passed, ..end_events(next, game_end)]))
        None -> Ok(#(next, [passed, ..turn_started(next)]))
      }
    }
    Resign -> {
      use #(next, game_end) <- result.try(state.resign(state, player_id))
      Ok(
        #(next, [
          custom("resigned", [#("player_id", json.string(player_id))]),
          ..end_events(next, game_end)
        ]),
      )
    }
  }
}

fn end_events(next: GameState, end: state.GameEnd) -> List(Event) {
  let won = case end.kind {
    state.Scored(black2, white2) -> [
      custom("scored", [
        #("black", json.float(state.score2_to_float(black2))),
        #("white", json.float(state.score2_to_float(white2))),
        #("komi", json.float(state.komi(next))),
      ]),
      custom("game_won", [
        #("player_id", json.string(end.winner)),
        #("kind", json.string("scored")),
      ]),
    ]
    state.Resigned -> [
      custom("game_won", [
        #("player_id", json.string(end.winner)),
        #("kind", json.string("resigned")),
      ]),
    ]
  }
  list.append(won, [event.PhaseChanged("game_over")])
}

pub fn legal(state: GameState, player_id: String) -> List(Schema) {
  let resign = case state.can_resign(state, player_id) {
    True -> [action.simple("resign", "Resign")]
    False -> []
  }
  let turn = case state.can_pass(state, player_id) {
    False -> []
    True -> {
      let place = case state.legal_point_ids(state, player_id) {
        [] -> []
        candidates -> [
          action.Schema("place", "Place a stone", [
            action.select("point", board_zone, candidates, 1, 1),
          ]),
        ]
      }
      list.append(place, [action.simple("pass", "Pass")])
    }
  }
  list.append(turn, resign)
}

pub fn on_the_clock(state: GameState) -> List(String) {
  case state.to_move(state) {
    Some(id) -> [id]
    None -> []
  }
}
