//// A practice session: what to put in front of the player next.
////
////   GET  /papi/practice            the session
////   GET  /papi/practice?band=<g>   one tier's session: FIX ONE
////   GET  /papi/practice?all=1      PRACTICE ANYWAY, once the queue is empty
////   POST /papi/practice/more       {band} KEEP GOING: more new ones, then the session
////   GET  /papi/practice/decks      the five decks (see "The five decks" below)
////   GET  /papi/practice/decks/:slug  one deck, its cells and its month
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
import oskol/caps/practice.{
  type Card, type Cell, type Day, type Session as DeckSession, type Summary,
  Active, New, Suspended,
}
import oskol/caps/puzzles.{type DeckSource} as _
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session, Session}
import oskol/handlers/home
import oskol/practice/catalog
import oskol/practice/cost
import oskol/practice/deck
import oskol/practice/decks
import oskol/practice/sync
import oskol/puzzles
import oskol/rooms/seat

/// The session: what to put in front of the player right now. There is no
/// page after it -- when they have answered these, they ask again.
///
/// `band` names one tier of mistakes ("very_bad", "bad", "doubtful") and
/// is what FIX ONE asks for: that tier's own queue, due first and then
/// ones never seen. Empty means the whole deck, which is what the page
/// opens with. A band that is not one of the three is refused rather
/// than widened into everything.
pub fn practice_json(
  ctx: Ctx,
  session: Session,
  band: String,
) -> Result(String, ApiError) {
  session_json(ctx, session, band, False)
}

/// The same, with PRACTICE ANYWAY: `all` asks, only when the ordinary queue
/// has nothing in it, for the positions in rotation soonest due first
/// (`deck.anyway`), each `due: false` and nothing written. While the queue
/// has anything at all, `all` is ignored: today's set comes first.
pub fn session_json(
  ctx: Ctx,
  session: Session,
  band: String,
  all: Bool,
) -> Result(String, ApiError) {
  use band <- result.try(checked_band(band))
  case session.user_id, session.guest_id {
    Some(uid), _ -> Ok(account_session(ctx, uid, band, all))
    // A guest has no deck, so nothing is scheduled and nothing is in
    // rotation: a band narrows their mistakes to that tier and `all` has
    // nothing to add.
    None, Some(guest_id) -> Ok(guest_session(ctx, guest_id, band))
    None, None -> Ok(empty())
  }
}

fn checked_band(band: String) -> Result(String, ApiError) {
  case band == "" || deck.known_band(band) {
    True -> Ok(band)
    False -> Error(error.validation_failed(deck.unknown_band_message))
  }
}

/// KEEP GOING: put the deck's pace again (`deck.keep_going_new`) of new
/// mistakes into rotation, over the day's budget, and answer the session
/// that results, so the page needs one call and not two. `band` names the
/// tier to take them from ("" is the whole deck) and is the session that
/// comes back.
///
/// Only an account has a rotation to add to. For a guest the page already
/// holds every mistake they have, so this is the same session and nothing
/// else -- and, as everywhere a guest practices, it writes nothing.
pub fn more_json(
  ctx: Ctx,
  session: Session,
  band: String,
) -> Result(String, ApiError) {
  use band <- result.try(checked_band(band))
  case session.user_id {
    Some(uid) -> {
      let _ = deck.keep_going(ctx, uid, band)
      // From the front again: the cards that were just started are due
      // now, so they are exactly what the next page is.
      Ok(account_session(ctx, uid, band, False))
    }
    None -> practice_json(ctx, session, band)
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
  // Every deck they have added counts its day in the same place.
  decks.set_timezone(ctx, uid, tz)
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

fn account_session(ctx: Ctx, uid: String, band: String, all: Bool) -> String {
  let found = case band {
    "" -> deck.session(ctx, uid)
    _ -> deck.band_session(ctx, uid, band)
  }
  let entries = case found.reviews, found.fresh, all {
    [], [], True -> cards(deck.anyway(ctx, uid, band), False)
    _, _, _ ->
      list.append(cards(found.reviews, True), cards(found.fresh, False))
  }
  // One read of the deck's totals, for both the counts the page prints
  // and the day's count: two reads could not disagree by much, but they
  // could disagree, and both are printed on the same card.
  let summary =
    ctx.practice.summary(uid, []) |> list.first |> option.from_result
  let tiers = deck.tiers(ctx, uid)
  body(
    entries,
    Some(counts(summary, found)),
    None,
    Some(deck.today_json(deck.today(ctx, uid))),
    // The tiers the practice hub leads with: how many mistakes of each
    // severity this player has made, how many are patched, and what each
    // still has to do today.
    Some(json.preprocessed_array(list.map(tiers, deck.severity_json))),
    deck.lead(tiers),
  )
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
fn guest_session(ctx: Ctx, guest_id: String, band: String) -> String {
  let mine = guest_mistakes(ctx, guest_id)
  let page =
    mine
    |> list.filter(fn(pair) { band == "" || pair.1 == band })
    |> list.map(fn(pair) { pair.0 })
    |> list.take(deck.page)
  let mine = list.map(mine, fn(pair) { pair.0 })
  body(
    list.map(page, fn(source) {
      entry(source.puzzle_id, source.kind, source.question_json, False)
    }),
    None,
    Some(mistakes(mine)),
    // No deck, so no day of theirs to count and nothing patched: a guest
    // is never shown progress against mistakes nothing is keeping for
    // them, and so has no tier to lead with either.
    None,
    None,
    None,
  )
}

/// A guest's own mistakes, one per puzzle, newest game first, each with the
/// tier it counts in: the worst grade any of their games reached it at,
/// which is how an account's card is banded too.
///
/// The query narrows by the guest id; the holder rule says which of the
/// rows that came back are really this browser's.
fn guest_mistakes(ctx: Ctx, guest_id: String) -> List(#(DeckSource, String)) {
  let held =
    ctx.puzzles.guest_sources(guest_id)
    |> list.filter(fn(source) {
      seat.holder(source.seat, Session(guest_id: Some(guest_id), user_id: None))
    })
  held
  |> dedupe([], [])
  |> list.map(fn(source) {
    let band =
      held
      |> list.filter(fn(other) { other.puzzle_id == source.puzzle_id })
      |> list.map(fn(other) { other.grade })
      |> worst_band
    #(source, band)
  })
}

/// The worst of these grades, in the deck's own bands: "" when none is one.
fn worst_band(grades: List(String)) -> String {
  list.find(deck.bands, fn(band) { list.contains(grades, band) })
  |> result.unwrap("")
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
  lead: Option(String),
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
    // The day's count: what this account has answered today, with
    // nothing to measure it against. An account's only, like `counts`.
    #("today", option.unwrap(today, json.null())),
    // The deck by how bad the mistake was, worst band first, with how
    // much of each is patched, and the rung that means patched.
    #("severity", option.unwrap(severity, json.null())),
    // The one tier to put in front of the player: the worst that still
    // has work, else the worst they have made a mistake in at all. The
    // choice is made here so that the hub and the home cannot make it
    // two different ways.
    #("lead", case lead {
      Some(grade) -> json.string(grade)
      None -> json.null()
    }),
    #("patched_level", json.int(deck.patched_level)),
    // This endpoint is never one game's mistakes; the per-game list is its
    // own route and names the game it answered for.
    #("game", json.null()),
  ])
}

fn empty() -> String {
  body([], None, None, None, None, None)
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

// ---------- The five decks ----------
//
//   GET /papi/practice/decks          every deck, with the caller's standing
//   GET /papi/practice/decks/:slug    one deck, with its cells and its month
//
// One shape for the three tiers of a player's mistakes and the two
// universal sets, so the hub, a deck's page and a run read one answer
// rather than three that count the same cards three ways. Every number is
// counted here from the deck's cells (`deck.standing`); nothing is written,
// nothing is started and no budget is spent by reading.

/// How many days a deck's page draws in its strip.
pub const month = 30

/// One deck, read for the caller.
type Reading {
  Reading(
    deck: catalog.Deck,
    /// How many positions: a tier's mistakes (an account's cards of that
    /// band, a guest's own mistakes of it, a stranger's none) or a set's.
    size: Int,
    /// Does this account have it? A tier with cards in it, a set added.
    joined: Bool,
    /// An account's; None for a guest and a stranger.
    standing: Option(deck.Standing),
    /// The cards the grid draws: an account's own, else none.
    cells: List(Cell),
    /// Answers in the scope's own day (`day.answered`): the mistakes'
    /// for a tier -- the three share it -- or the set's. 0 off an account.
    answered: Int,
  )
}

/// What an account's mistakes say, read once for all three tiers: they are
/// one learner with one day and one budget.
type MistakesRead {
  MistakesRead(cells: List(Cell), day: Day, by_band: List(#(String, Int)))
}

pub fn decks_json(ctx: Ctx, session: Session, now_ms: Int) -> String {
  // A guest's own mistakes, read once: the tiers' sizes and the line over
  // them ("23 mistakes from your 4 games") are counted off the same rows.
  let mine = case session.user_id, session.guest_id {
    None, Some(guest_id) -> Some(guest_mistakes(ctx, guest_id))
    _, _ -> None
  }
  let readings = read_decks(ctx, session, now_ms, offered_decks(ctx), mine)
  let costing =
    costing(ctx, session, readings, fn() {
      readings
      |> list.filter(fn(r) { is_tier(r.deck) })
      |> list.flat_map(fn(r) { r.cells })
    })
  let #(today, streak) = case session.user_id {
    Some(uid) -> #(
      Some(json.object([#("done", json.int(done_today(readings)))])),
      home.days_running(ctx.activity.days(uid, home.streak_window)),
    )
    None -> #(None, 0)
  }
  envelope.ok([
    #("decks", json.array(readings, reading_json(_, costing))),
    #("lead", case lead(readings) {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("today", option.unwrap(today, json.null())),
    #("streak", json.int(streak)),
    #("patched_level", json.int(deck.patched_level)),
    #("cost_all", cost.all_json(costing.window, costing.patched)),
    // A guest's: what is theirs, from how many games. Null for an account
    // (its tiers say it) and for a stranger (nothing is theirs).
    #("mistakes", case mine {
      Some(pairs) -> mistakes(list.map(pairs, fn(pair) { pair.0 }))
      None -> json.null()
    }),
  ])
}

pub fn deck_page_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  now_ms: Int,
) -> Result(String, ApiError) {
  use found <- result.try(
    catalog.find_slug(slug)
    |> result.replace_error(error.NotFound(decks.unknown_deck_message)),
  )
  let size = size_of(ctx, found)
  use _ <- result.try(case found.kind, size {
    catalog.Set(_), 0 -> Error(error.NotFound(decks.unknown_deck_message))
    _, _ -> Ok(Nil)
  })
  let reading = case read_decks(ctx, session, now_ms, [#(found, size)], None) {
    [reading] -> reading
    _ -> Reading(found, size, False, None, [], 0)
  }
  let costing =
    costing(ctx, session, [reading], fn() {
      case session.user_id {
        Some(uid) -> ctx.practice.cells(uid)
        None -> []
      }
    })
  let days = case session.user_id {
    Some(uid) ->
      case found.kind {
        // The three tiers are one learner, so a tier's month is the
        // mistakes' month.
        catalog.Mistakes(_) -> ctx.practice.days(uid, month)
        catalog.Set(set) -> decks.practice(ctx, set).days(uid, month)
      }
    None -> list.repeat(False, month)
  }
  Ok(
    envelope.ok([
      #("deck", reading_json(reading, costing)),
      #("cells", json.array(reading.cells, cell_json)),
      #("days", json.array(days, json.bool)),
      #("patched_level", json.int(deck.patched_level)),
    ]),
  )
}

/// The five, less a set nobody has built yet: a page must not offer a set
/// of puzzles with nothing in it. Each with the size a set's rows give it
/// (a tier's is the caller's, worked out when it is read).
fn offered_decks(ctx: Ctx) -> List(#(catalog.Deck, Int)) {
  catalog.all()
  |> list.filter_map(fn(d) {
    case d.kind, size_of(ctx, d) {
      catalog.Set(_), 0 -> Error(Nil)
      _, size -> Ok(#(d, size))
    }
  })
}

fn size_of(ctx: Ctx, d: catalog.Deck) -> Int {
  case d.kind {
    catalog.Set(set) -> ctx.decks.size(set.id)
    catalog.Mistakes(_) -> 0
  }
}

fn is_tier(d: catalog.Deck) -> Bool {
  case d.kind {
    catalog.Mistakes(_) -> True
    catalog.Set(_) -> False
  }
}

fn read_decks(
  ctx: Ctx,
  session: Session,
  now_ms: Int,
  offered: List(#(catalog.Deck, Int)),
  guest_mine: Option(List(#(DeckSource, String))),
) -> List(Reading) {
  case session.user_id, session.guest_id {
    Some(uid), _ -> account_readings(ctx, uid, now_ms, offered)
    None, Some(guest_id) -> {
      // Asked for only when a tier is: a set's page reads nothing of
      // theirs. The list has read them already, and hands them in.
      let mine = case
        guest_mine,
        list.any(offered, fn(pair) { is_tier(pair.0) })
      {
        Some(mine), _ -> mine
        None, True -> guest_mistakes(ctx, guest_id)
        None, False -> []
      }
      list.map(offered, fn(pair) {
        let #(d, size) = pair
        case d.kind {
          catalog.Mistakes(band) ->
            Reading(
              d,
              list.count(mine, fn(m) { m.1 == band }),
              False,
              None,
              [],
              0,
            )
          catalog.Set(_) -> Reading(d, size, False, None, [], 0)
        }
      })
    }
    None, None ->
      list.map(offered, fn(pair) { Reading(pair.0, pair.1, False, None, [], 0) })
  }
}

fn account_readings(
  ctx: Ctx,
  uid: String,
  now_ms: Int,
  offered: List(#(catalog.Deck, Int)),
) -> List(Reading) {
  let rungs = list.length(ctx.practice.intervals())
  // The mistakes are read only when a tier is asked about, and then once.
  let mistakes = case list.any(offered, fn(pair) { is_tier(pair.0) }) {
    True ->
      Some(MistakesRead(
        cells: ctx.practice.cells(uid),
        day: ctx.practice.day(uid),
        by_band: ctx.practice.answered_today_by_band(uid),
      ))
    False -> None
  }
  list.map(offered, fn(pair) {
    let #(d, size) = pair
    case d.kind, mistakes {
      catalog.Mistakes(band), Some(read) -> {
        let cells = list.filter(read.cells, fn(c) { c.band == band })
        let done = list.key_find(read.by_band, band) |> result.unwrap(0)
        let standing =
          deck.standing(cells, read.day.new_remaining, done, now_ms, rungs)
        Reading(
          d,
          standing.total,
          standing.total > 0,
          Some(standing),
          cells,
          read.day.answered,
        )
      }
      catalog.Set(set), _ -> {
        let caps = decks.practice(ctx, set)
        let cells = caps.cells(uid)
        let day = caps.day(uid)
        let standing =
          deck.standing(cells, day.new_remaining, day.answered, now_ms, rungs)
        Reading(
          d,
          size,
          standing.total > 0,
          Some(standing),
          cells,
          day.answered,
        )
      }
      // Not reached: the mistakes are read whenever a tier is offered.
      catalog.Mistakes(_), None -> Reading(d, 0, False, None, [], 0)
    }
  })
}

/// Everything this account has answered today, in every deck: the
/// mistakes' day (one learner for the three tiers, so counted once) and
/// each set's. Read off the days the readings already hold.
fn done_today(readings: List(Reading)) -> Int {
  let sets =
    readings
    |> list.filter(fn(r) { !is_tier(r.deck) })
    |> list.map(fn(r) { r.answered })
    |> int.sum
  let mistakes = case list.find(readings, fn(r) { is_tier(r.deck) }) {
    Ok(r) -> r.answered
    Error(Nil) -> 0
  }
  mistakes + sets
}

/// The one deck to put in front: the worst tier of mistakes with work
/// today, else a set the account has added with work (in the registry's
/// order), else the worst tier with anything in it at all -- so the page
/// can say it is in good shape rather than go blank -- else nothing. A
/// guest has no today, so theirs is the worst tier they have mistakes in.
fn lead(readings: List(Reading)) -> Option(String) {
  let working = fn(r: Reading) {
    case r.standing {
      Some(s) -> deck.standing_has_work(s)
      None -> False
    }
  }
  let first = fn(keep: fn(Reading) -> Bool) {
    list.find(readings, keep) |> result.map(fn(r) { r.deck.id })
  }
  first(fn(r) { is_tier(r.deck) && working(r) })
  |> result.lazy_or(fn() {
    first(fn(r) { !is_tier(r.deck) && r.joined && working(r) })
  })
  |> result.lazy_or(fn() { first(fn(r) { is_tier(r.deck) && r.size > 0 }) })
  |> option.from_result
}

/// What the mistakes cost in PR (`practice/cost`), read once for every
/// tier on the page: the account's window of graded games and its
/// mistakes, and which of them it has patched.
type Costing {
  Costing(window: Option(cost.Window), patched: List(String))
}

/// Only an account has a rating, and only a tier has a cost: a guest, a
/// stranger and a page with no tier on it (a set's) read nothing.
///
/// `cells` is every card of the mistakes, not one tier's: a row is costed
/// in the band it was graded in, and the card its puzzle became may sit in
/// a worse tier, so "patched" is asked of the whole deck. The list already
/// holds all three tiers' cells; a tier's page reads them (`all_cells`).
fn costing(
  ctx: Ctx,
  session: Session,
  readings: List(Reading),
  all_cells: fn() -> List(Cell),
) -> Costing {
  case session.user_id, list.any(readings, fn(r) { is_tier(r.deck) }) {
    Some(_), True ->
      Costing(
        window: cost.read(ctx, session),
        // Patched is the rung, on a card still in rotation: a mistake the
        // player said NEVER to was not fixed, only put away.
        patched: all_cells()
          |> list.filter(fn(c) { c.status == Active })
          |> list.map(fn(c) { #(c.key, c.level) })
          |> cost.patched_ids,
      )
    _, _ -> Costing(window: None, patched: [])
  }
}

fn reading_json(r: Reading, costing: Costing) -> Json {
  json.object([
    #("id", json.string(r.deck.id)),
    #("slug", json.string(r.deck.slug)),
    #("kind", json.string(catalog.kind_name(r.deck))),
    #("name", json.string(r.deck.name)),
    #("mark", json.string(r.deck.mark)),
    // A set's one line on what it is for; a tier is said by its name.
    #(
      "blurb",
      json.string(case r.deck.kind {
        catalog.Mistakes(_) -> ""
        catalog.Set(set) -> set.blurb
      }),
    ),
    #("size", json.int(r.size)),
    // How many new positions KEEP GOING puts in front: the mistakes' pace
    // (one for the three tiers, which share a day) or the set's own.
    #(
      "pace",
      json.int(case r.deck.kind {
        catalog.Mistakes(_) -> deck.keep_going_new
        catalog.Set(set) -> set.new_per_day
      }),
    ),
    #("joined", json.bool(r.joined)),
    #("standing", case r.standing {
      Some(s) -> deck.standing_json(s)
      None -> json.null()
    }),
    // What this tier's mistakes cost in PR; a set has none.
    #("cost", case r.deck.kind {
      catalog.Mistakes(band) ->
        cost.tier_json(costing.window, costing.patched, band)
      catalog.Set(_) -> json.null()
    }),
  ])
}

fn cell_json(c: Cell) -> Json {
  json.object([
    #("id", json.string(c.key)),
    #("level", json.int(c.level)),
    // Unix milliseconds, as every time on this wire is.
    #("due", json.int(c.due_ms)),
    #(
      "status",
      json.string(case c.status {
        New -> "new"
        Active -> "active"
        Suspended -> "suspended"
      }),
    ),
    #("position", case c.position {
      Some(p) -> json.int(p)
      None -> json.null()
    }),
    #("band", json.string(c.band)),
  ])
}
