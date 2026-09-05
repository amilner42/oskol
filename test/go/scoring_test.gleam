//// Tromp-Taylor scoring on hand-built boards, and komi at the engine level.

import gamekit/game
import gamekit/rng
import gleam/dict
import gleam/list
import gleam/option.{Some}
import go/board
import go/engine
import go/game as go
import go/helpers
import go/state

pub fn an_empty_board_scores_zero_for_both_test() {
  assert board.score(board.new(9)) == #(0, 0)
  assert board.score(board.new(13)) == #(0, 0)
  assert board.score(board.new(19)) == #(0, 0)
}

pub fn a_lone_stone_owns_the_whole_board_test() {
  let b = board.from_rows(["...", ".b.", "..."])
  assert board.score(b) == #(9, 0)
  let w = board.from_rows(["...", ".w.", "..."])
  assert board.score(w) == #(0, 9)
}

pub fn divided_territory_counts_stones_plus_own_territory_test() {
  let b =
    board.from_rows([
      "..bw.",
      "..bw.",
      "..bw.",
      "..bw.",
      "..bw.",
    ])
  // Black: 5 stones + 10 empty points reaching only black.
  // White: 5 stones + 5 empty points reaching only white.
  assert board.score(b) == #(15, 10)
}

pub fn dame_touching_both_colors_counts_for_neither_test() {
  let b =
    board.from_rows([
      ".b.w.",
      ".b.w.",
      ".b.w.",
      ".b.w.",
      ".b.w.",
    ])
  // The middle column reaches both colors: neutral. 5 + 5 for each side.
  assert board.score(b) == #(10, 10)
}

pub fn a_seki_like_shared_region_counts_for_neither_test() {
  // Two white groups stand in a black frame sharing the two middle
  // liberties. Under Tromp-Taylor the shared empty region reaches both
  // colors, so it scores for no one: this is how seki falls out.
  let b =
    board.from_rows([
      "bbbbb",
      "bw.wb",
      "bw.wb",
      "bwwwb",
      "bbbbb",
    ])
  assert board.score(b) == #(16, 7)
}

pub fn territory_with_a_hole_in_the_wall_leaks_test() {
  // One gap in black's wall lets the empty region reach white: the whole
  // region goes neutral.
  let leaky =
    board.from_rows([
      "..bw.",
      "...w.",
      "..bw.",
      "..bw.",
      "..bw.",
    ])
  // The gap at (2,1) joins black's side to the white wall: the whole left
  // region reaches both colors and goes neutral. White keeps its side.
  assert board.score(leaky) == #(4, 10)
}

// The 9x9 position used by the komi tests: black area 44, white area 37,
// one neutral point at (4,8). The 7-point margin sits between komi 6.5
// (black by 0.5) and komi 7.5 (white by 0.5).
fn close_board() -> List(String) {
  [
    "....bw...",
    "....bw...",
    "....bw...",
    "....bw...",
    "....bw...",
    "....bw...",
    "....bw...",
    "....bw...",
    "...bww...",
  ]
}

pub fn the_close_board_scores_as_documented_test() {
  assert board.score(board.from_rows(close_board())) == #(44, 37)
}

fn finish_by_passes(komi2: Int) -> state.GameState {
  let s = helpers.mid_game(close_board(), board.Black)
  let s = state.GameState(..s, config: state.Config(..s.config, komi2: komi2))
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Pass)
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Pass)
  s
}

pub fn komi_decides_a_close_game_test() {
  // 5.5 and 6.5: black 44 beats white 37 + komi.
  let assert state.Finished(board.Black) = finish_by_passes(11).phase
  let assert state.Finished(board.Black) = finish_by_passes(13).phase
  // 7.5: white 44.5 edges black 44.
  let assert state.Finished(board.White) = finish_by_passes(15).phase
  assert finish_by_passes(15).final_score2 == Some(#(88, 89))
  assert finish_by_passes(13).final_score2 == Some(#(88, 87))
}

pub fn every_komi_setting_configures_the_engine_test() {
  let assert Ok(format) = game.find_format(go.info(), "9x9")
  list.each([#("55", 11), #("65", 13), #("75", 15)], fn(choice) {
    let assert Ok(config) =
      game.configure(format, dict.from_list([#("komi", choice.0)]))
    let assert Ok(s) = go.init(config, helpers.seats(), rng.seed(1))
    assert s.config.komi2 == choice.1
  })
  // The default is 6.5.
  let assert Ok(s) =
    go.init(game.default_config(format), helpers.seats(), rng.seed(1))
  assert s.config.komi2 == 13
}

pub fn every_board_size_initialises_and_scores_test() {
  list.each([#("9x9", 9), #("13x13", 13), #("19x19", 19)], fn(f) {
    let s = helpers.new_game(f.0)
    assert s.config.size == f.1
    assert s.board.size == f.1
    // Black opens with the full board to choose from.
    assert list.length(state.legal_point_ids(s, "p1")) == f.1 * f.1
    assert state.legal_point_ids(s, "p2") == []
    // An immediate double pass scores the empty board: white wins by komi.
    let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Pass)
    let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Pass)
    let assert state.Finished(board.White) = s.phase
    assert s.final_score2 == Some(#(0, 13))
  })
}
