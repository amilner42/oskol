//// Guest-identity capabilities. Built for real in
//// lib/oskol/gleam/caps/guests.ex.
////
//// Guest bookkeeping must never break a page: the Elixir closures rescue
//// and degrade to "the site just doesn't remember you", so nothing here
//// fails in a way a handler branches on.

import gleam/option.{type Option}

pub type GuestsCaps {
  GuestsCaps(
    /// A fresh opaque guest id.
    mint: fn() -> String,
    /// Upsert the guest's row, moving `last_seen_at` forward, and give back
    /// the display name they last played under.
    touch: fn(String) -> Option(String),
    /// Remember the name this guest played under. Last writer wins.
    save_name: fn(String, String) -> Nil,
  )
}

pub fn stub() -> GuestsCaps {
  GuestsCaps(
    mint: fn() { panic as "stub guests.mint" },
    touch: fn(_) { panic as "stub guests.touch" },
    save_name: fn(_, _) { panic as "stub guests.save_name" },
  )
}
