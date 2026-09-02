//// The surface Elixir calls.
////
//// Everything here speaks in opaque `Instance` values and JSON strings, so
//// the Elixir host never sees a game-specific type. This is the only bridge
//// between the platform and the games, and it does not grow when a game is
//// added.

import gamekit/action
import gamekit/event.{type Event}
import gamekit/game.{type Outcome, type Seat}
import gamekit/instance.{type Instance}
import gamekit/registry
import gamekit/scene
import gamekit/text
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/result

/// JSON array of every registered game's info, for the library page.
pub fn games_json() -> String {
  registry.infos()
  |> json.array(game.info_to_json)
  |> json.to_string
}

/// JSON for one game's info.
pub fn game_info_json(slug: String) -> Result(String, String) {
  use entry <- result.try(find(slug))
  Ok(json.to_string(game.info_to_json(entry.info)))
}

pub fn game_exists(slug: String) -> Bool {
  case registry.find(slug) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Format ids offered by a game, in order.
pub fn format_ids(slug: String) -> List(String) {
  case registry.find(slug) {
    Ok(entry) -> list.map(entry.info.formats, fn(f) { f.id })
    Error(_) -> []
  }
}

pub fn player_limits(slug: String) -> Result(#(Int, Int), String) {
  use entry <- result.try(find(slug))
  Ok(#(entry.info.min_players, entry.info.max_players))
}

/// Start a game. `seats` are `#(player_id, display_name)` pairs.
pub fn start(
  slug: String,
  format_id: String,
  seats: List(#(String, String)),
  seed: Int,
) -> Result(Instance, String) {
  use entry <- result.try(find(slug))
  let seats = list.map(seats, fn(s) { game.Seat(id: s.0, name: s.1) })
  entry.start(format_id, seats, seed)
}

/// Apply a raw action (an Elixir map decoded from the client JSON).
pub fn apply(
  instance: Instance,
  player_id: String,
  raw: Dynamic,
) -> Result(#(Instance, List(Event)), String) {
  instance.apply(instance, player_id, raw)
}

/// The full update payload for one player: scene, legal actions, outcome and
/// the events that led here. Sent after every state change and on join.
pub fn player_update_json(
  instance: Instance,
  player_id: String,
  events: List(Event),
) -> String {
  update_json(
    instance,
    scene.Player(player_id),
    instance.legal(instance, player_id),
    events,
  )
}

pub fn spectator_update_json(instance: Instance, events: List(Event)) -> String {
  update_json(instance, scene.Spectator, [], events)
}

fn update_json(
  instance: Instance,
  viewer: scene.Viewer,
  legal: List(action.Schema),
  events: List(Event),
) -> String {
  json.object([
    #("scene", scene.to_json(instance.scene(instance, viewer))),
    #("legal", json.array(legal, action.to_json)),
    #("outcome", game.outcome_to_json(instance.outcome(instance))),
    #("events", json.array(events, event.to_json)),
  ])
  |> json.to_string
}

pub fn outcome(instance: Instance) -> Outcome {
  instance.outcome(instance)
}

pub fn finished(instance: Instance) -> Bool {
  instance.finished(instance)
}

pub fn slug(instance: Instance) -> String {
  instance.slug(instance)
}

pub fn seats(instance: Instance) -> List(Seat) {
  instance.seats(instance)
}

/// Text rendering for logs, agents and tests.
pub fn text(instance: Instance, player_id: String) -> String {
  text.render_with_actions(
    instance.scene(instance, scene.Player(player_id)),
    instance.legal(instance, player_id),
  )
}

fn find(slug: String) -> Result(registry.Entry, String) {
  registry.find(slug) |> result.replace_error("Unknown game: " <> slug)
}
