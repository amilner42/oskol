//// Board-level rules in controlled positions: liberties, capture order,
//// suicide, point ids, canonical positions.

import gleam/list
import gleam/set
import go/board.{Black, White}

pub fn point_ids_round_trip_test() {
  let b = board.new(9)
  assert board.point_id(b, board.index(b, 0, 0)) == "p0-0"
  assert board.point_id(b, board.index(b, 8, 0)) == "p8-0"
  assert board.point_id(b, board.index(b, 3, 7)) == "p3-7"
  list.each(list.range(0, 80), fn(point) {
    assert board.parse_point(b, board.point_id(b, point)) == Ok(point)
  })
  assert board.parse_point(b, "p9-0") == Error(Nil)
  assert board.parse_point(b, "p0-9") == Error(Nil)
  assert board.parse_point(b, "x1-1") == Error(Nil)
  assert board.parse_point(b, "p1") == Error(Nil)
  assert board.parse_point(b, "s3") == Error(Nil)
}

pub fn liberties_center_edge_corner_test() {
  let b =
    board.from_rows([
      "b...w",
      ".....",
      "..b..",
      ".....",
      "w...b",
    ])
  // Corners have two liberties, the center stone four.
  let #(_, corner) = board.group(b, board.index(b, 0, 0))
  assert corner == 2
  let #(_, far_corner) = board.group(b, board.index(b, 4, 4))
  assert far_corner == 2
  let #(_, center) = board.group(b, board.index(b, 2, 2))
  assert center == 4
  // An edge stone has three.
  let edge = board.from_rows([".b...", ".....", ".....", ".....", "....."])
  let #(_, on_edge) = board.group(edge, board.index(edge, 1, 0))
  assert on_edge == 3
}

pub fn a_group_connects_orthogonally_and_shares_liberties_test() {
  let b =
    board.from_rows([
      ".bb..",
      "bbw..",
      ".b...",
      "...b.",
      ".....",
    ])
  let #(stones, liberties) = board.group(b, board.index(b, 1, 1))
  // Five connected stones; the diagonal stone at (3,3) and the white stone
  // are not part of the group.
  assert set.size(stones) == 5
  assert !set.contains(stones, board.index(b, 3, 3))
  assert !set.contains(stones, board.index(b, 2, 1))
  // Distinct liberties: (0,0), (3,0), (0,2), (2,2), (1,3).
  assert liberties == 5
}

pub fn single_stone_capture_test() {
  let b =
    board.from_rows([
      ".b...",
      "bw...",
      ".....",
      ".....",
      ".....",
    ])
  // The white stone has two liberties, (2,1) and (1,2); fill both.
  let assert Ok(#(b2, [])) = board.place(b, board.index(b, 2, 1), Black)
  let assert Ok(#(b3, captured)) = board.place(b2, board.index(b2, 1, 2), Black)
  assert captured == [board.index(b3, 1, 1)]
  assert board.stone_at(b3, board.index(b3, 1, 1)) == Error(Nil)
  assert board.stone_count(b3, White) == 0
  assert board.stone_count(b3, Black) == 4
}

pub fn multi_stone_group_capture_test() {
  let b =
    board.from_rows([
      ".bb..",
      "bww..",
      ".bb..",
      ".....",
      ".....",
    ])
  // The two-stone white group has one liberty left, (3,1).
  let #(_, liberties) = board.group(b, board.index(b, 1, 1))
  assert liberties == 1
  let assert Ok(#(b2, captured)) = board.place(b, board.index(b, 3, 1), Black)
  assert captured == [board.index(b, 1, 1), board.index(b, 2, 1)]
  assert board.stone_count(b2, White) == 0
  assert board.stone_count(b2, Black) == 6
}

pub fn occupied_point_is_rejected_test() {
  let b = board.from_rows(["b....", ".....", ".....", ".....", "....."])
  assert board.place(b, board.index(b, 0, 0), White) == Error(board.Occupied)
  assert board.place(b, board.index(b, 0, 0), Black) == Error(board.Occupied)
}

pub fn single_stone_suicide_is_rejected_test() {
  let b =
    board.from_rows([
      ".b...",
      "b.b..",
      ".b...",
      ".....",
      ".....",
    ])
  assert board.place(b, board.index(b, 1, 1), White) == Error(board.Suicide)
  // The same point is no suicide for black: it connects to its own stones.
  let assert Ok(#(_, [])) = board.place(b, board.index(b, 1, 1), Black)
}

pub fn multi_stone_suicide_is_rejected_test() {
  // White playing (2,1) joins its stone at (1,1) into a two-stone group
  // with no liberties, capturing nothing: suicide.
  let b =
    board.from_rows([
      ".bb..",
      "bw.b.",
      ".bb..",
      ".....",
      ".....",
    ])
  assert board.place(b, board.index(b, 2, 1), White) == Error(board.Suicide)
}

pub fn capture_happens_before_the_suicide_check_test() {
  // Black plays (2,1), all four neighbors white. It would be suicide were
  // the white stone at (1,1) not captured first: (2,1) is its last liberty.
  let b =
    board.from_rows([
      ".bw..",
      "bw.w.",
      ".bw..",
      ".....",
      ".....",
    ])
  let point = board.index(b, 2, 1)
  let assert Ok(#(b2, captured)) = board.place(b, point, Black)
  assert captured == [board.index(b, 1, 1)]
  assert board.stone_at(b2, point) == Ok(Black)
  // The captured point is the new stone's only liberty.
  let #(_, liberties) = board.group(b2, point)
  assert liberties == 1
}

pub fn canonical_reflects_the_position_test() {
  let empty = board.new(3)
  assert board.canonical(empty) == "........."
  let b = board.from_rows(["b.w", "...", "w.b"])
  assert board.canonical(b) == "b.w...w.b"
  let assert Ok(#(b2, [])) = board.place(b, board.index(b, 1, 1), Black)
  assert board.canonical(b2) == "b.w.b.w.b"
}

pub fn placeable_points_excludes_occupied_and_suicide_test() {
  let b =
    board.from_rows([
      ".b...",
      "b.b..",
      ".b...",
      ".....",
      ".....",
    ])
  let white_points = board.placeable_points(b, White)
  assert !list.contains(white_points, board.index(b, 1, 1))
  assert !list.contains(white_points, board.index(b, 1, 0))
  // 25 points minus 4 occupied minus the suicides at (1,1) and the corner
  // (0,0), whose only neighbors are black.
  assert !list.contains(white_points, board.index(b, 0, 0))
  assert list.length(white_points) == 19
  assert list.contains(board.placeable_points(b, Black), board.index(b, 1, 1))
}
