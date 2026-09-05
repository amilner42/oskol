//// Chess actions, events, legal schemas and clocks.

import chess/board.{
  type Kind, type Move, Bishop, King, Knight, Pawn, Queen, Rook,
}
import chess/state.{type GameState}
import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const board_zone = "board"

pub type Action {
  MovePiece(move: Move)
  Resign
  /// Applied for a player by the framework when their clock runs out; never
  /// offered as a legal action. A flag fall is a win for the opponent unless
  /// they cannot possibly checkmate, in which case it is a draw (FIDE 6.9,
  /// approximated by material; see `state.flag`).
  Flag
}

pub fn apply(
  state: GameState,
  player_id: String,
  action: Action,
) -> Result(#(GameState, List(Event)), String) {
  case action {
    Resign -> {
      use next <- result.try(state.resign(state, player_id))
      Ok(
        #(next, [
          event.Custom(
            "resigned",
            json.object([#("player_id", json.string(player_id))]),
          ),
          ..end_events(next)
        ]),
      )
    }
    Flag -> {
      use next <- result.try(state.flag(state, player_id))
      Ok(#(next, end_events(next)))
    }
    MovePiece(move) -> {
      use played <- result.try(state.play(state, player_id, move))
      let next = played.state
      let capture = case played.captured_token, played.info.captured {
        Some(token), Some(_) -> [event.destroyed(token, board_zone)]
        _, _ -> []
      }
      let rook = case played.rook_token {
        Some(#(token, _, _)) -> [event.moved(token, board_zone, board_zone)]
        None -> []
      }
      let promotion = case played.info.promoted {
        Some(kind) -> [
          event.Custom(
            "promoted",
            json.object([
              #("token", json.string(played.mover_token)),
              #("piece", json.string(kind_name(kind))),
            ]),
          ),
        ]
        None -> []
      }
      let check = case played.check, state.to_move(next) {
        True, Some(id) -> [
          event.Custom("check", json.object([#("player_id", json.string(id))])),
          event.Message(state.name_of(next, id) <> " is in check"),
        ]
        _, _ -> []
      }
      let ending = case next.phase {
        state.Playing -> turn_started(next)
        _ -> end_events(next)
      }
      Ok(#(
        next,
        list.flatten([
          [
            event.Custom(
              "moved",
              json.object([
                #("player_id", json.string(player_id)),
                #("from", json.string(board.square_name(move.from))),
                #("to", json.string(board.square_name(move.to))),
                #("piece", json.string(kind_name(played.info.piece.kind))),
                #("capture", json.bool(played.info.captured != None)),
                #("en_passant", json.bool(played.info.en_passant)),
                #("castle", json.bool(played.rook_token != None)),
                #(
                  "promotion",
                  json.nullable(played.info.promoted, fn(k) {
                    json.string(kind_name(k))
                  }),
                ),
              ]),
            ),
          ],
          capture,
          [
            event.moved(played.mover_token, board_zone, board_zone),
          ],
          rook,
          promotion,
          check,
          ending,
        ]),
      ))
    }
  }
}

fn turn_started(state: GameState) -> List(Event) {
  case state.to_move(state) {
    Some(id) -> [
      event.Custom(
        "turn_started",
        json.object([#("player_id", json.string(id))]),
      ),
    ]
    None -> []
  }
}

fn end_events(state: GameState) -> List(Event) {
  let describe = fn(fields: List(#(String, Json)), text: String) {
    [
      event.Custom("game_over", json.object(fields)),
      event.Message(text),
      event.PhaseChanged("game_over"),
    ]
  }
  case state.phase {
    state.WonBy(color, reason) -> {
      let winner = state.player_of(state, color)
      describe(
        [
          #("result", json.string("win")),
          #("winner_id", json.string(winner)),
          #("reason", json.string(state.reason_name(reason))),
        ],
        state.name_of(state, winner) <> " wins by " <> reason_text(reason),
      )
    }
    state.Drawn(reason) ->
      describe(
        [
          #("result", json.string("draw")),
          #("reason", json.string(state.reason_name(reason))),
        ],
        "Draw by " <> reason_text(reason),
      )
    state.Playing -> []
  }
}

fn reason_text(reason: state.EndReason) -> String {
  case reason {
    state.Checkmate -> "checkmate"
    state.Resignation -> "resignation"
    state.Stalemate -> "stalemate"
    state.ThreefoldRepetition -> "threefold repetition"
    state.FiftyMoveRule -> "the fifty-move rule"
    state.DeadPosition -> "insufficient material"
    state.FlagFall -> "flag fall"
  }
}

// ---------- Legal schemas ----------

/// One schema per legal move (promotions are distinct candidates), plus
/// resign for both seated players while the game is on.
pub fn legal(state: GameState, player_id: String) -> List(Schema) {
  let resign = case
    state.phase == state.Playing
    && state.color_of(state, player_id) != Error(Nil)
  {
    True -> [action.simple("resign", "Resign")]
    False -> []
  }
  let moves =
    state.legal_moves(state, player_id)
    |> list.map(fn(move) {
      let from = board.square_name(move.from)
      let to = board.square_name(move.to)
      let base = [
        action.choice("from", [#(from, from)]),
        action.choice("to", [#(to, to)]),
      ]
      let params = case move.promotion {
        Some(kind) ->
          list.append(base, [
            action.choice("promotion", [
              #(promo_id(kind), kind_label(kind)),
            ]),
          ])
        None -> base
      }
      action.Schema("move", label(state, move), params)
    })
  list.append(moves, resign)
}

/// A human label: "N g1 → f3", "e5 x d6 e.p.", "O-O", "e7 → e8 = Q".
pub fn label(state: GameState, move: Move) -> String {
  case dict_kind(state, move.from) {
    Some(King) ->
      case board.file(move.to) - board.file(move.from) {
        2 -> "O-O"
        -2 -> "O-O-O"
        _ -> plain_label(state, move)
      }
    _ -> plain_label(state, move)
  }
}

fn plain_label(state: GameState, move: Move) -> String {
  let piece = case dict_kind(state, move.from) {
    Some(Pawn) | None -> ""
    Some(kind) -> kind_letter(kind) <> " "
  }
  let target_taken = case board.piece_at(state.position, move.to) {
    Some(_) -> True
    None -> False
  }
  let en_passant =
    dict_kind(state, move.from) == Some(Pawn)
    && board.file(move.from) != board.file(move.to)
    && !target_taken
  let joiner = case target_taken || en_passant {
    True -> " x "
    False -> " → "
  }
  let suffix = case move.promotion {
    Some(kind) -> " = " <> kind_letter(kind)
    None ->
      case en_passant {
        True -> " e.p."
        False -> ""
      }
  }
  string.concat([
    piece,
    board.square_name(move.from),
    joiner,
    board.square_name(move.to),
    suffix,
  ])
}

fn dict_kind(state: GameState, sq: Int) -> Option(Kind) {
  case board.piece_at(state.position, sq) {
    Some(piece) -> Some(piece.kind)
    None -> None
  }
}

// ---------- Names ----------

pub fn kind_name(kind: Kind) -> String {
  case kind {
    Pawn -> "pawn"
    Knight -> "knight"
    Bishop -> "bishop"
    Rook -> "rook"
    Queen -> "queen"
    King -> "king"
  }
}

fn kind_letter(kind: Kind) -> String {
  case kind {
    Pawn -> ""
    Knight -> "N"
    Bishop -> "B"
    Rook -> "R"
    Queen -> "Q"
    King -> "K"
  }
}

pub fn promo_id(kind: Kind) -> String {
  case kind {
    Queen -> "q"
    Rook -> "r"
    Bishop -> "b"
    Knight -> "n"
    _ -> ""
  }
}

pub fn parse_promo(id: String) -> Result(Kind, Nil) {
  case id {
    "q" -> Ok(Queen)
    "r" -> Ok(Rook)
    "b" -> Ok(Bishop)
    "n" -> Ok(Knight)
    _ -> Error(Nil)
  }
}

fn kind_label(kind: Kind) -> String {
  case kind {
    Queen -> "Queen"
    Rook -> "Rook"
    Bishop -> "Bishop"
    Knight -> "Knight"
    Pawn -> "Pawn"
    King -> "King"
  }
}

/// Only the player to move is on the clock.
pub fn on_the_clock(state: GameState) -> List(String) {
  case state.to_move(state) {
    Some(id) -> [id]
    None -> []
  }
}
