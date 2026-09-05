//// The automatic game-end conventions: fifty-move rule, threefold
//// repetition (the FIDE definition of "same position"), dead positions,
//// and the flag-fall material rule.

import chess/board.{Black, White}
import chess/engine
import chess/fen
import chess/game as chess
import chess/positions.{black, mv, state_from, white}
import chess/state
import gamekit/game
import gleam/list
import gleam/option.{Some}

// ---------- Fifty-move rule ----------

pub fn fifty_moves_draw_exactly_at_the_boundary_test() {
  // Halfmove 99: one more quiet move is the hundredth.
  let s = state_from("4k3/8/8/8/8/8/8/R3K3 w - - 99 80")
  let assert Ok(played) = state.play(s, white, mv("a1a2"))
  assert played.state.phase == state.Drawn(state.FiftyMoveRule)
}

pub fn fifty_moves_not_before_the_boundary_test() {
  let s = state_from("4k3/8/8/8/8/8/8/R3K3 w - - 98 80")
  let assert Ok(played) = state.play(s, white, mv("a1a2"))
  assert played.state.phase == state.Playing
  assert played.state.position.halfmove == 99
}

pub fn a_pawn_move_resets_the_counter_test() {
  let s = state_from("4k3/8/8/8/8/P7/8/R3K3 w - - 99 80")
  let assert Ok(played) = state.play(s, white, mv("a3a4"))
  assert played.state.phase == state.Playing
  assert played.state.position.halfmove == 0
}

pub fn a_capture_resets_the_counter_test() {
  let s = state_from("4k3/8/8/8/8/r7/R7/4K3 w - - 99 80")
  let assert Ok(played) = state.play(s, white, mv("a2a3"))
  assert played.state.phase == state.Playing
  assert played.state.position.halfmove == 0
}

pub fn checkmate_on_the_hundredth_halfmove_wins_test() {
  // Mate takes precedence over the counter reaching 100.
  let s = state_from("6k1/5ppp/8/8/8/8/8/4R1K1 w - - 99 80")
  let assert Ok(played) = state.play(s, white, mv("e1e8"))
  assert played.state.phase == state.WonBy(White, state.Checkmate)
}

// ---------- Threefold repetition ----------

fn play_all(s: state.GameState, moves: List(String)) -> state.GameState {
  list.fold(moves, s, fn(s, text) {
    let assert Some(id) = state.to_move(s)
    let assert Ok(played) = state.play(s, id, mv(text))
    played.state
  })
}

pub fn knight_shuffle_repeats_the_initial_position_test() {
  let s = state.new(positions.seats())
  let shuffle = ["g1f3", "g8f6", "f3g1", "f6g8"]
  let after_one = play_all(s, shuffle)
  assert after_one.phase == state.Playing
  let after_seven = play_all(after_one, ["g1f3", "g8f6", "f3g1"])
  assert after_seven.phase == state.Playing
  // The eighth ply shows the initial position for the third time.
  let assert Ok(played) = state.play(after_seven, black, mv("f6g8"))
  assert played.state.phase == state.Drawn(state.ThreefoldRepetition)
}

pub fn same_board_with_different_castling_rights_is_not_a_repetition_test() {
  // Rook shuffles bring the pieces home, but the first shuffle spent both
  // kingside rights: the position at ply 8 matches ply 4, not ply 0.
  let s = state_from("r3k2r/8/8/8/8/8/8/R3K2R w KQkq -")
  let shuffle = ["h1g1", "h8g8", "g1h1", "g8h8"]
  let after_two = play_all(s, list.append(shuffle, shuffle))
  // A board-only count would call this the third occurrence and stop here.
  assert after_two.phase == state.Playing
  // With rights stable at Qq since ply 2, the position after black's g8
  // rook returns is now genuinely on its third occurrence.
  let after_nine = play_all(after_two, ["h1g1"])
  assert after_nine.phase == state.Playing
  let after_ten = play_all(after_nine, ["h8g8"])
  assert after_ten.phase == state.Drawn(state.ThreefoldRepetition)
}

pub fn en_passant_availability_distinguishes_positions_test() {
  // Same placement; a live en-passant capture makes it a different position.
  let capturable = fen.load("4k3/8/8/8/3Pp3/8/8/4K3 b - d3")
  let plain = fen.load("4k3/8/8/8/3Pp3/8/8/4K3 b - -")
  assert board.key(capturable) != board.key(plain)
}

pub fn an_unusable_ep_square_does_not_distinguish_positions_test() {
  // No enemy pawn can take en passant: the ep field is noise, not identity.
  let noise = fen.load("4k3/8/8/8/3P4/8/8/4K3 b - d3")
  let plain = fen.load("4k3/8/8/8/3P4/8/8/4K3 b - -")
  assert board.key(noise) == board.key(plain)
}

pub fn a_pinned_ep_capture_does_not_distinguish_positions_test() {
  // The ep capture exists geometrically but is illegal (the classic pin),
  // so the position counts as having no en-passant availability.
  let pinned = fen.load("8/8/8/KPp4r/8/8/8/7k w - c6")
  let plain = fen.load("8/8/8/KPp4r/8/8/8/7k w - -")
  assert board.key(pinned) == board.key(plain)
}

// ---------- Dead positions ----------

fn dead(fen_text: String) -> Bool {
  board.dead_position(fen.load(fen_text).board)
}

pub fn insufficient_material_combos_test() {
  assert dead("4k3/8/8/8/8/8/8/4K3 w - -")
  // KB vs K
  assert dead("4k3/8/8/8/8/8/8/2B1K3 w - -")
  // KN vs K
  assert dead("4k3/8/8/8/8/8/8/2N1K3 w - -")
  // KB vs KB, both bishops on dark squares
  assert dead("4k3/6b1/8/8/8/8/1B6/4K3 w - -")
}

pub fn sufficient_material_combos_test() {
  // KB vs KB with opposite-colored bishops can still be mated
  assert !dead("4k3/5b2/8/8/8/8/1B6/4K3 w - -")
  assert !dead("4k3/8/8/8/8/8/8/2N1K1N1 w - -")
  // Two knights on one side is not a dead position (helpmates exist)
  assert !dead("4k3/8/8/8/8/8/8/1NN1K3 w - -")
  assert !dead("4k3/8/8/8/8/8/8/R3K3 w - -")
  assert !dead("4k3/8/8/8/8/8/P7/4K3 w - -")
  assert !dead("4k3/8/8/8/8/8/8/Q3K3 w - -")
}

pub fn a_capture_into_a_dead_position_ends_the_game_test() {
  let s = state_from("4k3/8/8/8/8/8/4r3/4K3 w - -")
  let assert Ok(played) = state.play(s, white, mv("e1e2"))
  assert played.state.phase == state.Drawn(state.DeadPosition)
}

pub fn a_capture_leaving_kb_vs_k_ends_the_game_test() {
  let s = state_from("4k3/8/8/8/8/8/4r3/4KB2 w - -")
  let assert Ok(played) = state.play(s, white, mv("e1e2"))
  assert played.state.phase == state.Drawn(state.DeadPosition)
}

// ---------- Flag falls ----------

pub fn a_flag_fall_forfeits_against_mating_material_test() {
  let s = state.new(positions.seats())
  let assert Ok(next) = state.flag(s, white)
  assert next.phase == state.WonBy(Black, state.FlagFall)
}

pub fn a_flag_fall_against_a_bare_king_is_a_draw_test() {
  let s = state_from("4k3/8/8/8/8/8/8/Q3K3 w - -")
  // White's flag falls: bare-king Black cannot possibly mate, so a draw...
  let assert Ok(drawn) = state.flag(s, white)
  assert drawn.phase == state.Drawn(state.FlagFall)
  // ...but Black flagging loses: White has a queen.
  let assert Ok(lost) = state.flag(s, black)
  assert lost.phase == state.WonBy(White, state.FlagFall)
}

pub fn a_flag_fall_in_a_dead_position_is_a_draw_test() {
  let s = state_from("4k3/8/8/8/8/8/8/3BK3 w - -")
  let assert Ok(a) = state.flag(s, white)
  assert a.phase == state.Drawn(state.FlagFall)
  let assert Ok(b) = state.flag(s, black)
  assert b.phase == state.Drawn(state.FlagFall)
}

pub fn the_contract_times_out_into_a_flag_action_test() {
  let definition = chess.game()
  let s = state.new(positions.seats())
  assert definition.timeout(s, white) == game.Act(engine.Flag)
  // Outcomes follow the flag decision, not a blanket forfeit.
  let assert Ok(#(next, _)) = definition.apply(s, white, engine.Flag)
  assert definition.outcome(next) == game.Finished([black])
}
