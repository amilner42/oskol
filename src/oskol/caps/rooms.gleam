//// Room IO capabilities. Built for real in lib/oskol/gleam/caps/rooms.ex —
//// that file and this one must agree on constructor tag and field order.

import gleam/option.{type Option}
import oskol/rooms/errors.{type RoomError}
import oskol/rooms/room.{type Room, type Seat, type Setup, type Table}

pub type SpawnError {
  /// The registry already holds a live room under that code.
  AlreadyStarted
  SpawnFailed(reason: RoomError)
}

pub type RoomsCaps {
  RoomsCaps(
    /// The live room process for a code, if one answers right now.
    find: fn(String) -> Option(Room),
    /// Rebuild a room from its persisted seed and action log.
    resume: fn(String) -> Option(Room),
    /// The table as an invite link finds it. `None` when the room went away
    /// between the lookup and the read.
    table: fn(String) -> Option(Table),
    /// The game slug a live room is playing.
    slug_of: fn(String) -> Option(String),
    /// Start a room for (game_id, slug).
    spawn: fn(String, String) -> Result(Nil, SpawnError),
    /// Follow a room's broadcasts from the calling process.
    subscribe: fn(String) -> Nil,
    /// Set a room up before it starts.
    configure: fn(String, Setup) -> Result(Nil, RoomError),
    /// Take a free seat: (game_id, display name, guest id).
    join: fn(String, String, Option(String)) -> Result(Seat, RoomError),
    /// Take back a seat whose player is away: (game_id, player_id). The
    /// seat's token is rotated first, so a link that leaked earlier cannot
    /// shadow the seat later.
    claim: fn(String, String) -> Result(Seat, RoomError),
  )
}

pub fn stub() -> RoomsCaps {
  RoomsCaps(
    find: fn(_) { panic as "stub rooms.find" },
    resume: fn(_) { panic as "stub rooms.resume" },
    table: fn(_) { panic as "stub rooms.table" },
    slug_of: fn(_) { panic as "stub rooms.slug_of" },
    spawn: fn(_, _) { panic as "stub rooms.spawn" },
    subscribe: fn(_) { panic as "stub rooms.subscribe" },
    configure: fn(_, _) { panic as "stub rooms.configure" },
    join: fn(_, _, _) { panic as "stub rooms.join" },
    claim: fn(_, _) { panic as "stub rooms.claim" },
  )
}
