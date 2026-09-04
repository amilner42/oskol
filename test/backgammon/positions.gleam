//// Position builders shared by the backgammon suites: exact boards for rule
//// tests and seeded random boards for property and oracle tests.

import backgammon/board.{
  type Board, type Color, type Loc, Bar, Black, Off, Point, White,
}
import backgammon/game as backgammon
import backgammon/state
import gamekit/game.{type Seat, Seat}
import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list

pub fn seats() -> List(Seat) {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

/// Build a board from (color, location, count) entries. Ids are assigned in
/// order, so the same entries always give the same board.
pub fn setup(entries: List(#(Color, Loc, Int))) -> Board {
  let #(checkers, _) =
    list.fold(entries, #([], #(0, 0)), fn(acc, entry) {
      let #(placed, #(w, b)) = acc
      let #(color, loc, n) = entry
      let start = case color {
        White -> w
        Black -> b
      }
      let ids = case n {
        0 -> []
        _ ->
          list.range(1, n)
          |> list.map(fn(i) {
            #(board.prefix(color) <> int.to_string(start + i), #(color, loc))
          })
      }
      let counts = case color {
        White -> #(w + n, b)
        Black -> #(w, b + n)
      }
      #(list.append(placed, ids), counts)
    })
  board.Board(checkers: dict.from_list(checkers))
}

/// Where a random board may put a colour's checkers.
pub type Spread {
  /// Points, bar and off tray alike.
  Anywhere
  /// Home board or off: a bearing-off position.
  Home
}

/// Fifteen checkers per colour, never sharing a point with the other colour.
pub fn random_board(rng: Rng, white: Spread, black: Spread) -> #(Board, Rng) {
  let #(checkers, rng) = place(rng, White, white, dict.new())
  let #(checkers, rng) = place(rng, Black, black, checkers)
  #(board.Board(checkers: checkers), rng)
}

fn place(
  rng: Rng,
  color: Color,
  spread: Spread,
  checkers: Dict(String, #(Color, Loc)),
) -> #(Dict(String, #(Color, Loc)), Rng) {
  list.range(1, 15)
  |> list.fold(#(checkers, rng), fn(acc, i) {
    let #(checkers, rng) = acc
    let #(loc, rng) = pick_loc(rng, color, spread)
    let loc = case loc {
      Point(p) ->
        case blocked(checkers, color, p) {
          True -> Bar
          False -> loc
        }
      _ -> loc
    }
    #(
      dict.insert(checkers, board.prefix(color) <> int.to_string(i), #(
        color,
        loc,
      )),
      rng,
    )
  })
}

fn pick_loc(rng: Rng, color: Color, spread: Spread) -> #(Loc, Rng) {
  case spread {
    Anywhere -> {
      let #(k, rng) = rng.int(rng, 26)
      let loc = case k {
        0 -> Bar
        25 -> Off
        p -> Point(p)
      }
      #(loc, rng)
    }
    Home -> {
      let #(k, rng) = rng.int(rng, 7)
      let loc = case k, color {
        0, _ -> Off
        p, White -> Point(p)
        p, Black -> Point(25 - p)
      }
      #(loc, rng)
    }
  }
}

fn blocked(checkers: Dict(String, #(Color, Loc)), color: Color, p: Int) -> Bool {
  dict.values(checkers)
  |> list.any(fn(v) { v == #(board.opponent(color), Point(p)) })
}

/// A random roll as the engine stores it: doubles expand to four dice.
pub fn random_dice(rng: Rng) -> #(List(Int), Rng) {
  let #(a, rng) = rng.int(rng, 6)
  let #(b, rng) = rng.int(rng, 6)
  let a = a + 1
  let b = b + 1
  case a == b {
    True -> #([a, a, a, a], rng)
    False -> #([a, b], rng)
  }
}

/// A single game with White (p1) to move on the given board with the dice.
pub fn position(seed: Int, b: Board, dice: List(Int)) -> state.GameState {
  let assert Ok(f) = game.find_format(backgammon.info(), "single")
  let assert Ok(s) = backgammon.init(f.config, seats(), rng.seed(seed))
  state.GameState(
    ..s,
    board: b,
    turn_board: b,
    staged: [],
    phase: state.Moving(White, dice),
    last_roll: list.take(dice, 2),
  )
}

/// Seeded random positions: a board in one of three shapes and a roll.
pub fn each_random(n: Int, f: fn(Int, Board, List(Int)) -> Nil) -> Nil {
  list.each(list.range(1, n), fn(seed) {
    let r = rng.seed(seed * 101)
    let #(mode, r) = rng.int(r, 3)
    let #(white, black) = case mode {
      0 -> #(Anywhere, Anywhere)
      1 -> #(Home, Anywhere)
      _ -> #(Home, Home)
    }
    let #(b, r) = random_board(r, white, black)
    let #(dice, _) = random_dice(r)
    f(seed, b, dice)
  })
}
