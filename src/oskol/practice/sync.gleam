//// Filling the deck. "Your mistakes" has to grow by itself and recover by
//// itself: nobody ever presses "add this to my deck".
////
//// One decision, `sync_deck`: the mistakes on the seats an account owns go
//// into that account's deck as new cards, newest game first, and the rows
//// that made it are stamped so nothing does the work twice. Three moments
//// call it, and they are the three moments at which an account can come to
//// own a mistake it has not been given yet:
////
////   1. **A game was graded.** The review job has just written that game's
////      puzzles, so the seats that made them get their cards (`handlers/
////      reviews`).
////   2. **A browser signed in.** Its seats became an account's, and every
////      mistake on them is now that account's too. The stamp's own
////      transaction has to commit first -- until it does there is no owned
////      seat to read -- so this runs off the back of it, from the
////      persister's handler, and never in the request that asked for it.
////   3. **The sweep**, for anything the first two missed: a crash between
////      the extraction and the enrolment, a deploy in the gap, a retain
////      that was down for a minute. `mix oskol.puzzles.sync` is the same
////      sweep by hand.
////
//// Idempotent at both levels: the query only offers rows no deck holds yet
//// (`puzzle_sources.deck_synced_at`), and enrolling a key a deck already
//// has changes nothing, so a rerun is a no-op however far the last run
//// got. Bounded, too: asking for an account's sources charges a try
//// against those rows, and a row that has spent its tries is left out with
//// a reason, so no failure has the sweep replaying it every minute for
//// ever.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/set
import oskol/caps/practice.{
  type Card, type Item, type PracticeError, Active, Item,
}
import oskol/caps/puzzles.{type DeckSource, type Pending}
import oskol/core/ctx.{type Ctx}
import oskol/core/session.{Session}
import oskol/practice/deck
import oskol/rooms/seat

/// The tag every card in the mistakes deck carries. There is one deck in
/// this milestone; the tag is what lets there be others (an opening deck, a
/// quiz) without a second query.
pub const deck_tag = "mistakes"

pub const deck_tag_key = "deck"

pub const kind_tag_key = "kind"

/// How many accounts one sweep works through. The sweep runs every minute,
/// so this is a rate, not a limit: what it does not get to now it gets to
/// next time, and a backlog drains at 60 accounts a minute rather than
/// holding one database connection for all of it.
pub const sweep_batch = 60

/// New cards are introduced **worst first**, and the newest game first
/// within a band, and the deck orders them by `position`, lowest first.
///
/// So a position is a band's block plus time counted *backwards* from a
/// fixed moment: every very bad move comes before every bad one, and
/// inside a band the mistake you made most recently comes first.
///
/// The grain is minutes, and the epoch 2020 rather than 1970, because the
/// column is a 32-bit integer and three bands have to fit in it side by
/// side. Sixty years of minutes is about 32 million, which is why a band
/// is worth a hundred million: no amount of play can carry a card out of
/// its own band, and the three of them together use a tenth of the range.
/// A minute is a finer grain than two games ever need.
pub const position_epoch_s = 1_577_836_800

/// The room one band has to itself, in the same units as the time below
/// it. Wider than any playable span of time, so bands never overlap.
pub const band_span = 100_000_000

pub fn position_of(grade: String, ended_ms: Int) -> Int {
  band_rank(grade) * band_span + { position_epoch_s - ended_ms / 1000 } / 60
}

/// Worst first: the site's own bands, in the order `practice/deck` names
/// them. A grade this does not know (a row from before the bands, or one
/// written by something else) sorts after all three rather than jumping
/// the queue.
pub fn band_rank(grade: String) -> Int {
  case grade {
    "very_bad" -> 0
    "bad" -> 1
    "doubtful" -> 2
    _ -> 3
  }
}

/// Put every mistake this account owns and has not been given into its
/// deck. `game_ids` narrows it to the games that just changed hands; an
/// empty list means all of them, which is what the sweep asks for.
///
/// Returns how many cards were new. `Error` when the deck refused the
/// write -- the rows are told, and the sweep will come back for them
/// within their budget.
pub fn sync_deck(
  ctx: Ctx,
  user_id: String,
  game_ids: List(String),
) -> Result(Int, PracticeError) {
  case user_id {
    "" -> Ok(0)
    _ -> {
      let sources =
        ctx.puzzles.owned_sources(user_id, game_ids)
        |> list.filter(owned_by(_, user_id))
      case sources {
        // Nothing owed: no deck is created, nothing is written, and an
        // account that has never made a mistake never gets a row.
        [] -> Ok(0)
        _ -> enroll(ctx, user_id, sources)
      }
    }
  }
}

/// The holder rule, against the account alone: the query found these rows
/// by asking which seats name this account, and this is the one place that
/// says a seat named that way is really theirs. A seat with no account on
/// it is nobody's to enrol, whatever guest is sitting on it.
fn owned_by(source: DeckSource, user_id: String) -> Bool {
  seat.holder(source.seat, Session(guest_id: None, user_id: Some(user_id)))
}

fn enroll(
  ctx: Ctx,
  user_id: String,
  sources: List(DeckSource),
) -> Result(Int, PracticeError) {
  let ids = list.map(sources, fn(s) { s.source_id })
  let offered = items(sources)
  // Which of these the deck already holds, before anything is added: a
  // puzzle that is already there is one this player has just made again.
  let held = ctx.practice.cards(user_id, list.map(offered, fn(i) { i.key }))
  // The timezone is deliberately not named here: filling a deck has no
  // opinion about where its owner is, and saying "UTC" would undo the one
  // place that does (`POST /papi/practice/tz`).
  case deck.enroll_items(ctx, user_id, "", offered) {
    Ok(added) -> {
      relapse(ctx, user_id, sources, held)
      ctx.puzzles.mark_synced(ids)
      Ok(added)
    }
    Error(refusal) -> {
      ctx.puzzles.sync_failed(ids, deck.reason(refusal))
      Error(refusal)
    }
  }
}

/// **A mistake you make again comes back.** A puzzle already in the deck
/// that shows up in a new game is not a card to add -- it is a card the
/// player has just failed, in the only place that really counts -- so it
/// goes back to the start exactly as a missed answer would.
///
/// Only a card **in rotation**: a card the player has never been shown is
/// already at the front of the queue and has nothing to lose, and a
/// suspended one they have said NEVER to, which a game they happened to
/// play must not undo.
fn relapse(
  ctx: Ctx,
  user_id: String,
  sources: List(DeckSource),
  held: List(Card),
) -> Nil {
  list.each(sources, fn(source) {
    case list.find(held, fn(card) { card.key == source.puzzle_id }) {
      Ok(card) if card.status == Active -> {
        let _ = ctx.practice.relapse(user_id, source.puzzle_id, meta(source))
        Nil
      }
      _ -> Nil
    }
  })
}

/// Where a relapse came from, so the log says what happened rather than
/// only that something did.
fn meta(source: DeckSource) -> String {
  json.to_string(
    json.object([
      #("source", json.string("game")),
      #("game_id", json.string(source.game_id)),
      #("game_number", json.int(source.game_number)),
      #("turn", json.int(source.turn)),
    ]),
  )
}

/// The cards these mistakes become, worst first and one per puzzle.
///
/// Two seats can reach the same position in two games -- that is the whole
/// point of keying a puzzle on its question -- and one deck holds one card
/// for it. The **worst** of them wins the position, and the newest within
/// that band, so a card's place in the queue is how bad the mistake was
/// and then the last time the player made it; both rows are stamped
/// either way, because the deck does hold them.
fn items(sources: List(DeckSource)) -> List(Item) {
  sources
  |> list.sort(worst_first)
  |> list.fold(#([], set.new()), fn(acc, source) {
    let #(items, seen) = acc
    case set.contains(seen, source.puzzle_id) {
      True -> acc
      False -> #([item(source), ..items], set.insert(seen, source.puzzle_id))
    }
  })
  |> fn(acc) { list.reverse(acc.0) }
}

/// Worst band first, then the newest game, then within a game the order
/// the mistakes were made in. Two cards of one game and one band share a
/// position, so the order they are offered in is the order they go in.
fn worst_first(a: DeckSource, b: DeckSource) -> order.Order {
  case int.compare(band_rank(a.grade), band_rank(b.grade)) {
    order.Eq ->
      case int.compare(b.ended_ms, a.ended_ms) {
        order.Eq -> int.compare(a.turn, b.turn)
        other -> other
      }
    other -> other
  }
}

fn item(source: DeckSource) -> Item {
  Item(
    key: source.puzzle_id,
    // Sorted by key, as the deck requires: "deck" before "kind".
    tags: [#(deck_tag_key, deck_tag), #(kind_tag_key, source.kind)],
    // The question itself, which is immutable: a card can then be listed,
    // and its sentence written, without going back to the puzzle row.
    content_json: source.question_json,
    position: Some(position_of(source.grade, source.ended_ms)),
  )
}

// ---------- One game, just graded ----------

/// This game's puzzles have just been written: give them to the accounts
/// whose seats made them.
///
/// The review job knows the game and nothing about who owns its seats --
/// that is a fact about the `games` row, not about the analysis -- so it
/// asks the same question the sweep asks, narrowed to this one game.
/// Nothing owns a seat here, or every mistake is already in a deck, and
/// this is one small query and no writes.
pub fn sync_game(ctx: Ctx, game_id: String) -> Nil {
  ctx.puzzles.deck_pending([game_id], sweep_batch)
  |> list.each(fn(row) {
    let _ = sync_deck(ctx, row.user_id, [game_id])
    Nil
  })
}

// ---------- The sweep ----------

/// What the sweep would do: the accounts with mistakes no deck holds yet.
/// A read, and only a read -- this is what the mix task's dry run prints.
pub fn pending(ctx: Ctx, limit: Int) -> List(Pending) {
  ctx.puzzles.deck_pending([], limit)
}

/// Sync every account the deck still owes, and say how it went for each.
/// A refusal for one account never stops the next: they share nothing.
pub fn sweep(
  ctx: Ctx,
  limit: Int,
) -> List(#(String, Result(Int, PracticeError))) {
  pending(ctx, limit)
  |> list.map(fn(row) { #(row.user_id, sync_deck(ctx, row.user_id, [])) })
}
