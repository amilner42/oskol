//// Go: the gamekit contract entry.

import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/list
import gleam/result
import go/engine.{type Action}
import go/projection
import go/state.{type GameState}

pub fn game() -> Game(GameState, Action) {
  game.Game(
    info: info(),
    init: init,
    decode_action: decode_action,
    apply: engine.apply,
    legal: engine.legal,
    scene: projection.build,
    outcome: outcome,
    clocks: engine.on_the_clock,
    timeout: fn(_, _) { game.Forfeit },
  )
}

pub fn info() -> game.Info {
  game.Info(
    slug: projection.slug,
    name: "Go",
    tagline: "The oldest game",
    description: "Surround territory and capture stones on a 9x9, 13x13 or 19x19 board. Area scoring, positional superko, komi to white; two passes end the game.",
    min_players: 2,
    max_players: 2,
    formats: [
      format("9x9", "9×9", "A quick game on the small board", 9),
      format("13x13", "13×13", "The middle board", 13),
      format("19x19", "19×19", "The full board", 19),
    ],
    clocks: ["none", "blitz", "rapid", "delay", "per_move"],
    default_clock: "none",
  )
}

fn format(
  id: String,
  name: String,
  description: String,
  size: Int,
) -> game.Format {
  game.Format(
    id: id,
    name: name,
    description: description,
    config: dict.from_list([#("size", size), #("komi2", 13)]),
    settings: [
      game.Setting(
        id: "komi",
        name: "Komi",
        choices: [
          game.Choice("55", "5.5", dict.from_list([#("komi2", 11)])),
          game.Choice("65", "6.5", dict.from_list([#("komi2", 13)])),
          game.Choice("75", "7.5", dict.from_list([#("komi2", 15)])),
        ],
        default: "65",
      ),
    ],
  )
}

pub fn init(
  config: game.Config,
  seats: List(game.Seat),
  rng: Rng,
) -> Result(GameState, String) {
  case list.length(seats) {
    2 ->
      Ok(state.new(
        state.Config(
          size: game.config_get(config, "size", 9),
          komi2: game.config_get(config, "komi2", 13),
        ),
        list.map(seats, fn(s) { #(s.id, s.name) }),
        rng,
      ))
    _ -> Error("Go needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  case incoming.name {
    "pass" -> Ok(engine.Pass)
    "resign" -> Ok(engine.Resign)
    "place" -> {
      use point <- result.try(point_param(incoming.params))
      Ok(engine.Place(point))
    }
    other -> Error("Unknown action: " <> other)
  }
}

/// The point may arrive as a string or a one-element array (a select param
/// sends a list of ids).
fn point_param(params) -> Result(String, String) {
  case action.string_param(params, "point") {
    Ok(text) -> Ok(text)
    Error(_) ->
      case action.ids_param(params, "point") {
        Ok([text]) -> Ok(text)
        Ok(_) -> Error("Choose exactly one point")
        Error(e) -> Error(e)
      }
  }
}

pub fn outcome(state: GameState) -> game.Outcome {
  case state.phase {
    state.Finished(color) -> game.Finished([state.player_of(state, color)])
    _ -> game.Ongoing
  }
}
