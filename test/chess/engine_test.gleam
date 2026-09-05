//// Chess through the contract: schemas, decoding, events, scenes, seeded
//// conformance playouts and replay determinism.

import chess/board
import chess/engine
import chess/game as chess
import chess/positions.{black, mv, state_from, white}
import chess/state
import gamekit/action
import gamekit/conformance
import gamekit/event
import gamekit/game.{Seat}
import gamekit/scene
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}

fn seats() {
  [Seat(white, "Alice"), Seat(black, "Bob")]
}

fn new_game() -> state.GameState {
  state.new(positions.seats())
}

// ---------- Schemas ----------

pub fn white_opens_with_twenty_moves_and_resign_test() {
  let s = new_game()
  let schemas = engine.legal(s, white)
  let moves = list.filter(schemas, fn(schema) { schema.name == "move" })
  assert list.length(moves) == 20
  assert list.any(schemas, fn(schema) { schema.name == "resign" })
  // Black may only resign; outsiders get nothing.
  assert list.map(engine.legal(s, black), fn(schema) { schema.name })
    == ["resign"]
  assert engine.legal(s, "ghost") == []
  assert engine.on_the_clock(s) == [white]
}

pub fn move_labels_read_like_chess_test() {
  let s = new_game()
  let labels = list.map(engine.legal(s, white), fn(schema) { schema.label })
  assert list.contains(labels, "e2 → e4")
  assert list.contains(labels, "N g1 → f3")
  let castles = state_from("r3k2r/8/8/8/8/8/8/R3K2R w KQkq -")
  let labels =
    list.map(engine.legal(castles, white), fn(schema) { schema.label })
  assert list.contains(labels, "O-O")
  assert list.contains(labels, "O-O-O")
}

pub fn promotions_are_distinct_candidates_test() {
  let s = state_from("4k3/P7/8/8/8/8/8/4K3 w - -")
  let promos =
    engine.legal(s, white)
    |> list.filter(fn(schema) {
      list.any(schema.params, fn(p) { p.name == "promotion" })
    })
  assert list.length(promos) == 4
  let labels = list.map(promos, fn(schema) { schema.label })
  assert list.contains(labels, "a7 → a8 = Q")
  assert list.contains(labels, "a7 → a8 = N")
}

pub fn en_passant_gets_its_own_label_test() {
  let s = state_from("4k3/8/8/8/2p5/8/3P4/4K3 w - -")
  let assert Ok(played) = state.play(s, white, mv("d2d4"))
  let labels = list.map(engine.legal(played.state, black), fn(s) { s.label })
  assert list.contains(labels, "c4 x d3 e.p.")
}

// ---------- Decoding and applying ----------

pub fn a_json_move_round_trips_test() {
  let s = new_game()
  let assert Ok(next) =
    conformance.apply_json(
      chess.game(),
      s,
      white,
      "{\"name\":\"move\",\"params\":{\"from\":\"e2\",\"to\":\"e4\"}}",
    )
  assert board.piece_at(next.position, sq("e4"))
    == Some(board.Piece(board.White, board.Pawn))
  assert state.to_move(next) == Some(black)
}

pub fn a_json_promotion_round_trips_test() {
  let s = state_from("4k3/P7/8/8/8/8/8/4K3 w - -")
  let assert Ok(next) =
    conformance.apply_json(
      chess.game(),
      s,
      white,
      "{\"name\":\"move\",\"params\":{\"from\":\"a7\",\"to\":\"a8\",\"promotion\":\"n\"}}",
    )
  assert board.piece_at(next.position, sq("a8"))
    == Some(board.Piece(board.White, board.Knight))
}

pub fn illegal_actions_are_rejected_without_change_test() {
  let s = new_game()
  assert engine.apply(s, black, engine.MovePiece(mv("e7e5")))
    == Error("Not your turn")
  assert engine.apply(s, white, engine.MovePiece(mv("e2e5")))
    == Error("Illegal move")
  assert engine.apply(s, "ghost", engine.Resign)
    == Error("Not a player in this game")
  let bad = chess.decode_action(incoming("teleport", "{}"))
  assert bad == Error("Unknown action: teleport")
  let assert Error(_) =
    conformance.apply_json(
      chess.game(),
      s,
      white,
      "{\"name\":\"move\",\"params\":{\"from\":\"e2\"}}",
    )
}

fn incoming(name: String, params_json: String) -> action.Incoming {
  let assert Ok(params) = conformance.parse(params_json)
  action.Incoming(name, params)
}

// ---------- Events ----------

pub fn a_capture_destroys_the_token_test() {
  let s = new_game()
  let assert Ok(#(s, _)) = engine.apply(s, white, engine.MovePiece(mv("e2e4")))
  let assert Ok(#(s, _)) = engine.apply(s, black, engine.MovePiece(mv("d7d5")))
  let assert Ok(#(_, events)) =
    engine.apply(s, white, engine.MovePiece(mv("e4d5")))
  // The black d-pawn (bp4) is destroyed out of 5:d, then the mover arrives.
  assert list.contains(events, event.destroyed("bp4", "5:d"))
  assert list.contains(events, event.moved("wp5", "4:e", "5:d"))
}

pub fn castling_emits_two_token_moves_test() {
  let s = state_from("r3k2r/8/8/8/8/8/8/R3K2R w KQkq -")
  let assert Ok(#(_, events)) =
    engine.apply(s, white, engine.MovePiece(mv("e1g1")))
  let token_moves =
    list.filter(events, fn(e) {
      case e {
        event.TokenMoved(_, _, _) -> True
        _ -> False
      }
    })
  assert list.length(token_moves) == 2
}

pub fn a_check_is_announced_test() {
  let s = new_game()
  let assert Ok(#(s, _)) = engine.apply(s, white, engine.MovePiece(mv("e2e4")))
  let assert Ok(#(s, _)) = engine.apply(s, black, engine.MovePiece(mv("f7f6")))
  let assert Ok(#(_, events)) =
    engine.apply(s, white, engine.MovePiece(mv("d1h5")))
  assert list.contains(events, event.Message("Bob is in check"))
}

pub fn resignation_ends_the_game_test() {
  let s = new_game()
  let assert Ok(#(next, events)) = engine.apply(s, white, engine.Resign)
  assert next.phase == state.WonBy(board.Black, state.Resignation)
  assert chess.outcome(next) == game.Finished([black])
  assert list.contains(events, event.PhaseChanged("game_over"))
  assert engine.on_the_clock(next) == []
  assert engine.legal(next, black) == []
  // Nothing more may happen.
  assert engine.apply(next, black, engine.Resign) == Error("The game is over")
}

// ---------- Scene ----------

pub fn the_scene_shows_the_full_board_to_everyone_test() {
  let s = new_game()
  let mine = chess.game().scene(s, scene.Player(white))
  let theirs = chess.game().scene(s, scene.Player(black))
  let watching = chess.game().scene(s, scene.Spectator)
  assert list.length(mine.zones) == 64
  assert count_tokens(mine) == 32
  assert count_tokens(theirs) == 32
  assert count_tokens(watching) == 32
  // Stable ids: the white king sits in zone 1:e.
  assert scene.zone_token_ids(mine, "1:e") == ["wk"]
  assert scene.zone_token_ids(mine, "8:d") == ["bq"]
  assert scene.zone_token_ids(mine, "2:a") == ["wp1"]
}

pub fn tokens_survive_moves_test() {
  let s = new_game()
  let assert Ok(#(s, _)) = engine.apply(s, white, engine.MovePiece(mv("g1f3")))
  let viewed = chess.game().scene(s, scene.Player(black))
  assert scene.zone_token_ids(viewed, "3:f") == ["wn2"]
  assert scene.zone_token_ids(viewed, "1:g") == []
}

fn count_tokens(viewed: scene.Scene) -> Int {
  list.fold(viewed.zones, 0, fn(acc, zone) { acc + list.length(zone.tokens) })
}

// ---------- Conformance ----------

fn invariant(s: state.GameState) -> Result(Nil, String) {
  let pieces = dict.to_list(s.position.board)
  let kings = fn(color) {
    list.filter(pieces, fn(entry) { entry.1 == board.Piece(color, board.King) })
    |> list.length
  }
  let token_squares = dict.to_list(s.tokens) |> list.map(fn(entry) { entry.0 })
  let piece_squares = list.map(pieces, fn(entry) { entry.0 })
  let token_ids = dict.to_list(s.tokens) |> list.map(fn(entry) { entry.1 })
  case
    kings(board.White) == 1 && kings(board.Black) == 1,
    list.sort(token_squares, int.compare)
    == list.sort(piece_squares, int.compare),
    list.length(list.unique(token_ids)) == list.length(token_ids)
  {
    False, _, _ -> Error("a king went missing")
    _, False, _ -> Error("tokens out of sync with pieces")
    _, _, False -> Error("duplicate token ids")
    _, _, _ -> Ok(Nil)
  }
}

pub fn random_games_terminate_by_the_automatic_rules_test() {
  list.each(list.range(1, 10), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        chess.game(),
        "standard",
        seats(),
        seed,
        6000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
    assert report.state.phase != state.Playing
  })
}

pub fn replay_is_deterministic_test() {
  let assert Ok(report) =
    conformance.random_playout_with(
      chess.game(),
      "standard",
      seats(),
      42,
      6000,
      invariant,
      conformance.Options(exclude: ["resign"]),
    )
  let assert Ok(replayed) =
    conformance.replay(chess.game(), "standard", seats(), 42, report.steps)
  assert conformance.fingerprint(chess.game(), replayed, seats())
    == conformance.fingerprint(chess.game(), report.state, seats())
}

fn sq(name: String) -> Int {
  let assert Ok(square) = board.parse_square(name)
  square
}
