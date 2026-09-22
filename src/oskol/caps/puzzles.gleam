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
    /// An attempt by the key its own client minted: (puzzle_id, key).
    /// Whose it is, is the handler's to check.
    attempt: fn(String, String) -> Option(Attempt),
    /// What happened after the deck was asked: (attempt id, scheduled,
    /// review id, outcome, schedule as JSON text).
    settle_attempt: fn(Int, Bool, Option(Int), Option(String), String) -> Nil,
    /// The move tree already built for a puzzle id, as JSON text. A pure
    /// function of the stored question, so a hit is always right, and the
    /// store is bounded and may forget at any time.
    cached_tree: fn(String) -> Option(String),
    keep_tree: fn(String, String) -> Nil,
  )
}

pub fn stub() -> PuzzlesCaps {
  PuzzlesCaps(
    unextracted: fn(_) { panic as "stub puzzles.unextracted" },
    store: fn(_, _, _, _) { panic as "stub puzzles.store" },
    failed: fn(_, _, _) { panic as "stub puzzles.failed" },
    get: fn(_) { panic as "stub puzzles.get" },
    mine: fn(_, _, _) { panic as "stub puzzles.mine" },
    game_sources: fn(_, _) { panic as "stub puzzles.game_sources" },
    put_attempt: fn(_, _, _, _, _) { panic as "stub puzzles.put_attempt" },
    attempt: fn(_, _) { panic as "stub puzzles.attempt" },
    settle_attempt: fn(_, _, _, _, _) { panic as "stub puzzles.settle_attempt" },
    // A cache that never hits is a correct cache; a test that does not
    // arrange one still gets a tree.
    cached_tree: fn(_) { option.None },
    keep_tree: fn(_, _) { Nil },
  )
}
