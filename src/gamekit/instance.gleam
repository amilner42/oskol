//// A running game with its state type erased.
////
//// The host cannot be generic over every game's state type, so a started game
//// is wrapped in closures. Each call returns a fresh `Instance`; nothing is
//// mutated. The instance also owns the clocks: the game says who is on the
//// clock, the host says what time it is, and a player who runs out forfeits.

import gamekit/action.{type Schema}
import gamekit/clock.{type Clocks, type Control}
import gamekit/event.{type Event}
import gamekit/game.{type Game, type Outcome, type Seat}
import gamekit/rng
import gamekit/scene.{type PlayerId, type Scene, type Viewer}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub opaque type Instance {
  Instance(
    slug: String,
    seats: List(Seat),
    clocks: Clocks,
    apply: fn(PlayerId, Dynamic, Int) ->
      Result(#(Instance, List(Event)), String),
    legal: fn(PlayerId) -> List(Schema),
    scene: fn(Viewer) -> Scene,
    outcome: fn() -> Outcome,
    /// Rebuild this instance with different clocks (same game state).
    with_clocks: fn(Clocks) -> Instance,
  )
}

/// Start a game from a format id, the seated players, a seed, a time control
/// and the current time.
pub fn start(
  definition: Game(state, action),
  format_id: String,
  seats: List(Seat),
  seed: Int,
  control: Control,
  now: Int,
) -> Result(Instance, String) {
  use format <- result.try(
    game.find_format(definition.info, format_id)
    |> result.replace_error("Unknown format: " <> format_id),
  )
  let seat_count = list.length(seats)
  use <- require(
    seat_count >= definition.info.min_players
      && seat_count <= definition.info.max_players,
    "Wrong number of players",
  )
  use state <- result.try(definition.init(format.config, seats, rng.seed(seed)))
  let ids = list.map(seats, fn(s) { s.id })
  let clocks =
    clock.new(control, ids)
    |> clock.set_running(running_for(definition, state), now, None)
  Ok(wrap(definition, seats, state, clocks))
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

fn wrap(
  definition: Game(state, action),
  seats: List(Seat),
  state: state,
  clocks: Clocks,
) -> Instance {
  Instance(
    slug: definition.info.slug,
    seats: seats,
    clocks: clocks,
    apply: fn(player_id, raw, now) {
      let current = wrap(definition, seats, state, clocks)
      // A clock that already ran out decides the game before any new action.
      case expire(current, now) {
        Some(timed_out) -> Ok(timed_out)
        None -> {
          use <- require(clocks.timed_out == None, "The game is over")
          use incoming <- result.try(action.decode_incoming(raw))
          use decoded <- result.try(definition.decode_action(incoming))
          use #(next_state, events) <- result.try(definition.apply(
            state,
            player_id,
            decoded,
          ))
          let next_clocks =
            clock.set_running(
              clocks,
              running_for(definition, next_state),
              now,
              Some(player_id),
            )
          Ok(#(wrap(definition, seats, next_state, next_clocks), events))
        }
      }
    },
    legal: fn(player_id) {
      case clocks.timed_out {
        Some(_) -> []
        None -> definition.legal(state, player_id)
      }
    },
    scene: fn(viewer) { definition.scene(state, viewer) },
    outcome: fn() {
      case clocks.timed_out {
        Some(loser) ->
          game.Finished(
            list.filter_map(seats, fn(s) {
              case s.id == loser {
                True -> Error(Nil)
                False -> Ok(s.id)
              }
            }),
          )
        None -> definition.outcome(state)
      }
    },
    with_clocks: fn(new_clocks) { wrap(definition, seats, state, new_clocks) },
  )
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

pub fn finished(instance: Instance) -> Bool {
  case instance.outcome() {
    game.Ongoing -> False
    game.Finished(_) -> True
  }
}

/// If a running clock has reached zero, forfeit that player. Returns the new
/// instance and the events describing it, or None when nothing expired.
pub fn expire(instance: Instance, now: Int) -> Option(#(Instance, List(Event))) {
  case clock.expire(instance.clocks, now) {
    None -> None
    Some(#(loser, clocks)) -> {
      let name =
        list.find(instance.seats, fn(s) { s.id == loser })
        |> result.map(fn(s) { s.name })
        |> result.unwrap(loser)
      let events = [
        event.Custom(
          "timeout",
          json.object([#("player_id", json.string(loser))]),
        ),
        event.Message(name <> " ran out of time"),
        event.PhaseChanged("game_over"),
      ]
      Some(#(instance.with_clocks(clocks), events))
    }
  }
}

/// Milliseconds until a clock would expire, if any is running.
pub fn next_deadline(instance: Instance, now: Int) -> Option(Int) {
  clock.next_deadline(instance.clocks, now)
}
