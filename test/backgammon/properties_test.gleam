//// Properties of a staged turn over random positions and random play.

import backgammon/board.{Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/positions
import backgammon/state
import gamekit/conformance
import gamekit/rng.{type Rng}
import gamekit/scene
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}

fn longest_sequence(b: board.Board, dice: List(Int)) -> Int {
  board.sequences(b, White, dice)
  |> list.map(list.length)
  |> list.fold(0, int.max)
}

pub fn undo_after_stage_restores_the_exact_state_test() {
  positions.each_random(150, fn(seed, b, dice) {
    let s = positions.position(seed, b, dice)
    list.each(board.legal_moves(b, White, dice), fn(m) {
      let assert Ok(#(staged, _)) = state.stage(s, "p1", m.from, m.to)
      let assert Ok(#(back, _)) = state.undo(staged, "p1")
      assert back == s
    })
  })
}

pub fn staging_any_legal_move_keeps_the_turn_completable_test() {
  positions.each_random(150, fn(seed, b, dice) {
    let s = positions.position(seed, b, dice)
    let longest = longest_sequence(b, dice)
    list.each(board.legal_moves(b, White, dice), fn(m) {
      let assert Ok(#(s2, _)) = state.stage(s, "p1", m.from, m.to)
      // Either the turn is complete now, or there is still a move to make:
      // a legal first move never strands a playable die.
      assert state.can_play(s2, "p1") == { longest == 1 }
      assert { state.legal_moves(s2, "p1") != [] } == { longest > 1 }
    })
  })
}

fn walk(s: state.GameState, r: Rng, n: Int) -> #(state.GameState, Int) {
  case state.legal_moves(s, "p1") {
    [] -> #(s, n)
    moves -> {
      let assert Ok(#(m, r)) = rng.pick(r, moves)
      let assert Ok(#(s, _)) = state.stage(s, "p1", m.from, m.to)
      walk(s, r, n + 1)
    }
  }
}

pub fn a_random_walk_of_moves_uses_every_playable_die_and_commits_test() {
  positions.each_random(200, fn(seed, b, dice) {
    let s = positions.position(seed, b, dice)
    let longest = longest_sequence(b, dice)
    let #(s, n) = walk(s, rng.seed(seed), 0)
    assert n == longest
    assert state.can_play(s, "p1")
    // Pip accounting: every move shortens White by its die (or by the exact
    // distance when bearing off) and every hit sends a Black checker back
    // by the point it stood on.
    let white_delta =
      list.fold(s.staged, 0, fn(acc, st) {
        acc
        + case st.move.from, st.move.to {
          Point(p), Off -> board.pip_distance(White, p)
          _, _ -> st.move.die
        }
      })
    let black_delta =
      list.fold(s.staged, 0, fn(acc, st) {
        acc
        + case st.hit, st.move.to {
          Some(_), Point(p) -> p
          _, _ -> 0
        }
      })
    assert board.pip_count(b, White) - board.pip_count(s.board, White)
      == white_delta
    assert board.pip_count(s.board, Black) - board.pip_count(b, Black)
      == black_delta
    let assert Ok(played) = state.play(s, "p1")
    assert list.length(played.moves) == n
    assert played.state.staged == []
    assert played.state.turn_board == played.state.board
    case board.borne_off(played.state.board, White) == 15 {
      True -> {
        let assert state.Finished(White) = played.state.phase
        Nil
      }
      False -> {
        let assert state.Rolling(Black) = played.state.phase
        Nil
      }
    }
  })
}

// ---------- random play through the full engine ----------

fn unwind(s: state.GameState, mover: String) -> state.GameState {
  case state.undo(s, mover) {
    Ok(#(s, _)) -> unwind(s, mover)
    Error(_) -> s
  }
}

fn scene_json(s: state.GameState, viewer: scene.Viewer) -> String {
  json.to_string(scene.to_json(backgammon.game().scene(s, viewer)))
}

/// While moves are staged, nobody but the mover can tell.
fn nothing_leaks(s: state.GameState) -> Result(Nil, String) {
  case s.staged {
    [] -> Ok(Nil)
    _ -> {
      let assert Some(mover) = state.to_move(s)
      let other = case mover {
        "p1" -> "p2"
        _ -> "p1"
      }
      let base = unwind(s, mover)
      let same = fn(viewer) {
        scene_json(s, viewer) == scene_json(base, viewer)
      }
      let other_legal =
        list.map(engine.legal(s, other), fn(schema) { schema.name })
      case
        base.board == s.turn_board,
        same(scene.Player(other)),
        same(scene.Spectator),
        same(scene.Player(mover)),
        other_legal
      {
        True, True, True, False, ["resign"] -> Ok(Nil)
        False, _, _, _, _ ->
          Error("undoing every move does not restore the turn board")
        _, False, _, _, _ -> Error("the opponent can see staged moves")
        _, _, False, _, _ -> Error("spectators can see staged moves")
        _, _, _, True, _ -> Error("the mover cannot see their own staged moves")
        _, _, _, _, _ -> Error("the waiting player has actions during staging")
      }
    }
  }
}

// Split by seed so each stays inside the per-test timeout: the scene
// comparisons make these the slowest tests in the suite.
pub fn staged_moves_never_leak_during_random_games_a_test() {
  never_leak([1, 2])
}

pub fn staged_moves_never_leak_during_random_games_b_test() {
  never_leak([3, 4])
}

pub fn staged_moves_never_leak_during_random_games_c_test() {
  never_leak([5, 6])
}

pub fn staged_moves_never_leak_during_random_games_d_test() {
  never_leak([7, 8])
}

fn never_leak(seeds: List(Int)) {
  list.each(seeds, fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        backgammon.game(),
        "single",
        positions.seats(),
        seed,
        4000,
        nothing_leaks,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
  })
}
