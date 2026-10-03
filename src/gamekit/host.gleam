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

/// JSON array of the fixed time-control presets (every one still defined,
/// offered or not). A game's own tiers are on its page (`game.tier_to_json`).
pub fn clock_presets_json() -> String {
  clock.presets() |> json.array(clock.preset_to_json) |> json.to_string
}

/// Every clock id a room may carry: the fixed presets and every registered
/// game's tiers.
pub fn clock_ids() -> List(String) {
  list.append(
    clock.preset_ids(),
    list.flat_map(registry.infos(), fn(info) {
      list.map(info.tiers, fn(t) { t.id })
    }),
  )
}

/// Resolve a clock id to a control for one format of a game: a tier is
/// sized to the format, a preset is what it always was. Unknown ids (and a
/// tier asked about a format the game does not have) mean no clock.
pub fn clock_control(
  slug: String,
  format_id: String,
  clock_id: String,
) -> Control {
  case clock_for(slug, format_id, clock_id) {
    Ok(c) -> c.control
    Error(_) -> clock.NoClock
  }
}

/// A clock in words for one format, as a room's setup line names it: a
/// tier and what it is worth ("Standard clock · 14 min each", "Standard
/// clock · 5 min each per game"), a preset by name ("5 min clock"), or ""
/// for no clock and for an id nobody knows.
pub fn clock_line(slug: String, format_id: String, clock_id: String) -> String {
  case clock_for(slug, format_id, clock_id) {
    Ok(c) ->
      case c.control, c.tier {
        clock.NoClock, _ -> ""
        _, True -> c.name <> " clock · " <> c.each
        _, False -> c.name <> " clock"
      }
    Error(_) -> ""
  }
}

/// A clock id resolved for one format of a game (`game.clock_for`). Error
/// for a game nobody registered, an id nobody knows, and a tier asked about
/// a format the game does not have.
pub fn clock_for(
  slug: String,
  format_id: String,
  clock_id: String,
) -> Result(game.Clock, Nil) {
  use entry <- result.try(registry.find(slug))
  game.clock_for(entry.info, format_id, clock_id)
}

// ---------- Lifecycle ----------

/// Start a game. `seats` are `#(player_id, display_name)` pairs.
pub fn start(
  slug: String,
  format_id: String,
  seats: List(#(String, String)),
  seed: Int,
  control: Control,
  now: Int,
) -> Result(Instance, String) {
  use entry <- result.try(find(slug))
  let seats = list.map(seats, fn(s) { game.Seat(id: s.0, name: s.1) })
  entry.start(format_id, seats, seed, control, now)
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

/// What the step that produced this instance committed, as the game's own
/// JSON (`Game.committed`). `Error(Nil)` when it committed nothing, which
/// is every step of a game that has no such unit of play.
///
/// The value belongs to the instance and not to a moment, so reading it
/// twice reads the same step twice: a caller acting on it must act once,
/// on the instance a step just returned.
pub fn committed_json(instance: Instance) -> Result(String, Nil) {
  case instance.committed(instance) {
    Some(payload) -> Ok(json.to_string(payload))
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

// ---------- Bots ----------

/// Whose turn it is, by the game's own account (`summary_json`'s `to_act`).
/// What the platform asks before it wakes a bot seat.
pub fn to_act(instance: Instance) -> List(String) {
  instance.to_act(instance)
}

/// What a bot seat does now: a JSON array in the order the actions are to be
/// applied, each `{"action": {"name", "params"}, "pace": "step" | "beat" |
/// "settle"}` -- the object a browser sends, and the moment it is for a
/// watcher (`game.Pace`), which the platform turns into milliseconds.
///
/// `ask` is the analysis engine, and it is called from wherever this runs --
/// never inside a room, because an answer can take seconds. `attempts` is
/// how many asks have already come back empty for this decision; what to do
/// once that is too many is the game's call, not the platform's.
pub fn think(
  instance: Instance,
  player_id: String,
  ask: game.Ask,
  attempts: Int,
) -> Result(String, String) {
  instance.bot(instance, player_id, ask, attempts)
  |> result.map(fn(actions) {
    json.to_string(
      json.array(actions, fn(decided: game.BotAction) {
        json.object([
          #("action", decided.action),
          #("pace", json.string(game.pace_name(decided.pace))),
        ])
      }),
    )
  })
}

/// A small public snapshot of where the game stands, for the platform to
/// write down beside the row after every step: whose turn it is, whose
/// clock is running, whether it is over, and each player's public counters
/// and flags (the spectator's projection, which carries nothing hidden by
/// construction). No board, no tokens: enough to list and watch active
/// games from the database without waking a room, not enough to replay
/// one. Game-agnostic: a game that wants more in it adds counters to its
/// scene.
///
/// `to_act` is the game's own answer to whose turn it is: the players it
/// says should be charged right now (`Game.clocks`), whether or not a
/// clock is set, or whoever has something to do when it charges nobody (a
/// READY between games). Not "who has a legal action": in backgammon the
/// waiting player may always resign, and that is not their turn.
///
/// `clocks` is each seat's time as of `now`: what is left, the free time
/// still on this move, and whether it is running. Null under no clock. A
/// row's copy is exact while the room is cold (a paused clock does not
/// move) and as of the last step while it is live.
pub fn summary_json(instance: Instance, now: Int) -> String {
  let seats = instance.seats(instance)
  let clocks = instance.clocks(instance)
  let viewed = instance.scene(instance, scene.Spectator)

  json.object([
    #("to_act", json.array(instance.to_act(instance), json.string)),
    #(
      "on_clock",
      json.array(
        list.filter(seats, fn(seat) { clock.running(clocks, seat.id) }),
        fn(seat) { json.string(seat.id) },
      ),
    ),
    #("outcome", game.outcome_to_json(instance.outcome(instance))),
    #("phase", json.string(viewed.phase)),
    #("players", json.array(viewed.players, scene.player_to_json)),
    #("clocks", case clock.enabled(clocks) {
      False -> json.null()
      True ->
        json.array(seats, fn(seat) {
          json.object([
            #("id", json.string(seat.id)),
            #("remaining_ms", json.int(clock.remaining(clocks, seat.id, now))),
            #("move_ms", json.int(clock.move_left(clocks, seat.id, now))),
            #("running", json.bool(clock.running(clocks, seat.id))),
          ])
        })
    }),
  ])
  |> json.to_string
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

/// The actions this player may take now and nothing else: the same shapes
/// an update carries under "legal", without the scene, the events and the
/// clock beside them. For tooling that walks a game step by step -- the
/// bots the suite plays whole matches with -- where building two whole
/// updates a step was most of the cost of a playout.
pub fn legal_json(instance: Instance, player_id: String) -> String {
  instance.legal(instance, player_id)
  |> json.array(action.to_json)
  |> json.to_string
}

/// The names of the actions this player may take now, without building a
/// whole update: for platform tooling that walks a log step by step.
pub fn legal_names(instance: Instance, player_id: String) -> List(String) {
  instance.legal(instance, player_id) |> list.map(fn(schema) { schema.name })
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
