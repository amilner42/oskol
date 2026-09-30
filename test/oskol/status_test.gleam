//// What the status page asks the engine, and what it makes of the answer.
////
//// The point of the page is that a stub cannot pass it, so these are the
//// two halves of that: a request that really describes the stored position
//// (get the cube's owner or the score wrong and the engine answers a
//// different question, convincingly), and a read that reports an answer it
//// did not understand rather than drawing an empty board.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import oskol/puzzles.{type Question, Centered, Move, Mover, Opponent, Question}
import oskol/status

/// A middle-game move question: a checker of each colour on the bar, a
/// turned cube, and a score that is not level, so nothing in the request
/// can be right by accident.
fn a_question() -> Question {
  Question(
    kind: Move,
    board: [
      1, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0,
      -2, 1,
    ],
    dice: Some(#(6, 3)),
    cube_value: 2,
    cube_owner: Mover,
    away_mover: 3,
    away_opponent: 5,
    crawford: False,
    jacoby: False,
  )
}

// ---------- Asking ----------

pub fn the_request_describes_the_stored_position_test() {
  let body = status.request(a_question())

  assert string.contains(body, "\"board\":[1,-2,0")
  assert string.contains(body, "\"dice\":[6,3]")
  assert string.contains(body, "\"cube_value\":2")
  assert string.contains(body, "\"away1\":3")
  assert string.contains(body, "\"away2\":5")
  assert string.contains(body, "\"is_crawford\":false")
}

pub fn the_cube_owner_is_written_in_the_engines_words_test() {
  // `puzzles` names the owner from the solver's side and the engine from
  // the seat's; a request that sent "mover" would be answered as centered.
  let owner = fn(o) { status.request(Question(..a_question(), cube_owner: o)) }

  assert string.contains(owner(Mover), "\"cube_owner\":\"player\"")
  assert string.contains(owner(Opponent), "\"cube_owner\":\"opponent\"")
  assert string.contains(owner(Centered), "\"cube_owner\":\"centered\"")
}

pub fn the_turn_is_asked_not_graded_test() {
  let body = status.request(a_question())

  // Nothing has been played: the page is asking what to play. A request
  // that named a played board would be asking how bad it was.
  assert string.contains(body, "\"played\":null")
  assert string.contains(body, "\"doubled\":false")
  // A turn sent on its own is read as an opening roll unless it says where
  // it sits, and the board is the mover's own, so they are the first seat.
  assert string.contains(body, "\"index\":1")
  assert string.contains(body, "\"player\":0")
}

pub fn luck_is_not_asked_for_test() {
  // It is a number about a roll that already happened, and asking costs
  // another analysis of a position nobody is waiting on.
  assert string.contains(status.request(a_question()), "\"include_luck\":false")
}

// ---------- Reading ----------

fn an_answer(plays: String) -> String {
  "{\"levels\":{\"moves\":\"4ply\",\"cube\":\"4ply\"},\"timing_ms\":2571,"
  <> "\"turns\":[{\"index\":1,\"player\":0,\"move\":"
  <> plays
  <> "}]}"
}

fn a_play(notation: String, equity: String, diff: String, win: String) -> String {
  "{\"rank\":1,\"notation\":\""
  <> notation
  <> "\",\"equity\":"
  <> equity
  <> ",\"equity_diff\":"
  <> diff
  <> ",\"probs\":{\"win\":"
  <> win
  <> ",\"gammon_win\":0.1,\"backgammon_win\":0.0,"
  <> "\"gammon_loss\":0.1,\"backgammon_loss\":0.0}}"
}

pub fn the_plays_come_back_best_first_test() {
  let body =
    an_answer(
      "{\"best\":"
      <> a_play("13/7 8/7", "0.152", "0.0", "0.584")
      <> ",\"top\":["
      <> a_play("13/7 8/7", "0.152", "0.0", "0.584")
      <> ","
      <> a_play("24/18 13/10", "-0.021", "-0.173", "0.551")
      <> "]}",
    )

  let assert Ok(read) = status.read(body)

  assert string.contains(read, "\"notation\":\"13/7 8/7\"")
  assert string.contains(read, "\"notation\":\"24/18 13/10\"")
  assert string.contains(read, "\"level\":\"4ply\"")
  assert string.contains(read, "\"took_ms\":2571")
  // Best first, as the engine ranked them.
  let assert Ok(#(first, _)) = string.split_once(read, "24/18")
  assert string.contains(first, "13/7 8/7")
}

pub fn a_lone_best_play_is_still_an_answer_test() {
  // `top` is what the request asks for, but an engine that sent only the
  // one play has still said something worth printing.
  let body =
    an_answer(
      "{\"best\":" <> a_play("13/7 8/7", "0.152", "0.0", "0.584") <> "}",
    )

  let assert Ok(read) = status.read(body)
  assert string.contains(read, "13/7 8/7")
}

pub fn python_may_write_a_whole_number_without_a_point_test() {
  let body = an_answer("{\"best\":" <> a_play("13/7 8/7", "0", "0", "1") <> "}")

  let assert Ok(read) = status.read(body)
  assert string.contains(read, "\"equity\":0.0")
  assert string.contains(read, "\"win\":1.0")
}

pub fn a_turn_with_no_move_is_reported_not_drawn_empty_test() {
  let body = "{\"turns\":[{\"index\":1,\"player\":0}]}"
  assert status.read(body) == Error("The engine named no play")
}

pub fn an_answer_that_is_not_one_is_an_error_test() {
  assert status.read("{}") == Error("The engine's answer did not read as one")
  assert status.read("not json")
    == Error("The engine's answer did not read as one")
  // What a health stub answers with. It must not read as a board.
  assert status.read("{\"ok\":true}")
    == Error("The engine's answer did not read as one")
}

pub fn an_answer_without_a_depth_or_a_timing_still_reads_test() {
  // Both are the engine talking about itself, and neither is the answer.
  let body =
    "{\"turns\":[{\"move\":{\"best\":"
    <> a_play("13/7 8/7", "0.152", "0.0", "0.584")
    <> "}}]}"

  let assert Ok(read) = status.read(body)
  assert string.contains(read, "\"level\":\"\"")
  assert string.contains(read, "\"took_ms\":0")
}

pub fn the_read_is_json_the_page_can_take_test() {
  // The page decodes this with Jason and prints the fields by name, so a
  // read that is not parseable JSON would fail there and not here.
  let body =
    an_answer(
      "{\"best\":" <> a_play("13/7 8/7", "0.152", "0.0", "0.584") <> "}",
    )

  let assert Ok(read) = status.read(body)
  let shape = {
    use level <- decode.field("level", decode.string)
    use took_ms <- decode.field("took_ms", decode.int)
    use plays <- decode.field("plays", decode.list(decode.dynamic))
    decode.success(#(level, took_ms, list.length(plays)))
  }

  assert json.parse(read, shape) == Ok(#("4ply", 2571, 1))
}
