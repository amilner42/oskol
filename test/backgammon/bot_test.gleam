//// Sage, on positions where the right answer is known.
////
//// The engine is the pure fake in `backgammon/bot` -- it plays the first
//// legal sequence and never doubles, always takes -- so what these assert is
//// the brain around it: which question gets asked at all, that the board the
//// engine picks is found among Oskol's own legal sequences, and the answers
//// it comes to with no engine involved.

import backgammon/board.{type Board, Bar, Black, Off, Point, White}
import backgammon/bot
import backgammon/engine
import backgammon/game as backgammon
import backgammon/positions
import backgammon/state
import gamekit/action
import gamekit/game
import gamekit/rng
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result

const sage = "p2"

const human = "p1"

// ---------- Ground ----------

fn a_game(format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) = backgammon.init(f.config, positions.seats(), rng.seed(3))
  s
}

/// Sage plays Black (the second seat), on roll, with `board` in front of it.
fn sages_turn(format: String, b: Board) -> state.GameState {
  state.GameState(
    ..a_game(format),
    board: b,
    turn_board: b,
    phase: state.Rolling(Black),
  )
}

/// The same, with the dice already rolled and nothing staged. A roll of
/// doubles puts four dice on the table, as `roll` does.
fn sage_to_move(format: String, b: Board, roll: List(Int)) -> state.GameState {
  let s = state.GameState(..sages_turn(format, b), last_roll: roll)
  state.GameState(..s, phase: state.Moving(Black, state.turn_dice(s)))
}

/// An engine that must not be called: every test that says "no question was
/// asked" leans on this rather than on counting.
fn no_engine(_route: String, _body: String) -> Result(String, String) {
  panic as "Sage asked the engine a question it did not need to ask"
}

/// An engine that never answers.
fn dead_engine(_route: String, _body: String) -> Result(String, String) {
  Error("connection refused")
}

/// What Sage decided, as the actions alone. How each is paced has tests of
/// its own (`paces`).
fn decided(
  s: state.GameState,
  player_id: String,
  ask: game.Ask,
  attempts: Int,
) -> Result(List(Json), String) {
  bot.decide(s, player_id, ask, attempts)
  |> result.map(list.map(_, fn(decided: game.BotAction) { decided.action }))
}

/// How Sage decided to pace each action, in order.
fn paces(s: state.GameState, ask: game.Ask) -> Result(List(game.Pace), String) {
  bot.decide(s, sage, ask, 0)
  |> result.map(list.map(_, fn(decided: game.BotAction) { decided.pace }))
}

fn action(name: String) -> Json {
  json.object([#("name", json.string(name)), #("params", json.object([]))])
}

// ---------- Between games, and other questions with no engine in them ----------

pub fn between_games_sage_says_ready_test() {
  let s = a_game("match3")
  let over =
    state.GameState(
      ..s,
      phase: state.BetweenGames(
        state.GameEnd(
          winner: human,
          kind: state.Won(board.Single),
          points: 1,
          cube: 1,
          match_over: False,
        ),
        [],
      ),
    )

  assert decided(over, sage, no_engine, 0) == Ok([action("ready")])
}

pub fn between_games_sage_says_ready_only_once_test() {
  let s = a_game("match3")
  let over =
    state.GameState(
      ..s,
      phase: state.BetweenGames(
        state.GameEnd(
          winner: human,
          kind: state.Won(board.Single),
          points: 1,
          cube: 1,
          match_over: False,
        ),
        [sage],
      ),
    )

  assert decided(over, sage, no_engine, 0) == Ok([])
}

pub fn a_turn_that_is_not_sages_is_nothing_to_do_test() {
  let s = sages_turn("single", board.initial())
  let theirs = state.GameState(..s, phase: state.Rolling(White))

  assert decided(theirs, sage, no_engine, 0) == Ok([])
}

pub fn a_roll_that_plays_nothing_is_committed_test() {
  // Black is on the bar against a closed board: the roll is dead.
  let shut =
    positions.setup([
      #(Black, Bar, 1),
      #(Black, Point(1), 14),
      #(White, Point(19), 2),
      #(White, Point(20), 2),
      #(White, Point(21), 2),
      #(White, Point(22), 2),
      #(White, Point(23), 2),
      #(White, Point(24), 2),
      #(White, Off, 3),
    ])
  let s =
    state.GameState(..sage_to_move("single", shut, [3, 1]), turn_dead: True)

  assert decided(s, sage, no_engine, 0) == Ok([action("play")])
}

// ---------- The cube ----------

pub fn a_game_with_no_cube_is_rolled_without_asking_test() {
  // A single game is one point each way: nothing to double for, and the
  // engine has no opinion about a cube that cannot be turned.
  let s = sages_turn("single", board.initial())

  assert decided(s, sage, no_engine, 0) == Ok([action("roll")])
}

pub fn the_crawford_game_is_rolled_without_asking_test() {
  let s = sages_turn("match3", board.initial())
  let crawford = state.GameState(..s, crawford: True)

  assert decided(crawford, sage, no_engine, 0) == Ok([action("roll")])
}

pub fn a_live_cube_is_asked_about_and_this_one_says_roll_test() {
  // The fake engine never doubles.
  let s = sages_turn("unlimited", board.initial())

  assert decided(s, sage, bot.fake_answer, 0) == Ok([action("roll")])
}

pub fn a_double_is_answered_from_the_doublers_side_test() {
  // The fake engine always takes.
  let s = sages_turn("unlimited", board.initial())
  let doubled = state.GameState(..s, phase: state.Doubled(White))

  assert decided(doubled, sage, bot.fake_answer, 0) == Ok([action("take")])
}

// ---------- Pacing ----------
//
// The platform turns these into milliseconds; what the game owes it is the
// right moment for each action. The dice must be seen to land before a
// checker moves, and a cube action must be seen coming.

pub fn the_roll_settles_before_anything_else_happens_test() {
  let s = sages_turn("unlimited", board.initial())
  assert paces(s, bot.fake_answer) == Ok([game.Settle])
}

pub fn a_take_is_held_a_beat_test() {
  let s = sages_turn("unlimited", board.initial())
  let doubled = state.GameState(..s, phase: state.Doubled(White))
  assert paces(doubled, bot.fake_answer) == Ok([game.Beat])
}

pub fn checkers_go_one_step_at_a_time_test() {
  let s = sage_to_move("single", board.initial(), [3, 1])
  assert paces(s, bot.fake_answer) == Ok([game.Step, game.Step, game.Step])
}

// ---------- The move ----------

pub fn the_engines_play_is_found_among_the_legal_sequences_test() {
  let s = sage_to_move("single", board.initial(), [3, 1])
  let assert Ok(actions) = decided(s, sage, bot.fake_answer, 0)

  // Two moves and the commit.
  assert list.length(actions) == 3
  let assert Ok(last) = list.last(actions)
  assert last == action("play")

  // And they are actions the game takes: a play the engine picked that Oskol
  // would not let Sage make is the one bug that matters here, and it cannot
  // hide behind a comparison of two lists we made up.
  let assert Ok(after) = plays(s, sage, actions)
  assert after.phase == state.Rolling(White)
  assert after.staged == []
}

pub fn doubles_are_four_moves_test() {
  let s = sage_to_move("single", board.initial(), [2, 2])
  let assert Ok(actions) = decided(s, sage, bot.fake_answer, 0)

  assert list.length(actions) == 5
  let assert Ok(after) = plays(s, sage, actions)
  assert after.phase == state.Rolling(White)
}

pub fn staged_moves_are_taken_off_before_the_turn_is_replayed_test() {
  // A half-applied think: two moves are staged, and the sequence below was
  // worked out from the board the turn opened on, so the staging comes off.
  let s = sage_to_move("single", board.initial(), [3, 1])
  let assert [first, ..] = board.sequences(board.initial(), Black, [3, 1])
  let assert [one, ..] = first
  let #(after, mover, _) = board.apply_move(board.initial(), Black, one)
  let staged =
    state.GameState(..s, board: after, phase: state.Moving(Black, [3]), staged: [
      state.Staged(
        move: one,
        mover: mover,
        hit: None,
        board_before: board.initial(),
      ),
    ])

  let assert Ok(actions) = decided(staged, sage, bot.fake_answer, 0)
  let assert Ok(head) = list.first(actions)
  assert head == action("undo")
  assert list.length(actions) == 4
  let assert Ok(after) = plays(staged, sage, actions)
  assert after.phase == state.Rolling(White)
}

// ---------- A resignation offered to Sage ----------

pub fn a_resignation_worth_what_the_board_is_worth_is_accepted_test() {
  // White has a checker off, so a win from here is a single however it ends,
  // and a single is what is on offer.
  let losing =
    positions.setup([
      #(White, Point(3), 14),
      #(White, Off, 1),
      #(Black, Point(22), 1),
      #(Black, Off, 14),
    ])
  let s = sages_turn("unlimited", losing)
  let offered =
    state.GameState(
      ..s,
      resign_offer: Some(state.ResignOffer(White, board.Single)),
    )

  assert board.win_kind(losing, Black) == board.Single
  assert decided(offered, sage, no_engine, 0) == Ok([action("accept_resign")])
}

pub fn a_resignation_worth_more_than_the_board_is_accepted_too_test() {
  let losing =
    positions.setup([
      #(White, Point(3), 14),
      #(White, Off, 1),
      #(Black, Point(22), 1),
      #(Black, Off, 14),
    ])
  let s = sages_turn("unlimited", losing)
  let offered =
    state.GameState(
      ..s,
      resign_offer: Some(state.ResignOffer(White, board.Gammon)),
    )

  assert decided(offered, sage, no_engine, 0) == Ok([action("accept_resign")])
}

pub fn a_resignation_worth_less_than_the_board_is_declined_test() {
  // White has borne nothing off and is shut out of Black's home board: a
  // win from here is a backgammon, so a single is not enough.
  let crushing =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(24), 14),
      #(Black, Point(1), 1),
      #(Black, Off, 14),
    ])
  let s = sages_turn("unlimited", crushing)
  let offered =
    state.GameState(
      ..s,
      turn_board: crushing,
      resign_offer: Some(state.ResignOffer(White, board.Single)),
    )

  assert decided(offered, sage, no_engine, 0) == Ok([action("decline_resign")])
}

pub fn a_resignation_sage_offered_is_not_sages_to_answer_test() {
  let s = sages_turn("unlimited", board.initial())
  let offered =
    state.GameState(
      ..s,
      resign_offer: Some(state.ResignOffer(Black, board.Single)),
    )

  assert decided(offered, sage, no_engine, 0) == Ok([])
}

// ---------- An engine that has stopped answering ----------

pub fn an_engine_that_does_not_answer_is_a_failure_at_first_test() {
  let s = sage_to_move("single", board.initial(), [3, 1])

  assert decided(s, sage, dead_engine, 0) == Error("connection refused")
}

pub fn an_engine_that_never_answers_never_ends_the_game_test() {
  let s = sage_to_move("single", board.initial(), [3, 1])

  // However many asks have already failed, a failure is still a failure and
  // nothing is played. It must never become a resignation: an engine we
  // cannot reach is our problem, not a position, and a resignation is a
  // result -- points, a rating, a review, all of it written down. A board
  // that has not moved can be recovered by the engine coming back; a result
  // cannot be taken back. (2026-09-30: it was, by hand, in production.)
  assert decided(s, sage, dead_engine, 0) == Error("connection refused")
  assert decided(s, sage, dead_engine, 3) == Error("connection refused")
  assert decided(s, sage, dead_engine, 99) == Error("connection refused")
}

pub fn a_run_of_failures_never_touches_a_turn_that_needs_no_engine_test() {
  // Between games there is nothing to ask, so a run of failures elsewhere
  // leaves READY exactly as it was.
  let s = a_game("match3")
  let over =
    state.GameState(
      ..s,
      phase: state.BetweenGames(
        state.GameEnd(
          winner: human,
          kind: state.Won(board.Single),
          points: 1,
          cube: 1,
          match_over: False,
        ),
        [],
      ),
    )

  assert decided(over, sage, no_engine, 99) == Ok([action("ready")])
}

// ---------- The fake engine ----------

pub fn the_fake_engine_knows_only_the_review_route_test() {
  let assert Error(_) = bot.fake_answer("/backgammon/moves", "{}")
}

/// Put Sage's actions through the game the way the room does: the same
/// decode and the same `apply`, one after another.
fn plays(
  s: state.GameState,
  player_id: String,
  actions: List(Json),
) -> Result(state.GameState, String) {
  list.try_fold(actions, s, fn(so_far, raw) {
    let assert Ok(dynamic) = json.parse(json.to_string(raw), decode.dynamic)
    use incoming <- result.try(action.decode_incoming(dynamic))
    use decoded <- result.try(backgammon.decode_action(incoming))
    use #(next, _events) <- result.try(engine.apply(so_far, player_id, decoded))
    Ok(next)
  })
}
