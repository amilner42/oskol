//// Who is asking. Oskol has no accounts yet: the only identity is the
//// silent guest id minted by OskolWeb.Plugs.GuestId, carried in the
//// year-long cookie and mirrored into the session.
////
//// It is the identity that holds a seat. A seat is the guest who took it,
//// and a seat whose guest is away may be claimed by anyone with the room
//// code — friends playing, not security. When accounts arrive this is the
//// thing that becomes an account session (`guests.user_id`), which is why
//// there is no second mechanism beside it.
////
//// A session with no guest id is a perfectly ordinary visitor: they simply
//// hold no seat anywhere.

import gleam/option.{type Option, None}

pub type Session {
  Session(guest_id: Option(String))
}

pub fn anonymous() -> Session {
  Session(guest_id: None)
}
