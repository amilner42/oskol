//// A puzzle: one decision out of a real game, stored so anybody can try
//// it. This module is the stored shape and nothing else -- the question,
//// the answer, the key that makes two of the same position one puzzle, and
//// the JSON each column is written as. Which turns become puzzles is
//// `oskol/puzzles/extract`; serving them, grading them and scheduling them
//// are later tickets, and all of them read this.
////
//// **Everything is relative to the player on roll.** The board is the
//// engine's 26-int board drawn from that player's side (see
//// `backgammon/analysis`), the cube's owner is `Mover` when they hold it,
//// and the away scores are theirs first. For a `Take` question the player
//// on roll is the *doubler*: the question is the same position as the
//// `Double` one, asked of the other side, and the three equities a cube
//// answer stores are the doubler's payoff either way. Which seat made the
//// mistake is a `puzzle_sources` row, never the puzzle; how a page draws a
//// take is presentation (`flip` turns a board around).
////
//// **A stored answer is never rewritten.** A puzzle is public and shared,
//// so a later engine cannot silently change what a link says; a change of
//// shape is a migration, as it is for a rendered review.

import backgammon/analysis
import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/rooms/code

/// What a puzzle asks. A `Double` and a `Take` on the same position are two
/// puzzles: the question differs even though the board does not.
pub type Kind {
  /// "What's your play?" -- a checker play, with dice.
  Move
  /// "Double?" -- the player on roll's cube decision.
  Double
  /// "Take?" -- the other player's answer to the double that was offered.
  Take
}

pub fn kind_name(kind: Kind) -> String {
  case kind {
    Move -> "move"
    Double -> "double"
    Take -> "take"
  }
}

pub fn kind_from_name(name: String) -> Result(Kind, Nil) {
  case name {
    "move" -> Ok(Move)
    "double" -> Ok(Double)
    "take" -> Ok(Take)
    _ -> Error(Nil)
  }
}

/// Who owns the cube, from the player on roll's side.
pub type Owner {
  Centered
  Mover
  Opponent
}

pub fn owner_name(owner: Owner) -> String {
  case owner {
    Centered -> "center"
    Mover -> "mover"
    Opponent -> "opponent"
  }
}

pub fn owner_from_name(name: String) -> Owner {
  case name {
    "mover" -> Mover
    "opponent" -> Opponent
    _ -> Centered
  }
}

/// The question, and the whole of it: two questions with the same fields
/// are the same puzzle.
pub type Question {
  Question(
    kind: Kind,
    /// The engine's 26-int board from the player on roll's side: index 0 is
    /// the opponent's bar, 1..24 the points they move 24 -> 1 along, 25
    /// their own bar.
    board: List(Int),
    /// The roll, higher die first. `None` for a cube question: what comes
    /// next is not part of asking whether to double, and keying on it would
    /// split one question into thirty-six.
    dice: Option(#(Int, Int)),
    cube_value: Int,
    cube_owner: Owner,
    /// Points the player on roll still needs, then their opponent's. Both
    /// zero in money play (unlimited).
    away_mover: Int,
    away_opponent: Int,
    crawford: Bool,
    jacoby: Bool,
  )
}

/// Chances, as the engine reports them: the player on roll's.
pub type Probs {
  Probs(
    win: Float,
    gammon_win: Float,
    backgammon_win: Float,
    gammon_loss: Float,
    backgammon_loss: Float,
  )
}

/// One legal play the engine evaluated: the board it leaves and what it
/// gives up against the best. Every legal play has one of these when the
/// answer is `complete`, which is what lets any attempt be graded exactly.
pub type Outcome {
  Outcome(board: List(Int), equity_lost: Float)
}

/// A play with everything a reveal shows.
pub type Candidate {
  Candidate(
    rank: Int,
    notation: String,
    equity: Float,
    equity_lost: Float,
    board: List(Int),
    probs: Probs,
  )
}

/// The engine's call on a cube decision.
pub type Optimal {
  NoDouble
  DoubleTake
  DoublePass
  /// A word from a later engine that this one does not know.
  OtherCall(String)
}

pub fn optimal_name(optimal: Optimal) -> String {
  case optimal {
    NoDouble -> "no_double"
    DoubleTake -> "double_take"
    DoublePass -> "double_pass"
    OtherCall(word) -> word
  }
}

/// The engine's `optimal_action`, which it writes in words ("No Double",
/// "Double/Take"), as the call it means.
pub fn optimal_from_engine(word: String) -> Optimal {
  let lower = string.lowercase(word)
  case
    string.contains(lower, "no"),
    string.contains(lower, "pass"),
    string.contains(lower, "take")
  {
    True, _, _ -> NoDouble
    _, True, _ -> DoublePass
    _, _, True -> DoubleTake
    _, _, _ -> OtherCall(word)
  }
}

/// What the engine says the answer is.
pub type Answer {
  MoveAnswer(
    /// Every legal play's board and cost when `complete`, the five the
    /// engine described when not.
    outcomes: List(Outcome),
    /// The engine sent a result for every legal play, so any answer can be
    /// graded exactly. False for a review taken before it was asked for
    /// that: an answer outside `candidates` is then honestly unknown.
    complete: Bool,
    /// How many legal plays there were, by the engine's count.
    n_legal: Int,
    /// The top five, and the move that was actually played when it fell
    /// outside them (by rank, so a reader can tell: rank 6 or worse is the
    /// extra one). A public reveal shows the top five only -- the extra
    /// candidate is the source game's move and would name it.
    candidates: List(Candidate),
  )
  CubeAnswer(
    /// The three equities, all of them the *doubler's* payoff, whether this
    /// is a `Double` question or a `Take` one.
    no_double: Float,
    double_take: Float,
    double_pass: Float,
    /// The chances the cube was judged on, before the roll. None for an
    /// engine answer written before the report kept them.
    probs: Option(Probs),
    optimal: Optimal,
    /// Too good to double: the engine says no double, and playing on is
    /// worth more than the point a pass would hand over.
    too_good: Bool,
  )
}

/// Who worked the answer out, so a later engine's verdict is never mistaken
/// for this one's.
pub type EvaluatedBy {
  EvaluatedBy(move_level: Option(String), cube_level: Option(String))
}

// ---------- The key and the id ----------

/// The canonical form of a question: one line, every field of it, and
/// nothing else. The key is its sha256, so two players who reach the same
/// position and are asked the same thing get one puzzle.
///
/// Versioned: a change to this text is a change to every key, which is a
/// migration and not a silent re-keying.
pub fn canonical(q: Question) -> String {
  string.join(
    [
      "v1",
      kind_name(q.kind),
      "b:" <> string.join(list.map(q.board, int.to_string), ","),
      "d:"
        <> case q.dice {
        Some(#(high, low)) -> int.to_string(high) <> "," <> int.to_string(low)
        None -> "-"
      },
      "c:" <> int.to_string(q.cube_value) <> ":" <> owner_name(q.cube_owner),
      "a:"
        <> int.to_string(q.away_mover)
        <> ","
        <> int.to_string(q.away_opponent),
      "cr:" <> flag(q.crawford),
      "j:" <> flag(q.jacoby),
    ],
    "|",
  )
}

fn flag(value: Bool) -> String {
  case value {
    True -> "1"
    False -> "0"
  }
}

/// The key a puzzle is deduplicated on: sha256 of `canonical`, in hex.
pub fn key(q: Question) -> String {
  digest(q) |> bit_array.base16_encode |> string.lowercase
}

/// The ids to try for a new puzzle, best first: eight characters of the
/// room-code alphabet, read off the same digest the key is, so a rerun of
/// the same extraction asks for exactly the same row.
///
/// Several, because eight characters is a billion times a thousand and a
/// birthday collision between two *different* questions is possible where a
/// million puzzles are. The writer takes the first id no other key already
/// holds; nothing else depends on which one that is.
pub fn ids(q: Question) -> List(String) {
  let d = digest(q)
  list.range(0, 3) |> list.map(fn(n) { id_at(d, n * 5) })
}

@external(erlang, "oskol_puzzles_ffi", "sha256")
fn sha256(text: String) -> BitArray

fn digest(q: Question) -> BitArray {
  sha256(canonical(q))
}

/// Eight five-bit groups out of five bytes of the digest, each a letter of
/// the room-code alphabet.
fn id_at(d: BitArray, offset: Int) -> String {
  case bit_array.slice(d, offset, 5) {
    Ok(<<
      a:size(5),
      b:size(5),
      c:size(5),
      e:size(5),
      f:size(5),
      g:size(5),
      h:size(5),
      i:size(5),
    >>) ->
      [a, b, c, e, f, g, h, i]
      |> list.map(letter)
      |> string.concat
    _ -> "00000000"
  }
}

fn letter(value: Int) -> String {
  code.alphabet
  |> string.to_graphemes
  |> list.drop(value)
  |> list.first
  |> result.unwrap("0")
}

// ---------- Turning a board around ----------

/// The same position from the other side: what a page wants for a `Take`,
/// whose solver is not the player the board is stored for. Points reverse
/// and the two bars swap; the signs follow.
pub fn flip(board: List(Int)) -> List(Int) {
  case board {
    [their_bar, ..rest] ->
      case list.length(rest) == 25 {
        False -> board
        True -> {
          let points = list.take(rest, 24)
          let my_bar = list.drop(rest, 24) |> list.first |> result.unwrap(0)
          list.flatten([
            [my_bar],
            points |> list.reverse |> list.map(int.negate),
            [their_bar],
          ])
        }
      }
    [] -> board
  }
}

// ---------- The stored columns ----------

pub fn question_json(q: Question) -> Json {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string(kind_name(q.kind))),
    #("board", json.array(q.board, json.int)),
    #("dice", case q.dice {
      Some(#(high, low)) -> json.array([high, low], json.int)
      None -> json.null()
    }),
    #(
      "cube",
      json.object([
        #("value", json.int(q.cube_value)),
        #("owner", json.string(owner_name(q.cube_owner))),
      ]),
    ),
    // Money play has no score, and says so rather than reporting 0-away.
    #("score", case q.away_mover == 0 && q.away_opponent == 0 {
      True -> json.null()
      False ->
        json.object([
          #("mover_away", json.int(q.away_mover)),
          #("opponent_away", json.int(q.away_opponent)),
        ])
    }),
    #("crawford", json.bool(q.crawford)),
    #("jacoby", json.bool(q.jacoby)),
  ])
}

pub fn question_decoder() -> Decoder(Question) {
  use kind <- decode.field("kind", decode.string)
  use board <- decode.field("board", decode.list(decode.int))
  use dice <- decode.optional_field(
    "dice",
    None,
    decode.optional(decode.list(decode.int)),
  )
  use value <- decode.subfield(["cube", "value"], decode.int)
  use owner <- decode.subfield(["cube", "owner"], decode.string)
  // Money play writes `"score": null` rather than reporting 0-away, so the
  // whole object is optional *and* nullable. Reading the two fields through
  // a path would refuse an explicit null, and every unlimited game's
  // puzzles are written that way.
  use score <- decode.optional_field(
    "score",
    None,
    decode.optional({
      use mover <- decode.field("mover_away", decode.int)
      use opponent <- decode.field("opponent_away", decode.int)
      decode.success(#(mover, opponent))
    }),
  )
  let #(mover_away, opponent_away) = option.unwrap(score, #(0, 0))
  use crawford <- decode.optional_field("crawford", False, decode.bool)
  use jacoby <- decode.optional_field("jacoby", False, decode.bool)
  decode.success(Question(
    kind: kind_from_name(kind) |> result.unwrap(Move),
    board: board,
    dice: case dice {
      Some([high, low]) -> Some(#(high, low))
      _ -> None
    },
    cube_value: value,
    cube_owner: owner_from_name(owner),
    away_mover: mover_away,
    away_opponent: opponent_away,
    crawford: crawford,
    jacoby: jacoby,
  ))
}

pub fn answer_json(answer: Answer) -> Json {
  case answer {
    MoveAnswer(outcomes, complete, n_legal, candidates) ->
      json.object([
        #("kind", json.string("move")),
        #("complete", json.bool(complete)),
        #("n_legal", json.int(n_legal)),
        #(
          "outcomes",
          json.array(outcomes, fn(o) {
            json.object([
              #("board", json.array(o.board, json.int)),
              #("equity_lost", json.float(o.equity_lost)),
            ])
          }),
        ),
        #("candidates", json.array(candidates, candidate_json)),
      ])
    CubeAnswer(nd, dt, dp, probs, optimal, too_good) ->
      json.object([
        #("kind", json.string("cube")),
        #(
          "equities",
          json.object([
            #("no_double", json.float(nd)),
            #("double_take", json.float(dt)),
            #("double_pass", json.float(dp)),
          ]),
        ),
        #("probs", case probs {
          Some(p) -> probs_json(p)
          None -> json.null()
        }),
        #("optimal", json.string(optimal_name(optimal))),
        #("too_good", json.bool(too_good)),
      ])
  }
}

fn candidate_json(c: Candidate) -> Json {
  json.object([
    #("rank", json.int(c.rank)),
    #("notation", json.string(c.notation)),
    #("equity", json.float(c.equity)),
    #("equity_lost", json.float(c.equity_lost)),
    #("board", json.array(c.board, json.int)),
    #("probs", probs_json(c.probs)),
  ])
}

fn probs_json(p: Probs) -> Json {
  json.object([
    #("win", json.float(p.win)),
    #("gammon_win", json.float(p.gammon_win)),
    #("backgammon_win", json.float(p.backgammon_win)),
    #("gammon_loss", json.float(p.gammon_loss)),
    #("backgammon_loss", json.float(p.backgammon_loss)),
  ])
}

pub fn answer_decoder() -> Decoder(Answer) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "move" -> {
      use outcomes <- decode.optional_field(
        "outcomes",
        [],
        decode.list(outcome_decoder()),
      )
      use complete <- decode.optional_field("complete", False, decode.bool)
      use n_legal <- decode.optional_field("n_legal", 0, decode.int)
      use candidates <- decode.optional_field(
        "candidates",
        [],
        decode.list(candidate_decoder()),
      )
      decode.success(MoveAnswer(outcomes, complete, n_legal, candidates))
    }
    _ -> {
      use nd <- decode.subfield(["equities", "no_double"], number())
      use dt <- decode.subfield(["equities", "double_take"], number())
      use dp <- decode.subfield(["equities", "double_pass"], number())
      use probs <- decode.optional_field(
        "probs",
        None,
        decode.optional(probs_decoder()),
      )
      use optimal <- decode.optional_field("optimal", "", decode.string)
      use too_good <- decode.optional_field("too_good", False, decode.bool)
      decode.success(CubeAnswer(
        nd,
        dt,
        dp,
        probs,
        optimal_from_name(optimal),
        too_good,
      ))
    }
  }
}

fn optimal_from_name(name: String) -> Optimal {
  case name {
    "no_double" -> NoDouble
    "double_take" -> DoubleTake
    "double_pass" -> DoublePass
    other -> OtherCall(other)
  }
}

fn outcome_decoder() -> Decoder(Outcome) {
  use board <- decode.field("board", decode.list(decode.int))
  use equity_lost <- decode.field("equity_lost", number())
  decode.success(Outcome(board, equity_lost))
}

fn candidate_decoder() -> Decoder(Candidate) {
  use rank <- decode.field("rank", decode.int)
  use notation <- decode.field("notation", decode.string)
  use equity <- decode.field("equity", number())
  use equity_lost <- decode.field("equity_lost", number())
  use board <- decode.optional_field("board", [], decode.list(decode.int))
  use probs <- decode.field("probs", probs_decoder())
  decode.success(Candidate(rank, notation, equity, equity_lost, board, probs))
}

fn probs_decoder() -> Decoder(Probs) {
  use win <- decode.field("win", number())
  use gammon_win <- decode.field("gammon_win", number())
  use backgammon_win <- decode.field("backgammon_win", number())
  use gammon_loss <- decode.field("gammon_loss", number())
  use backgammon_loss <- decode.field("backgammon_loss", number())
  decode.success(Probs(
    win,
    gammon_win,
    backgammon_win,
    gammon_loss,
    backgammon_loss,
  ))
}

/// JSON numbers from Python may be written as 0 or 0.0.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

pub fn evaluated_by_json(by: EvaluatedBy) -> Json {
  json.object([
    #("levels", case by.move_level, by.cube_level {
      Some(moves), Some(cube) ->
        json.object([
          #("moves", json.string(moves)),
          #("cube", json.string(cube)),
        ])
      _, _ -> json.null()
    }),
  ])
}

// ---------- Reading one back ----------

pub fn question_from_json(text: String) -> Result(Question, String) {
  json.parse(text, question_decoder())
  |> result.replace_error("A stored puzzle question did not read as one")
}

pub fn answer_from_json(text: String) -> Result(Answer, String) {
  json.parse(text, answer_decoder())
  |> result.replace_error("A stored puzzle answer did not read as one")
}

// ---------- The position a question is asked about ----------

/// The question a turn's position asks, for one kind. The dice belong to a
/// `Move` and to nothing else.
pub fn question_of(
  kind: Kind,
  position: analysis.Position,
  dice: Option(#(Int, Int)),
  jacoby: Bool,
) -> Question {
  Question(
    kind: kind,
    board: position.board,
    dice: case kind {
      Move -> option.map(dice, sorted)
      _ -> None
    },
    cube_value: position.cube_value,
    cube_owner: case position.cube_owner {
      "player" -> Mover
      "opponent" -> Opponent
      _ -> Centered
    },
    away_mover: position.away1,
    away_opponent: position.away2,
    crawford: position.crawford,
    jacoby: jacoby,
  )
}

/// Higher die first, so 6-4 and 4-6 ask one question.
fn sorted(dice: #(Int, Int)) -> #(Int, Int) {
  case dice.0 >= dice.1 {
    True -> dice
    False -> #(dice.1, dice.0)
  }
}

// ---------- The sentence a puzzle is asked in ----------

/// What a puzzle asks, in the game's own words: the head of its page, the
/// line above its board and the line a session lists it by, all one string
/// so that the three can never say different things.
///
/// Written from the **solver's** side, which is the side a page draws at
/// the bottom: the mover for a move or a double, and the player being
/// doubled for a take (whose board a page flips). The solver is White
/// whatever colour they had in the game, which is the whole of the
/// orientation rule.
pub fn prompt(q: Question) -> String {
  case q.kind {
    Move -> "White to play " <> roll(q.dice) <> ". " <> "What's your play?"
    Double -> "White to play. Double?"
    Take -> "White is doubled. Take?"
  }
}

/// A roll as it is written: "6-4", and "3-3" for a double.
fn roll(dice: Option(#(Int, Int))) -> String {
  case dice {
    Some(#(high, low)) -> int.to_string(high) <> "-" <> int.to_string(low)
    // A move question always has its dice; a stored one that somehow does
    // not still has to ask something a page can print.
    None -> "the roll"
  }
}

/// Equity lost at or above which a decision is a mistake, and so a puzzle:
/// the site's doubtful band and everything worse. Floats arrive rounded, so
/// the comparison is made with a hair of room.
pub const mistake_threshold = 0.02

pub fn is_mistake(equity_lost: Float) -> Bool {
  equity_lost >=. mistake_threshold -. 0.000001
}

/// Too good to double: the engine's call is "no double" and playing on is
/// worth more than the point a pass would hand over. The same rule the
/// replay reads (`Page/Replay.elm`, `tooGood`).
pub fn too_good(optimal: Optimal, no_double: Float, double_pass: Float) -> Bool {
  optimal == NoDouble && no_double >=. double_pass
}
