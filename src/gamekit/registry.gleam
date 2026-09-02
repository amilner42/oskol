//// Every game the platform knows about.
////
//// Adding a game means adding one entry here. Nothing else on the server or
//// in the generic client changes.

import gamekit/game.{type Info, type Seat}
import gamekit/instance.{type Instance}
import gleam/list
import tilt/game as tilt

pub type Entry {
  Entry(
    info: Info,
    start: fn(String, List(Seat), Int) -> Result(Instance, String),
  )
}

/// Register a game by its contract record.
pub fn entry(definition: game.Game(state, action)) -> Entry {
  Entry(info: definition.info, start: fn(format_id, seats, seed) {
    instance.start(definition, format_id, seats, seed)
  })
}

/// The registered games, in library display order.
pub fn all() -> List(Entry) {
  [entry(tilt.game())]
}

pub fn find(slug: String) -> Result(Entry, Nil) {
  list.find(all(), fn(e) { e.info.slug == slug })
}

pub fn infos() -> List(Info) {
  list.map(all(), fn(e) { e.info })
}
