//// What a finished game becomes on its way to the analysis engine: the
//// engine's on-roll board, the per-turn cube and match state, and the turn
//// list replayed from a room's seed and log.

import backgammon/analysis.{Passed, Took}
import backgammon/board.{Bar, Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/positions
import backgammon/record
import backgammon/state
import gamekit/action.{type Schema}
import gamekit/clock.{type Control}
import gamekit/conformance
import gamekit/game
import gamekit/instance
import gamekit/replay
import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string

const opening = [
  0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2,
  0,
]

// ---------- The board ----------

pub fn the_opening_position_is_the_engines_for_either_mover_test() {
  assert analysis.encode(board.initial(), White) == opening
  assert analysis.encode(board.initial(), Black) == opening
}

pub fn the_bar_is_25_for_the_mover_and_0_for_the_opponent_test() {
  let b =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(6), 14),
      #(Black, Bar, 2),
      #(Black, Point(19), 13),
    ])
  let white = analysis.encode(b, White)
  assert list.length(white) == 26
  assert at(white, 25) == 1
  // Both bars are counts: bgsage's format, whatever the service doc says
  assert at(white, 0) == 2
  assert at(white, 6) == 14
  // Black's 19-point is White's 19-point seen from White: index 19
  assert at(white, 19) == -13
  let black = analysis.encode(b, Black)
  assert at(black, 25) == 2
  assert at(black, 0) == 1
  // Black moves 1 -> 24, so their 19-point is their own 6-point
  assert at(black, 6) == 13
  assert at(black, 19) == -14
}

pub fn black_points_count_from_blacks_side_test() {
  // A Black checker on Oskol's 1-point is on Black's 24-point: the back of
  // the board, as far from home as a checker gets.
  let b =
    positions.setup([
      #(Black, Point(1), 1),
      #(Black, Point(24), 14),
      #(White, Point(3), 15),
    ])
  let black = analysis.encode(b, Black)
  assert at(black, 24) == 1
  assert at(black, 1) == 14
  assert at(black, 22) == -15
}

pub fn borne_off_checkers_are_not_stored_test() {
  let b =
    positions.setup([
      #(White, Point(1), 2),
      #(White, Point(3), 1),
      #(White, Off, 12),
      #(Black, Point(24), 3),
      #(Black, Off, 12),
    ])
  let white = analysis.encode(b, White)
  assert int.sum(list.filter(white, fn(n) { n > 0 })) == 3
  assert int.sum(list.filter(white, fn(n) { n < 0 })) == -3
  assert at(white, 1) == 2
  assert at(white, 3) == 1
  // Black's 24-point is their own 1-point: index 1 from Black's side,
  // index 24 from White's.
  assert at(white, 24) == -3
  let black = analysis.encode(b, Black)
  assert at(black, 1) == 3
  assert at(black, 24) == -2
}

// ---------- The position a turn starts from ----------

fn match_state(format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) = backgammon.init(f.config, positions.seats(), rng.seed(3))
  state.GameState(..s, phase: state.Rolling(White))
}

pub fn a_centred_cube_and_a_money_game_test() {
  let p = analysis.position(match_state("unlimited"), White)
  assert p.board == opening
  assert p.cube_value == 1
  assert p.cube_owner == "centered"
  assert #(p.away1, p.away2) == #(0, 0)
  assert p.crawford == False
  assert analysis.engine_can_double(p)
}

pub fn a_single_game_is_one_point_each_test() {
  let p = analysis.position(match_state("single"), Black)
  assert #(p.away1, p.away2) == #(1, 1)
  // Double-match-point: nothing to double for
  assert !analysis.engine_can_double(p)
}

pub fn the_cube_owner_is_relative_to_the_mover_test() {
  let s =
    state.GameState(
      ..match_state("match5"),
      cube_value: 2,
      cube_owner: Some(White),
    )
  let white = analysis.position(s, White)
  let black = analysis.position(s, Black)
  assert white.cube_value == 2
  assert white.cube_owner == "player"
  assert black.cube_owner == "opponent"
  assert analysis.engine_can_double(white)
  assert !analysis.engine_can_double(black)
}

pub fn away_scores_are_the_movers_first_test() {
  let s =
    state.GameState(
      ..match_state("match5"),
      scores: dict.from_list([#("p1", 3), #("p2", 1)]),
    )
  let white = analysis.position(s, White)
  let black = analysis.position(s, Black)
  assert #(white.away1, white.away2) == #(2, 4)
  assert #(black.away1, black.away2) == #(4, 2)
}

pub fn the_crawford_game_is_flagged_and_has_no_cube_test() {
  let s =
    state.GameState(
      ..match_state("match5"),
      scores: dict.from_list([#("p1", 4), #("p2", 1)]),
      crawford: True,
    )
  let p = analysis.position(s, Black)
  assert p.crawford
  assert #(p.away1, p.away2) == #(4, 1)
  assert !analysis.engine_can_double(p)
}

pub fn a_dead_cube_is_not_a_double_the_engine_takes_test() {
  // Two away holding a 2-cube: another double gains the doubler nothing.
  let s =
    state.GameState(
      ..match_state("match5"),
      scores: dict.from_list([#("p1", 3), #("p2", 0)]),
      cube_value: 2,
      cube_owner: Some(White),
    )
  assert !analysis.engine_can_double(analysis.position(s, White))
}

pub fn the_position_is_the_board_the_turn_began_on_test() {
  // A staged move never leaks into what the engine is asked about.
  let b = board.initial()
  let s = positions.position(1, b, [3, 1])
  let assert Ok(#(staged, _)) = state.stage(s, "p1", Point(8), Point(5))
  assert analysis.position(staged, White).board == opening
}

// ---------- Turns from a log ----------

/// Drive a real game from a seed with a policy, recording the log a room
/// would persist. The policy picks, for the player to act, one of their
/// legal schemas by name preference; `chooser` fills in params.
fn drive(
  format: String,
  selections: List(#(String, String)),
  seed: Int,
  control: Control,
  max_steps: Int,
  pick: fn(state.GameState, List(#(String, Schema)), Rng) ->
    Option(#(#(String, Schema), Rng)),
) -> #(replay.Log, state.GameState) {
  let seats = positions.seats()
  let assert Ok(running) =
    instance.begin(
      backgammon.game(),
      format,
      selections,
      seats,
      seed,
      control,
      0,
    )
  let log =
    replay.Log(
      format_id: format,
      selections: selections,
      seats: seats,
      seed: seed,
      control: control,
      entries: [],
    )
  let #(entries, running) =
    drive_loop(running, rng.seed(seed * 31 + 7), max_steps, [], pick)
  #(replay.Log(..log, entries: entries), instance.running_state(running))
}

fn drive_loop(running, chooser: Rng, left: Int, entries, pick) {
  let s = instance.running_state(running)
  let choices =
    list.flat_map(["p1", "p2"], fn(id) {
      engine.legal(s, id) |> list.map(fn(schema) { #(id, schema) })
    })
  let over = instance.running_outcome(running) != game.Ongoing
  case left == 0 || over, pick(s, choices, chooser) {
    True, _ | _, None -> #(list.reverse(entries), running)
    False, Some(#(#(player_id, schema), chooser)) -> {
      let #(text, chooser) = conformance.build_action(schema, chooser)
      let assert Ok(raw) = conformance.parse(text)
      let at = list.length(entries) * 1000
      let assert Ok(#(next, _)) = instance.step(running, player_id, raw, at)
      drive_loop(
        next,
        chooser,
        left - 1,
        [replay.Act(player_id, raw, at), ..entries],
        pick,
      )
    }
  }
}

/// The first legal schema, for whoever holds it, by name preference.
fn prefer(names: List(String)) {
  fn(_s, choices: List(#(String, Schema)), chooser: Rng) {
    list.find_map(names, fn(name) {
      list.find(choices, fn(c) { { c.1 }.name == name })
    })
    |> option.from_result
    |> option.map(fn(choice) { #(choice, chooser) })
  }
}

/// Uniformly random among the legal schemas, never these names.
fn random_except(excluded: List(String)) {
  fn(_s, choices: List(#(String, Schema)), chooser: Rng) {
    let choices =
      list.filter(choices, fn(c) { !list.contains(excluded, { c.1 }.name) })
    case rng.pick(chooser, choices) {
      Ok(picked) -> Some(picked)
      Error(_) -> None
    }
  }
}

const eager = ["double", "take", "play", "move", "roll"]

pub fn the_opening_turn_is_the_first_mover_on_the_opening_roll_test() {
  let #(log, _) =
    drive("match5", [], 11, clock.NoClock, 400, prefer(["play", "move"]))
  let assert Ok([first, ..]) = analysis.games(log)
  assert first.number == 1
  let assert [turn, ..] = first.turns
  assert turn.position.board == opening
  assert turn.position.cube_owner == "centered"
  assert #(turn.position.away1, turn.position.away2) == #(5, 5)
  assert turn.double == None
  let assert Some(#(a, b)) = turn.dice
  assert a != b
  assert option.is_some(turn.played)
  assert turn.picked == False
}

pub fn doubles_and_takes_carry_the_cube_from_the_movers_side_test() {
  // Everyone doubles at every chance and takes every double, in a match
  // to 5: 1 -> 2 -> 4 are live cubes, and the double to 16 on an 8-cube
  // is dead (the doubler needed 5), so the engine never sees it offered.
  let #(log, _) = drive("match5", [], 11, clock.NoClock, 400, prefer(eager))
  let assert Ok([g, ..]) = analysis.games(log)
  let assert [t0, t1, t2, t3, t4, ..] = g.turns
  assert t0.double == None
  assert t1.player != t0.player
  assert t1.double == Some(Took)
  assert #(t1.position.cube_value, t1.position.cube_owner) == #(1, "centered")
  assert option.is_some(t1.dice)
  assert t2.player == t0.player
  assert t2.double == Some(Took)
  assert #(t2.position.cube_value, t2.position.cube_owner) == #(2, "player")
  assert t3.double == Some(Took)
  assert #(t3.position.cube_value, t3.position.cube_owner) == #(4, "player")
  // The dead double to 16, taken: folded into the cube the taker now owns
  assert t4.double == None
  assert #(t4.position.cube_value, t4.position.cube_owner) == #(16, "opponent")
}

pub fn a_passed_double_ends_the_game_with_no_dice_test() {
  let #(log, _) =
    drive(
      "match5",
      [],
      11,
      clock.NoClock,
      400,
      prefer(["double", "drop", "ready", "play", "move", "roll"]),
    )
  let assert Ok([g1, g2, ..]) = analysis.games(log)
  assert g1.finished
  let assert [_opening, passed] = g1.turns
  assert passed.double == Some(Passed)
  assert passed.dice == None
  assert passed.played == None
  // The next game of the match starts on its own opening roll, a point down
  assert g2.number == 2
  let assert [next, ..] = g2.turns
  assert next.position.board == opening
  assert next.position.away1 + next.position.away2 == 9
}

pub fn a_match_game_is_over_the_moment_it_is_won_test() {
  // The same drop, and then nobody says READY: the game just played is
  // over (and so owed its review) though the next has not begun, and no
  // empty game follows it.
  let #(log, final) =
    drive(
      "match5",
      [],
      11,
      clock.NoClock,
      400,
      prefer(["double", "drop", "play", "move", "roll"]),
    )
  let assert state.BetweenGames(..) = final.phase
  let assert Ok([g1]) = analysis.games(log)
  assert g1.finished
  assert g1.number == 1
  let assert [_opening, passed] = g1.turns
  assert passed.double == Some(Passed)
  // One READY is not the next game either
  let #(log, _) =
    drive(
      "match5",
      [],
      11,
      clock.NoClock,
      400,
      fn(s: state.GameState, choices, chooser) {
        case s.phase, list.find(choices, fn(c) { { c.1 }.name == "ready" }) {
          state.BetweenGames(_, []), Ok(ready) -> Some(#(ready, chooser))
          state.BetweenGames(_, _), _ -> None
          _, _ ->
            prefer(["double", "drop", "play", "move", "roll"])(
              s,
              choices,
              chooser,
            )
        }
      },
    )
  let assert Ok([g1]) = analysis.games(log)
  assert g1.finished
}

pub fn a_resignation_keeps_only_complete_turns_test() {
  // The opening mover resigns with the dice still unplayed: that turn was
  // never played, so there is nothing of it to grade.
  let #(log, _) =
    drive(
      "single",
      [],
      11,
      clock.NoClock,
      10,
      prefer(["resign", "accept_resign"]),
    )
  let assert Ok([g]) = analysis.games(log)
  assert g.finished
  assert g.turns == []
}

pub fn a_game_still_being_played_is_listed_unfinished_test() {
  let #(log, _) =
    drive("single", [], 11, clock.NoClock, 12, prefer(["play", "move", "roll"]))
  let assert Ok([g]) = analysis.games(log)
  assert !g.finished
  assert g.turns != []
}

pub fn a_clock_that_ran_out_ends_the_game_where_it_stood_test() {
  // The opening mover plays in time; the other player's roll arrives an
  // hour late, after their minute ran out: the forfeit stands and the roll
  // is dropped, exactly as the room applied it.
  let control = clock.Fischer(60_000, 0)
  let #(log, _) =
    drive("single", [], 11, control, 400, fn(s, choices, chooser) {
      case s.phase {
        state.Moving(_, _) -> prefer(["play", "move"])(s, choices, chooser)
        _ -> None
      }
    })
  let assert Ok([g]) = analysis.games(log)
  assert !g.finished
  let late = case to_act(log) {
    Some(id) -> id
    None -> panic as "someone should be to roll"
  }
  let roll = raw("{\"name\":\"roll\",\"params\":{}}")
  let late_log =
    replay.Log(
      ..log,
      entries: list.append(log.entries, [replay.Act(late, roll, 3_600_000)]),
    )
  let assert Ok([g]) = analysis.games(late_log)
  assert g.finished
  assert list.length(g.turns) == 1
  // An expiry the room resolved on its own tick reads the same way
  let ticked =
    replay.Log(
      ..log,
      entries: list.append(log.entries, [replay.Expire(3_600_000)]),
    )
  let assert Ok([g]) = analysis.games(ticked)
  assert g.finished
  assert list.length(g.turns) == 1
}

fn raw(text: String) {
  let assert Ok(raw) = conformance.parse(text)
  raw
}

/// Who is to act after the log.
fn to_act(log: replay.Log) -> Option(String) {
  let assert Ok(#(_, running)) =
    replay.fold(backgammon.game(), log, fn(_) { Nil }, fn(_, _) { Nil })
  state.to_act(instance.running_state(running))
}

pub fn picked_dice_are_marked_test() {
  let #(log, _) =
    drive(
      "single",
      [#("twist", "pick_dice")],
      11,
      clock.NoClock,
      400,
      prefer(["pick", "play", "move", "roll"]),
    )
  let assert Ok([g, ..]) = analysis.games(log)
  let assert [opening_turn, second, third, fourth, ..] = g.turns
  // The opening roll is rolled; each player's first turn after it is
  // picked, and after that the pick is spent.
  assert !opening_turn.picked
  assert second.picked
  assert third.picked
  assert !fourth.picked
}

pub fn a_log_the_game_rejects_fails_the_replay_test() {
  let #(log, _) =
    drive("single", [], 11, clock.NoClock, 3, prefer(["play", "move"]))
  let bogus = raw("{\"name\":\"take\",\"params\":{}}")
  let log =
    replay.Log(
      ..log,
      entries: list.append(log.entries, [replay.Act("p1", bogus, 5000)]),
    )
  let assert Error(_) = analysis.games(log)
}

pub fn the_request_is_the_engines_shape_test() {
  let #(log, _) = drive("match5", [], 11, clock.NoClock, 400, prefer(eager))
  let assert Ok([g, ..]) = analysis.games(log)
  let text = json.to_string(analysis.request_json(g))
  assert string.starts_with(text, "{\"jacoby\":false,")
  assert string.contains(
    text,
    "\"board\":[0,-2,0,0,0,0,5,0,3,0,0,0,-5,5,0,0,0,-3,0,-5,0,0,0,0,2,0]",
  )
  assert string.contains(text, "\"doubled\":true,\"response\":\"take\"")
  assert string.contains(text, "\"cube_owner\":\"centered\"")
}

// ---------- The property: every played board is legal for its dice ----------

fn random_games(format: String, selections, seeds: List(Int), excluded) {
  list.each(seeds, fn(seed) {
    let #(log, final) =
      drive(
        format,
        selections,
        seed,
        clock.NoClock,
        3000,
        random_except(excluded),
      )
    let assert Ok(games) = analysis.games(log)
    check_games(games, final)
  })
}

pub fn every_played_board_is_legal_in_single_games_test() {
  random_games("single", [], [1, 2, 3, 4], ["resign"])
}

pub fn a_dance_is_sent_as_the_board_it_began_on_test() {
  // Random single games dance now and then; each dance goes out with its
  // dice and the unchanged board, which is how the engine lists one.
  let dances =
    list.flat_map([1, 2, 3, 4], fn(seed) {
      let #(log, _) =
        drive(
          "single",
          [],
          seed,
          clock.NoClock,
          3000,
          random_except(["resign"]),
        )
      let assert Ok(games) = analysis.games(log)
      list.flat_map(games, fn(g) { list.filter(g.turns, analysis.danced) })
    })
  assert dances != []
  list.each(dances, fn(turn) {
    let assert Some(dice) = turn.dice
    assert legal_boards(turn.position.board, dice) == []
    assert turn.played == Some(turn.position.board)
  })
}

pub fn every_played_board_is_legal_in_a_match_to_3_test() {
  random_games("match3", [], [1, 2], ["resign"])
}

pub fn every_played_board_is_legal_in_a_match_to_5_test() {
  random_games("match5", [], [3], ["resign"])
}

pub fn every_played_board_is_legal_in_unlimited_play_test() {
  // 3000 steps of unlimited play is several games, each its own list
  random_games("unlimited", [], [1], ["resign"])
}

pub fn every_played_board_is_legal_with_picked_dice_test() {
  random_games("single", [#("twist", "pick_dice")], [5, 6, 7], ["resign"])
}

pub fn resignations_in_random_play_keep_the_turns_legal_test() {
  // Resigning is legal at every step, so these games end early, often in
  // the middle of a turn
  random_games("match5", [], list.range(1, 20), [])
}

fn check_games(games: List(analysis.GameTurns), final: state.GameState) {
  check_entries(games, final)
  // Numbered 1.. without a gap; every game but the last is over
  assert list.map(games, fn(g) { g.number })
    == list.range(1, list.length(games))
  assert list.length(games) == final.game_number
  games
  |> list.reverse
  |> list.drop(1)
  |> list.each(fn(g) {
    assert g.finished
  })
  list.each(games, fn(g) {
    check_alternation(g.turns)
    list.each(g.turns, check_turn)
  })
}

/// Every turn names the lines of its game's record it is about, and those
/// lines say the same thing: the committed turn is the mover's, and the
/// board it left, read back from the engine's format, is the record's own
/// snapshot; the double is the mover's and the answer the other player's.
fn check_entries(games: List(analysis.GameTurns), final: state.GameState) {
  let by_game = record.by_game(state.record(final))
  list.each(games, fn(g) {
    let assert Ok(entries) = by_game |> list.drop(g.number - 1) |> list.first
    let line = fn(i) {
      let assert Ok(e) = entries |> list.drop(i) |> list.first
      e
    }
    list.each(g.turns, fn(turn) {
      let color = case turn.player {
        0 -> White
        _ -> Black
      }
      case turn.entry, turn.played {
        Some(i), Some(played) -> {
          let assert record.Turn(player: p, position: pos, ..) = line(i)
          assert p == turn.player_id
          assert analysis.decode(played, color) == Ok(#(pos.white, pos.black))
        }
        None, None -> Nil
        _, _ -> panic as "a played board without its record line"
      }
      case turn.double, turn.double_entry, turn.answer_entry {
        Some(answer), Some(d), Some(a) -> {
          let assert record.Double(player: doubler, ..) = line(d)
          assert doubler == turn.player_id
          case answer, line(a) {
            Took, record.Take(player: taker) -> {
              assert taker != turn.player_id
            }
            Passed, record.Drop(player: dropper) -> {
              assert dropper != turn.player_id
            }
            _, _ -> panic as "the answer's line is not the answer"
          }
        }
        None, None, None -> Nil
        _, _, _ -> panic as "a double without its record lines"
      }
    })
  })
}

pub fn a_turn_names_its_lines_of_the_record_test() {
  // Doubles and takes from the second turn on: the first turn is the
  // record's first line, and the next turn's double, take and roll are the
  // three lines after it.
  let #(log, final) = drive("match5", [], 11, clock.NoClock, 400, prefer(eager))
  let assert Ok([g, ..]) = analysis.games(log)
  let assert [t0, t1, ..] = g.turns
  assert #(t0.entry, t0.double_entry, t0.answer_entry) == #(Some(0), None, None)
  assert #(t1.double_entry, t1.answer_entry, t1.entry)
    == #(Some(1), Some(2), Some(3))
  // A double the engine cannot grade (the dead one in this game) keeps its
  // turn's line but names no double
  let assert [_, _, _, _, t4, ..] = g.turns
  assert t4.double_entry == None
  assert option.is_some(t4.entry)
  check_entries([g], final)
}

pub fn a_passed_double_names_the_double_and_the_drop_test() {
  let #(log, final) =
    drive(
      "match5",
      [],
      11,
      clock.NoClock,
      400,
      prefer(["double", "drop", "ready", "play", "move", "roll"]),
    )
  let assert Ok([g1, g2, ..]) = analysis.games(log)
  let assert [_opening, passed] = g1.turns
  assert #(passed.entry, passed.double_entry, passed.answer_entry)
    == #(None, Some(1), Some(2))
  // The next game's lines count from its own first line
  let assert [next, ..] = g2.turns
  assert next.entry == Some(0)
  check_entries([g1, g2], final)
}

/// A whole match to 7, as the engine is told it: every turn carries what
/// each player still needs from the score as it then stood, the Crawford
/// game is the one that follows someone reaching 6, and nobody may double
/// in it. The expected scores are read off the record's own result lines,
/// not off the encoder.
pub fn a_match_tells_the_engine_the_score_and_crawford_test() {
  // Everyone doubles at the first chance and drops it: a point a game, so
  // the match runs its full length quickly.
  let #(log, final) =
    drive(
      "match7",
      [],
      11,
      clock.NoClock,
      2000,
      prefer(["double", "drop", "ready", "play", "move", "roll"]),
    )
  let assert Ok(games) = analysis.games(log)
  // The running score after each finished game, oldest first.
  let results =
    record.results(state.record(final))
    |> list.filter_map(fn(e) {
      case e {
        record.GameOver(scores: scores, ..) -> Ok(scores)
        _ -> Error(Nil)
      }
    })
  assert list.length(results) >= 7
  let score_of = fn(scores: List(#(String, Int)), id: String) {
    list.key_find(scores, id) |> result.unwrap(0)
  }
  let crawford_games =
    list.filter_map(games, fn(g) {
      // What the score was when this game began
      let before = case list.drop(results, g.number - 2) {
        [scores, ..] if g.number > 1 -> scores
        _ -> [#("p1", 0), #("p2", 0)]
      }
      let one_away =
        list.any(["p1", "p2"], fn(id) { score_of(before, id) == 6 })
      // Every turn of the game says the same thing, from its mover's side
      list.each(g.turns, fn(turn) {
        let other = case turn.player_id {
          "p1" -> "p2"
          _ -> "p1"
        }
        assert #(turn.position.away1, turn.position.away2)
          == #(
            7 - score_of(before, turn.player_id),
            7 - score_of(before, other),
          )
        assert turn.position.crawford
          == { one_away && !crawford_done(games, g) }
      })
      case g.turns {
        [turn, ..] if turn.position.crawford -> Ok(g.number)
        _ -> Error(Nil)
      }
    })
  // Exactly one Crawford game, and no cube in it
  let assert [crawford] = crawford_games
  let assert Ok(g) = list.find(games, fn(g) { g.number == crawford })
  list.each(g.turns, fn(turn) {
    assert !analysis.engine_can_double(turn.position)
    assert turn.double == None
  })
}

/// Crawford is played once: a game after one that was already Crawford is
/// not another (the rule is "the game after the first time someone gets
/// within one point").
fn crawford_done(games: List(analysis.GameTurns), g: analysis.GameTurns) -> Bool {
  games
  |> list.take(g.number - 1)
  |> list.any(fn(earlier) {
    case earlier.turns {
      [turn, ..] -> turn.position.crawford
      [] -> False
    }
  })
}

pub fn unlimited_play_is_a_money_game_with_jacoby_test() {
  let #(log, _) =
    drive(
      "unlimited",
      [],
      11,
      clock.NoClock,
      1500,
      prefer(["double", "take", "play", "move", "roll"]),
    )
  let assert Ok(games) = analysis.games(log)
  assert games != []
  list.each(games, fn(g) {
    // Gammons only count once the cube is turned: the engine is told so
    assert g.jacoby
    assert string.contains(
      json.to_string(analysis.request_json(g)),
      "\"jacoby\":true",
    )
    list.each(g.turns, fn(turn) {
      assert #(turn.position.away1, turn.position.away2) == #(0, 0)
      assert turn.position.crawford == False
    })
  })
  // A single game is neither: one point each, and no Jacoby to apply
  let #(single, _) =
    drive(
      "single",
      [],
      11,
      clock.NoClock,
      400,
      prefer(["play", "move", "roll"]),
    )
  let assert Ok([g, ..]) = analysis.games(single)
  assert !g.jacoby
  let assert [turn, ..] = g.turns
  assert #(turn.position.away1, turn.position.away2) == #(1, 1)
}

// ---------- Reading the engine's boards back ----------

pub fn a_board_reads_back_as_the_record_draws_it_test() {
  positions.each_random(200, fn(_seed, b, _dice) {
    let snap = record.snapshot(b, 1, None)
    list.each([White, Black], fn(mover) {
      assert analysis.decode(analysis.encode(b, mover), mover)
        == Ok(#(snap.white, snap.black))
    })
  })
  let snap = record.snapshot(board.initial(), 1, None)
  assert analysis.decode(opening, White) == Ok(#(snap.white, snap.black))
  assert analysis.decode(opening, Black) == Ok(#(snap.white, snap.black))
  assert analysis.decode([0, 1, 2], White) == Error(Nil)
  assert analysis.decode([], White) == Error(Nil)
}

pub fn landings_are_the_points_that_gained_the_movers_checkers_test() {
  // 31 from the opening: 8/5 6/5, two checkers on the 5
  let made_the_5 = [
    0, -2, 0, 0, 0, 2, 4, 0, 2, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0,
    2, 0,
  ]
  assert analysis.landings(opening, made_the_5, White) == [5, 5]
  // The same boards from Black's side: their 5-point is Oskol's 20
  assert analysis.landings(opening, made_the_5, Black) == [20, 20]
  // A hit: the blot's point turns from theirs to mine, and they go to the bar
  let blot = [
    0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -4, -1, 0, 0, 0,
    2, 0,
  ]
  let hit = [
    1, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -4, 1, 0, 0, 0,
    1, 0,
  ]
  assert analysis.landings(blot, hit, White) == [20]
  // A checker borne off lands nowhere; one that moves within lands once
  let home = [
    0,
    0,
    2,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]
  let off = [
    0,
    1,
    2,
    2,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]
  assert analysis.landings(home, off, White) == [1]
}

fn check_alternation(turns: List(analysis.Turn)) {
  case turns {
    [a, b, ..rest] -> {
      assert a.player != b.player
      check_alternation([b, ..rest])
    }
    _ -> Nil
  }
}

fn check_turn(turn: analysis.Turn) {
  let p = turn.position
  assert list.length(p.board) == 26
  check_board(p.board)
  // The engine refuses a double it thinks illegal: we never send one
  case turn.double {
    Some(_) -> {
      assert analysis.engine_can_double(p)
    }
    None -> Nil
  }
  case turn.dice, turn.played {
    None, played -> {
      // Only a double can stand without dice
      assert option.is_some(turn.double)
      assert played == None
    }
    // A roll is always sent with its board: the engine 422s one without
    Some(_), None -> panic as "dice with no played board"
    Some(dice), Some(played) -> {
      check_board(played)
      let legal = legal_boards(p.board, dice)
      case analysis.danced(turn) {
        // A dance commits the board it began on, and only a dance does
        True -> {
          assert legal == []
        }
        False -> {
          assert list.contains(legal, played)
        }
      }
    }
  }
}

/// 26 ints; both bars counts (never negative); at most 15 checkers a side.
fn check_board(board: List(Int)) {
  assert list.length(board) == 26
  assert at(board, 25) >= 0
  assert at(board, 0) >= 0
  let points = board |> list.drop(1) |> list.take(24)
  let mover = int.sum(list.filter(points, fn(n) { n > 0 })) + at(board, 25)
  let opponent = -int.sum(list.filter(points, fn(n) { n < 0 })) + at(board, 0)
  assert mover <= 15
  assert opponent <= 15
}

// ---------- An independent move generator on the engine's board ----------
//
// Written from the rulebook on the engine's own format, not Oskol's: the
// mover's checkers are positive and travel 24 -> 1, their bar is 25, the
// opponent's bar is 0 (a count: a hit adds one there), and a checker bears
// off past 1. Use as many dice as possible; if only one of two different
// dice can be used, the larger. The hit convention is checked against the
// real engine's own legal list by hand (see the PR), since the service doc
// had it backwards.

fn legal_boards(board: List(Int), dice: #(Int, Int)) -> List(List(Int)) {
  let #(a, b) = dice
  let start = set.from_list([to_dict(board)])
  let boards = case a == b {
    // Doubles: as many of the four as can be played, level by level
    True -> {
      let levels =
        list.fold(list.range(1, 4), [start], fn(levels, _) {
          let assert [last, ..] = levels
          [then(last, a), ..levels]
        })
      case list.find(levels, fn(level) { set.size(level) > 0 }) {
        Ok(level) if level != start -> level
        _ -> set.new()
      }
    }
    False -> {
      let first_a = then(start, a)
      let first_b = then(start, b)
      let both = set.union(then(first_a, b), then(first_b, a))
      let #(big, small) = case a > b {
        True -> #(first_a, first_b)
        False -> #(first_b, first_a)
      }
      case set.size(both) > 0, set.size(big) > 0 {
        True, _ -> both
        False, True -> big
        False, False -> small
      }
    }
  }
  boards |> set.to_list |> list.map(from_dict)
}

/// Every board one move of `die` away from any board in `boards`.
fn then(boards: Set(Dict(Int, Int)), die: Int) -> Set(Dict(Int, Int)) {
  boards
  |> set.to_list
  |> list.flat_map(fn(b) { single(b, die) })
  |> set.from_list
}

fn single(b: Dict(Int, Int), die: Int) -> List(Dict(Int, Int)) {
  case get(b, 25) > 0 {
    True -> {
      let to = 25 - die
      case get(b, to) >= -1 {
        True -> [land(leave(b, 25), to)]
        False -> []
      }
    }
    False -> {
      let home = list.all(list.range(7, 24), fn(p) { get(b, p) <= 0 })
      list.range(1, 24)
      |> list.filter(fn(p) { get(b, p) > 0 })
      |> list.filter_map(fn(from) {
        let to = from - die
        case to >= 1 {
          True ->
            case get(b, to) >= -1 {
              True -> Ok(land(leave(b, from), to))
              False -> Error(Nil)
            }
          False -> {
            // A higher point still holding a checker of the mover's
            let behind =
              from < 6
              && list.any(list.range(from + 1, 6), fn(p) { get(b, p) > 0 })
            case home, to == 0, behind {
              True, True, _ -> Ok(leave(b, from))
              True, False, False -> Ok(leave(b, from))
              _, _, _ -> Error(Nil)
            }
          }
        }
      })
    }
  }
}

fn leave(b: Dict(Int, Int), from: Int) -> Dict(Int, Int) {
  dict.insert(b, from, get(b, from) - 1)
}

fn land(b: Dict(Int, Int), to: Int) -> Dict(Int, Int) {
  case get(b, to) == -1 {
    True -> b |> dict.insert(to, 1) |> dict.insert(0, get(b, 0) + 1)
    False -> dict.insert(b, to, get(b, to) + 1)
  }
}

fn to_dict(board: List(Int)) -> Dict(Int, Int) {
  board |> list.index_map(fn(n, i) { #(i, n) }) |> dict.from_list
}

fn from_dict(b: Dict(Int, Int)) -> List(Int) {
  list.range(0, 25) |> list.map(fn(i) { get(b, i) })
}

fn get(b: Dict(Int, Int), i: Int) -> Int {
  case dict.get(b, i) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

fn at(board: List(Int), i: Int) -> Int {
  get(to_dict(board), i)
}

pub fn a_hit_lands_on_the_opponents_bar_as_the_engine_writes_it_test() {
  // Copied from the live engine's /backgammon/moves answer (2026-09-15):
  // 3-4 from this board, 13/9 6/3*, comes back with +1 at index 0.
  let before = [
    0, -1, 0, -1, 0, 0, 5, 0, 3, 0, 0, 0, -4, 5, 0, 0, 0, -4, 0, -5, 0, 0, 0, 0,
    2, 0,
  ]
  let engine_says = [
    1, -1, 0, 1, 0, 0, 4, 0, 3, 1, 0, 0, -4, 4, 0, 0, 0, -4, 0, -5, 0, 0, 0, 0,
    2, 0,
  ]
  let boards = legal_boards(before, #(3, 4))
  assert list.contains(boards, engine_says)
  // The engine listed 18 plays for this roll
  assert list.length(boards) == 18
}

pub fn the_generator_agrees_with_the_rules_on_random_boards_test() {
  // The same generator against Oskol's own, through the encoder: every
  // maximal sequence Oskol allows lands on a board the engine allows, and
  // no more boards than that. This is the encoder's direction checked on
  // positions games rarely reach (both bars, bear-offs, doubles).
  positions.each_random(200, fn(_seed, b, dice) {
    list.each([White, Black], fn(mover) {
      let roll = case dice {
        [x, y] -> #(x, y)
        [x, ..] -> #(x, x)
        [] -> #(1, 1)
      }
      let oskol =
        board.sequences(b, mover, dice)
        |> list.map(fn(sequence) {
          let after =
            list.fold(sequence, b, fn(acc, m) {
              let #(next, _, _) = board.apply_move(acc, mover, m)
              next
            })
          analysis.encode(after, mover)
        })
        |> list.unique
        |> list.sort(compare_boards)
      let engine =
        legal_boards(analysis.encode(b, mover), roll)
        |> list.sort(compare_boards)
      assert oskol == engine
    })
  })
}

fn compare_boards(a: List(Int), b: List(Int)) -> order.Order {
  case a, b {
    [x, ..xs], [y, ..ys] ->
      case int.compare(x, y) {
        order.Eq -> compare_boards(xs, ys)
        other -> other
      }
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
  }
}
