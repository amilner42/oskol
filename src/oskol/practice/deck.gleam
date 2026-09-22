//// The deck's decisions: what a practice session asks for, and what a
//// refusal says to the player.
////
//// This is the seam between the puzzle pages and the `practice` capability.
//// It holds the rules from the brief that are about the deck rather than
//// about backgammon -- due before new, ten new a day, KEEP GOING uncapped --
//// and turns the cap's refusals into the sentence a player reads. Everything
//// it needs arrives through the Ctx, so it is pure and tested on stubs.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/practice.{
  type Ask, type Graded, type Item, type Outcome, type PracticeError,
  type Session, Ask, BadContent, CardNotStarted, CardSuspended, NotAmendable,
  OutOfOrder, UnknownCard, UnknownTimezone,
}
import oskol/core/ctx.{type Ctx}
import oskol/core/error.{type ApiError}

/// New cards a day, from the brief. Everything due comes first; only then up
/// to this many, newest game first.
pub const new_per_day = 10

/// How many puzzles one page of a session holds.
pub const page = 20

/// How many new puzzles KEEP GOING puts into rotation, each time it is
/// pressed. The brief caps the day for the player who takes what they are
/// given; it never caps the one who asks for more.
pub const keep_going_new = 10

/// What a deck runs on until its owner's browser says otherwise. Every
/// "due today" and every "tomorrow" is read in this zone, so the answer to
/// "is this due?" is the site's day and not the player's until then.
pub const default_timezone = "Etc/UTC"

pub const unknown_timezone_message = "We do not know that timezone."

pub const not_in_rotation_message = "That puzzle is not in your rotation, so there is nothing to put off."

pub const unknown_card_message = "That puzzle is not in your deck."

pub const suspended_message = "You have put that puzzle aside."

pub const out_of_order_message = "That answer arrived out of order."

pub const not_amendable_message = "That answer cannot be changed."

pub const not_started_message = "You have not started that puzzle yet."

/// Ours, not theirs: a deck opened with a bad timezone or a card offered with
/// content that is not an object. The player is told nothing useful because
/// there is nothing they can do about it.
pub const deck_broken_message = "Your deck is not available right now."

/// What a normal session asks for: everything due first, then new material.
///
/// `offset` is what KEEP GOING moves: the brief caps the day's *new* cards,
/// never the reviews, so a player who wants to keep going walks further down
/// the same due ordering and is given no more new ones.
pub fn daily_ask(offset: Int) -> Ask {
  Ask(
    tags: [],
    limit: page,
    offset: offset,
    new_after_reviews: True,
    new_limit: case offset {
      0 -> None
      _ -> Some(0)
    },
  )
}

/// Make sure the account has a deck and put these puzzles in it. Returns how
/// many were new: re-adding a game's mistakes is safe, so this is also what
/// signing in does with the games a browser brought along.
pub fn enroll(
  ctx: Ctx,
  uid: String,
  tz: String,
  items: List(Item),
) -> Result(Int, ApiError) {
  case ctx.practice.put_user(uid, tz, new_per_day) {
    Ok(Nil) -> ctx.practice.put_items(uid, items) |> refusal
    Error(error) -> Error(api_error(error))
  }
}

/// A session's worth of work for this account.
pub fn session(ctx: Ctx, uid: String, offset: Int) -> Session {
  ctx.practice.queue(uid, daily_ask(offset))
}

/// Grade an answer. The caller has already decided this attempt counts (the
/// first answer at a due puzzle, and no retry): the deck only records it.
pub fn answer(
  ctx: Ctx,
  uid: String,
  key: String,
  outcome: Outcome,
) -> Result(Graded, ApiError) {
  ctx.practice.review(uid, key, outcome) |> refusal
}

/// The override after the reveal: the player says the grade was wrong. The
/// log stays append-only; the correction supersedes the row it names.
pub fn correct(
  ctx: Ctx,
  uid: String,
  key: String,
  review_id: Int,
  outcome: Outcome,
) -> Result(Graded, ApiError) {
  ctx.practice.amend(uid, key, review_id, outcome) |> refusal
}

/// KEEP GOING: put more new puzzles into rotation, over today's budget,
/// and say how many moved. The caller fetches the session again after.
pub fn keep_going(ctx: Ctx, uid: String) -> Int {
  ctx.practice.start_new(uid, keep_going_new)
}

// ---------- Where the player is ----------

/// The browser has told us its timezone. Written once, on the deck itself,
/// which is the only thing that reads it -- "due today" and "back
/// tomorrow" are both that player's own day.
///
/// The shape is checked here and the name itself by the deck, which has
/// the zone database: an unknown one is the player's browser being wrong
/// about itself, so it is a refusal they can read and not a 500.
pub fn set_timezone(ctx: Ctx, uid: String, tz: String) -> Result(Nil, ApiError) {
  case valid_timezone(tz) {
    False -> Error(error.validation_failed(unknown_timezone_message))
    True ->
      case ctx.practice.put_user(uid, tz, new_per_day) {
        Ok(Nil) -> Ok(Nil)
        Error(UnknownTimezone) ->
          Error(error.validation_failed(unknown_timezone_message))
        Error(other) -> Error(api_error(other))
      }
  }
}

/// Does this look like an IANA zone name? "Europe/Paris",
/// "America/Argentina/Buenos_Aires", "UTC".
///
/// Shape only: one to three segments of letters, digits, `_`, `+` or `-`,
/// each starting with a letter, and nothing long enough to be an attack.
/// Whether the name is one the world actually has is the zone database's
/// answer, not a list kept here that would go stale every time a country
/// changes its mind.
pub fn valid_timezone(tz: String) -> Bool {
  let parts = string.split(tz, "/")
  let count = list.length(parts)
  string.length(tz) <= 64
  && count >= 1
  && count <= 3
  && list.all(parts, segment)
}

fn segment(part: String) -> Bool {
  case string.to_graphemes(part) {
    [] -> False
    [first, ..rest] ->
      letter(first) && list.all(rest, fn(c) { letter(c) || extra(c) })
  }
}

fn letter(c: String) -> Bool {
  string.length(c) == 1
  && string.contains(
    does: "abcdefghijklmnopqrstuvwxyz",
    contain: string.lowercase(c),
  )
}

fn extra(c: String) -> Bool {
  string.length(c) == 1 && string.contains(does: "0123456789_+-", contain: c)
}

// ---------- Putting one off ----------

/// Bury a puzzle: it comes back at the start of the player's tomorrow, at
/// the level it already had.
///
/// This is what happens to an answer the engine could not grade and the
/// player did not grade either. It cannot simply be left alone: a due card
/// nobody ever answers sits at the front of the queue for ever, in front
/// of every new one.
///
/// A puzzle that is not in rotation is not a refusal of anything the
/// player typed -- it is a session that has moved on -- so it answers 409
/// rather than 422.
pub fn bury(ctx: Ctx, uid: String, key: String) -> Result(Graded, ApiError) {
  case ctx.practice.defer_tomorrow(uid, key) {
    Ok(graded) -> Ok(graded)
    Error(CardNotStarted) ->
      Error(error.Conflict("not_in_rotation", not_in_rotation_message))
    Error(other) -> Error(api_error(other))
  }
}

/// "Not today": push a puzzle out without moving it on the ladder.
pub fn snooze(
  ctx: Ctx,
  uid: String,
  key: String,
  until_ms: Int,
) -> Result(Graded, ApiError) {
  ctx.practice.defer_until(uid, key, until_ms) |> refusal
}

/// The sentence a player reads.
pub fn message(error: PracticeError) -> String {
  case error {
    UnknownCard -> unknown_card_message
    CardSuspended -> suspended_message
    CardNotStarted -> not_started_message
    OutOfOrder -> out_of_order_message
    NotAmendable -> not_amendable_message
    UnknownTimezone | BadContent -> deck_broken_message
  }
}

/// A puzzle that is not in the deck is the only 404. The things the player
/// did are 422s with their own sentence; the two that are our fault are 500s,
/// answered on purpose rather than by crashing on the way out.
fn api_error(error: PracticeError) -> ApiError {
  case error {
    UnknownCard -> error.NotFound(unknown_card_message)
    UnknownTimezone | BadContent -> error.Internal(deck_broken_message)
    other -> error.validation_failed(message(other))
  }
}

fn refusal(result: Result(a, PracticeError)) -> Result(a, ApiError) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(api_error(error))
  }
}
