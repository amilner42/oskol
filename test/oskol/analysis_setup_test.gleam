//// The position a player sets up on the analysis board: its refusals, the
//// question it asks and the turn the engine is sent, and the way back from
//// a stored question. Controlled positions for every rule, then a hundred
//// seeded random ones for the round trips.

import backgammon/analysis
import backgammon/board.{type Board, Bar, Black, Off, Point, White}
import backgammon/positions
import gamekit/rng
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/analysis/setup.{
  type Setup, Double, Match, Move, Setup, Take, no_roll,
}
import oskol/practice/openings
import oskol/puzzles

// ---------- Builders ----------

/// A setup of a board as it stands, White's side, with the rest plain:
/// White to play 3-1, cube centered, unlimited.
fn of_board(b: Board) -> Setup {
  Setup(
    points: list.range(1, 24)
      |> list.map(fn(p) {
        board.count(b, White, Point(p)) - board.count(b, Black, Point(p))
      }),
    white_bar: board.on_bar(b, White),
    black_bar: board.on_bar(b, Black),
    to_play: White,
    ask: Move(#(3, 1)),
    cube_value: 1,
    cube_owner: None,
    match: None,
  )
}

fn opening() -> Setup {
  of_board(board.initial())
}

/// The opening with one point's count replaced.
fn with_point(s: Setup, point: Int, count: Int) -> Setup {
  Setup(
    ..s,
    points: list.index_map(s.points, fn(n, i) {
      case i + 1 == point {
        True -> count
        False -> n
      }
    }),
  )
}

fn match(length: Int, white: Int, black: Int, crawford: Bool) -> Setup {
  Setup(..opening(), match: Some(Match(length, white, black, crawford)))
}

fn refused(s: Setup) -> String {
  let assert Error(message) = setup.check(s)
  message
}

fn empty_points() -> List(Int) {
  list.repeat(0, 24)
}

// ---------- The question ----------

pub fn opening_three_one_is_the_openings_question_test() {
  // Low die first on purpose: the question sorts it.
  let s = Setup(..opening(), ask: Move(#(1, 3)))
  let assert Ok(_) = setup.check(s)
  let q = setup.question(s)
  assert puzzles.key(q)
    == puzzles.key(openings.question(openings.start(), #(3, 1)))
  assert q.dice == Some(#(3, 1))
  assert q.jacoby
  assert q.away_mover == 0 && q.away_opponent == 0
}

pub fn black_to_play_encodes_from_blacks_side_test() {
  let s = Setup(..opening(), to_play: Black, ask: Move(#(6, 4)))
  let q = setup.question(s)
  assert q.board == analysis.encode(board.initial(), Black)
}

pub fn cube_owner_is_relative_to_the_mover_test() {
  let owned = fn(owner, to_play) {
    setup.question(
      Setup(
        ..opening(),
        to_play: to_play,
        ask: Double,
        cube_value: 2,
        cube_owner: owner,
      ),
    ).cube_owner
  }
  assert owned(Some(White), White) == puzzles.Mover
  assert owned(Some(Black), Black) == puzzles.Mover
  assert owned(None, Black) == puzzles.Centered
  // A take is stored from the doubler's side: White doubled by Black, who
  // owns nothing yet -- and when White holds the cube, it is the opponent's.
  let take =
    Setup(..opening(), ask: Take, cube_value: 2, cube_owner: Some(White))
  assert setup.question(take).cube_owner == puzzles.Opponent
}

pub fn match_away_scores_and_jacoby_test() {
  let s = Setup(..match(7, 2, 4, False), ask: Double)
  let q = setup.question(s)
  assert q.away_mover == 5 && q.away_opponent == 3
  assert !q.jacoby
  assert q.dice == None
  let black = setup.question(Setup(..s, to_play: Black))
  assert black.away_mover == 3 && black.away_opponent == 5
}

pub fn money_has_no_scores_and_no_crawford_test() {
  // Crawford lives in `Match`, so unlimited play cannot carry it at all.
  let q = setup.question(opening())
  assert q.away_mover == 0 && q.away_opponent == 0
  assert !q.crawford
  assert q.jacoby
}

pub fn take_stores_the_doublers_board_test() {
  let b = asymmetric()
  let take = Setup(..of_board(b), ask: Take, match: Some(Match(7, 0, 3, False)))
  let assert Ok(_) = setup.check(take)
  let q = setup.question(take)
  assert q.kind == puzzles.Take
  assert q.board == analysis.encode(b, Black)
  // Black is the doubler: Black's away first.
  assert q.away_mover == 4 && q.away_opponent == 7
  assert setup.from_question(q) == take
  // The double on the same position, asked of Black, is the same board.
  let double = Setup(..take, to_play: Black, ask: Double)
  assert setup.question(double).board == q.board
}

pub fn from_question_puts_the_solver_at_the_bottom_test() {
  let s = Setup(..opening(), to_play: Black, ask: Move(#(6, 4)))
  let back = setup.from_question(setup.question(s))
  assert back == setup.flip(s)
  assert back.to_play == White
}

pub fn from_question_reads_the_shortest_match_test() {
  // 3 away against 5: a match to 5 at 2-0.
  let s = match(9, 6, 4, False)
  assert setup.from_question(setup.question(s)).match
    == Some(Match(5, 2, 0, False))
}

// ---------- Refusals ----------

pub fn the_opening_is_fine_test() {
  assert setup.check(opening()) == Ok(opening())
}

pub fn a_board_has_24_points_test() {
  assert refused(Setup(..opening(), points: [1, 2])) == setup.points_message
}

pub fn counts_are_0_to_15_test() {
  assert refused(with_point(opening(), 3, 16)) == setup.count_message
  assert refused(with_point(opening(), 3, -16)) == setup.count_message
  assert refused(Setup(..opening(), white_bar: -1)) == setup.count_message
  assert refused(Setup(..opening(), black_bar: 16)) == setup.count_message
}

pub fn too_many_of_a_colour_test() {
  let s = Setup(..opening(), white_bar: 2)
  assert refused(s) == "White has 17 checkers; 15 is the most"
  assert refused(s) == setup.too_many_message(White, 17)
  assert refused(with_point(opening(), 2, -1))
    == "Black has 16 checkers; 15 is the most"
}

pub fn a_colour_with_nothing_on_the_board_test() {
  let clear = Setup(..opening(), points: empty_points())
  assert refused(clear) == "Put some White checkers on the board"
  assert refused(clear) == setup.no_white_message
  let whites =
    Setup(..clear, points: list.map(opening().points, fn(n) { int_max(n, 0) }))
  assert refused(whites) == "Put some Black checkers on the board"
  assert setup.none_message(Black) == setup.no_black_message
  let blacks =
    Setup(..clear, points: list.map(opening().points, fn(n) { int_min(n, 0) }))
  assert refused(blacks) == setup.no_white_message
}

pub fn a_finished_game_test() {
  // Black has borne everything off and White is still bearing off.
  let s = Setup(..opening(), points: [3, 2, ..list.repeat(0, 22)])
  assert refused(s) == "The game is over in this position"
  assert refused(s) == setup.game_over_message
}

pub fn pick_a_roll_test() {
  assert refused(Setup(..opening(), ask: Move(no_roll))) == "Pick a roll"
  assert refused(Setup(..opening(), ask: Move(no_roll)))
    == setup.no_roll_message
}

pub fn dice_are_1_to_6_test() {
  assert refused(Setup(..opening(), ask: Move(#(7, 1)))) == setup.die_message
  assert refused(Setup(..opening(), ask: Move(#(3, 0)))) == setup.die_message
}

pub fn cube_values_test() {
  assert refused(Setup(..opening(), cube_value: 3, cube_owner: Some(White)))
    == setup.cube_value_message
  assert refused(Setup(..opening(), cube_value: 128, cube_owner: Some(White)))
    == setup.cube_value_message
  list.each([2, 4, 8, 16, 32, 64], fn(v) {
    let assert Ok(_) =
      setup.check(Setup(..opening(), cube_value: v, cube_owner: Some(Black)))
  })
}

pub fn cube_owner_and_value_agree_test() {
  assert refused(Setup(..opening(), cube_owner: Some(White)))
    == setup.owned_at_one_message
  assert refused(Setup(..opening(), cube_value: 2)) == setup.unowned_message
}

pub fn match_length_test() {
  assert refused(match(0, 0, 0, False)) == setup.length_message
  assert refused(match(26, 0, 0, False)) == setup.length_message
  let assert Ok(_) = setup.check(match(25, 0, 0, False))
  let assert Ok(_) = setup.check(match(1, 0, 0, False))
}

pub fn scores_test() {
  assert refused(match(7, 7, 0, False))
    == "Each score is 0 to 6 in a match to 7"
  assert refused(match(7, 0, -1, False)) == setup.score_message(7)
  let assert Ok(_) = setup.check(match(7, 6, 6, False))
}

pub fn crawford_test() {
  // Nobody one away.
  assert refused(match(7, 3, 4, True)) == setup.crawford_message
  assert refused(match(7, 0, 0, True))
    == "Crawford needs somebody one point away"
  // 7 away against 1 away, either way round.
  let assert Ok(_) = setup.check(match(7, 0, 6, True))
  let assert Ok(_) = setup.check(match(7, 6, 0, True))
  // Post-Crawford: one away, no Crawford, and the trailer may double.
  let post = Setup(..match(7, 2, 6, False), ask: Double)
  let assert Ok(_) = setup.check(post)
  assert !setup.question(post).crawford
}

pub fn no_double_in_the_crawford_game_test() {
  let s = Setup(..match(7, 2, 6, True), ask: Double)
  assert refused(s) == "No double is possible here: this is the Crawford game"
  assert refused(s) == setup.crawford_double_message
  assert refused(Setup(..s, ask: Take)) == setup.crawford_double_message
}

pub fn no_double_on_the_other_sides_cube_test() {
  let s =
    Setup(..opening(), ask: Double, cube_value: 2, cube_owner: Some(Black))
  assert refused(s) == "No double is possible here: the cube is Black's"
  assert refused(s) == setup.cube_owned_message(Black)
  let assert Ok(_) = setup.check(Setup(..s, cube_owner: Some(White)))
  let assert Ok(_) = setup.check(Setup(..s, cube_owner: None, cube_value: 1))
}

pub fn no_take_of_your_own_cube_test() {
  // White is being doubled, so Black is doubling: a cube White holds is not
  // Black's to turn.
  let s = Setup(..opening(), ask: Take, cube_value: 2, cube_owner: Some(White))
  assert refused(s) == setup.cube_owned_message(White)
  let assert Ok(_) = setup.check(Setup(..s, cube_owner: Some(Black)))
}

pub fn no_double_on_a_dead_cube_test() {
  // White is 2 away and the cube is already at 2.
  let s =
    Setup(
      ..match(7, 5, 0, False),
      ask: Double,
      cube_value: 2,
      cube_owner: Some(White),
    )
  assert refused(s)
    == "No double is possible here: the cube already covers what White needs"
  assert refused(s) == setup.dead_cube_message(White)
  // Money play has no dead cube.
  let assert Ok(_) = setup.check(Setup(..s, match: None, cube_value: 64))
  // A take where the doubler's cube is dead: Black 2 away, cube Black's at 2.
  let t =
    Setup(
      ..match(7, 0, 5, False),
      ask: Take,
      cube_value: 2,
      cube_owner: Some(Black),
    )
  assert refused(t) == setup.dead_cube_message(Black)
}

pub fn the_refusals_come_in_order_test() {
  // Too many checkers and no roll: the board comes first.
  assert refused(Setup(..opening(), white_bar: 1, ask: Move(no_roll)))
    == setup.too_many_message(White, 16)
  // No roll and a bad cube: the roll first.
  assert refused(Setup(..opening(), ask: Move(no_roll), cube_value: 3))
    == setup.no_roll_message
}

// ---------- The turn ----------

pub fn a_move_turn_names_a_legal_play_test() {
  let assert Ok(turn) = setup.turn(opening())
  assert turn.player == 0
  assert turn.dice == Some(#(3, 1))
  assert turn.double == None
  assert turn.position.board == openings.start()
  assert turn.position.cube_owner == "centered"
  let assert Some(played) = turn.played
  assert played != turn.position.board
  // The same turn the opening deck asks about.
  assert openings.turn(openings.start(), #(3, 1)) == Ok(turn)
}

pub fn a_dance_is_not_asked_test() {
  // White on the bar against a closed board.
  let points =
    list.range(1, 24)
    |> list.map(fn(p) {
      case p {
        _ if p >= 19 -> -2
        13 -> 5
        6 -> 5
        8 -> 4
        _ -> 0
      }
    })
  let s = Setup(..opening(), points: points, white_bar: 1, ask: Move(#(6, 5)))
  let assert Ok(_) = setup.check(s)
  assert setup.turn(s) == Error(setup.dances_message)
}

pub fn a_cube_turn_has_no_dice_and_no_play_test() {
  let s =
    Setup(
      ..match(7, 2, 3, False),
      ask: Double,
      cube_value: 2,
      cube_owner: Some(White),
    )
  let assert Ok(turn) = setup.turn(s)
  assert turn.dice == None
  assert turn.played == None
  assert turn.double == None
  assert turn.position.cube_owner == "player"
  assert turn.position.away1 == 5 && turn.position.away2 == 4
  // A take is the doubler's turn.
  let t = Setup(..s, ask: Take, cube_owner: Some(Black))
  let assert Ok(take) = setup.turn(t)
  assert take.position.board == setup.question(t).board
  assert take.position.away1 == 4 && take.position.cube_owner == "player"
}

pub fn the_turn_refuses_what_check_refuses_test() {
  assert setup.turn(Setup(..opening(), ask: Move(no_roll)))
    == Error(setup.no_roll_message)
}

// ---------- The board ----------

pub fn board_places_the_games_own_ids_test() {
  let b = setup.board(opening())
  assert board.count(b, White, Point(24)) == 2
  assert board.count(b, Black, Point(19)) == 5
  assert dict.size(b.checkers) == 30
  assert dict.has_key(b.checkers, "w15") && dict.has_key(b.checkers, "b15")
  let bearing = Setup(..opening(), points: [3, -2, ..list.repeat(0, 22)])
  let b = setup.board(bearing)
  assert board.borne_off(b, White) == 12
}

// ---------- Flip ----------

pub fn flip_swaps_everything_test() {
  let s =
    Setup(
      ..of_board(asymmetric()),
      ask: Double,
      cube_value: 4,
      cube_owner: Some(White),
      match: Some(Match(9, 3, 8, True)),
    )
  let f = setup.flip(s)
  assert f.to_play == Black
  assert f.cube_owner == Some(Black)
  assert f.match == Some(Match(9, 8, 3, True))
  assert f.white_bar == s.black_bar && f.black_bar == s.white_bar
  // Point 1 is the old point 24, turned.
  let assert [first, ..] = f.points
  let assert Ok(last) = list.last(s.points)
  assert first == -last
}

// ---------- Describe ----------

pub fn describe_test() {
  assert setup.describe(opening()) == "Unlimited play. Cube centered."
  assert setup.describe(match(1, 0, 0, False)) == "Single game. Cube centered."
  assert setup.describe(
      Setup(
        ..match(7, 6, 2, True),
        to_play: Black,
        cube_value: 2,
        cube_owner: Some(Black),
      ),
    )
    == "Match play, 5 away against 1, Crawford. Cube at 2, Black's."
}

// ---------- The wire ----------

pub fn json_round_trip_test() {
  let shapes = [
    opening(),
    Setup(..opening(), ask: Move(no_roll)),
    Setup(
      ..match(7, 2, 6, True),
      to_play: Black,
      ask: Take,
      cube_value: 2,
      cube_owner: Some(Black),
    ),
  ]
  list.each(shapes, fn(s) {
    let text = json.to_string(setup.to_json(s))
    assert json.parse(text, setup.decoder()) == Ok(s)
  })
  let text =
    json.to_string(setup.to_json(Setup(..opening(), ask: Move(no_roll))))
  assert string.contains(text, "\"dice\":null")
  assert string.contains(
    json.to_string(setup.to_json(opening())),
    "\"owner\":\"center\"",
  )
}

pub fn the_decoder_reads_the_shape_only_test() {
  let parse = fn(text) { json.parse(text, setup.decoder()) }
  let base = fn(ask, dice) {
    "{\"points\":[1],\"white_bar\":0,\"black_bar\":0,\"to_play\":\"white\",\"ask\":\""
    <> ask
    <> "\",\"dice\":"
    <> dice
    <> ",\"cube\":{\"value\":1,\"owner\":\"center\"},\"match\":null}"
  }
  // A short board decodes, and `check` says what is wrong with it.
  let assert Ok(s) = parse(base("move", "[6,4]"))
  assert setup.check(s) == Error(setup.points_message)
  let assert Ok(s) = parse(base("double", "null"))
  assert s.ask == Double
  let assert Error(_) = parse(base("roll", "null"))
  let assert Error(_) = parse(base("move", "[6]"))
  let assert Error(_) =
    parse(string.replace(base("move", "null"), "\"white\"", "\"green\""))
}

// ---------- A hundred random positions ----------

/// Seeded random setups that pass `check`, White to play, dice high first,
/// and in a match the player further away on 0: the setups a stored question
/// gives back exactly.
fn random_setups(n: Int) -> List(Setup) {
  random_loop(rng.seed(4242), n, [])
}

fn random_loop(r: rng.Rng, n: Int, acc: List(Setup)) -> List(Setup) {
  case n {
    0 -> list.reverse(acc)
    _ -> {
      let #(s, r) = random_setup(r)
      let s = case setup.check(s) {
        Ok(s) -> Ok(s)
        // A cube ask the doubler could not make is a move ask instead.
        Error(_) -> setup.check(Setup(..s, ask: Move(#(5, 2))))
      }
      case s {
        Ok(s) -> random_loop(r, n - 1, [s, ..acc])
        Error(_) -> random_loop(r, n, acc)
      }
    }
  }
}

fn random_setup(r: rng.Rng) -> #(Setup, rng.Rng) {
  let #(mode, r) = rng.int(r, 3)
  let #(white, black) = case mode {
    0 -> #(positions.Anywhere, positions.Anywhere)
    1 -> #(positions.Home, positions.Anywhere)
    _ -> #(positions.Home, positions.Home)
  }
  let #(b, r) = positions.random_board(r, white, black)
  let #(ask, r) = rng.int(r, 3)
  let #(a, r) = rng.int(r, 6)
  let #(c, r) = rng.int(r, 6)
  let dice = #(int_max(a, c) + 1, int_min(a, c) + 1)
  let ask = case ask {
    0 -> Move(dice)
    1 -> Double
    _ -> Take
  }
  let #(v, r) = rng.int(r, 7)
  let cube_value = power(v)
  let #(o, r) = rng.int(r, 2)
  let cube_owner = case cube_value, o {
    1, _ -> None
    _, 0 -> Some(White)
    _, _ -> Some(Black)
  }
  let #(kind, r) = rng.int(r, 2)
  let #(length, r) = rng.int(r, 25)
  let length = length + 1
  let #(lead, r) = rng.int(r, length)
  let #(who, r) = rng.int(r, 2)
  let #(cr, r) = rng.int(r, 2)
  let crawford = cr == 1 && lead == length - 1
  let match = case kind, who {
    0, _ -> None
    _, 0 -> Some(Match(length, lead, 0, crawford))
    _, _ -> Some(Match(length, 0, lead, crawford))
  }
  #(
    Setup(
      ..of_board(b),
      ask: ask,
      cube_value: cube_value,
      cube_owner: cube_owner,
      match: match,
    ),
    r,
  )
}

fn power(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 2 * power(n - 1)
  }
}

pub fn a_hundred_round_trips_test() {
  let setups = random_setups(100)
  assert list.length(setups) == 100
  // The set is not all one kind.
  assert list.any(setups, fn(s) { s.ask == Take })
  assert list.any(setups, fn(s) { s.ask == Double })
  assert list.any(setups, fn(s) { s.match != None })
  list.each(setups, fn(s) {
    let q = setup.question(s)
    assert setup.from_question(q) == s
    let f = setup.flip(s)
    assert setup.flip(f) == s
    assert puzzles.key(setup.question(f)) == puzzles.key(q)
    assert setup.check(f) == Ok(f)
    // A flipped setup asks the same question, so it comes back unflipped.
    assert setup.from_question(setup.question(f)) == s
    let text = json.to_string(setup.to_json(s))
    assert json.parse(text, setup.decoder()) == Ok(s)
  })
}

// ---------- Helpers ----------

/// A middle-game board, asymmetric on purpose: each side has a checker on
/// the bar and one borne off.
fn asymmetric() -> Board {
  positions.setup([
    #(White, Point(24), 1),
    #(White, Point(13), 4),
    #(White, Point(8), 3),
    #(White, Point(6), 4),
    #(White, Point(5), 1),
    #(White, Bar, 1),
    #(White, Off, 1),
    #(Black, Point(1), 2),
    #(Black, Point(12), 3),
    #(Black, Point(17), 4),
    #(Black, Point(19), 3),
    #(Black, Point(20), 1),
    #(Black, Bar, 1),
    #(Black, Off, 1),
  ])
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}
