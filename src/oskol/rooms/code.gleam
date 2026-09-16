//// A game code: six characters. Short enough to read out over the phone,
//// and the only thing a player needs to find a table -- which is also the
//// only thing standing between a stranger and a live room, now that no
//// secret rides in a URL.
////
//// The alphabet is Crockford's: the ten digits and the twenty-two letters
//// left after I, L, O and U are dropped. 32^6 is about 1.07 billion codes,
//// far more than a code walk can sweep, and nobody reading one down the
//// phone has to say "that's a letter O, not a zero". Every digit is still
//// in the alphabet, so the six-digit codes minted before this still are
//// codes and every link to one still works.
////
//// `normalise` is the other half of the bargain: a code typed in lower
//// case, or with an O for a zero, still finds its room.

import gleam/list
import gleam/string

pub const length = 6

/// The alphabet, in value order: `from_random` reads a code off it.
pub const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

pub const base = 32

/// How many codes there are: 32^6. A function, not a constant, so the
/// Elixir facade that draws the random number can read it rather than keep
/// its own copy.
pub fn space() -> Int {
  1_073_741_824
}

/// The code for a random non-negative integer. The randomness is the
/// caller's (a capability); the shape of a code is decided here.
pub fn from_random(n: Int) -> String {
  let digits = string.to_graphemes(alphabet)
  encode(n % space(), length, digits, "")
}

fn encode(n: Int, left: Int, digits: List(String), acc: String) -> String {
  case left <= 0 {
    True -> acc
    False -> {
      let char = case list.drop(digits, n % base) {
        [c, ..] -> c
        [] -> "0"
      }
      encode(n / base, left - 1, digits, char <> acc)
    }
  }
}

/// A code as typed, as the code it means: upper case, with the four
/// characters the alphabet leaves out folded onto the ones they are
/// mistaken for. Anything else is passed through untouched, so a string
/// that is not a code stays not a code and simply finds no room.
pub fn normalise(typed: String) -> String {
  typed
  |> string.uppercase
  |> string.to_graphemes
  |> list.map(fold)
  |> string.concat
}

fn fold(char: String) -> String {
  case char {
    "I" | "L" -> "1"
    "O" -> "0"
    "U" -> "V"
    other -> other
  }
}
