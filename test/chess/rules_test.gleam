//// Controlled-position rule tests: the rulebook, spelled out. Perft proves
//// the counts; these prove each rule is the reason.

import chess/board.{Black, White}
import chess/fen
import chess/positions.{has_move, moves_at, mv}
import chess/state
import gleam/dict
import gleam/list
import gleam/option.{None, Some}

// ---------- Castling ----------

const both_castles = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq -"

pub fn castling_both_sides_available_test() {
  let moves = moves_at(both_castles)
  assert has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn castling_through_an_attacked_square_is_illegal_test() {
  // A black rook on f3 covers f1: the king may not cross it kingside.
  let moves = moves_at("r3k2r/8/8/8/8/5r2/8/R3K2R w KQkq -")
  assert !has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn castling_out_of_check_is_illegal_test() {
  // A rook on e3 gives check: neither castle may answer it.
  let moves = moves_at("r3k2r/8/8/8/8/4r3/8/R3K2R w KQkq -")
  assert !has_move(moves, "e1g1")
  assert !has_move(moves, "e1c1")
}

pub fn castling_into_check_is_illegal_test() {
  // A rook on g3 covers g1, the king's landing square.
  let moves = moves_at("r3k2r/8/8/8/8/6r1/8/R3K2R w KQkq -")
  assert !has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn queenside_b1_may_be_attacked_test() {
  // Only the king's path must be safe: b1 under fire does not stop O-O-O.
  let moves = moves_at("r3k2r/8/8/8/8/1r6/8/R3K2R w KQkq -")
  assert has_move(moves, "e1c1")
}

pub fn castling_blocked_by_a_piece_is_illegal_test() {
  let moves = moves_at("r3k2r/8/8/8/8/8/8/R3KB1R w KQkq -")
  assert !has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn castling_needs_the_right_test() {
  // Same position, kingside right already spent.
  let moves = moves_at("r3k2r/8/8/8/8/8/8/R3K2R w Qkq -")
  assert !has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn a_king_move_spends_both_rights_forever_test() {
  let pos = fen.load(both_castles)
  let #(pos, _) = board.make_move(pos, mv("e1e2"))
  let #(pos, _) = board.make_move(pos, mv("e8e7"))
  let #(pos, _) = board.make_move(pos, mv("e2e1"))
  let #(pos, _) = board.make_move(pos, mv("e7e8"))
  assert pos.castling == board.Castling(False, False, False, False)
  let moves = board.legal_moves(pos)
  assert !has_move(moves, "e1g1")
  assert !has_move(moves, "e1c1")
}

pub fn a_rook_move_spends_only_its_own_right_test() {
  let pos = fen.load(both_castles)
  let #(pos, _) = board.make_move(pos, mv("h1g1"))
  let #(pos, _) = board.make_move(pos, mv("a8b8"))
  let #(pos, _) = board.make_move(pos, mv("g1h1"))
  let #(pos, _) = board.make_move(pos, mv("b8a8"))
  assert pos.castling == board.Castling(False, True, True, False)
  let moves = board.legal_moves(pos)
  assert !has_move(moves, "e1g1")
  assert has_move(moves, "e1c1")
}

pub fn capturing_the_rook_on_its_square_kills_the_right_test() {
  // Black's h8 rook runs down the file and takes h1: both kingside rights
  // die, one with the capture and one with the capturing rook leaving home.
  let pos = fen.load("r3k2r/8/8/8/8/8/8/R3K2R b KQkq -")
  let #(pos, info) = board.make_move(pos, mv("h8h1"))
  assert info.captured == Some(#(7, board.Piece(White, board.Rook)))
  assert pos.castling == board.Castling(False, True, False, True)
  assert !has_move(board.legal_moves(pos), "e1g1")
}

pub fn castling_moves_both_tokens_test() {
  // Engine level: O-O-O emits two token moves, king and rook.
  let s = positions.state_from(both_castles)
  let assert Ok(played) = state.play(s, positions.white, mv("e1c1"))
  let assert Some(#(_, from, to)) = played.rook_token
  assert board.square_name(from) == "a1"
  assert board.square_name(to) == "d1"
  assert board.piece_at(played.state.position, sq("d1"))
    == Some(board.Piece(White, board.Rook))
  assert board.piece_at(played.state.position, sq("c1"))
    == Some(board.Piece(White, board.King))
}

// ---------- En passant ----------

pub fn en_passant_is_available_immediately_test() {
  let pos = fen.load("4k3/8/8/8/2p5/8/3P4/4K3 w - -")
  let #(pos, _) = board.make_move(pos, mv("d2d4"))
  assert pos.ep == Some(sq("d3"))
  let moves = board.legal_moves(pos)
  assert has_move(moves, "c4d3")
  // The capture removes the pawn on d4, not d3.
  let #(after, info) = board.make_move(pos, mv("c4d3"))
  assert info.en_passant
  assert info.captured == Some(#(sq("d4"), board.Piece(White, board.Pawn)))
  assert board.piece_at(after, sq("d4")) == None
  assert board.piece_at(after, sq("d3")) == Some(board.Piece(Black, board.Pawn))
}

pub fn en_passant_expires_after_one_move_test() {
  let pos = fen.load("4k3/8/8/8/2p5/8/3P4/4K3 w - -")
  let #(pos, _) = board.make_move(pos, mv("d2d4"))
  let #(pos, _) = board.make_move(pos, mv("e8d8"))
  let #(pos, _) = board.make_move(pos, mv("e1d1"))
  assert pos.ep == None
  assert !has_move(board.legal_moves(pos), "c4d3")
}

pub fn en_passant_that_exposes_the_king_is_illegal_test() {
  // The classic pin: bxc6 e.p. would clear rank 5 between the white king
  // and the black rook.
  let pos = fen.load("8/2p5/8/KP5r/8/8/8/7k b - -")
  let #(pos, _) = board.make_move(pos, mv("c7c5"))
  assert pos.ep == Some(sq("c6"))
  assert !has_move(board.legal_moves(pos), "b5c6")
}

// ---------- Promotion ----------

pub fn promotion_offers_all_four_pieces_test() {
  let moves =
    moves_at("4k3/P7/8/8/8/8/8/4K3 w - -")
    |> list.filter(fn(m) { m.from == sq("a7") })
  assert list.length(moves) == 4
  assert list.all(moves, fn(m) { m.to == sq("a8") && m.promotion != None })
  assert has_move(moves, "a7a8q")
  assert has_move(moves, "a7a8r")
  assert has_move(moves, "a7a8b")
  assert has_move(moves, "a7a8n")
}

pub fn promotion_with_capture_test() {
  let moves = moves_at("1n2k3/P7/8/8/8/8/8/4K3 w - -")
  assert has_move(moves, "a7b8q")
  assert has_move(moves, "a7b8n")
  let pos = fen.load("1n2k3/P7/8/8/8/8/8/4K3 w - -")
  let #(after, info) = board.make_move(pos, mv("a7b8q"))
  assert info.captured == Some(#(sq("b8"), board.Piece(Black, board.Knight)))
  assert board.piece_at(after, sq("b8"))
    == Some(board.Piece(White, board.Queen))
}

pub fn a_pawn_may_not_stay_a_pawn_on_the_last_rank_test() {
  let moves = moves_at("4k3/P7/8/8/8/8/8/4K3 w - -")
  assert !list.contains(moves, board.Move(sq("a7"), sq("a8"), None))
}

pub fn underpromotion_can_deliver_mate_test() {
  // c8=R is mate (as it happens, so is c8=Q; the point is the rook counts).
  let s = positions.state_from("k7/2P5/1K6/8/8/8/8/8 w - -")
  let assert Ok(played) = state.play(s, positions.white, mv("c7c8r"))
  assert played.state.phase == state.WonBy(White, state.Checkmate)
}

pub fn promoted_pawn_keeps_its_token_test() {
  let s = positions.state_from("4k3/P7/8/8/8/8/8/4K3 w - -")
  let assert Ok(token) = dict_get(s.tokens, sq("a7"))
  let assert Ok(played) = state.play(s, positions.white, mv("a7a8q"))
  assert played.mover_token == token
  assert dict_get(played.state.tokens, sq("a8")) == Ok(token)
  assert board.piece_at(played.state.position, sq("a8"))
    == Some(board.Piece(White, board.Queen))
}

// ---------- Pins and checks ----------

pub fn an_absolute_pin_immobilizes_except_along_the_line_test() {
  // The e4 rook is pinned to the king by the e8 rook: it may only slide on
  // the e-file (including capturing the pinner).
  let rook_moves =
    moves_at("4r3/8/8/8/4R3/8/8/4K3 w - -")
    |> list.filter(fn(m) { m.from == sq("e4") })
  assert list.length(rook_moves) == 6
  assert list.all(rook_moves, fn(m) { board.file(m.to) == 4 })
  assert has_move(rook_moves, "e4e8")
}

pub fn a_pinned_bishop_cannot_move_at_all_test() {
  let moves = moves_at("4r3/8/8/8/8/8/4B3/4K3 w - -")
  assert list.filter(moves, fn(m) { m.from == sq("e2") }) == []
}

pub fn double_check_forces_a_king_move_test() {
  // Rook e8 and knight f3 both check e1; the queen can block or take
  // either, but not both, so only the king may move.
  let moves = moves_at("4r3/8/8/8/8/5n2/8/3QK3 w - -")
  assert moves != []
  assert list.all(moves, fn(m) { m.from == sq("e1") })
}

pub fn a_move_may_never_leave_the_king_in_check_test() {
  // The king is in check from the e8 rook: every legal move must address it.
  let moves = moves_at("4r3/8/8/8/8/8/3B4/4K3 w - -")
  assert has_move(moves, "d2e3")
  // Blocking on e3 works; wandering off with the bishop does not.
  assert !has_move(moves, "d2c3")
}

pub fn discovered_check_test() {
  let pos = fen.load("4k3/8/8/8/4N3/8/8/4R1K1 w - -")
  let #(after, _) = board.make_move(pos, mv("e4c5"))
  assert board.in_check(after)
}

pub fn smothered_mate_test() {
  let s = positions.state_from("6rk/6pp/8/6N1/8/8/8/6K1 w - -")
  let assert Ok(played) = state.play(s, positions.white, mv("g5f7"))
  assert played.state.phase == state.WonBy(White, state.Checkmate)
}

pub fn back_rank_mate_test() {
  let s = positions.state_from("6k1/5ppp/8/8/8/8/8/4R1K1 w - -")
  let assert Ok(played) = state.play(s, positions.white, mv("e1e8"))
  assert played.state.phase == state.WonBy(White, state.Checkmate)
}

pub fn stalemate_is_a_draw_test() {
  // Qc7 leaves the a8 king unchecked and without a square.
  let s = positions.state_from("k7/8/1K6/2Q5/8/8/8/8 w - -")
  let assert Ok(played) = state.play(s, positions.white, mv("c5c7"))
  assert played.state.phase == state.Drawn(state.Stalemate)
}

pub fn fools_mate_from_the_initial_position_test() {
  let s = state.new(positions.seats())
  let assert Ok(p) = state.play(s, positions.white, mv("f2f3"))
  let assert Ok(p) = state.play(p.state, positions.black, mv("e7e5"))
  let assert Ok(p) = state.play(p.state, positions.white, mv("g2g4"))
  let assert Ok(p) = state.play(p.state, positions.black, mv("d8h4"))
  assert p.state.phase == state.WonBy(Black, state.Checkmate)
  assert state.to_move(p.state) == None
}

fn sq(name: String) -> Int {
  let assert Ok(square) = board.parse_square(name)
  square
}

fn dict_get(tokens, key) {
  dict.get(tokens, key)
}
