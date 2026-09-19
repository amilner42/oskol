//// Room IO capabilities. Built for real in lib/oskol/gleam/caps/rooms.ex —
//// that file and this one must agree on constructor tag and field order.

import gamekit/instance.{type Instance}
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
    /// Take a free seat: (game_id, display name, guest id, user id). The
    /// guest is what holds the seat afterwards -- unless the browser is
    /// signed in, in which case the seat is the account's from the start.
    join: fn(String, String, Option(String), Option(String)) ->
      Result(Seat, RoomError),
    /// Take back a seat whose player is away: (game_id, player_id, guest
    /// id, user id). The seat passes to that browser, so whoever held it
    /// before no longer does, and to their account if they have one. A seat
    /// whose player is connected is `SeatConnected`; one an account owns is
    /// `SeatOwned`, whoever asks.
    claim: fn(String, String, Option(String), Option(String)) ->
      Result(Seat, RoomError),
    /// The running game behind the seat this caller holds, and that seat's
    /// player id: (game_id, guest id, user id) -- the holder rule
    /// (`rooms/seat.holder`), so an account reaches its seat from any
    /// browser it is signed in on. A caller at no seat here is `NoSeat`;
    /// a room still in its lobby is `GameNotStarted`. Reading it changes
    /// nothing and attaches nothing.
    seated_game: fn(String, Option(String), Option(String)) ->
      Result(#(String, Instance), RoomError),
    /// The running game at a room, for anyone: what every seat and every
    /// spectator already sees. A room still in its lobby is
    /// `GameNotStarted`. Reading it changes nothing and attaches nothing.
    game: fn(String) -> Result(Instance, RoomError),
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
    join: fn(_, _, _, _) { panic as "stub rooms.join" },
    claim: fn(_, _, _, _) { panic as "stub rooms.claim" },
    seated_game: fn(_, _, _) { panic as "stub rooms.seated_game" },
    game: fn(_) { panic as "stub rooms.game" },
  )
}
