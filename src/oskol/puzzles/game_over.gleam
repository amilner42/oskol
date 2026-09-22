//// How a stored game ended, read off its record.
////
//// A game's record (`game_records`, one row per finished game) ends on one
//// `game_over` line: the winner and the points. Everything else in it is a
//// turn, and none of that is this module's business. The memory line and
//// the shared story both say "and lost 2 points" from it, so the reading
//// lives once, here.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// The winner's player id and the points, from a record's JSON text, or
/// nothing where the record has no `game_over` line (or will not parse).
pub fn of(entries: String) -> Option(#(String, Int)) {
  case json.parse(entries, game_over_decoder()) {
    Ok(found) -> found
    Error(_) -> None
  }
}

fn game_over_decoder() -> decode.Decoder(Option(#(String, Int))) {
  use entries <- decode.then(decode.list(record_entry_decoder()))
  decode.success(
    entries
    |> list.filter_map(option.to_result(_, Nil))
    |> list.first
    |> option.from_result,
  )
}

fn record_entry_decoder() -> decode.Decoder(Option(#(String, Int))) {
  use kind <- decode.optional_field("kind", "", decode.string)
  case kind {
    "game_over" -> {
      use winner <- decode.optional_field("winner", "", decode.string)
      use points <- decode.optional_field("points", 0, decode.int)
      decode.success(Some(#(winner, points)))
    }
    _ -> decode.success(None)
  }
}
