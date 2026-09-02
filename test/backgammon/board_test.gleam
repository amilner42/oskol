import backgammon/board.{Bar, Black, Move, Off, Point, White}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// A board from a compact description: #(color, point, count) entries.
fn setup(entries: List(#(board.Color, board.Loc, Int))) -> board.Board {
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
            #(board.prefix(color) <> int_to_string(start + i), #(color, loc))
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

fn int_to_string(n: Int) -> String {
  board.loc_id(Point(n))
}

fn moves(
  b: board.Board,
  color: board.Color,
  dice: List(Int),
) -> List(#(String, String)) {
  board.legal_moves(b, color, dice)
  |> list.map(fn(m) { #(board.loc_id(m.from), board.loc_id(m.to)) })
  |> list.sort(fn(x, y) { string.compare(x.0 <> x.1, y.0 <> y.1) })
}

pub fn initial_position_test() {
  let b = board.initial()
  assert board.count(b, White, Point(24)) == 2
  assert board.count(b, White, Point(13)) == 5
  assert board.count(b, White, Point(8)) == 3
  assert board.count(b, White, Point(6)) == 5
  assert board.count(b, Black, Point(1)) == 2
  assert board.count(b, Black, Point(19)) == 5
  assert board.pip_count(b, White) == 167
  assert board.pip_count(b, Black) == 167
  assert dict.size(b.checkers) == 30
}

pub fn opening_moves_test() {
  let b = board.initial()
  // 3-1 for white: classic 8/5 6/5 is available among others
  let ms = moves(b, White, [3, 1])
  assert list.contains(ms, #("8", "5"))
  assert list.contains(ms, #("6", "5"))
  // Cannot land on a point the opponent holds with two or more (black's 19 has 5)
  assert list.contains(ms, #("24", "19")) == False
}

pub fn must_enter_from_bar_first_test() {
  let b =
    setup([
      #(White, Bar, 1),
      #(White, Point(13), 5),
      #(Black, Point(20), 2),
      #(Black, Point(1), 2),
    ])
  // Die 5 enters on 20 which is blocked; die 3 enters on 22
  assert moves(b, White, [5, 3]) == [#("bar", "22")]
  // Fully blocked: no moves at all
  let blocked =
    setup([#(White, Bar, 1), #(Black, Point(22), 2), #(Black, Point(20), 2)])
  assert moves(blocked, White, [5, 3]) == []
}

pub fn hitting_a_blot_sends_it_to_the_bar_test() {
  let b = setup([#(White, Point(8), 1), #(Black, Point(5), 1)])
  let #(after, mover, hit) =
    board.apply_move(b, White, Move(Point(8), Point(5), 3))
  assert mover == "w1"
  assert hit == Some("b1")
  assert board.on_bar(after, Black) == 1
  assert board.count(after, White, Point(5)) == 1
}

pub fn larger_die_rule_test() {
  // White has a single checker on 7 (all others off). Black holds points 3 and 1...
  // Construct: only one die can be played and both are playable alone -> must use larger.
  let b =
    setup([
      #(White, Point(12), 1),
      #(Black, Point(10), 2),
      #(Black, Point(9), 2),
      #(Black, Point(4), 2),
      #(Black, Point(2), 2),
    ])
  // Dice 6 and 3: 12->6 (die 6) then 6->3 open? 3 is open (black on 4 and 2). So both playable: 12->6->3.
  // Make 3 blocked to force the rule: add black on 3.
  let b2 =
    setup([
      #(White, Point(12), 1),
      #(Black, Point(10), 2),
      #(Black, Point(9), 2),
      #(Black, Point(3), 2),
      #(Black, Point(6), 1),
    ])
  let _ = b
  // With b2: die 3 from 12 -> 9 blocked; die 6 from 12 -> 6 hits a blot, then die 3 from 6 -> 3 blocked.
  // Only one die usable overall and it must be the 6.
  assert moves(b2, White, [6, 3]) == [#("12", "6")]
}

pub fn must_play_both_dice_when_possible_test() {
  // White checker on 12 and on 5. Die 4 from 12 -> 8 is open, die 2 from 12 -> 10 blocked.
  // Playing 5->3 (die 2) first would leave die 4 from 12 -> 8 playable, fine; but 5->1 (die 4) then 12->10 blocked
  // and 1 -> off not allowed (not all home). So 5->1 must be excluded as a first move.
  let b =
    setup([
      #(White, Point(12), 1),
      #(White, Point(5), 1),
      #(Black, Point(10), 2),
      #(Black, Point(3), 2),
    ])
  let ms = moves(b, White, [4, 2])
  assert list.contains(ms, #("5", "1")) == False
  assert list.contains(ms, #("12", "8"))
}

pub fn bearing_off_requires_all_home_test() {
  let b = setup([#(White, Point(6), 2), #(White, Point(7), 1)])
  assert list.contains(moves(b, White, [6, 6]), #("6", "off")) == False
  let home = setup([#(White, Point(6), 2), #(White, Point(3), 1)])
  assert list.contains(moves(home, White, [6, 6]), #("6", "off"))
}

pub fn bearing_off_with_a_larger_die_only_from_the_highest_point_test() {
  let b = setup([#(White, Point(4), 1), #(White, Point(2), 1)])
  // Die 6: only the checker on 4 (the farthest) may bear off; the 2 may not.
  let ms = moves(b, White, [6, 1])
  assert list.contains(ms, #("4", "off"))
  assert list.contains(ms, #("2", "off")) == False
  // Exact die always works
  assert list.contains(moves(b, White, [2, 1]), #("2", "off"))
}

pub fn doubles_give_four_moves_test() {
  let b = setup([#(White, Point(13), 4)])
  let seqs = board.sequences(b, White, [2, 2, 2, 2])
  assert list.all(seqs, fn(s) { list.length(s) == 4 })
  assert seqs != []
}

pub fn win_kinds_test() {
  let single =
    setup([#(White, Off, 15), #(Black, Off, 1), #(Black, Point(20), 14)])
  assert board.win_kind(single, White) == board.Single
  let gammon = setup([#(White, Off, 15), #(Black, Point(20), 15)])
  assert board.win_kind(gammon, White) == board.Gammon
  let backgammon =
    setup([#(White, Off, 15), #(Black, Point(3), 1), #(Black, Point(20), 14)])
  assert board.win_kind(backgammon, White) == board.Backgammon
  let on_bar =
    setup([#(White, Off, 15), #(Black, Bar, 1), #(Black, Point(20), 14)])
  assert board.win_kind(on_bar, White) == board.Backgammon
  assert board.points_for(board.Backgammon) == 3
}

pub fn loc_parsing_round_trips_test() {
  assert board.parse_loc("bar") == Ok(Bar)
  assert board.parse_loc("off") == Ok(Off)
  assert board.parse_loc("17") == Ok(Point(17))
  assert board.parse_loc("25") == Error(Nil)
  assert board.parse_loc("x") == Error(Nil)
  assert board.occupant(board.initial(), 3) == #(None, 0)
}
