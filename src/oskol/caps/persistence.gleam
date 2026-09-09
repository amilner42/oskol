//// Durable-storage capabilities. Built for real in
//// lib/oskol/gleam/caps/persistence.ex.

pub type PersistenceCaps {
  PersistenceCaps(
    /// Whether a game row still holds this code. A database hiccup must not
    /// block creating games, so the Elixir closure degrades to False — the
    /// registry still makes collisions with live rooms impossible.
    game_exists: fn(String) -> Bool,
  )
}

pub fn stub() -> PersistenceCaps {
  PersistenceCaps(game_exists: fn(_) { panic as "stub persistence.game_exists" })
}
