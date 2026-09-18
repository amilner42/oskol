//// The game record: notation on controlled positions, the cube and game
//// lines, and that it reaches every viewer's scene and survives a replay.

import backgammon/board.{Bar, Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/positions
import backgammon/projection
import backgammon/record
import backgammon/state
import gamekit/conformance
import gamekit/game
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn new_game(seed: Int, format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) =
    backgammon.init(f.config, positions.seats(), rng.seed(seed))
  s
}

/// A game in a chosen position with `color` to play the given dice.
fn position(
  seed: Int,
  format: String,
  b: board.Board,
  color: board.Color,
  dice: List(Int),
) -> state.GameState {
  let s = new_game(seed, format)
  state.GameState(
    ..s,
    board: b,
    turn_board: b,
    staged: [],
    turn_dead: board.legal_moves(b, color, dice) == [],
    phase: state.Moving(color, dice),
    last_roll: list.take(dice, 2),
    record: [],
  )
}

fn apply(
  s: state.GameState,
  id: String,
  action: engine.Action,
) -> state.GameState {
  let assert Ok(#(next, _)) = engine.apply(s, id, action)
  next
}

fn move(s: state.GameState, id: String, from: board.Loc, to: board.Loc) {
  apply(s, id, engine.MoveChecker(from, to))
}

/// The last turn recorded.
fn last_turn(s: state.GameState) -> record.Entry {
  let assert [entry, ..] = s.record
  entry
}

// ---------- Notation ----------

pub fn a_hit_is_starred_test() {
  let b =
    setup([
      #(White, Point(8), 2),
      #(White, Point(6), 2),
      #(White, Point(24), 11),
      #(Black, Point(5), 1),
      #(Black, Point(12), 14),
    ])
  let s = position(1, "single", b, White, [3, 1])
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(6), Point(5))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [3, 1], ["8/5*", "6/5"], state.snapshot(s), [
      5,
      5,
    ])
  assert record.text(last_turn(s)) == "31: 8/5* 6/5"
}

pub fn entering_from_the_bar_reads_bar_slash_point_test() {
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(13), 14),
      #(Black, Point(1), 2),
      #(Black, Point(12), 13),
    ])
  let s = position(2, "single", b, White, [3, 5])
  let s = move(s, "p1", Bar, Point(22))
  let s = move(s, "p1", Point(13), Point(8))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [5, 3], ["bar/22", "13/8"], state.snapshot(s), [
      8,
      22,
    ])
}

pub fn bearing_off_reads_point_slash_off_test() {
  let b =
    setup([#(White, Point(6), 2), #(White, Off, 13), #(Black, Point(19), 15)])
  let s = position(3, "single", b, White, [6, 4])
  let s = move(s, "p1", Point(6), Off)
  let s = move(s, "p1", Point(6), Point(2))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 4], ["6/off", "6/2"], state.snapshot(s), [2])
}

pub fn a_double_groups_identical_moves_test() {
  let b =
    setup([
      #(White, Point(8), 3),
      #(White, Point(6), 5),
      #(White, Point(13), 7),
      #(Black, Point(1), 2),
      #(Black, Point(12), 13),
    ])
  let s = position(4, "single", b, White, [3, 3, 3, 3])
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(6), Point(3))
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(6), Point(3))
  let s = apply(s, "p1", engine.Play)
  // Grouped by move, in the order each was first made, however the four
  // were interleaved.
  assert last_turn(s)
    == record.Turn("p1", [3, 3], ["8/5(2)", "6/3(2)"], state.snapshot(s), [
      3,
      3,
      5,
      5,
    ])
  assert record.text(last_turn(s)) == "33: 8/5(2) 6/3(2)"
}

pub fn a_hit_by_a_grouped_move_keeps_its_star_test() {
  let b =
    setup([
      #(White, Point(8), 3),
      #(White, Point(24), 12),
      #(Black, Point(5), 1),
      #(Black, Point(12), 14),
    ])
  let s = position(5, "single", b, White, [3, 3, 3, 3])
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(5), Point(2))
  let s = apply(s, "p1", engine.Play)
  // The step from 5 continues the checker that got there last: two made
  // the point (the first of them hit), one went on to 2.
  assert last_turn(s)
    == record.Turn("p1", [3, 3], ["8/5*(2)", "8/2"], state.snapshot(s), [
      2,
      5,
      5,
    ])
}

pub fn black_reads_the_board_from_its_own_side_test() {
  // Black moves 1 -> 24: its point 1 is its 24, its point 19 is its 6.
  let b =
    setup([
      #(Black, Point(1), 2),
      #(Black, Point(19), 13),
      #(White, Point(13), 15),
    ])
  let s = position(6, "single", b, Black, [4, 2])
  let s = move(s, "p2", Point(1), Point(5))
  let s = move(s, "p2", Point(19), Point(21))
  let s = apply(s, "p2", engine.Play)
  assert last_turn(s)
    == record.Turn("p2", [4, 2], ["24/20", "6/4"], state.snapshot(s), [
      5,
      21,
    ])
  // And its bar entry and bear-off read the same as White's.
  assert record.loc_text(Black, Bar) == "bar"
  assert record.loc_text(Black, Off) == "off"
  assert record.loc_text(Black, Point(22)) == "3"
}

/// One checker's two steps are one move: 6-5 run from the back is `24/13`,
/// not `24/18 18/13`.
pub fn one_checker_running_both_dice_is_one_move_test() {
  let b =
    setup([
      #(White, Point(24), 1),
      #(White, Point(13), 14),
      #(Black, Point(1), 2),
      #(Black, Point(19), 13),
    ])
  let s = position(18, "single", b, White, [6, 5])
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(18), Point(13))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 5], ["24/13"], state.snapshot(s), [13])
  assert record.text(last_turn(s)) == "65: 24/13"
}

/// Which checker of a stack the engine lifts is not the move: here the
/// step from 18 lifts the checker that was already there (the higher id),
/// and the position is the same as the one that ran, so it still reads
/// `24/13`.
pub fn chaining_does_not_depend_on_which_checker_id_moved_test() {
  let b =
    setup([
      #(White, Point(24), 1),
      #(White, Point(18), 1),
      #(White, Point(13), 13),
      #(Black, Point(1), 2),
      #(Black, Point(19), 13),
    ])
  let s = position(19, "single", b, White, [6, 5])
  let assert [runner] = board.checkers_at(s.board, White, Point(24))
  let assert [waiting] = board.checkers_at(s.board, White, Point(18))
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(18), Point(13))
  // The runner stayed on 18; the checker that was waiting there moved on.
  // The position is the same as one checker running 24/13, and that is how
  // both the notation and `landed` read it: one checker, on the 13.
  assert board.checkers_at(s.board, White, Point(18)) == [runner]
  assert list.contains(board.checkers_at(s.board, White, Point(13)), waiting)
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 5], ["24/13"], state.snapshot(s), [13])
}

/// A double that runs both back checkers all the way is `24/12(2)`.
pub fn a_double_running_both_back_checkers_is_grouped_whole_test() {
  let b =
    setup([
      #(White, Point(24), 2),
      #(White, Point(13), 13),
      #(Black, Point(1), 2),
      #(Black, Point(19), 13),
    ])
  let s = position(20, "single", b, White, [6, 6, 6, 6])
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(18), Point(12))
  let s = move(s, "p1", Point(18), Point(12))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 6], ["24/12(2)"], state.snapshot(s), [
      12,
      12,
    ])
  assert record.text(last_turn(s)) == "66: 24/12(2)"
}

/// A hit on the way keeps its point: `24/18*/13`.
pub fn a_hit_on_the_way_is_written_where_it_happened_test() {
  let b =
    setup([
      #(White, Point(24), 1),
      #(White, Point(13), 14),
      #(Black, Point(18), 1),
      #(Black, Point(1), 2),
      #(Black, Point(19), 12),
    ])
  let s = position(21, "single", b, White, [6, 5])
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(18), Point(13))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 5], ["24/18*/13"], state.snapshot(s), [13])
  assert s.board |> board.on_bar(Black) == 1
}

/// Bar entry and bearing off chain the same way: `bar/16`, `6/off`.
pub fn entering_and_running_on_is_one_move_test() {
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(13), 14),
      #(Black, Point(1), 2),
      #(Black, Point(12), 13),
    ])
  let s = position(22, "single", b, White, [3, 6])
  let s = move(s, "p1", Bar, Point(22))
  let s = move(s, "p1", Point(22), Point(16))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn("p1", [6, 3], ["bar/16"], state.snapshot(s), [16])
  let home =
    setup([#(White, Point(6), 1), #(White, Off, 14), #(Black, Point(19), 15)])
  let s = position(23, "single", home, White, [2, 4])
  let s = move(s, "p1", Point(6), Point(4))
  let s = move(s, "p1", Point(4), Off)
  let s = apply(s, "p1", engine.Play)
  let assert [_, record.Turn("p1", [4, 2], moves, _, landed), ..] = s.record
  assert moves == ["6/off"]
  // Borne off: nothing on the board to mark.
  assert landed == []
}

/// A record writes the high die first, the opening roll included: whichever
/// side threw which die, a Black opening 3-5 reads `53`.
pub fn the_high_die_is_written_first_even_on_the_opening_roll_test() {
  let assert Ok(s) =
    list.range(1, 60)
    |> list.map(fn(seed) { new_game(seed, "single") })
    |> list.find(fn(s) {
      case s.last_roll {
        [white, black] -> black > white && state.to_move(s) == Some("p2")
        _ -> False
      }
    })
  let assert [low, high] = s.last_roll
  let s = play_a_turn(s)
  let assert [record.Turn("p2", dice, _, _, _)] = s.record
  assert dice == [high, low]
}

/// The position a turn leaves includes the cube: a past board is drawn with
/// the cube as it stood, not as it stands now.
pub fn a_snapshot_keeps_the_cube_as_it_stood_test() {
  let b =
    setup([
      #(White, Point(8), 2),
      #(White, Point(6), 13),
      #(Black, Point(1), 2),
      #(Black, Point(12), 13),
    ])
  let s =
    state.GameState(
      ..position(24, "match5", b, White, [3, 1]),
      cube_value: 2,
      cube_owner: Some(Black),
    )
  let s = move(s, "p1", Point(8), Point(5))
  let s = move(s, "p1", Point(6), Point(5))
  let s = apply(s, "p1", engine.Play)
  let assert record.Turn(_, _, _, position, _) = last_turn(s)
  assert position.cube == 2
  assert position.cube_owner == Some("p2")
  // A centred cube has no owner.
  assert { record.snapshot(board.initial(), 1, None) }.cube_owner == None
}

pub fn a_dance_records_the_roll_and_no_play_test() {
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(13), 14),
      #(Black, Point(19), 2),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
      #(Black, Point(22), 2),
      #(Black, Point(23), 2),
      #(Black, Point(24), 2),
      #(Black, Point(1), 3),
    ])
  let s = position(7, "single", b, White, [6, 5])
  assert state.no_moves(s)
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s) == record.Turn("p1", [6, 5], [], state.snapshot(s), [])
  assert record.text(last_turn(s)) == "65: (no play)"
}

pub fn staging_and_undo_never_touch_the_record_test() {
  let s = new_game(9, "single")
  let assert Some(mover) = state.to_move(s)
  let before = s.record
  let assert [m, ..] = state.legal_moves(s, mover)
  let s = move(s, mover, m.from, m.to)
  assert s.record == before
  let s = apply(s, mover, engine.Undo)
  assert s.record == before
}

// ---------- The cube and the games ----------

pub fn cube_actions_and_a_drop_are_recorded_test() {
  let s = new_game(10, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White), record: [])
  let s = apply(s, "p1", engine.Double)
  assert s.record == [record.Double("p1", 2)]
  let s = apply(s, "p2", engine.Take)
  assert s.record == [record.Take("p2"), record.Double("p1", 2)]
  // Redouble and drop: the game line follows the drop.
  let s = state.GameState(..s, phase: state.Rolling(Black))
  let s = apply(s, "p2", engine.Double)
  let s = apply(s, "p1", engine.Drop)
  assert list.reverse(s.record)
    == [
      record.Double("p1", 2),
      record.Take("p2"),
      record.Double("p2", 4),
      record.Drop("p1"),
      record.GameOver(1, "p2", "dropped", 2, 2, [#("p1", 0), #("p2", 2)]),
    ]
  assert record.text(record.Double("p2", 4)) == "Doubles to 4"
  assert record.text(record.Take("p2")) == "Takes"
  assert record.text(record.Drop("p1")) == "Drops"
}

pub fn a_won_game_ends_the_game_record_with_its_kind_and_score_test() {
  let gammon =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = position(11, "match5", gammon, White, [1, 2])
  let s = move(s, "p1", Point(1), Off)
  let s = apply(s, "p1", engine.Play)
  // Both ready up, and the next game starts clean on the same record: the
  // turn that bore off, then the game line.
  let s = both_ready(s)
  let assert [record.GameOver(1, "p1", "gammon", 2, 1, scores), turn, ..] =
    s.record
  assert scores == [#("p1", 2), #("p2", 0)]
  let assert record.Turn("p1", [2, 1], ["1/off"], position, []) = turn
  // The snapshot is the board the turn left, before the next game reset it.
  assert position.white.off == 15 && position.black.off == 0
  assert s.game_number == 2
}

/// Under the Jacoby rule a gammon with a centred cube is a single game:
/// the record says so, not just the score.
pub fn a_jacoby_gammon_is_recorded_as_a_single_game_test() {
  let gammon =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = position(14, "unlimited", gammon, White, [1, 2])
  assert s.config.jacoby && s.cube_owner == option.None
  let s = move(s, "p1", Point(1), Off)
  let s = apply(s, "p1", engine.Play)
  let assert [record.GameOver(1, "p1", "single", 1, 1, _), ..] = s.record
  // Once the cube is turned the same finish is the gammon it looks like.
  let turned =
    state.GameState(
      ..position(14, "unlimited", gammon, White, [1, 2]),
      cube_value: 2,
      cube_owner: option.Some(White),
    )
  let turned = move(turned, "p1", Point(1), Off)
  let turned = apply(turned, "p1", engine.Play)
  let assert [record.GameOver(1, "p1", "gammon", 4, 2, _), ..] = turned.record
}

/// A resignation is an offer: only an accepted one is a line of the record
/// (the resigner's), followed by the game line at the stakes offered. A
/// declined offer leaves no trace; the game went on.
pub fn a_resignation_is_recorded_when_accepted_test() {
  let s = new_game(12, "match5")
  let s = state.GameState(..s, record: [])
  let declined = apply(s, "p2", engine.Resign(board.Single))
  let declined = apply(declined, "p1", engine.DeclineResign)
  assert declined.record == []
  let s = apply(declined, "p2", engine.Resign(board.Gammon))
  assert s.record == []
  let s = apply(s, "p1", engine.AcceptResign)
  assert list.reverse(s.record)
    == [
      record.Resign("p2"),
      record.GameOver(1, "p1", "resigned", 2, 1, [#("p1", 2), #("p2", 0)]),
    ]
}

// ---------- The scene ----------

pub fn the_record_reaches_both_players_and_spectators_test() {
  let s = new_game(13, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White), record: [])
  let s = apply(s, "p1", engine.Double)
  let s = apply(s, "p2", engine.Drop)
  let s = both_ready(s)
  // Game 2 has begun: its record is empty so far, and game 1 is a result
  // line. Its turns are the `/record` endpoint's, not every update's.
  assert s.game_number == 2
  let game_one =
    record.GameOver(1, "p1", "dropped", 1, 1, [#("p1", 1), #("p2", 0)])
  let s = play_a_turn(s)
  let assert [turn, ..] = s.record
  list.each([scene.Player("p1"), scene.Player("p2"), scene.Spectator], fn(v) {
    let sc = projection.build(s, v)
    assert list.key_find(sc.data, "record")
      == Ok(json.array([turn], record.to_json))
    assert list.key_find(sc.data, "games")
      == Ok(json.array([game_one], record.to_json))
  })
}

/// Once the match is over the scene keeps its last game, result and all:
/// the game-over card's review opens on it.
pub fn a_finished_match_keeps_its_last_game_in_the_scene_test() {
  let s = new_game(16, "match5")
  let s =
    state.GameState(
      ..s,
      phase: state.Rolling(White),
      record: [],
      scores: dict.from_list([#("p1", 4), #("p2", 0)]),
    )
  let s = apply(s, "p1", engine.Double)
  let s = apply(s, "p2", engine.Drop)
  let last = record.GameOver(1, "p1", "dropped", 1, 1, [#("p1", 5), #("p2", 0)])
  let sc = projection.build(s, scene.Player("p1"))
  assert list.key_find(sc.data, "record")
    == Ok(json.array(
      [record.Double("p1", 2), record.Drop("p2"), last],
      record.to_json,
    ))
  // And the whole record has exactly that one game: no empty one after it.
  assert json.to_string(projection.record_json(s))
    == json.to_string(
      json.object([
        #(
          "players",
          json.preprocessed_array([
            player_json("p1", "Alice", "white"),
            player_json("p2", "Bob", "black"),
          ]),
        ),
        #("target", json.int(5)),
        #("cube", json.bool(True)),
        #("start", opening_json()),
        #(
          "games",
          json.preprocessed_array([
            json.object([
              #("number", json.int(1)),
              #(
                "entries",
                json.array(
                  [record.Double("p1", 2), record.Drop("p2"), last],
                  record.to_json,
                ),
              ),
            ]),
          ]),
        ),
      ]),
    )
}

/// Between the games of a match, the next game has not begun: the record
/// is the games that were played, with no empty one waiting.
pub fn the_record_between_games_has_no_empty_game_test() {
  let s = new_game(17, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White), record: [])
  let s = apply(s, "p1", engine.Double)
  let s = apply(s, "p2", engine.Drop)
  let assert state.BetweenGames(_, _) = s.phase
  let assert Ok(games) =
    json.parse(
      json.to_string(projection.record_json(s)),
      decode.at(["games"], decode.list(decode.at(["number"], decode.int))),
    )
  assert games == [1]
}

/// The endpoint's record is every game, each with its entries and ending in
/// its result, then the game in progress; the contract hands it out.
pub fn the_whole_record_is_every_game_in_order_test() {
  let s = new_game(17, "match5")
  let s = state.GameState(..s, phase: state.Rolling(White), record: [])
  let s = apply(s, "p1", engine.Double)
  let s = apply(s, "p2", engine.Drop)
  let s = both_ready(s)
  let s = play_a_turn(s)
  let assert [turn, ..] = s.record
  let game_one =
    record.GameOver(1, "p1", "dropped", 1, 1, [#("p1", 1), #("p2", 0)])
  let expected =
    json.object([
      #(
        "players",
        json.preprocessed_array([
          player_json("p1", "Alice", "white"),
          player_json("p2", "Bob", "black"),
        ]),
      ),
      #("target", json.int(5)),
      #("cube", json.bool(True)),
      #("start", opening_json()),
      #(
        "games",
        json.preprocessed_array([
          json.object([
            #("number", json.int(1)),
            #(
              "entries",
              json.array(
                [record.Double("p1", 2), record.Drop("p2"), game_one],
                record.to_json,
              ),
            ),
          ]),
          json.object([
            #("number", json.int(2)),
            #("entries", json.array([turn], record.to_json)),
          ]),
        ]),
      ),
    ])
  assert json.to_string(projection.record_json(s)) == json.to_string(expected)
  let assert Some(from_contract) = { backgammon.game() }.record(s)
  assert json.to_string(from_contract) == json.to_string(expected)
}

/// Every game of the record starts from the opening position, centred cube.
fn opening_json() -> json.Json {
  record.snapshot_to_json(record.snapshot(board.initial(), 1, None))
}

pub fn the_wire_shape_is_plain_json_test() {
  let opening = record.snapshot(board.initial(), 1, None)
  assert json.to_string(
      record.to_json(
        record.Turn("p1", [3, 1], ["8/5*", "6/5"], opening, [5, 5]),
      ),
    )
    == "{\"kind\":\"turn\",\"player\":\"p1\",\"dice\":[3,1],\"moves\":[\"8/5*\",\"6/5\"],\"landed\":[5,5],\"position\":"
    <> json.to_string(record.snapshot_to_json(opening))
    <> "}"
  assert json.to_string(record.snapshot_to_json(opening))
    == "{\"white\":{\"points\":[0,0,0,0,0,5,0,3,0,0,0,0,5,0,0,0,0,0,0,0,0,0,0,2],\"bar\":0,\"off\":0,\"pips\":167},\"black\":{\"points\":[2,0,0,0,0,0,0,0,0,0,0,5,0,0,0,0,3,0,5,0,0,0,0,0],\"bar\":0,\"off\":0,\"pips\":167},\"cube\":{\"value\":1,\"owner\":null}}"
  assert json.to_string(
      record.snapshot_to_json(record.snapshot(board.initial(), 4, Some("p2"))),
    )
    |> string.ends_with(",\"cube\":{\"value\":4,\"owner\":\"p2\"}}")
  assert json.to_string(
      record.to_json(
        record.GameOver(2, "p2", "single", 2, 2, [
          #("p1", 1),
          #("p2", 2),
        ]),
      ),
    )
    == "{\"kind\":\"game_over\",\"number\":2,\"winner\":\"p2\",\"result\":\"single\",\"points\":2,\"cube\":2,\"scores\":{\"p1\":1,\"p2\":2}}"
}

// ---------- The position a turn leaves ----------

pub fn a_snapshot_counts_every_checker_where_it_stands_test() {
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(6), 4),
      #(White, Point(13), 3),
      #(White, Off, 7),
      #(Black, Point(1), 2),
      #(Black, Point(24), 1),
      #(Black, Off, 12),
    ])
  let snap = record.snapshot(b, 1, None)
  assert snap.white
    == record.Side(
      points: [
        0,
        0,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
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
      ],
      bar: 1,
      off: 7,
      pips: 25 + 4 * 6 + 3 * 13,
    )
  assert snap.black
    == record.Side(
      points: [
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
        1,
      ],
      bar: 0,
      off: 12,
      pips: 2 * 24 + 1,
    )
  assert list.length(snap.white.points) == 24
}

pub fn a_turn_records_the_board_it_left_test() {
  let s = new_game(15, "single")
  let assert Some(mover) = state.to_move(s)
  let assert [m, ..] = state.legal_moves(s, mover)
  let s = move(s, mover, m.from, m.to)
  let s = case state.legal_moves(s, mover) {
    [n, ..] -> move(s, mover, n.from, n.to)
    [] -> s
  }
  let s = apply(s, mover, engine.Play)
  let assert [record.Turn(_, _, _, position, _), ..] = s.record
  assert position == state.snapshot(s)
  assert position != record.snapshot(board.initial(), 1, None)
  // Every checker is somewhere in the snapshot.
  let total = fn(side: record.Side) {
    list.fold(side.points, 0, fn(a, n) { a + n }) + side.bar + side.off
  }
  assert total(position.white) == 15 && total(position.black) == 15
}

/// The snapshot (board and cube) rides in every turn of the game on the
/// board, in every update, so it has to stay small: a hundred turns -- a
/// long game and then some -- cost under 36 KB of JSON. Earlier games are
/// not in the scene at all (`a_finished_match_keeps_its_last_game...`).
pub fn a_hundred_turns_of_record_stay_small_test() {
  // Random play against the cube drops early, so pool the turns of a few
  // single games until there are a hundred of them.
  let turns =
    list.flat_map(list.range(31, 40), fn(seed) {
      let assert Ok(report) =
        conformance.random_playout_with(
          backgammon.game(),
          "single",
          positions.seats(),
          seed,
          4000,
          fn(_) { Ok(Nil) },
          conformance.Options(exclude: ["resign"]),
        )
      list.filter(report.state.record, fn(e) {
        case e {
          record.Turn(..) -> True
          _ -> False
        }
      })
    })
  let hundred = list.take(turns, 100)
  assert list.length(hundred) == 100
  let bytes =
    json.to_string(json.array(hundred, record.to_json)) |> string.byte_size
  echo #("record bytes for 100 turns", bytes)
  assert bytes < 36_000
}

// ---------- Replay ----------

/// A room rebuilt from its log goes through the same `apply`, so its record
/// is the live one, entry for entry.
pub fn a_replayed_match_carries_the_same_record_test() {
  let assert Ok(report) =
    conformance.random_playout_with(
      backgammon.game(),
      "match3",
      positions.seats(),
      21,
      30_000,
      fn(_) { Ok(Nil) },
      conformance.Options(exclude: ["resign"]),
    )
  assert report.finished
  let assert Ok(replayed) =
    conformance.replay(
      backgammon.game(),
      "match3",
      positions.seats(),
      21,
      report.steps,
    )
  assert replayed.record == report.state.record
  // A finished match has at least one game line, and the last line is it.
  let assert [record.GameOver(..), ..] = report.state.record
  // Every turn's dice are the two that were rolled.
  list.each(report.state.record, fn(e) {
    case e {
      record.Turn(_, dice, _, _, _) -> {
        assert list.length(dice) == 2
      }
      _ -> Nil
    }
  })
}

fn setup(entries) {
  positions.setup(entries)
}

/// Between the games of a match: both players press READY, and the next
/// game starts.
fn both_ready(s: state.GameState) -> state.GameState {
  let s = apply(s, "p1", engine.Ready)
  apply(s, "p2", engine.Ready)
}

/// Play the mover's whole turn with the first legal move each time, and
/// commit it (a dance commits straight away).
fn play_a_turn(s: state.GameState) -> state.GameState {
  let s = case s.phase {
    state.Rolling(_) -> {
      let assert Some(id) = state.to_act(s)
      apply(s, id, engine.Roll)
    }
    _ -> s
  }
  let assert Some(mover) = state.to_move(s)
  stage_all(s, mover)
}

fn stage_all(s: state.GameState, mover: String) -> state.GameState {
  case state.legal_moves(s, mover) {
    [m, ..] -> stage_all(move(s, mover, m.from, m.to), mover)
    [] -> apply(s, mover, engine.Play)
  }
}

fn player_json(id: String, name: String, color: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("color", json.string(color)),
  ])
}
