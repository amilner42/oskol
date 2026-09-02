//// A running game with its state type erased.
////
//// The host cannot be generic over every game's state type, so a started game
//// is wrapped in closures. Each call returns a fresh `Instance`; the state is
//// never mutated.

import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gamekit/game.{type Game, type Outcome, type Seat}
import gamekit/rng
import gamekit/scene.{type PlayerId, type Scene, type Viewer}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/result

pub opaque type Instance {
  Instance(
    slug: String,
    seats: List(Seat),
    apply: fn(PlayerId, Dynamic) -> Result(#(Instance, List(Event)), String),
    legal: fn(PlayerId) -> List(Schema),
    scene: fn(Viewer) -> Scene,
    outcome: fn() -> Outcome,
  )
}

/// Start a game from a format id, the seated players, and a seed.
pub fn start(
  definition: Game(state, action),
  format_id: String,
  seats: List(Seat),
  seed: Int,
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
  Ok(wrap(definition, seats, state))
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

fn wrap(
  definition: Game(state, action),
  seats: List(Seat),
  state: state,
) -> Instance {
  Instance(
    slug: definition.info.slug,
    seats: seats,
    apply: fn(player_id, raw) {
      use incoming <- result.try(action.decode_incoming(raw))
      use decoded <- result.try(definition.decode_action(incoming))
      use #(next_state, events) <- result.try(definition.apply(
        state,
        player_id,
        decoded,
      ))
      Ok(#(wrap(definition, seats, next_state), events))
    },
    legal: fn(player_id) { definition.legal(state, player_id) },
    scene: fn(viewer) { definition.scene(state, viewer) },
    outcome: fn() { definition.outcome(state) },
  )
}

pub fn slug(instance: Instance) -> String {
  instance.slug
}

pub fn seats(instance: Instance) -> List(Seat) {
  instance.seats
}

pub fn apply(
  instance: Instance,
  player_id: PlayerId,
  raw: Dynamic,
) -> Result(#(Instance, List(Event)), String) {
  instance.apply(player_id, raw)
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
