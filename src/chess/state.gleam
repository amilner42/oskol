//// The chess game state: seats, the position, the token story, and every
//// way a game ends. Draws are automatic (a product decision, not claims):
//// threefold repetition, the fifty-move rule and dead positions end the
//// game the moment they occur.

import chess/board.{type Color, type Move, type Position, Black, White}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type EndReason {
  Checkmate
  Resignation
  Stalemate
  ThreefoldRepetition
  FiftyMoveRule
  DeadPosition
  /// A flag fell: a win for the opponent, or a draw when they cannot
  /// possibly mate (see `chess/engine.Flag`).
  FlagFall
}

pub type Phase {
  Playing
  WonBy(color: Color, reason: EndReason)
  Drawn(reason: EndReason)
}

pub type GameState {
  GameState(
    /// Seats in order: the first seat is White.
    seats: List(#(String, String)),
    position: Position,
    /// Square -> stable token id. A promoted pawn keeps its token id; its
    /// face changes with the piece on the square.
    tokens: Dict(Int, String),
    /// Position identity -> times seen, for threefold repetition.
    repetition: Dict(String, Int),
    last_move: Option(#(Int, Int)),
    /// Plies played.
    ply: Int,
    phase: Phase,
  )
}

/// What playing a move did, ready for events.
pub type Played {
  Played(
    state: GameState,
    info: board.MoveInfo,
    mover_token: String,
    captured_token: Option(String),
    rook_token: Option(#(String, Int, Int)),
    /// Is the new side to move in check (and the game still on)?
    check: Bool,
  )
}

pub fn new(seats: List(#(String, String))) -> GameState {
  let position = board.initial()
  GameState(
    seats: seats,
    position: position,
    tokens: initial_tokens(),
    repetition: dict.from_list([#(board.key(position), 1)]),
    last_move: None,
    ply: 0,
    phase: Playing,
  )
}

/// Deterministic token ids that survive moves: pawns are numbered by their
/// starting file (wp1 = a-pawn), doubled pieces by queenside first.
fn initial_tokens() -> Dict(Int, String) {
  let back = ["r1", "n1", "b1", "q", "k", "b2", "n2", "r2"]
  list.index_fold(back, dict.new(), fn(tokens, name, f) {
    let pawn = int_name(f + 1)
    tokens
    |> dict.insert(board.square(f, 0), "w" <> name)
    |> dict.insert(board.square(f, 1), "wp" <> pawn)
    |> dict.insert(board.square(f, 7), "b" <> name)
    |> dict.insert(board.square(f, 6), "bp" <> pawn)
  })
}

fn int_name(n: Int) -> String {
  int.to_string(n)
}

// ---------- Seats ----------

pub fn color_of(state: GameState, player_id: String) -> Result(Color, Nil) {
  case state.seats {
    [#(white, _), #(black, _)] if white == player_id -> {
      let _ = black
      Ok(White)
    }
    [_, #(black, _)] if black == player_id -> Ok(Black)
    _ -> Error(Nil)
  }
}

pub fn player_of(state: GameState, color: Color) -> String {
  case state.seats, color {
    [#(white, _), _], White -> white
    [_, #(black, _)], Black -> black
    _, _ -> ""
  }
}

pub fn name_of(state: GameState, player_id: String) -> String {
  case list.find(state.seats, fn(seat) { seat.0 == player_id }) {
    Ok(#(_, name)) -> name
    Error(_) -> player_id
  }
}

/// The player who must move now, while the game is on.
pub fn to_move(state: GameState) -> Option(String) {
  case state.phase {
    Playing -> Some(player_of(state, state.position.to_move))
    _ -> None
  }
}

// ---------- Moves ----------

pub fn legal_moves(state: GameState, player_id: String) -> List(Move) {
  case state.phase, color_of(state, player_id) {
    Playing, Ok(color) if color == state.position.to_move ->
      board.legal_moves(state.position)
    _, _ -> []
  }
}

pub fn play(
  state: GameState,
  player_id: String,
  move: Move,
) -> Result(Played, String) {
  use <- require(state.phase == Playing, "The game is over")
  use color <- seated(state, player_id)
  use <- require(color == state.position.to_move, "Not your turn")
  use <- require(
    list.contains(board.legal_moves(state.position), move),
    "Illegal move",
  )
  let #(position, info) = board.make_move(state.position, move)
  let assert Ok(mover_token) = dict.get(state.tokens, move.from)
  let captured_token = case info.captured {
    Some(#(sq, _)) ->
      case dict.get(state.tokens, sq) {
        Ok(token) -> Some(token)
        Error(_) -> None
      }
    None -> None
  }
  let tokens =
    state.tokens
    |> dict.delete(move.from)
    |> fn(t) {
      case info.captured {
        Some(#(sq, _)) -> dict.delete(t, sq)
        None -> t
      }
    }
    |> dict.insert(move.to, mover_token)
  let #(tokens, rook_token) = case info.castle_rook {
    Some(#(from, to)) -> {
      let assert Ok(rook) = dict.get(tokens, from)
      #(
        tokens |> dict.delete(from) |> dict.insert(to, rook),
        Some(#(rook, from, to)),
      )
    }
    None -> #(tokens, None)
  }
  // A capture or pawn move makes every earlier position unreachable, so the
  // repetition book restarts (halfmove reset marks exactly those moves).
  let seen = case position.halfmove {
    0 -> dict.new()
    _ -> state.repetition
  }
  let key = board.key(position)
  let count = case dict.get(seen, key) {
    Ok(n) -> n + 1
    Error(_) -> 1
  }
  let repetition = dict.insert(seen, key, count)
  let phase = ending(position, color, count)
  let next =
    GameState(
      ..state,
      position: position,
      tokens: tokens,
      repetition: repetition,
      last_move: Some(#(move.from, move.to)),
      ply: state.ply + 1,
      phase: phase,
    )
  Ok(Played(
    state: next,
    info: info,
    mover_token: mover_token,
    captured_token: captured_token,
    rook_token: rook_token,
    check: phase == Playing && board.in_check(position),
  ))
}

/// How the game stands after a move by `mover`: checkmate and stalemate
/// first, then the automatic draws.
fn ending(position: Position, mover: Color, repetitions: Int) -> Phase {
  case board.legal_moves(position) {
    [] ->
      case board.in_check(position) {
        True -> WonBy(mover, Checkmate)
        False -> Drawn(Stalemate)
      }
    _ -> {
      let dead = board.dead_position(position.board)
      case dead, position.halfmove >= 100, repetitions >= 3 {
        True, _, _ -> Drawn(DeadPosition)
        _, True, _ -> Drawn(FiftyMoveRule)
        _, _, True -> Drawn(ThreefoldRepetition)
        _, _, _ -> Playing
      }
    }
  }
}

// ---------- Resignation and flag fall ----------

pub fn resign(state: GameState, player_id: String) -> Result(GameState, String) {
  use <- require(state.phase == Playing, "The game is over")
  use color <- seated(state, player_id)
  Ok(GameState(..state, phase: WonBy(board.opposite(color), Resignation)))
}

/// A player's flag fell. FIDE: the game is lost on time unless the opponent
/// cannot possibly checkmate by any series of legal moves, in which case it
/// is a draw. Approximated by material: a bare king (or a dead position)
/// cannot mate; anything else wins.
pub fn flag(state: GameState, player_id: String) -> Result(GameState, String) {
  use <- require(state.phase == Playing, "The game is over")
  use color <- seated(state, player_id)
  let opponent = board.opposite(color)
  let phase = case board.can_possibly_mate(state.position.board, opponent) {
    True -> WonBy(opponent, FlagFall)
    False -> Drawn(FlagFall)
  }
  Ok(GameState(..state, phase: phase))
}

// ---------- Helpers ----------

fn require(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

fn seated(
  state: GameState,
  player_id: String,
  next: fn(Color) -> Result(a, String),
) -> Result(a, String) {
  case color_of(state, player_id) {
    Ok(color) -> next(color)
    Error(_) -> Error("Not a player in this game")
  }
}

pub fn reason_name(reason: EndReason) -> String {
  case reason {
    Checkmate -> "checkmate"
    Resignation -> "resignation"
    Stalemate -> "stalemate"
    ThreefoldRepetition -> "threefold_repetition"
    FiftyMoveRule -> "fifty_move_rule"
    DeadPosition -> "dead_position"
    FlagFall -> "flag_fall"
  }
}
