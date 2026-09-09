//// The room types that cross the capability boundary. A room itself is an
//// Erlang process: handlers only ever hold it as an opaque handle and hand
//// it back to Elixir, exactly as the platform holds a game instance.

import gleam/dynamic.{type Dynamic}

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
  Setup(format: String, selections: List(#(String, String)), clock: String)
}

/// A seat just taken: its player id, the token that opens it, and whether
/// taking it filled the table and started the game.
pub type Seat {
  Seat(player_id: String, token: String, started: Bool)
}

/// A player seated in a room, with everything the caller needs to send them
/// to their lobby or their game.
pub type Seated {
  Seated(
    game_id: String,
    player_id: String,
    token: String,
    name: String,
    started: Bool,
  )
}
