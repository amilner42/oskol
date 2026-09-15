//// Between the games of a match: the pause until both players are ready.
////
//// When a game of a match or of unlimited play ends, its final position
//// stays up, nobody is on the clock, and the next game starts -- opening
//// roll and all -- when the second player says `ready`.

import backgammon/board.{Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/clock
import gamekit/conformance.{type Step}
import gamekit/event
import gamekit/game.{Seat}
import gamekit/instance
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

/// A game of this format, as a room would start it.
fn game_at(seed: Int, format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) =
    backgammon.init(game.default_config(f), seats(), rng.seed(seed))
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
      let ids =
        list.range(1, n)
        |> list.map(fn(i) {
          #(board.prefix(color) <> int.to_string(start + i), #(color, loc))
        })
      let counts = case color {
        White -> #(w + n, b)
        Black -> #(w, b + n)
      }
      #(list.append(placed, ids), counts)
    })
  board.Board(checkers: dict.from_list(checkers))
}

/// White (p1) one checker from home, black with none off: bearing it off
/// wins a gammon.
fn white_gammon_board() -> board.Board {
  setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
}

/// Black (p2) one checker from home, white with one off: a single.
fn black_single_board() -> board.Board {
  setup([
    #(Black, Off, 14),
    #(Black, Point(24), 1),
    #(White, Point(6), 14),
    #(White, Off, 1),
  ])
}

fn about_to_win(s: state.GameState, b: board.Board, color) -> state.GameState {
  state.GameState(
    ..s,
    board: b,
    turn_board: b,
    phase: state.Moving(color, [1, 2]),
  )
}

fn apply(
  s: state.GameState,
  id: String,
  action: engine.Action,
) -> #(state.GameState, List(event.Event)) {
  let assert Ok(result) = engine.apply(s, id, action)
  result
}

/// p1 bears off the last checker from `white_gammon_board`.
fn white_wins(s: state.GameState) -> #(state.GameState, List(event.Event)) {
  let s = about_to_win(s, white_gammon_board(), White)
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  apply(s, "p1", engine.Play)
}

/// p2 bears off the last checker from `black_single_board`.
fn black_wins(s: state.GameState) -> #(state.GameState, List(event.Event)) {
  let s = about_to_win(s, black_single_board(), Black)
  let #(s, _) = apply(s, "p2", engine.MoveChecker(Point(24), Off))
  apply(s, "p2", engine.Play)
}

fn names(s: state.GameState, id: String) -> List(String) {
  list.map(engine.legal(s, id), fn(schema) { schema.name })
}

fn kinds(events: List(event.Event)) -> List(String) {
  list.filter_map(events, fn(e) {
    case e {
      event.Custom(kind, _) -> Ok(kind)
      event.PhaseChanged(phase) -> Ok("phase:" <> phase)
      _ -> Error(Nil)
    }
  })
}

fn payload_of(events: List(event.Event), kind: String) -> String {
  let assert Ok(payload) =
    list.find_map(events, fn(e) {
      case e {
        event.Custom(k, payload) if k == kind -> Ok(json.to_string(payload))
        _ -> Error(Nil)
      }
    })
  payload
}

fn scene_data(s: state.GameState, viewer: scene.Viewer) -> String {
  json.to_string(json.object(backgammon.game().scene(s, viewer).data))
}

fn ready(
  s: state.GameState,
  id: String,
) -> #(state.GameState, List(event.Event)) {
  apply(s, id, engine.Ready)
}

// ---------- The pause ----------

pub fn a_finished_game_pauses_on_its_final_position_test() {
  let s = game_at(3, "match5")
  let #(s, events) = white_wins(s)
  assert kinds(events)
    == ["turn_played", "checker_moved", "game_won", "phase:between_games"]
  let assert state.BetweenGames(last, []) = s.phase
  assert last.winner == "p1" && last.points == 2 && !last.match_over
  // The score is in, the next game is not: same game number, the final
  // position still on the board, the dice of the last roll still there.
  assert state.score_of(s, "p1") == 2
  assert s.game_number == 1
  assert board.borne_off(s.board, White) == 15
  assert board.checkers_at(s.board, Black, Point(19)) |> list.length == 15
  assert s.last_roll != []
  // Only `ready`, for both players.
  assert names(s, "p1") == ["ready"]
  assert names(s, "p2") == ["ready"]
  assert state.to_act(s) == None && state.to_move(s) == None
  let sc = backgammon.game().scene(s, scene.Player("p2"))
  assert sc.phase == "between_games"
  let assert Ok(off) = scene.find_zone(sc, "off:p1")
  assert list.length(off.tokens) == 15
  // Both players and a spectator read the result and who is ready.
  list.each([scene.Player("p1"), scene.Player("p2"), scene.Spectator], fn(v) {
    let data = scene_data(s, v)
    assert string.contains(
      data,
      "\"between_games\":{\"ready\":[],\"winner\":\"p1\",\"kind\":\"gammon\",\"stakes\":\"gammon\",\"points\":2,\"cube\":1}",
    )
    assert string.contains(data, "\"to_act\":null")
  })
}

pub fn nothing_but_ready_is_legal_between_games_test() {
  let s = game_at(4, "match5")
  let #(s, _) = white_wins(s)
  let not_started = Error("The next game has not started")
  list.each(["p1", "p2"], fn(id) {
    assert engine.apply(s, id, engine.Roll) == not_started
    assert engine.apply(s, id, engine.Pick(6, 6)) == not_started
    assert engine.apply(s, id, engine.Double) == not_started
    assert engine.apply(s, id, engine.MoveChecker(Point(6), Point(5)))
      == not_started
    assert engine.apply(s, id, engine.Resign(board.Single)) == not_started
    assert engine.apply(s, id, engine.Take) == Error("No double to answer")
    assert engine.apply(s, id, engine.Drop) == Error("No double to answer")
    assert engine.apply(s, id, engine.Undo) == Error("Nothing to undo")
    assert engine.apply(s, id, engine.Play) == Error("Nothing to play")
    assert engine.apply(s, id, engine.AcceptResign)
      == Error("No resignation to answer")
    assert state.can_resign(s, id) == False
    assert state.can_double(s, id) == False
  })
  let assert Error(_) = engine.apply(s, "ghost", engine.Ready)
}

pub fn one_ready_does_nothing_but_wait_test() {
  let s = game_at(5, "match5")
  let #(s, _) = white_wins(s)
  let before = s
  let #(s, events) = ready(s, "p2")
  assert kinds(events) == ["player_ready"]
  assert payload_of(events, "player_ready") == "{\"player_id\":\"p2\"}"
  let assert state.BetweenGames(_, ["p2"]) = s.phase
  // Nothing else moved: same board, score, cube, game, dice, randomness.
  assert state.GameState(..s, phase: before.phase) == before
  assert names(s, "p2") == []
  assert names(s, "p1") == ["ready"]
  assert engine.apply(s, "p2", engine.Ready) == Error("You are already ready")
  list.each([scene.Player("p1"), scene.Player("p2"), scene.Spectator], fn(v) {
    assert string.contains(scene_data(s, v), "\"ready\":[\"p2\"]")
  })
}

pub fn both_ready_start_the_next_game_test() {
  // The pause defers the next game, it does not change it: ready spends no
  // randomness, so the opening roll is the one the game's end would have
  // made at once (the platform's log patch for rooms from before the pause
  // relies on this; see Oskol.Game.ReadyUpPatch).
  list.each([6, 7, 8, 9], fn(seed) {
    let #(paused, _) = white_wins(game_at(seed, "match5"))
    let #(s, _) = ready(paused, "p1")
    assert s.rng == paused.rng
    let #(s, events) = ready(s, "p2")
    assert kinds(events) == ["player_ready", "new_game", "turn_started"]
    assert payload_of(events, "new_game")
      == "{\"game_number\":2,\"crawford\":false}"
    assert s.game_number == 2 && state.score_of(s, "p1") == 2
    let assert state.Moving(_, [a, b]) = s.phase
    assert a != b
    assert s.last_roll == [a, b] || s.last_roll == [b, a]
    assert s.board == board.initial() && s.turn_board == board.initial()
    assert s.cube_value == 1 && s.cube_owner == None
    assert s.staged == [] && s.picks_used == []
  })
}

pub fn the_cube_of_the_finished_game_stands_until_the_next_one_test() {
  let s = game_at(10, "match7")
  let s = state.GameState(..s, cube_value: 2, cube_owner: Some(White))
  let #(s, events) = white_wins(s)
  assert string.contains(payload_of(events, "game_won"), "\"points\":4")
  assert state.score_of(s, "p1") == 4
  // The cube the game was played for is still on the board...
  assert s.cube_value == 2 && s.cube_owner == Some(White)
  assert string.contains(
    scene_data(s, scene.Spectator),
    "\"points\":4,\"cube\":2}",
  )
  // ...and the next game starts centred, as it always has.
  let #(s, _) = ready(s, "p1")
  let #(s, _) = ready(s, "p2")
  assert s.cube_value == 1 && s.cube_owner == None
  assert state.score_of(s, "p1") == 4 && state.score_of(s, "p2") == 0
}

pub fn a_drop_and_an_accepted_resignation_pause_too_test() {
  // A drop
  let s = game_at(11, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White))
  let #(s, _) = apply(s, "p1", engine.Double)
  let #(s, _) = apply(s, "p2", engine.Drop)
  let assert state.BetweenGames(last, []) = s.phase
  assert last.kind == state.Dropped && last.winner == "p1"
  assert string.contains(
    scene_data(s, scene.Player("p1")),
    "\"kind\":\"dropped\",\"stakes\":\"single\",\"points\":1",
  )
  // A resignation, offered and accepted while the mover had a move staged:
  // the game ends on the position everyone saw, never on the private one.
  let s = game_at(12, "match5")
  let assert state.Moving(mover_color, _) = s.phase
  let mover = state.player_of(s, mover_color)
  let other = state.player_of(s, board.opponent(mover_color))
  let assert [m, ..] = state.legal_moves(s, mover)
  let #(staged, _) = apply(s, mover, engine.MoveChecker(m.from, m.to))
  assert staged.board != s.board
  let #(offered, _) = apply(staged, mover, engine.Resign(board.Gammon))
  let #(done, _) = apply(offered, other, engine.AcceptResign)
  let assert state.BetweenGames(last, []) = done.phase
  assert last.winner == other && last.points == 2
  assert done.board == s.board
  assert done.staged == []
  list.each([scene.Player(mover), scene.Player(other), scene.Spectator], fn(v) {
    let sc = backgammon.game().scene(done, v)
    let opening = backgammon.game().scene(s, scene.Player(other))
    assert list.filter(sc.zones, fn(z) { z.id != "dice" })
      == list.filter(opening.zones, fn(z) { z.id != "dice" })
  })
}

// ---------- Where ready is not ----------

pub fn ready_is_never_legal_in_a_single_game_test() {
  let s = game_at(13, "single")
  assert names(s, "p1") |> list.contains("ready") == False
  assert engine.apply(s, "p1", engine.Ready) == Error("The game is still on")
  let #(s, events) = white_wins(s)
  assert kinds(events)
    == [
      "turn_played",
      "checker_moved",
      "game_won",
      "match_over",
      "phase:game_over",
    ]
  let assert state.Finished(White) = s.phase
  assert names(s, "p1") == [] && names(s, "p2") == []
  assert engine.apply(s, "p1", engine.Ready) == Error("The match is over")
}

pub fn ready_is_not_legal_once_the_match_is_won_test() {
  let s = game_at(14, "match5")
  let s = state.GameState(..s, scores: dict.from_list([#("p1", 3), #("p2", 4)]))
  let #(s, events) = white_wins(s)
  assert list.contains(kinds(events), "match_over")
  let assert state.Finished(White) = s.phase
  assert backgammon.outcome(s) == game.Finished(["p1"])
  assert names(s, "p1") == [] && names(s, "p2") == []
  assert engine.apply(s, "p2", engine.Ready) == Error("The match is over")
}

pub fn ready_is_not_legal_during_play_test() {
  let s = game_at(15, "unlimited")
  list.each(["p1", "p2"], fn(id) {
    assert names(s, id) |> list.contains("ready") == False
    assert engine.apply(s, id, engine.Ready) == Error("The game is still on")
  })
  let s = state.GameState(..s, phase: state.Rolling(White))
  let #(s, _) = apply(s, "p1", engine.Double)
  assert engine.apply(s, "p2", engine.Ready) == Error("The game is still on")
}

pub fn unlimited_play_pauses_between_every_game_test() {
  let s = game_at(16, "unlimited")
  let #(s, _) = white_wins(s)
  let assert state.BetweenGames(_, []) = s.phase
  let #(s, _) = ready(s, "p2")
  let #(s, _) = ready(s, "p1")
  let #(s, _) = black_wins(s)
  let assert state.BetweenGames(last, []) = s.phase
  assert last.winner == "p2"
  assert state.score_of(s, "p1") == 1 && state.score_of(s, "p2") == 1
  assert backgammon.outcome(s) == game.Ongoing
}

// ---------- Crawford across the pause ----------

pub fn the_crawford_game_still_follows_a_pause_test() {
  // Match to 3: p1 wins a gammon, 2-0, one away. The pause comes first;
  // the game after it is the Crawford game.
  let s = game_at(17, "match3")
  let #(s, _) = white_wins(s)
  let assert state.BetweenGames(_, []) = s.phase
  assert s.crawford == False && s.crawford_done == False
  let #(s, _) = ready(s, "p2")
  let #(s, events) = ready(s, "p1")
  assert string.contains(payload_of(events, "new_game"), "\"crawford\":true")
  assert s.crawford && s.crawford_done && s.game_number == 2
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "resign"]
  // p2 wins the Crawford game: 2-1, a pause, then doubling is back.
  let #(s, _) = black_wins(s)
  let assert state.BetweenGames(_, []) = s.phase
  let #(s, _) = ready(s, "p1")
  let #(s, events) = ready(s, "p2")
  assert string.contains(payload_of(events, "new_game"), "\"crawford\":false")
  assert s.crawford == False && s.crawford_done
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "double", "resign"]
}

// ---------- Clocks ----------

fn send(inst, who: String, text: String, now: Int) {
  let assert Ok(raw) = conformance.parse(text)
  let assert Ok(#(next, events)) = instance.apply(inst, who, raw, now)
  #(next, events)
}

pub fn nobody_is_on_the_clock_between_games_test() {
  // Fischer 60 s + 5 s with backgammon's 12 s turn delay. The first game
  // ends by an accepted resignation; then ten minutes pass between games.
  // Neither clock may lose a millisecond, nobody flags, and the clock that
  // starts again is the next game's mover's, with a fresh turn delay.
  let assert Ok(inst) =
    instance.start(
      backgammon.game(),
      "match5",
      [],
      seats(),
      40,
      clock.Fischer(60_000, 5000),
      0,
    )
  let clocks = instance.clocks(inst)
  let #(mover, other) = case clock.running(clocks, "p1") {
    True -> #("p1", "p2")
    False -> #("p2", "p1")
  }
  let #(inst, _) =
    send(
      inst,
      mover,
      "{\"name\":\"resign\",\"params\":{\"stakes\":\"single\"}}",
      1000,
    )
  let #(inst, _) =
    send(inst, other, "{\"name\":\"accept_resign\",\"params\":{}}", 2000)
  assert list.map(instance.legal(inst, "p1"), fn(s) { s.name }) == ["ready"]
  let clocks = instance.clocks(inst)
  assert !clock.running(clocks, "p1") && !clock.running(clocks, "p2")
  let mover_left = clock.remaining(clocks, mover, 2000)
  let other_left = clock.remaining(clocks, other, 2000)
  assert instance.next_deadline(inst, 2000) == None
  let later = 2000 + 600_000
  assert instance.expire(inst, later) == None
  assert clock.remaining(clocks, mover, later) == mover_left
  assert clock.remaining(clocks, other, later) == other_left
  // One ready, still nobody charged, and no increment for pressing it.
  let #(inst, _) = send(inst, "p1", "{\"name\":\"ready\",\"params\":{}}", later)
  let clocks = instance.clocks(inst)
  assert !clock.running(clocks, "p1") && !clock.running(clocks, "p2")
  let later = later + 600_000
  let #(inst, events) =
    send(inst, "p2", "{\"name\":\"ready\",\"params\":{}}", later)
  assert list.contains(kinds(events), "new_game")
  assert instance.clocks(inst).timed_out == None
  let clocks = instance.clocks(inst)
  let assert [next_mover] =
    list.filter(["p1", "p2"], fn(id) { clock.running(clocks, id) })
  let waiting = case next_mover {
    "p1" -> "p2"
    _ -> "p1"
  }
  let before = case next_mover == mover {
    True -> mover_left
    False -> other_left
  }
  // The new turn's delay covers its first twelve seconds.
  assert clock.remaining(clocks, next_mover, later + 12_000) == before
  assert clock.remaining(clocks, waiting, later + 12_000)
    == case waiting == mover {
      True -> mover_left
      False -> other_left
    }
}

// ---------- A game is its seed plus its log ----------

/// The shortest prefix of `steps` whose replay ends between games.
fn first_pause(steps: List(Step), taken: Int) -> Result(Int, Nil) {
  case taken > list.length(steps) {
    True -> Error(Nil)
    False -> {
      let assert Ok(s) =
        conformance.replay(
          backgammon.game(),
          "match5",
          seats(),
          21,
          list.take(steps, taken),
        )
      case s.phase {
        state.BetweenGames(_, []) -> Ok(taken)
        _ -> first_pause(steps, taken + 1)
      }
    }
  }
}

pub fn a_paused_match_replays_from_its_seed_and_log_test() {
  // Random play presses ready like any
  // other action and still finishes the match.
  let assert Ok(report) =
    conformance.random_playout(
      backgammon.game(),
      "match5",
      seats(),
      21,
      20_000,
      fn(_) { Ok(Nil) },
    )
  assert report.finished
  assert list.any(report.steps, fn(step) {
    string.contains(step.action_json, "\"ready\"")
  })
  let assert Ok(pause) = first_pause(report.steps, 1)
  let log = list.take(report.steps, pause)
  // Rebuilt from the seed and the log, twice: the same paused state.
  let assert Ok(a) =
    conformance.replay(backgammon.game(), "match5", seats(), 21, log)
  let assert Ok(b) =
    conformance.replay(backgammon.game(), "match5", seats(), 21, log)
  assert a == b
  assert string.contains(
    scene_data(a, scene.Spectator),
    "\"between_games\":{\"ready\":[]",
  )
  // Half ready survives a rebuild too.
  let half =
    list.append(log, [
      conformance.Step("p2", "{\"name\":\"ready\",\"params\":{}}"),
    ])
  let assert Ok(h) =
    conformance.replay(backgammon.game(), "match5", seats(), 21, half)
  let assert state.BetweenGames(_, ["p2"]) = h.phase
  assert names(h, "p1") == ["ready"]
}
