//// Backgammon rules that need controlled positions.

import backgammon/board.{Bar, Black, Move, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/action
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
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

fn moves(
  b: board.Board,
  color: board.Color,
  dice: List(Int),
) -> List(#(String, String)) {
  board.legal_moves(b, color, dice)
  |> list.map(fn(m) { #(board.loc_id(m.from), board.loc_id(m.to)) })
  |> list.sort(fn(x, y) { string.compare(x.0 <> x.1, y.0 <> y.1) })
}

fn new_game(seed: Int, format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) = backgammon.init(f.config, seats(), rng.seed(seed))
  s
}

/// A game in a chosen position with White (p1) to play the given dice.
fn position(
  seed: Int,
  format: String,
  b: board.Board,
  dice: List(Int),
) -> state.GameState {
  let s = new_game(seed, format)
  state.GameState(
    ..s,
    board: b,
    phase: state.Moving(White, dice),
    last_roll: list.take(dice, 2),
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

fn has_custom(events: List(event.Event), kind: String) -> Bool {
  list.any(events, fn(e) {
    case e {
      event.Custom(k, _) -> k == kind
      _ -> False
    }
  })
}

// ---------- Board rules ----------

pub fn dice_order_matters_when_only_one_order_uses_both_test() {
  // 8 -> 4 -> 2 works; 8 -> 6 is blocked, so the 4 must be played first.
  let b =
    setup([
      #(White, Point(8), 1),
      #(White, Point(20), 1),
      #(Black, Point(6), 2),
      #(Black, Point(16), 2),
      #(Black, Point(18), 2),
    ])
  assert moves(b, White, [4, 2]) == [#("8", "4")]
}

pub fn larger_die_when_either_die_plays_alone_but_not_both_test() {
  let b =
    setup([
      #(White, Point(9), 1),
      #(White, Point(24), 1),
      #(Black, Point(6), 2),
      #(Black, Point(15), 2),
      #(Black, Point(3), 2),
    ])
  // 24->18 (6) or 24->21 (3) alone; neither continues. Must take the 6.
  assert moves(b, White, [6, 3]) == [#("24", "18")]
}

pub fn every_bar_checker_enters_before_anything_else_moves_test() {
  let b =
    setup([#(White, Bar, 2), #(White, Point(13), 3), #(Black, Point(1), 2)])
  assert moves(b, White, [3, 3, 3, 3]) == [#("bar", "22")]
  let seqs = board.sequences(b, White, [3, 3, 3, 3])
  assert seqs != []
  assert list.all(seqs, fn(seq) {
    case seq {
      [Move(Bar, Point(22), 3), Move(Bar, Point(22), 3), ..] -> True
      _ -> False
    }
  })
}

pub fn entering_on_a_blot_hits_it_test() {
  let b =
    setup([#(White, Bar, 1), #(Black, Point(22), 1), #(Black, Point(1), 2)])
  let #(after, mover, hit) = board.apply_move(b, White, Move(Bar, Point(22), 3))
  assert mover == "w1"
  assert hit == Some("b1")
  assert board.on_bar(after, Black) == 1
  assert board.on_bar(after, White) == 0
  assert board.count(after, White, Point(22)) == 1
}

pub fn doubles_bear_off_four_checkers_test() {
  let b =
    setup([
      #(White, Point(2), 4),
      #(White, Point(1), 1),
      #(Black, Point(20), 15),
    ])
  let seqs = board.sequences(b, White, [2, 2, 2, 2])
  assert list.all(seqs, fn(seq) { list.length(seq) == 4 })
  let assert [first, ..] = seqs
  let final =
    list.fold(first, b, fn(acc, m) {
      let #(next, _, _) = board.apply_move(acc, White, m)
      next
    })
  assert board.borne_off(final, White) == 4
}

pub fn a_lower_point_cannot_bear_off_with_a_larger_die_while_a_higher_point_is_occupied_test() {
  let b =
    setup([
      #(White, Point(5), 1),
      #(White, Point(2), 1),
      #(Black, Point(20), 15),
    ])
  // Die 3: 5 -> 2 is the only move; the checker on 2 must wait.
  assert moves(b, White, [3, 3, 3, 3]) == [#("5", "2")]
}

pub fn the_highest_id_checker_on_a_point_moves_test() {
  let b = setup([#(White, Point(13), 3), #(Black, Point(1), 2)])
  let #(after, mover, _) =
    board.apply_move(b, White, Move(Point(13), Point(9), 4))
  assert mover == "w3"
  assert board.checkers_at(after, White, Point(13)) == ["w1", "w2"]
  assert board.checkers_at(after, White, Point(9)) == ["w3"]
}

pub fn pip_count_tracks_moves_and_the_bar_test() {
  let b =
    setup([#(White, Point(13), 1), #(White, Bar, 1), #(Black, Point(24), 1)])
  assert board.pip_count(b, White) == 13 + 25
  assert board.pip_count(b, Black) == 1
  let #(after, _, _) = board.apply_move(b, White, Move(Bar, Point(20), 5))
  assert board.pip_count(after, White) == 13 + 20
}

pub fn partially_blocked_doubles_only_allow_what_fits_test() {
  let b =
    setup([#(White, Point(13), 1), #(Black, Point(5), 2), #(Black, Point(1), 2)])
  // 13 -> 9 with a 4, then 9 -> 5 is blocked: exactly one move
  let seqs = board.sequences(b, White, [4, 4, 4, 4])
  assert list.map(seqs, list.length) == [1]
}

pub fn black_moves_the_other_way_test() {
  let b = setup([#(Black, Point(12), 1), #(White, Point(24), 2)])
  assert moves(b, Black, [3, 1]) |> list.contains(#("12", "15"))
  assert moves(b, Black, [3, 1]) |> list.contains(#("12", "13"))
  assert board.entry_point(Black, 4) == 4
  assert board.is_home(Black, 22) && board.is_home(Black, 18) == False
}

// ---------- Engine flow ----------

pub fn doubles_grant_four_moves_in_one_turn_test() {
  let b =
    setup([
      #(White, Point(13), 5),
      #(White, Point(24), 2),
      #(Black, Point(1), 2),
    ])
  let s = position(1, "single", b, [3, 3, 3, 3])
  let s =
    list.fold(list.range(1, 3), s, fn(acc, _) {
      let assert [m, ..] = state.legal_moves(acc, "p1")
      let #(next, _) = apply(acc, "p1", engine.MoveChecker(m.from, m.to))
      assert state.to_move(next) == Some("p1")
      next
    })
  assert state.dice_left(s) == [3]
  let assert [m, ..] = state.legal_moves(s, "p1")
  let #(s, events) = apply(s, "p1", engine.MoveChecker(m.from, m.to))
  assert state.to_move(s) == Some("p2")
  assert has_custom(events, "turn_started")
}

pub fn a_roll_with_no_legal_move_passes_the_turn_test() {
  // White is on the bar against a closed board.
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
  let s = new_game(2, "single")
  let s = state.GameState(..s, board: b, phase: state.Rolling(White))
  assert list.first(engine.legal(s, "p1")) == Ok(engine_roll())
  let #(s, events) = apply(s, "p1", engine.Roll)
  assert has_custom(events, "dice_rolled")
  assert has_custom(events, "no_moves")
  let assert state.Rolling(Black) = s.phase
  assert state.to_move(s) == Some("p2")
  assert list.first(engine.legal(s, "p2")) == Ok(engine_roll())
}

fn engine_roll() {
  action.simple("roll", "Roll dice")
}

pub fn hitting_puts_the_opponent_on_the_bar_and_they_must_enter_test() {
  let b =
    setup([
      #(White, Point(8), 1),
      #(White, Point(24), 2),
      #(Black, Point(5), 1),
      #(Black, Point(12), 5),
    ])
  let s = position(3, "single", b, [3, 1])
  let #(s, events) = apply(s, "p1", engine.MoveChecker(Point(8), Point(5)))
  assert has_custom(events, "hit")
  assert board.on_bar(s.board, Black) == 1
  assert list.any(events, fn(e) { e == event.moved("b1", "point:5", "bar:p2") })
  // Finish White's turn, then Black rolls and may only enter from the bar
  let assert [m, ..] = state.legal_moves(s, "p1")
  let #(s, _) = apply(s, "p1", engine.MoveChecker(m.from, m.to))
  let #(s, _) = apply(s, "p2", engine.Roll)
  case s.phase {
    state.Moving(Black, _) -> {
      assert list.all(state.legal_moves(s, "p2"), fn(m) { m.from == Bar })
    }
    _ -> Nil
  }
}

pub fn bearing_off_the_last_checker_wins_with_the_right_kind_test() {
  let gammon =
    setup([#(White, Off, 14), #(White, Point(1), 1), #(Black, Point(19), 15)])
  let s = position(4, "single", gammon, [1, 2])
  let #(s, events) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  assert has_custom(events, "game_won")
  assert has_custom(events, "match_over")
  let assert state.Finished(White) = s.phase
  assert backgammon.outcome(s) == game.Finished(["p1"])
  assert state.score_of(s, "p1") == 2
  assert engine.legal(s, "p1") == [] && engine.legal(s, "p2") == []
  assert engine.on_the_clock(s) == []
  let assert Error("The match is over") = engine.apply(s, "p2", engine.Roll)
}

pub fn match_play_continues_with_a_fresh_board_until_the_target_test() {
  let backgammon_position =
    setup([
      #(White, Off, 14),
      #(White, Point(1), 1),
      #(Black, Bar, 1),
      #(Black, Point(19), 14),
    ])
  let s = position(5, "match5", backgammon_position, [1, 2])
  let #(s, events) = apply(s, "p1", engine.MoveChecker(Point(1), Off))
  assert has_custom(events, "game_won") && has_custom(events, "new_game")
  assert has_custom(events, "match_over") == False
  assert state.score_of(s, "p1") == 3
  assert s.game_number == 2
  assert dict.size(s.board.checkers) == 30
  assert board.count(s.board, White, Point(24)) == 2
    && board.count(s.board, Black, Point(19)) == 5
  let assert state.Moving(_, _) = s.phase
  // Two more gammons take the match
  let again = fn(st: state.GameState) {
    let st =
      state.GameState(
        ..st,
        board: setup([
          #(White, Off, 14),
          #(White, Point(1), 1),
          #(Black, Point(19), 15),
        ]),
        phase: state.Moving(White, [1, 2]),
      )
    let #(next, _) = apply(st, "p1", engine.MoveChecker(Point(1), Off))
    next
  }
  let s = again(s)
  assert state.score_of(s, "p1") == 5
  let assert state.Finished(White) = s.phase
}

pub fn dice_tokens_show_what_has_been_used_test() {
  let b =
    setup([
      #(White, Point(13), 5),
      #(White, Point(24), 2),
      #(Black, Point(1), 2),
    ])
  let s = position(6, "single", b, [5, 5, 5, 5])
  let assert [m, ..] = state.legal_moves(s, "p1")
  let #(s, _) = apply(s, "p1", engine.MoveChecker(m.from, m.to))
  let sc = backgammon.game().scene(s, scene.Player("p1"))
  let assert Ok(dice) = scene.find_zone(sc, "dice")
  let used =
    list.map(dice.tokens, fn(t) {
      list.key_find(t.props, "used") == Ok(json.bool(True))
    })
  assert list.length(dice.tokens) == 4
  assert list.filter(used, fn(u) { u }) |> list.length == 1
  let assert Ok(off) = scene.find_zone(sc, "off:p1")
  assert off.tokens == []
  let assert Ok(me) = scene.find_zone(sc, "point:24")
  assert list.length(me.tokens) == 2
}

pub fn every_move_lowers_the_movers_pips_by_the_die_or_the_distance_test() {
  // Drive a game with random legal choices and check the pip arithmetic each move.
  list.each([21, 22, 23], fn(seed) {
    let s = new_game(seed, "single")
    let _ = walk(s, rng.seed(seed), 600)
    Nil
  })
}

fn walk(s: state.GameState, chooser: rng.Rng, steps: Int) -> state.GameState {
  case steps, s.phase {
    0, _ -> s
    _, state.Finished(_) -> s
    _, state.Doubled(_) -> s
    _, state.Rolling(c) -> {
      let #(next, _) = apply(s, state.player_of(s, c), engine.Roll)
      walk(next, chooser, steps - 1)
    }
    _, state.Moving(c, _) -> {
      let id = state.player_of(s, c)
      let legal = state.legal_moves(s, id)
      let assert Ok(#(m, chooser)) = rng.pick(chooser, legal)
      let before = board.pip_count(s.board, c)
      let #(next, _) = apply(s, id, engine.MoveChecker(m.from, m.to))
      let after = case next.game_number == s.game_number {
        True -> board.pip_count(next.board, c)
        False -> before - expected_drop(c, m)
      }
      assert before - after == expected_drop(c, m)
      walk(next, chooser, steps - 1)
    }
  }
}

fn expected_drop(c: board.Color, m: board.Move) -> Int {
  case m.from, m.to {
    Point(p), Off -> board.pip_distance(c, p)
    _, _ -> m.die
  }
}

pub fn unknown_or_malformed_actions_are_rejected_test() {
  let s = new_game(7, "single")
  let _ = s
  let assert Error("Unknown action: dance") =
    backgammon.decode_action(action.Incoming("dance", dynamic.nil()))
  let assert Error(_) =
    backgammon.decode_action(action.Incoming("move", dynamic.nil()))
}

pub fn black_bears_off_and_wins_a_gammon_too_test() {
  let b =
    setup([#(Black, Off, 14), #(Black, Point(24), 1), #(White, Point(6), 15)])
  let s = new_game(8, "single")
  let s = state.GameState(..s, board: b, phase: state.Moving(Black, [1, 2]))
  assert list.contains(moves(b, Black, [1, 2]), #("24", "off"))
  let #(s, events) = apply(s, "p2", engine.MoveChecker(Point(24), Off))
  assert has_custom(events, "game_won")
  let assert state.Finished(Black) = s.phase
  assert state.score_of(s, "p2") == 2
  assert backgammon.outcome(s) == game.Finished(["p2"])
}

pub fn black_enters_from_the_bar_on_the_low_points_test() {
  let b =
    setup([
      #(Black, Bar, 1),
      #(Black, Point(12), 5),
      #(White, Point(3), 2),
      #(White, Point(24), 2),
    ])
  assert moves(b, Black, [3, 5]) == [#("bar", "5")]
}
