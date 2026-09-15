//// Display preferences kept against the silent guest. A preference is the
//// player's own taste — the wood their board is made of — never anything
//// the room, the engine or the opponent can see. It is display only: no
//// preference ever reaches a scene, an event or the game channel.
////
//// The bag is generic (a jsonb column on `guests`) but what may go in it is
//// not: this module is the whitelist. An unknown key or an unknown value is
//// a refusal with a sentence a player could read, never a silent write —
//// otherwise the column becomes whatever any client felt like posting.

import gleam/list
import gleam/option.{type Option, None, Some}

/// What the site remembers for one guest: key/value pairs, in no particular
/// order.
pub type Prefs =
  List(#(String, String))

/// The backgammon board's colours. Display only.
pub const backgammon_theme = "backgammon_theme"

/// The eight boards, in the order the picker lists them. `walnut` is what a
/// player who has never picked gets, and is the board Oskol shipped with.
pub fn backgammon_themes() -> List(String) {
  ["walnut", "midnight", "forest", "sand", "ivory", "cherry", "slate", "neon"]
}

pub fn default_backgammon_theme() -> String {
  "walnut"
}

/// The value stored under `key`, if anything valid is.
pub fn get(prefs: Prefs, key: String) -> Option(String) {
  case list.key_find(prefs, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Is this a preference the site knows how to keep, at a value it allows?
/// The sentence is the refusal a player reads.
pub fn validate(key: String, value: String) -> Result(#(String, String), String) {
  case key {
    "backgammon_theme" ->
      case list.contains(backgammon_themes(), value) {
        True -> Ok(#(key, value))
        False -> Error("That is not one of the board themes")
      }
    _ -> Error("Unknown preference")
  }
}

/// Only the pairs the whitelist still recognises. A row written by an older
/// release (or a theme that has since been retired) is dropped rather than
/// handed to a client that has no such board.
pub fn known(prefs: Prefs) -> Prefs {
  list.filter(prefs, fn(pair) {
    case validate(pair.0, pair.1) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}
