//// Who is asking: the silent guest id minted by OskolWeb.Plugs.GuestId,
//// carried in the year-long cookie and mirrored into the session, and the
//// account that guest is signed in as, if any.
////
//// The guest is what holds a seat. A seat is the guest who took it, and a
//// seat whose guest is away may be claimed by anyone with the room code —
//// friends playing, not security. An account is the guest grown up
//// (`guests.user_id`, read once per request): the same mechanism, not a
//// second one beside it.
////
//// A session with no guest id is a perfectly ordinary visitor: they simply
//// hold no seat anywhere. A session with a guest and no user is every
//// visitor who never typed an email, which is most of them.

import gleam/option.{type Option, None}

pub type Session {
  Session(guest_id: Option(String), user_id: Option(String))
}

pub fn anonymous() -> Session {
  Session(guest_id: None, user_id: None)
}

/// Whether this browser is signed in.
pub fn signed_in(session: Session) -> Bool {
  session.user_id != None
}
