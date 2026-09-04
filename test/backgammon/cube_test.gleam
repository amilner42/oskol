//// The doubling cube, match formats, Crawford, Jacoby, resigning.

import backgammon/board.{Bar, Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/conformance
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

fn new_game(seed: Int, format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) = backgammon.init(f.config, seats(), rng.seed(seed))
  s
}

fn setup(entries: List(#(board.Color, board.Loc, Int))) -> board.Board {
  let #(checkers, _) =
    list.fold(entries, #([], #(0, 0)), fn(acc, entry) {
      let #(placed, #(w, b)) = acc
      let #(color, loc, n) = entry
      let start = case color {
        White -> w
        Black -> b
      }
      let ids = case n {
        0 -> []
        _ ->
          list.range(1, n)
          |> list.map(fn(i) {
            #(board.prefix(color) <> int.to_string(start + i), #(color, loc))
          })
      }
      let counts = case color {
        White -> #(w + n, b)
        Black -> #(w, b + n)
      }
      #(list.append(placed, ids), counts)
    })
  board.Board(checkers: dict.from_list(checkers))
}

/// White (p1) about to roll in the given format.
fn white_to_roll(seed: Int, format: String) -> state.GameState {
  let s = new_game(seed, format)
  state.GameState(..s, phase: state.Rolling(White))
}

fn apply(
  s: state.GameState,
  id: String,
  action: engine.Action,
) -> #(state.GameState, List(event.Event)) {
  let assert Ok(result) = engine.apply(s, id, action)
  result
}

fn names(s: state.GameState, id: String) -> List(String) {
  list.map(engine.legal(s, id), fn(schema) { schema.name })
}

fn has_custom(events: List(event.Event), kind: String) -> Bool {
  list.any(events, fn(e) {
    case e {
      event.Custom(k, _) -> k == kind
      _ -> False
    }
  })
}

// ---------- Formats ----------

pub fn formats_configure_target_cube_and_jacoby_test() {
  let single = new_game(1, "single")
  assert single.config == state.Config(target: 1, cube: False, jacoby: False)
  let match3 = new_game(1, "match3")
  assert match3.config == state.Config(target: 3, cube: True, jacoby: False)
  let unlimited = new_game(1, "unlimited")
  assert unlimited.config == state.Config(target: 0, cube: True, jacoby: True)
  assert state.unlimited(unlimited)
  assert list.map(backgammon.info().formats, fn(f) { f.id })
    == ["single", "match3", "match5", "match7", "unlimited"]
}

// ---------- Offering and answering ----------

pub fn the_player_to_roll_may_double_with_a_centred_cube_test() {
  let s = white_to_roll(2, "match5")
  assert names(s, "p1") == ["roll", "double", "resign"]
  assert names(s, "p2") == ["resign"]
  let #(s, events) = apply(s, "p1", engine.Double)
  assert has_custom(events, "double_offered")
  let assert state.Doubled(White) = s.phase
  assert names(s, "p2") == ["take", "drop", "resign"]
  assert names(s, "p1") == ["resign"]
  // The responder is on the clock, not the doubler
  assert engine.on_the_clock(s) == ["p2"]
  assert state.to_move(s) == Some("p1")
  assert engine.apply(s, "p1", engine.Roll) == Error("A double is pending")
  assert engine.apply(s, "p1", engine.Take) == Error("You offered the double")
}

pub fn taking_doubles_the_cube_and_gives_it_to_the_taker_test() {
  let s = white_to_roll(3, "match5")
  let #(s, _) = apply(s, "p1", engine.Double)
  let #(s, events) = apply(s, "p2", engine.Take)
  assert has_custom(events, "double_taken")
  assert s.cube_value == 2
  assert s.cube_owner == Some(Black)
  let assert state.Rolling(White) = s.phase
  // Only the owner may redouble now
  assert names(s, "p1") == ["roll", "resign"]
  assert engine.apply(s, "p1", engine.Double)
    == Error("You do not own the cube")
  let #(s, _) = apply(s, "p1", engine.Roll)
  let assert state.Moving(White, _) = s.phase
  assert engine.apply(s, "p1", engine.Double)
    == Error("You can only double before rolling")
}

pub fn the_owner_can_redouble_on_their_turn_test() {
  let s = white_to_roll(4, "match7")
  let #(s, _) = apply(s, "p1", engine.Double)
  let #(s, _) = apply(s, "p2", engine.Take)
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "double", "resign"]
  let #(s, _) = apply(s, "p2", engine.Double)
  let #(s, _) = apply(s, "p1", engine.Take)
  assert s.cube_value == 4
  assert s.cube_owner == Some(White)
}

pub fn dropping_concedes_the_cube_value_and_starts_a_new_game_test() {
  let s = white_to_roll(5, "match5")
  let s = state.GameState(..s, cube_value: 2, cube_owner: Some(White))
  let #(s, _) = apply(s, "p1", engine.Double)
  let #(s, events) = apply(s, "p2", engine.Drop)
  assert has_custom(events, "double_dropped")
  assert has_custom(events, "game_won")
  assert has_custom(events, "new_game")
  assert state.score_of(s, "p1") == 2
  assert s.game_number == 2
  assert s.cube_value == 1 && s.cube_owner == None
  assert dict.size(s.board.checkers) == 30
}

pub fn no_cube_in_a_single_game_test() {
  let s = white_to_roll(6, "single")
  assert names(s, "p1") == ["roll", "resign"]
  assert engine.apply(s, "p1", engine.Double)
    == Error("The cube is not in play")
  let sc = backgammon.game().scene(s, scene.Player("p1"))
  let assert Ok(cube) = scene.find_zone(sc, "cube")
  assert cube.tokens == []
}

pub fn the_cube_stops_at_sixty_four_test() {
  let s = white_to_roll(7, "unlimited")
  let s = state.GameState(..s, cube_value: 64, cube_owner: Some(White))
  assert engine.apply(s, "p1", engine.Double)
    == Error("The cube is at its limit")
}

// ---------- Scoring with the cube ----------

pub fn a_gammon_with_the_cube_at_two_scores_four_test() {
  let b =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = new_game(8, "match7")
  let s =
    state.GameState(
      ..s,
      board: b,
      phase: state.Moving(White, [1, 2]),
      cube_value: 2,
      cube_owner: Some(White),
    )
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  let #(s, events) = apply(s, "p1", engine.Play)
  assert state.score_of(s, "p1") == 4
  assert list.any(events, fn(e) {
    case e {
      event.Custom("game_won", payload) ->
        json.to_string(payload) |> string.contains("\"kind\":\"gammon\"")
        && json.to_string(payload) |> string.contains("\"points\":4")
      _ -> False
    }
  })
}

pub fn jacoby_makes_gammons_single_until_the_cube_is_turned_test() {
  let b =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let centred = new_game(9, "unlimited")
  let centred =
    state.GameState(..centred, board: b, phase: state.Moving(White, [1, 2]))
  let #(after, _) = apply(centred, "p1", engine.MoveChecker(Point(1), Off))
  let #(after, _) = apply(after, "p1", engine.Play)
  assert state.score_of(after, "p1") == 1
  let turned =
    state.GameState(..centred, cube_value: 2, cube_owner: Some(White))
  let #(after, _) = apply(turned, "p1", engine.MoveChecker(Point(1), Off))
  let #(after, _) = apply(after, "p1", engine.Play)
  assert state.score_of(after, "p1") == 4
  // Match play has no Jacoby rule
  let match = new_game(9, "match5")
  let match =
    state.GameState(..match, board: b, phase: state.Moving(White, [1, 2]))
  let #(after, _) = apply(match, "p1", engine.MoveChecker(Point(1), Off))
  let #(after, _) = apply(after, "p1", engine.Play)
  assert state.score_of(after, "p1") == 2
}

pub fn resigning_gives_the_opponent_the_cube_value_test() {
  let s = white_to_roll(10, "match5")
  let s = state.GameState(..s, cube_value: 4, cube_owner: Some(Black))
  let #(s, events) = apply(s, "p2", engine.Resign)
  assert has_custom(events, "resigned")
  assert state.score_of(s, "p1") == 4
  assert s.game_number == 2
  // Resigning the last points ends the match
  let s = state.GameState(..s, cube_value: 1)
  let #(s, events) = apply(s, "p2", engine.Resign)
  assert has_custom(events, "match_over")
  let assert state.Finished(White) = s.phase
  assert backgammon.outcome(s) == game.Finished(["p1"])
  assert engine.apply(s, "p2", engine.Resign) == Error("The match is over")
}

fn bear_off_and_play(
  s: state.GameState,
) -> #(state.GameState, List(event.Event)) {
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  apply(s, "p1", engine.Play)
}

// ---------- Crawford ----------

pub fn the_crawford_game_forbids_doubling_then_it_resumes_test() {
  // Match to 3: p1 wins 2 points -> 2-0, one away -> Crawford game.
  let b =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = new_game(11, "match3")
  let s = state.GameState(..s, board: b, phase: state.Moving(White, [1, 2]))
  let #(s, events) = bear_off_and_play(s)
  assert state.score_of(s, "p1") == 2
  assert s.crawford && s.crawford_done
  assert list.any(events, fn(e) {
    case e {
      event.Custom("new_game", payload) ->
        json.to_string(payload) |> string.contains("\"crawford\":true")
      _ -> False
    }
  })
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "resign"]
  assert engine.apply(s, "p2", engine.Double)
    == Error("No doubling in the Crawford game")
  // p2 wins the Crawford game as a single: 2-1, post-Crawford doubling is back
  let win_b =
    setup([
      #(Black, Off, 14),
      #(Black, Point(24), 1),
      #(White, Point(6), 14),
      #(White, Off, 1),
    ])
  let s = state.GameState(..s, board: win_b, phase: state.Moving(Black, [1, 2]))
  let #(s, _) = apply(s, "p2", engine.MoveChecker(Point(24), Off))
  let #(s, _) = apply(s, "p2", engine.Play)
  assert state.score_of(s, "p2") == 1
  assert s.crawford == False && s.crawford_done
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "double", "resign"]
  // And even if p1 later also sits one away, there is no second Crawford game
  let s2 =
    state.GameState(
      ..s,
      scores: dict.from_list([#("p1", 1), #("p2", 2)]),
      board: win_b,
      phase: state.Moving(Black, [1, 2]),
    )
  let s2 =
    state.GameState(..s2, scores: dict.from_list([#("p1", 2), #("p2", 1)]))
  let #(s2, _) = apply(s2, "p2", engine.MoveChecker(Point(24), Off))
  let #(s2, _) = apply(s2, "p2", engine.Play)
  assert s2.crawford == False
}

pub fn unlimited_play_never_finishes_by_itself_test() {
  let assert Ok(report) =
    conformance.random_playout(
      backgammon.game(),
      "unlimited",
      seats(),
      77,
      2500,
      fn(_) { Ok(Nil) },
    )
  assert report.finished == False
  assert report.state.game_number > 1
  assert backgammon.outcome(report.state) == game.Ongoing
  assert state.score_of(report.state, "p1") + state.score_of(report.state, "p2")
    > 0
}

pub fn matches_with_the_cube_still_terminate_and_replay_test() {
  list.each([31, 32, 33, 34], fn(seed) {
    let assert Ok(report) =
      conformance.random_playout(
        backgammon.game(),
        "match3",
        seats(),
        seed,
        20_000,
        fn(_) { Ok(Nil) },
      )
    assert report.finished
    let assert state.Finished(winner) = report.state.phase
    assert state.score_of(report.state, state.player_of(report.state, winner))
      >= 3
    let assert Ok(replayed) =
      conformance.replay(
        backgammon.game(),
        "match3",
        seats(),
        seed,
        report.steps,
      )
    assert conformance.fingerprint(backgammon.game(), replayed, seats())
      == conformance.fingerprint(backgammon.game(), report.state, seats())
  })
}

pub fn scene_reports_the_cube_test() {
  let s = white_to_roll(12, "match5")
  let #(s, _) = apply(s, "p1", engine.Double)
  let sc = backgammon.game().scene(s, scene.Player("p2"))
  assert sc.phase == "doubled"
  let assert Ok(cube) = scene.find_zone(sc, "cube")
  let assert [token] = cube.tokens
  assert token.kind == "cube"
  assert list.key_find(token.props, "value") == Ok(json.int(1))
  assert json.to_string(json.object(sc.data))
    |> string.contains("\"pending_from\":\"p1\"")
  let #(s, _) = apply(s, "p2", engine.Take)
  let sc = backgammon.game().scene(s, scene.Player("p2"))
  let assert Ok(cube) = scene.find_zone(sc, "cube")
  let assert [token] = cube.tokens
  assert list.key_find(token.props, "value") == Ok(json.int(2))
  assert list.key_find(token.props, "owner") == Ok(json.string("p2"))
  let assert [_, them] = sc.players
  assert list.contains(them.flags, "owns_cube")
}

pub fn unknown_players_cannot_touch_the_cube_test() {
  let s = white_to_roll(13, "match5")
  let assert Error(_) = engine.apply(s, "ghost", engine.Double)
  let assert Error("No double to answer") = engine.apply(s, "p2", engine.Take)
  let assert Error("No double to answer") = engine.apply(s, "p2", engine.Drop)
  let _ = Bar
  Nil
}
