//// Randomness. Built for real in lib/oskol/gleam/caps/ids.ex.

pub type IdsCaps {
  IdsCaps(
    /// A candidate game code: six crypto-random digits (see
    /// oskol/rooms/code). Nothing guarantees it is free.
    game_code: fn() -> String,
  )
}

pub fn stub() -> IdsCaps {
  IdsCaps(game_code: fn() { panic as "stub ids.game_code" })
}
