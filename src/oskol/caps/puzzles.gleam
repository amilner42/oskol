//// Writing a graded game's puzzles down. One capability, one call, one
//// transaction: the puzzles, the sources that point at them and the marker
//// that says this game has been extracted all land together, or none of
//// them do. Built for real in lib/oskol/gleam/caps/puzzles.ex -- that file
//// and this one must agree on constructor tags and field order.
////
//// The call is idempotent by construction: a puzzle is written only where
//// its key is new, a source only where its (game, game number, turn, kind)
//// is new, and running the same extraction again writes nothing.

import gleam/option.{type Option}
import oskol/core/error.{type ApiError}
import oskol/rooms/seat.{type Seat}

/// A puzzle to write, unless its key is already there.
pub type NewPuzzle {
  NewPuzzle(
    /// sha256 of the canonical question: what makes two the same.
    key: String,
    /// The ids to try, best first. The first one no other key holds wins;
    /// a puzzle whose key is already stored keeps the id it has.
    ids: List(String),
    /// "move", "double" or "take".
    kind: String,
    question_json: String,
    answer_json: String,
    evaluated_by_json: String,
    /// The answer can grade any attempt exactly (`oskol/puzzles.complete`).
    /// The one thing that may change a stored answer: a complete one
    /// replaces an incomplete one for the same question, and nothing else
    /// is ever rewritten.
    complete: Bool,
  )
}

/// What one game's write actually did, as row counts. A rerun of the same
/// extraction is all zeros.
pub type Written {
  Written(
    /// Puzzles whose key was new.
    puzzles: Int,
    /// Stored puzzles whose incomplete answer was replaced by this game's
    /// complete one (`puzzles.answer_upgraded_at`).
    upgraded: Int,
    /// Source rows that were new.
    sources: Int,
  )
}

/// Whose mistake it was, and where. One per qualifying decision of the
/// game, including the ones no puzzle was written for.
pub type NewSource {
  NewSource(
    /// The puzzle this is a source of, by key. None for a turn that was
    /// skipped: the row is still written, with a reason, so a later repair
    /// can count and revisit them without replaying anything.
    key: Option(String),
    game_number: Int,
    /// Which turn of that game, counting from 1, as the review numbers
    /// them.
    turn: Int,
    kind: String,
    /// The seat that made the decision: the mover for a move or a double,
    /// the responder for a take.
    seat: Int,
    player_id: String,
    /// The move played, in notation, or the cube action taken.
    played: String,
    equity_lost: Float,
    /// The engine's band: "doubtful", "bad", "very_bad".
    grade: String,
    skipped_reason: Option(String),
  )
}

/// One stored mistake, as the deck reads it: which puzzle it points at,
/// what it asks, and the seat that made it.
///
/// The seat rides along so that **the holder rule decides whose mistake
/// this is, not the query**. The queries behind these capabilities narrow
/// by a guest id or an account id the way `seated_rooms` does -- a coarse,
/// indexed containment test over `games.players` -- and `rooms/seat.holder`
/// then says which of the rows that came back are really the caller's.
pub type DeckSource {
  DeckSource(
    /// The `puzzle_sources` row, so a sync stamps exactly what it enrolled.
    source_id: Int,
    puzzle_id: String,
    /// The game this mistake was made in, and which game of the match:
    /// what a relapse writes down about itself.
    game_id: String,
    game_number: Int,
    /// "move", "double" or "take".
    kind: String,
    /// Which turn of its game, counting from 1. Two mistakes of one game
    /// are drilled in the order they were made.
    turn: Int,
    /// The stored question, as JSON text: what a prompt is built from, and
    /// what a card carries so a session needs no second query. A question
    /// is immutable (it is the puzzle's key), so a copy of one cannot go
    /// stale.
    question_json: String,
    /// When the game this came from ended, in Unix milliseconds: the
    /// moment its review row was opened, which is the game ending and not
    /// the moment somebody got round to extracting it. New cards are
    /// introduced newest game first, and a backfill or a retried review
    /// must not put an old game at the front of the queue.
    ended_ms: Int,
    seat: Seat,
  )
}

/// An account the deck sweep still owes work to, and where that work is.
pub type Pending {
  Pending(user_id: String, game_ids: List(String), sources: Int)
}

/// A puzzle as it was written: the question and the answer, still as the
/// JSON text Gleam stored, because Gleam is what reads them back.
pub type Stored {
  Stored(id: String, kind: String, question_json: String, answer_json: String)
}

/// One decision of one game that a puzzle came from.
pub type Source {
  Source(
    id: Int,
    puzzle_id: String,
    kind: String,
    game_id: String,
    game_number: Int,
    /// Which turn of that game, counting from 1 as the review numbers them.
    turn: Int,
    /// The seat that made the decision, by index and by player id.
    seat: Int,
    player_id: String,
    played: String,
    equity_lost: Float,
    grade: String,
    /// The day the game was played, as "2026-09-12".
    date: String,
    /// The puzzle's own question, as stored, so a list of a game's mistakes
    /// can ask each one in its own words without a read apiece. Empty for a
    /// decision no puzzle was written for.
    question_json: String,
  )
}

/// A source with the room it sits in: the seats, so the handler can ask the
/// one holder rule who may see it, and the slug, so a link can be written.
pub type SourceRoom {
  SourceRoom(
    source: Source,
    slug: String,
    /// #(player_id, display name, guest id, account id), in seat order, as
    /// `records.Setup` has them.
    seats: List(#(String, String, String, String)),
  )
}

/// A share-with-my-story link, read back by its token: which puzzle it is
/// about, the name the sharer consented to be shown under (frozen when the
/// link was minted: a rename or a seat taken over must not change who the
/// story names), and the one decision it tells.
pub type Share {
  Share(token: String, puzzle_id: String, shared_name: String, source: Source)
}

/// What answering one puzzle did, as the serialized section hands it back:
/// the verdict that stands and the schedule that was reported.
pub type Scheduled {
  Scheduled(verdict: String, schedule_json: String)
}

/// One answer somebody gave, as the row holds it.
pub type Attempt {
  Attempt(
    id: Int,
    puzzle_id: String,
    user_id: String,
    key: String,
    verdict: String,
    /// The player's override, once they have given one.
    outcome: Option(String),
    /// This attempt spent the card's review opportunity.
    scheduled: Bool,
    /// The deck review it wrote, which is what an override supersedes.
    review_id: Option(Int),
    /// The schedule reported at the time, as JSON text; "" when there was
    /// none. A retried key answers with this rather than working it out
    /// again against a card that has since moved.
    schedule_json: String,
    /// This call is what wrote the row. False means the key was already
    /// there, so nothing may be scheduled for it a second time.
    fresh: Bool,
  )
}

/// `moves` is a built move tree (`oskol/puzzles/tree.Tree`). It is a type
/// variable rather than that type because a capability describes IO, and
/// the store it crosses into neither reads it nor knows what it is.
pub type PuzzlesCaps(moves) {
  PuzzlesCaps(
    /// The game numbers of a room whose review the engine has answered and
    /// whose puzzles have never been written: a crash between the two, a
    /// room graded before puzzles existed, or an extraction that failed and
    /// still has attempts left. Small: three columns of the review rows.
    unextracted: fn(String) -> List(Int),
    /// Write one game's puzzles, sources and extraction marker atomically:
    /// (game_id, game_number, puzzles, sources). The marker is set even
    /// when both lists are empty -- a game with no mistakes is extracted,
    /// not owed forever. Error(reason) when the write failed; extraction
    /// never fails a review, so a caller logs and moves on.
    store: fn(String, Int, List(NewPuzzle), List(NewSource)) ->
      Result(Written, String),
    /// This game was owed puzzles and could not have them: (game_id,
    /// game_number, why). Charges the try and logs it, and once the budget
    /// is spent marks the row so the sweep stops coming back. Every path
    /// that gives up on a game's puzzles goes through here or through a
    /// failing `store`, or the sweep would replay that room every minute
    /// for ever without saying so.
    failed: fn(String, Int, String) -> Nil,
    /// The mistakes on seats this account owns that its deck does not hold
    /// yet, newest game first: `(user_id, game_ids)`, and every game of
    /// theirs when the list is empty. A row that has run out of tries is
    /// left out, so nothing loops for ever.
    ///
    /// **Asking charges a try**, exactly as an engine call does: a sync
    /// that keeps crashing must not have the sweep coming back every
    /// minute for the same rows. A row that syncs is marked and leaves
    /// this query, so the charge only outlives a failure.
    owned_sources: fn(String, List(String)) -> List(DeckSource),
    /// The deck holds these source rows now.
    mark_synced: fn(List(Int)) -> Nil,
    /// These rows could not be put in a deck: log it, and once their tries
    /// are spent record why, so the sweep lets them go.
    sync_failed: fn(List(Int), String) -> Nil,
    /// The accounts with mistakes no deck holds yet, most recent first, at
    /// most this many, in these games (everywhere when the list is empty).
    /// The sweep's work list, what its dry run prints, and how a game that
    /// has just been graded finds out whose mistakes it wrote. Asking
    /// costs nothing and charges nothing.
    deck_pending: fn(List(String), Int) -> List(Pending),
    /// The mistakes on seats this guest's cookie holds. A guest has no
    /// deck, so this is their whole session: newest game first, nothing
    /// scheduled, nothing written.
    guest_sources: fn(String) -> List(DeckSource),
    /// One puzzle by id, or nothing. Open: a puzzle is a position and a
    /// question, and the answer never rides in this.
    get: fn(String) -> Option(Stored),
    /// The sources of a puzzle in rooms that list this guest id or this
    /// account id among their seats, newest first: (puzzle_id, guest_id,
    /// user_id), either of which may be "". The query only narrows -- who
    /// really holds a seat is `rooms/seat.holder`, asked by the handler on
    /// the seats that come back.
    mine: fn(String, String, String) -> List(SourceRoom),
    /// One game of one room's sources, in turn order: (game_id,
    /// game_number). Every qualifying decision, including the ones with no
    /// puzzle, which the caller drops.
    game_sources: fn(String, Int) -> List(Source),
    /// Write this answer down, unless its key is already there: (puzzle_id,
    /// user_id, idempotency key, answer as JSON text, verdict). The row
    /// that comes back is the one that stands, and `fresh` says whether
    /// this call is what wrote it -- which is what stops a retried POST
    /// moving anybody's ladder twice.
    put_attempt: fn(String, String, String, String, String) -> Attempt,
    /// An attempt by the key its own client minted: (puzzle_id, user_id,
    /// key). Scoped to the account, because a key is only unique within
    /// one -- it is a uuid the client made up, and two browsers could pick
    /// the same one. Looking one up by key alone would hand somebody
    /// else's row to whoever guessed it.
    attempt: fn(String, String, String) -> Option(Attempt),
    /// What happened after the deck was asked: (attempt id, scheduled,
    /// review id, outcome, schedule as JSON text). An empty schedule leaves
    /// the one already on the row alone, so a deck action that is not an
    /// answer cannot blank what an answer reported.
    settle_attempt: fn(Int, Bool, Option(Int), Option(String), String) -> Nil,
    /// Decide what one answer does to one account's card with nobody else
    /// deciding the same thing at the same moment: (user_id, puzzle_id,
    /// what to decide).
    ///
    /// Whether an answer counts is read-then-act -- is this attempt row
    /// new, and is the card due -- and two requests that read before either
    /// wrote would both find a due card and both move the ladder. Everything
    /// from writing the attempt row to moving the card runs in here, one
    /// account and one puzzle at a time.
    ///
    /// A refusal is still an answer: the attempt row stands, because the
    /// player did answer, so nothing here rolls back on `Error`.
    serialize: fn(String, String, fn() -> Result(Scheduled, ApiError)) ->
      Result(Scheduled, ApiError),
    /// The payload already built for a puzzle id, as JSON text. A pure
    /// function of the stored question, so a hit is always right, and the
    /// store is bounded and may forget at any time.
    cached_tree: fn(String) -> Option(String),
    keep_tree: fn(String, String) -> Nil,
    /// The same for a turn too big to send whole, kept as the tree itself
    /// rather than as bytes: a level request reads one node out of it and
    /// an attempt walks it, and neither wants to parse a megabyte back.
    /// Opaque here -- it crosses as a term and comes back as it went.
    cached_moves: fn(String) -> Option(moves),
    keep_moves: fn(String, moves) -> Nil,
    /// Draw the link pictures of the puzzles one game just wrote: (game_id,
    /// game_number). Called once `store` has succeeded for that game, and
    /// only from the review job -- a picture is never drawn on a request.
    /// Each render is charged and bounded on its own row
    /// (`Oskol.Puzzles.Pictures`); a picture that does not get drawn is
    /// the sweep's to find, never a reason for a review to fail.
    pictures: fn(String, Int) -> Nil,
    /// Mint a story link, or hand back the one this sharer already has for
    /// this decision: (puzzle_id, source_id, shared_by, shared_name, a fresh
    /// token). One row per (source, sharer), whichever request got there
    /// first, so the token that comes back may not be the one offered.
    mint_share: fn(String, Int, String, String, String) -> String,
    /// A story link by its token, or nothing. The caller checks the puzzle
    /// it names: a token minted for one puzzle says nothing on another.
    share: fn(String) -> Option(Share),
  )
}

pub fn stub() -> PuzzlesCaps(moves) {
  PuzzlesCaps(
    unextracted: fn(_) { panic as "stub puzzles.unextracted" },
    store: fn(_, _, _, _) { panic as "stub puzzles.store" },
    failed: fn(_, _, _) { panic as "stub puzzles.failed" },
    owned_sources: fn(_, _) { panic as "stub puzzles.owned_sources" },
    mark_synced: fn(_) { panic as "stub puzzles.mark_synced" },
    sync_failed: fn(_, _) { panic as "stub puzzles.sync_failed" },
    deck_pending: fn(_, _) { panic as "stub puzzles.deck_pending" },
    guest_sources: fn(_) { panic as "stub puzzles.guest_sources" },
    get: fn(_) { panic as "stub puzzles.get" },
    mine: fn(_, _, _) { panic as "stub puzzles.mine" },
    game_sources: fn(_, _) { panic as "stub puzzles.game_sources" },
    put_attempt: fn(_, _, _, _, _) { panic as "stub puzzles.put_attempt" },
    attempt: fn(_, _, _) { panic as "stub puzzles.attempt" },
    settle_attempt: fn(_, _, _, _, _) { panic as "stub puzzles.settle_attempt" },
    // Nothing to serialize against in a test: run it.
    serialize: fn(_, _, decide) { decide() },
    // A cache that never hits is a correct cache; a test that does not
    // arrange one still gets a tree.
    cached_tree: fn(_) { option.None },
    keep_tree: fn(_, _) { Nil },
    cached_moves: fn(_) { option.None },
    keep_moves: fn(_, _) { Nil },
    pictures: fn(_, _) { panic as "stub puzzles.pictures" },
    mint_share: fn(_, _, _, _, _) { panic as "stub puzzles.mint_share" },
    share: fn(_) { panic as "stub puzzles.share" },
  )
}
