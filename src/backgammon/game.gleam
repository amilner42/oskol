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
    description: "Roll, move, hit and bear off. Gammons count double, backgammons triple. Play a single game or a match to five points.",
    min_players: 2,
    max_players: 2,
    formats: [
      game.Format(
        "single",
        "Single game",
        "First to bear off wins",
        dict.from_list([#("target", 1)]),
      ),
      game.Format(
        "match5",
        "Match to 5",
        "Gammons and backgammons count",
        dict.from_list([#("target", 5)]),
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
        state.Config(target: game.config_get(config, "target", 1)),
        list.map(seats, fn(s) { #(s.id, s.name) }),
        rng,
      ))
    _ -> Error("Backgammon needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  case incoming.name {
    "roll" -> Ok(engine.Roll)
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
