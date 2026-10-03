//// The position a player sets up on the analysis board: one shape, one set
//// of rules, and the question it asks the engine. Pure.
////
//// Every door into the analysis board (the editor, a puzzle id, a replay
//// step) and every door out (asking the engine, storing a puzzle, sharing)
//// goes through here, so the four of them cannot disagree about what a
//// position is or whether it may be asked.
////
//// **Colours are real, not relative.** Unlike a stored `puzzles.Question`,
//// which is drawn from the player on roll's side, a `Setup` is the board as
//// the page shows it: White at the bottom moving 24 -> 1 (Oskol's numbering,
//// `backgammon/board`), Black the other way, and `to_play` says which of
//// them is being asked. `question` turns it into the mover-relative form;
//// `from_question` turns a stored one back with the solver as White.
////
//// **`to_play` is the player being asked.** For a move or a double that is
//// the player on roll; for a take it is the player who was doubled, so the
//// doubler (the player on roll in the stored question) is the other colour.
////
//// **`check` never fights the player.** It names the one thing that stops a
//// position being asked, in a sentence a player reads, and refuses nothing
//// else: an unusual position is still a position.

import backgammon/analysis.{type Position, type Turn, Position, Turn}
import backgammon/board.{type Board, type Color, Black, White}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/puzzles.{type Question}
import oskol/puzzles/tree

// ---------- The shape ----------

/// What the position asks.
pub type Ask {
  /// "What's your play?" with this roll. `no_roll` (0-0) is a move ask whose
  /// roll has not been picked yet, which `check` refuses with `no_roll_message`.
  Move(dice: #(Int, Int))
  /// "Double?", asked of `to_play`, who is on roll.
  Double
  /// "Take?", asked of `to_play`, who has been doubled by the other colour.
  Take
}

/// A match score. `None` in its place is unlimited play, which is money
/// play with the Jacoby rule here, as every unlimited game is
/// (`practice/openings.jacoby`).
pub type Match {
  Match(length: Int, white: Int, black: Int, crawford: Bool)
}

pub type Setup {
  Setup(
    /// 24 signed counts, point 1 first in Oskol's numbering: White's
    /// checkers positive, Black's negative. Borne off is whatever of a
    /// colour's fifteen is on neither the points nor the bar.
    points: List(Int),
    white_bar: Int,
    black_bar: Int,
    /// The player being asked (see the module doc).
    to_play: Color,
    ask: Ask,
    /// 1, 2, 4 ... 64.
    cube_value: Int,
    /// None is the middle.
    cube_owner: Option(Color),
    match: Option(Match),
  )
}

/// The roll of a move ask nobody has picked yet.
pub const no_roll = #(0, 0)

// ---------- The refusals ----------
//
// One sentence each, the first that applies. The ones that name a colour or
// a number are functions; the rest are constants.

/// The wire sent something that is not a board. The editor never does.
pub const points_message = "A board has 24 points"

/// A point or a bar with a count outside 0..15.
pub const count_message = "A point holds 0 to 15 checkers"

/// "White has 17 checkers; 15 is the most".
pub fn too_many_message(color: Color, checkers: Int) -> String {
  name(color)
  <> " has "
  <> int.to_string(checkers)
  <> " checkers; 15 is the most"
}

pub const no_white_message = "Put some White checkers on the board"

pub const no_black_message = "Put some Black checkers on the board"

/// "Put some Black checkers on the board".
pub fn none_message(color: Color) -> String {
  case color {
    White -> no_white_message
    Black -> no_black_message
  }
}

pub const no_roll_message = "Pick a roll"

pub const die_message = "A die shows 1 to 6"

pub const cube_value_message = "The cube is 1, 2, 4, 8, 16, 32 or 64"

pub const owned_at_one_message = "A cube at 1 sits in the center"

pub const unowned_message = "A cube above 1 belongs to somebody"

pub const length_message = "A match is 1 to 25 points"

/// "Each score is 0 to 6 in a match to 7".
pub fn score_message(length: Int) -> String {
  "Each score is 0 to "
  <> int.to_string(length - 1)
  <> " in a match to "
  <> int.to_string(length)
}

pub const crawford_message = "Crawford needs somebody one point away"

/// The doubler (`to_play` for a double, the other colour for a take) does
/// not hold the cube.
pub fn cube_owned_message(owner: Color) -> String {
  "No double is possible here: the cube is " <> name(owner) <> "'s"
}

pub const crawford_double_message = "No double is possible here: this is the Crawford game"

/// The cube already covers what the doubler needs to win the match.
pub fn dead_cube_message(doubler: Color) -> String {
  "No double is possible here: the cube already covers what "
  <> name(doubler)
  <> " needs"
}

pub const game_over_message = "The game is over in this position"

/// What `turn` says of a roll that can play nothing: there is nothing to
/// ask the engine.
pub const dances_message = "That roll has no legal moves here"

fn name(color: Color) -> String {
  case color {
    White -> "White"
    Black -> "Black"
  }
}

/// The setup if it may be asked, else the first refusal that applies, in
/// this order: the board's shape, the counts, too many of a colour, a colour
/// with none on the board, the roll, the cube, the match, Crawford, a double
/// or take the doubler could not have made, and a game that is over.
///
/// A point holding both colours and Crawford in unlimited play cannot be
/// said in this shape at all (a point is one signed count; Crawford lives in
/// `Match`), so they are refused by construction rather than here.
///
/// A colour with nothing on the board is "Put some ... checkers" while the
/// other colour has none borne off (a board being set up); when the other
/// colour has borne some off too, it is a race somebody has finished, and
/// that is `game_over_message`.
pub fn check(setup: Setup) -> Result(Setup, String) {
  use _ <- result.try(require(list.length(setup.points) == 24, points_message))
  use _ <- result.try(require(
    list.all(setup.points, fn(n) { n >= -15 && n <= 15 })
      && in_range(setup.white_bar, 0, 15)
      && in_range(setup.black_bar, 0, 15),
    count_message,
  ))
  let white = on_board(setup, White)
  let black = on_board(setup, Black)
  use _ <- result.try(require(white <= 15, too_many_message(White, white)))
  use _ <- result.try(require(black <= 15, too_many_message(Black, black)))
  use _ <- result.try(require(
    !{ white == 0 && { black == 0 || black == 15 } },
    no_white_message,
  ))
  use _ <- result.try(require(
    !{ black == 0 && { white == 0 || white == 15 } },
    no_black_message,
  ))
  use _ <- result.try(case setup.ask {
    Move(dice) if dice == no_roll -> Error(no_roll_message)
    Move(#(a, b)) ->
      require(in_range(a, 1, 6) && in_range(b, 1, 6), die_message)
    _ -> Ok(Nil)
  })
  use _ <- result.try(require(
    list.contains([1, 2, 4, 8, 16, 32, 64], setup.cube_value),
    cube_value_message,
  ))
  use _ <- result.try(case setup.cube_value, setup.cube_owner {
    1, Some(_) -> Error(owned_at_one_message)
    1, None -> Ok(Nil)
    _, None -> Error(unowned_message)
    _, Some(_) -> Ok(Nil)
  })
  use _ <- result.try(case setup.match {
    None -> Ok(Nil)
    Some(m) -> {
      use _ <- result.try(require(in_range(m.length, 1, 25), length_message))
      use _ <- result.try(require(
        in_range(m.white, 0, m.length - 1) && in_range(m.black, 0, m.length - 1),
        score_message(m.length),
      ))
      require(
        !m.crawford || m.white == m.length - 1 || m.black == m.length - 1,
        crawford_message,
      )
    }
  })
  use _ <- result.try(case setup.ask {
    Move(_) -> Ok(Nil)
    Double -> can_double(setup, setup.to_play)
    Take -> can_double(setup, board.opponent(setup.to_play))
  })
  use _ <- result.try(require(white > 0 && black > 0, game_over_message))
  Ok(setup)
}

fn require(holds: Bool, message: String) -> Result(Nil, String) {
  case holds {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn in_range(n: Int, low: Int, high: Int) -> Bool {
  n >= low && n <= high
}

/// Checkers of a colour on the points and the bar.
fn on_board(setup: Setup, color: Color) -> Int {
  let points =
    list.fold(setup.points, 0, fn(sum, n) {
      case color {
        White -> sum + int.max(0, n)
        Black -> sum + int.max(0, -n)
      }
    })
  points + bar(setup, color)
}

fn bar(setup: Setup, color: Color) -> Int {
  case color {
    White -> setup.white_bar
    Black -> setup.black_bar
  }
}

/// Whether `doubler` could double here, by the rule the engine grades a
/// double on (`analysis.engine_can_double`), in its own sentences.
fn can_double(setup: Setup, doubler: Color) -> Result(Nil, String) {
  let p = position(setup, doubler)
  case analysis.engine_can_double(p) {
    True -> Ok(Nil)
    False ->
      case setup.cube_owner, p.crawford {
        Some(owner), _ if owner != doubler -> Error(cube_owned_message(owner))
        _, True -> Error(crawford_double_message)
        _, False -> Error(dead_cube_message(doubler))
      }
  }
}

// ---------- The board ----------

/// The checkers placed with the game's own ids ("w1".."b15", as
/// `puzzles/tree.from_engine` places them), so everything in
/// `backgammon/board` works on it. Meant for a setup that passed `check`.
pub fn board(setup: Setup) -> Board {
  let assert Ok(b) = tree.from_engine(white_board(setup))
  b
}

/// The setup as the engine's 26-int board drawn from White's side: Black's
/// bar, the 24 points in Oskol's numbering, White's bar.
fn white_board(setup: Setup) -> List(Int) {
  list.flatten([[setup.black_bar], setup.points, [setup.white_bar]])
}

// ---------- The question it asks ----------

/// The player on roll in the question: the one asked for a move or a
/// double, the doubler for a take.
fn mover(setup: Setup) -> Color {
  case setup.ask {
    Take -> board.opponent(setup.to_play)
    _ -> setup.to_play
  }
}

fn jacoby(setup: Setup) -> Bool {
  setup.match == None
}

/// The engine's position, from `mover`'s side.
fn position(setup: Setup, mover: Color) -> Position {
  let #(away1, away2, crawford) = case setup.match {
    None -> #(0, 0, False)
    Some(m) -> #(
      m.length - score(m, mover),
      m.length - score(m, board.opponent(mover)),
      m.crawford,
    )
  }
  Position(
    board: analysis.encode(board(setup), mover),
    cube_value: setup.cube_value,
    cube_owner: case setup.cube_owner {
      None -> "centered"
      Some(owner) if owner == mover -> "player"
      Some(_) -> "opponent"
    },
    away1: away1,
    away2: away2,
    crawford: crawford,
  )
}

fn score(m: Match, color: Color) -> Int {
  case color {
    White -> m.white
    Black -> m.black
  }
}

/// The puzzle question this setup asks, mover-relative as every stored
/// question is: dice high die first, away scores `length - score` each way
/// (both 0 in unlimited play), `jacoby` exactly for unlimited play. A take
/// is stored from the doubler's side, as `puzzles/extract` writes one, so
/// its key is the key a game's own take would have.
pub fn question(setup: Setup) -> Question {
  let kind = case setup.ask {
    Move(_) -> puzzles.Move
    Double -> puzzles.Double
    Take -> puzzles.Take
  }
  let dice = case setup.ask {
    Move(dice) -> Some(dice)
    _ -> None
  }
  puzzles.question_of(kind, position(setup, mover(setup)), dice, jacoby(setup))
}

/// The one turn an engine request is built from
/// (`analysis.turns_request([#(1, turn)], jacoby, None, None)`), after
/// `check`. A move names its first legal play as `played`, the way
/// `practice/openings.turn` does (the engine grades every legal play
/// whatever is named); a roll that plays nothing is `dances_message`, so
/// nothing is asked. A cube ask has no dice, no played board and no double
/// on it, from the doubler's side. `player` is 0.
pub fn turn(setup: Setup) -> Result(Turn, String) {
  use setup <- result.try(check(setup))
  let q = question(setup)
  let p = position(setup, mover(setup))
  use #(dice, played) <- result.try(case q.dice {
    None -> Ok(#(None, None))
    Some(roll) -> {
      let assert Ok(from) = tree.from_engine(q.board)
      use first <- result.try(
        board.sequences(from, White, tree.dice_of(roll))
        |> list.first
        |> result.replace_error(dances_message),
      )
      let after =
        list.fold(first, from, fn(so_far, move) {
          let #(next, _, _) = board.apply_move(so_far, White, move)
          next
        })
      Ok(#(Some(roll), Some(analysis.encode(after, White))))
    }
  })
  Ok(Turn(
    player: 0,
    player_id: "",
    position: p,
    double: None,
    dice: dice,
    played: played,
    log_index: 0,
    entry: None,
    double_entry: None,
    answer_entry: None,
  ))
}

/// The setup a stored question opens as (`/analysis?p=<id>`): the solver as
/// White at the bottom, as `handlers/puzzles.shown` draws it, so a stored
/// take comes back as a `Take` asked of White with the doubler Black.
///
/// A question keeps away scores, not the score, so a match comes back as
/// the shortest one with those away scores: the length is the larger away,
/// and the player further away has 0.
pub fn from_question(q: Question) -> Setup {
  // Turned round for a take, so that the solver is the mover from here on.
  let #(engine_board, owner, mine, theirs) = case q.kind {
    puzzles.Take -> #(
      puzzles.flip(q.board),
      case q.cube_owner {
        puzzles.Mover -> puzzles.Opponent
        puzzles.Opponent -> puzzles.Mover
        puzzles.Centered -> puzzles.Centered
      },
      q.away_opponent,
      q.away_mover,
    )
    _ -> #(q.board, q.cube_owner, q.away_mover, q.away_opponent)
  }
  let black_bar = list.first(engine_board) |> result.unwrap(0)
  let points = engine_board |> list.drop(1) |> list.take(24)
  let white_bar =
    engine_board |> list.drop(25) |> list.first |> result.unwrap(0)
  let match = case mine, theirs {
    0, 0 -> None
    _, _ -> {
      let length = int.max(mine, theirs)
      Some(Match(
        length: length,
        white: length - mine,
        black: length - theirs,
        crawford: q.crawford,
      ))
    }
  }
  Setup(
    points: points,
    white_bar: white_bar,
    black_bar: black_bar,
    to_play: White,
    ask: case q.kind {
      puzzles.Move -> Move(option.unwrap(q.dice, no_roll))
      puzzles.Double -> Double
      puzzles.Take -> Take
    },
    cube_value: q.cube_value,
    cube_owner: case owner {
      puzzles.Mover -> Some(White)
      puzzles.Opponent -> Some(Black)
      puzzles.Centered -> None
    },
    match: match,
  )
}

/// The same position with the colours swapped: point p becomes 25 - p with
/// its sign turned, the bars, the cube's owner, the scores and `to_play`
/// change sides. The question it asks is the same one (`question` is
/// mover-relative), so its key is too.
pub fn flip(setup: Setup) -> Setup {
  Setup(
    ..setup,
    points: setup.points |> list.reverse |> list.map(int.negate),
    white_bar: setup.black_bar,
    black_bar: setup.white_bar,
    to_play: board.opponent(setup.to_play),
    cube_owner: option.map(setup.cube_owner, board.opponent),
    match: option.map(setup.match, fn(m) {
      Match(..m, white: m.black, black: m.white)
    }),
  )
}

// ---------- The words ----------

/// The score and the cube in the puzzle page's words, from `to_play`'s
/// side and in the board's real colours: "Match play, 3 away against 5,
/// Crawford. Cube at 2, Black's." The page's fixed line under the board.
pub fn describe(setup: Setup) -> String {
  let #(mine, theirs, crawford) = case setup.match {
    None -> #(0, 0, False)
    Some(m) -> #(
      m.length - score(m, setup.to_play),
      m.length - score(m, board.opponent(setup.to_play)),
      m.crawford,
    )
  }
  situation(
    mine,
    theirs,
    crawford,
    setup.cube_value,
    setup.cube_owner,
    setup.ask == Take,
  )
}

/// The words `describe` and the puzzle page (`handlers/puzzles.describe`)
/// share: the score from the asked player's side, then the cube. No score
/// is unlimited play, and one point each way is a single game unless it is
/// marked Crawford, which only a match is.
///
/// `offered` is a take question: the cube given is the one before the
/// double, so the line says what was done to it -- "Cube at 2, Black's,
/// redoubled to 4." or "Cube centered, doubled to 2." -- and never reads
/// as the stakes the player is answering.
pub fn situation(
  away_mine: Int,
  away_theirs: Int,
  crawford: Bool,
  cube_value: Int,
  cube_owner: Option(Color),
  offered: Bool,
) -> String {
  let score = case away_mine, away_theirs, crawford {
    0, 0, _ -> "Unlimited play"
    1, 1, False -> "Single game"
    mine, theirs, crawford ->
      "Match play, "
      <> int.to_string(mine)
      <> " away against "
      <> int.to_string(theirs)
      <> case crawford {
        True -> ", Crawford"
        False -> ""
      }
  }
  let to = int.to_string(cube_value * 2)
  let cube = case cube_owner, offered {
    Some(owner), False ->
      "Cube at " <> int.to_string(cube_value) <> ", " <> name(owner) <> "'s."
    Some(owner), True ->
      "Cube at "
      <> int.to_string(cube_value)
      <> ", "
      <> name(owner)
      <> "'s, redoubled to "
      <> to
      <> "."
    None, False -> "Cube centered."
    None, True -> "Cube centered, doubled to " <> to <> "."
  }
  score <> ". " <> cube
}

// ---------- The wire ----------

/// `{points: [24 ints], white_bar, black_bar, to_play: "white"|"black",
/// ask: "move"|"double"|"take", dice: [a, b] | null, cube: {value, owner:
/// "center"|"white"|"black"}, match: {length, white, black, crawford} |
/// null}`. `dice` is null for a cube ask and for a move whose roll is not
/// picked yet.
pub fn to_json(setup: Setup) -> Json {
  json.object([
    #("points", json.array(setup.points, json.int)),
    #("white_bar", json.int(setup.white_bar)),
    #("black_bar", json.int(setup.black_bar)),
    #("to_play", json.string(color_name(setup.to_play))),
    #(
      "ask",
      json.string(case setup.ask {
        Move(_) -> "move"
        Double -> "double"
        Take -> "take"
      }),
    ),
    #("dice", case setup.ask {
      Move(dice) if dice != no_roll -> json.array([dice.0, dice.1], json.int)
      _ -> json.null()
    }),
    #(
      "cube",
      json.object([
        #("value", json.int(setup.cube_value)),
        #(
          "owner",
          json.string(case setup.cube_owner {
            None -> "center"
            Some(owner) -> color_name(owner)
          }),
        ),
      ]),
    ),
    #("match", case setup.match {
      None -> json.null()
      Some(m) ->
        json.object([
          #("length", json.int(m.length)),
          #("white", json.int(m.white)),
          #("black", json.int(m.black)),
          #("crawford", json.bool(m.crawford)),
        ])
    }),
  ])
}

fn color_name(color: Color) -> String {
  case color {
    White -> "white"
    Black -> "black"
  }
}

/// The wire shape back. It reads the shape and nothing more -- whether the
/// position may be asked is `check`'s, so a decoded setup can still be
/// refused in a sentence. A move with no dice is a move with `no_roll`;
/// dice that are not a pair fail the decode.
pub fn decoder() -> Decoder(Setup) {
  use points <- decode.field("points", decode.list(decode.int))
  use white_bar <- decode.field("white_bar", decode.int)
  use black_bar <- decode.field("black_bar", decode.int)
  use to_play <- decode.field("to_play", color_decoder())
  use ask <- decode.field("ask", decode.string)
  use dice <- decode.optional_field(
    "dice",
    None,
    decode.optional(decode.list(decode.int)),
  )
  use cube_value <- decode.subfield(["cube", "value"], decode.int)
  use cube_owner <- decode.subfield(["cube", "owner"], owner_decoder())
  use match <- decode.optional_field(
    "match",
    None,
    decode.optional({
      use length <- decode.field("length", decode.int)
      use white <- decode.field("white", decode.int)
      use black <- decode.field("black", decode.int)
      use crawford <- decode.optional_field("crawford", False, decode.bool)
      decode.success(Match(length, white, black, crawford))
    }),
  )
  let setup = fn(ask) {
    decode.success(Setup(
      points: points,
      white_bar: white_bar,
      black_bar: black_bar,
      to_play: to_play,
      ask: ask,
      cube_value: cube_value,
      cube_owner: cube_owner,
      match: match,
    ))
  }
  case ask, dice {
    "move", None -> setup(Move(no_roll))
    "move", Some([a, b]) -> setup(Move(#(a, b)))
    "double", _ -> setup(Double)
    "take", _ -> setup(Take)
    _, _ -> decode.failure(empty(), "Setup")
  }
}

fn empty() -> Setup {
  Setup(
    points: [],
    white_bar: 0,
    black_bar: 0,
    to_play: White,
    ask: Double,
    cube_value: 1,
    cube_owner: None,
    match: None,
  )
}

fn color_decoder() -> Decoder(Color) {
  use word <- decode.then(decode.string)
  case word {
    "white" -> decode.success(White)
    "black" -> decode.success(Black)
    _ -> decode.failure(White, "Color")
  }
}

fn owner_decoder() -> Decoder(Option(Color)) {
  use word <- decode.then(decode.string)
  case word {
    "center" -> decode.success(None)
    "white" -> decode.success(Some(White))
    "black" -> decode.success(Some(Black))
    _ -> decode.failure(None, "Owner")
  }
}
