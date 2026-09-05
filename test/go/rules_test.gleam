//// Engine-level rules in controlled positions: turn order, ko, positional
//// superko, snapback, passing, resignation, timeouts, decoding.

import gamekit/action
import gamekit/conformance
import gamekit/event
import gamekit/game
import gamekit/scene
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import go/board.{Black, White}
import go/engine
import go/game as go
import go/helpers
import go/state

const superko_error = "That move would repeat an earlier board position"

pub fn black_moves_first_test() {
  let s = helpers.new_game("9x9")
  assert state.to_move(s) == Some("p1")
  assert state.color_of(s, "p1") == Ok(Black)
  assert state.color_of(s, "p2") == Ok(White)
  // Black may place (all 81 points) or pass or resign; white only resign.
  let names = list.map(engine.legal(s, "p1"), fn(schema) { schema.name })
  assert names == ["place", "pass", "resign"]
  assert list.map(engine.legal(s, "p2"), fn(schema) { schema.name })
    == ["resign"]
  let assert [action.Schema("place", _, [action.Param("point", kind)]), ..] =
    engine.legal(s, "p1")
  let assert action.Select("board", candidates, 1, 1) = kind
  assert list.length(candidates) == 81
  assert engine.on_the_clock(s) == ["p1"]
}

pub fn placement_emits_stone_created_and_passes_the_turn_test() {
  let s = helpers.new_game("9x9")
  let assert Ok(#(s2, events)) = engine.apply(s, "p1", engine.Place("p4-4"))
  assert state.to_move(s2) == Some("p2")
  assert list.any(events, fn(e) { e == event.created("s1", "board") })
  assert list.any(events, fn(e) {
    case e {
      event.Custom("turn_started", _) -> True
      _ -> False
    }
  })
  // The stone shows up in every viewer's scene with its color.
  let viewed = go.game().scene(s2, scene.Player("p2"))
  assert scene.has_token(viewed, "s1")
  let spectator = go.game().scene(s2, scene.Spectator)
  assert scene.has_token(spectator, "s1")
}

pub fn out_of_turn_and_bad_points_are_rejected_test() {
  let s = helpers.new_game("9x9")
  assert engine.apply(s, "p2", engine.Place("p0-0")) == Error("Not your turn")
  assert engine.apply(s, "p2", engine.Pass) == Error("Not your turn")
  assert engine.apply(s, "p1", engine.Place("p9-9"))
    == Error("Invalid point: p9-9")
  assert engine.apply(s, "p1", engine.Place("nope"))
    == Error("Invalid point: nope")
  let assert Ok(#(s2, _)) = engine.apply(s, "p1", engine.Place("p4-4"))
  assert engine.apply(s2, "p2", engine.Place("p4-4"))
    == Error("That point is occupied")
  let assert Error(_) = engine.apply(s2, "ghost", engine.Place("p0-0"))
}

fn ko_rows() -> List(String) {
  [
    ".bw......",
    "bw.w.....",
    ".bw......",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
  ]
}

pub fn simple_ko_is_forbidden_immediately_test() {
  let s = helpers.mid_game(ko_rows(), Black)
  // Black takes the ko: (2,1) captures the white stone at (1,1).
  let assert Ok(#(s2, events)) = engine.apply(s, "p1", engine.Place("p2-1"))
  assert list.any(events, fn(e) {
    case e {
      event.TokenMoved(_, Some("board"), None) -> True
      _ -> False
    }
  })
  assert state.captured_by(s2, "p1") == 1
  // White may not recapture at once: that recreates the previous position.
  assert engine.apply(s2, "p2", engine.Place("p1-1")) == Error(superko_error)
  // The candidate list agrees.
  assert !list.contains(state.legal_point_ids(s2, "p2"), "p1-1")
}

pub fn ko_is_legal_after_an_intervening_move_elsewhere_test() {
  let s = helpers.mid_game(ko_rows(), Black)
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p2-1"))
  // White plays a ko threat elsewhere, black answers elsewhere.
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Place("p8-8"))
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p0-8"))
  // Now the recapture creates a position never seen before.
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Place("p1-1"))
  assert board.stone_at(s.board, board.index(s.board, 1, 1)) != Error(Nil)
  assert board.stone_at(s.board, board.index(s.board, 2, 1)) == Error(Nil)
}

pub fn superko_is_positional_not_situational_test() {
  // The history records positions only: no notion of who was to move is
  // attached, so recreating a position with the other player to move is
  // just as forbidden. Inject a position black's own move would recreate.
  let s = helpers.mid_game(ko_rows(), Black)
  let assert Ok(#(with_stone, _)) =
    board.place(s.board, board.index(s.board, 4, 4), Black)
  let s =
    state.GameState(
      ..s,
      history: set.insert(s.history, board.canonical(with_stone)),
    )
  assert engine.apply(s, "p1", engine.Place("p4-4")) == Error(superko_error)
  assert !list.contains(state.legal_point_ids(s, "p1"), "p4-4")
}

fn double_ko_rows() -> List(String) {
  // Two ko shapes: ko1 top left (white stone at (1,1) in atari at (2,1)),
  // ko2 middle right (white stone at (6,5) in atari at (7,5)).
  [
    ".bw......",
    "bw.w.....",
    ".bw......",
    ".........",
    "......bw.",
    ".....bw.w",
    "......bw.",
    ".........",
    ".........",
  ]
}

pub fn positional_superko_stops_a_longer_double_ko_cycle_test() {
  let s = helpers.mid_game(double_ko_rows(), Black)
  // Black takes ko1.
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p2-1"))
  // White passes rather than answering.
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Pass)
  // Black takes ko2 as well.
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p7-5"))
  // White retakes ko1: a position never seen (ko2 has changed). Legal.
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Place("p1-1"))
  // Black passes.
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Pass)
  let assert state.Playing(_) = s.phase
  // White retaking ko2 would recreate the starting position, six plies
  // back, which stood with the other player to move. A simple ko rule
  // would allow it; positional superko forbids it.
  assert engine.apply(s, "p2", engine.Place("p6-5")) == Error(superko_error)
  assert !list.contains(state.legal_point_ids(s, "p2"), "p6-5")
  // White is not stuck: any other point is fine.
  let assert Ok(#(_, _)) = engine.apply(s, "p2", engine.Place("p0-8"))
}

pub fn snapback_is_a_legal_immediate_recapture_test() {
  // Play the whole snapback through the engine from an empty board.
  let s = helpers.new_game("9x9")
  let moves = [
    #("p1", "p1-1"),
    #("p2", "p2-0"),
    #("p1", "p2-1"),
    #("p2", "p0-1"),
    #("p1", "p3-0"),
    #("p2", "p4-4"),
    // Black sacrifices a stone in the corner...
    #("p1", "p0-0"),
  ]
  let s =
    list.fold(moves, s, fn(s, move) {
      let assert Ok(#(next, _)) = engine.apply(s, move.0, engine.Place(move.1))
      next
    })
  // ...white captures it...
  let assert Ok(#(s, events)) = engine.apply(s, "p2", engine.Place("p1-0"))
  assert state.captured_by(s, "p2") == 1
  assert list.any(events, fn(e) {
    case e {
      event.Custom("captured", _) -> True
      _ -> False
    }
  })
  // ...and black immediately recaptures the two-stone white group by
  // replaying the same point. Not ko: the position is new.
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p0-0"))
  assert state.captured_by(s, "p1") == 2
  assert board.stone_at(s.board, board.index(s.board, 1, 0)) == Error(Nil)
  assert board.stone_at(s.board, board.index(s.board, 2, 0)) == Error(Nil)
  assert board.stone_at(s.board, board.index(s.board, 0, 0)) == Ok(Black)
}

pub fn a_single_pass_changes_nothing_but_the_turn_test() {
  let s = helpers.new_game("9x9")
  let assert Ok(#(s2, events)) = engine.apply(s, "p1", engine.Pass)
  assert s2.passes == 1
  assert state.to_move(s2) == Some("p2")
  let assert state.Playing(_) = s2.phase
  assert list.any(events, fn(e) {
    case e {
      event.Custom("passed", _) -> True
      _ -> False
    }
  })
  // A placement resets the pass count.
  let assert Ok(#(s3, _)) = engine.apply(s2, "p2", engine.Place("p4-4"))
  assert s3.passes == 0
}

pub fn two_consecutive_passes_end_and_score_the_game_test() {
  let s = helpers.new_game("9x9")
  let assert Ok(#(s, _)) = engine.apply(s, "p1", engine.Place("p4-4"))
  let assert Ok(#(s, _)) = engine.apply(s, "p2", engine.Pass)
  let assert Ok(#(s, events)) = engine.apply(s, "p1", engine.Pass)
  let assert state.Finished(Black) = s.phase
  assert go.outcome(s) == game.Finished(["p1"])
  assert list.contains(events, event.PhaseChanged("game_over"))
  assert list.any(events, fn(e) {
    case e {
      event.Custom("scored", _) -> True
      _ -> False
    }
  })
  assert list.any(events, fn(e) {
    case e {
      event.Custom("game_won", _) -> True
      _ -> False
    }
  })
  // 81 to 0 + 6.5: doubled scores 162 and 13.
  assert s.final_score2 == Some(#(162, 13))
  // Nothing is legal once the game is over.
  assert engine.legal(s, "p1") == []
  assert engine.legal(s, "p2") == []
  assert engine.on_the_clock(s) == []
  assert engine.apply(s, "p1", engine.Pass) == Error("The game is over")
  assert engine.apply(s, "p2", engine.Place("p0-0"))
    == Error("The game is over")
}

pub fn resignation_ends_the_game_immediately_test() {
  let s = helpers.new_game("9x9")
  // The player to move may resign...
  let assert Ok(#(s2, events)) = engine.apply(s, "p1", engine.Resign)
  let assert state.Finished(White) = s2.phase
  assert go.outcome(s2) == game.Finished(["p2"])
  assert list.contains(events, event.PhaseChanged("game_over"))
  // ...and so may the player who is waiting.
  let assert Ok(#(s3, _)) = engine.apply(s, "p2", engine.Resign)
  let assert state.Finished(Black) = s3.phase
  assert go.outcome(s3) == game.Finished(["p1"])
  // But not once the game is over.
  assert engine.apply(s2, "p1", engine.Resign) == Error("The game is over")
}

pub fn a_timeout_forfeits_in_any_state_test() {
  let g = go.game()
  let s = helpers.new_game("9x9")
  assert g.timeout(s, "p1") == game.Forfeit
  assert g.timeout(s, "p2") == game.Forfeit
}

pub fn decode_action_accepts_string_and_list_points_test() {
  let decode = fn(text) {
    let assert Ok(raw) = conformance.parse(text)
    let assert Ok(incoming) = action.decode_incoming(raw)
    go.decode_action(incoming)
  }
  assert decode("{\"name\":\"pass\"}") == Ok(engine.Pass)
  assert decode("{\"name\":\"resign\"}") == Ok(engine.Resign)
  assert decode("{\"name\":\"place\",\"params\":{\"point\":\"p1-2\"}}")
    == Ok(engine.Place("p1-2"))
  assert decode("{\"name\":\"place\",\"params\":{\"point\":[\"p1-2\"]}}")
    == Ok(engine.Place("p1-2"))
  let assert Error(_) =
    decode("{\"name\":\"place\",\"params\":{\"point\":[\"p1-2\",\"p2-2\"]}}")
  let assert Error(_) = decode("{\"name\":\"place\",\"params\":{}}")
  let assert Error(_) = decode("{\"name\":\"jump\"}")
}
