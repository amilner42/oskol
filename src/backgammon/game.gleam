//// Backgammon: the gamekit contract entry.

import backgammon/board
import backgammon/engine.{type Action}
import backgammon/projection
import backgammon/state.{type GameState}
import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/list
import gleam/result

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
  )
}

pub fn info() -> game.Info {
  game.Info(
    slug: projection.slug,
    name: "Backgammon",
    tagline: "The classic race game",
    description: "Roll, move, hit and bear off, with the doubling cube. Play a single game, a match to a target with the Crawford rule, or unlimited games with the Jacoby rule.",
    min_players: 2,
    max_players: 2,
    formats: [
      format("single", "Single game", "One game, no cube", 1, False, False),
      format("match3", "Match to 3", "Cube and Crawford rule", 3, True, False),
      format("match5", "Match to 5", "Cube and Crawford rule", 5, True, False),
      format("match7", "Match to 7", "Cube and Crawford rule", 7, True, False),
      format(
        "unlimited",
        "Unlimited",
        "Keep playing, cube and Jacoby rule",
        0,
        True,
        True,
      ),
    ],
  )
}

fn format(
  id: String,
  name: String,
  description: String,
  target: Int,
  cube: Bool,
  jacoby: Bool,
) -> game.Format {
  game.Format(
    id: id,
    name: name,
    description: description,
    config: dict.from_list([
      #("target", target),
      #("cube", bool_int(cube)),
      #("jacoby", bool_int(jacoby)),
    ]),
  )
}

fn bool_int(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
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
          target: game.config_get(config, "target", 1),
          cube: game.config_get(config, "cube", 0) == 1,
          jacoby: game.config_get(config, "jacoby", 0) == 1,
        ),
        list.map(seats, fn(s) { #(s.id, s.name) }),
        rng,
      ))
    _ -> Error("Backgammon needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  case incoming.name {
    "roll" -> Ok(engine.Roll)
    "double" -> Ok(engine.Double)
    "take" -> Ok(engine.Take)
    "drop" -> Ok(engine.Drop)
    "resign" -> Ok(engine.Resign)
    "move" -> {
      use from <- result.try(loc_param(incoming.params, "from"))
      use to <- result.try(loc_param(incoming.params, "to"))
      Ok(engine.MoveChecker(from, to))
    }
    other -> Error("Unknown action: " <> other)
  }
}

/// A location param may arrive as a string or a one-element array.
fn loc_param(params, name: String) -> Result(board.Loc, String) {
  let raw = case action.string_param(params, name) {
    Ok(text) -> Ok(text)
    Error(_) ->
      case action.ids_param(params, name) {
        Ok([text]) -> Ok(text)
        Ok(_) -> Error("Choose exactly one " <> name)
        Error(e) -> Error(e)
      }
  }
  use text <- result.try(raw)
  board.parse_loc(text) |> result.replace_error("Invalid location: " <> text)
}

pub fn outcome(state: GameState) -> game.Outcome {
  case state.phase {
    state.Finished(color) -> game.Finished([state.player_of(state, color)])
    _ -> game.Ongoing
  }
}
