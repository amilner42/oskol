//// An independent move generator checked against the engine's.
////
//// The oracle restates the movement rules from scratch on raw checker data
//// and enumerates die orders explicitly, so it shares no code with
//// `board.sequences`. If the two disagree on any random board, one of them
//// has the rules wrong.

import backgammon/board.{
  type Board, type Color, type Loc, type Move, Bar, Black, Move, Off, Point,
  White,
}
import backgammon/positions
import gleam/dict
import gleam/int
import gleam/list
import gleam/string

// ---------- the oracle ----------

fn other(c: Color) -> Color {
  case c {
    White -> Black
    Black -> White
  }
}

fn step(c: Color) -> Int {
  case c {
    White -> -1
    Black -> 1
  }
}

fn distance(c: Color, p: Int) -> Int {
  case c {
    White -> p
    Black -> 25 - p
  }
}

fn home(c: Color, p: Int) -> Bool {
  case c {
    White -> p <= 6
    Black -> p >= 19
  }
}

fn checkers(b: Board, c: Color, loc: Loc) -> List(String) {
  dict.to_list(b.checkers)
  |> list.filter_map(fn(e) {
    case e.1 == #(c, loc) {
      True -> Ok(e.0)
      False -> Error(Nil)
    }
  })
}

fn count(b: Board, c: Color, loc: Loc) -> Int {
  list.length(checkers(b, c, loc))
}

fn own_points(b: Board, c: Color) -> List(Int) {
  dict.values(b.checkers)
  |> list.filter_map(fn(v) {
    case v {
      #(col, Point(p)) if col == c -> Ok(p)
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(int.compare)
}

fn open(b: Board, c: Color, p: Int) -> Bool {
  count(b, other(c), Point(p)) <= 1
}

fn may_bear_off(b: Board, c: Color) -> Bool {
  count(b, c, Bar) == 0 && list.all(own_points(b, c), home(c, _))
}

/// Every move one die allows, straight from the rulebook.
fn moves_for(b: Board, c: Color, d: Int) -> List(Move) {
  case count(b, c, Bar) > 0 {
    True -> {
      let entry = case c {
        White -> 25 - d
        Black -> d
      }
      case open(b, c, entry) {
        True -> [Move(Bar, Point(entry), d)]
        False -> []
      }
    }
    False -> {
      let points = own_points(b, c)
      let farthest =
        list.fold(points, 0, fn(acc, p) { int.max(acc, distance(c, p)) })
      list.filter_map(points, fn(p) {
        let target = p + step(c) * d
        case target >= 1 && target <= 24 {
          True ->
            case open(b, c, target) {
              True -> Ok(Move(Point(p), Point(target), d))
              False -> Error(Nil)
            }
          False ->
            case
              may_bear_off(b, c)
              && { distance(c, p) == d || distance(c, p) == farthest }
            {
              True -> Ok(Move(Point(p), Off, d))
              False -> Error(Nil)
            }
        }
      })
    }
  }
}

fn apply(b: Board, c: Color, m: Move) -> Board {
  let assert [id, ..] = checkers(b, c, m.from)
  let moved = dict.insert(b.checkers, id, #(c, m.to))
  let moved = case m.to {
    Point(p) ->
      case checkers(b, other(c), Point(p)) {
        [blot] -> dict.insert(moved, blot, #(other(c), Bar))
        _ -> moved
      }
    _ -> moved
  }
  board.Board(checkers: moved)
}

/// Every way to play the dice in this exact order, stopping at the first die
/// that cannot be played.
fn plays(b: Board, c: Color, order: List(Int)) -> List(List(Move)) {
  case order {
    [] -> [[]]
    [d, ..rest] ->
      case moves_for(b, c, d) {
        [] -> [[]]
        ms ->
          list.flat_map(ms, fn(m) {
            plays(apply(b, c, m), c, rest)
            |> list.map(fn(tail) { [m, ..tail] })
          })
      }
  }
}

fn oracle_sequences(b: Board, c: Color, dice: List(Int)) -> List(List(Move)) {
  let orders = case dice {
    [x, y] if x != y -> [[x, y], [y, x]]
    _ -> [dice]
  }
  let all =
    list.flat_map(orders, fn(order) { plays(b, c, order) }) |> list.unique
  let longest = list.fold(all, 0, fn(acc, s) { int.max(acc, list.length(s)) })
  let best = list.filter(all, fn(s) { list.length(s) == longest })
  case longest, dice {
    0, _ -> []
    1, [x, y] if x != y -> {
      let bigger = int.max(x, y)
      let using_bigger =
        list.filter(best, fn(s) {
          case s {
            [m] -> m.die == bigger
            _ -> False
          }
        })
      case using_bigger {
        [] -> best
        _ -> using_bigger
      }
    }
    _, _ -> best
  }
}

// ---------- comparison ----------

fn move_key(m: Move) -> String {
  board.loc_id(m.from)
  <> ">"
  <> board.loc_id(m.to)
  <> "/"
  <> int.to_string(m.die)
}

fn normalize(seqs: List(List(Move))) -> List(String) {
  list.map(seqs, fn(s) { list.map(s, move_key) |> string.join(" ") })
  |> list.unique
  |> list.sort(string.compare)
}

fn check(b: Board, c: Color, dice: List(Int)) -> Nil {
  let expected = normalize(oracle_sequences(b, c, dice))
  let actual = normalize(board.sequences(b, c, dice))
  case expected == actual {
    True -> Nil
    False -> {
      let message =
        "Move generation differs for "
        <> board.color_name(c)
        <> " with dice "
        <> string.inspect(dice)
        <> "\nboard: "
        <> string.inspect(
          list.sort(dict.to_list(b.checkers), fn(x, y) {
            string.compare(x.0, y.0)
          }),
        )
        <> "\noracle: "
        <> string.inspect(expected)
        <> "\nengine: "
        <> string.inspect(actual)
      panic as message
    }
  }
  let firsts =
    oracle_sequences(b, c, dice)
    |> list.filter_map(list.first)
    |> list.map(move_key)
    |> list.unique
    |> list.sort(string.compare)
  let engine_firsts =
    board.legal_moves(b, c, dice)
    |> list.map(move_key)
    |> list.sort(string.compare)
  assert firsts == engine_firsts
}

pub fn move_generation_matches_the_oracle_on_random_boards_test() {
  positions.each_random(240, fn(_seed, b, dice) {
    check(b, White, dice)
    check(b, Black, dice)
    // Mid-turn: after the first move of some sequence, the remaining dice
    case board.sequences(b, White, dice) {
      [[first, ..], ..] -> {
        let #(next, _, _) = board.apply_move(b, White, first)
        check(next, White, remove_one(dice, first.die))
      }
      _ -> Nil
    }
  })
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

// ---------- named positions the oracle must also get right ----------

fn expect(b: Board, c: Color, dice: List(Int), sequences: List(String)) -> Nil {
  check(b, c, dice)
  assert normalize(board.sequences(b, c, dice))
    == list.sort(sequences, string.compare)
}

pub fn bearing_off_with_a_larger_die_only_from_the_farthest_point_test() {
  let b =
    positions.setup([
      #(White, Point(6), 1),
      #(White, Point(2), 1),
      #(Black, Point(20), 2),
    ])
  expect(b, White, [6, 4], ["6>off/6 2>off/4", "6>2/4 2>off/6"])
}

pub fn when_only_one_die_can_be_played_it_must_be_the_larger_test() {
  // 24->18 then 18->14 is blocked, 24->20 then 20->14 is blocked: either die
  // alone plays, so the 6 must be used.
  let b = positions.setup([#(White, Point(24), 1), #(Black, Point(14), 2)])
  expect(b, White, [6, 4], ["24>18/6"])
}

pub fn a_checker_on_the_bar_must_enter_before_anything_else_test() {
  let b =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(13), 1),
      #(Black, Point(19), 2),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
      #(Black, Point(22), 2),
    ])
  expect(b, White, [6, 2], ["bar>23/2 23>17/6", "bar>23/2 13>7/6"])
}

pub fn doubles_play_up_to_four_times_test() {
  let b = positions.setup([#(White, Point(13), 1), #(Black, Point(24), 2)])
  expect(b, White, [3, 3, 3, 3], ["13>10/3 10>7/3 7>4/3 4>1/3"])
}

pub fn a_fully_blocked_roll_has_no_sequences_test() {
  let b =
    positions.setup([
      #(White, Point(24), 2),
      #(Black, Point(18), 2),
      #(Black, Point(20), 2),
    ])
  expect(b, White, [6, 4], [])
}
