//// Signing in, by email and nothing else:
////
////   POST /papi/auth/start  {email, next?}  -> {ok}          (always)
////   GET  /login/<token>                    -> the page's flags, no write
////   POST /papi/auth/link   {token}         -> {ok, saved}
////   POST /papi/auth/code   {email, code}   -> {ok, saved}
////   POST /papi/auth/logout                 -> {ok}
////   GET  /papi/me                          -> {ok, guest_name, user}
////
//// Two doors, one token: a link in the mail and a six-digit code printed
//// under it. The link is the smooth path; the code is what saves the case
//// where the mail opens on the phone and the game is on the laptop.
////
//// The rules this file keeps, in one place:
////
////   * **A GET never signs anyone in.** `/login/<token>` only reads the
////     token and renders "Sign in as you@example.com" with a button; the
////     button POSTs, with the page's CSRF token, and *that* consumes it.
////     So a mail scanner prefetching the link cannot burn it, a webview
////     opening it cannot spend it, and no other site can sign a visitor
////     in behind their back.
////   * **A code redeems only from the browser that asked for it.** The row
////     remembers the guest that started the sign-in; a code typed anywhere
////     else gets the same answer as an expired one.
////   * **No enumeration.** Starting a sign-in answers the same whether the
////     address has an account, has none, or is over its rate limit.
////   * **Fifteen minutes, one use, five tries.** Hashed at rest, and the
////     plaintext exists only between minting it and posting the mail.
////   * **`next` is a local path or nothing.** Never a URL, so a sign-in
////     cannot be aimed at somewhere else.
////
//// Signing in also hands this browser's games to the account and rotates
//// its guest id, both in one write (`sign_in`): `saved` is how many seats
//// the account gained, and the fresh guest rides back to Elixir in
//// `SignedIn.guest_id` to be written into the cookie.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/auth.{
  type Pending, type User, CodeDead, CodeOk, CodeWrong, User,
}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/guests/identity
import oskol/guests/username

/// How long a sign-in is good for. Long enough to go and find the mail,
/// short enough that a link left in an inbox is not a key.
pub const ttl_s = 900

/// Tries a six-digit code gets before its token is dead. Six digits is a
/// million, so five tries is nothing to guess with.
pub const code_attempts = 5

/// The mail is the only thing worth protecting here, so the limits are on
/// sending it. The browser is the tighter bucket, because it is the one an
/// abuser actually has; the address bucket is a high ceiling that stops one
/// mailbox being buried however many browsers ask.
pub const starts_per_guest = 10

pub const starts_per_address = 30

pub const start_window_s = 3600

// ---------- POST /papi/auth/start ----------

/// Ask for a sign-in. Answers the same thing every time it is asked
/// properly: nothing about the address, nothing about the rate limit,
/// nothing about whether a mail went out.
pub fn start_json(
  ctx: Ctx,
  session: Session,
  email: String,
  next: String,
) -> Result(String, ApiError) {
  let address = normalise_email(email)

  // The shape of what was typed is the one thing worth saying out loud: it
  // is about the request, not about who exists.
  use <- require(
    address_like(address),
    "That doesn't look like an email address",
  )

  case within_limits(ctx, session, address) {
    True -> {
      let issued =
        ctx.auth.issue_token(address, session.guest_id, local_path(next), ttl_s)
      ctx.auth.send_mail(address, issued.token, issued.code)
    }
    // Asked too often: the same answer, and silence.
    False -> Nil
  }

  Ok(envelope.ok([]))
}

/// Both buckets are bumped whichever one is over, so the counters read the
/// same however a caller arrives. Per node: one machine today, and a
/// second one would give each its own allowance (a comment, not a bug —
/// the ceiling is what matters, not its exactness).
fn within_limits(ctx: Ctx, session: Session, address: String) -> Bool {
  let by_guest = case session.guest_id {
    Some(id) ->
      ctx.auth.count("start:guest:" <> id, start_window_s) <= starts_per_guest
    None -> True
  }
  let by_address =
    ctx.auth.count("start:email:" <> address, start_window_s)
    <= starts_per_address

  by_guest && by_address
}

// ---------- GET /login/<token> ----------

/// What the page behind a mailed link boots with. It reads the token and
/// writes nothing at all:
///
///   {"state": "confirm", "email": "you@example.com", "next": "/"}
///   {"state": "expired"}
///
/// A visitor who lands here with a live token is one button away from being
/// signed in, and that button is a POST.
pub fn link_flags(ctx: Ctx, token: String) -> String {
  case ctx.auth.verify_token(token) {
    Some(pending) ->
      json.object([
        #("state", json.string("confirm")),
        #("email", json.string(pending.email)),
        #("next", json.string(where_next(pending.next))),
      ])
      |> json.to_string
    None -> json.object([#("state", json.string("expired"))]) |> json.to_string
  }
}

// ---------- POST /papi/auth/link ----------

/// What a sign-in leaves for Elixir to do, beside sending the body.
/// `renew` means a session was just established, which is the moment to
/// renew the session cookie; `guest_id`, when it is there, is the fresh
/// guest this browser now carries, to be written into the cookie and the
/// session (see `sign_in`).
pub type SignedIn {
  SignedIn(
    renew: Bool,
    guest_id: Option(String),
    /// The guest whose sockets to drop once the response (and the cookie
    /// it carries) is on its way: every socket the browser opened before
    /// the sign-in speaks for that guest and no account, and dropped, each
    /// reconnects on the new cookie as the account. Not dropped here: a
    /// reconnect that raced the response would come back on the old
    /// cookie and be refused at its own table.
    drop_sockets: Option(String),
    body: Result(String, ApiError),
  )
}

fn refused(error: ApiError) -> SignedIn {
  SignedIn(renew: False, guest_id: None, drop_sockets: None, body: Error(error))
}

/// Spend the token the mailed link carried and sign this browser in.
pub fn link_json(ctx: Ctx, session: Session, token: String) -> SignedIn {
  case ctx.auth.consume_token(token) {
    Some(pending) -> sign_in(ctx, session, pending)
    None -> refused(dead())
  }
}

// ---------- POST /papi/auth/code ----------

/// The six digits from the mail, typed into the browser that asked for
/// them. A code for another browser, a code past its tries, a code for a
/// token already spent: one answer for all of them.
pub fn code_json(
  ctx: Ctx,
  session: Session,
  email: String,
  code: String,
) -> SignedIn {
  let address = normalise_email(email)
  let digits = only_digits(code)

  case address_like(address) && string.length(digits) == 6 {
    False -> refused(dead())
    True ->
      case
        ctx.auth.check_code(address, digits, session.guest_id, code_attempts)
      {
        CodeOk(pending) -> sign_in(ctx, session, pending)
        CodeWrong ->
          refused(error.validation_failed(
            "That code is not right. Check the mail, or ask for a new one.",
          ))
        CodeDead -> refused(dead())
      }
  }
}

// ---------- POST /papi/auth/logout ----------

/// This browser is a guest again. Its own sockets go with it, so a tab left
/// open at a table stops playing a seat this browser may no longer hold.
/// Other browsers signed into the same account are untouched.
pub fn logout_json(ctx: Ctx, session: Session) -> String {
  case session.guest_id {
    Some(id) -> {
      ctx.auth.unbind_guest(id)
      ctx.auth.disconnect(id)
    }
    None -> Nil
  }

  envelope.ok([])
}

// ---------- GET /papi/me ----------

/// Who this browser is: the name it last played under, and the account it
/// is signed into, if any.
pub fn me_json(ctx: Ctx, session: Session) -> String {
  let user = case session.user_id {
    Some(id) -> ctx.auth.user(id)
    None -> None
  }

  envelope.ok([
    #("guest_name", nullable(identity.remembered_name(ctx, session))),
    #("user", case user {
      Some(user) ->
        json.object([
          #("email", json.string(user.email)),
          #("name", nullable(user.name)),
        ])
      None -> json.null()
    }),
  ])
}

// ---------- Shared ----------

/// The account for this address, this browser bound to it, and how many of
/// the games it has played came with it (`saved`).
///
/// Two things happen in the one write (`auth.stamp_seats`), because they
/// are the same fact seen twice:
///
///   * **the stamp.** Every unowned seat this guest holds becomes the
///     account's, in finished rooms as well as live ones. A seat somebody
///     else's account already owns is never taken, so a shared laptop hands
///     each person only what nobody has claimed.
///   * **the rotation.** The browser leaves with a fresh guest id, carrying
///     its name, its preferences and its seats. The cookie is the
///     credential, and the id it arrived with may have been learned by
///     somebody (a shared machine, a devtools pane, the browser it was
///     minted in): after a sign-in that id opens nothing.
fn sign_in(ctx: Ctx, session: Session, pending: Pending) -> SignedIn {
  case session.guest_id {
    // Every request through the browser pipeline carries a guest, so this
    // is a browser that refused the cookie: there is nothing to sign in.
    None ->
      refused(error.validation_failed(
        "Signing in needs a browser that keeps cookies.",
      ))

    Some(guest_id) -> {
      let user = ctx.auth.find_or_create_user(pending.email)
      // Read before the stamp: the stamp moves this browser's guest row
      // (and the name on it) to a fresh id.
      let remembered = identity.remembered_name(ctx, session)
      let fresh = ctx.guests.mint()
      // Named before the stamp: the stamp hands the seats to the account,
      // and an account's seat plays under the account's name, so it has to
      // have one by then.
      let #(user, is_new) = case user.name {
        Some(_) -> #(user, False)
        None -> #(named(ctx, user, remembered), True)
      }
      let #(saved, signed_in_as) = case
        ctx.auth.stamp_seats(guest_id, fresh, user.id)
      {
        Ok(saved) -> #(saved, fresh)
        // The write did not land, so nothing moved: the browser keeps the
        // id it has and is signed in on that. Its games come with the next
        // sign-in; the sign-in itself does not fail over them.
        Error(Nil) -> #(0, guest_id)
      }
      ctx.auth.bind_guest(signed_in_as, user.id)

      SignedIn(
        renew: True,
        guest_id: case signed_in_as == guest_id {
          True -> None
          False -> Some(signed_in_as)
        },
        // The tab at a table keeps its seat (it reconnects as the account),
        // and a later logout reaches every tab.
        drop_sockets: Some(guest_id),
        body: Ok(
          envelope.ok([
            #("saved", json.int(saved)),
            #("next", json.string(where_next(pending.next))),
            #("user", user_json(user)),
            // True when this sign-in made the account: the page says which
            // username it was given, and offers to change it.
            #("new", json.bool(is_new)),
          ]),
        ),
      )
    }
  }
}

/// The account as the client sees it. Its email is here because it is
/// the account's own browser asking; nothing puts it on screen for others.
fn user_json(user: User) -> Json {
  json.object([
    #("email", json.string(user.email)),
    #("name", nullable(user.name)),
  ])
}

/// A new account's username: the first of `username.candidates` no other
/// account has. The last candidate carries a piece of the account's id,
/// so in practice a new account is always named.
fn named(ctx: Ctx, user: User, remembered: Option(String)) -> User {
  let taken =
    list.find(username.candidates_for(remembered, user.id), fn(candidate) {
      ctx.auth.claim_name(user.id, candidate) == Ok(Nil)
    })
  case taken {
    Ok(name) -> User(..user, name: Some(name))
    Error(Nil) -> user
  }
}

// ---------- POST /papi/me/name ----------

/// A signed-in browser renames its account. The same rules as a display
/// name, and unique regardless of case.
pub fn name_json(
  ctx: Ctx,
  session: Session,
  typed: String,
) -> Result(String, ApiError) {
  case session.user_id {
    None -> Error(error.validation_failed("Sign in first."))
    Some(user_id) ->
      case username.clean(typed) {
        Error(sentence) -> Error(error.validation_failed(sentence))
        Ok(name) ->
          case ctx.auth.claim_name(user_id, name) {
            Error(Nil) -> Error(error.validation_failed("That name is taken."))
            Ok(Nil) -> {
              ctx.auth.renamed(user_id, name)
              case ctx.auth.user(user_id) {
                Some(user) -> Ok(envelope.ok([#("user", user_json(user))]))
                None -> Error(error.validation_failed("Sign in first."))
              }
            }
          }
      }
  }
}

/// The one thing a failed sign-in ever says. A token that expired, one
/// already spent, one that never existed and one belonging to another
/// browser are deliberately indistinguishable.
fn dead() -> ApiError {
  error.validation_failed("That sign-in link has expired. Ask for a new one.")
}

/// Where a signed-in browser goes next: the local path it came from, or
/// home. Never a URL, and never a protocol-relative path, so a mailed
/// sign-in cannot be aimed off the site.
pub fn where_next(next: Option(String)) -> String {
  case next {
    Some(path) -> option.unwrap(local_path(path), "/")
    None -> "/"
  }
}

/// A path this site will send a player to, or nothing.
pub fn local_path(next: String) -> Option(String) {
  case
    string.starts_with(next, "/")
    && !string.starts_with(next, "//")
    && !string.contains(next, "\\")
    && !string.contains(next, " ")
    && printable(next)
    && string.length(next) <= 200
  {
    True ->
      case next {
        "/" -> None
        path -> Some(path)
      }
    False -> None
  }
}

/// An address as it is stored and compared: trimmed and lower case. The
/// column is citext as well; this is the half that does not depend on the
/// database.
pub fn normalise_email(email: String) -> String {
  email |> string.trim |> string.lowercase
}

/// Whether what was typed can be an address at all. Deliberately loose:
/// the only proof an address works is that the mail arrives.
pub fn address_like(email: String) -> Bool {
  case string.split(email, "@") {
    [local, domain] ->
      local != ""
      && string.length(email) <= 254
      && string.contains(domain, ".")
      && !string.starts_with(domain, ".")
      && !string.ends_with(domain, ".")
      && !string.contains(email, " ")
    _ -> False
  }
}

/// No control characters, and no delete. This is not tidiness: a browser's
/// URL parser deletes tabs and newlines *before* it resolves a link, so
/// "/<tab>/evil.example.com" would resolve as "//evil.example.com" — another
/// origin — having passed a check that only read the first two characters.
fn printable(text: String) -> Bool {
  string.to_utf_codepoints(text)
  |> list.all(fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code > 0x1f && code != 0x7f
  })
}

fn only_digits(code: String) -> String {
  code
  |> string.to_graphemes
  |> list.filter(fn(c) { string.contains("0123456789", c) })
  |> string.join("")
}

fn require(
  condition: Bool,
  message: String,
  continue: fn() -> Result(a, ApiError),
) -> Result(a, ApiError) {
  case condition {
    True -> continue()
    False -> Error(error.validation_failed(message))
  }
}

fn nullable(value: Option(String)) -> json.Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}
