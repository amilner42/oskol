//// Properties of a staged turn over random positions and random play.

import backgammon/board.{Black, Off, Point, White}
import backgammon/engine
import backgammon/game as backgammon
import backgammon/positions
import backgammon/state
import gamekit/conformance
import gamekit/rng.{type Rng}
import gamekit/scene
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

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
        let assert state.Finished(Some(White)) = played.state.phase
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

/// A scene's board without the staging layer: the points, bars and trays,
/// and the players' counters. The dice and the `data` are left out: the dice
/// show what the staging has used, to everyone.
fn committed_json(s: state.GameState, viewer: scene.Viewer) -> String {
  let sc = backgammon.game().scene(s, viewer)
  scene.Scene(
    ..sc,
    zones: list.filter(sc.zones, fn(z) { z.id != "dice" }),
    data: [],
  )
  |> scene.to_json
  |> json.to_string
}

/// Checkers per place and colour, as `#(zone, color letter)` to a count.
fn tally(sc: scene.Scene) -> dict.Dict(#(String, String), Int) {
  list.fold(sc.zones, dict.new(), fn(acc, z) {
    case z.id {
      "dice" | "cube" -> acc
      _ ->
        list.fold(z.tokens, acc, fn(acc, t) {
          bump(acc, #(z.id, string.slice(t.id, 0, 1)), 1)
        })
    }
  })
  |> dict.filter(fn(_, n) { n != 0 })
}

fn bump(
  acc: dict.Dict(#(String, String), Int),
  key: #(String, String),
  by: Int,
) -> dict.Dict(#(String, String), Int) {
  dict.upsert(acc, key, fn(n) { option.unwrap(n, 0) + by })
}

/// A watcher's committed board with its ghosts laid on: the arrivals added,
/// the leavers taken away.
fn with_ghosts(sc: scene.Scene) -> dict.Dict(#(String, String), Int) {
  let assert Ok(layer) = list.key_find(sc.data, "ghosts")
  let arrive = {
    use zone <- decode.field("zone", decode.string)
    use color <- decode.field("color", decode.string)
    decode.success(#(zone, string.slice(color, 0, 1), 1))
  }
  let leave = {
    use zone <- decode.field("zone", decode.string)
    use color <- decode.field("color", decode.string)
    use count <- decode.field("count", decode.int)
    decode.success(#(zone, string.slice(color, 0, 1), -count))
  }
  let decoder = {
    use a <- decode.field("arrive", decode.list(arrive))
    use l <- decode.field("leave", decode.list(leave))
    decode.success(list.append(a, l))
  }
  let assert Ok(changes) = json.parse(json.to_string(layer), decoder)
  list.fold(changes, tally(sc), fn(acc, c) { bump(acc, #(c.0, c.1), c.2) })
  |> dict.filter(fn(_, n) { n != 0 })
}

/// While moves are staged, nothing is committed: the opponent and a
/// spectator keep the turn-start board, and the staging they see is a ghost
/// layer that, laid on that board, gives exactly the mover's board. The
/// waiting player still has nothing to do but resign.
fn staging_is_a_layer(s: state.GameState) -> Result(Nil, String) {
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
        committed_json(s, viewer) == committed_json(base, viewer)
      }
      let mine = backgammon.game().scene(s, scene.Player(mover))
      let adds_up = fn(viewer) {
        with_ghosts(backgammon.game().scene(s, viewer)) == tally(mine)
      }
      let other_legal =
        list.map(engine.legal(s, other), fn(schema) { schema.name })
      case
        base.board == s.turn_board,
        same(scene.Player(other)) && same(scene.Spectator),
        adds_up(scene.Player(other)) && adds_up(scene.Spectator),
        list.key_find(mine.data, "ghosts"),
        other_legal
      {
        True, True, True, Error(Nil), ["resign"] -> Ok(Nil)
        False, _, _, _, _ ->
          Error("undoing every move does not restore the turn board")
        _, False, _, _, _ -> Error("a watcher's committed board moved")
        _, _, False, _, _ -> Error("the ghosts do not add up to the staging")
        _, _, _, Ok(_), _ -> Error("the mover sees ghosts of their own moves")
        _, _, _, _, _ -> Error("the waiting player has actions during staging")
      }
    }
  }
}

// Split by seed so each stays inside the per-test timeout: the scene
// comparisons make these the slowest tests in the suite.
pub fn staging_is_a_layer_during_random_games_a_test() {
  layer_holds([1, 2])
}

pub fn staging_is_a_layer_during_random_games_b_test() {
  layer_holds([3, 4])
}

pub fn staging_is_a_layer_during_random_games_c_test() {
  layer_holds([5, 6])
}

pub fn staging_is_a_layer_during_random_games_d_test() {
  layer_holds([7, 8])
}

fn layer_holds(seeds: List(Int)) {
  list.each(seeds, fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        backgammon.game(),
        "single",
        positions.seats(),
        seed,
        4000,
        staging_is_a_layer,
        conformance.Options(exclude: conceding),
      )
    assert report.finished
  })
}

/// Random play never gives a game up: an offer needs an answer, and a
/// random resignation -- or a random `close`, which ends an unlimited
/// session after its first game -- would end every playout early.
const conceding = ["resign", "accept_resign", "decline_resign", "close"]
