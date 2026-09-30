//// The engine's own answers, read back.
////
//// A review assembled out of turns graded one at a time is the engine's
//// answer for every turn and exactly one thing worked out here: the seats'
//// totals. So the totals have to be the engine's arithmetic, to the last
//// float -- and the only way to know that is to take answers the engine
//// really gave and add them up again.
////
//// The answers are the twelve games of the seeded match at 821900
//// (`priv/dev/rooms/821900.json`, what `mix oskol.seed` plants): 57-turn
//// games with cubes offered, taken and dropped, dances, gammons and a
//// Crawford game, graded at 4-ply by the real engine.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import oskol/core/raw
import oskol/reviews/report

@external(erlang, "oskol_test_files", "read")
fn read_file(path: String) -> Result(BitArray, Dynamic)

const room = "priv/dev/rooms/821900.json"

/// Every stored engine answer in the seeded room, as the text it was stored
/// as.
fn stored_answers() -> List(String) {
  let assert Ok(bytes) = read_file(room)
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert Ok(answers) =
    json.parse(
      text,
      decode.at(
        ["reviews"],
        decode.list({
          use response <- decode.field("response", decode.dynamic)
          decode.success(response)
        }),
      ),
    )
  list.map(answers, raw.text)
}

pub fn a_games_totals_are_its_turns_added_up_test() {
  let answers = stored_answers()
  // The fixture is the whole seeded match; a smaller one would not have a
  // Crawford game or a dropped cube in it.
  assert list.length(answers) == 12
  list.each(answers, fn(body) {
    let assert Ok(review) = report.parse(body)
    assert report.totals_of(review.turns) == review.players
  })
}

pub fn a_review_assembled_from_its_turns_is_the_same_review_test() {
  list.each(stored_answers(), fn(body) {
    let assert Ok(engines) = report.parse(body)
    // Each turn on its own, as a grade of it is stored, and then put back
    // together the way the end-of-game job puts one together.
    let assert Ok(parts) = report.graded_turns(body)
    let assert Ok(assembled) = report.assemble(parts)
    let assert Ok(ours) = report.parse(json.to_string(assembled))

    assert ours.turns == engines.turns
    assert ours.players == engines.players
    assert ours.levels == engines.levels
  })
}

pub fn an_assembled_review_says_so_and_adds_up_what_it_cost_test() {
  let assert [body, ..] = stored_answers()
  let assert Ok(parts) = report.graded_turns(body)
  let assert Ok(assembled) = report.assemble(parts)
  let text = json.to_string(assembled)
  let assert Ok(flag) = json.parse(text, decode.at(["assembled"], decode.bool))
  assert flag
  // The engine times a request; the parts of one share its time, so what
  // the parts cost between them is what the request cost.
  let assert Ok(review) = report.parse(body)
  let assert Ok(ours) = report.parse(text)
  let assert Some(theirs_ms) = review.timing_ms
  let assert Some(ours_ms) = ours.timing_ms
  // Integer division of one request's time over its turns, so the total is
  // that time give or take one millisecond a turn.
  assert ours_ms <= theirs_ms
  assert theirs_ms - ours_ms < list.length(review.turns)
}

pub fn turns_out_of_order_are_not_a_review_test() {
  let assert [body, ..] = stored_answers()
  let assert Ok(parts) = report.graded_turns(body)
  // A cache that answered with somebody else's turn would grade the wrong
  // positions and say nothing about it, so assembly refuses a set that is
  // not this game's turns in order.
  let assert Error(_) = report.assemble(list.reverse(parts))
  let assert Error(_) = report.assemble(list.drop(parts, 1))
  let assert Ok(_) = report.assemble(parts)
  Nil
}

pub fn a_grade_that_is_not_one_turn_is_not_a_grade_test() {
  let assert [body, ..] = stored_answers()
  let assert Ok(parts) = report.graded_turns(body)
  assert list.length(parts) > 1
  let assert Error(_) = report.graded_turns("{}")
  let assert Error(_) = report.graded_turns("not json")
  // A response with turns it cannot read is no answer at all.
  let assert Error(_) =
    report.graded_turns("{\"turns\":[{\"index\":\"first\"}]}")
  Nil
}
