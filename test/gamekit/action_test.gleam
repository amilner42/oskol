//// Incoming action decoding and parameter validation.

import gamekit/action
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}

fn parsed(text: String) -> Dynamic {
  let assert Ok(d) = json.parse(text, decode.dynamic)
  d
}

pub fn incoming_accepts_a_missing_params_object_test() {
  let assert Ok(incoming) =
    action.decode_incoming(parsed("{\"name\":\"roll\"}"))
  assert incoming.name == "roll"
  assert action.string_param(incoming.params, "x")
    == Error("Missing or invalid param: x")
  assert action.optional_ids_param(incoming.params, "cards") == []
}

pub fn incoming_rejects_the_wrong_shape_test() {
  let malformed = Error("Malformed action: expected {name, params}")
  assert action.decode_incoming(parsed("{\"params\":{}}")) == malformed
  assert action.decode_incoming(parsed("[]")) == malformed
  assert action.decode_incoming(parsed("{\"name\":7}")) == malformed
  assert action.decode_incoming(parsed("\"roll\"")) == malformed
}

pub fn params_are_read_with_their_types_test() {
  let p =
    parsed(
      "{\"cards\":[\"AS\",\"KD\"],\"from\":\"13\",\"n\":3,\"bad\":\"x\",\"mixed\":[\"a\",1]}",
    )
  assert action.ids_param(p, "cards") == Ok(["AS", "KD"])
  assert action.string_param(p, "from") == Ok("13")
  assert action.int_param(p, "n") == Ok(3)
  assert action.int_param(p, "bad") == Error("Missing or invalid param: bad")
  assert action.ids_param(p, "from") == Error("Missing or invalid param: from")
  assert action.ids_param(p, "mixed")
    == Error("Missing or invalid param: mixed")
  assert action.string_param(p, "n") == Error("Missing or invalid param: n")
  assert action.optional_ids_param(p, "missing") == []
  assert action.optional_ids_param(p, "cards") == ["AS", "KD"]
  assert action.optional_ids_param(p, "mixed") == []
}

pub fn validate_select_checks_candidates_count_and_duplicates_test() {
  let param = action.select("cards", "hand:p1", ["AS", "KD", "2C"], 1, 2)
  assert action.validate_select(param, ["AS"]) == Ok(Nil)
  assert action.validate_select(param, ["KD", "AS"]) == Ok(Nil)
  assert action.validate_select(param, [])
    == Error("Wrong number of selections for cards")
  assert action.validate_select(param, ["AS", "KD", "2C"])
    == Error("Wrong number of selections for cards")
  assert action.validate_select(param, ["AS", "AS"])
    == Error("Selection contains duplicates for cards")
  assert action.validate_select(param, ["ZZ"])
    == Error("Selection contains an invalid candidate for cards")
  assert action.validate_select(action.number("n", 1, 3), ["1"])
    == Error("n is not a selection")
}

pub fn find_looks_up_a_schema_by_name_test() {
  let roll = action.simple("roll", "Roll")
  assert action.find([roll], "roll") == Some(roll)
  assert action.find([roll], "play") == None
  assert action.find([], "roll") == None
}
