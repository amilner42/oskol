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
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import oskol/caps/practice.{type Item, Item}
import oskol/caps/puzzles.{type DeckSource, type Pending}
import oskol/core/ctx.{type Ctx}
import oskol/core/error.{type ApiError}
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

/// New cards are introduced newest game first, and the deck orders them by
/// `position`, lowest first -- so a position is time counted *backwards*
/// from a fixed moment.
///
/// It is seconds and not milliseconds, and from 2020 and not from 1970,
/// because the column is a 32-bit integer: negated Unix milliseconds would
/// overflow it by six orders of magnitude, and negated Unix seconds would
/// run out in 2038. Counted this way it holds until well past 2080, and a
/// second is a finer grain than two games ever need.
pub const position_epoch_s = 1_577_836_800

pub fn position_of(ended_ms: Int) -> Int {
  position_epoch_s - ended_ms / 1000
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
) -> Result(Int, ApiError) {
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
) -> Result(Int, ApiError) {
  let ids = list.map(sources, fn(s) { s.source_id })
  // The timezone is deliberately not named here: filling a deck has no
  // opinion about where its owner is, and saying "UTC" would undo the one
  // place that does (`POST /papi/practice/tz`).
  case deck.enroll(ctx, user_id, "", items(sources)) {
    Ok(added) -> {
      ctx.puzzles.mark_synced(ids)
      Ok(added)
    }
    Error(refusal) -> {
      ctx.puzzles.sync_failed(ids, error.message(refusal))
      Error(refusal)
    }
  }
}

/// The cards these mistakes become, newest game first and one per puzzle.
///
/// Two seats can reach the same position in two games -- that is the whole
/// point of keying a puzzle on its question -- and one deck holds one card
/// for it. The newest of them wins the position, so a card's place in the
/// queue is the last time the player got it wrong; both rows are stamped
/// either way, because the deck does hold them.
fn items(sources: List(DeckSource)) -> List(Item) {
  sources
  |> list.sort(fn(a, b) { int.compare(b.ended_ms, a.ended_ms) })
  |> list.fold(#([], set.new()), fn(acc, source) {
    let #(items, seen) = acc
    case set.contains(seen, source.puzzle_id) {
      True -> acc
      False -> #([item(source), ..items], set.insert(seen, source.puzzle_id))
    }
  })
  |> fn(acc) { list.reverse(acc.0) }
}

fn item(source: DeckSource) -> Item {
  Item(
    key: source.puzzle_id,
    // Sorted by key, as the deck requires: "deck" before "kind".
    tags: [#(deck_tag_key, deck_tag), #(kind_tag_key, source.kind)],
    // The question itself, which is immutable: a card can then be listed,
    // and its sentence written, without going back to the puzzle row.
    content_json: source.question_json,
    position: Some(position_of(source.ended_ms)),
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
pub fn sweep(ctx: Ctx, limit: Int) -> List(#(String, Result(Int, ApiError))) {
  pending(ctx, limit)
  |> list.map(fn(row) { #(row.user_id, sync_deck(ctx, row.user_id, [])) })
}
