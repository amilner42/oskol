//// Action schemas: how a client discovers what a player may do.
////
//// Instead of enumerating every legal move, a game describes each available
//// action as a schema: a name plus parameters, where each parameter says which
//// tokens or options are valid candidates right now. The client derives the
//// click-to-select flow from the schema and the engine only ever receives a
//// complete action.
////
//// Incoming actions are JSON of the shape `{"name": ..., "params": {...}}`.
//// Each game decodes its own params; helpers below cover the common cases.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type ParamKind {
  /// Choose `min..max` tokens from the candidate ids (which live in `zone`).
  Select(zone: String, candidates: List(String), min: Int, max: Int)
  /// Choose exactly one option by id.
  Choice(options: List(#(String, String)))
  /// Choose an integer in a range.
  Number(min: Int, max: Int)
}

pub type Param {
  Param(name: String, kind: ParamKind)
}

pub type Schema {
  Schema(name: String, label: String, params: List(Param))
}

/// An action with no parameters (pass, ready, confirm).
pub fn simple(name: String, label: String) -> Schema {
  Schema(name: name, label: label, params: [])
}

pub fn select(
  name: String,
  zone: String,
  candidates: List(String),
  min: Int,
  max: Int,
) -> Param {
  Param(name: name, kind: Select(zone, candidates, min, max))
}

pub fn choice(name: String, options: List(#(String, String))) -> Param {
  Param(name: name, kind: Choice(options))
}

pub fn number(name: String, min: Int, max: Int) -> Param {
  Param(name: name, kind: Number(min, max))
}

// ---------- JSON out ----------

pub fn to_json(schema: Schema) -> Json {
  json.object([
    #("name", json.string(schema.name)),
    #("label", json.string(schema.label)),
    #("params", json.array(schema.params, param_to_json)),
  ])
}

fn param_to_json(param: Param) -> Json {
  let kind = case param.kind {
    Select(zone, candidates, min, max) -> [
      #("type", json.string("select")),
      #("zone", json.string(zone)),
      #("candidates", json.array(candidates, json.string)),
      #("min", json.int(min)),
      #("max", json.int(max)),
    ]
    Choice(options) -> [
      #("type", json.string("choice")),
      #(
        "options",
        json.array(options, fn(o) {
          json.object([#("id", json.string(o.0)), #("label", json.string(o.1))])
        }),
      ),
    ]
    Number(min, max) -> [
      #("type", json.string("number")),
      #("min", json.int(min)),
      #("max", json.int(max)),
    ]
  }
  json.object([#("name", json.string(param.name)), ..kind])
}

// ---------- JSON in ----------

/// A raw incoming action: its name and its params object, still dynamic so
/// each game can decode the params it expects.
pub type Incoming {
  Incoming(name: String, params: Dynamic)
}

pub fn incoming_decoder() -> decode.Decoder(Incoming) {
  use name <- decode.field("name", decode.string)
  use params <- decode.optional_field("params", dynamic.nil(), decode.dynamic)
  decode.success(Incoming(name: name, params: params))
}

pub fn decode_incoming(value: Dynamic) -> Result(Incoming, String) {
  case decode.run(value, incoming_decoder()) {
    Ok(incoming) -> Ok(incoming)
    Error(_) -> Error("Malformed action: expected {name, params}")
  }
}

/// Read a string param.
pub fn string_param(params: Dynamic, name: String) -> Result(String, String) {
  run(params, decode.field(name, decode.string, decode.success), name)
}

/// Read a list-of-strings param (token ids).
pub fn ids_param(params: Dynamic, name: String) -> Result(List(String), String) {
  run(
    params,
    decode.field(name, decode.list(decode.string), decode.success),
    name,
  )
}

/// Read an optional list-of-strings param, defaulting to empty.
pub fn optional_ids_param(params: Dynamic, name: String) -> List(String) {
  case
    decode.run(
      params,
      decode.optional_field(
        name,
        [],
        decode.list(decode.string),
        decode.success,
      ),
    )
  {
    Ok(ids) -> ids
    Error(_) -> []
  }
}

pub fn int_param(params: Dynamic, name: String) -> Result(Int, String) {
  run(params, decode.field(name, decode.int, decode.success), name)
}

fn run(
  params: Dynamic,
  decoder: decode.Decoder(a),
  name: String,
) -> Result(a, String) {
  case decode.run(params, decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("Missing or invalid param: " <> name)
  }
}

/// Validate a selection against a schema param: every id must be a candidate
/// and the count must fall within min..max.
pub fn validate_select(
  param: Param,
  chosen: List(String),
) -> Result(Nil, String) {
  case param.kind {
    Select(_, candidates, min, max) -> {
      let count = list.length(chosen)
      let all_valid = list.all(chosen, fn(id) { list.contains(candidates, id) })
      let unique = list.length(list.unique(chosen)) == count
      case all_valid, unique, count >= min, count <= max {
        True, True, True, True -> Ok(Nil)
        False, _, _, _ ->
          Error("Selection contains an invalid candidate for " <> param.name)
        _, False, _, _ ->
          Error("Selection contains duplicates for " <> param.name)
        _, _, _, _ -> Error("Wrong number of selections for " <> param.name)
      }
    }
    _ -> Error(param.name <> " is not a selection")
  }
}

/// Find a schema by action name.
pub fn find(schemas: List(Schema), name: String) -> Option(Schema) {
  case list.find(schemas, fn(s) { s.name == name }) {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
}
