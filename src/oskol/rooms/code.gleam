//// A game code: six digits. Short enough to read out over the phone, and
//// the only thing a player needs to find a table.

import gleam/int
import gleam/string

/// How many codes there are.
pub const space = 1_000_000

pub const length = 6

/// The code for a random non-negative integer. The randomness is the
/// caller's (a capability); the shape of a code is decided here.
pub fn from_random(n: Int) -> String {
  n % space
  |> int.to_string
  |> string.pad_start(to: length, with: "0")
}
