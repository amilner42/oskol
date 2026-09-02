//// Generic checks every game must pass.
////
//// These drive a game only through its contract, sampling actions from the
//// legal schemas, so the same suite runs against every registered game. Games
//// add their own invariant via the `check` callback.

import gamekit/action.{type Schema}
import gamekit/game.{type Game, type Seat}
import gamekit/rng.{type Rng}
import gamekit/scene
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

pub type Step {
  Step(player_id: String, action_json: String)
}

pub type Report(state) {
  Report(state: state, steps: List(Step), finished: Bool)
}

/// Play a game to completion (or `max_steps`) choosing uniformly among the
/// legal actions of all players. Fails if a legal action is rejected, if the
/// game is stuck with no legal actions while unfinished, or if `check` fails.
pub fn random_playout(
  definition: Game(state, a),
  format_id: String,
  seats: List(Seat),
  seed: Int,
  max_steps: Int,
  check: fn(state) -> Result(Nil, String),
) -> Result(Report(state), String) {
  use format <- result.try(
    game.find_format(definition.info, format_id)
    |> result.replace_error("Unknown format"),
  )
  use initial <- result.try(definition.init(
    format.config,
    seats,
    rng.seed(seed),
  ))
  use _ <- result.try(check(initial))
  loop(definition, seats, initial, rng.seed(seed + 7919), max_steps, [], check)
}

fn loop(
  definition: Game(state, a),
  seats: List(Seat),
  state: state,
  chooser: Rng,
  remaining: Int,
  steps: List(Step),
  check: fn(state) -> Result(Nil, String),
) -> Result(Report(state), String) {
  let finished = case definition.outcome(state) {
    game.Ongoing -> False
    game.Finished(_) -> True
  }
  case finished, remaining {
    True, _ ->
      Ok(Report(state: state, steps: list.reverse(steps), finished: True))
    False, 0 ->
      Ok(Report(state: state, steps: list.reverse(steps), finished: False))
    False, _ -> {
      let options =
        list.flat_map(seats, fn(seat) {
          list.map(definition.legal(state, seat.id), fn(schema) {
            #(seat.id, schema)
          })
        })
      case options {
        [] ->
          Error(
            "Stuck: no legal actions but the game is not finished after "
            <> int.to_string(list.length(steps))
            <> " steps",
          )
        _ -> {
          let assert Ok(#(#(player_id, schema), chooser)) =
            rng.pick(chooser, options)
          let #(action_json, chooser) = build_action(schema, chooser)
          use next <- result.try(apply_json(
            definition,
            state,
            player_id,
            action_json,
          ))
          use _ <- result.try(
            check(next)
            |> result.map_error(fn(e) {
              "Invariant failed after "
              <> player_id
              <> " "
              <> action_json
              <> ": "
              <> e
            }),
          )
          loop(
            definition,
            seats,
            next,
            chooser,
            remaining - 1,
            [Step(player_id, action_json), ..steps],
            check,
          )
        }
      }
    }
  }
}

/// Apply an action given as JSON text through the full decode path.
pub fn apply_json(
  definition: Game(state, a),
  state: state,
  player_id: String,
  action_json: String,
) -> Result(state, String) {
  use raw <- result.try(parse(action_json))
  use incoming <- result.try(action.decode_incoming(raw))
  use decoded <- result.try(definition.decode_action(incoming))
  case definition.apply(state, player_id, decoded) {
    Ok(#(next, events)) ->
      case events {
        [] -> Error("Action produced no events: " <> action_json)
        _ -> Ok(next)
      }
    Error(e) ->
      Error(
        "Legal action rejected ("
        <> e
        <> "): "
        <> player_id
        <> " "
        <> action_json,
      )
  }
}

/// Replay a recorded step list from the same seed.
pub fn replay(
  definition: Game(state, a),
  format_id: String,
  seats: List(Seat),
  seed: Int,
  steps: List(Step),
) -> Result(state, String) {
  use format <- result.try(
    game.find_format(definition.info, format_id)
    |> result.replace_error("Unknown format"),
  )
  use initial <- result.try(definition.init(
    format.config,
    seats,
    rng.seed(seed),
  ))
  list.try_fold(steps, initial, fn(state, step) {
    apply_json(definition, state, step.player_id, step.action_json)
  })
}

/// Scene JSON for every viewer, joined, for comparing two states.
pub fn fingerprint(
  definition: Game(state, a),
  state: state,
  seats: List(Seat),
) -> String {
  seats
  |> list.map(fn(seat) {
    json.to_string(
      scene.to_json(definition.scene(state, scene.Player(seat.id))),
    )
  })
  |> string.join("\n")
}

pub fn parse(text: String) -> Result(Dynamic, String) {
  json.parse(text, decode.dynamic)
  |> result.replace_error("Invalid JSON: " <> text)
}

/// Build a random complete action from a schema.
pub fn build_action(schema: Schema, chooser: Rng) -> #(String, Rng) {
  let #(params, chooser) =
    list.fold(schema.params, #([], chooser), fn(acc, param) {
      let #(fields, chooser) = acc
      let #(value, chooser) = build_param(param, chooser)
      #(list.append(fields, [#(param.name, value)]), chooser)
    })
  let text =
    json.to_string(
      json.object([
        #("name", json.string(schema.name)),
        #("params", json.object(params)),
      ]),
    )
  #(text, chooser)
}

fn build_param(param: action.Param, chooser: Rng) -> #(Json, Rng) {
  case param.kind {
    action.Select(_, candidates, min, max) -> {
      let max = int.min(max, list.length(candidates))
      let #(extra, chooser) = rng.int(chooser, max - min + 1)
      let count = int.clamp(min + extra, min, max)
      let #(chosen, chooser) = rng.sample(chooser, candidates, count)
      #(json.array(chosen, json.string), chooser)
    }
    action.Choice(options) ->
      case rng.pick(chooser, options) {
        Ok(#(option, chooser)) -> #(json.string(option.0), chooser)
        Error(_) -> #(json.null(), chooser)
      }
    action.Number(min, max) -> {
      let #(extra, chooser) = rng.int(chooser, max - min + 1)
      #(json.int(min + extra), chooser)
    }
  }
}

/// First schema with the given name among a player's legal actions.
pub fn schema_named(
  definition: Game(state, a),
  state: state,
  player_id: String,
  name: String,
) -> Result(Schema, Nil) {
  list.find(definition.legal(state, player_id), fn(s) { s.name == name })
}
