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
  /// `to_move` must roll (or offer a double first).
  Rolling(to_move: Color)
  /// `by` offered a double; the opponent must take or drop.
  Doubled(by: Color)
  /// `to_move` has dice left to play. Moves are staged on the mover's own
  /// view and only committed with `play`; `dice` are the ones still unused.
  Moving(to_move: Color, dice: List(Int))
  /// The match is over.
  Finished(winner: Color)
}

/// `target` 0 means unlimited play: games keep coming and the score just
/// accumulates. `jacoby` makes gammons count only once the cube was turned,
/// the usual convention for unlimited (money) play.
pub type Config {
  Config(target: Int, cube: Bool, jacoby: Bool)
}

pub const cube_limit = 64

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
    /// Doubling cube: value and owner (None while centred).
    cube_value: Int,
    cube_owner: Option(Color),
    /// This game is the Crawford game: no doubling.
    crawford: Bool,
    /// The Crawford game has been played (or is being played).
    crawford_done: Bool,
    /// The board as the opponent sees it: before any move staged this turn.
    turn_board: Board,
    /// Moves staged this turn, oldest first. Committed by `play`.
    staged: List(Staged),
    rng: Rng,
  )
}

/// A move staged but not yet played, with what undo needs.
pub type Staged {
  Staged(move: Move, mover: String, hit: Option(String), board_before: Board)
}

/// How a game ended.
pub type EndKind {
  Won(board.WinKind)
  Dropped
  Resigned
}

/// What happened when a game finished.
pub type GameEnd {
  GameEnd(
    winner: PlayerId,
    kind: EndKind,
    /// Points scored, cube included.
    points: Int,
    cube: Int,
    match_over: Bool,
  )
}

pub fn end_kind_name(kind: EndKind) -> String {
  case kind {
    Won(k) -> board.kind_name(k)
    Dropped -> "dropped"
    Resigned -> "resigned"
  }
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
      cube_value: 1,
      cube_owner: None,
      crawford: False,
      crawford_done: False,
      turn_board: board.initial(),
      staged: [],
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
  let state = GameState(..state, turn_board: state.board, staged: [])
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

/// The player who must act now: the mover, or the player answering a double.
pub fn to_act(state: GameState) -> Option(PlayerId) {
  case state.phase {
    Rolling(c) -> Some(player_of(state, c))
    Moving(c, _) -> Some(player_of(state, c))
    Doubled(by) -> Some(player_of(state, board.opponent(by)))
    Finished(_) -> None
  }
}

/// The player whose turn it is (the doubler, while a double is pending).
pub fn to_move(state: GameState) -> Option(PlayerId) {
  case state.phase {
    Rolling(c) -> Some(player_of(state, c))
    Moving(c, _) -> Some(player_of(state, c))
    Doubled(by) -> Some(player_of(state, by))
    Finished(_) -> None
  }
}

pub fn unlimited(state: GameState) -> Bool {
  state.config.target <= 0
}

/// May this player offer a double right now?
pub fn can_double(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Rolling(c), Ok(mine) if c == mine ->
      state.config.cube
      && !state.crawford
      && state.cube_value < cube_limit
      && { state.cube_owner == None || state.cube_owner == Some(mine) }
    _, _ -> False
  }
}

pub fn must_answer_double(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Doubled(by), Ok(mine) -> by != mine
    _, _ -> False
  }
}

pub fn can_resign(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Finished(_), _ -> False
    _, Ok(_) -> True
    _, Error(_) -> False
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

/// Can the mover take back their last staged move?
pub fn can_undo(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Moving(c, _), Ok(mine) if c == mine -> state.staged != []
    _, _ -> False
  }
}

/// The turn is complete: no legal move remains for the unused dice.
pub fn can_play(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Moving(c, dice), Ok(mine) if c == mine ->
      board.legal_moves(state.board, c, dice) == []
    _, _ -> False
  }
}

/// All dice of the current roll (four for doubles).
pub fn turn_dice(state: GameState) -> List(Int) {
  case state.last_roll {
    [a, b] if a == b -> [a, a, a, a]
    other -> other
  }
}

/// The board this viewer may see: the mover's own staging, or the board as
/// it stood when the turn began for everyone else.
pub fn visible_board(state: GameState, viewer: Option(PlayerId)) -> Board {
  case state.phase {
    Moving(c, _) ->
      case state.staged != [] && viewer != Some(player_of(state, c)) {
        True -> state.turn_board
        False -> state.board
      }
    _ -> state.board
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
    Doubled(_) -> Error("A double is pending")
    Moving(_, _) -> Error("Dice already rolled")
    Finished(_) -> Error("The match is over")
  }
}

// ---------- Cube ----------

pub fn double(
  state: GameState,
  player_id: PlayerId,
) -> Result(GameState, String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Rolling(c) if c == color ->
      case can_double(state, player_id) {
        True -> Ok(GameState(..state, phase: Doubled(color)))
        False -> {
          let owns = state.cube_owner == None || state.cube_owner == Some(color)
          case
            state.config.cube,
            state.crawford,
            owns,
            state.cube_value < cube_limit
          {
            False, _, _, _ -> Error("The cube is not in play")
            _, True, _, _ -> Error("No doubling in the Crawford game")
            _, _, False, _ -> Error("You do not own the cube")
            _, _, _, _ -> Error("The cube is at its limit")
          }
        }
      }
    Rolling(_) -> Error("Not your turn")
    Doubled(_) -> Error("A double is pending")
    Moving(_, _) -> Error("You can only double before rolling")
    Finished(_) -> Error("The match is over")
  }
}

pub fn take(state: GameState, player_id: PlayerId) -> Result(GameState, String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Doubled(by) if by != color ->
      Ok(
        GameState(
          ..state,
          phase: Rolling(by),
          cube_value: state.cube_value * 2,
          cube_owner: Some(color),
        ),
      )
    Doubled(_) -> Error("You offered the double")
    _ -> Error("No double to answer")
  }
}

pub fn drop(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, GameEnd), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Doubled(by) if by != color -> Ok(finish_game(state, by, Dropped))
    Doubled(_) -> Error("You offered the double")
    _ -> Error("No double to answer")
  }
}

pub fn resign(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, GameEnd), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Finished(_) -> Error("The match is over")
    _ -> Ok(finish_game(state, board.opponent(color), Resigned))
  }
}

/// Stage a move on the mover's board. Nothing is committed until `play`.
pub fn stage(
  state: GameState,
  player_id: PlayerId,
  from: board.Loc,
  to: board.Loc,
) -> Result(#(GameState, Staged), String) {
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
      let staged = Staged(chosen, mover, hit, state.board)
      Ok(#(
        GameState(
          ..state,
          board: next_board,
          phase: Moving(color, remove_one(dice, chosen.die)),
          staged: list.append(state.staged, [staged]),
        ),
        staged,
      ))
    }
    Moving(_, _) -> Error("Not your turn")
    Rolling(c) if c == color -> Error("Roll first")
    Rolling(_) -> Error("Not your turn")
    Doubled(_) -> Error("A double is pending")
    Finished(_) -> Error("The match is over")
  }
}

/// Take back the most recently staged move.
pub fn undo(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, Staged), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Moving(c, dice) if c == color ->
      case list.reverse(state.staged) {
        [] -> Error("Nothing to undo")
        [last, ..rest] ->
          Ok(#(
            GameState(
              ..state,
              board: last.board_before,
              phase: Moving(color, [last.move.die, ..dice]),
              staged: list.reverse(rest),
            ),
            last,
          ))
      }
    _ -> Error("Nothing to undo")
  }
}

/// What a committed turn produced.
pub type Played {
  Played(state: GameState, moves: List(Staged), game_end: Option(GameEnd))
}

/// Commit the staged moves. The turn must be complete: every die that can
/// be played has been.
pub fn play(state: GameState, player_id: PlayerId) -> Result(Played, String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Moving(c, dice) if c == color ->
      case board.legal_moves(state.board, color, dice) {
        [] -> {
          let moves = state.staged
          let state = GameState(..state, turn_board: state.board, staged: [])
          case board.borne_off(state.board, color) == 15 {
            True -> {
              let #(state, game_end) =
                finish_game(
                  state,
                  color,
                  Won(board.win_kind(state.board, color)),
                )
              Ok(Played(state, moves, Some(game_end)))
            }
            False ->
              Ok(Played(
                GameState(..state, phase: Rolling(board.opponent(color))),
                moves,
                None,
              ))
          }
        }
        _ -> Error("You still have moves to play")
      }
    Moving(_, _) -> Error("Not your turn")
    _ -> Error("Nothing to play")
  }
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

/// Score a finished game, then either end the match or set up the next game
/// (fresh board, centred cube, Crawford bookkeeping).
fn finish_game(
  state: GameState,
  winner: Color,
  kind: EndKind,
) -> #(GameState, GameEnd) {
  let base = case kind {
    Won(k) ->
      // Jacoby: gammons only count once the cube has been turned
      case state.config.jacoby && state.cube_owner == None {
        True -> 1
        False -> board.points_for(k)
      }
    Dropped -> 1
    Resigned -> 1
  }
  let points = base * state.cube_value
  let winner_id = player_of(state, winner)
  let scores =
    dict.upsert(state.scores, winner_id, fn(s) { option.unwrap(s, 0) + points })
  let total = dict.get(scores, winner_id) |> result.unwrap(0)
  let match_over = state.config.target > 0 && total >= state.config.target
  let cube = state.cube_value
  let state = GameState(..state, scores: scores)
  let state = case match_over {
    True -> GameState(..state, phase: Finished(winner))
    False -> {
      // Crawford: the first time someone gets within one point, the next
      // game is played without the cube; after it, doubling resumes.
      let one_away =
        state.config.target > 0
        && list.any(state.order, fn(id) {
          { dict.get(scores, id) |> result.unwrap(0) }
          == state.config.target - 1
        })
      let crawford_done = state.crawford_done || state.crawford
      let crawford = !crawford_done && one_away
      opening_roll(
        GameState(
          ..state,
          board: board.initial(),
          game_number: state.game_number + 1,
          last_roll: [],
          cube_value: 1,
          cube_owner: None,
          crawford: crawford,
          crawford_done: crawford_done || crawford,
        ),
      )
    }
  }
  #(
    state,
    GameEnd(
      winner: winner_id,
      kind: kind,
      points: points,
      cube: cube,
      match_over: match_over,
    ),
  )
}
