//// Backgammon actions, events, legal schemas and clocks.

import backgammon/board.{type Loc}
import backgammon/state.{type GameState}
import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type Action {
  Roll
  /// Stage a move on your own board.
  MoveChecker(from: Loc, to: Loc)
  /// Take back the last staged move.
  Undo
  /// Commit the staged moves and end the turn.
  Play
  Double
  Take
  Drop
  Resign
}

pub const dice_zone = "dice"

fn custom(kind: String, fields: List(#(String, Json))) -> Event {
  event.Custom(kind, json.object(fields))
}

fn turn_started(state: GameState) -> List(Event) {
  case state.to_move(state) {
    Some(id) -> [custom("turn_started", [#("player_id", json.string(id))])]
    None -> []
  }
}

pub fn apply(
  state: GameState,
  player_id: String,
  action: Action,
) -> Result(#(GameState, List(Event)), String) {
  case action {
    Double -> {
      use next <- result.try(state.double(state, player_id))
      Ok(
        #(next, [
          custom("double_offered", [
            #("player_id", json.string(player_id)),
            #("value", json.int(state.cube_value * 2)),
          ]),
        ]),
      )
    }
    Take -> {
      use next <- result.try(state.take(state, player_id))
      Ok(
        #(next, [
          custom("double_taken", [
            #("player_id", json.string(player_id)),
            #("value", json.int(next.cube_value)),
          ]),
          ..turn_started(next)
        ]),
      )
    }
    Drop -> {
      use #(next, end) <- result.try(state.drop(state, player_id))
      Ok(
        #(next, [
          custom("double_dropped", [#("player_id", json.string(player_id))]),
          ..end_events(state, next, end)
        ]),
      )
    }
    Resign -> {
      use #(next, end) <- result.try(state.resign(state, player_id))
      Ok(
        #(next, [
          custom("resigned", [#("player_id", json.string(player_id))]),
          ..end_events(state, next, end)
        ]),
      )
    }
    Roll -> {
      use #(next, dice) <- result.try(state.roll(state, player_id))
      let rolled =
        custom("dice_rolled", [
          #("player_id", json.string(player_id)),
          #("dice", json.array(dice, json.int)),
        ])
      let events = case next.phase {
        state.Rolling(_) -> [
          rolled,
          custom("no_moves", [#("player_id", json.string(player_id))]),
          ..turn_started(next)
        ]
        _ -> [rolled]
      }
      Ok(#(next, events))
    }
    MoveChecker(from, to) -> {
      use #(next, _staged) <- result.try(state.stage(state, player_id, from, to))
      // Staging is private: the opponent only learns that the mover is thinking.
      Ok(
        #(next, [
          custom("move_staged", [
            #("player_id", json.string(player_id)),
            #("dice_left", json.int(list.length(state.dice_left(next)))),
          ]),
        ]),
      )
    }
    Undo -> {
      use #(next, _undone) <- result.try(state.undo(state, player_id))
      Ok(
        #(next, [
          custom("move_undone", [#("player_id", json.string(player_id))]),
        ]),
      )
    }
    Play -> {
      use played <- result.try(state.play(state, player_id))
      let next = played.state
      let opponent_id = case
        list.find(state.order, fn(id) { id != player_id })
      {
        Ok(id) -> id
        Error(_) -> ""
      }
      let move_events =
        list.flat_map(played.moves, fn(staged) {
          let m = staged.move
          let moved = [
            custom("checker_moved", [
              #("player_id", json.string(player_id)),
              #("checker", json.string(staged.mover)),
              #("from", json.string(board.loc_id(m.from))),
              #("to", json.string(board.loc_id(m.to))),
              #("die", json.int(m.die)),
            ]),
            event.moved(
              staged.mover,
              board.zone_id(m.from, player_id),
              board.zone_id(m.to, player_id),
            ),
          ]
          case staged.hit {
            Some(checker) ->
              list.append(moved, [
                custom("hit", [
                  #("player_id", json.string(opponent_id)),
                  #("checker", json.string(checker)),
                ]),
                event.moved(
                  checker,
                  board.zone_id(m.to, opponent_id),
                  board.zone_id(board.Bar, opponent_id),
                ),
              ])
            None -> moved
          }
        })
      let pips = case state.color_of(state, player_id) {
        Ok(color) -> [
          event.CounterChanged(
            player_id,
            "pips",
            board.pip_count(state.turn_board, color),
            board.pip_count(next.turn_board, color),
          ),
        ]
        Error(_) -> []
      }
      let ending = case played.game_end {
        Some(end) -> end_events(state, next, end)
        None -> turn_started(next)
      }
      Ok(#(
        next,
        list.flatten([
          [
            custom("turn_played", [
              #("player_id", json.string(player_id)),
              #("moves", json.int(list.length(played.moves))),
            ]),
          ],
          move_events,
          pips,
          ending,
        ]),
      ))
    }
  }
}

/// Events for a finished game: the result, the score change, and either the
/// end of the match or the start of the next game.
fn end_events(
  before: GameState,
  next: GameState,
  end: state.GameEnd,
) -> List(Event) {
  let won =
    custom("game_won", [
      #("player_id", json.string(end.winner)),
      #("kind", json.string(state.end_kind_name(end.kind))),
      #("points", json.int(end.points)),
      #("cube", json.int(end.cube)),
      #(
        "scores",
        json.object(
          list.map(next.order, fn(id) {
            #(id, json.int(state.score_of(next, id)))
          }),
        ),
      ),
    ])
  let score_change =
    event.CounterChanged(
      end.winner,
      "score",
      state.score_of(before, end.winner),
      state.score_of(next, end.winner),
    )
  case end.match_over {
    True -> [
      won,
      score_change,
      custom("match_over", [#("winner", json.string(end.winner))]),
      event.PhaseChanged("game_over"),
    ]
    False -> [
      won,
      score_change,
      custom("new_game", [
        #("game_number", json.int(next.game_number)),
        #("crawford", json.bool(next.crawford)),
      ]),
      ..turn_started(next)
    ]
  }
}

pub fn legal(state: GameState, player_id: String) -> List(Schema) {
  let resign = case state.can_resign(state, player_id) {
    True -> [action.simple("resign", "Resign")]
    False -> []
  }
  let main = case
    state.can_roll(state, player_id),
    state.must_answer_double(state, player_id)
  {
    True, _ -> {
      let double = case state.can_double(state, player_id) {
        True -> [
          action.simple(
            "double",
            "Double to " <> int.to_string(state.cube_value * 2),
          ),
        ]
        False -> []
      }
      [action.simple("roll", "Roll dice"), ..double]
    }
    _, True -> [
      action.simple(
        "take",
        "Take (cube to " <> int.to_string(state.cube_value * 2) <> ")",
      ),
      action.simple("drop", "Drop"),
    ]
    _, _ -> {
      let moves =
        state.legal_moves(state, player_id)
        |> list.map(fn(m) {
          let from = board.loc_id(m.from)
          let to = board.loc_id(m.to)
          action.Schema("move", label_for(m), [
            action.choice("from", [#(from, from)]),
            action.choice("to", [#(to, to)]),
          ])
        })
      let undo = case state.can_undo(state, player_id) {
        True -> [action.simple("undo", "Undo")]
        False -> []
      }
      let play = case state.can_play(state, player_id) {
        True -> [action.simple("play", "Play")]
        False -> []
      }
      list.flatten([moves, undo, play])
    }
  }
  list.append(main, resign)
}

fn label_for(m: board.Move) -> String {
  board.loc_id(m.from)
  <> " → "
  <> board.loc_id(m.to)
  <> " ("
  <> int.to_string(m.die)
  <> ")"
}

/// Only the player who must act is on the clock (the responder while a
/// double is pending).
pub fn on_the_clock(state: GameState) -> List(String) {
  case state.to_act(state) {
    Some(id) -> [id]
    None -> []
  }
}
