import backgammon/board.{Point}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/state
import gamekit/conformance
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gleam/dict
import gleam/list
import gleam/option.{Some}

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

fn new_game(seed: Int, format: String) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), format)
  let assert Ok(s) = backgammon.init(f.config, seats(), rng.seed(seed))
  s
}

pub fn opening_roll_decides_who_moves_first_test() {
  let s = new_game(1, "single")
  let assert state.Moving(color, dice) = s.phase
  assert list.length(dice) == 2
  let assert [a, b] = s.last_roll
  assert a != b
  assert dict.get(s.colors, "p1") == Ok(board.White)
  assert state.to_move(s) == Some(state.player_of(s, color))
  // The mover has move schemas, the other player nothing
  let mover = state.player_of(s, color)
  let other = case mover {
    "p1" -> "p2"
    _ -> "p1"
  }
  assert list.any(engine.legal(s, mover), fn(schema) { schema.name == "move" })
  // The waiting player can only resign
  assert list.map(engine.legal(s, other), fn(schema) { schema.name })
    == ["resign"]
  assert engine.on_the_clock(s) == [mover]
}

pub fn rolling_out_of_turn_is_rejected_test() {
  let s = new_game(2, "single")
  let assert Some(mover) = state.to_move(s)
  assert engine.apply(s, mover, engine.Roll) == Error("Dice already rolled")
  let assert Error(_) = engine.apply(s, "ghost", engine.Roll)
}

pub fn moving_uses_a_die_and_eventually_passes_the_turn_test() {
  let s = new_game(3, "single")
  let assert Some(mover) = state.to_move(s)
  let assert [first, ..] = state.legal_moves(s, mover)
  let assert Ok(#(s2, events)) =
    engine.apply(s, mover, engine.MoveChecker(first.from, first.to))
  // Staging is private: no token movement is announced yet
  assert list.any(events, fn(e) {
    case e {
      event.Custom("move_staged", _) -> True
      _ -> False
    }
  })
  assert list.length(state.dice_left(s2)) == 1
  assert state.to_move(s2) == Some(mover)
  let assert [second, ..] = state.legal_moves(s2, mover)
  let assert Ok(#(s3, _)) =
    engine.apply(s2, mover, engine.MoveChecker(second.from, second.to))
  // Both dice used, but the turn is still the mover's until they play
  assert state.to_move(s3) == Some(mover)
  assert state.can_play(s3, mover)
  let assert Ok(#(s4, events4)) = engine.apply(s3, mover, engine.Play)
  assert state.to_move(s4) != Some(mover)
  let assert state.Rolling(_) = s4.phase
  assert list.any(events4, fn(e) {
    case e {
      event.Custom("turn_started", _) -> True
      _ -> False
    }
  })
}

pub fn illegal_moves_are_rejected_test() {
  let s = new_game(4, "single")
  let assert Some(mover) = state.to_move(s)
  assert engine.apply(s, mover, engine.MoveChecker(Point(3), Point(2)))
    == Error("Illegal move")
  let other = case mover {
    "p1" -> "p2"
    _ -> "p1"
  }
  let assert [m, ..] = state.legal_moves(s, mover)
  assert engine.apply(s, other, engine.MoveChecker(m.from, m.to))
    == Error("Not your turn")
}

fn invariant(s: state.GameState) -> Result(Nil, String) {
  let whites =
    dict.filter(s.board.checkers, fn(_, v) { v.0 == board.White }) |> dict.size
  let blacks =
    dict.filter(s.board.checkers, fn(_, v) { v.0 == board.Black }) |> dict.size
  let mixed =
    list.range(1, 24)
    |> list.any(fn(p) {
      board.count(s.board, board.White, Point(p)) > 0
      && board.count(s.board, board.Black, Point(p)) > 0
    })
  case whites == 15, blacks == 15, mixed {
    True, True, False -> Ok(Nil)
    False, _, _ -> Error("white checker count changed")
    _, False, _ -> Error("black checker count changed")
    _, _, True -> Error("a point holds both colors")
  }
}

pub fn random_single_games_terminate_test() {
  list.each(list.range(1, 12), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        backgammon.game(),
        "single",
        seats(),
        seed,
        4000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
    let assert state.Finished(_) = report.state.phase
  })
}

pub fn random_matches_terminate_and_score_test() {
  list.each([50, 51, 52], fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        backgammon.game(),
        "match5",
        seats(),
        seed,
        30_000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
    let assert state.Finished(winner) = report.state.phase
    assert state.score_of(report.state, state.player_of(report.state, winner))
      >= 5
  })
}

pub fn replay_is_deterministic_test() {
  let assert Ok(report) =
    conformance.random_playout(
      backgammon.game(),
      "single",
      seats(),
      9,
      4000,
      invariant,
    )
  let assert Ok(replayed) =
    conformance.replay(backgammon.game(), "single", seats(), 9, report.steps)
  assert conformance.fingerprint(backgammon.game(), replayed, seats())
    == conformance.fingerprint(backgammon.game(), report.state, seats())
}
