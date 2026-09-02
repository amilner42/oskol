//// Fixture corpus: a seeded random playout with every payload the clients
//// would have received, rendered as JSON.
////
//// The same file serves two suites. Gleam golden tests replay the steps and
//// compare the final fingerprint; Elm tests decode every payload so a change
//// to the wire shape fails before a browser is opened.

import gamekit/action
import gamekit/clock
import gamekit/conformance
import gamekit/event
import gamekit/game.{type Game, type Seat}
import gamekit/rng
import gamekit/scene
import gleam/json.{type Json}
import gleam/list
import gleam/result

/// Actions random play never picks when building fixtures: conceding early
/// would make every fixture trivially short.
pub const excluded = ["resign"]

/// A compact replay: the action log and the final fingerprint. Small enough
/// to commit for every format and seed; Gleam golden tests replay it.
pub fn replay_json(
  definition: Game(state, a),
  format_id: String,
  seats: List(Seat),
  seed: Int,
  max_steps: Int,
) -> Result(String, String) {
  use report <- result.try(conformance.random_playout_with(
    definition,
    format_id,
    seats,
    seed,
    max_steps,
    fn(_) { Ok(Nil) },
    conformance.Options(exclude: excluded),
  ))
  Ok(
    json.to_string(
      json.object([
        #("game", json.string(definition.info.slug)),
        #("format", json.string(format_id)),
        #("seed", json.int(seed)),
        #("seats", seats_json(seats)),
        #("finished", json.bool(report.finished)),
        #(
          "steps",
          json.array(report.steps, fn(step) {
            json.object([
              #("player_id", json.string(step.player_id)),
              #("action", json.string(step.action_json)),
            ])
          }),
        ),
        #(
          "fingerprint",
          json.string(conformance.fingerprint(definition, report.state, seats)),
        ),
      ]),
    ),
  )
}

fn seats_json(seats: List(Seat)) -> Json {
  json.array(seats, fn(s) {
    json.object([#("id", json.string(s.id)), #("name", json.string(s.name))])
  })
}

/// A payload capture: the first `capture_steps` steps of a playout with the
/// update every viewer would have received. Elm contract tests decode these.
pub fn playout_json(
  definition: Game(state, a),
  format_id: String,
  seats: List(Seat),
  seed: Int,
  capture_steps: Int,
) -> Result(String, String) {
  use report <- result.try(conformance.random_playout_with(
    definition,
    format_id,
    seats,
    seed,
    capture_steps,
    fn(_) { Ok(Nil) },
    conformance.Options(exclude: excluded),
  ))
  use format <- result.try(
    game.find_format(definition.info, format_id)
    |> result.replace_error("Unknown format"),
  )
  use initial <- result.try(definition.init(
    format.config,
    seats,
    rng.seed(seed),
  ))
  // Walk the steps again, capturing what every viewer would receive
  use #(_, captured) <- result.try(
    list.try_fold(report.steps, #(initial, []), fn(acc, step) {
      let #(state, out) = acc
      use raw <- result.try(conformance.parse(step.action_json))
      use incoming <- result.try(action.decode_incoming(raw))
      use decoded <- result.try(definition.decode_action(incoming))
      use #(next, events) <- result.try(definition.apply(
        state,
        step.player_id,
        decoded,
      ))
      let entry =
        json.object([
          #("player_id", json.string(step.player_id)),
          #("action", json.string(step.action_json)),
          #("updates", updates(definition, next, seats, events)),
        ])
      Ok(#(next, [entry, ..out]))
    }),
  )
  Ok(
    json.to_string(
      json.object([
        #("game", json.string(definition.info.slug)),
        #("format", json.string(format_id)),
        #("seed", json.int(seed)),
        #("seats", seats_json(seats)),
        #("finished", json.bool(report.finished)),
        #("initial", updates(definition, initial, seats, [])),
        #("steps", json.preprocessed_array(list.reverse(captured))),
        #(
          "fingerprint",
          json.string(conformance.fingerprint(definition, report.state, seats)),
        ),
      ]),
    ),
  )
}

/// The update each viewer sees after a step: seats by id plus a spectator.
fn updates(
  definition: Game(state, a),
  state: state,
  seats: List(Seat),
  events: List(event.Event),
) -> Json {
  // Same shape as gamekit/host.player_update_json, with an idle clock
  let clocks = clock.new(clock.NoClock, list.map(seats, fn(s) { s.id }))
  let viewers =
    list.map(seats, fn(s) { #(s.id, scene.Player(s.id)) })
    |> list.append([#("spectator", scene.Spectator)])
  json.object(
    list.map(viewers, fn(v) {
      let legal = case v.1 {
        scene.Player(id) -> definition.legal(state, id)
        scene.Spectator -> []
      }
      let viewed = definition.scene(state, v.1)
      #(
        v.0,
        json.object([
          #("scene", scene.to_json(viewed)),
          #("legal", json.array(legal, action.to_json)),
          #("outcome", game.outcome_to_json(definition.outcome(state))),
          #(
            "events",
            json.array(event.for_viewer(events, viewed), event.to_json),
          ),
          #("clock", clock.to_json(clocks, 0)),
        ]),
      )
    }),
  )
}
