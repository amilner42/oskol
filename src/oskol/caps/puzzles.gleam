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

pub type PuzzlesCaps {
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
      Result(Nil, String),
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
    /// Draw the link pictures of the puzzles one game just wrote: (game_id,
    /// game_number). Called once `store` has succeeded for that game, and
    /// only from the review job -- a picture is never drawn on a request.
    /// Each render is charged and bounded on its own row
    /// (`Oskol.Puzzles.Pictures`); a picture that does not get drawn is
    /// the sweep's to find, never a reason for a review to fail.
    pictures: fn(String, Int) -> Nil,
  )
}

pub fn stub() -> PuzzlesCaps {
  PuzzlesCaps(
    unextracted: fn(_) { panic as "stub puzzles.unextracted" },
    store: fn(_, _, _, _) { panic as "stub puzzles.store" },
    failed: fn(_, _, _) { panic as "stub puzzles.failed" },
    owned_sources: fn(_, _) { panic as "stub puzzles.owned_sources" },
    mark_synced: fn(_) { panic as "stub puzzles.mark_synced" },
    sync_failed: fn(_, _) { panic as "stub puzzles.sync_failed" },
    deck_pending: fn(_, _) { panic as "stub puzzles.deck_pending" },
    guest_sources: fn(_) { panic as "stub puzzles.guest_sources" },
    pictures: fn(_, _) { panic as "stub puzzles.pictures" },
  )
}
