//// The deck's decisions: what a practice session asks for, and what a
//// refusal says to the player.
////
//// This is the seam between the puzzle pages and the `practice` capability.
//// It holds the rules from the brief that are about the deck rather than
//// about backgammon -- due before new, ten new a day, KEEP GOING uncapped --
//// and turns the cap's refusals into the sentence a player reads. Everything
//// it needs arrives through the Ctx, so it is pure and tested on stubs.

import gleam/option.{None, Some}
import oskol/caps/practice.{
  type Ask, type Graded, type Item, type Outcome, type PracticeError,
  type Session, Ask, CardSuspended, NotAmendable, OutOfOrder, UnknownCard,
}
import oskol/core/ctx.{type Ctx}
import oskol/core/error.{type ApiError}

/// New cards a day, from the brief. Everything due comes first; only then up
/// to this many, newest game first.
pub const new_per_day = 10

/// How many puzzles one page of a session holds.
pub const page = 20

pub const unknown_card_message = "That puzzle is not in your deck."

pub const suspended_message = "You have put that puzzle aside."

pub const out_of_order_message = "That answer arrived out of order."

pub const not_amendable_message = "That answer cannot be changed."

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
pub fn enroll(ctx: Ctx, uid: String, tz: String, items: List(Item)) -> Int {
  ctx.practice.put_user(uid, tz, new_per_day)
  ctx.practice.put_items(uid, items)
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

/// "Not today": push a puzzle out without moving it on the ladder.
pub fn snooze(
  ctx: Ctx,
  uid: String,
  key: String,
  until_ms: Int,
) -> Result(Graded, ApiError) {
  ctx.practice.defer_until(uid, key, until_ms) |> refusal
}

/// The sentence a player reads. A puzzle that is not in their deck is the
/// only one of these that is a 404: the others are things they did.
pub fn message(error: PracticeError) -> String {
  case error {
    UnknownCard -> unknown_card_message
    CardSuspended -> suspended_message
    OutOfOrder -> out_of_order_message
    NotAmendable -> not_amendable_message
  }
}

fn refusal(result: Result(Graded, PracticeError)) -> Result(Graded, ApiError) {
  case result {
    Ok(graded) -> Ok(graded)
    Error(UnknownCard) -> Error(error.NotFound(unknown_card_message))
    Error(other) -> Error(error.validation_failed(message(other)))
  }
}
