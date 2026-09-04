//// Backgammon board and move generation. Pure rules, no game flow.
////
//// Points are numbered 1..24. White moves from 24 down to 1 and bears off
//// past 1; Black moves from 1 up to 24 and bears off past 24. Each checker
//// has a stable id ("w1".."w15", "b1".."b15") so the client can animate it.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Color {
  White
  Black
}

pub type Loc {
  Point(Int)
  Bar
  Off
}

pub type Board {
  Board(checkers: Dict(String, #(Color, Loc)))
}

pub type Move {
  Move(from: Loc, to: Loc, die: Int)
}

pub type WinKind {
  Single
  Gammon
  Backgammon
}

pub fn opponent(color: Color) -> Color {
  case color {
    White -> Black
    Black -> White
  }
}

pub fn prefix(color: Color) -> String {
  case color {
    White -> "w"
    Black -> "b"
  }
}

pub fn color_name(color: Color) -> String {
  case color {
    White -> "white"
    Black -> "black"
  }
}

fn direction(color: Color) -> Int {
  case color {
    White -> -1
    Black -> 1
  }
}

/// Distance from a point to bearing off, for this color.
pub fn pip_distance(color: Color, point: Int) -> Int {
  case color {
    White -> point
    Black -> 25 - point
  }
}

pub fn is_home(color: Color, point: Int) -> Bool {
  pip_distance(color, point) <= 6
}

pub fn entry_point(color: Color, die: Int) -> Int {
  case color {
    White -> 25 - die
    Black -> die
  }
}

/// The standard starting position.
pub fn initial() -> Board {
  let place = fn(color, layout: List(#(Int, Int))) {
    layout
    |> list.flat_map(fn(entry) { list.repeat(entry.0, entry.1) })
    |> list.index_map(fn(point, i) {
      #(prefix(color) <> int.to_string(i + 1), #(color, Point(point)))
    })
  }
  Board(
    checkers: dict.from_list(list.append(
      place(White, [#(24, 2), #(13, 5), #(8, 3), #(6, 5)]),
      place(Black, [#(1, 2), #(12, 5), #(17, 3), #(19, 5)]),
    )),
  )
}

/// Checkers of a color at a location, ids ascending.
pub fn checkers_at(board: Board, color: Color, loc: Loc) -> List(String) {
  board.checkers
  |> dict.to_list
  |> list.filter(fn(entry) { entry.1 == #(color, loc) })
  |> list.map(fn(entry) { entry.0 })
  |> list.sort(compare_ids)
}

fn compare_ids(a: String, b: String) {
  int.compare(id_number(a), id_number(b))
}

fn id_number(id: String) -> Int {
  case int.parse(string.drop_start(id, 1)) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

pub fn count(board: Board, color: Color, loc: Loc) -> Int {
  list.length(checkers_at(board, color, loc))
}

/// Who occupies a point and with how many checkers.
pub fn occupant(board: Board, point: Int) -> #(Option(Color), Int) {
  case count(board, White, Point(point)), count(board, Black, Point(point)) {
    0, 0 -> #(None, 0)
    w, 0 -> #(Some(White), w)
    _, b -> #(Some(Black), b)
  }
}

pub fn open_for(board: Board, color: Color, point: Int) -> Bool {
  case occupant(board, point) {
    #(Some(other), n) if other != color -> n < 2
    _ -> True
  }
}

pub fn borne_off(board: Board, color: Color) -> Int {
  count(board, color, Off)
}

pub fn on_bar(board: Board, color: Color) -> Int {
  count(board, color, Bar)
}

/// Points holding at least one checker of this color, ascending.
pub fn points_of(board: Board, color: Color) -> List(Int) {
  list.range(1, 24)
  |> list.filter(fn(p) { count(board, color, Point(p)) > 0 })
}

pub fn all_home(board: Board, color: Color) -> Bool {
  on_bar(board, color) == 0
  && list.all(points_of(board, color), fn(p) { is_home(color, p) })
}

pub fn pip_count(board: Board, color: Color) -> Int {
  let on_points =
    points_of(board, color)
    |> list.fold(0, fn(acc, p) {
      acc + pip_distance(color, p) * count(board, color, Point(p))
    })
  on_points + 25 * on_bar(board, color)
}

/// The farthest-from-home distance among this color's checkers on points.
fn farthest(board: Board, color: Color) -> Int {
  points_of(board, color)
  |> list.map(fn(p) { pip_distance(color, p) })
  |> list.fold(0, int.max)
}

/// Every legal single move for one die.
pub fn single_moves(board: Board, color: Color, die: Int) -> List(Move) {
  case on_bar(board, color) > 0 {
    True -> {
      let entry = entry_point(color, die)
      case open_for(board, color, entry) {
        True -> [Move(Bar, Point(entry), die)]
        False -> []
      }
    }
    False -> {
      let home = all_home(board, color)
      let far = farthest(board, color)
      points_of(board, color)
      |> list.filter_map(fn(p) {
        let target = p + direction(color) * die
        let dist = pip_distance(color, p)
        case target >= 1 && target <= 24 {
          True ->
            case open_for(board, color, target) {
              True -> Ok(Move(Point(p), Point(target), die))
              False -> Error(Nil)
            }
          False ->
            case home, dist == die, dist < die && dist == far {
              True, True, _ -> Ok(Move(Point(p), Off, die))
              True, False, True -> Ok(Move(Point(p), Off, die))
              _, _, _ -> Error(Nil)
            }
        }
      })
    }
  }
}

/// Apply one move. Returns the board, the id of the checker that moved, and
/// the id of an opposing blot sent to the bar, if any.
pub fn apply_move(
  board: Board,
  color: Color,
  move: Move,
) -> #(Board, String, Option(String)) {
  let mover = case checkers_at(board, color, move.from) |> list.last {
    Ok(id) -> id
    Error(_) -> ""
  }
  let hit = case move.to {
    Point(p) ->
      case occupant(board, p) {
        #(Some(other), 1) if other != color ->
          list.first(checkers_at(board, other, Point(p))) |> option.from_result
        _ -> None
      }
    _ -> None
  }
  let checkers = dict.insert(board.checkers, mover, #(color, move.to))
  let checkers = case hit {
    Some(id) -> dict.insert(checkers, id, #(opponent(color), Bar))
    None -> checkers
  }
  #(Board(checkers: checkers), mover, hit)
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

/// All maximal move sequences for the dice, honouring the rules that you must
/// use as many dice as possible and, when only one die can be used, the larger.
pub fn sequences(
  board: Board,
  color: Color,
  dice: List(Int),
) -> List(List(Move)) {
  let all = search(board, color, dice)
  let longest =
    list.fold(all, 0, fn(acc, seq) { int.max(acc, list.length(seq)) })
  case longest {
    0 -> []
    1 ->
      case list.unique(dice) {
        [a, b] -> {
          let bigger = int.max(a, b)
          let single_length =
            list.filter(all, fn(seq) { list.length(seq) == 1 })
          let with_bigger =
            list.filter(single_length, fn(seq) {
              case seq {
                [m] -> m.die == bigger
                _ -> False
              }
            })
          case with_bigger {
            [] -> single_length
            _ -> with_bigger
          }
        }
        _ -> list.filter(all, fn(seq) { list.length(seq) == 1 })
      }
    n -> list.filter(all, fn(seq) { list.length(seq) == n })
  }
}

fn search(board: Board, color: Color, dice: List(Int)) -> List(List(Move)) {
  let continuations =
    list.unique(dice)
    |> list.flat_map(fn(die) {
      single_moves(board, color, die)
      |> list.flat_map(fn(move) {
        let #(next, _, _) = apply_move(board, color, move)
        search(next, color, remove_one(dice, die))
        |> list.map(fn(rest) { [move, ..rest] })
      })
    })
  case continuations {
    [] -> [[]]
    _ -> continuations
  }
}

/// The moves a player may make now, given the dice still unused.
pub fn legal_moves(board: Board, color: Color, dice: List(Int)) -> List(Move) {
  sequences(board, color, dice)
  |> list.filter_map(list.first)
  |> list.unique
}

pub fn win_kind(board: Board, winner: Color) -> WinKind {
  let loser = opponent(winner)
  let in_winner_home =
    points_of(board, loser) |> list.any(fn(p) { is_home(winner, p) })
  case borne_off(board, loser) > 0, on_bar(board, loser) > 0 || in_winner_home {
    True, _ -> Single
    False, True -> Backgammon
    False, False -> Gammon
  }
}

pub fn points_for(kind: WinKind) -> Int {
  case kind {
    Single -> 1
    Gammon -> 2
    Backgammon -> 3
  }
}

pub fn kind_name(kind: WinKind) -> String {
  case kind {
    Single -> "single"
    Gammon -> "gammon"
    Backgammon -> "backgammon"
  }
}

pub fn loc_id(loc: Loc) -> String {
  case loc {
    Point(p) -> int.to_string(p)
    Bar -> "bar"
    Off -> "off"
  }
}

pub fn parse_loc(text: String) -> Result(Loc, Nil) {
  case text {
    "bar" -> Ok(Bar)
    "off" -> Ok(Off)
    _ ->
      case int.parse(text) {
        Ok(p) if p >= 1 && p <= 24 -> Ok(Point(p))
        _ -> Error(Nil)
      }
  }
}

/// Zone id for a location in the scene, owned zones carry the player id.
pub fn zone_id(loc: Loc, owner: String) -> String {
  case loc {
    Point(p) -> "point:" <> int.to_string(p)
    Bar -> "bar:" <> owner
    Off -> "off:" <> owner
  }
}
