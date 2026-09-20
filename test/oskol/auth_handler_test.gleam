//// Signing in, decided on stub capabilities: what goes in the mail, what a
//// link's page says, what a code is worth, and every refusal.
////
//// Every cap panics until a test arranges it, so a branch that reaches IO it
//// was not supposed to reach fails loudly. That is how "this answers ok and
//// sends nothing" is tested: `send_mail` is left panicking.

import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/auth.{
  type MailBudget, AuthCaps, CodeDead, CodeOk, CodeWrong, Issued, LimitBucket,
  MailBudget, Pending, User,
}
import oskol/caps/guests as guests_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/auth as handler

fn under_limit(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    auth: AuthCaps(..ctx.auth, allow_mail: fn(_) { True }, mail_budget: fn() {
      ordinary_budget()
    }),
  )
}

fn ordinary_budget() -> MailBudget {
  MailBudget(
    guest_limit: 10,
    guest_window_s: 3600,
    address_limit: 30,
    address_window_s: 3600,
    source_limit: 20,
    source_window_s: 3600,
    global_limit: 200,
    global_window_s: 86_400,
  )
}

fn policy_budget() -> MailBudget {
  MailBudget(
    guest_limit: 2,
    guest_window_s: 61,
    address_limit: 3,
    address_window_s: 62,
    source_limit: 4,
    source_window_s: 63,
    global_limit: 5,
    global_window_s: 64,
  )
}

/// A sign-in that records what it was asked to put in the mail, by panicking
/// with the details unless they are the ones expected.
fn mailing(ctx: Ctx, expected: #(String, String, String)) -> Ctx {
  Ctx(
    ..ctx,
    auth: AuthCaps(
      ..ctx.auth,
      issue_token: fn(email, _guest, next, ttl) {
        assert email == expected.0
        assert ttl == handler.ttl_s
        // The path is validated before it is stored.
        assert next == handler.local_path("/backgammon/abc123")
        Issued(token: expected.1, code: expected.2)
      },
      send_mail: fn(email, token, code) {
        assert #(email, token, code) == expected
        Nil
      },
    ),
  )
}

// ---------- POST /papi/auth/start ----------

pub fn a_sign_in_puts_the_token_and_the_code_in_the_mail_test() {
  let ctx =
    fakes.ctx()
    |> under_limit
    |> mailing(#("her@example.com", "tok-32-bytes", "482913"))

  let assert Ok(body) =
    handler.start_json(
      ctx,
      fakes.guest("g1"),
      "  Her@Example.com ",
      "/backgammon/abc123",
      Some("source-key"),
    )

  // Nothing about the address, and nothing about the mail.
  assert body == "{\"ok\":true}"
}

pub fn a_limited_guest_request_reserves_the_configured_policy_and_is_not_mailed_test() {
  // send_mail and issue_token are left panicking: reaching them fails. The
  // refusal cap also proves the exact normalized, opaque policy it received.
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(
          ..ctx.auth,
          allow_mail: fn(buckets) {
            assert buckets
              == [
                LimitBucket(key: "start:guest:g1", limit: 2, window_s: 61),
                LimitBucket(
                  key: "start:source:opaque-source",
                  limit: 4,
                  window_s: 63,
                ),
                LimitBucket(
                  key: "start:address:her@example.com",
                  limit: 3,
                  window_s: 62,
                ),
                LimitBucket(key: "start:global", limit: 5, window_s: 64),
              ]
            False
          },
          mail_budget: fn() { policy_budget() },
        ),
      )
    }

  let assert Ok(body) =
    handler.start_json(
      ctx,
      fakes.guest("g1"),
      "  Her@Example.com ",
      "",
      Some("opaque-source"),
    )
  assert body == "{\"ok\":true}"
}

pub fn a_limited_anonymous_request_omits_the_guest_bucket_and_is_not_mailed_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(
          ..ctx.auth,
          allow_mail: fn(buckets) {
            assert buckets
              == [
                LimitBucket(
                  key: "start:source:opaque-source",
                  limit: 4,
                  window_s: 63,
                ),
                LimitBucket(
                  key: "start:address:a@b.com",
                  limit: 3,
                  window_s: 62,
                ),
                LimitBucket(key: "start:global", limit: 5, window_s: 64),
              ]
            False
          },
          mail_budget: fn() { policy_budget() },
        ),
      )
    }

  let assert Ok(body) =
    handler.start_json(
      ctx,
      fakes.no_guest(),
      "a@b.com",
      "",
      Some("opaque-source"),
    )
  assert body == "{\"ok\":true}"
}

pub fn a_missing_source_omits_its_bucket_and_is_not_mailed_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(
          ..ctx.auth,
          allow_mail: fn(buckets) {
            assert buckets
              == [
                LimitBucket(
                  key: "start:address:a@b.com",
                  limit: 3,
                  window_s: 62,
                ),
                LimitBucket(key: "start:global", limit: 5, window_s: 64),
              ]
            False
          },
          mail_budget: fn() { policy_budget() },
        ),
      )
    }

  let assert Ok(body) =
    handler.start_json(ctx, fakes.no_guest(), "a@b.com", "", None)
  assert body == "{\"ok\":true}"
}

pub fn something_that_is_not_an_address_is_refused_before_anything_happens_test() {
  // Not even the switch is read: the shape is wrong, and saying so leaks
  // nothing about who has an account.
  let cases = ["", "nobody", "no@domain", "two@at@signs.com", "sp ace@b.com"]

  let refused =
    list_all(cases, fn(typed) {
      case
        handler.start_json(
          fakes.ctx(),
          fakes.guest("g1"),
          typed,
          "",
          Some("source-key"),
        )
      {
        Error(err) -> error.status(err) == 422
        Ok(_) -> False
      }
    })

  assert refused
}

// ---------- GET /login/<token> ----------

fn verifying(ctx: Ctx, found: Option(auth.Pending)) -> Ctx {
  Ctx(..ctx, auth: AuthCaps(..ctx.auth, verify_token: fn(_) { found }))
}

pub fn a_live_link_offers_the_address_it_is_for_test() {
  let ctx =
    fakes.ctx()
    |> verifying(
      Some(Pending(
        email: "her@example.com",
        guest_id: Some("g1"),
        next: Some("/backgammon/abc123"),
      )),
    )

  let flags = handler.link_flags(ctx, "tok")

  assert string.contains(flags, "\"state\":\"confirm\"")
  assert string.contains(flags, "\"email\":\"her@example.com\"")
  assert string.contains(flags, "\"next\":\"/backgammon/abc123\"")
}

pub fn a_dead_link_says_only_that_test() {
  let ctx = fakes.ctx() |> verifying(None)

  assert handler.link_flags(ctx, "tok") == "{\"state\":\"expired\"}"
}

pub fn a_link_that_is_opened_is_never_spent_test() {
  // consume_token is left panicking. A GET that consumed anything would
  // reach it, and this test would die instead of answering "expired".
  let ctx = fakes.ctx() |> verifying(None)

  assert handler.link_flags(ctx, "tok") == "{\"state\":\"expired\"}"
}

// ---------- POST /papi/auth/link ----------

/// Caps for a sign-in that works: the account is made, the browser's seats
/// are stamped onto it, its guest is rotated to the freshly minted id, and
/// the new guest is the one bound to the account. `expect` is the guest the
/// browser arrived with and the account id it leaves with; `saved` is how
/// many seats the stamp took.
fn binding(ctx: Ctx, expect: #(String, String), saved: Int) -> Ctx {
  Ctx(
    ..ctx,
    guests: guests_caps.GuestsCaps(
      ..ctx.guests,
      mint: fn() { fakes.minted_id },
      // The name this browser last played under, read before the stamp.
      touch: fn(_) { Some("Alice") },
    ),
    auth: AuthCaps(
      ..ctx.auth,
      find_or_create_user: fn(email) {
        User(id: expect.1, email: email, name: None)
      },
      // "Alice" is somebody else's already; the account gets "Alice1".
      claim_name: fn(user_id, name) {
        assert user_id == expect.1
        case name {
          "Alice" -> Error(Nil)
          _ -> Ok(Nil)
        }
      },
      stamp_seats: fn(old_guest, new_guest, user_id) {
        // The seats move from the guest that played them to the fresh id,
        // and to the account.
        assert old_guest == expect.0
        assert new_guest == fakes.minted_id
        assert user_id == expect.1
        Ok(saved)
      },
      // The account is bound to the *new* guest: the old id is finished.
      bind_guest: fn(guest_id, user_id) {
        assert #(guest_id, user_id) == #(fakes.minted_id, expect.1)
        Nil
      },
    ),
  )
}

pub fn the_button_on_the_page_spends_the_token_and_signs_the_browser_in_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(..ctx.auth, consume_token: fn(token) {
          assert token == "tok"
          Some(Pending(
            email: "her@example.com",
            guest_id: Some("g1"),
            next: Some("/backgammon/abc123"),
          ))
        }),
      )
    }
    |> binding(#("g1", "user-uuid"), 3)

  let signed_in = handler.link_json(ctx, fakes.guest("g1"), "tok")
  let assert Ok(body) = signed_in.body

  // True is Elixir's cue to renew the session cookie.
  assert signed_in.renew
  // And this is the cookie it writes: the browser leaves with a fresh
  // guest id, because the one it arrived with may have been learned.
  assert signed_in.guest_id == Some(fakes.minted_id)
  // Every socket it opened under the old id is dropped once the response is
  // sent, so each comes back on the new cookie as the account.
  assert signed_in.drop_sockets == Some("g1")
  // The games this browser played came with it.
  assert string.contains(body, "\"saved\":3")
  // A new account is named after the name the browser played under, with a
  // number when that one is taken, and the page is told it is new.
  assert string.contains(body, "\"name\":\"Alice1\"")
  assert string.contains(body, "\"new\":true")
  assert string.contains(body, "\"next\":\"/backgammon/abc123\"")
  assert string.contains(body, "\"email\":\"her@example.com\"")
}

pub fn a_stamp_that_did_not_land_signs_in_on_the_id_the_browser_has_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        guests: guests_caps.GuestsCaps(
          ..ctx.guests,
          mint: fn() { fakes.minted_id },
          touch: fn(_) { None },
        ),
        auth: AuthCaps(
          ..ctx.auth,
          consume_token: fn(_) {
            Some(Pending(
              email: "her@example.com",
              guest_id: Some("g1"),
              next: None,
            ))
          },
          find_or_create_user: fn(email) {
            User(id: "user-uuid", email: email, name: None)
          },
          // The one write failed and rolled back: no seat moved.
          stamp_seats: fn(_, _, _) { Error(Nil) },
          claim_name: fn(_, _) { Ok(Nil) },
          // So the account goes on the id the browser already has...
          bind_guest: fn(guest_id, user_id) {
            assert #(guest_id, user_id) == #("g1", "user-uuid")
            Nil
          },
        ),
      )
    }

  let signed_in = handler.link_json(ctx, fakes.guest("g1"), "tok")
  let assert Ok(body) = signed_in.body

  // ...and no new cookie is written: rotating to an id nothing moved to
  // would strand the browser's games on the old one.
  assert signed_in.guest_id == None
  assert signed_in.renew
  assert string.contains(body, "\"saved\":0")
  // Its old sockets still come back, now as the account.
  assert signed_in.drop_sockets == Some("g1")
}

pub fn a_token_already_spent_signs_nobody_in_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(..ctx, auth: AuthCaps(..ctx.auth, consume_token: fn(_) { None }))
    }

  let signed_in = handler.link_json(ctx, fakes.guest("g1"), "tok")

  assert !signed_in.renew
  // Nothing was stamped and no cookie is rewritten.
  assert signed_in.guest_id == None
  assert refusal_is_generic(signed_in.body)
}

// ---------- POST /papi/auth/code ----------

fn checking(ctx: Ctx, verdict: auth.CodeCheck) -> Ctx {
  Ctx(
    ..ctx,
    auth: AuthCaps(..ctx.auth, check_code: fn(email, code, guest, attempts) {
      assert email == "her@example.com"
      assert code == "482913"
      // The row is found by the browser that asked: a code is not a
      // password anyone may type anywhere.
      assert guest == Some("g1")
      assert attempts == handler.code_attempts
      verdict
    }),
  )
}

pub fn the_code_from_the_mail_signs_in_the_browser_that_asked_test() {
  let ctx =
    fakes.ctx()
    |> checking(
      CodeOk(Pending(email: "her@example.com", guest_id: Some("g1"), next: None)),
    )
    |> binding(#("g1", "user-uuid"), 1)

  let signed_in =
    handler.code_json(ctx, fakes.guest("g1"), "Her@Example.com", "482 913")
  let assert Ok(body) = signed_in.body

  assert signed_in.renew
  assert signed_in.guest_id == Some(fakes.minted_id)
  assert string.contains(body, "\"saved\":1")
  // Nowhere in particular to go back to.
  assert string.contains(body, "\"next\":\"/\"")
}

pub fn a_wrong_code_says_so_test() {
  let ctx = fakes.ctx() |> checking(CodeWrong)

  let signed_in =
    handler.code_json(ctx, fakes.guest("g1"), "her@example.com", "482913")

  assert !signed_in.renew
  let assert Error(err) = signed_in.body
  assert error.status(err) == 422
  assert string.contains(error.message(err), "not right")
}

pub fn a_code_out_of_tries_reads_like_an_expired_one_test() {
  let ctx = fakes.ctx() |> checking(CodeDead)

  let signed_in =
    handler.code_json(ctx, fakes.guest("g1"), "her@example.com", "482913")

  assert refusal_is_generic(signed_in.body)
}

pub fn something_that_is_not_six_digits_is_never_looked_up_test() {
  // check_code is left panicking: a short code never reaches the row.
  let ctx = fakes.ctx()

  let signed_in =
    handler.code_json(ctx, fakes.guest("g1"), "her@example.com", "4821")

  assert refusal_is_generic(signed_in.body)
}

// ---------- POST /papi/auth/logout ----------

pub fn logging_out_unbinds_this_browser_and_drops_its_sockets_test() {
  let ctx =
    fakes.ctx()
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(
          ..ctx.auth,
          unbind_guest: fn(id) {
            assert id == "g1"
            Nil
          },
          disconnect: fn(id) {
            assert id == "g1"
            Nil
          },
        ),
      )
    }

  assert handler.logout_json(ctx, fakes.signed_in_guest("g1", "user-uuid"))
    == "{\"ok\":true}"
}

pub fn logging_out_with_no_browser_to_log_out_does_nothing_test() {
  // unbind_guest and disconnect are left panicking.
  assert handler.logout_json(fakes.ctx(), fakes.no_guest()) == "{\"ok\":true}"
}

// ---------- GET /papi/me ----------

pub fn me_names_the_account_this_browser_is_signed_into_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(Some("Renée"))
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: AuthCaps(..ctx.auth, user: fn(id) {
          assert id == "user-uuid"
          Some(User(id: id, email: "her@example.com", name: None))
        }),
      )
    }

  let body = handler.me_json(ctx, fakes.signed_in_guest("g1", "user-uuid"))

  assert string.contains(body, "\"guest_name\":\"Renée\"")
  assert string.contains(body, "\"email\":\"her@example.com\"")
  assert string.contains(body, "\"name\":null")
}

pub fn me_says_no_account_for_a_guest_test() {
  // The user cap is left panicking: a guest's row is never looked up.
  let ctx = fakes.ctx() |> fakes.with_guests(None)
  let body = handler.me_json(ctx, fakes.guest("g1"))

  assert string.contains(body, "\"user\":null")
}

// ---------- `next` ----------

pub fn a_sign_in_can_only_be_aimed_at_this_site_test() {
  // Kept: a local path, and nothing else.
  assert handler.local_path("/backgammon/abc123") == Some("/backgammon/abc123")
  assert handler.where_next(Some("/backgammon/abc123")) == "/backgammon/abc123"

  // Dropped: another origin, a protocol-relative path, a scheme, a bare
  // path, a backslash, and home (which is where nothing means).
  let dropped = [
    "//evil.example.com", "https://evil.example.com/", "backgammon/abc",
    "/back\\slash", "/with space", "javascript:alert(1)", "/",
    // A browser deletes tabs and newlines before it resolves a link, so
    // each of these would resolve as "//evil.example.com": another origin.
    "/\t/evil.example.com", "/\n/evil.example.com", "/\r/evil.example.com",
  ]

  assert list_all(dropped, fn(path) { handler.local_path(path) == None })
  assert handler.where_next(Some("//evil.example.com")) == "/"
  assert handler.where_next(None) == "/"
}

// ---------- Shared ----------

/// Every failed sign-in says the same thing, whatever went wrong.
fn refusal_is_generic(result: Result(String, error.ApiError)) -> Bool {
  case result {
    Error(err) ->
      error.status(err) == 422
      && string.contains(error.message(err), "has expired")
    Ok(_) -> False
  }
}

fn list_all(items: List(a), predicate: fn(a) -> Bool) -> Bool {
  case items {
    [] -> True
    [first, ..rest] ->
      case predicate(first) {
        True -> list_all(rest, predicate)
        False -> False
      }
  }
}
