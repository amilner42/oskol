//// A practice session: what to put in front of the player next.
////
////   GET  /papi/practice              the session
////   POST /papi/practice/more       KEEP GOING: more new ones, then the session
////   POST /papi/practice/tz         {tz} -- where this browser is
////   POST /papi/practice/bury       {id} -- back tomorrow, level kept
////
//// One endpoint answers three kinds of caller, because the page is the
//// same page for all three:
////
////   * an **account** gets its deck -- everything due first, then new
////     material once nothing is due, twenty at a time. Every fetch is the
////     front of the queue: the due set is live, so what the player has
////     just answered has left it, and a page taken at an offset would
////     skip exactly as many cards as they had answered.
////   * a **guest** gets the mistakes on the seats their cookie holds,
////     newest game first. No schedule, no counts, and nothing written:
////     only an account has a deck, and a guest who never signs in loses
////     nothing they were promised.
////   * **nobody** -- a stranger with no games behind them -- gets an
////     empty list. Not an error: there is nothing wrong with having
////     nothing to practice yet.
////
//// Reading a session never starts a card and never spends a day's budget.
//// A new card is not due until it is first seen, and it is answering one
//// that starts it, so a page that is merely opened twice costs nothing.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/practice.{type Card, type Session as DeckSession, type Summary}
import oskol/caps/puzzles.{type DeckSource} as _
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session, Session}
import oskol/practice/deck
import oskol/practice/sync
import oskol/puzzles
import oskol/rooms/seat

/// The session: what to put in front of the player right now. There is no
/// page after it -- when they have answered these, they ask again.
pub fn practice_json(ctx: Ctx, session: Session) -> Result(String, ApiError) {
  case session.user_id, session.guest_id {
    Some(uid), _ -> Ok(account_session(ctx, uid))
    None, Some(guest_id) -> Ok(guest_session(ctx, guest_id))
    None, None -> Ok(empty())
  }
}

/// KEEP GOING: put ten more new puzzles into rotation and answer the
/// session that results, so the page needs one call and not two.
///
/// Only an account has a rotation to add to. For a guest the page already
/// holds every mistake they have, so this is the next page of it and
/// nothing else -- and, as everywhere a guest practices, it writes nothing.
pub fn more_json(ctx: Ctx, session: Session) -> Result(String, ApiError) {
  case session.user_id {
    Some(uid) -> {
      let _ = deck.keep_going(ctx, uid)
      // From the front again: the cards that were just started are due
      // now, so they are exactly what the next page is.
      Ok(account_session(ctx, uid))
    }
    None -> practice_json(ctx, session)
  }
}

/// Where this browser is, for "due today" and "back tomorrow". Signed in
/// only: a guest has no deck, so there is no day of theirs to keep.
pub fn timezone_json(
  ctx: Ctx,
  session: Session,
  tz: String,
) -> Result(String, ApiError) {
  use uid <- result.try(signed_in(session))
  use Nil <- result.try(deck.set_timezone(ctx, uid, tz))
  Ok(envelope.ok([#("tz", json.string(tz))]))
}

/// Put a puzzle off until tomorrow: the session moved on without an answer
/// anybody could grade, so it must not stay at the front of the queue.
pub fn bury_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use uid <- result.try(signed_in(session))
  use graded <- result.try(deck.bury(ctx, uid, id))
  Ok(
    envelope.ok([
      #("id", json.string(id)),
      #("level", json.int(graded.level_after)),
      #("due", json.int(graded.due_ms)),
    ]),
  )
}

/// A guest has no deck, so there is nothing of theirs to write to. The
/// page never offers these two to one, so this is a bug rather than
/// something a player can do, and it says as little as the seat rules do.
fn signed_in(session: Session) -> Result(String, ApiError) {
  case session.user_id {
    Some(uid) -> Ok(uid)
    None ->
      Error(error.Conflict("not_in_rotation", deck.not_in_rotation_message))
  }
}

// ---------- An account's session ----------

fn account_session(ctx: Ctx, uid: String) -> String {
  let found = deck.session(ctx, uid)
  let entries =
    list.append(cards(found.reviews, True), cards(found.fresh, False))
  // One read of the deck's totals, for both the counts the page prints
  // and the day's ring: two reads could not disagree by much, but they
  // could disagree, and the ring is drawn beside the number it is made of.
  let summary =
    ctx.practice.summary(uid, []) |> list.first |> option.from_result
  body(
    entries,
    Some(counts(summary, found)),
    None,
    Some(deck.today_json(deck.today(ctx, uid, due_of(summary)))),
    // The three lines the practice home leads with: how many mistakes of
    // each severity this player has made, and how many they have patched.
    Some(
      json.preprocessed_array(list.map(
        deck.severity(ctx, uid),
        deck.severity_json,
      )),
    ),
  )
}

fn due_of(summary: Option(Summary)) -> Int {
  case summary {
    Some(row) -> row.due_count
    None -> 0
  }
}

fn cards(items: List(Card), due: Bool) -> List(Json) {
  list.map(items, fn(card) {
    entry(card.key, kind_of(card), card.content_json, due)
  })
}

/// A card's kind, off the tag it was enrolled with. A card written by an
/// older sync without one still has its question, which names it too.
fn kind_of(card: Card) -> String {
  case list.key_find(card.tags, sync.kind_tag_key) {
    Ok(kind) -> kind
    Error(Nil) -> ""
  }
}

/// What a page prints beside the queue: how many are due, how much of
/// today's new budget is left, how many new ones tomorrow will bring (the
/// day's budget, or the cards never seen when there are fewer of those),
/// and how big the deck is altogether.
fn counts(summary: Option(Summary), found: DeckSession) -> Json {
  json.object([
    #(
      "due",
      json.int(case summary {
        Some(row) -> row.due_count
        None -> 0
      }),
    ),
    #("new_today", json.int(found.new_remaining_today)),
    #(
      "new_tomorrow",
      json.int(case summary {
        Some(row) -> int.min(row.new_count, deck.new_per_day)
        None -> 0
      }),
    ),
    #(
      "deck",
      json.int(case summary {
        Some(row) -> row.count
        None -> 0
      }),
    ),
  ])
}

// ---------- A guest's session ----------

/// The mistakes on the seats this cookie holds, newest game first.
///
/// The query narrows by the guest id; the holder rule says which of the
/// rows that came back are really this browser's, which is what keeps an
/// owned seat out of it -- a browser that logged out, or the next person
/// on the same laptop, is offered nothing of the account's.
fn guest_session(ctx: Ctx, guest_id: String) -> String {
  let mine =
    ctx.puzzles.guest_sources(guest_id)
    |> list.filter(fn(source) {
      seat.holder(source.seat, Session(guest_id: Some(guest_id), user_id: None))
    })
    |> dedupe([], [])
  let page = list.take(mine, deck.page)
  body(
    list.map(page, fn(source) {
      entry(source.puzzle_id, source.kind, source.question_json, False)
    }),
    None,
    Some(mistakes(mine)),
    // No deck, so no day of theirs to count and nothing patched: a guest
    // is never shown a goal they are not being held to, or progress
    // against mistakes nothing is keeping for them.
    None,
    None,
  )
}

/// What the home says a guest has behind them: "23 mistakes from your 4
/// games". Counted over everything that is theirs, not the page.
fn mistakes(mine: List(DeckSource)) -> Json {
  let games =
    mine
    |> list.map(fn(source) { source.game_id })
    |> list.unique
    |> list.length
  json.object([
    #("puzzles", json.int(list.length(mine))),
    #("games", json.int(games)),
  ])
}

/// One card per puzzle, keeping the first (and so the newest): the same
/// position reached in two games is one mistake to practice, not two.
fn dedupe(
  sources: List(DeckSource),
  seen: List(String),
  kept: List(DeckSource),
) -> List(DeckSource) {
  case sources {
    [] -> list.reverse(kept)
    [source, ..rest] ->
      case list.contains(seen, source.puzzle_id) {
        True -> dedupe(rest, seen, kept)
        False -> dedupe(rest, [source.puzzle_id, ..seen], [source, ..kept])
      }
  }
}

// ---------- The shape on the wire ----------

fn body(
  entries: List(Json),
  counts: Option(Json),
  mistakes: Option(Json),
  today: Option(Json),
  severity: Option(Json),
) -> String {
  envelope.ok([
    #("puzzles", json.preprocessed_array(entries)),
    // Always null. A session is not paged: the client asks again and gets
    // the front of the queue, which is what is left. The field stays
    // because the wire has it and a client may still be reading it.
    #("cursor", json.null()),
    #("counts", option.unwrap(counts, json.null())),
    // A guest's: how many mistakes are theirs and from how many games.
    // Null for an account (`counts` says it) and for nobody.
    #("mistakes", option.unwrap(mistakes, json.null())),
    // The day's ring: what this account has answered today against the
    // day's work. An account's and only an account's, like `counts`.
    #("today", option.unwrap(today, json.null())),
    // The deck by how bad the mistake was, worst band first, with how
    // much of each is patched, and the rung that means patched.
    #("severity", option.unwrap(severity, json.null())),
    #("patched_level", json.int(deck.patched_level)),
    // This endpoint is never one game's mistakes; the per-game list is its
    // own route and names the game it answered for.
    #("game", json.null()),
  ])
}

fn empty() -> String {
  body([], None, None, None, None)
}

/// One puzzle as a session lists it: what it is and what it asks. The
/// sentence is written from the stored question every time rather than
/// copied when the card was made, so a change to the words reaches every
/// deck at once.
fn entry(id: String, kind: String, question_json: String, due: Bool) -> Json {
  json.object([
    #("id", json.string(id)),
    #("kind", json.string(kind)),
    #("prompt", json.string(prompt(question_json))),
    #("due", json.bool(due)),
  ])
}

fn prompt(question_json: String) -> String {
  case puzzles.question_from_json(question_json) {
    Ok(question) -> puzzles.prompt(question)
    // A card whose question no longer reads as one is still a puzzle the
    // page can open; it is the page that has the whole of it.
    Error(_) -> "What's your play?"
  }
}
