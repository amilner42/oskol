//// Durable-storage capabilities. Built for real in
//// lib/oskol/gleam/caps/persistence.ex.

import gleam/option.{type Option}
import oskol/rooms/room.{type ActiveRoom}

pub type PersistenceCaps {
  PersistenceCaps(
    /// Whether a game row still holds this code. A database hiccup must not
    /// block creating games, so the Elixir closure degrades to False — the
    /// registry still makes collisions with live rooms impossible.
    game_exists: fn(String) -> Bool,
    /// The unfinished rooms this caller holds a seat in, most recently
    /// touched first, from their rows alone: asking wakes no room. Seats
    /// are matched by guest *or* by account (an account's seats follow it
    /// to any browser it signs in on); the holder rule then says which of
    /// them are really this caller's. A database hiccup is an empty list,
    /// never a broken page.
    seated_rooms: fn(Option(String), Option(String)) -> List(ActiveRoom),
    /// One room as its row holds it, whoever asks: what an invite link's
    /// head is built from, so a crawler wakes nothing and the inviter is
    /// the seat's name, not a live connection's. A missing row, or a
    /// database hiccup, is None.
    room: fn(String) -> Option(ActiveRoom),
  )
}

pub fn stub() -> PersistenceCaps {
  PersistenceCaps(
    game_exists: fn(_) { panic as "stub persistence.game_exists" },
    seated_rooms: fn(_, _) { panic as "stub persistence.seated_rooms" },
    room: fn(_) { panic as "stub persistence.room" },
  )
}
