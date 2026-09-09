//// Landing-page prose, read from the presentation layer. Built for real in
//// lib/oskol/gleam/caps/copy.ex.

import oskol/landing/copy.{type Copy, type Site}

pub type CopyCaps {
  CopyCaps(
    /// The library's own title and description.
    site: fn() -> Site,
    /// One game's copy, by slug. Raises for a slug no game answers to:
    /// handlers resolve the game first.
    for_game: fn(String) -> Copy,
  )
}

pub fn stub() -> CopyCaps {
  CopyCaps(site: fn() { panic as "stub copy.site" }, for_game: fn(_) {
    panic as "stub copy.for_game"
  })
}
