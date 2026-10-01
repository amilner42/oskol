//// The five decks a player practises, in the order the practice home lists
//// them: the three tiers of their own mistakes, worst first, and the two
//// universal sets.
////
//// A deck here is a name for something that already exists. A tier is a
//// band of the one mistakes learner (`practice/deck`), never a scope of its
//// own -- the three share a ladder, a day and a budget of new mistakes. A
//// set is a registry entry (`practice/decks`) with a scope of its own. This
//// module puts the five side by side so that every page lists them one way,
//// and names each twice: the `id` the wire speaks (the band, or the set's
//// id) and the `slug` its page lives at (`/practice/<slug>`).

import gleam/list
import gleam/string
import oskol/practice/decks

pub type Kind {
  /// A tier of the player's own mistakes: the band its cards count in.
  Mistakes(band: String)
  /// A universal set.
  Set(set: decks.Deck)
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

/// All five, in hub order. The sets come from the registry, so a new set is
/// a registry entry and shows up here with the slug its id makes.
pub fn all() -> List(Deck) {
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

/// The page's URL segment for a set id: "opening_replies" is
/// "opening-replies".
fn slug_of(id: String) -> String {
  string.replace(id, "_", "-")
}

pub fn find_slug(slug: String) -> Result(Deck, Nil) {
  list.find(all(), fn(deck) { deck.slug == slug })
}

pub fn find_id(id: String) -> Result(Deck, Nil) {
  list.find(all(), fn(deck) { deck.id == id })
}

/// The wire's word for a kind.
pub fn kind_name(deck: Deck) -> String {
  case deck.kind {
    Mistakes(_) -> "mistakes"
    Set(_) -> "set"
  }
}
