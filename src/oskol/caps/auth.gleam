//// Sign-in capabilities. Built for real in lib/oskol/gleam/caps/auth.ex —
//// that file and this one must agree on constructor tag and field order.
////
//// Everything here is IO: a row read, a row written, an email handed to a
//// mail adapter, a counter bumped. Every *decision* — whether an address
//// looks like one, how long a token lives, how many tries a code gets,
//// what a refusal says, where a player is sent afterwards — belongs to
//// `oskol/handlers/auth`.
////
//// Nothing in here ever hands back a token or a code that was stored: both
//// are kept as sha256 and are only ever known in plaintext for the one
//// moment between minting them and putting them in the mail.

import gleam/option.{type Option}

/// An account. `id` is the uuid `guests.user_id` points at; `email` is the
/// whole credential; `name` is set later, from the home board.
pub type User {
  User(id: String, email: String, name: Option(String))
}

/// A sign-in in flight, as the row remembers it: the address it was asked
/// for, the browser that asked, and where that browser was at the time.
pub type Pending {
  Pending(email: String, guest_id: Option(String), next: Option(String))
}

/// A freshly minted sign-in, in plaintext, for the one moment before it
/// goes in the mail. Only the hashes are stored.
pub type Issued {
  Issued(token: String, code: String)
}

/// The configured ceilings for the one mail Oskol sends. The handler decides
/// which buckets must pass; Elixir only reads these values from application
/// configuration. `source` is an opaque, one-way key for a request IP, never
/// an IP address retained by Oskol.
pub type MailBudget {
  MailBudget(
    guest_limit: Int,
    guest_window_s: Int,
    address_limit: Int,
    address_window_s: Int,
    source_limit: Int,
    source_window_s: Int,
    global_limit: Int,
    global_window_s: Int,
  )
}

/// One bucket in an all-or-nothing sign-in mail reservation. The handler
/// makes this list from its policy; the limiter atomically says whether all
/// of them can spend one message.
pub type LimitBucket {
  LimitBucket(key: String, limit: Int, window_s: Int)
}

/// What came of typing a six-digit code.
pub type CodeCheck {
  /// It matched a live token, which is now consumed.
  CodeOk(pending: Pending)
  /// There is a live token and that was not its code. The try is recorded.
  CodeWrong
  /// Nothing live to check it against: no token for this address and this
  /// browser, or it expired, or it was used, or it ran out of tries.
  CodeDead
}

pub type AuthCaps {
  AuthCaps(
    /// Spend one unit from every bucket only when every bucket has room.
    /// This is the handler's decision expressed as data; the limiter makes
    /// the multi-bucket reservation atomic.
    allow_mail: fn(List(LimitBucket)) -> Bool,
    /// The configurable ceilings for sign-in mail. The handler still decides
    /// whether to issue a token; this only supplies its numbers.
    mail_budget: fn() -> MailBudget,
    /// Mint a token and a code for this address, store their hashes against
    /// the asking browser and where it was, and hand back the plaintext.
    /// Several may be live for one address at once; each dies on its own
    /// expiry or first use.
    issue_token: fn(String, Option(String), Option(String), Int) -> Issued,
    /// Put the sign-in in the mail: the address, the token the link carries,
    /// and the code printed under it.
    send_mail: fn(String, String, String) -> Nil,
    /// What a token names, without spending it. This is what a link's `GET`
    /// may do: a mail scanner that fetches the link must not burn it.
    verify_token: fn(String) -> Option(Pending),
    /// Spend a token: one statement, so two opens cannot both win.
    consume_token: fn(String) -> Option(Pending),
    /// Check a code against the live token for this address *and this
    /// browser*, allowing at most the given number of tries. A match
    /// consumes the token; a miss records the try.
    check_code: fn(String, String, Option(String), Int) -> CodeCheck,
    /// The account for this address, made if it is new; either way its
    /// `last_login_at` moves forward.
    find_or_create_user: fn(String) -> User,
    /// One account, by id. `None` for an id nothing answers to (a row
    /// deleted under a live session).
    user: fn(String) -> Option(User),
    /// Sign-in's one write, and the only thing that hands seats to an
    /// account: `stamp_seats(old_guest, new_guest, user_id)`.
    ///
    /// In one ordered write (behind everything the rooms have queued, so it
    /// cannot race a room rewriting its seats):
    ///
    ///   * every seat that guest holds, in a room of any status, that no
    ///     account owns yet, becomes this account's -- except in a room
    ///     where the account already has a seat (one person, one seat per
    ///     table, however many devices they signed in on);
    ///   * this browser's guest row and those seats move to `new_guest`, so
    ///     the id anyone may have learned before the sign-in is worth
    ///     nothing afterwards.
    ///
    /// Answers how many seats the account gained, or `Error(Nil)` when the
    /// write did not land (nothing moved: the browser keeps its id). Rooms
    /// that are live are told, so memory and disk agree.
    stamp_seats: fn(String, String, String) -> Result(Int, Nil),
    /// This browser is signed in as that account (`guests.user_id`).
    bind_guest: fn(String, String) -> Nil,
    /// This browser is a guest again.
    unbind_guest: fn(String) -> Nil,
    /// Drop this browser's live sockets, so a tab at a table does not go on
    /// playing a seat the browser no longer holds.
    disconnect: fn(String) -> Nil,
    /// The account renamed itself: every live room holding one of its
    /// seats shows the new name. Nothing is written -- a seat points at
    /// the account -- so this is only the rooms catching up.
    renamed: fn(String, String) -> Nil,
    /// Give this account that username, if no other account has it
    /// (regardless of case). `Error(Nil)` when it is taken.
    claim_name: fn(String, String) -> Result(Nil, Nil),
  )
}

pub fn stub() -> AuthCaps {
  AuthCaps(
    allow_mail: fn(_) { panic as "stub auth.allow_mail" },
    mail_budget: fn() { panic as "stub auth.mail_budget" },
    issue_token: fn(_, _, _, _) { panic as "stub auth.issue_token" },
    send_mail: fn(_, _, _) { panic as "stub auth.send_mail" },
    verify_token: fn(_) { panic as "stub auth.verify_token" },
    consume_token: fn(_) { panic as "stub auth.consume_token" },
    check_code: fn(_, _, _, _) { panic as "stub auth.check_code" },
    find_or_create_user: fn(_) { panic as "stub auth.find_or_create_user" },
    user: fn(_) { panic as "stub auth.user" },
    stamp_seats: fn(_, _, _) { panic as "stub auth.stamp_seats" },
    bind_guest: fn(_, _) { panic as "stub auth.bind_guest" },
    unbind_guest: fn(_) { panic as "stub auth.unbind_guest" },
    disconnect: fn(_) { panic as "stub auth.disconnect" },
    renamed: fn(_, _) { panic as "stub auth.renamed" },
    claim_name: fn(_, _) { panic as "stub auth.claim_name" },
  )
}
