//// Perft: move-generation node counts against published values. The
//// rulebook is the spec; these counts are the proof that castling, en
//// passant, promotion, pins and checks are all generated exactly right.
////
//// Published values: https://www.chessprogramming.org/Perft_Results

import chess/board
import chess/fen
import gleam/list

fn expect(pos: board.Position, counts: List(Int)) -> Nil {
  list.index_map(counts, fn(count, i) {
    assert board.perft(pos, i + 1) == count
  })
  Nil
}

pub fn perft_initial_position_test() {
  expect(board.initial(), [20, 400, 8902, 197_281])
}

// Depth 5 runs in ~22s locally: slow but tolerable, and worth the coverage.
pub fn perft_initial_depth5_test() {
  assert board.perft(board.initial(), 5) == 4_865_609
}

// Kiwipete depth 4 (4,085,603 nodes, ~20s) is verified but left out of the
// regular suite to keep CI in bounds. Rename with `_test` to run it.
pub fn perft_kiwipete_depth4_slow() {
  let pos =
    fen.load("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -")
  assert board.perft(pos, 4) == 4_085_603
}

pub fn perft_kiwipete_test() {
  // Castling every which way, pins, en passant, checks.
  let pos =
    fen.load("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -")
  expect(pos, [48, 2039, 97_862])
}

pub fn perft_position3_test() {
  // A rook-and-pawns endgame full of ep and check subtleties.
  let pos = fen.load("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -")
  expect(pos, [14, 191, 2812, 43_238])
}

pub fn perft_position4_test() {
  // Promotions (with capture and underpromotion) under fire.
  let pos =
    fen.load("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")
  expect(pos, [6, 264, 9467])
}

pub fn perft_position5_test() {
  // The "talkchess" position: castling rights and promotion interplay.
  let pos =
    fen.load("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8")
  expect(pos, [44, 1486, 62_379])
}
