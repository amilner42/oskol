//// Every legal way to play a puzzle's roll, as a graph the page can walk.
////
//// A puzzle asks "what's your play?", and the page has to let the player
//// make it -- on a phone, with taps, with undo, with the bear-off tray and
//// the quick pair. The client owns none of the rules: this module works the
//// whole turn out on the server and sends it as node snapshots, so a tap is
//// a walk to a child and undo is a walk back to the parent. There is no
//// round trip per checker and no move generator in Elm.
////
//// **Nodes are positions, not sequences.** A double gives thousands of
//// orderings of the same few checkers; merged by the board they leave (and
//// the dice still to play) they are a few hundred. That merge is what makes
//// the graph a DAG and what keeps it inside the wire budget.
////
//// **The rules are already applied.** A node's children are exactly the
//// taps the rulebook allows next: a move only survives if it still leads to
//// a longest play (must use as many dice as possible), and at the question's
//// own roll, where only one die can be played, only the larger one is
//// offered. `terminal` is true exactly where nothing more can be played,
//// which is where PLAY is offered and nowhere else.
////
//// **The mover is White.** A question stores its board from the player on
//// roll's side (`backgammon/analysis`), and Oskol's White runs the same way:
//// 24 -> 1, entering onto 24..19, bearing off from 6..1. So the engine's
//// 26-int board reads straight across, and the page draws the solver at the
//// bottom whatever colour they really had.
////
//// The search is memoised on (board, dice left) rather than run per node:
//// asking `board.sequences` at every node would redo the exponential walk
//// once per node, and the contrived worst case is 35,370 sequences.

import backgammon/board.{
  type Board, type Color, type Loc, type Move, Bar, Black, Board, Off, Point,
  White,
}
import backgammon/record
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The step that reached a node. Decoration: the page reads what may move
/// next off `children`, never off here.
pub type Moved {
  Moved(from: Loc, to: Loc, hit: Bool)
}

/// One checker move and the node it reaches.
pub type Child {
  Child(die: Int, from: Loc, to: Loc, node: String)
}

pub type Node {
  Node(
    id: String,
    board: Board,
    dice_left: List(Int),
    moved: Option(Moved),
    children: List(Child),
  )
}

/// The whole turn. `lazy` says only the root is here and the rest is fetched
/// a level at a time (`GET /papi/puzzles/:id/tree?node=`).
pub type Tree {
  Tree(root: String, nodes: List(Node), lazy: Bool)
}

/// The id of the root of an eager tree. Short on purpose: an id is repeated
/// once per edge, and the wire budget is bytes.
pub const root_id = "r"

// ---------- The board a question stores ----------

/// The engine's 26-int board as a board to play on, with the mover as
/// White: index 0 is the opponent's bar, 1..24 the points the mover runs
/// 24 -> 1 along (theirs positive), 25 the mover's own bar. Error when the
/// list is not a board.
pub fn from_engine(engine: List(Int)) -> Result(Board, Nil) {
  case engine {
    [black_bar, ..rest] ->
      case list.length(rest) == 25 {
        False -> Error(Nil)
        True -> {
          let points = list.take(rest, 24)
          let white_bar = list.drop(rest, 24) |> list.first |> result.unwrap(0)
          let white_points =
            list.index_map(points, fn(n, i) { #(i + 1, int.max(0, n)) })
          let black_points =
            list.index_map(points, fn(n, i) { #(i + 1, int.max(0, -n)) })
          Ok(
            Board(
              checkers: dict.from_list(list.append(
                place(White, white_points, white_bar),
                place(Black, black_points, black_bar),
              )),
            ),
          )
        }
      }
    [] -> Error(Nil)
  }
}

/// Fifteen checkers of one colour: the ones the board names, then the bar,
/// and whatever is left over is borne off. Ids are the game's own
/// ("w1".."b15") so a board built here is a board like any other.
fn place(
  color: Color,
  points: List(#(Int, Int)),
  bar: Int,
) -> List(#(String, #(Color, Loc))) {
  let on_points =
    points
    |> list.flat_map(fn(entry) { list.repeat(Point(entry.0), entry.1) })
  let locs =
    list.flatten([
      on_points,
      list.repeat(Bar, bar),
      list.repeat(Off, int.max(0, 15 - list.length(on_points) - bar)),
    ])
  list.index_map(locs, fn(loc, i) {
    #(board.prefix(color) <> int.to_string(i + 1), #(color, loc))
  })
}

/// The dice of a roll as the turn plays them: four of a double, else the
/// two, higher first (which is how a question stores them).
pub fn dice_of(roll: #(Int, Int)) -> List(Int) {
  let #(high, low) = roll
  case high == low {
    True -> [high, high, high, high]
    False -> [int.max(high, low), int.min(high, low)]
  }
}

// ---------- Building ----------

type Build {
  Build(
    nodes: Dict(String, Node),
    /// Node keys in the order they were found, newest first.
    found: List(String),
    /// (board, dice left) -> the id already given to it.
    ids: Dict(String, String),
    /// (board, dice left) -> how many dice can still be played from there.
    depths: Dict(String, Int),
    next: Int,
    /// The build outgrew its budget and the caller gets nothing.
    over: Bool,
    limit: Int,
  )
}

/// The whole turn from this position, or Error when it needs more than
/// `max_nodes` positions to say it -- the caller then serves the root alone
/// and answers for each level as the page reaches it.
pub fn build(start: Board, dice: List(Int), max_nodes: Int) -> Result(Tree, Nil) {
  let #(st, _) = walk(fresh(max_nodes), start, dice, None)
  case st.over {
    True -> Error(Nil)
    False ->
      Ok(Tree(
        root: root_id,
        nodes: st.found
          |> list.reverse
          |> list.filter_map(dict.get(st.nodes, _)),
        lazy: False,
      ))
  }
}

/// The node for this position, adding it and everything it leads to. A
/// position already reached by another order of the same checkers keeps the
/// id it was given: that merge is the whole point of the DAG.
///
/// The id is taken on the way in, so the root -- the first position asked
/// about -- is `root_id` and the rest are numbered in the order they were
/// discovered. Nothing can be waiting for an id that is not there yet: a
/// step always spends a die, so a position can never lead back to itself.
fn walk(
  st: Build,
  b: Board,
  dice: List(Int),
  moved: Option(Moved),
) -> #(Build, String) {
  let key = state_key(b, dice)
  case st.over, dict.get(st.ids, key) {
    True, _ -> #(st, "")
    False, Ok(id) -> #(st, id)
    False, Error(_) -> {
      let id = case st.next {
        0 -> root_id
        n -> "n" <> int.to_string(n)
      }
      let st =
        Build(
          ..st,
          next: st.next + 1,
          ids: dict.insert(st.ids, key, id),
          found: [key, ..st.found],
        )
      case st.next > st.limit {
        True -> #(Build(..st, over: True), "")
        False -> {
          let #(st, moves) = children_moves(st, b, dice)
          let #(st, children) =
            list.fold(moves, #(st, []), fn(acc, move) {
              let #(st, children) = acc
              let #(next, _mover, hit) = board.apply_move(b, White, move)
              let #(st, child_id) =
                walk(
                  st,
                  next,
                  remove_one(dice, move.die),
                  Some(Moved(from: move.from, to: move.to, hit: hit != None)),
                )
              #(st, [
                Child(
                  die: move.die,
                  from: move.from,
                  to: move.to,
                  node: child_id,
                ),
                ..children
              ])
            })
          case st.over {
            True -> #(st, "")
            False -> #(
              Build(
                ..st,
                nodes: dict.insert(
                  st.nodes,
                  key,
                  Node(
                    id: id,
                    board: b,
                    dice_left: dice,
                    moved: moved,
                    children: list.reverse(children),
                  ),
                ),
              ),
              id,
            )
          }
        }
      }
    }
  }
}

/// What makes two positions within a turn one node: the board, and the dice
/// still to play. Two orders of the same checkers reach the same board with
/// the same dice left and are one node; the same board with different dice
/// left (a checker borne off by either die of a 5-2, say) is two, because
/// what can be played next differs.
fn state_key(b: Board, dice: List(Int)) -> String {
  board_key(b) <> "#" <> string.join(list.map(dice, int.to_string), ",")
}

/// What makes two boards the same board: which colour sits where, counted,
/// with the checkers' own ids forgotten. Cheap on purpose -- it is asked
/// once per edge explored, and `analysis.encode` walks the whole board
/// twenty-four times over.
fn board_key(b: Board) -> String {
  b.checkers
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(_id, #(color, loc)) = entry
    board.prefix(color) <> board.loc_id(loc)
  })
  |> list.sort(string.compare)
  |> string.join(",")
}

/// The moves the rules allow from here: every one that still leads to a
/// longest play, and at a roll where only one die can be played, the larger.
///
/// This is `board.sequences` read one step at a time. Maximality is the
/// same question asked of the whole turn or of what is left of it: a move
/// belongs on a longest play exactly when playing it leaves one die fewer
/// than the longest play from here.
fn children_moves(st: Build, b: Board, dice: List(Int)) -> #(Build, List(Move)) {
  let #(st, best) = depth(st, b, dice)
  case best {
    0 -> #(st, [])
    _ -> {
      let #(st, keep) =
        list.fold(steps(b, dice), #(st, []), fn(acc, step) {
          let #(st, keep) = acc
          let #(move, next) = step
          let #(st, d) = depth(st, next, remove_one(dice, move.die))
          case 1 + d == best {
            True -> #(st, [move, ..keep])
            False -> #(st, keep)
          }
        })
      #(st, larger_die(list.reverse(keep), best, dice))
    }
  }
}

/// When only one die of a roll can be played, it must be the larger one if
/// either will go. Two different dice are only ever left at the question's
/// own roll -- one step in, a non-double has a single die left and a double
/// has nothing but itself -- so this is the opening filter and nowhere else.
fn larger_die(moves: List(Move), best: Int, dice: List(Int)) -> List(Move) {
  case best, list.unique(dice) {
    1, [a, b] ->
      case list.filter(moves, fn(m) { m.die == int.max(a, b) }) {
        [] -> moves
        bigger -> bigger
      }
    _, _ -> moves
  }
}

/// How many dice can still be played from this position, at most. Memoised
/// on (board, dice left), which is what turns an exponential walk into one
/// pass over the few hundred positions a turn really has.
///
/// The memo is what the budget is really spent on: the root's own answer
/// depends on every position the turn can reach, so a build that is going
/// to be too big is too big before a single node is written down. Past the
/// budget it stops and the answer it returns is worthless -- `over` is set,
/// and the caller throws the whole tree away and serves the root alone.
fn depth(st: Build, b: Board, dice: List(Int)) -> #(Build, Int) {
  case st.over {
    True -> #(st, 0)
    False -> depth_of(st, b, dice)
  }
}

fn depth_of(st: Build, b: Board, dice: List(Int)) -> #(Build, Int) {
  case dice {
    [] -> #(st, 0)
    _ -> {
      let key = state_key(b, dice)
      case dict.get(st.depths, key) {
        Ok(d) -> #(st, d)
        Error(_) -> {
          let #(st, best) =
            list.fold(steps(b, dice), #(st, 0), fn(acc, step) {
              let #(st, best) = acc
              let #(st, d) = depth(st, step.1, remove_one(dice, { step.0 }.die))
              #(st, int.max(best, 1 + d))
            })
          let depths = dict.insert(st.depths, key, best)
          #(
            Build(
              ..st,
              depths: depths,
              over: st.over || dict.size(depths) > st.limit,
            ),
            best,
          )
        }
      }
    }
  }
}

/// Every single move playable right now, with the board it leaves.
fn steps(b: Board, dice: List(Int)) -> List(#(Move, Board)) {
  list.unique(dice)
  |> list.sort(fn(a, c) { int.compare(c, a) })
  |> list.flat_map(fn(die) {
    board.single_moves(b, White, die)
    |> list.map(fn(move) {
      let #(next, _, _) = board.apply_move(b, White, move)
      #(move, next)
    })
  })
}

fn remove_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..remove_one(rest, die)]
  }
}

// ---------- JSON ----------

pub fn to_json(tree: Tree) -> Json {
  json.object(
    list.flatten([
      [
        #("root", json.string(tree.root)),
        #(
          "nodes",
          json.object(list.map(tree.nodes, fn(n) { #(n.id, node_json(n)) })),
        ),
      ],
      // Absent rather than false: the page defaults it, and an eager tree
      // repeats nothing it does not have to.
      case tree.lazy {
        True -> [#("lazy", json.bool(True))]
        False -> []
      },
    ]),
  )
}

pub fn node_json(n: Node) -> Json {
  json.object([
    #("board", board_json(n.board)),
    #("dice_left", json.array(n.dice_left, json.int)),
    #("terminal", json.bool(n.children == [])),
    #("moved", case n.moved {
      Some(m) ->
        json.object([
          #("from", json.string(board.loc_id(m.from))),
          #("to", json.string(board.loc_id(m.to))),
          #("hit", json.bool(m.hit)),
        ])
      None -> json.null()
    }),
    #(
      "children",
      json.array(n.children, fn(c) {
        json.object([
          #("die", json.int(c.die)),
          #("from", json.string(board.loc_id(c.from))),
          #("to", json.string(board.loc_id(c.to))),
          #("node", json.string(c.node)),
        ])
      }),
    ),
  ])
}

/// The board as the wire draws one: the mover White and the opponent Black,
/// because a question numbers its points from the mover's side.
pub fn board_json(b: Board) -> Json {
  json.object([
    #("white", side_json(side(b, White))),
    #("black", side_json(side(b, Black))),
  ])
}

fn side_json(s: record.Side) -> Json {
  // Not the record's own `side_to_json`: that carries the pip count too, and
  // a pip count is arithmetic the page already does. A tree repeats a board
  // per node, so every field costs bytes several hundred times over.
  json.object([
    #("points", json.array(s.points, json.int)),
    #("bar", json.int(s.bar)),
    #("off", json.int(s.off)),
  ])
}

/// One colour's checkers, counted in a single pass over the board. The
/// record's own builder asks the board twenty-six separate questions, each
/// of which walks every checker; here that is once per node of the tree.
fn side(b: Board, color: Color) -> record.Side {
  let #(points, bar, off) =
    dict.fold(b.checkers, #(dict.new(), 0, 0), fn(acc, _id, entry) {
      let #(c, loc) = entry
      let #(points, bar, off) = acc
      case c == color, loc {
        False, _ -> acc
        True, Point(p) -> #(
          dict.insert(
            points,
            p,
            { dict.get(points, p) |> result.unwrap(0) } + 1,
          ),
          bar,
          off,
        )
        True, Bar -> #(points, bar + 1, off)
        True, Off -> #(points, bar, off + 1)
      }
    })
  let counts =
    list.range(1, 24)
    |> list.map(fn(p) { dict.get(points, p) |> result.unwrap(0) })
  record.Side(
    points: counts,
    bar: bar,
    off: off,
    pips: 25
      * bar
      + int.sum(
      list.index_map(counts, fn(n, i) { n * board.pip_distance(color, i + 1) }),
    ),
  )
}

// ---------- One level at a time ----------

/// A node of a tree too big to send whole, named so the server can answer
/// for it without holding anything: the position and the dice left are in
/// the id. It is opaque to the page and says nothing about the answer --
/// it is the board the page is already looking at.
pub fn lazy_id(b: Board, dice: List(Int), moved: Option(Moved)) -> String {
  let text =
    string.join(
      [
        board_key(b),
        string.join(list.map(dice, int.to_string), ","),
        case moved {
          Some(m) ->
            board.loc_id(m.from)
            <> ">"
            <> board.loc_id(m.to)
            <> case m.hit {
              True -> "*"
              False -> ""
            }
          None -> ""
        },
      ],
      ";",
    )
  "z"
  <> {
    bit_array.from_string(text) |> bit_array.base16_encode |> string.lowercase
  }
}

/// The root of a tree served lazily: the one node, and its children named
/// by their own ids.
pub fn lazy_root(b: Board, dice: List(Int)) -> Tree {
  Tree(root: root_id, nodes: [level(b, dice, None, root_id)], lazy: True)
}

/// The taps the rules allow from one position, on its own. What a page was
/// offered, and so what an attempt is checked against.
pub fn legal_children(b: Board, dice: List(Int)) -> List(Move) {
  let #(_, moves) = children_moves(fresh(1_000_000), b, dice)
  moves
}

fn fresh(limit: Int) -> Build {
  Build(
    nodes: dict.new(),
    found: [],
    ids: dict.new(),
    depths: dict.new(),
    next: 0,
    over: False,
    limit: limit,
  )
}

/// One node worked out on its own: what it looks like, and the ids of the
/// positions its legal taps reach.
pub fn level(
  b: Board,
  dice: List(Int),
  moved: Option(Moved),
  id: String,
) -> Node {
  let moves = legal_children(b, dice)
  Node(
    id: id,
    board: b,
    dice_left: dice,
    moved: moved,
    children: list.map(moves, fn(move) {
      let #(next, _, hit) = board.apply_move(b, White, move)
      Child(
        die: move.die,
        from: move.from,
        to: move.to,
        node: lazy_id(
          next,
          remove_one(dice, move.die),
          Some(Moved(from: move.from, to: move.to, hit: hit != None)),
        ),
      )
    }),
  )
}

/// A lazy id read back: the position, the dice still to play, and the step
/// that reached it. Error for anything that is not one -- a page asking for
/// a node it was never offered learns nothing.
pub fn from_lazy_id(
  id: String,
) -> Result(#(Board, List(Int), Option(Moved)), Nil) {
  use rest <- result.try(case string.starts_with(id, "z") {
    True -> Ok(string.drop_start(id, 1))
    False -> Error(Nil)
  })
  use bytes <- result.try(bit_array.base16_decode(string.uppercase(rest)))
  use text <- result.try(bit_array.to_string(bytes))
  case string.split(text, ";") {
    [board_text, dice_text, moved_text] -> {
      use b <- result.try(board_from_key(board_text))
      let dice = case dice_text {
        "" -> []
        _ ->
          string.split(dice_text, ",")
          |> list.filter_map(int.parse)
      }
      Ok(#(b, dice, moved_from_text(moved_text)))
    }
    _ -> Error(Nil)
  }
}

fn moved_from_text(text: String) -> Option(Moved) {
  let #(body, hit) = case string.ends_with(text, "*") {
    True -> #(string.drop_end(text, 1), True)
    False -> #(text, False)
  }
  case string.split(body, ">") {
    [from, to] ->
      case board.parse_loc(from), board.parse_loc(to) {
        Ok(from), Ok(to) -> Some(Moved(from: from, to: to, hit: hit))
        _, _ -> None
      }
    _ -> None
  }
}

/// The inverse of `board_key`: a list of "w6", "b bar", "woff"... back into
/// the board it counts.
fn board_from_key(text: String) -> Result(Board, Nil) {
  let entries = case text {
    "" -> []
    _ -> string.split(text, ",")
  }
  let checkers =
    entries
    |> list.filter_map(fn(entry) {
      case string.pop_grapheme(entry) {
        Ok(#("w", loc)) ->
          board.parse_loc(loc) |> result.map(fn(l) { #(White, l) })
        Ok(#("b", loc)) ->
          board.parse_loc(loc) |> result.map(fn(l) { #(Black, l) })
        _ -> Error(Nil)
      }
    })
  case
    list.length(checkers) == list.length(entries) && list.length(entries) == 30
  {
    False -> Error(Nil)
    True ->
      Ok(Board(
        checkers: checkers
        |> list.index_map(fn(entry, i) {
          #(board.prefix(entry.0) <> int.to_string(i + 1), entry)
        })
        |> dict.from_list,
      ))
  }
}
