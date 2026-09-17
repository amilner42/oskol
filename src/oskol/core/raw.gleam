//// JSON that is already JSON.
////
//// A finished game's record and its rendered analysis are built once and
//// stored as jsonb. Serving them means putting stored text back on the
//// wire inside a larger envelope, without taking it apart and building it
//// again: `json` does that, and `text` goes the other way for the one
//// place that has to split a built document into the rows it is stored as.
////
//// Only ever give `json` text that is valid JSON -- everything handed to
//// it here has been through Postgres's jsonb, or came from
//// `gleam/json.to_string`.

import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}

/// A string of valid JSON as a Json value, verbatim.
@external(erlang, "oskol_json_ffi", "raw")
pub fn json(text: String) -> Json

/// Decoded JSON data (what `decode.dynamic` hands back from a parse) as
/// JSON text again. Object keys come back in no particular order, which is
/// what jsonb does to them anyway.
@external(erlang, "oskol_json_ffi", "encode")
pub fn text(value: Dynamic) -> String
