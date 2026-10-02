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

import backgammon/analysis.{Position, Turn}
import backgammon/board
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/analysis/rolls
import oskol/core/raw
import oskol/puzzles/fixture
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

// ---------- The per-roll grid on a turn ----------

/// Every answer stored before the grid existed carries none, and the page
/// rendered from one says `null` rather than inventing an empty grid. The
/// replay asks for those on demand instead.
pub fn an_answer_from_before_the_grid_has_no_grid_test() {
  list.each(stored_answers(), fn(body) {
    let assert Ok(review) = report.parse(body)
    assert list.all(review.turns, fn(turn) { turn.rolls == None })
  })
  let assert Ok(review) = report.parse(one_turn(""))
  assert json.to_string(page_of(review)) |> string.contains("\"rolls\":null")
}

/// A turn the engine sent a grid for reads it, and the page carries it as
/// cells: one shape and one field name, whether the number in it is a
/// position's equity or the difference between two plays.
pub fn a_turn_with_a_grid_renders_its_cells_test() {
  let grid = fixture.rolls_sample("opening")
  let body = one_turn(",\"rolls\":" <> fixture.rolls_answer("opening"))
  let assert Ok(review) = report.parse(body)
  let assert [turn] = review.turns
  let assert Some(read) = turn.rolls
  assert read.level == analysis.rolls_level
  assert list.length(read.rows) == 21
  assert float.loosely_equals(rolls.mean(read), grid.equity, 0.0000001)

  let page = json.to_string(page_of(review))
  assert string.contains(page, "\"rolls\":{\"level\":\"3ply\"")
  // Twenty-one cells (the turn's own dice is the twenty-second), each the
  // roll's own equity; the rows themselves never leave, and nothing on the
  // wire says anything about colour.
  assert count(page, "\"dice\":[") == 22
  assert string.contains(page, "\"value\":0.586184561252594")
  assert !string.contains(page, "\"rows\"")
  assert !string.contains(page, "band")
}

fn count(text: String, part: String) -> Int {
  list.length(string.split(text, part)) - 1
}

/// One graded turn of a review, with whatever extra field a test wants on it.
fn one_turn(extra: String) -> String {
  let totals =
    "{\"moves\":{\"decisions\":1,\"forced\":0,\"error\":0,\"grades\":{}},\"cube\":{\"decisions\":0,\"error\":0,\"mistakes\":{}},\"luck\":0,\"error\":0,\"pr\":0}"
  "{\"turns\":[{\"index\":0,\"player\":0,\"cube\":null,\"move\":null,\"luck\":null"
  <> extra
  <> "}],\"players\":["
  <> totals
  <> ","
  <> totals
  <> "]}"
}

/// That turn as the page renders it.
fn page_of(review: report.Review) -> json.Json {
  let board = analysis.encode(board.initial(), board.White)
  let turn =
    Turn(
      player: 0,
      player_id: "p1",
      position: Position(
        board: board,
        cube_value: 1,
        cube_owner: "centered",
        away1: 0,
        away2: 0,
        crawford: False,
      ),
      double: None,
      dice: Some(#(3, 1)),
      played: Some(board),
      log_index: 0,
      entry: Some(0),
      double_entry: None,
      answer_entry: None,
    )
  let seats = [
    report.Seat("p1", "Alice", "white"),
    report.Seat("p2", "Bob", "black"),
  ]
  let assert Ok(page) = report.to_json(review, [turn], seats)
  page
}
