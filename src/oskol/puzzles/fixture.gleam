//// Real puzzle payloads, for the client's tests.
////
//// The wire between the server and the puzzle page is frozen
//// (`puzzles-wire`), and the Elm side decodes it strictly. So the Elm suite
//// is given the server's own bytes rather than a hand-written copy of them:
//// `mix oskol.fixtures payloads` writes these into `assets/tests`, and a
//// decoder that drifts from what is actually sent fails there.
////
//// The same idea as `gamekit/fixture`, and for the same reason: the two
//// sides of a frozen contract should be tested against one artefact, not
//// against two people's readings of a document.

import backgammon/analysis
import backgammon/board.{type Board, Black, Point, White}
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/analysis/rolls.{type Roll, type Rolls, Roll, Rolls}
import oskol/caps/puzzles.{
  type ReplayLink, type Stored, Keyed, ReplayLink, Stored,
} as _
import oskol/handlers/analysis as analysis_handler
import oskol/handlers/puzzles as handler
import oskol/puzzles.{
  type Answer, type Kind, type Probs, type Question, Candidate, Centered,
  CubeAnswer, Double, DoublePass, Move, MoveAnswer, Mover, Outcome, Probs,
  Question, Take,
}
import oskol/puzzles/tree

// ---------- The per-roll grids ----------

/// One real 3-ply grid, named: what `POST /papi/analysis/rolls` answers about.
/// Taken from the live engine (bgsage 2.0.20260907) rather than made up, so
/// the colours a page draws are the colours real positions produce.
///
///   * `opening` -- the opening position, the mover's own 21 rolls. 6-6 is the
///     best throw there is and 1-2 the worst, which is the sign in a form
///     anybody can check.
///   * `baseline` and `compared` -- the boards 24/18 13/8 and a blot-leaving
///     play of 6-5 leave in a real early midgame, each read from the
///     opponent's side. The second lets them hit from the bar on 2-2, 2-6 and
///     1-1, and dances on 5-5, 6-6 and 6-5; the difference grid says so.
pub fn rolls_sample(name: String) -> Rolls {
  case name {
    "baseline" -> baseline_grid()
    "compared" -> compared_grid()
    _ -> opening_grid()
  }
}

/// The same grid as the engine writes one: `{level, equity, rows}`, which is
/// what a turn of a review carries and what `POST /backgammon/rolls` answers.
/// What a test stands in for the engine with, so both sides of the wire are
/// read from one artefact.
pub fn rolls_answer(name: String) -> String {
  let grid = rolls_sample(name)
  json.to_string(
    json.object([
      #("level", json.string(grid.level)),
      #("equity", json.float(grid.equity)),
      #(
        "rows",
        json.array(grid.rows, fn(row: Roll) {
          json.object([
            #("dice", json.array([row.dice.0, row.dice.1], json.int)),
            #("weight", json.int(row.weight)),
            #("equity", json.float(row.equity)),
            #("best", json.string(row.best)),
          ])
        }),
      ),
    ]),
  )
}

/// The opening position's own grid, from the engine.
fn opening_grid() -> Rolls {
  Rolls(level: analysis.rolls_level, equity: 0.09823331981897354, rows: [
    Roll(#(1, 1), 1, 0.29992392659187317, "8/7(2) 6/5(2)"),
    Roll(#(2, 2), 1, 0.3128664791584015, "13/11(2) 6/4(2)"),
    Roll(#(3, 3), 1, 0.3341923654079437, "8/5(2) 6/3(2)"),
    Roll(#(4, 4), 1, 0.43256622552871704, "24/20(2) 13/9(2)"),
    Roll(#(5, 5), 1, 0.1593828648328781, "13/3(2)"),
    Roll(#(6, 6), 1, 0.586184561252594, "24/18(2) 13/7(2)"),
    Roll(#(1, 2), 2, -0.0043206606060266495, "24/23 13/11"),
    Roll(#(1, 3), 2, 0.21308979392051697, "8/5 6/5"),
    Roll(#(1, 4), 2, -0.005338947754353285, "24/23 13/9"),
    Roll(#(1, 5), 2, 0.007008453365415335, "24/23 13/8"),
    Roll(#(1, 6), 2, 0.13307785987854004, "13/7 8/7"),
    Roll(#(2, 3), 2, 0.006010701414197683, "24/21 13/11"),
    Roll(#(2, 4), 2, 0.14198105037212372, "8/4 6/4"),
    Roll(#(2, 5), 2, 0.008565329946577549, "24/22 13/8"),
    Roll(#(2, 6), 2, 0.015899542719125748, "24/18 13/11"),
    Roll(#(3, 4), 2, -0.0037979776971042156, "24/20 13/10"),
    Roll(#(3, 5), 2, 0.06961020082235336, "8/3 6/3"),
    Roll(#(3, 6), 2, 0.0077416375279426575, "24/18 13/10"),
    Roll(#(4, 5), 2, 0.024491041898727417, "24/20 13/8"),
    Roll(#(4, 6), 2, 0.010247399099171162, "24/18 13/9"),
    Roll(#(5, 6), 2, 0.08137615025043488, "24/13"),
  ])
}

/// The grid of the board 24/18 13/8 leaves, from the opponent's side.
fn baseline_grid() -> Rolls {
  Rolls(level: analysis.rolls_level, equity: -0.17296656966209412, rows: [
    Roll(#(1, 1), 1, 0.1338711529970169, "8/7* 8/7 6/5(2)"),
    Roll(#(2, 2), 1, -0.006393031217157841, "13/11(2) 6/4(2)"),
    Roll(#(3, 3), 1, 0.14689384400844574, "13/7* 13/7"),
    Roll(#(4, 4), 1, 0.04608413204550743, "13/5(2)"),
    Roll(#(5, 5), 1, 0.07805745303630829, "13/8(2) 6/1* 6/1"),
    Roll(#(6, 6), 1, 0.2759859561920166, "13/7* 13/1* 7/1"),
    Roll(#(1, 2), 2, -0.30465424060821533, "13/11 8/7*"),
    Roll(#(1, 3), 2, -0.1855165958404541, "8/5 6/5"),
    Roll(#(1, 4), 2, -0.3066243529319763, "13/9 8/7*"),
    Roll(#(1, 5), 2, -0.26294395327568054, "13/7*"),
    Roll(#(1, 6), 2, 0.041188932955265045, "13/7 8/7*"),
    Roll(#(2, 3), 2, -0.32637879252433777, "13/8"),
    Roll(#(2, 4), 2, -0.19894637167453766, "8/4 6/4"),
    Roll(#(2, 5), 2, -0.29792696237564087, "24/22 13/8"),
    Roll(#(2, 6), 2, -0.22064875066280365, "13/11 13/7*"),
    Roll(#(3, 4), 2, -0.35619020462036133, "13/6"),
    Roll(#(3, 5), 2, -0.27225619554519653, "24/16"),
    Roll(#(3, 6), 2, -0.22931762039661407, "24/21 13/7*"),
    Roll(#(4, 5), 2, -0.3907969295978546, "13/9 13/8"),
    Roll(#(4, 6), 2, -0.18040518462657928, "24/14"),
    Roll(#(5, 6), 2, 0.04076911881566048, "24/13"),
  ])
}

/// The same for a play that leaves two blots and a checker on their bar.
fn compared_grid() -> Rolls {
  Rolls(level: analysis.rolls_level, equity: 0.22087480127811432, rows: [
    Roll(#(1, 1), 1, 0.8395447731018066, "bar/24* 24/23* 6/5(2)"),
    Roll(#(2, 2), 1, 0.8083012104034424, "bar/23* 13/11 6/4(2)"),
    Roll(#(3, 3), 1, 0.28395354747772217, "bar/22 13/10(3)"),
    Roll(#(4, 4), 1, 0.6964887976646423, "bar/17* 13/9(2)"),
    Roll(#(5, 5), 1, -0.30075767636299133, ""),
    Roll(#(6, 6), 1, -0.30075767636299133, ""),
    Roll(#(1, 2), 2, 0.3234127163887024, "bar/23* 23/22"),
    Roll(#(1, 3), 2, 0.22590960562229156, "bar/24* 13/10"),
    Roll(#(1, 4), 2, 0.23651398718357086, "bar/24* 13/9"),
    Roll(#(1, 5), 2, 0.22563494741916656, "bar/24* 13/8"),
    Roll(#(1, 6), 2, 0.18630999326705933, "bar/24* 13/7"),
    Roll(#(2, 3), 2, 0.36217036843299866, "bar/23* 13/10"),
    Roll(#(2, 4), 2, 0.38164207339286804, "bar/23* 13/9"),
    Roll(#(2, 5), 2, 0.36413660645484924, "bar/23* 13/8"),
    Roll(#(2, 6), 2, 0.5679813623428345, "bar/23* 23/17*"),
    Roll(#(3, 4), 2, 0.048757873475551605, "bar/22 13/9"),
    Roll(#(3, 5), 2, 0.3221558630466461, "bar/17*"),
    Roll(#(3, 6), 2, 0.0036598944570869207, "bar/16"),
    Roll(#(4, 5), 2, 0.0036598944570869207, "bar/16"),
    Roll(#(4, 6), 2, 0.011172774247825146, "bar/15"),
    Roll(#(5, 6), 2, -0.30075767636299133, ""),
  ])
}

/// One payload per shape a page has to draw, named: exactly what
/// `GET /papi/puzzles/:id` answers for each.
pub fn samples() -> List(#(String, String)) {
  ["move", "doubles", "double", "take"]
  |> list.map(fn(name) { #(name, rendered(stored_sample(name), None)) })
  // The checker play as a position shared out of a replay: the same page,
  // and the way back to the step it came from.
  |> list.append([
    #(
      "replay",
      rendered(
        stored_sample("move"),
        Some(ReplayLink(slug: "backgammon", id: "821900", game: 3, step: 17)),
      ),
    ),
  ])
}

/// The row behind a sample, as an extraction would have written it: what a
/// test seeds so the server answers from the database and not from here.
/// `old` is the `move` position as a review from before `all_results`
/// stored it: two candidates and nothing else, so a play outside them is
/// an honest unknown.
pub fn stored_sample(name: String) -> Stored {
  case name {
    "doubles" -> move_puzzle("fixdbl01", doubles_board(), #(3, 3))
    "double" -> cube_puzzle(Double)
    "take" -> cube_puzzle(Take)
    "double_close" -> close_double()
    "old" -> old_move_puzzle("fixold01", hit_board(), #(6, 4))
    _ -> move_puzzle("fixmove1", hit_board(), #(6, 4))
  }
}

/// What `POST /papi/puzzles/:id/attempts` answers a guest, one per shape a
/// reveal has to draw: a checker play that passes, one that is dubious
/// (a miss), a worse miss and one the stored answer cannot grade; a double
/// and a take answered right and wrong, and a take too close to call. And the three shapes a schedule takes for an account, which the
/// same endpoint carries in place of `null`.
pub fn reveals() -> List(#(String, String)) {
  let move = stored_sample("move")
  let old = stored_sample("old")
  let due = 1_800_000_000_000
  [
    #("move_pass", attempted(move, moves_to(move, 1), None)),
    // 0.07 given up: a dubious play, and so a miss.
    #("move_dubious", attempted(move, moves_to(move, 2), None)),
    #("move_fail", attempted(move, moves_to(move, 3), None)),
    #("move_unknown", attempted(old, moves_to(move, 3), None)),
    #("double_pass", attempted(stored_sample("double"), [], Some(1))),
    #("double_fail", attempted(stored_sample("double"), [], Some(-1))),
    #("take_pass", attempted(stored_sample("take"), [], Some(-1))),
    // A coin flip: taking and passing are within 0.02 of each other, so
    // either answer passes, the wrong side giving up a hair.
    #("take_close", attempted(close_take(), [], Some(1))),
    // The same coin flip asked of the doubler, from both sides: doubling
    // gains 0.003, and DOUBLE and NO DOUBLE read alike.
    #("double_close_yes", attempted(close_double(), [], Some(1))),
    #("double_close_no", attempted(close_double(), [], Some(-1))),
    // `held_days` as `config :retain, intervals` has it: 7 days at level
    // 3, 1 at level 1.
    #("schedule_amendable", handler.schedule_json(2, 3, due, True, False, 7)),
    #("schedule_self_grade", handler.schedule_json(3, 3, due, False, True, 7)),
    #("schedule_settled", handler.schedule_json(1, 1, due, False, False, 1)),
  ]
}

/// What `GET /papi/analysis/:key` (and a cached `POST /papi/analysis`)
/// answers once the engine has: the puzzle and its reveal, for a checker
/// play, a double and a take, all at 4-ply, and the checker play from a
/// row that does not say how deep it was looked at.
pub fn analyses() -> List(#(String, String)) {
  let levels = "{\"levels\":{\"moves\":\"4ply\",\"cube\":\"4ply\"}}"
  [
    #("move", analysed("move", levels)),
    #("double", analysed("double", levels)),
    #("take", analysed("take", levels)),
    #("double_close", analysed("double_close", levels)),
    #("move_no_levels", analysed("move", "{\"levels\":null}")),
  ]
}

/// What `POST /papi/analysis/rolls` answers, named: one position's own grid,
/// and two plays with the difference between them. Its own corpus rather than
/// one of `analyses`, which is every answer the *status* endpoint gives and is
/// decoded as such.
pub fn rolls_answers() -> List(#(String, String)) {
  [
    #("rolls", analysis_handler.position_grid_body(rolls_sample("opening"))),
    #(
      "compare",
      analysis_handler.compare_grids_body(
        rolls_sample("baseline"),
        rolls_sample("compared"),
      ),
    ),
  ]
}

fn analysed(name: String, evaluated_by: String) -> String {
  case
    analysis_handler.done_fixture(
      "fixture-key-" <> name,
      Keyed(
        stored: stored_sample(name),
        complete: True,
        evaluated_by_json: evaluated_by,
      ),
    )
  {
    Ok(body) -> body
    Error(_) -> "{\"ok\":false}"
  }
}

fn attempted(
  stored: Stored,
  moves: List(#(String, String, Int)),
  band: Option(Int),
) -> String {
  case
    handler.attempt_body(stored, handler.Attempted(moves, band, "fixture-key"))
  {
    Ok(body) -> body
    Error(_) -> "{\"ok\":false}"
  }
}

/// The path through the turn that leaves the board the candidate of that
/// rank leaves -- what the page sends after walking there. The candidates
/// are ranked by the terminals' order, so every rank up to the number of
/// legal plays has one.
fn moves_to(stored: Stored, rank: Int) -> List(#(String, String, Int)) {
  case
    puzzles.question_from_json(stored.question_json),
    puzzles.answer_from_json(stored.answer_json)
  {
    Ok(question), Ok(MoveAnswer(candidates: candidates, ..)) ->
      case
        list.find(candidates, fn(c) { c.rank == rank }),
        question.dice,
        tree.from_engine(question.board)
      {
        Ok(candidate), Some(roll), Ok(b) ->
          case tree.build(b, tree.dice_of(roll), 100_000) {
            Ok(t) -> path_to(t, tree.root_id, [], candidate.board)
            Error(_) -> []
          }
        _, _, _ -> []
      }
    _, _ -> []
  }
}

fn path_to(
  t: tree.Tree,
  id: String,
  so_far: List(#(String, String, Int)),
  target: List(Int),
) -> List(#(String, String, Int)) {
  case tree.node_by_id(t, id) {
    None -> []
    Some(n) ->
      case n.children {
        [] ->
          case analysis.encode(n.board, White) == target {
            True -> list.reverse(so_far)
            False -> []
          }
        children ->
          list.find_map(children, fn(c) {
            case
              path_to(
                t,
                c.node,
                [#(board.loc_id(c.from), board.loc_id(c.to), c.die), ..so_far],
                target,
              )
            {
              [] -> Error(Nil)
              found -> Ok(found)
            }
          })
          |> result.unwrap([])
      }
  }
}

fn rendered(stored: Stored, replay: Option(ReplayLink)) -> String {
  case handler.puzzle_body(stored, replay) {
    Ok(body) -> body
    Error(_) -> "{\"ok\":false}"
  }
}

fn stored(id: String, question: Question, answer: Answer) -> Stored {
  Stored(
    id: id,
    kind: puzzles.kind_name(question.kind),
    question_json: json.to_string(puzzles.question_json(question)),
    answer_json: json.to_string(puzzles.answer_json(answer)),
  )
}

// ---------- The positions ----------

/// White to play 6-4 with two runners on 13 and a blot on 7 to hit: a hit,
/// a bear-in, and two orders that reach one node.
fn hit_board() -> Board {
  place([
    #(White, 13, 2),
    #(White, 4, 4),
    #(White, 5, 4),
    #(White, 6, 5),
    #(Black, 1, 2),
    #(Black, 2, 2),
    #(Black, 7, 1),
    #(Black, 17, 3),
    #(Black, 18, 3),
    #(Black, 20, 2),
    #(Black, 21, 2),
  ])
}

/// 3-3 with the home board shut, so two runners walk 13/10/7/4 and every
/// order of the fours threes merges: the shape only doubles give.
fn doubles_board() -> Board {
  place([
    #(White, 13, 2),
    #(White, 4, 4),
    #(White, 5, 4),
    #(White, 6, 5),
    #(Black, 1, 2),
    #(Black, 2, 2),
    #(Black, 3, 2),
    #(Black, 20, 3),
    #(Black, 22, 3),
    #(Black, 24, 3),
  ])
}

fn place(entries: List(#(board.Color, Int, Int))) -> Board {
  let #(checkers, _) =
    list.fold(entries, #([], #(0, 0)), fn(acc, entry) {
      let #(placed, #(w, b)) = acc
      let #(color, point, n) = entry
      let start = case color {
        White -> w
        Black -> b
      }
      let ids =
        list.range(1, n)
        |> list.map(fn(i) {
          #(board.prefix(color) <> int.to_string(start + i), #(
            color,
            Point(point),
          ))
        })
      let counts = case color {
        White -> #(w + n, b)
        Black -> #(w, b + n)
      }
      #(list.append(placed, ids), counts)
    })
  board.Board(checkers: dict.from_list(checkers))
}

// ---------- The puzzles ----------

fn move_puzzle(id: String, b: Board, roll: #(Int, Int)) -> Stored {
  let question =
    Question(
      kind: Move,
      board: analysis.encode(b, White),
      dice: Some(roll),
      cube_value: 1,
      cube_owner: Centered,
      away_mover: 3,
      away_opponent: 5,
      crawford: False,
      jacoby: False,
    )
  stored(id, question, move_answer(b, roll))
}

/// Costs made up, boards real. The answer never reaches the page, so a
/// fixture only has to be well formed -- but the boards are the ones this
/// position's own legal plays leave, so an attempt made against the fixture
/// grades exactly as a real one would.
fn move_answer(b: Board, roll: #(Int, Int)) -> Answer {
  let boards = terminals(b, roll)
  let costs = list.index_map(boards, fn(_, i) { int.to_float(i) *. 0.07 })
  let pairs = list.zip(boards, costs)
  MoveAnswer(
    outcomes: list.map(pairs, fn(pair) {
      Outcome(board: pair.0, equity_lost: pair.1)
    }),
    complete: True,
    n_legal: list.length(boards),
    candidates: list.index_map(pairs, fn(pair, i) {
      Candidate(
        rank: i + 1,
        notation: "play " <> int.to_string(i + 1),
        equity: 0.42 -. pair.1,
        equity_lost: pair.1,
        board: pair.0,
        probs: probs(),
      )
    })
      |> list.take(5),
  )
}

/// The boards every legal way of playing this roll leaves.
fn terminals(b: Board, roll: #(Int, Int)) -> List(List(Int)) {
  case tree.build(b, tree.dice_of(roll), 100_000) {
    Error(_) -> []
    Ok(t) ->
      t.nodes
      |> list.filter(fn(n) { n.children == [] })
      |> list.map(fn(n) { analysis.encode(n.board, White) })
  }
}

/// The same position as `move` graded by an engine asked for five moves and
/// nothing else: two candidates stand for the whole answer, so an attempt
/// that leaves any other board is unknown.
fn old_move_puzzle(id: String, b: Board, roll: #(Int, Int)) -> Stored {
  let whole = move_puzzle(id, b, roll)
  case puzzles.answer_from_json(whole.answer_json) {
    Ok(MoveAnswer(candidates: candidates, ..)) -> {
      let kept = list.take(candidates, 2)
      Stored(
        ..whole,
        answer_json: json.to_string(
          puzzles.answer_json(MoveAnswer(
            outcomes: list.map(kept, fn(c) {
              Outcome(board: c.board, equity_lost: c.equity_lost)
            }),
            complete: False,
            n_legal: list.length(candidates),
            candidates: kept,
          )),
        ),
      )
    }
    _ -> whole
  }
}

fn cube_puzzle(kind: Kind) -> Stored {
  let question =
    Question(
      kind: kind,
      board: analysis.encode(hit_board(), White),
      dice: None,
      cube_value: 2,
      cube_owner: Mover,
      away_mover: 3,
      away_opponent: 5,
      crawford: False,
      jacoby: False,
    )
  let id = case kind {
    Take -> "fixtake1"
    _ -> "fixdoub1"
  }
  stored(
    id,
    question,
    // A genuine double-and-pass, and the numbers have to say so: taking
    // pays the doubler 1.12 where passing pays them the point, so the
    // responder passes (DP - DT = -0.12, a plain pass) and the doubler
    // doubles (min(DT, DP) - ND = +0.69, a big double). A label that its
    // own equities contradict would make a fixture that grades the
    // opposite of what it claims to be.
    CubeAnswer(
      no_double: 0.31,
      double_take: 1.12,
      double_pass: 1.0,
      probs: Some(probs()),
      optimal: DoublePass,
      too_good: False,
    ),
  )
}

/// The same take with the numbers a hair apart: the engine's band is zero
/// and the reveal says too close to call.
fn close_take() -> Stored {
  let Stored(id: _, kind: kind, question_json: question, answer_json: _) =
    cube_puzzle(Take)
  Stored(
    id: "fixtakec",
    kind: kind,
    question_json: question,
    answer_json: json.to_string(
      puzzles.answer_json(CubeAnswer(
        no_double: 0.31,
        double_take: 1.01,
        double_pass: 1.0,
        probs: Some(probs()),
        optimal: DoublePass,
        too_good: False,
      )),
    ),
  )
}

/// The double reported from prod (`cube-verdict-from-equities`): ND
/// +0.221, D/T +0.224, D/P +1.000. Doubling gains 0.003 -- a double by the
/// equities, band 0 on the puzzles' scale -- and the page once said "not a
/// double yet" beside those very numbers.
fn close_double() -> Stored {
  let Stored(id: _, kind: kind, question_json: question, answer_json: _) =
    cube_puzzle(Double)
  Stored(
    id: "fixdoubc",
    kind: kind,
    question_json: question,
    answer_json: json.to_string(
      puzzles.answer_json(cube_answer_of(0.221, 0.224, 1.0)),
    ),
  )
}

/// A cube answer as an extraction writes it: the call and the flag read
/// off the equities.
fn cube_answer_of(nd: Float, dt: Float, dp: Float) -> Answer {
  CubeAnswer(
    no_double: nd,
    double_take: dt,
    double_pass: dp,
    probs: Some(probs()),
    optimal: puzzles.cube_call(nd, dt, dp),
    too_good: puzzles.too_good(nd, dp),
  )
}

/// The cube call on equities at, above and below each of its lines, as the
/// server decides it: `mix oskol.fixtures payloads` writes these into
/// `assets/tests/CubeCallFixtures.elm`, and `CubeCallTest` holds the Elm
/// twin (`Replay.cubeCall`, `Replay.tooGood`, `Replay.takes`) to every one.
/// Each is `{no_double, double_take, double_pass, call, too_good, takes}`.
pub fn cube_calls() -> List(#(String, String)) {
  [
    #("the reported double", 0.221, 0.224, 1.0),
    #("its mirror, a no double", 0.224, 0.221, 1.0),
    #("on the double line", 0.5, 0.5, 1.0),
    #("a hair over the double line", 0.5, 0.5001, 1.0),
    #("a hair under the double line", 0.5, 0.4999, 1.0),
    #("on the take line", 0.5, 1.0, 1.0),
    #("a hair under the take line", 0.5, 0.9999, 1.0),
    #("a hair over the take line, a pass", 0.5, 1.0001, 1.0),
    #("double, pass by a hair over waiting", 0.9999, 1.4, 1.0),
    #("on the too-good line", 1.0, 1.4, 1.0),
    #("a hair too good", 1.0001, 1.4, 1.0),
    #("too good, and a take if doubled", 1.2, 0.9, 1.0),
    #("losing", -0.3, -0.5, 1.0),
    #("a clear double, take", 0.5, 0.7, 1.0),
    #("a clear double, pass", 0.31, 1.12, 1.0),
    #("the stand-in engine's pass with the game close", 0.62, 1.31, 1.0),
  ]
  |> list.map(fn(c) {
    let #(name, nd, dt, dp) = c
    #(
      name,
      json.to_string(
        json.object([
          #("no_double", json.float(nd)),
          #("double_take", json.float(dt)),
          #("double_pass", json.float(dp)),
          #(
            "call",
            json.string(puzzles.optimal_name(puzzles.cube_call(nd, dt, dp))),
          ),
          #("too_good", json.bool(puzzles.too_good(nd, dp))),
          #("takes", json.bool(puzzles.takes(dt, dp))),
        ]),
      ),
    )
  })
}

fn probs() -> Probs {
  Probs(0.55, 0.12, 0.01, 0.1, 0.01)
}
