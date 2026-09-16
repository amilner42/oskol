//// A running game, typed and erased.
////
//// `Running(state, action)` is a started game with its state type intact:
//// the definition, the seats, the state and the clocks. The host cannot be
//// generic over every game's state type, so what it holds is an `Instance`:
//// the same running game wrapped in closures (`erase`). Both go through the
//// one set of step functions below, so a typed replay (a post-game review,
//// say) sees exactly what the room saw. Nothing is mutated; every call
//// returns a fresh value. The clocks live here too: the game says who is on
//// the clock, the host says what time it is, and a player who runs out
//// forfeits (or the game acts for them).

import gamekit/action.{type Schema}
import gamekit/clock.{type Clocks, type Control}
import gamekit/event.{type Event}
import gamekit/game.{type Game, type Outcome, type Seat}
import gamekit/rng
import gamekit/scene.{type PlayerId, type Scene, type Viewer}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A started game with its state type intact.
pub opaque type Running(state, action) {
  Running(
    definition: Game(state, action),
    seats: List(Seat),
    state: state,
    clocks: Clocks,
  )
}

/// A started game with its state type erased: what the host holds.
pub opaque type Instance {
  Instance(
    slug: String,
    seats: List(Seat),
    clocks: Clocks,
    apply: fn(PlayerId, Dynamic, Int) ->
      Result(#(Instance, List(Event)), String),
    expire: fn(Int) -> Option(#(Instance, List(Event))),
    legal: fn(PlayerId) -> List(Schema),
    scene: fn(Viewer) -> Scene,
    outcome: fn() -> Outcome,
    /// The game's public record, if it keeps one (`Game.record`).
    record: fn() -> Option(json.Json),
  )
}

// ---------- Typed ----------

/// Start a game from a format id, the creator's setting selections, the
/// seated players, a seed, a time control and the current time.
pub fn begin(
  definition: Game(state, action),
  format_id: String,
  selections: List(#(String, String)),
  seats: List(Seat),
  seed: Int,
  control: Control,
  now: Int,
) -> Result(Running(state, action), String) {
  use format <- result.try(
    game.find_format(definition.info, format_id)
    |> result.replace_error("Unknown format: " <> format_id),
  )
  use config <- result.try(game.configure(format, dict.from_list(selections)))
  let seat_count = list.length(seats)
  use <- require(
    seat_count >= definition.info.min_players
      && seat_count <= definition.info.max_players,
    "Wrong number of players",
  )
  use state <- result.try(definition.init(config, seats, rng.seed(seed)))
  let ids = list.map(seats, fn(s) { s.id })
  let clocks =
    clock.new(control, ids)
    |> clock.with_turn_delay(definition.info.turn_delay_ms)
    |> clock.set_running(running_for(definition, state), now, None)
  Ok(Running(definition, seats, state, clocks))
}

/// Apply a raw action for a player at `now`.
///
/// A clock that already ran out decides before any new action. The action
/// is then still tried on what that left (an opponent's resign, say); one
/// the timeout made stale is dropped, but never lost silently along with
/// the timeout itself.
pub fn step(
  running: Running(state, action),
  player_id: PlayerId,
  raw: Dynamic,
  now: Int,
) -> Result(#(Running(state, action), List(Event)), String) {
  step_taken(running, player_id, raw, now)
  |> result.map(fn(stepped) { #(stepped.0, stepped.1) })
}

/// `step`, also saying whether the action itself was applied: `Some` with
/// the decoded action when it was, `None` when a clock that ran out was
/// resolved instead and left the action stale.
pub fn step_taken(
  running: Running(state, action),
  player_id: PlayerId,
  raw: Dynamic,
  now: Int,
) -> Result(#(Running(state, action), List(Event), Option(action)), String) {
  case step_expire(running, now) {
    Some(#(timed_out, timeout_events)) ->
      case timed_out.clocks.timed_out {
        None ->
          case step_taken(timed_out, player_id, raw, now) {
            Ok(#(after, more, taken)) ->
              Ok(#(after, list.append(timeout_events, more), taken))
            Error(_) -> Ok(#(timed_out, timeout_events, None))
          }
        Some(_) -> Ok(#(timed_out, timeout_events, None))
      }
    None -> {
      let definition = running.definition
      use <- require(running.clocks.timed_out == None, "The game is over")
      use incoming <- result.try(action.decode_incoming(raw))
      use decoded <- result.try(definition.decode_action(incoming))
      use #(next_state, events) <- result.try(definition.apply(
        running.state,
        player_id,
        decoded,
      ))
      let next_clocks =
        clock.set_running(
          running.clocks,
          running_for(definition, next_state),
          now,
          Some(player_id),
        )
      Ok(#(
        Running(..running, state: next_state, clocks: next_clocks),
        events,
        Some(decoded),
      ))
    }
  }
}

/// If a running clock has reached zero, resolve it the way the game wants:
/// a forfeit, or an action taken for the player. Returns the new game and
/// the events describing it, or None when nothing expired.
pub fn step_expire(
  running: Running(state, action),
  now: Int,
) -> Option(#(Running(state, action), List(Event))) {
  case clock.expired(running.clocks, now) {
    [] -> None
    [loser, ..] -> {
      let name =
        list.find(running.seats, fn(s) { s.id == loser })
        |> result.map(fn(s) { s.name })
        |> result.unwrap(loser)
      let #(next, game_events) = on_timeout(running, loser, now)
      let forfeited = next.clocks.timed_out != None
      let events =
        list.flatten([
          [
            event.Custom(
              "timeout",
              json.object([
                #("player_id", json.string(loser)),
                #("forfeit", json.bool(forfeited)),
              ]),
            ),
            event.Message(name <> " ran out of time"),
          ],
          game_events,
          case forfeited {
            True -> [event.PhaseChanged("game_over")]
            False -> []
          },
        ])
      Some(#(next, events))
    }
  }
}

/// Resolve a player's clock running out: forfeit, or the game's own auto
/// action with the events it produced.
fn on_timeout(
  running: Running(state, action),
  loser: PlayerId,
  now: Int,
) -> #(Running(state, action), List(Event)) {
  let definition = running.definition
  let forfeit = fn() {
    let assert Some(#(_, stopped)) = clock.expire(running.clocks, now)
    #(Running(..running, clocks: stopped), [])
  }
  case definition.timeout(running.state, loser) {
    game.Forfeit -> forfeit()
    game.Act(auto_action) ->
      // The game acts for the player and play goes on; their clock is
      // settled (bank spent) and restarted if it is still their turn.
      case definition.apply(running.state, loser, auto_action) {
        Ok(#(next_state, events)) -> {
          let next_clocks =
            clock.set_running(
              running.clocks,
              running_for(definition, next_state),
              now,
              Some(loser),
            )
          #(Running(..running, state: next_state, clocks: next_clocks), events)
        }
        // The game had no action for them: fall back to a forfeit
        Error(_) -> forfeit()
      }
  }
}

/// The game's own state.
pub fn running_state(running: Running(state, action)) -> state {
  running.state
}

pub fn running_clocks(running: Running(state, action)) -> Clocks {
  running.clocks
}

/// The outcome, a clock that ran out included.
pub fn running_outcome(running: Running(state, action)) -> Outcome {
  case running.clocks.timed_out {
    Some(loser) ->
      game.Finished(
        list.filter_map(running.seats, fn(s) {
          case s.id == loser {
            True -> Error(Nil)
            False -> Ok(s.id)
          }
        }),
      )
    None -> running.definition.outcome(running.state)
  }
}

/// Hide the state type: the value the host holds.
pub fn erase(running: Running(state, action)) -> Instance {
  Instance(
    slug: running.definition.info.slug,
    seats: running.seats,
    clocks: running.clocks,
    apply: fn(player_id, raw, now) {
      step(running, player_id, raw, now)
      |> result.map(fn(stepped) { #(erase(stepped.0), stepped.1) })
    },
    expire: fn(now) {
      step_expire(running, now)
      |> option.map(fn(stepped) { #(erase(stepped.0), stepped.1) })
    },
    legal: fn(player_id) {
      case running.clocks.timed_out {
        Some(_) -> []
        None -> running.definition.legal(running.state, player_id)
      }
    },
    scene: fn(viewer) { running.definition.scene(running.state, viewer) },
    outcome: fn() { running_outcome(running) },
    record: fn() { running.definition.record(running.state) },
  )
}

fn require(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

fn running_for(definition: Game(state, action), state: state) -> List(PlayerId) {
  case definition.outcome(state) {
    game.Finished(_) -> []
    game.Ongoing -> definition.clocks(state)
  }
}

// ---------- Erased ----------

/// Start a game and erase it: `begin`, for the host.
pub fn start(
  definition: Game(state, action),
  format_id: String,
  selections: List(#(String, String)),
  seats: List(Seat),
  seed: Int,
  control: Control,
  now: Int,
) -> Result(Instance, String) {
  begin(definition, format_id, selections, seats, seed, control, now)
  |> result.map(erase)
}

pub fn slug(instance: Instance) -> String {
  instance.slug
}

pub fn seats(instance: Instance) -> List(Seat) {
  instance.seats
}

pub fn clocks(instance: Instance) -> Clocks {
  instance.clocks
}

pub fn apply(
  instance: Instance,
  player_id: PlayerId,
  raw: Dynamic,
  now: Int,
) -> Result(#(Instance, List(Event)), String) {
  instance.apply(player_id, raw, now)
}

pub fn legal(instance: Instance, player_id: PlayerId) -> List(Schema) {
  instance.legal(player_id)
}

pub fn scene(instance: Instance, viewer: Viewer) -> Scene {
  instance.scene(viewer)
}

pub fn outcome(instance: Instance) -> Outcome {
  instance.outcome()
}

/// The game's public record, if it keeps one: every seat may read it.
pub fn record(instance: Instance) -> Option(json.Json) {
  instance.record()
}

pub fn finished(instance: Instance) -> Bool {
  case instance.outcome() {
    game.Ongoing -> False
    game.Finished(_) -> True
  }
}

/// If a running clock has reached zero, resolve it the way the game wants:
/// a forfeit, or an action taken for the player. Returns the new instance
/// and the events describing it, or None when nothing expired.
pub fn expire(instance: Instance, now: Int) -> Option(#(Instance, List(Event))) {
  instance.expire(now)
}

/// Milliseconds until a clock would expire, if any is running.
pub fn next_deadline(instance: Instance, now: Int) -> Option(Int) {
  clock.next_deadline(instance.clocks, now)
}
