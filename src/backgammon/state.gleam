//// Backgammon game flow: turns, dice, match play. Rules live in `board`.

import backgammon/board.{type Board, type Color, type Move, Black, White}
import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type PlayerId =
  String

pub type Phase {
  /// `to_move` must roll.
  Rolling(to_move: Color)
  /// `to_move` has dice left to play.
  Moving(to_move: Color, dice: List(Int))
  /// The match is over.
  Finished(winner: Color)
}

pub type Config {
  Config(target: Int)
}

pub type GameState {
  GameState(
    config: Config,
    order: List(PlayerId),
    names: Dict(PlayerId, String),
    colors: Dict(PlayerId, Color),
    board: Board,
    phase: Phase,
    scores: Dict(PlayerId, Int),
    game_number: Int,
    /// The last dice rolled, for display.
    last_roll: List(Int),
    rng: Rng,
  )
}

/// What happened when a move finished a game.
pub type GameEnd {
  GameEnd(winner: PlayerId, kind: board.WinKind, points: Int, match_over: Bool)
}

pub fn new(
  config: Config,
  seats: List(#(PlayerId, String)),
  rng: Rng,
) -> GameState {
  let order = list.map(seats, fn(s) { s.0 })
  let colors = case order {
    [a, b] -> dict.from_list([#(a, White), #(b, Black)])
    _ -> dict.new()
  }
  let state =
    GameState(
      config: config,
      order: order,
      names: dict.from_list(seats),
      colors: colors,
      board: board.initial(),
      phase: Rolling(White),
      scores: dict.from_list(list.map(order, fn(id) { #(id, 0) })),
      game_number: 1,
      last_roll: [],
      rng: rng,
    )
  opening_roll(state)
}

/// Each side rolls one die; the higher plays first with both dice.
fn opening_roll(state: GameState) -> GameState {
  let #(a, rng) = die(state.rng)
  let #(b, rng) = die(rng)
  let state = GameState(..state, rng: rng)
  case a == b {
    True -> opening_roll(state)
    False -> {
      let first = case a > b {
        True -> White
        False -> Black
      }
      start_moving(GameState(..state, last_roll: [a, b]), first, [a, b])
    }
  }
}

fn die(rng: Rng) -> #(Int, Rng) {
  let #(n, rng) = rng.int(rng, 6)
  #(n + 1, rng)
}

fn start_moving(state: GameState, color: Color, dice: List(Int)) -> GameState {
  case board.legal_moves(state.board, color, dice) {
    [] -> GameState(..state, phase: Rolling(board.opponent(color)))
    _ -> GameState(..state, phase: Moving(color, dice))
  }
}

// ---------- Queries ----------

pub fn color_of(state: GameState, player_id: PlayerId) -> Result(Color, String) {
  dict.get(state.colors, player_id) |> result.replace_error("Player not found")
}

pub fn player_of(state: GameState, color: Color) -> PlayerId {
  state.colors
  |> dict.to_list
  |> list.find(fn(entry) { entry.1 == color })
  |> result.map(fn(entry) { entry.0 })
  |> result.unwrap("")
}

pub fn name_of(state: GameState, player_id: PlayerId) -> String {
  dict.get(state.names, player_id) |> result.unwrap(player_id)
}

pub fn score_of(state: GameState, player_id: PlayerId) -> Int {
  dict.get(state.scores, player_id) |> result.unwrap(0)
}

pub fn to_move(state: GameState) -> Option(PlayerId) {
  case state.phase {
    Rolling(c) -> Some(player_of(state, c))
    Moving(c, _) -> Some(player_of(state, c))
    Finished(_) -> None
  }
}

pub fn dice_left(state: GameState) -> List(Int) {
  case state.phase {
    Moving(_, dice) -> dice
    _ -> []
  }
}

pub fn legal_moves(state: GameState, player_id: PlayerId) -> List(Move) {
  case state.phase, color_of(state, player_id) {
    Moving(c, dice), Ok(mine) if c == mine ->
      board.legal_moves(state.board, c, dice)
    _, _ -> []
  }
}

pub fn can_roll(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Rolling(c), Ok(mine) -> c == mine
    _, _ -> False
  }
}

// ---------- Transitions ----------

pub fn roll(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, List(Int)), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Rolling(c) if c == color -> {
      let #(a, rng) = die(state.rng)
      let #(b, rng) = die(rng)
      let dice = case a == b {
        True -> [a, a, a, a]
        False -> [a, b]
      }
      let state = GameState(..state, rng: rng, last_roll: [a, b])
      Ok(#(start_moving(state, color, dice), [a, b]))
    }
    Rolling(_) -> Error("Not your turn")
    Moving(_, _) -> Error("Dice already rolled")
    Finished(_) -> Error("The match is over")
  }
}

pub type Applied {
  Applied(
    state: GameState,
    move: Move,
    mover: String,
    hit: Option(String),
    /// The turn passed to the opponent after this move.
    turn_ended: Bool,
    game_end: Option(GameEnd),
  )
}

pub fn move(
  state: GameState,
  player_id: PlayerId,
  from: board.Loc,
  to: board.Loc,
) -> Result(Applied, String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Moving(c, dice) if c == color -> {
      let candidates =
        board.legal_moves(state.board, color, dice)
        |> list.filter(fn(m) { m.from == from && m.to == to })
      // Prefer the exact die when several dice could make the same move
      use chosen <- result.try(
        candidates
        |> list.sort(fn(a, b) { int.compare(a.die, b.die) })
        |> list.first
        |> result.replace_error("Illegal move"),
      )
      let #(next_board, mover, hit) =
        board.apply_move(state.board, color, chosen)
      let remaining = remove_one(dice, chosen.die)
      let state = GameState(..state, board: next_board)
      case board.borne_off(next_board, color) == 15 {
        True -> {
          let #(state, game_end) = finish_game(state, color)
          Ok(Applied(state, chosen, mover, hit, True, Some(game_end)))
        }
        False -> {
          let continues =
            remaining != []
            && board.legal_moves(next_board, color, remaining) != []
          let state = case continues {
            True -> GameState(..state, phase: Moving(color, remaining))
            False -> GameState(..state, phase: Rolling(board.opponent(color)))
          }
          Ok(Applied(state, chosen, mover, hit, !continues, None))
        }
      }
    }
    Moving(_, _) -> Error("Not your turn")
    Rolling(c) if c == color -> Error("Roll first")
    Rolling(_) -> Error("Not your turn")
    Finished(_) -> Error("The match is over")
  }
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

fn finish_game(state: GameState, winner: Color) -> #(GameState, GameEnd) {
  let kind = board.win_kind(state.board, winner)
  let points = board.points_for(kind)
  let winner_id = player_of(state, winner)
  let scores =
    dict.upsert(state.scores, winner_id, fn(s) { option.unwrap(s, 0) + points })
  let total = dict.get(scores, winner_id) |> result.unwrap(0)
  let match_over = total >= state.config.target
  let state = GameState(..state, scores: scores)
  let state = case match_over {
    True -> GameState(..state, phase: Finished(winner))
    False ->
      opening_roll(
        GameState(
          ..state,
          board: board.initial(),
          game_number: state.game_number + 1,
          last_roll: [],
        ),
      )
  }
  #(
    state,
    GameEnd(
      winner: winner_id,
      kind: kind,
      points: points,
      match_over: match_over,
    ),
  )
}
