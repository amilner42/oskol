//// The legal-move DAG a puzzle is played on, in controlled positions.
////
//// The playouts elsewhere prove nothing crashes; these prove the rules are
//// right, which is the whole point of sending the moves from the server: a
//// child the page is offered is a move the rulebook allows, and a node it
//// is allowed to PLAY on is one where nothing more can be played.

import backgammon/analysis
import backgammon/board.{type Board, Bar, Black, Off, Point, White}
import backgammon/positions
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/puzzles/tree

const no_limit = 1_000_000

/// The tree for a board and a roll, as the handler builds it.
fn built(b: Board, roll: #(Int, Int)) -> tree.Tree {
  let assert Ok(t) = tree.build(b, tree.dice_of(roll), no_limit)
  t
}

fn root(t: tree.Tree) -> tree.Node {
  let assert Ok(node) = list.find(t.nodes, fn(n) { n.id == tree.root_id })
  node
}

fn node(t: tree.Tree, id: String) -> tree.Node {
  let assert Ok(node) = list.find(t.nodes, fn(n) { n.id == id })
  node
}

/// A child as it reads: "6 13/7".
fn step(child: tree.Child) -> String {
  int.to_string(child.die)
  <> " "
  <> board.loc_id(child.from)
  <> "/"
  <> board.loc_id(child.to)
}

fn steps(node: tree.Node) -> List(String) {
  node.children |> list.map(step) |> list.sort(string.compare)
}

fn terminal(node: tree.Node) -> Bool {
  node.children == []
}

// ---------- The board a question stores ----------

pub fn from_engine_round_trips_test() {
  // The opening position, drawn from White's side, back into a board that
  // is the opening position.
  let opening = analysis.encode(board.initial(), White)
  let assert Ok(b) = tree.from_engine(opening)
  assert analysis.encode(b, White) == opening
  assert board.borne_off(b, White) == 0
  assert board.borne_off(b, Black) == 0
}

pub fn from_engine_counts_checkers_off_test() {
  // Thirteen borne off, two on the board: the engine board says nothing
  // about the tray, so what is not on it and not on the bar is off.
  let b =
    positions.setup([
      #(White, Point(1), 1),
      #(White, Point(2), 1),
      #(White, Off, 13),
      #(Black, Point(20), 5),
      #(Black, Point(22), 5),
      #(Black, Point(24), 5),
    ])
  let assert Ok(back) = tree.from_engine(analysis.encode(b, White))
  assert board.borne_off(back, White) == 13
  assert board.count(back, White, Point(1)) == 1
  assert board.count(back, Black, Point(20)) == 5
}

pub fn from_engine_refuses_a_non_board_test() {
  assert tree.from_engine([]) == Error(Nil)
  assert tree.from_engine([0, 0, 0]) == Error(Nil)
}

// ---------- The rules, one node at a time ----------

/// White on the bar against a 6-3: only the 6 enters, so the larger die
/// must be played and the turn is over with the 3 standing.
pub fn bar_entry_takes_the_larger_die_test() {
  let b =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(4), 4),
      #(White, Point(5), 5),
      #(White, Point(6), 5),
      #(Black, Point(1), 2),
      #(Black, Point(2), 2),
      #(Black, Point(3), 2),
      #(Black, Point(16), 2),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
      #(Black, Point(23), 3),
    ])
  let t = built(b, #(6, 3))
  // The 3 would enter on 22, which is open -- but nothing could follow it,
  // and only one die can be played, so it must be the bigger one.
  assert steps(root(t)) == ["6 bar/19"]
  let assert [only] = root(t).children
  assert terminal(node(t, only.node))
  assert node(t, only.node).dice_left == [3]
}

/// A checker on the bar is played before anything else: no other checker
/// may move while one is up.
pub fn nothing_moves_while_a_checker_is_on_the_bar_test() {
  let b =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(13), 2),
      #(White, Point(8), 3),
      #(White, Point(6), 5),
      #(White, Point(5), 4),
      #(Black, Point(1), 2),
      #(Black, Point(12), 5),
      #(Black, Point(17), 3),
      #(Black, Point(19), 5),
    ])
  let t = built(b, #(4, 2))
  assert list.all(root(t).children, fn(c) { c.from == Bar })
}

/// A turn that can play nothing: the root is where it starts and where it
/// ends, and PLAY is offered there.
pub fn a_danced_roll_makes_the_root_terminal_test() {
  let b =
    positions.setup([
      #(White, Bar, 1),
      #(White, Point(13), 5),
      #(White, Point(8), 5),
      #(White, Point(6), 4),
      // Every entry point shut.
      #(Black, Point(19), 2),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
      #(Black, Point(22), 3),
      #(Black, Point(23), 3),
      #(Black, Point(24), 3),
    ])
  let t = built(b, #(6, 5))
  assert list.length(t.nodes) == 1
  assert terminal(root(t))
  assert root(t).dice_left == [6, 5]
  assert root(t).moved == None
}

/// Both dice have to be played where both can be: a first move that would
/// strand the other die is not offered, even though it is a legal move on
/// its own.
pub fn a_move_that_strands_a_die_is_not_offered_test() {
  // White has two checkers that can move and a 6-1. 13/12 is a perfectly
  // good one on its own, but after it the six has nowhere to go (6 and 14
  // are shut, and nothing is home), so the turn would play one die where it
  // can play both. It is not offered; 20/19 is, because the six still
  // follows it.
  let b =
    positions.setup([
      #(White, Point(13), 1),
      #(White, Point(20), 1),
      #(White, Point(4), 13),
      #(Black, Point(1), 5),
      #(Black, Point(2), 4),
      #(Black, Point(3), 2),
      #(Black, Point(6), 2),
      #(Black, Point(14), 2),
    ])
  let t = built(b, #(6, 1))
  assert steps(root(t)) == ["1 20/19", "6 13/7"]
  // And both of those really do play both dice.
  assert list.all(root(t).children, fn(c) {
    let after = node(t, c.node)
    after.children != []
    && list.all(after.children, fn(g) { terminal(node(t, g.node)) })
  })
}

/// Two orders of the same two checkers reach one node, and the hit is
/// carried on the step that made it.
pub fn two_orders_reach_one_node_test() {
  let b =
    positions.setup([
      #(White, Point(13), 2),
      #(White, Point(4), 4),
      #(White, Point(5), 4),
      #(White, Point(6), 5),
      #(Black, Point(1), 2),
      #(Black, Point(2), 2),
      #(Black, Point(7), 1),
      #(Black, Point(17), 3),
      #(Black, Point(18), 3),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
    ])
  let t = built(b, #(6, 4))
  assert steps(root(t)) == ["4 13/9", "6 13/7"]
  let assert Ok(six) = list.find(root(t).children, fn(c) { c.die == 6 })
  let assert Ok(four) = list.find(root(t).children, fn(c) { c.die == 4 })
  // 6 then 4, and 4 then 6, both land on the same board.
  let after_six = node(t, six.node)
  let after_four = node(t, four.node)
  let assert Ok(then_four) =
    list.find(after_six.children, fn(c) { c.die == 4 && c.from == Point(13) })
  let assert Ok(then_six) =
    list.find(after_four.children, fn(c) { c.die == 6 && c.from == Point(13) })
  assert then_four.node == then_six.node
  assert terminal(node(t, then_four.node))
  // The hit is on the step that made it, and only there.
  assert after_six.moved == Some(tree.Moved(Point(13), Point(7), True))
  assert after_four.moved == Some(tree.Moved(Point(13), Point(9), False))
  assert board.on_bar(after_six.board, Black) == 1
  assert board.on_bar(after_four.board, Black) == 0
}

/// Bearing off: the tray is `off`, and a checker that either die takes off
/// leaves two different nodes, because what is left to play differs.
pub fn bearing_off_names_the_tray_test() {
  let b =
    positions.setup([
      #(White, Point(1), 1),
      #(White, Point(2), 1),
      #(White, Off, 13),
      #(Black, Point(20), 5),
      #(Black, Point(22), 5),
      #(Black, Point(24), 5),
    ])
  let t = built(b, #(5, 2))
  assert steps(root(t)) == ["2 2/off", "5 2/off"]
  // Four nodes: the root, one per die spent on the checker on 2, and the
  // one both of them lead to.
  assert list.length(t.nodes) == 4
  let assert [a, c] = root(t).children
  let assert [after_a] = node(t, a.node).children
  let assert [after_c] = node(t, c.node).children
  assert after_a.node == after_c.node
  assert after_a.to == Off
  let end = node(t, after_a.node)
  assert terminal(end)
  assert board.borne_off(end.board, White) == 15
}

/// Doubles: four of the same die, and every order of the same checkers is
/// one node.
pub fn doubles_merge_every_order_test() {
  let b =
    positions.setup([
      #(White, Point(13), 2),
      #(White, Point(4), 4),
      #(White, Point(5), 4),
      #(White, Point(6), 5),
      #(Black, Point(1), 2),
      #(Black, Point(2), 2),
      #(Black, Point(3), 2),
      #(Black, Point(20), 3),
      #(Black, Point(22), 3),
      #(Black, Point(24), 3),
    ])
  let t = built(b, #(3, 3))
  assert root(t).dice_left == [3, 3, 3, 3]
  // Two runners walking 13/10/7/4 in every order: eight positions, and the
  // two ways of reaching the middle ones are one node each.
  assert list.length(t.nodes) == 8
  assert list.length(list.filter(t.nodes, terminal)) == 2
  // Every child names a node the tree holds, and every node but the root
  // was reached by a step.
  assert list.all(t.nodes, fn(n) {
    list.all(n.children, fn(c) {
      list.any(t.nodes, fn(other) { other.id == c.node })
    })
  })
  assert list.all(t.nodes, fn(n) { n.id == tree.root_id || n.moved != None })
}

/// Fifteen checkers a side in every node, always: a tree that loses one has
/// applied a move wrongly.
pub fn every_node_keeps_fifteen_checkers_test() {
  positions.each_random(60, fn(_seed, b, dice) {
    let roll = case dice {
      [a, c, ..] -> #(int.max(a, c), int.min(a, c))
      _ -> #(6, 5)
    }
    let assert Ok(t) = tree.build(b, tree.dice_of(roll), no_limit)
    assert list.all(t.nodes, fn(n) {
      count_of(n.board, White) == 15 && count_of(n.board, Black) == 15
    })
  })
}

fn count_of(b: Board, color: board.Color) -> Int {
  dict.fold(b.checkers, 0, fn(total, _id, entry) {
    case entry.0 == color {
      True -> total + 1
      False -> total
    }
  })
}

/// The children of a node are the first moves of the sequences the rulebook
/// generator produces, at every node, on random positions. This is the
/// whole rules claim, checked against the code the table itself plays by.
pub fn children_agree_with_the_move_generator_test() {
  positions.each_random(40, fn(_seed, b, dice) {
    let roll = case dice {
      [a, c, ..] -> #(int.max(a, c), int.min(a, c))
      _ -> #(6, 5)
    }
    let assert Ok(t) = tree.build(b, tree.dice_of(roll), no_limit)
    assert list.all(t.nodes, fn(n) {
      let wanted =
        board.legal_moves(n.board, White, n.dice_left)
        |> list.map(fn(m) {
          int.to_string(m.die)
          <> " "
          <> board.loc_id(m.from)
          <> "/"
          <> board.loc_id(m.to)
        })
        |> list.sort(string.compare)
      steps(n) == wanted
    })
  })
}

// ---------- The budget, and the level-at-a-time fallback ----------

/// A position that needs more than the budget allows gives nothing, so the
/// caller serves the root alone instead of a megabyte.
pub fn a_build_over_the_budget_gives_up_test() {
  let spread =
    positions.setup(
      list.append(
        list.range(10, 24) |> list.map(fn(p) { #(White, Point(p), 1) }),
        [
          #(Black, Point(1), 4),
          #(Black, Point(2), 4),
          #(Black, Point(3), 4),
          #(Black, Point(4), 3),
        ],
      ),
    )
  assert tree.build(spread, [1, 1, 1, 1], 260) == Error(Nil)
  // And the root alone is always available.
  let lazy = tree.lazy_root(spread, [1, 1, 1, 1])
  assert lazy.lazy
  assert list.length(lazy.nodes) == 1
  assert list.length(root(lazy).children) == 15
}

/// A lazily served node carries its own position, so the server can answer
/// for it without keeping anything.
pub fn a_lazy_id_reads_back_test() {
  let b =
    positions.setup([
      #(White, Point(13), 2),
      #(White, Point(6), 13),
      #(Black, Point(1), 2),
      #(Black, Point(12), 13),
    ])
  let id = tree.lazy_id(b, [4], Some(tree.Moved(Point(13), Point(7), True)))
  let assert Ok(#(back, dice, moved)) = tree.from_lazy_id(id)
  assert dice == [4]
  assert moved == Some(tree.Moved(Point(13), Point(7), True))
  assert analysis.encode(back, White) == analysis.encode(b, White)
}

pub fn a_made_up_node_id_is_refused_test() {
  assert tree.from_lazy_id("") == Error(Nil)
  assert tree.from_lazy_id("r") == Error(Nil)
  assert tree.from_lazy_id("znotbase16") == Error(Nil)
  // Well-formed hex that is not a board.
  assert tree.from_lazy_id("z6162") == Error(Nil)
}

/// One level worked out on its own says exactly what the whole tree would
/// have said about that node.
pub fn a_level_matches_the_whole_tree_test() {
  let b =
    positions.setup([
      #(White, Point(13), 2),
      #(White, Point(4), 4),
      #(White, Point(5), 4),
      #(White, Point(6), 5),
      #(Black, Point(1), 2),
      #(Black, Point(2), 2),
      #(Black, Point(7), 1),
      #(Black, Point(17), 3),
      #(Black, Point(18), 3),
      #(Black, Point(20), 2),
      #(Black, Point(21), 2),
    ])
  let whole = built(b, #(6, 4))
  let level = tree.level(b, tree.dice_of(#(6, 4)), None, tree.root_id)
  assert steps(level) == steps(root(whole))
  assert level.dice_left == root(whole).dice_left
}

// ---------- What goes on the wire ----------

/// The board is drawn with the mover as White, its points numbered from the
/// mover's side, and the two sides carry only what the page reads.
pub fn the_wire_board_is_mover_relative_test() {
  let b =
    positions.setup([
      #(White, Point(1), 1),
      #(White, Point(2), 1),
      #(White, Off, 13),
      #(Black, Point(20), 5),
      #(Black, Point(22), 5),
      #(Black, Point(24), 5),
    ])
  let text = json.to_string(tree.board_json(b))
  assert string.contains(
    text,
    "\"white\":{\"points\":[1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],\"bar\":0,\"off\":13}",
  )
  assert string.contains(
    text,
    "\"black\":{\"points\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,5,0,5],\"bar\":0,\"off\":0}",
  )
}

/// An eager tree says nothing about being lazy; a lazy one says so.
pub fn only_a_lazy_tree_says_lazy_test() {
  let b = board.initial()
  let eager = built(b, #(3, 1))
  assert !string.contains(json.to_string(tree.to_json(eager)), "lazy")
  assert string.contains(
    json.to_string(tree.to_json(tree.lazy_root(b, [3, 1]))),
    "\"lazy\":true",
  )
}
