//// The surface Elixir calls.
////
//// Everything here speaks in opaque `Instance` values, JSON strings, and
//// plain integers, so the Elixir host never sees a game-specific type. This
//// is the only bridge between the platform and the games, and it does not
//// grow when a game is added.
////
//// `now` is a monotonic time in milliseconds supplied by the host.

import gamekit/action
import gamekit/clock.{type Control}
import gamekit/event.{type Event}
import gamekit/game.{type Outcome, type Seat}
import gamekit/instance.{type Instance}
import gamekit/registry
import gamekit/scene
import gamekit/text
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

/// JSON array of every registered game's info, for the library page.
pub fn games_json() -> String {
  registry.infos()
  |> json.array(game.info_to_json)
  |> json.to_string
}

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

// ---------- Clocks ----------

/// JSON array of the time-control presets offered in the lobby.
pub fn clock_presets_json() -> String {
  clock.presets() |> json.array(clock.preset_to_json) |> json.to_string
}

pub fn clock_ids() -> List(String) {
  clock.preset_ids()
}

/// Resolve a preset id to a control (unknown ids mean no clock).
pub fn clock_control(preset_id: String) -> Control {
  case clock.preset(preset_id) {
    Ok(p) -> p.control
    Error(_) -> clock.NoClock
  }
}

// ---------- Lifecycle ----------

/// Start a game. `selections` are `#(setting_id, choice_id)` pairs the
/// creator picked for the format; `seats` are `#(player_id, display_name)`.
pub fn start(
  slug: String,
  format_id: String,
  selections: List(#(String, String)),
  seats: List(#(String, String)),
  seed: Int,
  control: Control,
  now: Int,
) -> Result(Instance, String) {
  use entry <- result.try(find(slug))
  let seats = list.map(seats, fn(s) { game.Seat(id: s.0, name: s.1) })
  entry.start(format_id, selections, seats, seed, control, now)
}

/// Apply a raw action (an Elixir map decoded from the client JSON).
pub fn apply(
  instance: Instance,
  player_id: String,
  raw: Dynamic,
  now: Int,
) -> Result(#(Instance, List(Event)), String) {
  instance.apply(instance, player_id, raw, now)
}

/// Forfeit a player whose clock ran out, if any. `Error(Nil)` means nothing
/// expired.
pub fn expire(
  instance: Instance,
  now: Int,
) -> Result(#(Instance, List(Event)), Nil) {
  case instance.expire(instance, now) {
    Some(result) -> Ok(result)
    None -> Error(Nil)
  }
}

/// Milliseconds until the next possible clock expiry, if a clock is running.
pub fn next_deadline(instance: Instance, now: Int) -> Result(Int, Nil) {
  case instance.next_deadline(instance, now) {
    Some(ms) -> Ok(ms)
    None -> Error(Nil)
  }
}

/// A seeded random playout as a JSON fixture (see gamekit/fixture).
pub fn fixture_json(
  slug: String,
  format_id: String,
  seats: List(#(String, String)),
  seed: Int,
  max_steps: Int,
) -> Result(String, String) {
  use entry <- result.try(find(slug))
  let seats = list.map(seats, fn(s) { game.Seat(id: s.0, name: s.1) })
  entry.fixture(format_id, seats, seed, max_steps)
}

/// A compact replay fixture (action log plus fingerprint).
pub fn replay_json(
  slug: String,
  format_id: String,
  seats: List(#(String, String)),
  seed: Int,
  max_steps: Int,
) -> Result(String, String) {
  use entry <- result.try(find(slug))
  let seats = list.map(seats, fn(s) { game.Seat(id: s.0, name: s.1) })
  entry.replay(format_id, seats, seed, max_steps)
}

// ---------- Updates ----------

/// The full update payload for one player: scene, legal actions, outcome,
/// clocks and the events that led here. Sent after every change and on join.
pub fn player_update_json(
  instance: Instance,
  player_id: String,
  events: List(Event),
  now: Int,
) -> String {
  update_json(
    instance,
    scene.Player(player_id),
    instance.legal(instance, player_id),
    events,
    now,
  )
}

pub fn spectator_update_json(
  instance: Instance,
  events: List(Event),
  now: Int,
) -> String {
  update_json(instance, scene.Spectator, [], events, now)
}

fn update_json(
  instance: Instance,
  viewer: scene.Viewer,
  legal: List(action.Schema),
  events: List(Event),
  now: Int,
) -> String {
  let viewed = instance.scene(instance, viewer)
  json.object([
    #("scene", scene.to_json(viewed)),
    #("legal", json.array(legal, action.to_json)),
    #("outcome", game.outcome_to_json(instance.outcome(instance))),
    #("events", json.array(event.for_viewer(events, viewed), event.to_json)),
    #("clock", clock.to_json(instance.clocks(instance), now)),
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
