//// Conformance and property tests: seeded playouts to termination on every
//// board size, invariants over every state, replay determinism, and scene
//// facts that hold for any go game.

import gamekit/conformance
import gamekit/game
import gamekit/rng
import gamekit/scene
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/set
import go/board
import go/engine
import go/game as go
import go/helpers
import go/state.{type GameState}

/// The invariants that must hold after every action:
///  - stone accounting: a color's stones on the board are exactly its
///    placements minus the prisoners the opponent took;
///  - the position history has one entry per placement plus the initial
///    position, and it is a set, so no whole-board position ever repeated;
///  - consecutive passes never exceed two.
fn invariant(s: GameState) -> Result(Nil, String) {
  let black = state.player_of(s, board.Black)
  let white = state.player_of(s, board.White)
  let blacks_on_board = board.stone_count(s.board, board.Black)
  let whites_on_board = board.stone_count(s.board, board.White)
  let black_ok =
    blacks_on_board == state.placed_by(s, black) - state.captured_by(s, white)
  let white_ok =
    whites_on_board == state.placed_by(s, white) - state.captured_by(s, black)
  let history_ok =
    set.size(s.history)
    == state.placed_by(s, black) + state.placed_by(s, white) + 1
  case black_ok, white_ok, history_ok, s.passes <= 2 {
    True, True, True, True -> Ok(Nil)
    False, _, _, _ -> Error("black stone accounting broke")
    _, False, _, _ -> Error("white stone accounting broke")
    _, _, False, _ -> Error("a board position repeated")
    _, _, _, False -> Error("more than two consecutive passes")
  }
}

pub fn random_playouts_terminate_on_every_size_test() {
  list.each(
    [
      #("9x9", list.range(1, 10)),
      #("13x13", list.range(1, 4)),
      #("19x19", list.range(1, 2)),
    ],
    fn(fmt) {
      list.each(fmt.1, fn(seed) {
        let assert Ok(report) =
          conformance.random_playout_with(
            go.game(),
            fmt.0,
            helpers.seats(),
            seed,
            600,
            invariant,
            conformance.Options(exclude: ["resign"]),
          )
        assert report.finished
        let assert state.Finished(_) = report.state.phase
      })
    },
  )
}

/// Random play that prefers placing to passing: pick a random legal point
/// while any exists; pass when none does, or once `place_limit` stones have
/// been played (random no-pass go runs essentially unbounded, so the limit
/// stands in for players agreeing the game is over). This drives long games
/// full of captures and kos, so superko has to earn its keep.
fn greedy_playout(
  s: GameState,
  chooser: rng.Rng,
  steps_left: Int,
  place_limit: Int,
) -> #(GameState, Int) {
  case s.phase, steps_left {
    state.Finished(_), _ -> #(s, steps_left)
    _, 0 -> #(s, 0)
    state.Playing(_), _ -> {
      let assert Some(mover) = state.to_move(s)
      let assert Ok(_) = invariant(s)
      let candidates = case s.move_number < place_limit {
        True -> state.legal_point_ids(s, mover)
        False -> []
      }
      let #(next, chooser) = case candidates {
        [] -> {
          let assert Ok(#(next, _)) = engine.apply(s, mover, engine.Pass)
          #(next, chooser)
        }
        candidates -> {
          let assert Ok(#(point, chooser)) = rng.pick(chooser, candidates)
          let assert Ok(#(next, _)) =
            engine.apply(s, mover, engine.Place(point))
          #(next, chooser)
        }
      }
      greedy_playout(next, chooser, steps_left - 1, place_limit)
    }
  }
}

pub fn greedy_playouts_terminate_within_bounds_test() {
  // Every placement creates a brand new position (superko guarantees it,
  // and the invariant asserts it move by move); when placing stops, two
  // passes end the game.
  list.each(list.range(1, 6), fn(seed) {
    let #(final, left) =
      greedy_playout(helpers.new_game("9x9"), rng.seed(seed), 700, 600)
    let assert state.Finished(_) = final.phase
    assert left > 0
    let assert Ok(_) = invariant(final)
    // A finished greedy game really was a game: hundreds of stones went
    // down and prisoners were taken along the way.
    assert final.move_number >= 600
    assert state.captured_by(final, "p1") + state.captured_by(final, "p2") > 0
  })
  let #(final, left) =
    greedy_playout(helpers.new_game("13x13"), rng.seed(3), 900, 800)
  let assert state.Finished(_) = final.phase
  assert left > 0
  let #(final, left) =
    greedy_playout(helpers.new_game("19x19"), rng.seed(1), 600, 500)
  let assert state.Finished(_) = final.phase
  assert left > 0
  let assert Ok(_) = invariant(final)
}

pub fn replay_is_deterministic_test() {
  list.each([7, 8], fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        go.game(),
        "9x9",
        helpers.seats(),
        seed,
        600,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    let assert Ok(replayed) =
      conformance.replay(go.game(), "9x9", helpers.seats(), seed, report.steps)
    assert conformance.fingerprint(go.game(), replayed, helpers.seats())
      == conformance.fingerprint(go.game(), report.state, helpers.seats())
  })
}

pub fn malformed_actions_are_rejected_through_the_wire_test() {
  let s = helpers.new_game("9x9")
  let assert Error(_) =
    conformance.apply_json(go.game(), s, "p1", "{\"name\":\"place\"}")
  let assert Error(_) =
    conformance.apply_json(
      go.game(),
      s,
      "p1",
      "{\"name\":\"place\",\"params\":{\"point\":\"p99-0\"}}",
    )
  let assert Error(_) =
    conformance.apply_json(go.game(), s, "p2", "{\"name\":\"pass\"}")
  let assert Ok(_) =
    conformance.apply_json(
      go.game(),
      s,
      "p1",
      "{\"name\":\"place\",\"params\":{\"point\":[\"p4-4\"]}}",
    )
}

pub fn scenes_hide_nothing_and_cover_the_whole_board_test() {
  // Go is a perfect-information game: every viewer sees identical zones
  // and players, and the board zone always shows one token per point.
  let #(final, _) =
    greedy_playout(helpers.new_game("9x9"), rng.seed(11), 40, 40)
  let g = go.game()
  list.each(
    [scene.Player("p1"), scene.Player("p2"), scene.Spectator],
    fn(viewer) {
      let viewed = g.scene(final, viewer)
      let assert Ok(zone) = scene.find_zone(viewed, "board")
      assert list.length(zone.tokens) == 81
      let ids = list.map(zone.tokens, fn(t) { t.id })
      assert list.length(list.unique(ids)) == 81
      assert zone.layout == scene.Grid(9, 9)
    },
  )
  let p1 = g.scene(final, scene.Player("p1"))
  let p2 = g.scene(final, scene.Player("p2"))
  let spectator = g.scene(final, scene.Spectator)
  assert p1.zones == p2.zones
  assert p1.zones == spectator.zones
  assert p1.players == spectator.players
  // Legal placement candidates are all shown in the board zone.
  case state.to_move(final) {
    Some(mover) -> {
      let candidates = state.legal_point_ids(final, mover)
      let shown =
        scene.zone_token_ids(g.scene(final, scene.Player(mover)), "board")
      assert list.all(candidates, list.contains(shown, _))
    }
    _ -> Nil
  }
}

pub fn stone_ids_are_stable_and_never_recycled_test() {
  // Ids are the move number: unique for the life of the game even when
  // stones are captured and points are refilled.
  let #(final, _) =
    greedy_playout(helpers.new_game("9x9"), rng.seed(5), 300, 200)
  let assert state.Finished(_) = final.phase
  let g = go.game()
  let viewed = g.scene(final, scene.Spectator)
  let assert Ok(zone) = scene.find_zone(viewed, "board")
  let stone_numbers =
    zone.tokens
    |> list.filter(fn(t) { t.kind == "stone" })
    |> list.filter_map(fn(t) {
      case t.id {
        "s" <> n -> int.parse(n)
        _ -> Error(Nil)
      }
    })
  assert stone_numbers != []
  assert list.all(stone_numbers, fn(n) { n >= 1 && n <= final.move_number })
  assert list.length(list.unique(stone_numbers)) == list.length(stone_numbers)
}

pub fn outcome_names_the_winner_test() {
  let s = helpers.new_game("9x9")
  assert go.outcome(s) == game.Ongoing
  let assert Ok(#(s2, _)) = engine.apply(s, "p1", engine.Resign)
  assert go.outcome(s2) == game.Finished(["p2"])
}
