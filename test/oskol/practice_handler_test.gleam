//// What the deck decides, on stub capabilities: what a session asks the
//// deck for, what KEEP GOING changes about that, and what each refusal says
//// to the player.
////
//// Every capability the deck does not use still panics (fakes.ctx()), so a
//// change that reaches for IO this layer has no business doing fails loudly.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/caps/practice.{
  type Ask, type Graded, type Item, type PracticeError, Again, BadContent, Card,
  CardNotStarted, CardSuspended, Fail, Graded, Item, New, NotAmendable,
  OutOfOrder, Pass, PracticeCaps, Session, UnknownCard, UnknownTimezone,
}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/practice/deck

/// A deck that answers a queue with these two lists, and records what it was
/// asked for by handing it back in the fresh card's key.
fn with_queue(ctx: Ctx, reviews: Int, fresh: Int) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(..ctx.practice, queue: fn(_uid, ask: Ask) {
      Session(
        reviews: list.map(list.range(1, reviews), fn(n) {
          card("due" <> int(n))
        }),
        fresh: case fresh {
          0 -> []
          _ -> list.map(list.range(1, fresh), fn(n) { card("new" <> int(n)) })
        },
        new_remaining_today: ask.limit,
      )
    }),
  )
}

fn int(n: Int) -> String {
  case n {
    1 -> "1"
    2 -> "2"
    _ -> "n"
  }
}

fn card(key: String) {
  Card(
    key: key,
    tags: [],
    content_json: "{}",
    level: 0,
    due_ms: 0,
    reps: 0,
    lapses: 0,
    status: New,
  )
}

/// A deck whose every answer is this refusal.
fn refusing(ctx: Ctx, error: PracticeError) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(
      ..ctx.practice,
      review: fn(_, _, _) { Error(error) },
      amend: fn(_, _, _, _) { Error(error) },
      defer_until: fn(_, _, _) { Error(error) },
    ),
  )
}

fn graded() -> Graded {
  Graded(level_before: 1, level_after: 2, due_ms: 1000, review_id: 42)
}

pub fn a_session_asks_for_due_first_then_new_test() {
  // The brief: everything due comes first, then at most the day's new cards.
  let ask = deck.daily_ask(0)
  assert ask.new_after_reviews == True
  assert ask.limit == deck.page
  assert ask.offset == 0
  // No cap below the day's budget on the first page.
  assert ask.new_limit == None
}

pub fn keep_going_walks_further_down_and_adds_no_new_cards_test() {
  // KEEP GOING is uncapped for reviews and capped at zero for new material:
  // the day's ten are the day's ten however long the player keeps going.
  let ask = deck.daily_ask(20)
  assert ask.offset == 20
  assert ask.limit == deck.page
  assert ask.new_limit == Some(0)
  assert ask.new_after_reviews == True
}

pub fn the_day_gives_ten_new_cards_test() {
  assert deck.new_per_day == 10
}

pub fn a_session_hands_back_what_the_deck_answered_test() {
  let ctx = fakes.ctx() |> with_queue(2, 1)
  let session = deck.session(ctx, "acct", 0)

  assert list.map(session.reviews, fn(c) { c.key }) == ["due1", "due2"]
  assert list.map(session.fresh, fn(c) { c.key }) == ["new1"]
  assert session.new_remaining_today == deck.page
}

pub fn enrolling_opens_the_deck_before_putting_anything_in_it_test() {
  // put_user must come first: put_items on a deck that does not exist is a
  // 500, and signing in is the first time an account has one at all. The
  // stub's put_items panics unless put_user ran, because it reads what
  // put_user left behind.
  let items = [
    Item(
      key: "pos:a",
      tags: [#("kind", "cube")],
      content_json: "{}",
      position: Some(1),
    ),
  ]

  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        put_user: fn(uid, tz, per_day) {
          assert uid == "acct"
          assert tz == "Europe/Paris"
          assert per_day == deck.new_per_day
          Ok(Nil)
        },
        put_items: fn(uid, given: List(Item)) {
          assert uid == "acct"
          assert list.length(given) == 1
          Ok(1)
        },
      ),
    )

  assert deck.enroll(ctx, "acct", "Europe/Paris", items) == Ok(1)
}

pub fn a_deck_that_cannot_be_opened_is_a_500_not_a_crash_test() {
  // Neither of these can come from a puzzle page -- the timezone and a card's
  // content are ours -- but the cap is the boundary, so they arrive as answers
  // and the player is told nothing they cannot act on.
  let bad_tz =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(..fakes.ctx().practice, put_user: fn(_, _, _) {
        Error(UnknownTimezone)
      }),
    )

  assert deck.enroll(bad_tz, "acct", "Mars/Olympus", [])
    == Error(error.Internal(deck.deck_broken_message))

  let bad_content =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        put_user: fn(_, _, _) { Ok(Nil) },
        put_items: fn(_, _) { Error(BadContent) },
      ),
    )

  assert deck.enroll(bad_content, "acct", "Etc/UTC", [])
    == Error(error.Internal(deck.deck_broken_message))
}

pub fn nothing_is_put_in_a_deck_that_could_not_be_opened_test() {
  // put_items must not run when put_user failed: the stub panics if it does.
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(..fakes.ctx().practice, put_user: fn(_, _, _) {
        Error(UnknownTimezone)
      }),
    )

  assert deck.enroll(ctx, "acct", "Mars/Olympus", []) |> result.is_error
}

pub fn snoozing_a_card_not_in_rotation_says_so_test() {
  // A defer on a card that has never been started would move a date nothing
  // reads and then be overwritten the moment it is started, so the deck
  // refuses it rather than pretending.
  let ctx = fakes.ctx() |> refusing(CardNotStarted)

  assert deck.snooze(ctx, "acct", "pos:a", 1000)
    == Error(error.validation_failed(deck.not_started_message))
}

pub fn an_answer_that_lands_comes_back_graded_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        review: fn(uid, key, outcome) {
          assert uid == "acct"
          assert key == "pos:a"
          assert outcome == Again
          Ok(graded())
        },
      ),
    )

  assert deck.answer(ctx, "acct", "pos:a", Again) == Ok(graded())
}

pub fn a_puzzle_not_in_the_deck_is_the_only_refusal_that_is_a_404_test() {
  let ctx = fakes.ctx() |> refusing(UnknownCard)

  assert deck.answer(ctx, "acct", "pos:a", Pass)
    == Error(error.NotFound(deck.unknown_card_message))
  assert deck.correct(ctx, "acct", "pos:a", 1, Pass)
    == Error(error.NotFound(deck.unknown_card_message))
  assert deck.snooze(ctx, "acct", "pos:a", 1000)
    == Error(error.NotFound(deck.unknown_card_message))
}

pub fn the_refusals_a_player_caused_are_422_with_their_own_sentence_test() {
  // Each says what happened, and none of them leaks that a deck is a Leitner
  // ladder in a library.
  let suspended = fakes.ctx() |> refusing(CardSuspended)
  assert deck.answer(suspended, "acct", "pos:a", Fail)
    == Error(error.validation_failed(deck.suspended_message))

  let late = fakes.ctx() |> refusing(OutOfOrder)
  assert deck.answer(late, "acct", "pos:a", Fail)
    == Error(error.validation_failed(deck.out_of_order_message))

  let fixed = fakes.ctx() |> refusing(NotAmendable)
  assert deck.correct(fixed, "acct", "pos:a", 7, Pass)
    == Error(error.validation_failed(deck.not_amendable_message))
}

pub fn every_refusal_has_a_sentence_and_they_are_all_different_test() {
  // The five a player can cause each say something different; the two that
  // are our fault deliberately share one sentence that admits nothing.
  let sentences =
    [UnknownCard, CardSuspended, CardNotStarted, OutOfOrder, NotAmendable]
    |> list.map(deck.message)

  assert list.length(list.unique(sentences)) == 5
  assert list.all(sentences, fn(s) { s != "" })
  assert deck.message(UnknownTimezone) == deck.message(BadContent)
}

pub fn correcting_names_the_row_it_corrects_test() {
  // The review id from the answer is what the override sends back, which is
  // the whole reason `Graded` carries one.
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        amend: fn(_uid, _key, review_id, outcome) {
          assert review_id == 42
          assert outcome == Pass
          Ok(Graded(..graded(), level_after: 3))
        },
      ),
    )

  let assert Ok(after) =
    deck.correct(ctx, "acct", "pos:a", graded().review_id, Pass)
  assert after.level_after == 3
}

pub fn snoozing_passes_the_date_through_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        defer_until: fn(_uid, _key, until_ms) {
          assert until_ms == 1_800_000_000_000
          Ok(graded())
        },
      ),
    )

  assert deck.snooze(ctx, "acct", "pos:a", 1_800_000_000_000) == Ok(graded())
}
