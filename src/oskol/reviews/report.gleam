//// The analysis engine's review of one game, read and reshaped for a page
//// to render as it stands: every turn with its grade, the move played, the
//// best move and the top few with the equity each gives up, the cube
//// verdicts and the luck of the roll; every player's PR, error, grade
//// counts and luck. Seats are named by the room's own player ids, never
//// the engine's 0/1.
////
//// The engine's shape is its README's (`POST /backgammon/review`). Decoding
//// it is strict about what a page needs and lax about the rest, so a
//// response that decodes is one the page can render.

import backgammon/analysis.{type Turn, Passed, Took}
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// ---------- The engine's review ----------

pub type Review {
  Review(turns: List(TurnReview), players: List(Totals))
}

pub type TurnReview {
  TurnReview(
    index: Int,
    cube: Option(CubeReview),
    move: Option(MoveReview),
    luck: Option(Float),
  )
}

pub type CubeReview {
  CubeReview(
    action: String,
    response: Option(String),
    optimal: String,
    no_double: Float,
    double_take: Float,
    double_pass: Float,
    doubler: Verdict,
    taker: Option(Verdict),
  )
}

pub type Verdict {
  Verdict(error: Float, grade: String, mistake: Option(String))
}

pub type MoveReview {
  Danced
  Moved(
    played: Candidate,
    best: Candidate,
    top: List(Candidate),
    n_legal: Int,
    forced: Bool,
    error: Float,
    grade: String,
  )
}

pub type Candidate {
  Candidate(
    rank: Int,
    notation: String,
    equity: Float,
    equity_diff: Float,
    probs: Probs,
  )
}

pub type Probs {
  Probs(
    win: Float,
    gammon_win: Float,
    backgammon_win: Float,
    gammon_loss: Float,
    backgammon_loss: Float,
  )
}

pub type Totals {
  Totals(
    move_decisions: Int,
    forced: Int,
    move_error: Float,
    grades: Dict(String, Int),
    cube_decisions: Int,
    cube_error: Float,
    mistakes: Dict(String, Int),
    luck: Float,
    error: Float,
    pr: Float,
  )
}

/// Read the engine's response body.
pub fn parse(body: String) -> Result(Review, String) {
  json.parse(body, review_decoder())
  |> result.replace_error("The engine's review did not read as a review")
}

/// JSON numbers from Python may be written as 0 or 0.0.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn review_decoder() -> Decoder(Review) {
  use turns <- decode.field("turns", decode.list(turn_decoder()))
  use players <- decode.field("players", decode.list(totals_decoder()))
  case list.length(players) {
    2 -> decode.success(Review(turns, players))
    _ -> decode.failure(Review(turns, players), "two players")
  }
}

fn turn_decoder() -> Decoder(TurnReview) {
  use index <- decode.field("index", decode.int)
  use cube <- decode.optional_field(
    "cube",
    None,
    decode.optional(cube_decoder()),
  )
  use move <- decode.optional_field(
    "move",
    None,
    decode.optional(move_decoder()),
  )
  use luck <- decode.optional_field(
    "luck",
    None,
    decode.optional(decode.at(["luck"], number())),
  )
  decode.success(TurnReview(index, cube, move, luck))
}

fn cube_decoder() -> Decoder(CubeReview) {
  use action <- decode.field("action", decode.string)
  use response <- decode.optional_field(
    "response",
    None,
    decode.optional(decode.string),
  )
  use optimal <- decode.subfield(["analysis", "optimal_action"], decode.string)
  use nd <- decode.subfield(["analysis", "equity_nd"], number())
  use dt <- decode.subfield(["analysis", "equity_dt"], number())
  use dp <- decode.subfield(["analysis", "equity_dp"], number())
  use doubler <- decode.field("doubler", verdict_decoder())
  use taker <- decode.optional_field(
    "taker",
    None,
    decode.optional(verdict_decoder()),
  )
  decode.success(CubeReview(
    action: action,
    response: response,
    optimal: optimal,
    no_double: nd,
    double_take: dt,
    double_pass: dp,
    doubler: doubler,
    taker: taker,
  ))
}

fn verdict_decoder() -> Decoder(Verdict) {
  use error <- decode.field("error", number())
  use grade <- decode.field("grade", decode.string)
  use mistake <- decode.optional_field(
    "mistake",
    None,
    decode.optional(decode.string),
  )
  decode.success(Verdict(error, grade, mistake))
}

fn move_decoder() -> Decoder(MoveReview) {
  use danced <- decode.optional_field("danced", False, decode.bool)
  case danced {
    True -> decode.success(Danced)
    False -> {
      use played <- decode.field("played", candidate_decoder())
      use best <- decode.field("best", candidate_decoder())
      use top <- decode.field("top", decode.list(candidate_decoder()))
      use n_legal <- decode.field("n_legal", decode.int)
      use forced <- decode.field("forced", decode.bool)
      use error <- decode.field("error", number())
      use grade <- decode.field("grade", decode.string)
      decode.success(Moved(played, best, top, n_legal, forced, error, grade))
    }
  }
}

fn candidate_decoder() -> Decoder(Candidate) {
  use rank <- decode.field("rank", decode.int)
  use notation <- decode.field("notation", decode.string)
  use equity <- decode.field("equity", number())
  use equity_diff <- decode.field("equity_diff", number())
  use probs <- decode.field("probs", probs_decoder())
  decode.success(Candidate(rank, notation, equity, equity_diff, probs))
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

fn totals_decoder() -> Decoder(Totals) {
  use move_decisions <- decode.subfield(["moves", "decisions"], decode.int)
  use forced <- decode.subfield(["moves", "forced"], decode.int)
  use move_error <- decode.subfield(["moves", "error"], number())
  use grades <- decode.subfield(
    ["moves", "grades"],
    decode.dict(decode.string, decode.int),
  )
  use cube_decisions <- decode.subfield(["cube", "decisions"], decode.int)
  use cube_error <- decode.subfield(["cube", "error"], number())
  use mistakes <- decode.subfield(
    ["cube", "mistakes"],
    decode.dict(decode.string, decode.int),
  )
  use luck <- decode.field("luck", number())
  use error <- decode.field("error", number())
  use pr <- decode.field("pr", number())
  decode.success(Totals(
    move_decisions: move_decisions,
    forced: forced,
    move_error: move_error,
    grades: grades,
    cube_decisions: cube_decisions,
    cube_error: cube_error,
    mistakes: mistakes,
    luck: luck,
    error: error,
    pr: pr,
  ))
}

// ---------- The page's shape ----------

/// A seat as the review names it.
pub type Seat {
  Seat(player_id: String, name: String, color: String)
}

/// Move grades, best first, and the cube mistakes, always all present so a
/// page can lay out a fixed table.
pub const grade_names = ["best", "ok", "doubtful", "bad", "very_bad"]

pub const mistake_names = [
  "missed_double", "wrong_double", "wrong_take", "wrong_pass",
]

/// The review as a page renders it. `turns` are the turns the engine was
/// asked about, in the same order; a turn the engine answered for that is
/// missing here (or the other way round) means the review is not this
/// game's, and nothing is rendered.
pub fn to_json(
  review: Review,
  turns: List(Turn),
  seats: List(Seat),
) -> Result(Json, String) {
  use pairs <- result.try(
    list.strict_zip(turns, review.turns)
    |> result.replace_error("The review does not match the game"),
  )
  let seat_of = fn(index: Int) {
    case list.drop(seats, index) {
      [seat, ..] -> seat
      [] -> Seat("", "", "")
    }
  }
  Ok(
    json.object([
      #(
        "players",
        json.array(
          list.index_map(review.players, fn(t, i) { #(t, i) }),
          fn(pair) { totals_json(pair.0, pair.1, seat_of(pair.1)) },
        ),
      ),
      #(
        "turns",
        json.array(list.index_map(pairs, fn(pair, i) { #(pair, i) }), fn(entry) {
          let #(#(turn, graded), i) = entry
          turn_json(i + 1, turn, graded, seat_of)
        }),
      ),
    ]),
  )
}

fn totals_json(t: Totals, seat_index: Int, seat: Seat) -> Json {
  json.object([
    #("seat", json.int(seat_index)),
    #("player_id", json.string(seat.player_id)),
    #("name", json.string(seat.name)),
    #("color", json.string(seat.color)),
    #("pr", json.float(t.pr)),
    #("error", json.float(t.error)),
    #("luck", json.float(t.luck)),
    #(
      "moves",
      json.object([
        #("decisions", json.int(t.move_decisions)),
        #("forced", json.int(t.forced)),
        #("error", json.float(t.move_error)),
        #("grades", counts(t.grades, grade_names)),
      ]),
    ),
    #(
      "cube",
      json.object([
        #("decisions", json.int(t.cube_decisions)),
        #("error", json.float(t.cube_error)),
        #("mistakes", counts(t.mistakes, mistake_names)),
      ]),
    ),
  ])
}

fn counts(found: Dict(String, Int), names: List(String)) -> Json {
  json.object(
    list.map(names, fn(name) {
      #(name, json.int(dict.get(found, name) |> result.unwrap(0)))
    }),
  )
}

fn turn_json(
  number: Int,
  turn: Turn,
  graded: TurnReview,
  seat_of: fn(Int) -> Seat,
) -> Json {
  let seat = seat_of(turn.player)
  let other = 1 - turn.player
  json.object([
    #("number", json.int(number)),
    #("log_index", json.int(turn.log_index)),
    #("seat", json.int(turn.player)),
    #("player_id", json.string(turn.player_id)),
    #("color", json.string(seat.color)),
    #("dice", case turn.dice {
      Some(#(a, b)) -> json.array([a, b], json.int)
      None -> json.null()
    }),
    #("picked", json.bool(turn.picked)),
    #("double", case turn.double {
      Some(Took) -> json.string("take")
      Some(Passed) -> json.string("pass")
      None -> json.null()
    }),
    #("move", case graded.move, analysis.danced(turn) {
      None, _ -> json.null()
      // The engine lists a dance as a forced "move" that changes nothing;
      // it is a dance, and a page says so.
      Some(Danced), _ | _, True -> json.object([#("danced", json.bool(True))])
      Some(Moved(played, best, top, n_legal, forced, error, grade)), False ->
        json.object([
          #("danced", json.bool(False)),
          #("grade", json.string(grade)),
          #("equity_lost", json.float(error)),
          #("forced", json.bool(forced)),
          #("n_legal", json.int(n_legal)),
          #("played", candidate_json(played, played.rank)),
          #("best", candidate_json(best, played.rank)),
          #(
            "top",
            json.array(top, fn(candidate) {
              candidate_json(candidate, played.rank)
            }),
          ),
        ])
    }),
    #("cube", case graded.cube {
      None -> json.null()
      Some(cube) ->
        json.object([
          #("action", json.string(cube.action)),
          #("response", nullable_string(cube.response)),
          #("optimal", json.string(cube.optimal)),
          #(
            "equities",
            json.object([
              #("no_double", json.float(cube.no_double)),
              #("double_take", json.float(cube.double_take)),
              #("double_pass", json.float(cube.double_pass)),
            ]),
          ),
          #("doubler", verdict_json(cube.doubler, turn.player)),
          #("taker", case cube.taker {
            Some(verdict) -> verdict_json(verdict, other)
            None -> json.null()
          }),
        ])
    }),
    #("luck", case graded.luck, turn.picked {
      // Picked dice are chosen, not rolled: there is no luck to speak of.
      _, True -> json.null()
      Some(luck), False -> json.float(luck)
      None, False -> json.null()
    }),
  ])
}

fn candidate_json(c: Candidate, played_rank: Int) -> Json {
  json.object([
    #("rank", json.int(c.rank)),
    #("notation", json.string(c.notation)),
    #("equity", json.float(c.equity)),
    // The engine's diff is best-relative and negative for worse plays
    #("equity_lost", json.float(float.max(0.0, float.negate(c.equity_diff)))),
    #("played", json.bool(c.rank == played_rank)),
    #(
      "probs",
      json.object([
        #("win", json.float(c.probs.win)),
        #("gammon_win", json.float(c.probs.gammon_win)),
        #("backgammon_win", json.float(c.probs.backgammon_win)),
        #("gammon_loss", json.float(c.probs.gammon_loss)),
        #("backgammon_loss", json.float(c.probs.backgammon_loss)),
      ]),
    ),
  ])
}

fn verdict_json(v: Verdict, seat: Int) -> Json {
  json.object([
    #("seat", json.int(seat)),
    #("grade", json.string(v.grade)),
    #("equity_lost", json.float(v.error)),
    #("mistake", nullable_string(v.mistake)),
  ])
}

fn nullable_string(value: Option(String)) -> Json {
  case value {
    Some(text) -> json.string(text)
    None -> json.null()
  }
}
