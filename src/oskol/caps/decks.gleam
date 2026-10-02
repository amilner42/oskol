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
//// A player's own sets (`OwnDeck`) are the same machinery with an owner:
//// a `decks` row says who it belongs to and what it is called, and its
//// positions are `deck_puzzles` rows under its id like any other deck's.
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

/// A player's own set, as its row says (`decks`): never one of the
/// registry's, whose ids are lowercase words where these are eight
/// characters of the room-code alphabet.
pub type OwnDeck {
  OwnDeck(id: String, user_id: String, name: String, new_per_day: Int)
}

/// Why a write to an own set's row was refused by the row itself: the
/// owner already has a live set of that name (any case), or the minted id
/// is somebody's already.
pub type Refusal {
  NameTaken
  IdTaken
}

/// What putting a position into a set did: whether the membership row is
/// new, and where the position stands in the set either way.
pub type Added {
  Added(added: Bool, position: Int)
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
    /// An account's own sets that are not deleted, oldest first.
    own: fn(String) -> List(OwnDeck),
    /// Write a new own set: (user id, id, name, new per day). The name is
    /// already trimmed and checked; the row's unique index is the last word
    /// on a name taken by a request racing this one.
    create: fn(String, String, String, Int) -> Result(OwnDeck, Refusal),
    /// Rename a live own set: (id, name).
    rename: fn(String, String) -> Result(OwnDeck, Refusal),
    /// Soft-delete an own set: it leaves `own`, and its membership and its
    /// ladder stay where they are.
    delete: fn(String) -> Nil,
    /// Put a puzzle into a set at the end (one past its highest position),
    /// or leave it where it is if it is there already.
    add_member: fn(String, String) -> Added,
    /// Take a puzzle out of a set. True if a row went.
    remove_member: fn(String, String) -> Bool,
  )
}

pub fn stub() -> DeckCaps {
  DeckCaps(
    practice: fn(_) { panic as "stub decks.practice" },
    members: fn(_) { panic as "stub decks.members" },
    size: fn(_) { panic as "stub decks.size" },
    store: fn(_, _) { panic as "stub decks.store" },
    own: fn(_) { panic as "stub decks.own" },
    create: fn(_, _, _, _) { panic as "stub decks.create" },
    rename: fn(_, _) { panic as "stub decks.rename" },
    delete: fn(_) { panic as "stub decks.delete" },
    add_member: fn(_, _) { panic as "stub decks.add_member" },
    remove_member: fn(_, _) { panic as "stub decks.remove_member" },
  )
}
