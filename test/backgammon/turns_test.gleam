//// Staged turns: moves are private until played, can be undone, and a turn
//// can only be played once every usable die is used.

import backgammon/board.{Bar, Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
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

fn position(seed: Int, b: board.Board, dice: List(Int)) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), "single")
  let assert Ok(s) = backgammon.init(f.config, seats(), rng.seed(seed))
  state.GameState(
    ..s,
    board: b,
    turn_board: b,
    staged: [],
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

fn names(s: state.GameState, id: String) -> List(String) {
  list.map(engine.legal(s, id), fn(schema) { schema.name })
}

fn white_at(sc: scene.Scene, point: Int) -> Int {
  scene.zone_token_ids(sc, "point:" <> int.to_string(point)) |> list.length
}

fn open_board() -> board.Board {
  setup([#(White, Point(13), 2), #(White, Point(8), 1), #(Black, Point(1), 2)])
}

pub fn staged_moves_are_private_until_played_test() {
  let s = position(1, open_board(), [5, 3])
  let #(s, events) = apply(s, "p1", engine.MoveChecker(Point(13), Point(8)))
  // The mover sees the move; the opponent and a spectator see the turn's start
  let mine = backgammon.game().scene(s, scene.Player("p1"))
  let theirs = backgammon.game().scene(s, scene.Player("p2"))
  let watching = backgammon.game().scene(s, scene.Spectator)
  assert white_at(mine, 13) == 1 && white_at(mine, 8) == 2
  assert white_at(theirs, 13) == 2 && white_at(theirs, 8) == 1
  assert white_at(watching, 13) == 2
  // The opponent's dice show nothing used yet; the mover's show one die used
  let used = fn(sc: scene.Scene) {
    let assert Ok(z) = scene.find_zone(sc, "dice")
    list.filter(z.tokens, fn(t) {
      list.key_find(t.props, "used") == Ok(json.bool(True))
    })
    |> list.length
  }
  assert used(mine) == 1 && used(theirs) == 0
  // Staging events say nothing about the move itself
  assert events
    == [
      event.Custom(
        "move_staged",
        json.object([
          #("player_id", json.string("p1")),
          #("dice_left", json.int(1)),
        ]),
      ),
    ]
  // Pips in the opponent's view are the turn-start pips
  let assert [me_theirs, _] = theirs.players
  let assert [me_mine, _] = mine.players
  assert dict.get(me_theirs.counters, "pips")
    != dict.get(me_mine.counters, "pips")
}

pub fn undo_restores_the_board_and_the_die_test() {
  let s = position(2, open_board(), [5, 3])
  assert names(s, "p1") |> list.contains("undo") == False
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(13), Point(8)))
  assert state.dice_left(s) == [3]
  assert names(s, "p1") |> list.contains("undo")
  let #(s, events) = apply(s, "p1", engine.Undo)
  assert events
    == [
      event.Custom(
        "move_undone",
        json.object([#("player_id", json.string("p1"))]),
      ),
    ]
  assert state.dice_left(s) == [5, 3]
  assert s.board == open_board()
  assert s.staged == []
  assert engine.apply(s, "p1", engine.Undo) == Error("Nothing to undo")
  assert engine.apply(s, "p2", engine.Undo) == Error("Nothing to undo")
}

pub fn undo_returns_a_hit_checker_to_its_point_test() {
  let b =
    setup([
      #(White, Point(8), 1),
      #(White, Point(24), 2),
      #(Black, Point(5), 1),
      #(Black, Point(12), 5),
    ])
  let s = position(3, b, [3, 1])
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(8), Point(5)))
  assert board.on_bar(s.board, Black) == 1
  let #(s, _) = apply(s, "p1", engine.Undo)
  assert board.on_bar(s.board, Black) == 0
  assert board.count(s.board, Black, Point(5)) == 1
  assert board.count(s.board, White, Point(8)) == 1
}

pub fn play_needs_every_usable_die_test() {
  let s = position(4, open_board(), [5, 3])
  assert engine.apply(s, "p1", engine.Play)
    == Error("You still have moves to play")
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(13), Point(8)))
  assert engine.apply(s, "p1", engine.Play)
    == Error("You still have moves to play")
  assert names(s, "p1") |> list.contains("play") == False
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(8), Point(5)))
  assert names(s, "p1") |> list.contains("play")
  assert engine.apply(s, "p2", engine.Play) == Error("Not your turn")
  let #(s, events) = apply(s, "p1", engine.Play)
  let assert state.Rolling(Black) = s.phase
  assert s.staged == [] && s.turn_board == s.board
  // The played turn is announced move by move for the opponent's animation
  let moved =
    list.filter(events, fn(e) {
      case e {
        event.TokenMoved(_, _, _) -> True
        _ -> False
      }
    })
  assert list.length(moved) == 2
  assert list.any(events, fn(e) {
    case e {
      event.Custom("turn_played", _) -> True
      _ -> False
    }
  })
  // Now the opponent sees the result
  let theirs = backgammon.game().scene(s, scene.Player("p2"))
  assert white_at(theirs, 13) == 1 && white_at(theirs, 5) == 1
}

pub fn a_turn_with_one_playable_die_can_be_played_after_it_test() {
  // The 5 is blocked everywhere, so only 13 -> 10 plays; after it the turn is complete.
  let b =
    setup([
      #(White, Point(13), 1),
      #(Black, Point(8), 2),
      #(Black, Point(5), 2),
      #(Black, Point(1), 2),
    ])
  let s = position(5, b, [5, 3])
  assert names(s, "p1") |> list.filter(fn(n) { n == "move" }) |> list.length
    == 1
  assert engine.apply(s, "p1", engine.Play)
    == Error("You still have moves to play")
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(13), Point(10)))
  assert state.dice_left(s) == [5]
  assert state.can_play(s, "p1")
  let #(s, _) = apply(s, "p1", engine.Play)
  let assert state.Rolling(Black) = s.phase
}

pub fn a_new_turn_starts_with_nothing_staged_test() {
  let s = position(6, open_board(), [5, 3])
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(13), Point(8)))
  let #(s, _) = apply(s, "p1", engine.MoveChecker(Point(8), Point(5)))
  let #(s, _) = apply(s, "p1", engine.Play)
  let #(s, _) = apply(s, "p2", engine.Roll)
  assert s.staged == []
  assert s.turn_board == s.board
  assert state.can_undo(s, "p2") == False
  let _ = Bar
  let _ = Off
  let _ = None
  let _ = Some(1)
  Nil
}
