//// An account's username: what the home bar and anything else that names
//// the account shows, instead of its email. Picked when the account is
//// made, from the name the browser last played under as a guest, and
//// unique regardless of case (the database enforces it; this decides what
//// to try).

import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import oskol/rooms/name

/// The names to try, in order, for a new account. The guest's own name
/// first, then the same name with a number (`arie1`, `arie2`...), kept
/// within the length a name may have. A browser that never typed a name
/// is a `player` with a number from the start: a bare "player" would read
/// as nobody in particular.
pub fn candidates(remembered: Option(String)) -> List(String) {
  candidates_for(remembered, "")
}

/// The same, for an account with this id: after the numbered names, one
/// more with a few characters of the id, so a new account always gets a
/// name even when a hundred others share its base (every browser that
/// never typed a name starts from "player").
pub fn candidates_for(
  remembered: Option(String),
  account_id: String,
) -> List(String) {
  let base = case remembered {
    Some(typed) ->
      case name.clean(typed) {
        Ok(clean) -> Ok(clean)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  let numbered = fn(base) {
    list.range(1, 99) |> list.map(fn(n) { with_number(base, n) })
  }
  let named = case base {
    Ok(base) -> [base, ..numbered(base)]
    Error(Nil) -> numbered("player")
  }
  let tag =
    account_id
    |> string.replace("-", "")
    |> string.slice(0, 6)
  case tag {
    "" -> named
    _ -> {
      let root = case base {
        Ok(base) -> base
        Error(Nil) -> "player"
      }
      list.append(named, [
        string.slice(root, 0, name.max_length - 7) <> "_" <> tag,
      ])
    }
  }
}

/// A username a player typed: the display-name rules, with the sentence to
/// show when it breaks one.
pub fn clean(typed: String) -> Result(String, String) {
  case name.clean(typed) {
    Ok(clean) -> Ok(clean)
    Error("Pick a display name first") -> Error("Pick a username first")
    Error(sentence) -> Error(sentence)
  }
}

fn with_number(base: String, n: Int) -> String {
  let number = int.to_string(n)
  string.slice(base, 0, name.max_length - string.length(number)) <> number
}
