//// Randomness. Built for real in lib/oskol/gleam/caps/ids.ex.

pub type IdsCaps {
  IdsCaps(
    /// A candidate game code: six crypto-random characters of the code
    /// alphabet (see oskol/rooms/code). Nothing guarantees it is free.
    game_code: fn() -> String,
    /// A share token: twelve crypto-random characters of the same alphabet.
    /// Nothing guarantees it is free either; the row's insert decides.
    share_token: fn() -> String,
  )
}

pub fn stub() -> IdsCaps {
  IdsCaps(game_code: fn() { panic as "stub ids.game_code" }, share_token: fn() {
    panic as "stub ids.share_token"
  })
}
