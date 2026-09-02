//// Time controls.
////
//// Clocks are pure data driven by a monotonic `now` in milliseconds that the
//// host supplies. A game never reads the time; it only reports which players
//// are on the clock right now (see `Game.clocks`). That makes pausing natural:
//// during a phase where nobody should be charged, the game reports nobody.
////
//// Every game supports every control, and `NoClock` is always available.

import gleam/dict.{type Dict}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type PlayerId =
  String

pub type Control {
  NoClock
  /// A bank of time plus an increment added after each of your moves.
  Fischer(base_ms: Int, increment_ms: Int)
  /// A bank of time; the first `delay_ms` of every move are free.
  Bronstein(base_ms: Int, delay_ms: Int)
  /// A fresh allowance for every move; nothing carries over.
  PerMove(ms: Int)
}

pub type Preset {
  Preset(id: String, name: String, description: String, control: Control)
}

/// Controls offered in the lobby. The first is the default.
pub fn presets() -> List(Preset) {
  [
    Preset("none", "No clock", "Take your time", NoClock),
    Preset("blitz", "Blitz", "3 min + 2 s per move", Fischer(180_000, 2000)),
    Preset("rapid", "Rapid", "10 min + 5 s per move", Fischer(600_000, 5000)),
    Preset(
      "delay",
      "Delay",
      "5 min, first 10 s of each move free",
      Bronstein(300_000, 10_000),
    ),
    Preset("per_move", "Per move", "30 s for every move", PerMove(30_000)),
  ]
}

pub fn preset(id: String) -> Result(Preset, Nil) {
  list.find(presets(), fn(p) { p.id == id })
}

pub fn preset_ids() -> List(String) {
  list.map(presets(), fn(p) { p.id })
}

pub fn control_label(control: Control) -> String {
  case control {
    NoClock -> "No clock"
    Fischer(base, inc) -> minutes(base) <> " + " <> seconds(inc)
    Bronstein(base, delay) ->
      minutes(base) <> ", " <> seconds(delay) <> " delay"
    PerMove(ms) -> seconds(ms) <> " per move"
  }
}

fn minutes(ms: Int) -> String {
  int.to_string(ms / 60_000) <> " min"
}

fn seconds(ms: Int) -> String {
  int.to_string(ms / 1000) <> " s"
}

pub type PlayerClock {
  PlayerClock(
    /// Banked time, settled as of the last stop.
    remaining_ms: Int,
    /// When this clock started running, if it is running.
    running_since: Option(Int),
    /// Free time left on the current move (Bronstein).
    delay_left_ms: Int,
  )
}

pub type Clocks {
  Clocks(
    control: Control,
    order: List(PlayerId),
    players: Dict(PlayerId, PlayerClock),
    timed_out: Option(PlayerId),
  )
}

pub fn new(control: Control, player_ids: List(PlayerId)) -> Clocks {
  let start = case control {
    NoClock -> 0
    Fischer(base, _) -> base
    Bronstein(base, _) -> base
    PerMove(ms) -> ms
  }
  Clocks(
    control: control,
    order: player_ids,
    players: dict.from_list(
      list.map(player_ids, fn(id) {
        #(
          id,
          PlayerClock(
            remaining_ms: start,
            running_since: None,
            delay_left_ms: 0,
          ),
        )
      }),
    ),
    timed_out: None,
  )
}

pub fn enabled(clocks: Clocks) -> Bool {
  clocks.control != NoClock
}

fn get(clocks: Clocks, id: PlayerId) -> PlayerClock {
  case dict.get(clocks.players, id) {
    Ok(c) -> c
    Error(_) -> PlayerClock(0, None, 0)
  }
}

/// Time left for a player as of `now`, accounting for a running clock.
pub fn remaining(clocks: Clocks, id: PlayerId, now: Int) -> Int {
  settle(get(clocks, id), now).remaining_ms
}

pub fn running(clocks: Clocks, id: PlayerId) -> Bool {
  get(clocks, id).running_since != None
}

/// Charge elapsed time to a running clock, leaving it running.
fn settle(clock: PlayerClock, now: Int) -> PlayerClock {
  case clock.running_since {
    None -> clock
    Some(since) -> {
      let elapsed = int.max(0, now - since)
      let free = int.min(elapsed, clock.delay_left_ms)
      let charged = elapsed - free
      PlayerClock(
        remaining_ms: int.max(0, clock.remaining_ms - charged),
        running_since: Some(now),
        delay_left_ms: clock.delay_left_ms - free,
      )
    }
  }
}

/// Make exactly the given players' clocks run from `now`. Clocks that stop
/// are settled; if the stopping player is the `actor` (they just moved) a
/// Fischer increment is credited. Starting clocks receive their delay or
/// per-move allowance.
pub fn set_running(
  clocks: Clocks,
  should_run: List(PlayerId),
  now: Int,
  actor: Option(PlayerId),
) -> Clocks {
  case clocks.control, clocks.timed_out {
    NoClock, _ -> clocks
    _, Some(_) -> clocks
    control, None -> {
      let players =
        dict.map_values(clocks.players, fn(id, clock) {
          let is_running = clock.running_since != None
          let wants = list.contains(should_run, id)
          case is_running, wants {
            True, True -> clock
            False, False -> clock
            True, False -> stop(control, settle(clock, now), actor == Some(id))
            False, True -> start(control, clock, now)
          }
        })
      Clocks(..clocks, players: players)
    }
  }
}

fn stop(control: Control, clock: PlayerClock, moved: Bool) -> PlayerClock {
  let bonus = case control, moved, clock.remaining_ms > 0 {
    Fischer(_, inc), True, True -> inc
    _, _, _ -> 0
  }
  PlayerClock(
    remaining_ms: clock.remaining_ms + bonus,
    running_since: None,
    delay_left_ms: 0,
  )
}

fn start(control: Control, clock: PlayerClock, now: Int) -> PlayerClock {
  case control {
    Bronstein(_, delay) ->
      PlayerClock(..clock, running_since: Some(now), delay_left_ms: delay)
    PerMove(ms) ->
      PlayerClock(remaining_ms: ms, running_since: Some(now), delay_left_ms: 0)
    _ -> PlayerClock(..clock, running_since: Some(now), delay_left_ms: 0)
  }
}

/// Stop every clock (the game ended).
pub fn stop_all(clocks: Clocks, now: Int) -> Clocks {
  set_running(clocks, [], now, None)
}

/// Players whose running clock has reached zero, in seat order.
pub fn expired(clocks: Clocks, now: Int) -> List(PlayerId) {
  case clocks.control, clocks.timed_out {
    NoClock, _ -> []
    _, Some(_) -> []
    _, None ->
      list.filter(clocks.order, fn(id) {
        let clock = get(clocks, id)
        clock.running_since != None && settle(clock, now).remaining_ms <= 0
      })
  }
}

/// Record the first expired player as timed out and stop all clocks.
pub fn expire(clocks: Clocks, now: Int) -> Option(#(PlayerId, Clocks)) {
  case expired(clocks, now) {
    [] -> None
    [loser, ..] -> {
      let stopped = stop_all(clocks, now)
      Some(#(loser, Clocks(..stopped, timed_out: Some(loser))))
    }
  }
}

/// Milliseconds until the earliest running clock reaches zero.
pub fn next_deadline(clocks: Clocks, now: Int) -> Option(Int) {
  case clocks.control, clocks.timed_out {
    NoClock, _ -> None
    _, Some(_) -> None
    _, None ->
      clocks.order
      |> list.filter_map(fn(id) {
        let clock = get(clocks, id)
        case clock.running_since {
          None -> Error(Nil)
          Some(_) -> {
            let settled = settle(clock, now)
            Ok(settled.delay_left_ms + settled.remaining_ms)
          }
        }
      })
      |> list.reduce(int.min)
      |> option.from_result
  }
}

pub fn to_json(clocks: Clocks, now: Int) -> Json {
  json.object([
    #("enabled", json.bool(enabled(clocks))),
    #("control", control_to_json(clocks.control)),
    #("label", json.string(control_label(clocks.control))),
    #(
      "players",
      json.array(clocks.order, fn(id) {
        json.object([
          #("id", json.string(id)),
          #("remaining_ms", json.int(remaining(clocks, id, now))),
          #("running", json.bool(running(clocks, id))),
        ])
      }),
    ),
    #("timed_out", json.nullable(clocks.timed_out, json.string)),
  ])
}

pub fn control_to_json(control: Control) -> Json {
  case control {
    NoClock -> json.object([#("type", json.string("none"))])
    Fischer(base, inc) ->
      json.object([
        #("type", json.string("fischer")),
        #("base_ms", json.int(base)),
        #("increment_ms", json.int(inc)),
      ])
    Bronstein(base, delay) ->
      json.object([
        #("type", json.string("bronstein")),
        #("base_ms", json.int(base)),
        #("delay_ms", json.int(delay)),
      ])
    PerMove(ms) ->
      json.object([#("type", json.string("per_move")), #("ms", json.int(ms))])
  }
}

pub fn preset_to_json(p: Preset) -> Json {
  json.object([
    #("id", json.string(p.id)),
    #("name", json.string(p.name)),
    #("description", json.string(p.description)),
    #("control", control_to_json(p.control)),
  ])
}
