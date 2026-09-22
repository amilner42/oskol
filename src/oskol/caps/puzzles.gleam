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
  )
}

pub fn stub() -> PuzzlesCaps {
  PuzzlesCaps(
    unextracted: fn(_) { panic as "stub puzzles.unextracted" },
    store: fn(_, _, _, _) { panic as "stub puzzles.store" },
  )
}
