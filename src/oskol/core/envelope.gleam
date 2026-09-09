//// The JSON envelope every /papi endpoint speaks:
////
////   {"ok": true, ...payload}
////   {"ok": false, "error": {"code": "...", "message": "..."}}
////
//// Handlers return rendered JSON strings so the shape of a response is a
//// decision Gleam owns; the Elixir controller only picks the status and
//// writes the body.

import gleam/json.{type Json}
import oskol/core/error.{type ApiError}

/// A success envelope: `ok` plus the handler's own fields.
pub fn ok(fields: List(#(String, Json))) -> String {
  json.object([#("ok", json.bool(True)), ..fields])
  |> json.to_string
}

/// The status and body for a failure.
pub fn error(err: ApiError) -> #(Int, String) {
  let body =
    json.object([
      #("ok", json.bool(False)),
      #(
        "error",
        json.object([
          #("code", json.string(error.code(err))),
          #("message", json.string(error.message(err))),
        ]),
      ),
    ])
    |> json.to_string

  #(error.status(err), body)
}
