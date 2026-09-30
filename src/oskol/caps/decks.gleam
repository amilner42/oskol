//// Universal decks: practice decks that are not made of anybody's
//// mistakes and are offered to everyone (the openings, the replies to
//// them, and whatever comes next). Built for real in
//// lib/oskol/gleam/caps/decks.ex -- that file and this one must agree on
//// constructor tags and field order.
////
//// A deck is two things. **Which positions are in it** is data: a
//// `deck_puzzles` row per position, pointing at an ordinary puzzle, written
//// by the operator task that asks the engine (`handlers/decks_build`).
//// **Where a player stands on it** is the same ladder their mistakes use,
//// in a retain scope of its own (`practice`), so a deck's budget of new
//// positions, its queue and its levels never touch any other deck's.
////
//// What a deck is called, how many new positions a day it introduces and
//// what it is for are decisions, and live in `oskol/practice/decks`.

import oskol/caps/practice.{type PracticeCaps}
import oskol/caps/puzzles.{type NewPuzzle}

/// One position of a deck, in the order the deck introduces them.
pub type Member {
  Member(
    puzzle_id: String,
    /// Where it comes in the deck: smallest first.
    position: Int,
    /// "move", "double" or "take", as the puzzle row says.
    kind: String,
    /// The stored question, as JSON text: what a prompt is written from and
    /// what a card's content is, without reading the answer.
    question_json: String,
  )
}

/// What one build's write did, as row counts. A rerun is all zeros.
pub type Stored {
  Stored(
    /// Puzzles whose key was new.
    puzzles: Int,
    /// Stored puzzles whose incomplete answer this build's replaced.
    upgraded: Int,
    /// Membership rows that were new.
    members: Int,
  )
}

pub type DeckCaps {
  DeckCaps(
    /// The practice caps over this retain scope: the same ladder, queue and
    /// budget every mistake is scheduled on, kept apart per deck. The scope
    /// is `oskol/practice/decks.scope`'s, never a deck id on its own.
    practice: fn(String) -> PracticeCaps,
    /// A deck's positions, in its order. Empty for a deck nobody has built.
    members: fn(String) -> List(Member),
    /// How many positions a deck has, without reading them.
    size: fn(String) -> Int,
    /// Write a deck: its puzzles (only where the key is new, upgrading an
    /// incomplete answer as `puzzles.store` does) and its membership, each
    /// puzzle at the position it is paired with, in one transaction. A
    /// member already there keeps its row and takes the new position.
    store: fn(String, List(#(NewPuzzle, Int))) -> Result(Stored, String),
  )
}

pub fn stub() -> DeckCaps {
  DeckCaps(
    practice: fn(_) { panic as "stub decks.practice" },
    members: fn(_) { panic as "stub decks.members" },
    size: fn(_) { panic as "stub decks.size" },
    store: fn(_, _) { panic as "stub decks.store" },
  )
}
