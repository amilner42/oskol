import backgammon/board.{Point}
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

pub fn the_opening_roll_gives_the_first_turn_to_the_higher_die_test() {
  // The higher raw roller plays first. State keeps white/black roll order for
  // replay compatibility; projection ordering is covered separately below.
  list.each(list.range(1, 40), fn(seed) {
    let s = new_game(seed, "single")
    let assert state.Moving(color, dice) = s.phase
    let #(white_die, black_die) = first_opening_pair(rng.seed(seed))
    assert s.last_roll == [white_die, black_die]
    assert dice == [white_die, black_die]
    assert color
      == case white_die > black_die {
        True -> board.White
        False -> board.Black
      }
    assert s.staged == [] && s.turn_board == s.board
  })
  let firsts =
    list.map(list.range(1, 40), fn(seed) {
      let assert state.Moving(color, _) = new_game(seed, "single").phase
      color
    })
  assert list.contains(firsts, board.White)
  assert list.contains(firsts, board.Black)
}

fn first_opening_pair(random: rng.Rng) -> #(Int, Int) {
  let #(a, random) = rng.int(random, 6)
  let #(b, random) = rng.int(random, 6)
  case a == b {
    True -> first_opening_pair(random)
    False -> #(a + 1, b + 1)
  }
}

pub fn every_plain_roll_is_projected_high_die_first_test() {
  let rolls =
    list.map(list.range(1, 300), fn(seed) {
      let opened = new_game(seed, "single")
      let rolling = state.GameState(..opened, phase: state.Rolling(board.White))
      let assert Ok(#(next, events)) = engine.apply(rolling, "p1", engine.Roll)
      let assert [a, b] = next.last_roll
      let high = int.max(a, b)
      let low = int.min(a, b)
      let all = case a == b {
        True -> [a, a, a, a]
        False -> [high, low]
      }
      let projected = backgammon.game().scene(next, scene.Player("p1"))
      let assert Ok(zone) = scene.find_zone(projected, engine.dice_zone)
      let values = projected_dice(zone)
      assert high >= low
      assert values == list.map(all, json.int)
      assert list.key_find(projected.data, "dice")
        == Ok(json.array(all, json.int))
      assert list.key_find(projected.data, "last_roll")
        == Ok(json.array([high, low], json.int))
      assert list.contains(
        events,
        event.Custom(
          "dice_rolled",
          json.object([
            #("player_id", json.string("p1")),
            #("dice", json.array([high, low], json.int)),
          ]),
        ),
      )
      [high, low]
    })
  // The concrete product example is covered rather than only the invariant.
  assert list.contains(rolls, [6, 2])
}

pub fn a_finished_position_keeps_every_projected_die_high_first_test() {
  let s =
    state.GameState(
      ..new_game(1, "single"),
      phase: state.Finished(board.White),
      last_roll: [2, 6],
    )
  let projected = backgammon.game().scene(s, scene.Spectator)
  let assert Ok(zone) = scene.find_zone(projected, engine.dice_zone)
  let ordered = json.array([6, 2], json.int)
  assert projected_dice(zone) == [json.int(6), json.int(2)]
  // Non-moving phases have no dice left, but the public last roll and the
  // dice left on the finished board retain the same canonical order.
  assert list.key_find(projected.data, "dice") == Ok(json.array([], json.int))
  assert list.key_find(projected.data, "last_roll") == Ok(ordered)
}

fn projected_dice(zone: scene.Zone) -> List(json.Json) {
  list.map(zone.tokens, fn(token) {
    let assert Ok(value) = list.key_find(token.props, "value")
    value
  })
}

pub fn tied_opening_rolls_are_rerolled_test() {
  // Seeds whose first two die draws tie must still open with distinct dice:
  // the tie was rerolled.
  let tied =
    list.filter(list.range(1, 300), fn(seed) {
      let r = rng.seed(seed)
      let #(a, r) = rng.int(r, 6)
      let #(b, _) = rng.int(r, 6)
      a == b
    })
  assert tied != []
  list.each(tied, fn(seed) {
    let s = new_game(seed, "single")
    let assert state.Moving(_, _) = s.phase
    let assert [a, b] = s.last_roll
    assert a != b
  })
}

pub fn a_timeout_forfeits_in_any_phase_test() {
  let g = backgammon.game()
  let moving = new_game(5, "single")
  assert g.timeout(moving, "p1") == game.Forfeit
  assert g.timeout(moving, "p2") == game.Forfeit
  let rolling = state.GameState(..moving, phase: state.Rolling(board.White))
  assert g.timeout(rolling, "p1") == game.Forfeit
  let doubled = state.GameState(..moving, phase: state.Doubled(board.White))
  assert g.timeout(doubled, "p2") == game.Forfeit
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
        conformance.Options(exclude: resign_actions),
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
        conformance.Options(exclude: resign_actions),
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

/// Random play never resigns: an offer needs an answer, and a random one
/// would end every game early.
const resign_actions = ["resign", "accept_resign", "decline_resign"]
