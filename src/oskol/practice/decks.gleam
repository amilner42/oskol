//// Universal decks: practice that is not made of anybody's mistakes and is
//// offered to everyone. The first two are the openings -- the fifteen
//// opening rolls, and the twenty-one replies to each of them -- and the
//// registry is a list so that the next deck is one more entry.
////
//// What a deck *is* lives here: its name, what it is for, and how fast it
//// introduces new positions. **Which** positions are in it is data (the
//// `deck_puzzles` rows the operator's build writes, `handlers/decks_build`);
//// where a player stands on it is the ladder their mistakes use, in a retain
//// scope of the deck's own (`scope`), so no deck's budget, queue or levels
//// can move another's.
////
//// A player's own set (`own`) is a `Deck` with an `owner`: the same
//// scope, queue, standing and enrolling, its positions written one at a
//// time by its owner (`enroll_one`) rather than by an operator's build.
////
//// Everything here reads the caps it is given and decides; it writes only
//// by enrolling, which a player asks for.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/decks.{type Member, type OwnDeck}
import oskol/caps/practice.{
  type Card, type Cell, type PracticeCaps, type PracticeError, Item, Suspended,
}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/session.{type Session}
import oskol/practice/deck
import oskol/puzzles

/// A deck in the registry.
pub type Deck {
  Deck(
    /// Stable: the `deck_puzzles.deck` value, the URL segment, and (behind
    /// `scope`) the retain scope. Never renamed once a player has one.
    id: String,
    /// What a player reads it as.
    name: String,
    /// One line on what it is for.
    blurb: String,
    /// New positions a day. Everything due comes first, as with mistakes.
    new_per_day: Int,
    /// The account a player's own set belongs to; None for the registry's,
    /// which are everybody's.
    owner: Option(String),
  )
}

pub const openings_id = "openings"

pub const replies_id = "opening_replies"

/// Every universal deck, in the order a page lists them.
///
/// The budgets are a pace, not a wall: a run is open-ended and due
/// positions always come first. Five openings a day puts all fifteen in
/// front of a player inside three days; ten replies a day is a month for
/// all 315, which is what learning them takes.
pub fn all() -> List(Deck) {
  [
    Deck(
      id: openings_id,
      name: "Openings",
      blurb: "The fifteen opening rolls, and the play for each.",
      new_per_day: 5,
      owner: None,
    ),
    Deck(
      id: replies_id,
      name: "Opening replies",
      blurb: "Your first roll after each opening: 21 rolls against each of the 15.",
      new_per_day: 10,
      owner: None,
    ),
  ]
}

pub fn find(id: String) -> Result(Deck, Nil) {
  list.find(all(), fn(deck) { deck.id == id })
}

pub const unknown_deck_message = "There is no such set of puzzles."

/// An account's own sets, oldest first: the registry's machinery with an
/// owner. Its id is the row's, its scope is `scope`'s like any deck's, and
/// it has no blurb (a player names it, and the name says it).
pub fn own(ctx: Ctx, uid: String) -> List(Deck) {
  list.map(ctx.decks.own(uid), from_row)
}

/// An own set's row as a deck.
pub fn from_row(row: OwnDeck) -> Deck {
  Deck(
    id: row.id,
    name: row.name,
    blurb: "",
    new_per_day: row.new_per_day,
    owner: Some(row.user_id),
  )
}

/// A deck as this caller may reach it: one of the registry's, which is
/// everybody's, or one of the caller's own sets. Somebody else's set is
/// not found at all -- a set is private, so it does not say it exists.
/// The registry is asked first, so a universal id never reads a row.
pub fn find_for(ctx: Ctx, session: Session, id: String) -> Result(Deck, Nil) {
  case find(id), session.user_id {
    Ok(deck), _ -> Ok(deck)
    Error(Nil), Some(uid) -> list.find(own(ctx, uid), fn(d) { d.id == id })
    Error(Nil), None -> Error(Nil)
  }
}

/// Is this a player's own set (rather than one of the registry's)?
pub fn is_own(deck: Deck) -> Bool {
  option.is_some(deck.owner)
}

/// The retain scope a deck's ladder lives in. Prefixed, so no deck id can
/// ever be mistaken for the mistakes' own scope.
pub fn scope(deck: Deck) -> String {
  "deck:" <> deck.id
}

/// The practice caps for one deck.
pub fn practice(ctx: Ctx, deck: Deck) -> PracticeCaps {
  ctx.decks.practice(scope(deck))
}

/// The same context with the deck's ladder where the mistakes' is: every
/// rule in `practice/deck` (answering, correcting, putting one off) then
/// works on the deck as it does on mistakes, with nothing written twice.
pub fn in_deck(ctx: Ctx, deck: Deck) -> Ctx {
  Ctx(..ctx, practice: practice(ctx, deck))
}

// ---------- Where a player stands ----------

/// A player's standing on one deck, in the three states a mistake has
/// (untouched, in progress, patched) plus what it has to do today.
pub type Standing {
  Standing(
    /// Positions in this player's copy of the deck; 0 until they add it.
    total: Int,
    in_progress: Int,
    patched: Int,
    /// Due now.
    due: Int,
    /// Never shown, and within what today's budget still allows.
    new_left: Int,
  )
}

/// Has this player added the deck? Nothing is written until they do.
pub fn joined(standing: Standing) -> Bool {
  standing.total > 0
}

/// Everything not patched: what "left to master" counts.
pub fn left(standing: Standing) -> Int {
  int.max(standing.total - standing.patched, 0)
}

pub fn has_work(standing: Standing) -> Bool {
  standing.due > 0 || standing.new_left > 0
}

/// Read off the deck's own ladder: the totals retain keeps, and the count
/// per rung, of which the patched ones are the rungs at and above
/// `deck.patched_level` -- the same rule a mistake is patched by.
pub fn standing(ctx: Ctx, set: Deck, uid: String) -> Standing {
  let caps = practice(ctx, set)
  case caps.summary(uid, []) |> list.first {
    Error(Nil) -> Standing(0, 0, 0, 0, 0)
    Ok(row) -> {
      // An own set's positions taken out are suspended, not dropped (so a
      // re-save keeps its level): they are no longer in the set, and count
      // for nothing. A universal set keeps its NEVER cards as it always has.
      let #(total, patched) = case is_own(set) {
        True -> {
          let kept =
            caps.cells(uid) |> list.filter(fn(c) { c.status != Suspended })
          #(
            list.length(kept),
            list.count(kept, fn(c) { c.level >= deck.patched_level }),
          )
        }
        False -> #(
          row.count,
          caps.ladder(uid) |> list.drop(deck.patched_level) |> int.sum,
        )
      }
      let untouched = row.new_count
      let budget = int.max(caps.day(uid).new_remaining, 0)
      Standing(
        total: total,
        in_progress: int.max(total - untouched - patched, 0),
        patched: int.min(patched, total),
        due: row.due_count,
        new_left: int.min(untouched, budget),
      )
    }
  }
}

// ---------- Adding a deck ----------

/// Put every position of the deck into this player's copy of it. Idempotent:
/// a position already there is left exactly as it is, so adding a deck
/// again after it has grown adds only what is new. `tz` is the browser's
/// zone, or "" to keep whatever the deck already has.
pub fn enroll(
  ctx: Ctx,
  deck: Deck,
  uid: String,
  tz: String,
) -> Result(Int, PracticeError) {
  let caps = practice(ctx, deck)
  let tz = case deck.valid_timezone(tz) {
    True -> tz
    False -> ""
  }
  use Nil <- result.try(caps.put_user(uid, tz, deck.new_per_day))
  caps.put_items(uid, list.map(ctx.decks.members(deck.id), item(deck, _)))
}

/// Put one position of an own set into its owner's copy at once, so it is
/// due as a new position today: the same item `enroll` writes for it. A
/// position taken out of the set earlier was put away (suspended) and
/// comes back at the level it left at. Idempotent.
pub fn enroll_one(
  ctx: Ctx,
  deck: Deck,
  uid: String,
  member: Member,
) -> Result(Nil, PracticeError) {
  let caps = practice(ctx, deck)
  use Nil <- result.try(caps.put_user(uid, "", deck.new_per_day))
  use fresh <- result.try(caps.put_items(uid, [item(deck, member)]))
  case fresh {
    // Already on the ladder: taken out once, and now back at the set's end.
    0 -> {
      let _ = caps.resume(uid, [member.puzzle_id])
      let _ = caps.place(uid, [#(member.puzzle_id, member.position)])
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}

fn item(deck: Deck, member: Member) -> practice.Item {
  Item(
    key: member.puzzle_id,
    // Sorted by key, as the deck requires.
    tags: [#("deck", deck.id), #("kind", member.kind)],
    content_json: member.question_json,
    position: Some(member.position),
  )
}

/// Where the player's browser is, on every deck they have added: the day a
/// deck counts in is the same day their mistakes count in. A deck they
/// have not added is left alone rather than created.
pub fn set_timezone(ctx: Ctx, uid: String, tz: String) -> Nil {
  list.each(list.append(all(), own(ctx, uid)), fn(deck) {
    let caps = practice(ctx, deck)
    case caps.summary(uid, []) {
      [] -> Nil
      _ -> {
        let _ = caps.put_user(uid, tz, deck.new_per_day)
        Nil
      }
    }
  })
}

// ---------- A session ----------

/// One entry of a session: the puzzle, what it asks, and whether it is due.
pub type Entry {
  Entry(id: String, kind: String, question_json: String, due: Bool)
}

/// What to put in front of an account that has added the deck: everything
/// due, then new positions within the day's budget, a page at a time and
/// always from the front (`deck.daily_ask`'s reasons hold here too).
pub fn queue(ctx: Ctx, deck: Deck, uid: String) -> List(Entry) {
  let found = practice(ctx, deck).queue(uid, deck.daily_ask())
  list.append(
    list.map(found.reviews, entry(_, True)),
    list.map(found.fresh, entry(_, False)),
  )
}

/// PRACTICE ANYWAY through a set: its positions in rotation, soonest due
/// first (`deck.anyway` in the set's own scope), each one an answer that
/// moves nothing. `from` skips that many from the front (`deck.anyway`).
pub fn anyway(ctx: Ctx, set: Deck, uid: String, from: Int) -> List(Entry) {
  deck.anyway(in_deck(ctx, set), uid, "", from)
  |> list.map(entry(_, False))
}

fn entry(card: Card, due: Bool) -> Entry {
  Entry(
    id: card.key,
    kind: list.key_find(card.tags, "kind") |> result.unwrap(""),
    question_json: card.content_json,
    due: due,
  )
}

/// The deck in its own order, for anybody who has not added it: a guest,
/// a stranger, an account trying it before adding it. Nothing is
/// scheduled and nothing is written.
pub fn walk(ctx: Ctx, deck: Deck) -> List(Entry) {
  ctx.decks.members(deck.id)
  |> list.map(fn(m) { Entry(m.puzzle_id, m.kind, m.question_json, False) })
}

// ---------- The wire ----------

pub fn entry_json(entry: Entry) -> Json {
  json.object([
    #("id", json.string(entry.id)),
    #("kind", json.string(entry.kind)),
    #("prompt", json.string(prompt(entry.question_json))),
    #("due", json.bool(entry.due)),
  ])
}

fn prompt(question_json: String) -> String {
  case puzzles.question_from_json(question_json) {
    Ok(question) -> puzzles.prompt(question)
    Error(_) -> "What's your play?"
  }
}

/// One deck as a page lists it. `size` is how many positions the deck has;
/// `standing` is the caller's own, None for anybody without an account.
pub fn deck_json(deck: Deck, size: Int, standing: Option(Standing)) -> Json {
  json.object([
    #("id", json.string(deck.id)),
    #("name", json.string(deck.name)),
    #("blurb", json.string(deck.blurb)),
    #("size", json.int(size)),
    #("standing", case standing {
      None -> json.null()
      Some(s) -> standing_json(s)
    }),
    #("own", json.bool(is_own(deck))),
  ])
}

pub fn standing_json(s: Standing) -> Json {
  json.object([
    #("joined", json.bool(joined(s))),
    #("total", json.int(s.total)),
    #("in_progress", json.int(s.in_progress)),
    #("patched", json.int(s.patched)),
    #("left", json.int(left(s))),
    #("due", json.int(s.due)),
    #("new_left", json.int(s.new_left)),
  ])
}

/// An own set's cells as its pages draw them: what is in the set, which
/// leaves out a position taken out of it (suspended, so a re-save keeps
/// its level). Any other deck's cells are as they are.
pub fn shown_cells(set: Deck, cells: List(Cell)) -> List(Cell) {
  case is_own(set) {
    True -> list.filter(cells, fn(c) { c.status != Suspended })
    False -> cells
  }
}

/// An own set's positions for its owner, in the set's order, each with the
/// rung its card stands on (0 for one never answered). `cells` are the
/// owner's, read off the set's own ladder (`practice(ctx, deck).cells`).
/// `question` writes each one's question as the page draws it
/// (`handlers/puzzles.stored_question_json`, passed in because that module
/// reads this one), for the small board MANAGE lists it with.
pub fn members_json(
  ctx: Ctx,
  deck: Deck,
  cells: List(Cell),
  question: fn(String) -> Json,
) -> Json {
  let levels = list.map(cells, fn(c) { #(c.key, c.level) })
  json.array(ctx.decks.members(deck.id), fn(m) {
    json.object([
      #("id", json.string(m.puzzle_id)),
      #("kind", json.string(m.kind)),
      #("prompt", json.string(prompt(m.question_json))),
      #("position", json.int(m.position)),
      #(
        "level",
        json.int(list.key_find(levels, m.puzzle_id) |> result.unwrap(0)),
      ),
      #("question", question(m.question_json)),
    ])
  })
}
