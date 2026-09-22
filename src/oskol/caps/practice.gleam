//// The puzzle deck: what a player is drilling, what is due, and how each
//// attempt went. Behind it is the `retain` library (a Leitner ladder over an
//// append-only review log, in our own Postgres), but nothing above this file
//// knows that. Built for real in lib/oskol/gleam/caps/practice.ex -- that
//// file and this one must agree on constructor tags and field order.
////
//// The deck belongs to an **account**. A guest practises everything an
//// account can, but nothing is remembered for them, so a handler only
//// reaches these capabilities once it has a user id.
////
//// Two things the deck deliberately does not decide:
////
////   * **Whether an answer counts.** The deck does not check that a card was
////     due and cannot tell a first answer from a retry -- every `review` is
////     another row in the log. Only the first answer at a due puzzle moves
////     the ladder, and it is the caller that knows which one that is (the
////     attempt row); by the time it calls `review`, the decision is made.
////   * **What a grade is.** Equity lost becomes `Pass`, `Partial` or `Fail`
////     in the puzzle's own rules, not here.

import gleam/option.{type Option}

/// How an attempt went, as the ladder reads it.
///
/// `Fail` gives back one step of spacing; `Again` gives back all of it and
/// the card returns tomorrow whatever level it had -- which is what the brief
/// means by "a miss goes back to the start". `Known` is "I already knew this"
/// and jumps to the top.
pub type Outcome {
  Pass
  Partial
  Fail
  Again
  Known
}

/// Where a card stands in the rotation.
pub type Status {
  /// In the deck but never introduced.
  New
  /// In rotation.
  Active
  /// Paused: out of the queue until resumed.
  Suspended
}

/// Something to drill, as the host describes it when putting it in the deck.
/// `key` is ours and identifies the puzzle; `tags` filter and group;
/// `content_json` is opaque -- the deck stores it and never looks inside.
pub type Item {
  Item(
    key: String,
    /// Sorted by key, so the same item always crosses the same way.
    tags: List(#(String, String)),
    content_json: String,
    /// The order to introduce new cards in; None leaves it to creation order.
    position: Option(Int),
  )
}

/// A card in the deck, with where it stands on the ladder.
pub type Card {
  Card(
    key: String,
    tags: List(#(String, String)),
    content_json: String,
    /// 0..7.
    level: Int,
    /// When it is next due, in Unix milliseconds.
    due_ms: Int,
    /// Attempts so far.
    reps: Int,
    /// How many of those were a miss.
    lapses: Int,
    status: Status,
  )
}

/// What to put in front of the player now.
pub type Session {
  Session(
    /// Cards that are due, weakest and most overdue first.
    reviews: List(Card),
    /// Cards never seen before, within today's budget.
    fresh: List(Card),
    /// How much of today's new-card budget was left before this call.
    new_remaining_today: Int,
  )
}

/// What to ask for. `offset` walks further down the same ordering, which is
/// what KEEP GOING does once the first page is done.
pub type Ask {
  Ask(
    tags: List(#(String, String)),
    limit: Int,
    offset: Int,
    /// Hold new cards back until nothing is due.
    new_after_reviews: Bool,
    /// Cap the new cards below the day's budget; None takes the budget.
    new_limit: Option(Int),
  )
}

/// What one attempt did to a card. `review_id` names the row it wrote, which
/// is what `amend` needs to correct it afterwards.
pub type Graded {
  Graded(level_before: Int, level_after: Int, due_ms: Int, review_id: Int)
}

/// Aggregates over a slice of the deck, grouped by tag values.
pub type Summary {
  Summary(
    /// The grouping tag values, sorted by key; empty when not grouped.
    group: List(#(String, String)),
    count: Int,
    new_count: Int,
    active_count: Int,
    suspended_count: Int,
    due_count: Int,
    mean_level: Float,
  )
}

/// A refusal, rather than a crash.
///
/// The first four are things a player did and must be told about. The last two cannot happen
/// from the pages as they stand -- the timezone and a card's content are ours, not theirs --
/// but this is the boundary, so they cross as answers rather than as a `MatchError` on the way
/// out. A handler still turns them into a 500: they are our bug, not the player's.
pub type PracticeError {
  /// No such card in this player's deck.
  UnknownCard
  /// The card is paused: it cannot be answered until it is resumed.
  CardSuspended
  /// The card has not been put into rotation yet, so there is no schedule to move.
  CardNotStarted
  /// The attempt is older than the card's newest log entry.
  OutOfOrder
  /// That row cannot be corrected (it is not an attempt).
  NotAmendable
  /// The deck was opened with something that is not an IANA timezone name.
  UnknownTimezone
  /// A card was offered with content that is not a JSON object.
  BadContent
}

pub type PracticeCaps {
  PracticeCaps(
    /// Make sure this account has a deck, with their timezone and how many
    /// new cards a day they get. Idempotent; it is the first call of any
    /// practice session.
    put_user: fn(String, String, Int) -> Result(Nil, PracticeError),
    /// Add cards. Keys already in the deck are left exactly as they are, so
    /// re-adding a game's mistakes is safe. Returns how many were new.
    put_items: fn(String, List(Item)) -> Result(Int, PracticeError),
    /// A session's worth of work.
    queue: fn(String, Ask) -> Session,
    /// Put named new cards into rotation now. Returns how many moved.
    start: fn(String, List(String)) -> Int,
    /// Record an attempt and move the card.
    review: fn(String, String, Outcome) -> Result(Graded, PracticeError),
    /// Correct an earlier attempt: the row stays, a new one supersedes it,
    /// and the card is re-derived as if the correction had been the answer
    /// all along. This is the Anki-style override after the reveal.
    amend: fn(String, String, Int, Outcome) -> Result(Graded, PracticeError),
    /// Push a card's due date out without touching its level ("not today").
    /// The date is Unix milliseconds. The card has to be in rotation: there
    /// is nothing to move on one that has never been started, and starting
    /// it later would overwrite the date anyway.
    defer_until: fn(String, String, Int) -> Result(Graded, PracticeError),
    /// "I already know these": each jumps to the top level. Recorded in the
    /// log, so it survives a rebuild. Returns how many moved.
    master: fn(String, List(String)) -> Int,
    /// Pause cards: they leave the queue until resumed. Returns how many.
    suspend: fn(String, List(String)) -> Int,
    /// Un-pause them, at exactly the level they were paused at.
    resume: fn(String, List(String)) -> Int,
    /// Aggregates over the deck, grouped by the given tag keys.
    summary: fn(String, List(String)) -> List(Summary),
    /// The card this account holds for one key, if their deck holds it at
    /// all: (user id, key). Creates nothing and moves nothing -- it is what
    /// an attempt asks before it decides whether anything is at stake.
    card: fn(String, String) -> Option(Card),
  )
}

pub fn stub() -> PracticeCaps {
  PracticeCaps(
    put_user: fn(_, _, _) { panic as "stub practice.put_user" },
    put_items: fn(_, _) { panic as "stub practice.put_items" },
    queue: fn(_, _) { panic as "stub practice.queue" },
    start: fn(_, _) { panic as "stub practice.start" },
    review: fn(_, _, _) { panic as "stub practice.review" },
    amend: fn(_, _, _, _) { panic as "stub practice.amend" },
    defer_until: fn(_, _, _) { panic as "stub practice.defer_until" },
    master: fn(_, _) { panic as "stub practice.master" },
    suspend: fn(_, _) { panic as "stub practice.suspend" },
    resume: fn(_, _) { panic as "stub practice.resume" },
    summary: fn(_, _) { panic as "stub practice.summary" },
    card: fn(_, _) { panic as "stub practice.card" },
  )
}
