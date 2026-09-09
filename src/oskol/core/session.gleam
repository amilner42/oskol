//// Who is asking. Oskol has no accounts: the only identity is the silent
//// guest id minted by OskolWeb.Plugs.GuestId and carried in the session.
//// It authenticates nothing — seats are opened by seat tokens — so a
//// session with no guest id is a perfectly ordinary visitor.

import gleam/option.{type Option, None}

pub type Session {
  Session(guest_id: Option(String))
}

pub fn anonymous() -> Session {
  Session(guest_id: None)
}
