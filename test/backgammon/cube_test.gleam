//// The doubling cube, match formats, Crawford, Jacoby, resigning.

import backgammon/board.{
  Backgammon, Bar, Black, Gammon, Off, Point, Single, White,
}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/action
import gamekit/clock
import gamekit/conformance
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

/// Between the games of a match both players press ready; the second one
/// starts the next game.
fn both_ready(s: state.GameState) -> #(state.GameState, List(event.Event)) {
  let #(s, _) = apply(s, "p1", engine.Ready)
  apply(s, "p2", engine.Ready)
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
  assert single.config
    == state.Config(target: 1, cube: False, jacoby: False, pick_dice: False)
  let match3 = new_game(1, "match3")
  assert match3.config
    == state.Config(target: 3, cube: True, jacoby: False, pick_dice: False)
  let unlimited = new_game(1, "unlimited")
  assert unlimited.config
    == state.Config(target: 0, cube: True, jacoby: True, pick_dice: False)
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
  assert state.score_of(s, "p1") == 2
  let #(s, events) = both_ready(s)
  assert has_custom(events, "new_game")
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

// ---------- Resigning ----------
//
// A resignation is an offer of stakes the opponent answers. Accepted, it
// pays stakes x cube through the same finish as a won game; declined, the
// board is exactly as it was.

fn resign_schema(stakes: List(#(String, String))) {
  action.Schema("resign", "Resign", [action.choice("stakes", stakes)])
}

const all_stakes = [
  #("single", "Single"),
  #("gammon", "Gammon"),
  #("backgammon", "Backgammon"),
]

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

pub fn resigning_offers_stakes_and_freezes_the_board_test() {
  let s = white_to_roll(10, "match5")
  let s = state.GameState(..s, cube_value: 2, cube_owner: Some(Black))
  assert engine.legal(s, "p2") == [resign_schema(all_stakes)]
  let #(s, events) = apply(s, "p2", engine.Resign(Gammon))
  let payload = payload_of(events, "resign_offered")
  assert string.contains(payload, "\"stakes\":\"gammon\"")
  assert string.contains(payload, "\"points\":4")
  assert s.resign_offer == Some(state.ResignOffer(Black, Gammon))
  // Nothing else changed: same phase, same score, same game
  let assert state.Rolling(White) = s.phase
  assert state.score_of(s, "p1") == 0 && s.game_number == 1
  // The responder is the only one with anything to do, and is on the clock
  assert names(s, "p1") == ["accept_resign", "decline_resign"]
  assert names(s, "p2") == []
  assert engine.on_the_clock(s) == ["p1"]
  assert state.to_act(s) == Some("p1")
  assert state.to_move(s) == Some("p1")
  // Play is frozen for both, and a second offer waits for the first
  assert engine.apply(s, "p1", engine.Roll) == Error("A resignation is pending")
  assert engine.apply(s, "p1", engine.Double)
    == Error("A resignation is pending")
  assert engine.apply(s, "p2", engine.Resign(Single))
    == Error("A resignation is pending")
  assert engine.apply(s, "p1", engine.Resign(Single))
    == Error("A resignation is pending")
  // Only the opponent may answer
  assert engine.apply(s, "p2", engine.AcceptResign)
    == Error("You offered the resignation")
  assert engine.apply(s, "p2", engine.DeclineResign)
    == Error("You offered the resignation")
  // The offer is in both scenes
  let sc = backgammon.game().scene(s, scene.Player("p1"))
  assert json.to_string(json.object(sc.data))
    |> string.contains(
      "\"resign_offer\":{\"from\":\"p2\",\"stakes\":\"gammon\",\"points\":4}",
    )
  assert json.to_string(json.object(sc.data))
    |> string.contains("\"to_act\":\"p1\"")
}

pub fn accepting_a_resignation_pays_stakes_times_cube_test() {
  list.each(
    [
      #(Single, 1, 1),
      #(Gammon, 1, 2),
      #(Backgammon, 1, 3),
      #(Single, 2, 2),
      #(Gammon, 2, 4),
      #(Backgammon, 2, 6),
    ],
    fn(case_) {
      let #(stakes, cube, points) = case_
      let s = white_to_roll(11, "match7")
      let s = case cube {
        1 -> s
        _ -> state.GameState(..s, cube_value: cube, cube_owner: Some(Black))
      }
      let #(s, _) = apply(s, "p2", engine.Resign(stakes))
      let #(s, events) = apply(s, "p1", engine.AcceptResign)
      assert has_custom(events, "resign_accepted")
      assert has_custom(events, "game_won")
      let won = payload_of(events, "game_won")
      assert string.contains(won, "\"kind\":\"resigned\"")
      assert string.contains(
        won,
        "\"stakes\":\"" <> board.kind_name(stakes) <> "\"",
      )
      assert string.contains(won, "\"points\":" <> int.to_string(points))
      assert state.score_of(s, "p1") == points
      assert state.score_of(s, "p2") == 0
      assert s.resign_offer == None
      let #(s, events) = both_ready(s)
      assert has_custom(events, "new_game")
      assert s.game_number == 2
      assert s.cube_value == 1 && s.cube_owner == None
    },
  )
}

pub fn declining_a_resignation_resumes_the_same_turn_and_dice_test() {
  // Mid-turn, one move staged: the offer must not disturb any of it.
  let s = new_game(12, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White))
  let #(s, _) = apply(s, "p1", engine.Roll)
  let assert [m, ..] = state.legal_moves(s, "p1")
  let #(s, _) = apply(s, "p1", engine.MoveChecker(m.from, m.to))
  let before = s
  let #(s, _) = apply(s, "p1", engine.Resign(Single))
  assert names(s, "p1") == []
  assert names(s, "p2") == ["accept_resign", "decline_resign"]
  assert engine.apply(s, "p1", engine.Play) == Error("A resignation is pending")
  assert engine.apply(s, "p1", engine.Undo) == Error("A resignation is pending")
  // The responder joins the clock; the mover's keeps running
  assert engine.on_the_clock(s) == ["p2", "p1"]
  let #(s, events) = apply(s, "p2", engine.DeclineResign)
  assert has_custom(events, "resign_declined")
  assert has_custom(events, "turn_started")
  assert s == before
  assert state.dice_left(s) == state.dice_left(before)
  assert engine.legal(s, "p1") == engine.legal(before, "p1")
  assert engine.on_the_clock(s) == ["p1"]
  // And the resigner may offer again
  let #(s, _) = apply(s, "p1", engine.Resign(Gammon))
  assert s.resign_offer == Some(state.ResignOffer(White, Gammon))
}

pub fn a_resignation_may_be_offered_while_a_double_is_pending_test() {
  let s = white_to_roll(13, "match5")
  let #(s, _) = apply(s, "p1", engine.Double)
  // The player weighing the take resigns instead: the doubler answers
  let #(s, _) = apply(s, "p2", engine.Resign(Single))
  // The doubler answers the offer, and the taker's clock keeps running
  assert engine.on_the_clock(s) == ["p1", "p2"]
  assert engine.apply(s, "p2", engine.Take) == Error("A resignation is pending")
  let #(declined, _) = apply(s, "p1", engine.DeclineResign)
  let assert state.Doubled(White) = declined.phase
  assert names(declined, "p2") == ["take", "drop", "resign"]
  // Accepted, the cube was never turned: one point, not two
  let #(accepted, _) = apply(s, "p1", engine.AcceptResign)
  assert state.score_of(accepted, "p1") == 1
  let #(accepted, _) = both_ready(accepted)
  assert accepted.game_number == 2
}

pub fn jacoby_with_a_centred_cube_offers_only_a_single_test() {
  let s = white_to_roll(14, "unlimited")
  assert engine.legal(s, "p2") == [resign_schema([#("single", "Single")])]
  assert engine.apply(s, "p2", engine.Resign(Gammon))
    == Error("Gammons do not count until the cube is turned")
  assert engine.apply(s, "p2", engine.Resign(Backgammon))
    == Error("Gammons do not count until the cube is turned")
  // Once the cube is turned, gammons count and every stake is on offer
  let turned = state.GameState(..s, cube_value: 2, cube_owner: Some(White))
  assert engine.legal(turned, "p2") == [resign_schema(all_stakes)]
  let #(turned, _) = apply(turned, "p2", engine.Resign(Backgammon))
  let #(turned, _) = apply(turned, "p1", engine.AcceptResign)
  assert state.score_of(turned, "p1") == 6
  // Match play has no Jacoby rule: a centred cube still offers everything
  assert engine.legal(white_to_roll(14, "match5"), "p2")
    == [resign_schema(all_stakes)]
}

pub fn an_accepted_resignation_can_end_the_match_test() {
  // Match to 5 at 3-0, cube at 2: a resigned single ends it exactly.
  let s = white_to_roll(15, "match5")
  let s =
    state.GameState(
      ..s,
      scores: dict.from_list([#("p1", 3), #("p2", 0)]),
      cube_value: 2,
      cube_owner: Some(Black),
    )
  let #(s, _) = apply(s, "p2", engine.Resign(Single))
  let #(s, events) = apply(s, "p1", engine.AcceptResign)
  assert has_custom(events, "match_over")
  assert state.score_of(s, "p1") == 5
  let assert state.Finished(White) = s.phase
  assert backgammon.outcome(s) == game.Finished(["p1"])
  assert engine.legal(s, "p1") == [] && engine.legal(s, "p2") == []
  assert engine.apply(s, "p2", engine.Resign(Single))
    == Error("The match is over")
  // One short of the target hands the next game to Crawford
  let s = white_to_roll(15, "match5")
  let s = state.GameState(..s, scores: dict.from_list([#("p1", 2), #("p2", 0)]))
  let #(s, _) = apply(s, "p2", engine.Resign(Gammon))
  let #(s, _) = apply(s, "p1", engine.AcceptResign)
  assert state.score_of(s, "p1") == 4
  let #(s, _) = both_ready(s)
  assert s.crawford && s.game_number == 2
}

pub fn an_offer_never_stops_the_offerer_clock_test() {
  // Fischer 60 s + 10 s, with backgammon's 12 s turn delay. The mover is
  // on the clock from the opening roll; offering to resign must not stop
  // it, and being declined must not restart it with a fresh delay or an
  // increment -- otherwise a player about to flag could stall forever.
  let assert Ok(inst) =
    instance.start(
      backgammon.game(),
      "match5",
      [],
      seats(),
      40,
      clock.Fischer(60_000, 10_000),
      0,
    )
  let clocks = instance.clocks(inst)
  let #(mover, other) = case clock.running(clocks, "p1") {
    True -> #("p1", "p2")
    False -> #("p2", "p1")
  }
  assert clock.running(clocks, other) == False
  let send = fn(inst, who, text, now) {
    let assert Ok(raw) = conformance.parse(text)
    let assert Ok(#(next, _)) = instance.apply(inst, who, raw, now)
    next
  }
  let inst =
    send(
      inst,
      mover,
      "{\"name\":\"resign\",\"params\":{\"stakes\":\"single\"}}",
      5000,
    )
  let clocks = instance.clocks(inst)
  assert clock.running(clocks, mover) && clock.running(clocks, other)
  let inst =
    send(inst, other, "{\"name\":\"decline_resign\",\"params\":{}}", 6000)
  let clocks = instance.clocks(inst)
  assert clock.running(clocks, mover) && !clock.running(clocks, other)
  // 13 s into the turn: the 12 s delay from the roll is spent and one
  // second is charged. A re-granted delay would have left it untouched, an
  // increment would have added ten seconds.
  assert clock.remaining(clocks, mover, 13_000) == 59_000
  // The responder was charged for the second they took, inside their own
  // delay, and banked the increment for having acted.
  assert clock.remaining(clocks, other, 13_000) == 70_000
}

pub fn resign_actions_decode_with_and_without_stakes_test() {
  let decode = fn(text) {
    let assert Ok(raw) = conformance.parse(text)
    let assert Ok(incoming) = action.decode_incoming(raw)
    backgammon.decode_action(incoming)
  }
  assert decode("{\"name\":\"resign\",\"params\":{\"stakes\":\"gammon\"}}")
    == Ok(engine.Resign(Gammon))
  assert decode(
      "{\"name\":\"resign\",\"params\":{\"stakes\":[\"backgammon\"]}}",
    )
    == Ok(engine.Resign(Backgammon))
  assert decode("{\"name\":\"resign\",\"params\":{}}")
    == Ok(engine.Resign(Single))
  assert decode("{\"name\":\"resign\",\"params\":{\"stakes\":\"double\"}}")
    == Error("Unknown stakes: double")
  assert decode("{\"name\":\"accept_resign\",\"params\":{}}")
    == Ok(engine.AcceptResign)
  assert decode("{\"name\":\"decline_resign\",\"params\":{}}")
    == Ok(engine.DeclineResign)
}

fn bear_off_and_play(
  s: state.GameState,
) -> #(state.GameState, List(event.Event)) {
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  apply(s, "p1", engine.Play)
}

pub fn nobody_may_double_before_the_first_roll_test() {
  // The opening roll starts the game already in Moving: there is no chance
  // to double before the first roll, for either player.
  let s = new_game(20, "match5")
  let assert state.Moving(_, _) = s.phase
  assert state.can_double(s, "p1") == False
  assert state.can_double(s, "p2") == False
  assert names(s, "p1") |> list.contains("double") == False
  assert names(s, "p2") |> list.contains("double") == False
  assert engine.apply(s, "p1", engine.Double)
    == Error("You can only double before rolling")
  assert engine.apply(s, "p2", engine.Double)
    == Error("You can only double before rolling")
}

pub fn black_may_double_from_the_center_on_their_turn_test() {
  let s = new_game(21, "match5")
  let s = state.GameState(..s, phase: state.Rolling(Black))
  assert names(s, "p2") == ["roll", "double", "resign"]
  let #(s, _) = apply(s, "p2", engine.Double)
  let assert state.Doubled(Black) = s.phase
  assert names(s, "p1") == ["take", "drop", "resign"]
  let #(s, _) = apply(s, "p1", engine.Take)
  assert s.cube_value == 2
  assert s.cube_owner == Some(White)
  let assert state.Rolling(Black) = s.phase
}

pub fn a_backgammon_scores_three_times_the_cube_test() {
  // Black has borne off nothing and still has a checker on the bar.
  let b =
    setup([
      #(White, Off, 14),
      #(White, Point(1), 1),
      #(Black, Bar, 1),
      #(Black, Point(19), 14),
    ])
  let s = new_game(22, "match7")
  let s =
    state.GameState(
      ..s,
      board: b,
      phase: state.Moving(White, [1, 2]),
      cube_value: 2,
      cube_owner: Some(White),
    )
  let #(s, events) = bear_off_and_play(s)
  assert state.score_of(s, "p1") == 6
  assert list.any(events, fn(e) {
    case e {
      event.Custom("game_won", payload) ->
        json.to_string(payload) |> string.contains("\"kind\":\"backgammon\"")
        && json.to_string(payload) |> string.contains("\"points\":6")
      _ -> False
    }
  })
  // A checker left in the winner's home board is a backgammon too.
  let in_home =
    setup([
      #(White, Off, 14),
      #(White, Point(1), 1),
      #(Black, Point(3), 1),
      #(Black, Point(19), 14),
    ])
  let s2 = new_game(22, "match7")
  let s2 =
    state.GameState(..s2, board: in_home, phase: state.Moving(White, [1, 2]))
  let #(s2, _) = bear_off_and_play(s2)
  assert state.score_of(s2, "p1") == 3
}

pub fn jacoby_applies_to_backgammons_too_test() {
  let b =
    setup([
      #(White, Off, 14),
      #(White, Point(1), 1),
      #(Black, Bar, 1),
      #(Black, Point(19), 14),
    ])
  let centred = new_game(23, "unlimited")
  let centred =
    state.GameState(..centred, board: b, phase: state.Moving(White, [1, 2]))
  let #(after, _) = bear_off_and_play(centred)
  assert state.score_of(after, "p1") == 1
  let turned =
    state.GameState(..centred, cube_value: 2, cube_owner: Some(Black))
  let #(after, _) = bear_off_and_play(turned)
  assert state.score_of(after, "p1") == 6
}

pub fn the_match_ends_when_points_overshoot_the_target_test() {
  // Match to 3, gammon with the cube at 2: four points, the match is over.
  let b =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = new_game(24, "match3")
  let s =
    state.GameState(
      ..s,
      board: b,
      phase: state.Moving(White, [1, 2]),
      cube_value: 2,
      cube_owner: Some(White),
    )
  let #(s, events) = bear_off_and_play(s)
  assert has_custom(events, "match_over")
  assert state.score_of(s, "p1") == 4
  let assert state.Finished(White) = s.phase
}

// ---------- Crawford ----------

pub fn the_crawford_game_forbids_doubling_then_it_resumes_test() {
  // Match to 3: p1 wins 2 points -> 2-0, one away -> Crawford game.
  let b =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = new_game(11, "match3")
  let s = state.GameState(..s, board: b, phase: state.Moving(White, [1, 2]))
  let #(s, _) = bear_off_and_play(s)
  assert state.score_of(s, "p1") == 2
  let #(s, events) = both_ready(s)
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
  let #(s, _) = both_ready(s)
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
