//// Backgammon: the gamekit contract entry.

import backgammon/board
import backgammon/engine.{type Action}
import backgammon/projection
import backgammon/state.{type GameState}
import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
    timeout: fn(_, _) { game.Forfeit },
    record: fn(s) { Some(projection.record_json(s)) },
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
    // Minutes plus the 12 s delay below: backgammon's clocks. Rooms made
    // under the older presets (blitz, rapid, delay, per_move) still carry and
    // replay them; they are just no longer offered.
    clocks: ["none", "bg3", "bg5", "bg10"],
    default_clock: "none",
    // Live backgammon runs on a delay, not a bare clock: the first twelve
    // seconds of every turn are free under every control offered here, so
    // rolling, reading the dice and a turn that plays nothing all cost
    // nothing. Unused delay is not banked.
    turn_delay_ms: 12_000,
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
    "undo" -> Ok(engine.Undo)
    "play" -> Ok(engine.Play)
    "double" -> Ok(engine.Double)
    "take" -> Ok(engine.Take)
    "drop" -> Ok(engine.Drop)
    "resign" -> {
      // The stakes may arrive as a string or a one-element array, like a
      // location; a bare resign with no stakes is the humblest one.
      let raw = case action.string_param(incoming.params, "stakes") {
        Ok(text) -> Ok(text)
        Error(_) ->
          case action.ids_param(incoming.params, "stakes") {
            Ok([text]) -> Ok(text)
            Ok(_) -> Error("Choose exactly one stakes")
            Error(_) -> Ok("single")
          }
      }
      use text <- result.try(raw)
      use stakes <- result.try(engine.parse_stakes(text))
      Ok(engine.Resign(stakes))
    }
    "accept_resign" -> Ok(engine.AcceptResign)
    "decline_resign" -> Ok(engine.DeclineResign)
    "ready" -> Ok(engine.Ready)
    "move" -> {
      use from <- result.try(loc_param(incoming.params, "from"))
      use to <- result.try(loc_param(incoming.params, "to"))
      use die <- result.try(action.optional_string_param(
        incoming.params,
        "selected_die",
      ))
      case die {
        Some(value) -> {
          use parsed <- result.try(
            int.parse(value) |> result.replace_error("Invalid die"),
          )
          Ok(engine.MoveCheckerUsing(from, to, parsed))
        }
        None -> Ok(engine.MoveChecker(from, to))
      }
    }
    "bear_off" -> {
      use value <- result.try(action.string_param(incoming.params, "first_die"))
      use first_die <- result.try(
        int.parse(value) |> result.replace_error("Invalid first die"),
      )
      Ok(engine.BearOff(first_die))
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
