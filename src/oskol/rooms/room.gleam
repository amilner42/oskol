//// The room types that cross the capability boundary. A room itself is an
//// Erlang process: handlers only ever hold it as an opaque handle and hand
//// it back to Elixir, exactly as the platform holds a game instance.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

/// A live room. It is an Erlang process, and it stays opaque on purpose:
/// every question about a room is answered by a capability, never by
/// looking inside this value. Handlers only ever hand it back to Elixir.
pub type Room {
  Room(process: Dynamic)
}

/// What the creator picked, on its way into a room. Mirrors the Elixir
/// setup map's decidable half; `seed` and `control` are tooling-only and
/// stay on the Elixir side.
pub type Setup {
  Setup(format: String, clock: String)
}

/// A seat just taken: its player id, and whether taking it filled the table
/// and started the game. Nothing secret comes back: the seat is held by the
/// guest who took it, and the room remembers which one that is.
pub type Seat {
  Seat(player_id: String, started: Bool)
}

/// A player seated in a room, with everything the caller needs to send them
/// to their lobby or their game.
pub type Seated {
  Seated(game_id: String, player_id: String, name: String, started: Bool)
}

/// The table as an invite link finds it: whether it is full, who is sitting
/// at it right now, the one line describing what is being played, and the
/// seats whose player is away (#(player_id, name), in seat order).
pub type Table {
  Table(
    full: Bool,
    inviter: Option(String),
    summary: String,
    disconnected: List(#(String, String)),
  )
}

/// The URL of a seat: the game page, and nothing else. The seat is held by
/// the guest cookie that took it, so the link carries no secret and is the
/// same link for everyone -- what it opens is the room's decision, not the
/// link's.
pub fn seat_path(slug: String, game_id: String) -> String {
  "/" <> slug <> "/" <> game_id
}

/// An unfinished room a guest holds a seat in, as its row tells it: enough
/// to list it and send the player back, read without waking the room.
/// `seats` are #(player_id, name, guest id) in seat order ("" for a seat
/// held by nobody); `to_act` the seats that may act right now, from the
/// snapshot the room wrote with its last step (empty for a lobby, or for a
/// row from before the snapshot existed); `clocks` each seat's time as of
/// that step, #(player_id, remaining_ms, move_ms, running), empty under no
/// clock, and `clock_s` seconds since those clocks were read (from the
/// snapshot's own stamp, so a claimed seat or a wake does not skew it);
/// `idle_s` seconds since the room was last touched.
pub type ActiveRoom {
  ActiveRoom(
    slug: String,
    game_id: String,
    status: String,
    format: String,
    clock: String,
    seats: List(#(String, String, String)),
    to_act: List(String),
    clocks: List(#(String, Int, Int, Bool)),
    clock_s: Int,
    idle_s: Int,
  )
}
