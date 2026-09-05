//// The chess board: pieces, attack detection, full FIDE legal move
//// generation (castling, en passant, promotion, pins and checks), and
//// `make_move`. Pure position rules only; turns, draws by repetition and
//// game results live in `chess/state`.
////
//// Squares are ints 0..63 with a1 = 0, b1 = 1, ... h8 = 63
//// (file = sq % 8, rank = sq / 8).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Color {
  White
  Black
}

pub type Kind {
  Pawn
  Knight
  Bishop
  Rook
  Queen
  King
}

pub type Piece {
  Piece(color: Color, kind: Kind)
}

pub type Board =
  Dict(Int, Piece)

pub type Castling {
  Castling(wk: Bool, wq: Bool, bk: Bool, bq: Bool)
}

pub type Position {
  Position(
    board: Board,
    to_move: Color,
    castling: Castling,
    /// The en-passant target square after a double pawn push (the square the
    /// capturing pawn would land on), whether or not a capture is possible.
    ep: Option(Int),
    /// Plies since the last capture or pawn move (the fifty-move counter).
    halfmove: Int,
  )
}

pub type Move {
  Move(from: Int, to: Int, promotion: Option(Kind))
}

/// What applying a move did, for events and token bookkeeping.
pub type MoveInfo {
  MoveInfo(
    piece: Piece,
    /// The captured piece and the square it stood on (which differs from
    /// `move.to` for en passant).
    captured: Option(#(Int, Piece)),
    /// The rook's from and to squares when the move castles.
    castle_rook: Option(#(Int, Int)),
    en_passant: Bool,
    promoted: Option(Kind),
  )
}

pub fn opposite(color: Color) -> Color {
  case color {
    White -> Black
    Black -> White
  }
}

pub fn color_name(color: Color) -> String {
  case color {
    White -> "white"
    Black -> "black"
  }
}

pub fn file(sq: Int) -> Int {
  sq % 8
}

pub fn rank(sq: Int) -> Int {
  sq / 8
}

pub fn square(file: Int, rank: Int) -> Int {
  rank * 8 + file
}

pub fn square_name(sq: Int) -> String {
  let assert Ok(letter) =
    string.split("abcdefgh", "") |> list.drop(file(sq)) |> list.first
  letter <> int.to_string(rank(sq) + 1)
}

pub fn parse_square(name: String) -> Result(Int, Nil) {
  case string.to_graphemes(name) {
    [f, r] -> {
      use file <- try(index_of("abcdefgh", f))
      use rank <- try(index_of("12345678", r))
      Ok(square(file, rank))
    }
    _ -> Error(Nil)
  }
}

fn try(r: Result(a, e), f: fn(a) -> Result(b, e)) -> Result(b, e) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}

fn index_of(letters: String, grapheme: String) -> Result(Int, Nil) {
  string.split(letters, "")
  |> list.index_map(fn(l, i) { #(l, i) })
  |> list.find(fn(pair) { pair.0 == grapheme })
  |> result_map(fn(pair) { pair.1 })
}

fn result_map(r: Result(a, e), f: fn(a) -> b) -> Result(b, e) {
  case r {
    Ok(v) -> Ok(f(v))
    Error(e) -> Error(e)
  }
}

// ---------- The initial position ----------

pub fn initial() -> Position {
  let back = [Rook, Knight, Bishop, Queen, King, Bishop, Knight, Rook]
  let board =
    list.index_fold(back, dict.new(), fn(board, kind, f) {
      board
      |> dict.insert(square(f, 0), Piece(White, kind))
      |> dict.insert(square(f, 1), Piece(White, Pawn))
      |> dict.insert(square(f, 7), Piece(Black, kind))
      |> dict.insert(square(f, 6), Piece(Black, Pawn))
    })
  Position(
    board: board,
    to_move: White,
    castling: Castling(True, True, True, True),
    ep: None,
    halfmove: 0,
  )
}

// ---------- Attack detection ----------

fn step(sq: Int, df: Int, dr: Int) -> Option(Int) {
  let f = file(sq) + df
  let r = rank(sq) + dr
  case f >= 0 && f < 8 && r >= 0 && r < 8 {
    True -> Some(square(f, r))
    False -> None
  }
}

const knight_deltas = [
  #(1, 2),
  #(2, 1),
  #(2, -1),
  #(1, -2),
  #(-1, -2),
  #(-2, -1),
  #(-2, 1),
  #(-1, 2),
]

const king_deltas = [
  #(1, 0),
  #(1, 1),
  #(0, 1),
  #(-1, 1),
  #(-1, 0),
  #(-1, -1),
  #(0, -1),
  #(1, -1),
]

const bishop_dirs = [#(1, 1), #(1, -1), #(-1, 1), #(-1, -1)]

const rook_dirs = [#(1, 0), #(-1, 0), #(0, 1), #(0, -1)]

/// The first occupied square walking from `sq` in direction `#(df, dr)`.
fn ray_first(board: Board, sq: Int, df: Int, dr: Int) -> Option(Piece) {
  case step(sq, df, dr) {
    None -> None
    Some(next) ->
      case dict.get(board, next) {
        Ok(piece) -> Some(piece)
        Error(_) -> ray_first(board, next, df, dr)
      }
  }
}

/// Is `sq` attacked by any piece of `by`?
pub fn attacked(board: Board, sq: Int, by: Color) -> Bool {
  let leaper = fn(deltas: List(#(Int, Int)), kind: Kind) {
    list.any(deltas, fn(d) {
      case step(sq, d.0, d.1) {
        Some(s) -> dict.get(board, s) == Ok(Piece(by, kind))
        None -> False
      }
    })
  }
  let slider = fn(dirs: List(#(Int, Int)), kind: Kind) {
    list.any(dirs, fn(d) {
      case ray_first(board, sq, d.0, d.1) {
        Some(Piece(color, k)) -> color == by && { k == kind || k == Queen }
        None -> False
      }
    })
  }
  // A pawn of `by` attacks `sq` from one rank towards its own side.
  let pawn_dr = case by {
    White -> -1
    Black -> 1
  }
  let pawn =
    list.any([-1, 1], fn(df) {
      case step(sq, df, pawn_dr) {
        Some(s) -> dict.get(board, s) == Ok(Piece(by, Pawn))
        None -> False
      }
    })
  pawn
  || leaper(knight_deltas, Knight)
  || leaper(king_deltas, King)
  || slider(bishop_dirs, Bishop)
  || slider(rook_dirs, Rook)
}

pub fn piece_at(pos: Position, sq: Int) -> Option(Piece) {
  case dict.get(pos.board, sq) {
    Ok(piece) -> Some(piece)
    Error(_) -> None
  }
}

pub fn king_square(board: Board, color: Color) -> Int {
  let assert [sq] =
    dict.to_list(board)
    |> list.filter_map(fn(entry) {
      case entry.1 == Piece(color, King) {
        True -> Ok(entry.0)
        False -> Error(Nil)
      }
    })
  sq
}

/// Is the side to move in check?
pub fn in_check(pos: Position) -> Bool {
  attacked(
    pos.board,
    king_square(pos.board, pos.to_move),
    opposite(pos.to_move),
  )
}

// ---------- Move generation ----------

fn promotions(from: Int, to: Int, to_rank: Int) -> List(Move) {
  case to_rank == 0 || to_rank == 7 {
    True ->
      list.map([Queen, Rook, Bishop, Knight], fn(kind) {
        Move(from, to, Some(kind))
      })
    False -> [Move(from, to, None)]
  }
}

fn pawn_moves(pos: Position, from: Int, color: Color) -> List(Move) {
  let dr = case color {
    White -> 1
    Black -> -1
  }
  let start_rank = case color {
    White -> 1
    Black -> 6
  }
  let empty = fn(sq) { dict.get(pos.board, sq) == Error(Nil) }
  let pushes = case step(from, 0, dr) {
    Some(one) ->
      case empty(one) {
        True -> {
          let single = promotions(from, one, rank(one))
          case rank(from) == start_rank, step(from, 0, dr * 2) {
            True, Some(two) ->
              case empty(two) {
                True -> [Move(from, two, None), ..single]
                False -> single
              }
            _, _ -> single
          }
        }
        False -> []
      }
    None -> []
  }
  let captures =
    list.flat_map([-1, 1], fn(df) {
      case step(from, df, dr) {
        Some(to) ->
          case dict.get(pos.board, to), pos.ep {
            Ok(Piece(c, _)), _ if c != color -> promotions(from, to, rank(to))
            Error(_), Some(ep) if ep == to -> [Move(from, to, None)]
            _, _ -> []
          }
        None -> []
      }
    })
  list.append(pushes, captures)
}

fn leaper_moves(
  pos: Position,
  from: Int,
  color: Color,
  deltas: List(#(Int, Int)),
) -> List(Move) {
  list.filter_map(deltas, fn(d) {
    case step(from, d.0, d.1) {
      Some(to) ->
        case dict.get(pos.board, to) {
          Ok(Piece(c, _)) if c == color -> Error(Nil)
          _ -> Ok(Move(from, to, None))
        }
      None -> Error(Nil)
    }
  })
}

fn slide(
  pos: Position,
  from: Int,
  color: Color,
  df: Int,
  dr: Int,
  at: Int,
  acc: List(Move),
) -> List(Move) {
  case step(at, df, dr) {
    None -> acc
    Some(to) ->
      case dict.get(pos.board, to) {
        Error(_) ->
          slide(pos, from, color, df, dr, to, [Move(from, to, None), ..acc])
        Ok(Piece(c, _)) if c != color -> [Move(from, to, None), ..acc]
        Ok(_) -> acc
      }
  }
}

fn slider_moves(
  pos: Position,
  from: Int,
  color: Color,
  dirs: List(#(Int, Int)),
) -> List(Move) {
  list.flat_map(dirs, fn(d) { slide(pos, from, color, d.0, d.1, from, []) })
}

fn piece_moves(pos: Position, from: Int, piece: Piece) -> List(Move) {
  let color = piece.color
  case piece.kind {
    Pawn -> pawn_moves(pos, from, color)
    Knight -> leaper_moves(pos, from, color, knight_deltas)
    King -> leaper_moves(pos, from, color, king_deltas)
    Bishop -> slider_moves(pos, from, color, bishop_dirs)
    Rook -> slider_moves(pos, from, color, rook_dirs)
    Queen -> slider_moves(pos, from, color, list.append(bishop_dirs, rook_dirs))
  }
}

/// Castling moves for the side to move, with every FIDE condition checked:
/// the right survives (king and that rook unmoved), the squares between are
/// empty, the king is not in check, and neither the square it crosses nor
/// the one it lands on is attacked.
fn castle_moves(pos: Position) -> List(Move) {
  let color = pos.to_move
  let enemy = opposite(color)
  let home = case color {
    White -> 0
    Black -> 7
  }
  let e = square(4, home)
  let has_king = dict.get(pos.board, e) == Ok(Piece(color, King))
  let empty = fn(files: List(Int)) {
    list.all(files, fn(f) { dict.get(pos.board, square(f, home)) == Error(Nil) })
  }
  let safe = fn(files: List(Int)) {
    !list.any(files, fn(f) { attacked(pos.board, square(f, home), enemy) })
  }
  let #(kingside, queenside) = case color {
    White -> #(pos.castling.wk, pos.castling.wq)
    Black -> #(pos.castling.bk, pos.castling.bq)
  }
  let rook_at = fn(f: Int) {
    dict.get(pos.board, square(f, home)) == Ok(Piece(color, Rook))
  }
  let short = case
    kingside && has_king && rook_at(7) && empty([5, 6]) && safe([4, 5, 6])
  {
    True -> [Move(e, square(6, home), None)]
    False -> []
  }
  let long = case
    queenside && has_king && rook_at(0) && empty([1, 2, 3]) && safe([4, 3, 2])
  {
    True -> [Move(e, square(2, home), None)]
    False -> []
  }
  list.append(short, long)
}

/// Every pseudo-legal move for the side to move (may leave the king in
/// check); castling is included already fully validated.
fn pseudo_moves(pos: Position) -> List(Move) {
  let own =
    dict.to_list(pos.board)
    |> list.filter(fn(entry) { { entry.1 }.color == pos.to_move })
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  list.append(
    list.flat_map(own, fn(entry) { piece_moves(pos, entry.0, entry.1) }),
    castle_moves(pos),
  )
}

/// Every legal move for the side to move: pseudo-legal moves that do not
/// leave their own king attacked.
pub fn legal_moves(pos: Position) -> List(Move) {
  let mover = pos.to_move
  let enemy = opposite(mover)
  let king = king_square(pos.board, mover)
  list.filter(pseudo_moves(pos), fn(move) {
    let #(next, _) = make_move(pos, move)
    let king_sq = case move.from == king {
      True -> move.to
      False -> king
    }
    !attacked(next.board, king_sq, enemy)
  })
}

/// Apply a move (assumed pseudo-legal). Returns the new position and what
/// happened for events and token bookkeeping.
pub fn make_move(pos: Position, move: Move) -> #(Position, MoveInfo) {
  let assert Ok(piece) = dict.get(pos.board, move.from)
  let color = piece.color
  let is_pawn = piece.kind == Pawn
  // En passant: a pawn moving diagonally onto the empty ep target square.
  let en_passant =
    is_pawn
    && Some(move.to) == pos.ep
    && file(move.from) != file(move.to)
    && dict.get(pos.board, move.to) == Error(Nil)
  let captured = case dict.get(pos.board, move.to) {
    Ok(victim) -> Some(#(move.to, victim))
    Error(_) ->
      case en_passant {
        True -> {
          let victim_sq = square(file(move.to), rank(move.from))
          case dict.get(pos.board, victim_sq) {
            Ok(victim) -> Some(#(victim_sq, victim))
            Error(_) -> None
          }
        }
        False -> None
      }
  }
  let placed = case move.promotion {
    Some(kind) -> Piece(color, kind)
    None -> piece
  }
  let castle_rook = case piece.kind == King, file(move.to) - file(move.from) {
    True, 2 -> Some(#(square(7, rank(move.from)), square(5, rank(move.from))))
    True, -2 -> Some(#(square(0, rank(move.from)), square(3, rank(move.from))))
    _, _ -> None
  }
  let board =
    pos.board
    |> dict.delete(move.from)
    |> fn(b) {
      case captured {
        Some(#(sq, _)) -> dict.delete(b, sq)
        None -> b
      }
    }
    |> dict.insert(move.to, placed)
    |> fn(b) {
      case castle_rook {
        Some(#(from, to)) -> {
          let assert Ok(rook) = dict.get(b, from)
          b |> dict.delete(from) |> dict.insert(to, rook)
        }
        None -> b
      }
    }
  let ep = case is_pawn, rank(move.to) - rank(move.from) {
    True, 2 -> Some(move.from + 8)
    True, -2 -> Some(move.from - 8)
    _, _ -> None
  }
  let halfmove = case is_pawn || captured != None {
    True -> 0
    False -> pos.halfmove + 1
  }
  let castling =
    pos.castling
    |> clear_castling(color, piece.kind, move.from)
    |> clear_rook_rights(move.to)
  #(
    Position(
      board: board,
      to_move: opposite(color),
      castling: castling,
      ep: ep,
      halfmove: halfmove,
    ),
    MoveInfo(
      piece: piece,
      captured: captured,
      castle_rook: castle_rook,
      en_passant: en_passant,
      promoted: move.promotion,
    ),
  )
}

fn clear_castling(c: Castling, color: Color, kind: Kind, from: Int) -> Castling {
  case kind, color {
    King, White -> Castling(..c, wk: False, wq: False)
    King, Black -> Castling(..c, bk: False, bq: False)
    Rook, _ -> clear_rook_rights(c, from)
    _, _ -> c
  }
}

/// A rook moving from, or any piece landing on, a rook home square kills
/// that right.
fn clear_rook_rights(c: Castling, sq: Int) -> Castling {
  case sq {
    0 -> Castling(..c, wq: False)
    7 -> Castling(..c, wk: False)
    56 -> Castling(..c, bq: False)
    63 -> Castling(..c, bk: False)
    _ -> c
  }
}

// ---------- Position identity (threefold repetition) ----------

/// The FIDE identity of a position: piece placement, side to move, castling
/// rights, and en-passant availability. Two positions with the same board
/// but different rights are different positions. The ep square only counts
/// when an en-passant capture is actually legal.
pub fn key(pos: Position) -> String {
  let squares =
    list.range(0, 63)
    |> list.map(fn(sq) {
      case dict.get(pos.board, sq) {
        Ok(piece) -> piece_letter(piece)
        Error(_) -> "-"
      }
    })
    |> string.concat
  let rights =
    string.concat([
      right(pos.castling.wk, "K"),
      right(pos.castling.wq, "Q"),
      right(pos.castling.bk, "k"),
      right(pos.castling.bq, "q"),
    ])
  let ep = case ep_capture_legal(pos) {
    True -> {
      let assert Some(sq) = pos.ep
      square_name(sq)
    }
    False -> "-"
  }
  squares <> " " <> color_name(pos.to_move) <> " " <> rights <> " " <> ep
}

fn right(on: Bool, letter: String) -> String {
  case on {
    True -> letter
    False -> ""
  }
}

/// Is some en-passant capture actually legal in this position?
fn ep_capture_legal(pos: Position) -> Bool {
  case pos.ep {
    None -> False
    Some(target) ->
      list.any(legal_moves(pos), fn(move) {
        move.to == target
        && dict.get(pos.board, move.from) == Ok(Piece(pos.to_move, Pawn))
        && file(move.from) != file(move.to)
      })
  }
}

pub fn piece_letter(piece: Piece) -> String {
  let letter = case piece.kind {
    Pawn -> "p"
    Knight -> "n"
    Bishop -> "b"
    Rook -> "r"
    Queen -> "q"
    King -> "k"
  }
  case piece.color {
    White -> string.uppercase(letter)
    Black -> letter
  }
}

// ---------- Dead positions ----------

/// True when no sequence of legal moves can lead to checkmate by either
/// side: K vs K, KB vs K, KN vs K, and any number of bishops (either color)
/// all standing on squares of one color.
pub fn dead_position(board: Board) -> Bool {
  let others =
    dict.to_list(board)
    |> list.filter(fn(entry) { { entry.1 }.kind != King })
  let heavy =
    list.any(others, fn(entry) {
      case { entry.1 }.kind {
        Pawn | Rook | Queen -> True
        _ -> False
      }
    })
  case heavy, others {
    True, _ -> False
    False, [] -> True
    False, [#(_, Piece(_, Knight))] -> True
    False, pieces -> {
      let bishops_only =
        list.all(pieces, fn(entry) { { entry.1 }.kind == Bishop })
      let square_colors =
        list.map(pieces, fn(entry) { { file(entry.0) + rank(entry.0) } % 2 })
        |> list.unique
      bishops_only && list.length(square_colors) == 1
    }
  }
}

/// Can this side possibly deliver checkmate by any series of legal moves?
/// Approximated for flag falls: a bare king never can, and neither side can
/// in a dead position. Anything else is treated as able to mate.
pub fn can_possibly_mate(board: Board, color: Color) -> Bool {
  let own_others =
    dict.to_list(board)
    |> list.any(fn(entry) {
      { entry.1 }.color == color && { entry.1 }.kind != King
    })
  own_others && !dead_position(board)
}

// ---------- Perft ----------

/// Move-generation node count to `depth`, the standard correctness proof.
pub fn perft(pos: Position, depth: Int) -> Int {
  case depth {
    0 -> 1
    1 -> list.length(legal_moves(pos))
    _ ->
      list.fold(legal_moves(pos), 0, fn(acc, move) {
        let #(next, _) = make_move(pos, move)
        acc + perft(next, depth - 1)
      })
  }
}
