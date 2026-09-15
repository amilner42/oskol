//// The game record: what was played, in the notation the books use.
////
//// The record is part of the game, not of its presentation: `state` appends
//// to it on the same paths that commit a turn, turn the cube and finish a
//// game, so a room rebuilt from its log carries the same record as one that
//// was played live. Points are numbered from the mover's side (24 down to 1
//// for both colours), the bar is `bar`, the tray `off`, a hit is `*`, and
//// checkers that make the same move are grouped: `8/5(2)`.

import backgammon/board.{
  type Board, type Color, type Loc, Bar, Black, Off, Point, White,
}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type PlayerId =
  String

/// One colour's checkers in a position: how many on each of the 24 points
/// (point 1 first), on the bar and borne off, and the pip count.
pub type Side {
  Side(points: List(Int), bar: Int, off: Int, pips: Int)
}

/// The board after a turn, compact enough to ride in every turn of the
/// record: a client can draw any past position from it without knowing a
/// rule.
pub type Snapshot {
  Snapshot(white: Side, black: Side)
}

pub fn snapshot(board: Board) -> Snapshot {
  Snapshot(white: side(board, White), black: side(board, Black))
}

fn side(board: Board, color: Color) -> Side {
  Side(
    points: list.map(list.range(1, 24), fn(p) {
      board.count(board, color, Point(p))
    }),
    bar: board.on_bar(board, color),
    off: board.borne_off(board, color),
    pips: board.pip_count(board, color),
  )
}

/// One line of the record.
pub type Entry {
  /// A committed turn: the roll as it landed, the moves in notation (none
  /// means the roll played nothing, a dance) and the board it left.
  Turn(
    player: PlayerId,
    dice: List(Int),
    picked: Bool,
    moves: List(String),
    position: Snapshot,
  )
  /// `player` offered the cube at `value`.
  Double(player: PlayerId, value: Int)
  Take(player: PlayerId)
  Drop(player: PlayerId)
  Resign(player: PlayerId)
  /// A game ended. `scores` is the running match score after it, in seat
  /// order.
  GameOver(
    number: Int,
    winner: PlayerId,
    kind: String,
    points: Int,
    cube: Int,
    scores: List(#(PlayerId, Int)),
  )
}

/// One move as the mover made it, for `notation`.
pub type Played {
  Played(from: Loc, to: Loc, hit: Bool)
}

/// The moves of one turn in standard notation, from the mover's side.
/// Identical moves are grouped, in the order they were first made; a hit
/// marks the group. `["24/21*", "13/8"]`, `["8/5(2)"]`, `["bar/22"]`,
/// `["6/off"]`; a turn that played nothing is `[]`.
pub fn notation(color: Color, moves: List(Played)) -> List(String) {
  moves
  |> list.fold([], fn(groups: List(#(Loc, Loc, Bool, Int)), m) {
    case list.any(groups, fn(g) { g.0 == m.from && g.1 == m.to }) {
      True ->
        list.map(groups, fn(g) {
          case g.0 == m.from && g.1 == m.to {
            True -> #(g.0, g.1, g.2 || m.hit, g.3 + 1)
            False -> g
          }
        })
      False -> list.append(groups, [#(m.from, m.to, m.hit, 1)])
    }
  })
  |> list.map(fn(g) {
    let #(from, to, hit, n) = g
    let star = case hit {
      True -> "*"
      False -> ""
    }
    let times = case n {
      1 -> ""
      _ -> "(" <> int.to_string(n) <> ")"
    }
    loc_text(color, from) <> "/" <> loc_text(color, to) <> star <> times
  })
}

/// A location as the mover reads it: their own points count down to 1.
pub fn loc_text(color: Color, loc: Loc) -> String {
  case loc {
    Bar -> "bar"
    Off -> "off"
    Point(p) -> int.to_string(board.pip_distance(color, p))
  }
}

/// The dice as a roll reads in a record: "31", "66".
pub fn dice_text(dice: List(Int)) -> String {
  dice |> list.map(int.to_string) |> string.join("")
}

/// The entry as one line of text: `"31: 8/5 6/5"`, `"Doubles to 2"`.
pub fn text(entry: Entry) -> String {
  case entry {
    Turn(_, dice, _, [], _) -> dice_text(dice) <> ": (no play)"
    Turn(_, dice, _, moves, _) ->
      dice_text(dice) <> ": " <> string.join(moves, " ")
    Double(_, value) -> "Doubles to " <> int.to_string(value)
    Take(_) -> "Takes"
    Drop(_) -> "Drops"
    Resign(_) -> "Resigns"
    GameOver(_, _, kind, points, _, _) ->
      "Wins " <> kind <> ", " <> points_text(points)
  }
}

fn points_text(points: Int) -> String {
  case points {
    1 -> "1 point"
    n -> int.to_string(n) <> " points"
  }
}

pub fn player(entry: Entry) -> Option(PlayerId) {
  case entry {
    Turn(p, _, _, _, _) -> Some(p)
    Double(p, _) -> Some(p)
    Take(p) -> Some(p)
    Drop(p) -> Some(p)
    Resign(p) -> Some(p)
    GameOver(_, _, _, _, _, _) -> None
  }
}

/// The entry for the wire. Every field is plain JSON a generic client can
/// read; nothing here is hidden from anyone.
pub fn to_json(entry: Entry) -> Json {
  case entry {
    Turn(player, dice, picked, moves, position) ->
      json.object([
        #("kind", json.string("turn")),
        #("player", json.string(player)),
        #("dice", json.array(dice, json.int)),
        #("picked", json.bool(picked)),
        #("moves", json.array(moves, json.string)),
        #("position", snapshot_to_json(position)),
      ])
    Double(player, value) ->
      json.object([
        #("kind", json.string("double")),
        #("player", json.string(player)),
        #("value", json.int(value)),
      ])
    Take(player) ->
      json.object([
        #("kind", json.string("take")),
        #("player", json.string(player)),
      ])
    Drop(player) ->
      json.object([
        #("kind", json.string("drop")),
        #("player", json.string(player)),
      ])
    Resign(player) ->
      json.object([
        #("kind", json.string("resign")),
        #("player", json.string(player)),
      ])
    GameOver(number, winner, kind, points, cube, scores) ->
      json.object([
        #("kind", json.string("game_over")),
        #("number", json.int(number)),
        #("winner", json.string(winner)),
        #("result", json.string(kind)),
        #("points", json.int(points)),
        #("cube", json.int(cube)),
        #(
          "scores",
          json.object(list.map(scores, fn(s) { #(s.0, json.int(s.1)) })),
        ),
      ])
  }
}

pub fn snapshot_to_json(snapshot: Snapshot) -> Json {
  json.object([
    #("white", side_to_json(snapshot.white)),
    #("black", side_to_json(snapshot.black)),
  ])
}

fn side_to_json(side: Side) -> Json {
  json.object([
    #("points", json.array(side.points, json.int)),
    #("bar", json.int(side.bar)),
    #("off", json.int(side.off)),
    #("pips", json.int(side.pips)),
  ])
}
