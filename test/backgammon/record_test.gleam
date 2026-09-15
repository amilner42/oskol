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
import gleam/json
import gleam/list
import gleam/option.{Some}
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
    == record.Turn(
      "p1",
      [3, 1],
      False,
      ["8/5*", "6/5"],
      record.snapshot(s.board),
    )
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
    == record.Turn(
      "p1",
      [3, 5],
      False,
      ["bar/22", "13/8"],
      record.snapshot(s.board),
    )
}

pub fn bearing_off_reads_point_slash_off_test() {
  let b =
    setup([#(White, Point(6), 2), #(White, Off, 13), #(Black, Point(19), 15)])
  let s = position(3, "single", b, White, [6, 4])
  let s = move(s, "p1", Point(6), Off)
  let s = move(s, "p1", Point(6), Point(2))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn(
      "p1",
      [6, 4],
      False,
      ["6/off", "6/2"],
      record.snapshot(s.board),
    )
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
    == record.Turn(
      "p1",
      [3, 3],
      False,
      ["8/5(2)", "6/3(2)"],
      record.snapshot(s.board),
    )
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
  assert last_turn(s)
    == record.Turn(
      "p1",
      [3, 3],
      False,
      ["8/5*(3)", "5/2"],
      record.snapshot(s.board),
    )
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
    == record.Turn(
      "p2",
      [4, 2],
      False,
      ["24/20", "6/4"],
      record.snapshot(s.board),
    )
  // And its bar entry and bear-off read the same as White's.
  assert record.loc_text(Black, Bar) == "bar"
  assert record.loc_text(Black, Off) == "off"
  assert record.loc_text(Black, Point(22)) == "3"
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
  assert last_turn(s)
    == record.Turn("p1", [6, 5], False, [], record.snapshot(s.board))
  assert record.text(last_turn(s)) == "65: (no play)"
}

pub fn a_picked_roll_is_marked_test() {
  let s = new_game(8, "single")
  let s =
    state.GameState(
      ..s,
      phase: state.Rolling(White),
      config: state.Config(..s.config, pick_dice: True),
      record: [],
    )
  let s = apply(s, "p1", engine.Pick(6, 5))
  let s = move(s, "p1", Point(24), Point(18))
  let s = move(s, "p1", Point(18), Point(13))
  let s = apply(s, "p1", engine.Play)
  assert last_turn(s)
    == record.Turn(
      "p1",
      [6, 5],
      True,
      ["24/18", "18/13"],
      record.snapshot(s.board),
    )
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
  // The turn that bore off, then the game line; the next game starts clean
  // on the same record.
  let assert [record.GameOver(1, "p1", "gammon", 2, 1, scores), turn, ..] =
    s.record
  assert scores == [#("p1", 2), #("p2", 0)]
  let assert record.Turn("p1", [1, 2], False, ["1/off"], position) = turn
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
  let expected =
    json.array(
      [
        record.Double("p1", 2),
        record.Drop("p2"),
        record.GameOver(1, "p1", "dropped", 1, 1, [#("p1", 1), #("p2", 0)]),
      ],
      record.to_json,
    )
  let games =
    json.array(
      [record.GameOver(1, "p1", "dropped", 1, 1, [#("p1", 1), #("p2", 0)])],
      record.to_json,
    )
  list.each([scene.Player("p1"), scene.Player("p2"), scene.Spectator], fn(v) {
    let sc = projection.build(s, v)
    assert list.key_find(sc.data, "record") == Ok(expected)
    assert list.key_find(sc.data, "games") == Ok(games)
  })
}

pub fn the_wire_shape_is_plain_json_test() {
  let opening = record.snapshot(board.initial())
  assert json.to_string(
      record.to_json(record.Turn("p1", [3, 1], False, ["8/5*", "6/5"], opening)),
    )
    == "{\"kind\":\"turn\",\"player\":\"p1\",\"dice\":[3,1],\"picked\":false,\"moves\":[\"8/5*\",\"6/5\"],\"position\":"
    <> json.to_string(record.snapshot_to_json(opening))
    <> "}"
  assert json.to_string(record.snapshot_to_json(opening))
    == "{\"white\":{\"points\":[0,0,0,0,0,5,0,3,0,0,0,0,5,0,0,0,0,0,0,0,0,0,0,2],\"bar\":0,\"off\":0,\"pips\":167},\"black\":{\"points\":[2,0,0,0,0,0,0,0,0,0,0,5,0,0,0,0,3,0,5,0,0,0,0,0],\"bar\":0,\"off\":0,\"pips\":167}}"
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
  let snap = record.snapshot(b)
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
  let assert [record.Turn(_, _, _, _, position), ..] = s.record
  assert position == record.snapshot(s.board)
  assert position != record.snapshot(board.initial())
  // Every checker is somewhere in the snapshot.
  let total = fn(side: record.Side) {
    list.fold(side.points, 0, fn(a, n) { a + n }) + side.bar + side.off
  }
  assert total(position.white) == 15 && total(position.black) == 15
}

/// The snapshot rides in every turn of every scene, so it has to stay
/// small: a hundred turns of record cost well under 32 KB of JSON.
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
  assert bytes < 32_000
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
