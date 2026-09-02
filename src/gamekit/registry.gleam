//// Every game the platform knows about.
////
//// Adding a game means adding one entry here. Nothing else on the server or
//// in the generic client changes.

import backgammon/game as backgammon
import gamekit/clock.{type Control}
import gamekit/fixture
import gamekit/game.{type Info, type Seat}
import gamekit/instance.{type Instance}
import gleam/list
import tilt/game as tilt

pub type Entry {
  Entry(
    info: Info,
    start: fn(String, List(Seat), Int, Control, Int) -> Result(Instance, String),
    /// A seeded random playout rendered as a JSON fixture (see gamekit/fixture).
    fixture: fn(String, List(Seat), Int, Int) -> Result(String, String),
    /// A compact replay of a seeded random playout (see gamekit/fixture).
    replay: fn(String, List(Seat), Int, Int) -> Result(String, String),
  )
}

/// Register a game by its contract record.
pub fn entry(definition: game.Game(state, action)) -> Entry {
  Entry(
    info: definition.info,
    start: fn(format_id, seats, seed, control, now) {
      instance.start(definition, format_id, seats, seed, control, now)
    },
    fixture: fn(format_id, seats, seed, max_steps) {
      fixture.playout_json(definition, format_id, seats, seed, max_steps)
    },
    replay: fn(format_id, seats, seed, max_steps) {
      fixture.replay_json(definition, format_id, seats, seed, max_steps)
    },
  )
}

/// The registered games, in library display order.
pub fn all() -> List(Entry) {
  [entry(tilt.game()), entry(backgammon.game())]
}

pub fn find(slug: String) -> Result(Entry, Nil) {
  list.find(all(), fn(e) { e.info.slug == slug })
}

pub fn infos() -> List(Info) {
  list.map(all(), fn(e) { e.info })
}
