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
  let assert Ok(body) = status.request(a_question())

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
  let owner = fn(o) {
    let assert Ok(body) =
      status.request(Question(..a_question(), cube_owner: o))
    body
  }

  assert string.contains(owner(Mover), "\"cube_owner\":\"player\"")
  assert string.contains(owner(Opponent), "\"cube_owner\":\"opponent\"")
  assert string.contains(owner(Centered), "\"cube_owner\":\"centered\"")
}

pub fn a_rolled_turn_carries_a_play_test() {
  // The engine's own contract, and what production caught: the review route
  // grades a play, so a turn whose dice were rolled and whose `played` is
  // null is a 422 ("dice were rolled but no move was played"). What the page
  // draws is the answer's `top`, which is the engine's ranking of every play
  // whatever it was sent.
  let assert Ok(body) = status.request(a_question())

  assert !string.contains(body, "\"played\":null")
  assert string.contains(body, "\"played\":[")
  assert string.contains(body, "\"dice\":[6,3]")
}

pub fn the_play_it_carries_is_a_legal_one_test() {
  // 6-3 off this board: 26 ints, the same checkers, and not the board it
  // started on -- a played board that had not moved would be a dance, which
  // is a different answer.
  let assert Ok(body) = status.request(a_question())
  let assert Ok(#(_, after)) = string.split_once(body, "\"played\":")
  let assert Ok(#(played, _)) = string.split_once(after, "]")

  assert string.contains(played, ",")
  assert played != "[1,-2,0,0,0,0,5,0,3,0,0,0,-5,5,0,0,0,-3,0,-5,0,0,0,0,-2,1"
}

pub fn a_question_with_no_roll_is_not_asked_test() {
  // A move question always has one; a stored row that does not is a row to
  // skip, not an engine to call down.
  assert status.request(Question(..a_question(), dice: option.None))
    == Error("a move question with no roll")
}

pub fn a_board_that_is_not_a_board_is_not_asked_test() {
  assert status.request(Question(..a_question(), board: [1, 2, 3]))
    == Error("a stored board that is not the engine's 26 ints")
}

pub fn luck_is_not_asked_for_test() {
  // It is a number about a roll that already happened, and asking costs
  // another analysis of a position nobody is waiting on.
  let assert Ok(body) = status.request(a_question())
  assert string.contains(body, "\"include_luck\":false")
}

// ---------- Reading ----------

fn an_answer(plays: String) -> String {
  "{\"levels\":{\"move\":\"4ply\",\"cube\":\"4ply\",\"luck\":null},\"timing_ms\":2571,"
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

pub fn the_depth_is_read_off_the_key_the_engine_writes_test() {
  // `move`, not `moves`: the page said nothing about its depth for a while
  // because this was wrong, and the engine's own answer is the only place to
  // learn it. An older engine wrote `move: {moves: ...}`; `reviews/report`
  // reads both, so this does too.
  let play = a_play("13/7 8/7", "0.152", "0.0", "0.584")
  let with_levels = fn(levels) {
    "{\"levels\":"
    <> levels
    <> ",\"turns\":[{\"move\":{\"best\":"
    <> play
    <> "}}]}"
  }

  let assert Ok(now) =
    status.read(with_levels("{\"move\":\"4ply\",\"cube\":\"4ply\"}"))
  assert string.contains(now, "\"level\":\"4ply\"")

  let assert Ok(older) =
    status.read(with_levels("{\"move\":{\"moves\":\"3ply\"},\"cube\":\"3ply\"}"))
  assert string.contains(older, "\"level\":\"3ply\"")
}

pub fn only_as_many_plays_as_the_page_asked_to_list_test() {
  // The engine puts the play the turn carried into `top`, so `top` comes
  // back longer than `top_moves` -- and that play is an arbitrary legal one
  // this module chose, which must not be printed as a recommendation.
  let play = fn(n, eq) { a_play(n, eq, "0.0", "0.5") }
  let body =
    "{\"turns\":[{\"move\":{\"best\":"
    <> play("a", "0.4")
    <> ",\"top\":["
    <> play("a", "0.4")
    <> ","
    <> play("b", "0.3")
    <> ","
    <> play("c", "0.2")
    <> ","
    <> play("throwaway", "-0.9")
    <> "]}}]}"

  let assert Ok(read) = status.read(body)
  assert !string.contains(read, "throwaway")
}
