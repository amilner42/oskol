//// The game record: what was played, in the notation the books use.
////
//// The record is part of the game, not of its presentation: `state` appends
//// to it on the same paths that commit a turn, turn the cube and finish a
//// game, so a room rebuilt from its log carries the same record as one that
//// was played live. Points are numbered from the mover's side (24 down to 1
//// for both colours), the bar is `bar`, the tray `off`, a hit is `*`, one
//// checker's steps are one move (`24/13`, `24/18*/13` when it hit on the
//// way), and checkers that make the same move are grouped: `8/5(2)`.

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
/// rule. The cube is part of the position: its value and who owns it
/// (`None` while centred). A turn is committed with no double on offer (a
/// double is offered before the roll and answered before anyone moves), so
/// a snapshot never has one pending.
pub type Snapshot {
  Snapshot(white: Side, black: Side, cube: Int, cube_owner: Option(PlayerId))
}

pub fn snapshot(
  board: Board,
  cube: Int,
  cube_owner: Option(PlayerId),
) -> Snapshot {
  Snapshot(
    white: side(board, White),
    black: side(board, Black),
    cube: cube,
    cube_owner: cube_owner,
  )
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
  /// means the roll played nothing, a dance), the board it left, and where
  /// each checker that moved ended up (`landed`).
  Turn(
    player: PlayerId,
    dice: List(Int),
    moves: List(String),
    position: Snapshot,
    /// The points (1..24, as the board numbers them) where the checkers
    /// that moved this turn now stand: one per checker, low point first, so
    /// two checkers made the 5 is `[5, 5]`; a checker that moved twice is
    /// there once, at the point it stopped; one borne off is not there at
    /// all; one entered from the bar is where it landed. A client marks
    /// them; it never works them out.
    landed: List(Int),
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

/// One step as the mover made it, for `notation`: one die, one checker.
pub type Played {
  Played(from: Loc, to: Loc, hit: Bool)
}

/// One checker's move this turn: where it started and each place it
/// stopped, with whether it hit there, oldest first.
type Chain {
  Chain(from: Loc, stops: List(#(Loc, Bool)), last_step: Int)
}

/// The moves of one turn in standard notation, from the mover's side.
///
/// A step that starts where an earlier step of this turn ended continues
/// that checker (`24/18` then `18/13` is `24/13`); the stops in between are
/// written only where it hit (`24/18*/13`). Which checker of a stack the
/// engine picked up is not part of the move -- checkers on a point are
/// interchangeable, so the result is the same position whichever id moved
/// -- which is why chaining goes by where the checker stands and not by its
/// id. When two chains end on the point a step leaves, the checker that got
/// there last is the one that moves on.
///
/// Identical moves are then grouped, in the order each was first made, a hit
/// on the landing point marking the group: `["24/21*", "13/8"]`,
/// `["8/5(2)"]`, `["24/12(2)"]`, `["bar/22"]`, `["6/off"]`; a turn that
/// played nothing is `[]`.
pub fn notation(color: Color, moves: List(Played)) -> List(String) {
  let chains = chains(moves)
  notation_of(color, chains)
}

/// Where a turn's checkers ended up, read the way the notation reads the
/// turn: one checker per chain of steps (a step starting where an earlier
/// one ended carries on that checker), at the chain's final point, low
/// first; a checker borne off has no point. So `8/6 6/2` is one checker on
/// the 2, whichever piece of the 6 the engine happened to pick up.
pub fn landed(moves: List(Played)) -> List(Int) {
  chains(moves)
  |> list.filter_map(fn(c) {
    case end_of(c) {
      board.Point(p) -> Ok(p)
      _ -> Error(Nil)
    }
  })
  |> list.sort(int.compare)
}

fn chains(moves: List(Played)) -> List(Chain) {
  moves
  |> list.index_map(fn(m, i) { #(m, i) })
  |> list.fold([], fn(chains: List(Chain), step) {
    let #(m, i) = step
    let continuing =
      chains
      |> list.filter(fn(c) { end_of(c) == m.from && m.from != Off })
      |> list.sort(fn(a, b) { int.compare(b.last_step, a.last_step) })
      |> list.first
    case continuing {
      Ok(chain) ->
        list.map(chains, fn(c) {
          case c == chain {
            True ->
              Chain(
                ..c,
                stops: list.append(c.stops, [#(m.to, m.hit)]),
                last_step: i,
              )
            False -> c
          }
        })
      Error(_) -> list.append(chains, [Chain(m.from, [#(m.to, m.hit)], i)])
    }
  })
}

fn notation_of(color: Color, chains: List(Chain)) -> List(String) {
  chains
  |> list.fold([], fn(groups: List(#(#(Loc, List(Loc), Loc), Bool, Int)), c) {
    let key = chain_key(c)
    let hit = chain_lands_on_a_hit(c)
    case list.any(groups, fn(g) { g.0 == key }) {
      True ->
        list.map(groups, fn(g) {
          case g.0 == key {
            True -> #(g.0, g.1 || hit, g.2 + 1)
            False -> g
          }
        })
      False -> list.append(groups, [#(key, hit, 1)])
    }
  })
  |> list.map(fn(g) {
    let #(#(from, hits_on_the_way, to), hit, n) = g
    let star = case hit {
      True -> "*"
      False -> ""
    }
    let times = case n {
      1 -> ""
      _ -> "(" <> int.to_string(n) <> ")"
    }
    let on_the_way =
      list.map(hits_on_the_way, fn(loc) { "/" <> loc_text(color, loc) <> "*" })
      |> string.join("")
    loc_text(color, from)
    <> on_the_way
    <> "/"
    <> loc_text(color, to)
    <> star
    <> times
  })
}

fn end_of(chain: Chain) -> Loc {
  case list.last(chain.stops) {
    Ok(#(loc, _)) -> loc
    Error(_) -> chain.from
  }
}

/// What makes two checkers' moves the same move: the start, the points on
/// the way where each hit, and the end.
fn chain_key(chain: Chain) -> #(Loc, List(Loc), Loc) {
  let on_the_way =
    chain.stops
    |> list.take(list.length(chain.stops) - 1)
    |> list.filter(fn(stop) { stop.1 })
    |> list.map(fn(stop) { stop.0 })
  #(chain.from, on_the_way, end_of(chain))
}

fn chain_lands_on_a_hit(chain: Chain) -> Bool {
  case list.last(chain.stops) {
    Ok(#(_, hit)) -> hit
    Error(_) -> False
  }
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
    Turn(_, dice, [], _, _) -> dice_text(dice) <> ": (no play)"
    Turn(_, dice, moves, _, _) ->
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

/// The entries of the game being played (or, once the match is over, of
/// the last game), oldest first, from the whole record kept newest first.
/// A game's entries end with its `GameOver`; the game in progress is
/// everything since the last one of an earlier game.
pub fn current_game(newest_first: List(Entry), game_number: Int) -> List(Entry) {
  newest_first
  |> list.take_while(fn(e) {
    case e {
      GameOver(number: n, ..) -> n == game_number
      _ -> True
    }
  })
  |> list.reverse
}

/// The record split into its games, oldest first: each finished game's
/// entries end with its `GameOver`. What follows the last `GameOver` (the
/// game in progress, possibly nothing yet) is the last group.
pub fn by_game(oldest_first: List(Entry)) -> List(List(Entry)) {
  let #(done, open) =
    list.fold(oldest_first, #([], []), fn(acc, e) {
      let #(done, open) = acc
      case e {
        GameOver(..) -> #([list.reverse([e, ..open]), ..done], [])
        _ -> #(done, [e, ..open])
      }
    })
  list.reverse([list.reverse(open), ..done])
}

/// The finished games' result lines, oldest first.
pub fn results(entries: List(Entry)) -> List(Entry) {
  list.filter(entries, fn(e) {
    case e {
      GameOver(..) -> True
      _ -> False
    }
  })
}

/// The entry for the wire. Every field is plain JSON a generic client can
/// read; nothing here is hidden from anyone.
pub fn to_json(entry: Entry) -> Json {
  case entry {
    Turn(player, dice, moves, position, landed) ->
      json.object([
        #("kind", json.string("turn")),
        #("player", json.string(player)),
        #("dice", json.array(dice, json.int)),
        #("moves", json.array(moves, json.string)),
        #("landed", json.array(landed, json.int)),
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
    #(
      "cube",
      json.object([
        #("value", json.int(snapshot.cube)),
        #("owner", json.nullable(snapshot.cube_owner, json.string)),
      ]),
    ),
  ])
}

pub fn side_to_json(side: Side) -> Json {
  json.object([
    #("points", json.array(side.points, json.int)),
    #("bar", json.int(side.bar)),
    #("off", json.int(side.off)),
    #("pips", json.int(side.pips)),
  ])
}
