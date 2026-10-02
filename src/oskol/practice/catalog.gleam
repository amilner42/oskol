//// The decks a player practices, in the order the practice home lists
//// them: the three tiers of their own mistakes, worst first, the two
//// universal sets, and then an account's own sets, oldest first.
////
//// A deck here is a name for something that already exists. A tier is a
//// band of the one mistakes learner (`practice/deck`), never a scope of its
//// own -- the three share a ladder, a day and a budget of new mistakes. A
//// set is a registry entry (`practice/decks`) with a scope of its own; an
//// own set is the same with an owner (`decks.own`). This module puts them
//// side by side so that every page lists them one way, and names each
//// twice: the `id` the wire speaks (the band, or the set's id) and the
//// `slug` its page lives at (`/practice/<slug>`).

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/core/ctx.{type Ctx}
import oskol/core/session.{type Session}
import oskol/practice/decks

pub type Kind {
  /// A tier of the player's own mistakes: the band its cards count in.
  Mistakes(band: String)
  /// A universal set.
  Set(set: decks.Deck)
  /// A set an account made for itself: private, never on a sitemap.
  Own(set: decks.Deck)
}

pub type Deck {
  Deck(
    /// What the wire calls it: the band ("very_bad") or the set's id.
    id: String,
    /// The URL segment of its page.
    slug: String,
    kind: Kind,
    /// What a player reads it as.
    name: String,
    /// The replay's own mark for a tier (?? ? ?!); a set has none.
    mark: String,
  )
}

/// The five everybody has, in hub order. The sets come from the registry,
/// so a new set is a registry entry and shows up here with the slug its id
/// makes.
pub fn five() -> List(Deck) {
  list.append(
    [
      Deck(
        id: "very_bad",
        slug: "very-bad",
        kind: Mistakes("very_bad"),
        name: "Very bad moves",
        mark: "??",
      ),
      Deck(
        id: "bad",
        slug: "bad",
        kind: Mistakes("bad"),
        name: "Bad moves",
        mark: "?",
      ),
      Deck(
        id: "doubtful",
        slug: "dubious",
        kind: Mistakes("doubtful"),
        name: "Dubious moves",
        mark: "?!",
      ),
    ],
    list.map(decks.all(), fn(set) {
      Deck(
        id: set.id,
        slug: slug_of(set.id),
        kind: Set(set),
        name: set.name,
        mark: "",
      )
    }),
  )
}

/// Every deck this caller has: the five, then an account's own sets by
/// creation. A guest and a stranger have the five, and read nothing.
pub fn all(ctx: Ctx, session: Session) -> List(Deck) {
  list.append(five(), own(ctx, session))
}

fn own(ctx: Ctx, session: Session) -> List(Deck) {
  case session.user_id {
    Some(uid) -> list.map(decks.own(ctx, uid), own_deck)
    None -> []
  }
}

/// An own set as the catalog lists it: its id is its slug (eight
/// characters of the room-code alphabet, which no slug of the five is).
pub fn own_deck(set: decks.Deck) -> Deck {
  Deck(id: set.id, slug: set.id, kind: Own(set), name: set.name, mark: "")
}

/// The page's URL segment for a set id: "opening_replies" is
/// "opening-replies".
fn slug_of(id: String) -> String {
  string.replace(id, "_", "-")
}

/// A deck by its page's slug, as this caller may reach it: one of the
/// five (read without IO), else one of the caller's own sets. Somebody
/// else's set is not found.
pub fn find_slug(ctx: Ctx, session: Session, slug: String) -> Result(Deck, Nil) {
  find_by(ctx, session, fn(deck) { deck.slug == slug })
}

pub fn find_id(ctx: Ctx, session: Session, id: String) -> Result(Deck, Nil) {
  find_by(ctx, session, fn(deck) { deck.id == id })
}

fn find_by(
  ctx: Ctx,
  session: Session,
  keep: fn(Deck) -> Bool,
) -> Result(Deck, Nil) {
  case list.find(five(), keep) {
    Ok(deck) -> Ok(deck)
    Error(Nil) -> list.find(own(ctx, session), keep)
  }
}

/// The wire's word for a kind.
pub fn kind_name(deck: Deck) -> String {
  case deck.kind {
    Mistakes(_) -> "mistakes"
    Set(_) -> "set"
    Own(_) -> "own"
  }
}
