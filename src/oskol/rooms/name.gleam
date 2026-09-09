//// A display name: trimmed, bounded, printable. It goes into every payload,
//// the invite URL and the page title, and it grants nothing — a name is not
//// identity, a seat token is.

import gleam/int
import gleam/list
import gleam/string

pub const max_length = 24

/// The name to seat a player under, or the sentence to show them instead.
pub fn clean(name: String) -> Result(String, String) {
  let name = string.trim(name)

  case name {
    "" -> Error("Pick a display name first")
    _ ->
      case string.length(name) > max_length {
        True ->
          Error(
            "Names are " <> int.to_string(max_length) <> " characters at most",
          )
        False ->
          case printable(name) {
            True -> Ok(name)
            False -> Error("Invalid name")
          }
      }
  }
}

/// Unicode "other" (category C): control characters, formatting characters
/// (bidi overrides, zero-width joiners) and private-use codepoints. None of
/// them belong in a name that is rendered in a title and a URL.
fn printable(name: String) -> Bool {
  string.to_utf_codepoints(name)
  |> list.all(fn(point) { !control(string.utf_codepoint_to_int(point)) })
}

const control_ranges = [
  // Cc
  #(0x0000, 0x001F),
  #(0x007F, 0x009F),
  // Cf
  #(0x00AD, 0x00AD),
  #(0x0600, 0x0605),
  #(0x061C, 0x061C),
  #(0x06DD, 0x06DD),
  #(0x070F, 0x070F),
  #(0x08E2, 0x08E2),
  #(0x180E, 0x180E),
  #(0x200B, 0x200F),
  #(0x202A, 0x202E),
  #(0x2060, 0x2064),
  #(0x2066, 0x206F),
  #(0xFEFF, 0xFEFF),
  #(0xFFF9, 0xFFFB),
  #(0x110BD, 0x110BD),
  #(0x110CD, 0x110CD),
  #(0x13430, 0x1343F),
  #(0x1BCA0, 0x1BCA3),
  #(0x1D173, 0x1D17A),
  #(0xE0001, 0xE007F),
  // Co (private use)
  #(0xE000, 0xF8FF),
  #(0xF0000, 0xFFFFD),
  #(0x100000, 0x10FFFD),
]

fn control(point: Int) -> Bool {
  list.any(control_ranges, fn(range) { point >= range.0 && point <= range.1 })
}
