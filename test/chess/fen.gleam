//// Test-only FEN loader: builds a `chess/board.Position` from a FEN string
//// so rule and perft tests can spell out arbitrary positions.

import chess/board.{
  type Piece, Bishop, Black, Castling, King, Knight, Pawn, Piece, Position,
  Queen, Rook, White,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn position(fen: String) -> Result(board.Position, String) {
  case string.split(fen, " ") {
    [placement, side, castling, ep, ..rest] -> {
      use pieces <- result.try(parse_placement(placement))
      use to_move <- result.try(case side {
        "w" -> Ok(White)
        "b" -> Ok(Black)
        _ -> Error("Bad side: " <> side)
      })
      use ep_square <- result.try(case ep {
        "-" -> Ok(None)
        name ->
          board.parse_square(name)
          |> result.map(Some)
          |> result.replace_error("Bad ep square: " <> name)
      })
      let halfmove = case rest {
        [h, ..] -> int.parse(h) |> result.unwrap(0)
        [] -> 0
      }
      Ok(Position(
        board: pieces,
        to_move: to_move,
        castling: Castling(
          wk: string.contains(castling, "K"),
          wq: string.contains(castling, "Q"),
          bk: string.contains(castling, "k"),
          bq: string.contains(castling, "q"),
        ),
        ep: ep_square,
        halfmove: halfmove,
      ))
    }
    _ -> Error("Bad FEN: " <> fen)
  }
}

/// A position that must parse; panics otherwise.
pub fn load(fen: String) -> board.Position {
  let assert Ok(pos) = position(fen)
  pos
}

fn parse_placement(placement: String) -> Result(board.Board, String) {
  let ranks = string.split(placement, "/")
  case list.length(ranks) {
    8 ->
      ranks
      |> list.index_fold(Ok(dict.new()), fn(acc, rank_text, i) {
        use pieces <- result.try(acc)
        parse_rank(pieces, rank_text, 7 - i)
      })
    _ -> Error("Bad placement: " <> placement)
  }
}

fn parse_rank(
  pieces: board.Board,
  text: String,
  rank: Int,
) -> Result(board.Board, String) {
  let outcome =
    string.to_graphemes(text)
    |> list.fold(Ok(#(pieces, 0)), fn(acc, grapheme) {
      use #(pieces, file) <- result.try(acc)
      case int.parse(grapheme) {
        Ok(n) -> Ok(#(pieces, file + n))
        Error(_) -> {
          use piece <- result.try(parse_piece(grapheme))
          Ok(#(dict.insert(pieces, board.square(file, rank), piece), file + 1))
        }
      }
    })
  use #(pieces, file) <- result.try(outcome)
  case file {
    8 -> Ok(pieces)
    _ -> Error("Bad rank: " <> text)
  }
}

fn parse_piece(letter: String) -> Result(Piece, String) {
  case letter {
    "P" -> Ok(Piece(White, Pawn))
    "N" -> Ok(Piece(White, Knight))
    "B" -> Ok(Piece(White, Bishop))
    "R" -> Ok(Piece(White, Rook))
    "Q" -> Ok(Piece(White, Queen))
    "K" -> Ok(Piece(White, King))
    "p" -> Ok(Piece(Black, Pawn))
    "n" -> Ok(Piece(Black, Knight))
    "b" -> Ok(Piece(Black, Bishop))
    "r" -> Ok(Piece(Black, Rook))
    "q" -> Ok(Piece(Black, Queen))
    "k" -> Ok(Piece(Black, King))
    _ -> Error("Bad piece: " <> letter)
  }
}
