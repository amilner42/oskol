//// The deck's decisions: what a practice session asks for, and what a
//// refusal says to the player.
////
//// This is the seam between the puzzle pages and the `practice` capability.
//// It holds the rules from the brief that are about the deck rather than
//// about backgammon -- due before new, three new a day worst first, what
//// counts as patched, KEEP GOING uncapped --
//// and turns the cap's refusals into the sentence a player reads. Everything
//// it needs arrives through the Ctx, so it is pure and tested on stubs.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/practice.{
  type Ask, type Graded, type Item, type Outcome, type PracticeError,
  type Session, type Severity, Ask, BadContent, CardNotStarted, CardSuspended,
  DeckUnavailable, NotAmendable, OutOfOrder, Severity, UnknownCard,
  UnknownTimezone,
}
import oskol/core/ctx.{type Ctx}
import oskol/core/error.{type ApiError}

/// New cards a day. Everything due comes first; only then up to this many,
/// **worst first** (`practice/sync.position_of`).
///
/// Three, not ten. A deck is made of the player's own mistakes, and the
/// work that moves a player is answering the ones they already have again
/// -- three new positions a day is a pace a person keeps, where ten is a
/// queue that grows faster than it is patched. KEEP GOING is still
/// uncapped for whoever wants more.
pub const new_per_day = 3

/// The rung at which a mistake counts as **patched**.
///
/// The ladder's intervals are [1, 1, 3, 7, 21, 58, 145, 365] days, so a
/// card at level 4 has been answered right four times running and is not
/// due again for three weeks: a mistake you have genuinely stopped
/// making, rather than one you happened to get right this morning. This
/// is the only place the number lives -- the page is told it.
pub const patched_level = 4

/// The bands a deck is counted in, worst first: the site's own grades,
/// which is what `puzzle_sources.grade` already holds. A mistake is at
/// worst 0.16 equity lost (very bad), 0.08 (bad) or 0.02 (dubious); below
/// that it is not a mistake and never becomes a card.
pub const bands = ["very_bad", "bad", "doubtful"]

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

/// What a session asks for: everything due first, then new material once
/// nothing is due, a page at a time.
///
/// **Always from the beginning.** The due ordering is live -- answering a
/// card takes it out of the set -- so a second page at an offset would
/// skip exactly as many cards as the player had just answered, and a
/// session of 21 would end after 20 with one unseen and every new card
/// never offered. A page is always the front of the queue, and what the
/// player has answered is gone from it by itself.
pub fn daily_ask() -> Ask {
  Ask(
    tags: [],
    limit: page,
    offset: 0,
    new_after_reviews: True,
    new_limit: None,
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
  enroll_items(ctx, uid, tz, items) |> refusal
}

/// The same, keeping the deck's own refusal rather than the sentence a
/// player would read. The sync writes the reason onto the rows it could
/// not place, and "your deck is not available right now" is no use to the
/// operator who has to go and look.
pub fn enroll_items(
  ctx: Ctx,
  uid: String,
  tz: String,
  items: List(Item),
) -> Result(Int, PracticeError) {
  case ctx.practice.put_user(uid, tz, new_per_day) {
    Ok(Nil) -> ctx.practice.put_items(uid, items)
    Error(error) -> Error(error)
  }
}

/// A session's worth of work for this account: the front of the queue.
pub fn session(ctx: Ctx, uid: String) -> Session {
  ctx.practice.queue(uid, daily_ask())
}

/// One tier's worth: the mistakes of that grade alone, due first and
/// then ones never seen, worst first inside the band. What FIX ONE runs.
///
/// A page at a time, and always from the front, for the same reason
/// `daily_ask` is: the due set is live, so an offset would skip exactly
/// as many as the player had just answered.
pub fn band_session(ctx: Ctx, uid: String, band: String) -> Session {
  ctx.practice.band_queue(uid, band, page)
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

// ---------- Today ----------

/// The day's work: how many answers this account has recorded in its own
/// local day. A plain count, with nothing to measure it against.
///
/// **There is no target.** A day used to ask for ten and draw a ring
/// round how much of them was done, which read as a quota and put a
/// player off starting at all. Practice asks for one mistake at a time
/// now, so the day says only what has happened: "3 fixed today". The
/// streak is the days; this is today.
pub type Today {
  Today(done: Int)
}

pub fn today(ctx: Ctx, uid: String) -> Today {
  Today(done: ctx.practice.day(uid).answered)
}

/// One shape, on every endpoint that carries it (`/papi/practice`, a
/// game's own list, and the home's practice block), so the client has one
/// decoder and the count cannot mean two things.
pub fn today_json(today: Today) -> Json {
  json.object([#("done", json.int(today.done))])
}

// ---------- How much of the deck is patched ----------

/// The deck counted by how bad the mistake was, worst band first, with
/// every band named even when it is empty: the page's three lines are the
/// three bands, and a band that has gone quiet must read "0 of 0" rather
/// than disappear and shift the two beside it.
///
/// Each band comes in three states -- untouched, in progress, patched --
/// because patched is level 4, which is four right answers over twelve
/// days at the very earliest. A player halfway through fifty of their
/// mistakes is working, and a page that can only say "0 patched" tells
/// them nothing is happening.
pub fn severity(ctx: Ctx, uid: String) -> List(Severity) {
  let rows = ctx.practice.severity(uid, patched_level)
  list.map(bands, fn(band) {
    case list.find(rows, fn(row) { row.grade == band }) {
      Ok(row) -> row
      Error(Nil) ->
        Severity(
          grade: band,
          total: 0,
          in_progress: 0,
          patched: 0,
          due: 0,
          fresh: 0,
        )
    }
  })
}

pub fn severity_json(band: Severity) -> Json {
  json.object([
    #("grade", json.string(band.grade)),
    #("total", json.int(band.total)),
    #("in_progress", json.int(band.in_progress)),
    #("patched", json.int(band.patched)),
    // What the tier has to do right now: what is due, and how many of the
    // ones it has never shown the day still allows.
    #("due", json.int(band.due)),
    #("new_left", json.int(band.fresh)),
  ])
}

// ---------- Which tier is in front of you ----------

/// The deck as the practice hub reads it: one tier per band, worst
/// first, each knowing whether it still has work today.
///
/// A tier **has work** when something of it is due, or when it has a
/// mistake the player has never seen and the day's budget of new ones
/// has not been spent. The budget is the deck's, not the band's -- three
/// new a day across the whole deck -- so it is folded in here, once,
/// rather than by each page that asks.
pub fn tiers(ctx: Ctx, uid: String) -> List(Severity) {
  let budget = ctx.practice.day(uid).new_remaining
  list.map(severity(ctx, uid), fn(band) {
    Severity(..band, fresh: int.min(band.fresh, int.max(budget, 0)))
  })
}

/// Does this tier still have something to fix today?
pub fn has_work(band: Severity) -> Bool {
  band.due > 0 || band.fresh > 0
}

/// How many of a tier are still to fix: everything that is not patched.
/// The number the hub leads with, because it is what is left of the
/// worst of your play -- not what is due, which changes hour to hour.
pub fn left(band: Severity) -> Int {
  int.max(band.total - band.patched, 0)
}

/// The tier to put in front of the player: the **worst band that still
/// has work**. When none of them has any, the worst band they have made
/// a mistake in at all, so the page can say that one is in good shape
/// rather than go blank. Nothing at all when the deck is empty.
pub fn lead(bands: List(Severity)) -> option.Option(String) {
  let with_work = list.filter(bands, has_work)
  let any = list.filter(bands, fn(band) { band.total > 0 })
  case list.first(with_work), list.first(any) {
    Ok(band), _ -> Some(band.grade)
    _, Ok(band) -> Some(band.grade)
    _, _ -> None
  }
}

/// Is this one of the three bands a deck is counted in? A band the
/// client asked for that is not is a refusal, never a queue of
/// everything: a page must not be able to widen its own question.
pub fn known_band(grade: String) -> Bool {
  list.contains(bands, grade)
}

pub const unknown_band_message = "That is not one of your mistake tiers."

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
    UnknownTimezone | BadContent | DeckUnavailable(_) -> deck_broken_message
  }
}

/// What goes on the row an operator will read, which is not what goes on
/// the page a player reads: a deck that could not be reached says how.
pub fn reason(error: PracticeError) -> String {
  case error {
    DeckUnavailable(reason) -> reason
    other -> message(other)
  }
}

/// A puzzle that is not in the deck is the only 404. The things the player
/// did are 422s with their own sentence; the two that are our fault are 500s,
/// answered on purpose rather than by crashing on the way out.
fn api_error(error: PracticeError) -> ApiError {
  case error {
    UnknownCard -> error.NotFound(unknown_card_message)
    UnknownTimezone | BadContent | DeckUnavailable(_) ->
      error.Internal(deck_broken_message)
    other -> error.validation_failed(message(other))
  }
}

fn refusal(result: Result(a, PracticeError)) -> Result(a, ApiError) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(api_error(error))
  }
}
