//// Go game flow: turns, passes, positional superko, scoring, resignation.
//// Board rules live in `go/board`.
////
//// Superko is positional: no move may recreate any earlier whole-board
//// position, whoever was to move then. Every position ever on the board is
//// kept as a canonical string (see `board.canonical`) in a set; a placement
//// whose resulting canonical string is already present is illegal. Passes
//// do not change the board and are never restricted.

import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import go/board.{type Board, type Color, Black, White}

pub type PlayerId =
  String

pub type Phase {
  Playing(to_move: Color)
  Finished(winner: Color)
}

/// `komi2` is komi doubled, kept integral: 11, 13 or 15 for 5.5, 6.5, 7.5.
pub type Config {
  Config(size: Int, komi2: Int)
}

/// How the game ended.
pub type EndKind {
  /// Two consecutive passes: Tromp-Taylor scores, komi included in white's.
  Scored(black2: Int, white2: Int)
  Resigned
}

pub type GameEnd {
  GameEnd(winner: PlayerId, kind: EndKind)
}

pub type GameState {
  GameState(
    config: Config,
    order: List(PlayerId),
    names: Dict(PlayerId, String),
    colors: Dict(PlayerId, Color),
    board: Board,
    phase: Phase,
    /// Consecutive passes; two end the game.
    passes: Int,
    /// Every whole-board position seen so far (positional superko).
    history: Set(String),
    /// Token id of the stone standing on each occupied point.
    stone_ids: Dict(Int, String),
    /// Stones placed so far; the next stone is "s<move_number + 1>".
    move_number: Int,
    /// Prisoners each player has taken.
    captured: Dict(PlayerId, Int),
    /// Stones each player has placed.
    placed: Dict(PlayerId, Int),
    /// The most recent placement, for display.
    last_point: Option(Int),
    /// Doubled final scores `#(black2, white2)` once the game was scored.
    final_score2: Option(#(Int, Int)),
    /// Unused by go (no randomness), stored per the contract.
    rng: Rng,
  )
}

pub fn new(
  config: Config,
  seats: List(#(PlayerId, String)),
  rng: Rng,
) -> GameState {
  let order = list.map(seats, fn(s) { s.0 })
  let colors = case order {
    [a, b] -> dict.from_list([#(a, Black), #(b, White)])
    _ -> dict.new()
  }
  let empty = board.new(config.size)
  GameState(
    config: config,
    order: order,
    names: dict.from_list(seats),
    colors: colors,
    board: empty,
    phase: Playing(Black),
    passes: 0,
    history: set.insert(set.new(), board.canonical(empty)),
    stone_ids: dict.new(),
    move_number: 0,
    captured: dict.from_list(list.map(order, fn(id) { #(id, 0) })),
    placed: dict.from_list(list.map(order, fn(id) { #(id, 0) })),
    last_point: None,
    final_score2: None,
    rng: rng,
  )
}

// ---------- Queries ----------

pub fn color_of(state: GameState, player_id: PlayerId) -> Result(Color, String) {
  dict.get(state.colors, player_id) |> result.replace_error("Player not found")
}

pub fn player_of(state: GameState, color: Color) -> PlayerId {
  state.order
  |> list.find(fn(id) { dict.get(state.colors, id) == Ok(color) })
  |> result.unwrap("")
}

pub fn name_of(state: GameState, player_id: PlayerId) -> String {
  dict.get(state.names, player_id) |> result.unwrap(player_id)
}

pub fn to_move(state: GameState) -> Option(PlayerId) {
  case state.phase {
    Playing(color) -> Some(player_of(state, color))
    Finished(_) -> None
  }
}

pub fn captured_by(state: GameState, player_id: PlayerId) -> Int {
  dict.get(state.captured, player_id) |> result.unwrap(0)
}

pub fn placed_by(state: GameState, player_id: PlayerId) -> Int {
  dict.get(state.placed, player_id) |> result.unwrap(0)
}

pub fn komi(state: GameState) -> Float {
  int.to_float(state.config.komi2) /. 2.0
}

pub fn score2_to_float(score2: Int) -> Float {
  int.to_float(score2) /. 2.0
}

/// Point ids where this player may legally place a stone right now: empty,
/// not suicide, and not recreating any earlier position.
pub fn legal_point_ids(state: GameState, player_id: PlayerId) -> List(String) {
  case state.phase, color_of(state, player_id) {
    Playing(color), Ok(mine) if color == mine ->
      board.placeable_points(state.board, color)
      |> list.filter(fn(point) {
        case board.place(state.board, point, color) {
          Ok(#(next, _)) -> !set.contains(state.history, board.canonical(next))
          Error(_) -> False
        }
      })
      |> list.map(board.point_id(state.board, _))
    _, _ -> []
  }
}

pub fn can_pass(state: GameState, player_id: PlayerId) -> Bool {
  case state.phase, color_of(state, player_id) {
    Playing(color), Ok(mine) -> color == mine
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

// ---------- Transitions ----------

/// What a placement produced: the stone's token id and the captured stones'
/// token ids (in point order).
pub type Placed {
  Placed(state: GameState, stone_id: String, captured_ids: List(String))
}

pub fn place(
  state: GameState,
  player_id: PlayerId,
  point_id: String,
) -> Result(Placed, String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Finished(_) -> Error("The game is over")
    Playing(to_move) if to_move != color -> Error("Not your turn")
    Playing(_) -> {
      use point <- result.try(
        board.parse_point(state.board, point_id)
        |> result.replace_error("Invalid point: " <> point_id),
      )
      use #(next_board, captured_points) <- result.try(
        board.place(state.board, point, color)
        |> result.map_error(fn(e) {
          case e {
            board.Occupied -> "That point is occupied"
            board.Suicide -> "Suicide is forbidden"
          }
        }),
      )
      let position = board.canonical(next_board)
      use <- require(
        !set.contains(state.history, position),
        "That move would repeat an earlier board position",
      )
      let stone_id = "s" <> int.to_string(state.move_number + 1)
      let captured_ids =
        list.map(captured_points, fn(p) {
          dict.get(state.stone_ids, p) |> result.unwrap("")
        })
      let stone_ids =
        list.fold(captured_points, state.stone_ids, fn(ids, p) {
          dict.delete(ids, p)
        })
        |> dict.insert(point, stone_id)
      let next =
        GameState(
          ..state,
          board: next_board,
          phase: Playing(board.opponent(color)),
          passes: 0,
          history: set.insert(state.history, position),
          stone_ids: stone_ids,
          move_number: state.move_number + 1,
          captured: bump(
            state.captured,
            player_id,
            list.length(captured_points),
          ),
          placed: bump(state.placed, player_id, 1),
          last_point: Some(point),
        )
      Ok(Placed(state: next, stone_id: stone_id, captured_ids: captured_ids))
    }
  }
}

/// Pass. The second consecutive pass ends the game with a Tromp-Taylor
/// count, komi added to white.
pub fn pass(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, Option(GameEnd)), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Finished(_) -> Error("The game is over")
    Playing(to_move) if to_move != color -> Error("Not your turn")
    Playing(_) ->
      case state.passes + 1 >= 2 {
        True -> {
          let #(black, white) = board.score(state.board)
          let black2 = black * 2
          let white2 = white * 2 + state.config.komi2
          let winner = case black2 > white2 {
            True -> Black
            False -> White
          }
          let next =
            GameState(
              ..state,
              phase: Finished(winner),
              passes: 2,
              last_point: None,
              final_score2: Some(#(black2, white2)),
            )
          Ok(#(
            next,
            Some(GameEnd(
              winner: player_of(state, winner),
              kind: Scored(black2, white2),
            )),
          ))
        }
        False ->
          Ok(#(
            GameState(
              ..state,
              phase: Playing(board.opponent(color)),
              passes: state.passes + 1,
              last_point: None,
            ),
            None,
          ))
      }
  }
}

pub fn resign(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, GameEnd), String) {
  use color <- result.try(color_of(state, player_id))
  case state.phase {
    Finished(_) -> Error("The game is over")
    Playing(_) -> {
      let winner = board.opponent(color)
      Ok(#(
        GameState(..state, phase: Finished(winner), last_point: None),
        GameEnd(winner: player_of(state, winner), kind: Resigned),
      ))
    }
  }
}

fn bump(
  counts: Dict(PlayerId, Int),
  id: PlayerId,
  by: Int,
) -> Dict(PlayerId, Int) {
  dict.upsert(counts, id, fn(v) { option.unwrap(v, 0) + by })
}

fn require(check: Bool, error: String, then: fn() -> Result(a, String)) {
  case check {
    True -> then()
    False -> Error(error)
  }
}
