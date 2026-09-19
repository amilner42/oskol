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
//// Nothing here stamps a seat: in this first cut signing in binds the
//// browser to the account and says `saved: 0`. Taking ownership of the
//// seats a browser has played is the next piece of work.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/auth.{type Pending, CodeDead, CodeOk, CodeWrong}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/guests/identity

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

  case ctx.auth.enabled() && within_limits(ctx, session, address) {
    True -> {
      let issued =
        ctx.auth.issue_token(address, session.guest_id, local_path(next), ttl_s)
      ctx.auth.send_mail(address, issued.token, issued.code)
    }
    // Switched off, or asked too often: the same silence either way.
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
  case ctx.auth.enabled() {
    False -> expired_flags()
    True ->
      case ctx.auth.verify_token(token) {
        Some(pending) ->
          json.object([
            #("state", json.string("confirm")),
            #("email", json.string(pending.email)),
            #("next", json.string(where_next(pending.next))),
          ])
          |> json.to_string
        None -> expired_flags()
      }
  }
}

fn expired_flags() -> String {
  json.object([#("state", json.string("expired"))]) |> json.to_string
}

// ---------- POST /papi/auth/link ----------

/// Spend the token the mailed link carried and sign this browser in. The
/// first element of the answer is for Elixir alone: True means a session
/// was just established, which is the moment to renew the session cookie.
pub fn link_json(
  ctx: Ctx,
  session: Session,
  token: String,
) -> #(Bool, Result(String, ApiError)) {
  case ctx.auth.enabled() {
    False -> #(False, Error(dead()))
    True ->
      case ctx.auth.consume_token(token) {
        Some(pending) -> sign_in(ctx, session, pending)
        None -> #(False, Error(dead()))
      }
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
) -> #(Bool, Result(String, ApiError)) {
  let address = normalise_email(email)
  let digits = only_digits(code)

  case
    ctx.auth.enabled() && address_like(address) && string.length(digits) == 6
  {
    False -> #(False, Error(dead()))
    True ->
      case
        ctx.auth.check_code(address, digits, session.guest_id, code_attempts)
      {
        CodeOk(pending) -> sign_in(ctx, session, pending)
        CodeWrong -> #(
          False,
          Error(error.validation_failed(
            "That code is not right. Check the mail, or ask for a new one.",
          )),
        )
        CodeDead -> #(False, Error(dead()))
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
/// its games came with it (`saved`, always none yet: taking ownership of
/// the seats a browser has played is the next piece of work).
fn sign_in(
  ctx: Ctx,
  session: Session,
  pending: Pending,
) -> #(Bool, Result(String, ApiError)) {
  case session.guest_id {
    // Every request through the browser pipeline carries a guest, so this
    // is a browser that refused the cookie: there is nothing to sign in.
    None -> #(
      False,
      Error(error.validation_failed(
        "Signing in needs a browser that keeps cookies.",
      )),
    )

    Some(guest_id) -> {
      let user = ctx.auth.find_or_create_user(pending.email)
      ctx.auth.bind_guest(guest_id, user.id)

      #(
        True,
        Ok(
          envelope.ok([
            #("saved", json.int(0)),
            #("next", json.string(where_next(pending.next))),
            #(
              "user",
              json.object([
                #("email", json.string(user.email)),
                #("name", nullable(user.name)),
              ]),
            ),
          ]),
        ),
      )
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
