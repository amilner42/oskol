//// The "Pick dice" twist: once per game, on your turn to roll, pick both
//// dice instead of rolling. Off by default; picked rolls are transparent.

import backgammon/board.{Bar, Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/projection
import backgammon/state
import gamekit/action
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/string

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

/// A new game with the twist on (or off) for a format, via the same
/// `configure` path the lobby uses.
fn new_game(seed: Int, format: String, twist_on: Bool) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let selections = case twist_on {
    True -> dict.from_list([#("twist", "pick_dice")])
    False -> dict.new()
  }
  let assert Ok(config) = game.configure(f, selections)
  let assert Ok(s) = backgammon.init(config, seats(), rng.seed(seed))
  s
}

/// The game parked on White's turn to roll (p1 is White).
fn rolling(s: state.GameState) -> state.GameState {
  state.GameState(..s, phase: state.Rolling(White), staged: [])
}

/// A board from #(color, loc, count) entries.
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

fn names(schemas: List(action.Schema)) -> List(String) {
  list.map(schemas, fn(s) { s.name })
}

fn custom_payload(events: List(event.Event), kind: String) -> String {
  let assert Ok(payload) =
    list.find_map(events, fn(e) {
      case e {
        event.Custom(k, payload) if k == kind -> Ok(payload)
        _ -> Error(Nil)
      }
    })
  json.to_string(payload)
}

// ---------- Legality ----------

pub fn setting_off_pick_is_never_legal_test() {
  let s = rolling(new_game(1, "single", False))
  assert !list.contains(names(engine.legal(s, "p1")), "pick")
  assert engine.apply(s, "p1", engine.Pick(3, 4))
    == Error("Dice picking is not enabled")
}

pub fn setting_on_pick_is_legal_exactly_at_roll_time_test() {
  let s = rolling(new_game(1, "single", True))
  // The roller may roll or pick; the opponent may do neither.
  assert list.contains(names(engine.legal(s, "p1")), "pick")
  assert list.contains(names(engine.legal(s, "p1")), "roll")
  assert !list.contains(names(engine.legal(s, "p2")), "pick")
  assert engine.apply(s, "p2", engine.Pick(3, 4)) == Error("Not your turn")
  // Once the dice are down, the pick window is closed.
  let assert Ok(#(moving, _)) = engine.apply(s, "p1", engine.Pick(6, 5))
  let assert state.Moving(White, [6, 5]) = moving.phase
  assert moving.last_roll == [6, 5]
  assert moving.last_roll_picked
  assert !list.contains(names(engine.legal(moving, "p1")), "pick")
  assert engine.apply(moving, "p1", engine.Pick(1, 2))
    == Error("Dice already rolled")
  // And not while a double is pending either.
  let doubled = state.GameState(..s, phase: state.Doubled(Black))
  assert engine.apply(doubled, "p1", engine.Pick(1, 2))
    == Error("A double is pending")
}

pub fn pick_rejects_out_of_range_dice_test() {
  let s = rolling(new_game(1, "single", True))
  assert engine.apply(s, "p1", engine.Pick(0, 3))
    == Error("Die values must be 1 to 6")
  assert engine.apply(s, "p1", engine.Pick(3, 7))
    == Error("Die values must be 1 to 6")
}

pub fn pick_consumes_no_randomness_test() {
  let s = rolling(new_game(2, "single", True))
  let assert Ok(#(next, _)) = engine.apply(s, "p1", engine.Pick(3, 1))
  assert next.rng == s.rng
}

// ---------- Once per player per game ----------

pub fn each_player_picks_once_per_game_test() {
  let s = rolling(new_game(3, "single", True))
  let assert Ok(#(after, _)) = engine.apply(s, "p1", engine.Pick(2, 1))
  // Back on a later turn to roll: p1's pick is spent, p2 still holds theirs.
  let later = rolling(after)
  assert !state.can_pick(later, "p1")
  assert !list.contains(names(engine.legal(later, "p1")), "pick")
  assert engine.apply(later, "p1", engine.Pick(2, 1))
    == Error("You have already used your pick this game")
  let their_turn = state.GameState(..after, phase: state.Rolling(Black))
  assert state.can_pick(their_turn, "p2")
  assert list.contains(names(engine.legal(their_turn, "p2")), "pick")
}

pub fn picks_reset_each_game_of_a_match_test() {
  // Both picks spent; White bears off their last checker to end the game.
  let s = new_game(4, "match5", True)
  let b = setup([#(White, Point(1), 1), #(White, Off, 14), #(Black, Off, 15)])
  let s =
    state.GameState(
      ..s,
      board: b,
      turn_board: b,
      phase: state.Moving(White, [1]),
      last_roll: [1, 2],
      picks_used: ["p1", "p2"],
      staged: [],
    )
  let assert Ok(#(s, _)) =
    engine.apply(s, "p1", engine.MoveChecker(Point(1), Off))
  let assert Ok(#(next, events)) = engine.apply(s, "p1", engine.Play)
  // A new game of the match began, and both picks are back.
  let assert Ok(_) =
    list.find(events, fn(e) {
      case e {
        event.Custom("new_game", _) -> True
        _ -> False
      }
    })
  assert next.game_number == 2
  assert next.picks_used == []
  assert !next.last_roll_picked
  assert state.can_pick(rolling(next), "p1")
}

// ---------- Picked dice play like rolled dice ----------

pub fn a_doubles_pick_gives_four_moves_test() {
  let s = rolling(new_game(5, "single", True))
  let assert Ok(#(next, _)) = engine.apply(s, "p1", engine.Pick(6, 6))
  let assert state.Moving(White, [6, 6, 6, 6]) = next.phase
  assert state.turn_dice(next) == [6, 6, 6, 6]
}

pub fn a_picked_roll_drives_the_same_forced_move_logic_test() {
  // 8 -> 4 -> 2 works; 8 -> 6 is blocked, so the 4 must be played first:
  // exactly the constraint a rolled 4-2 imposes.
  let b =
    setup([
      #(White, Point(8), 1),
      #(White, Point(20), 1),
      #(Black, Point(6), 2),
      #(Black, Point(16), 2),
      #(Black, Point(18), 2),
    ])
  let s = new_game(6, "single", True)
  let s = rolling(state.GameState(..s, board: b, turn_board: b, last_roll: []))
  let assert Ok(#(next, _)) = engine.apply(s, "p1", engine.Pick(4, 2))
  assert list.map(state.legal_moves(next, "p1"), fn(m) {
      #(board.loc_id(m.from), board.loc_id(m.to))
    })
    == [#("8", "4")]
}

pub fn a_picked_roll_with_no_moves_dances_like_a_rolled_one_test() {
  // White is on the bar against a blocked 23 and 24: a picked 1-2 dances.
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(8), 14),
      #(Black, Point(23), 2),
      #(Black, Point(24), 2),
      #(Black, Point(12), 11),
    ])
  let s = new_game(7, "single", True)
  let s = rolling(state.GameState(..s, board: b, turn_board: b, last_roll: []))
  let assert Ok(#(next, events)) = engine.apply(s, "p1", engine.Pick(1, 2))
  // The picked dice stand on White's own turn until White passes it.
  let assert state.Moving(White, _) = next.phase
  assert state.no_moves(next)
  let assert Ok(#(passed, _)) = engine.apply(next, "p1", engine.Play)
  let assert state.Rolling(Black) = passed.phase
  let assert Ok(_) =
    list.find(events, fn(e) {
      case e {
        event.Custom("no_moves", _) -> True
        _ -> False
      }
    })
  assert string.contains(
    custom_payload(events, "dice_rolled"),
    "\"picked\":true",
  )
}

// ---------- Transparency ----------

pub fn the_dice_rolled_event_carries_the_picked_flag_test() {
  let s = rolling(new_game(8, "single", True))
  let assert Ok(#(_, picked_events)) = engine.apply(s, "p1", engine.Pick(5, 3))
  assert string.contains(
    custom_payload(picked_events, "dice_rolled"),
    "\"picked\":true",
  )
  let assert Ok(#(_, rolled_events)) = engine.apply(s, "p1", engine.Roll)
  assert string.contains(
    custom_payload(rolled_events, "dice_rolled"),
    "\"picked\":false",
  )
}

pub fn the_scene_shows_the_pick_to_both_players_test() {
  let s = rolling(new_game(9, "single", True))
  // Before any pick: both players still hold theirs.
  let before =
    json.to_string(scene.to_json(projection.build(s, scene.Player("p2"))))
  assert string.contains(before, "has_pick")
  let assert Ok(#(next, _)) = engine.apply(s, "p1", engine.Pick(6, 6))
  // The opponent's view marks the dice as picked and p1's pick as spent.
  let theirs =
    projection.build(next, scene.Player("p2"))
    |> scene.to_json
    |> json.to_string
  assert string.contains(theirs, "\"picked\":true")
  let assert Ok(p1) =
    list.find(projection.build(next, scene.Player("p2")).players, fn(p) {
      p.id == "p1"
    })
  assert !list.contains(p1.flags, "has_pick")
  let assert Ok(p2) =
    list.find(projection.build(next, scene.Player("p2")).players, fn(p) {
      p.id == "p2"
    })
  assert list.contains(p2.flags, "has_pick")
}

pub fn with_the_twist_off_nobody_holds_a_pick_test() {
  let s = rolling(new_game(10, "single", False))
  let assert Ok(p1) =
    list.find(projection.build(s, scene.Player("p1")).players, fn(p) {
      p.id == "p1"
    })
  assert !list.contains(p1.flags, "has_pick")
}

// ---------- Replay determinism with the twist on ----------

pub fn a_picked_game_replays_deterministically_test() {
  // The same seed and the same actions (pick included) land on the same
  // state: a pick is part of the log, not the randomness.
  let play = fn() {
    let s = rolling(new_game(11, "single", True))
    let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Pick(3, 1))
    let assert [m, ..] = state.legal_moves(s, "p1")
    let assert Ok(#(s, _)) =
      engine.apply(s, "p1", engine.MoveChecker(m.from, m.to))
    let assert [m2, ..] = state.legal_moves(s, "p1")
    let assert Ok(#(s, _)) =
      engine.apply(s, "p1", engine.MoveChecker(m2.from, m2.to))
    let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Play)
    // The next roll draws from the same untouched stream every time.
    let assert Ok(#(s, dice)) = state.roll(s, "p2")
    #(s, dice)
  }
  let #(a, dice_a) = play()
  let #(b, dice_b) = play()
  assert dice_a == dice_b
  assert projection.build(a, scene.Player("p1"))
    == projection.build(b, scene.Player("p1"))
}
