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
import backgammon/board
import backgammon/record
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
  Review(
    turns: List(TurnReview),
    players: List(Totals),
    /// The depth the engine searched at, as it names it ("4ply"): for moves,
    /// and for the cube. Absent from answers that predate it.
    levels: Option(Levels),
    /// How long the engine took, in milliseconds, when it says.
    timing_ms: Option(Int),
  )
}

pub type Levels {
  Levels(moves: String, cube: String)
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
    /// The chances the cube was judged on, before the roll; None for an
    /// answer written before the report kept them.
    probs: Option(Probs),
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
    /// The board the move leaves, from the mover's side, in the engine's
    /// format; empty when the engine did not send one.
    board: List(Int),
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

/// Just the performance ratings, in seat order, without reading the turns.
/// A whole review is large (every turn, with its candidate moves); a match
/// PR needs two numbers out of it, and asks for only those.
pub fn player_prs(body: String) -> Result(List(Float), String) {
  json.parse(
    body,
    decode.field(
      "players",
      decode.list({
        use pr <- decode.field("pr", number())
        decode.success(pr)
      }),
      decode.success,
    ),
  )
  |> result.replace_error("The engine's review named no ratings")
}

/// JSON numbers from Python may be written as 0 or 0.0.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn review_decoder() -> Decoder(Review) {
  use turns <- decode.field("turns", decode.list(turn_decoder()))
  use players <- decode.field("players", decode.list(totals_decoder()))
  use levels <- decode.optional_field(
    "levels",
    None,
    decode.one_of(
      {
        // The engine has called the move level both "move" and "moves".
        use moves <- decode.field(
          "move",
          decode.one_of(decode.string, [decode.at(["moves"], decode.string)]),
        )
        use cube <- decode.field("cube", decode.string)
        decode.success(Some(Levels(moves, cube)))
      },
      [
        {
          use moves <- decode.field("moves", decode.string)
          use cube <- decode.field("cube", decode.string)
          decode.success(Some(Levels(moves, cube)))
        },
        decode.success(None),
      ],
    ),
  )
  // Whatever shape a later engine gives it, a total that is not a number is
  // simply not shown.
  use timing_ms <- decode.optional_field(
    "timing_ms",
    None,
    decode.one_of(number() |> decode.map(fn(ms) { Some(float.round(ms)) }), [
      decode.at(["total"], number())
        |> decode.map(fn(ms) { Some(float.round(ms)) }),
      decode.success(None),
    ]),
  )
  let review = Review(turns, players, levels, timing_ms)
  case list.length(players) {
    2 -> decode.success(review)
    _ -> decode.failure(review, "two players")
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
  use probs <- decode.then(decode.optionally_at(
    ["analysis", "probs"],
    None,
    decode.optional(probs_decoder()),
  ))
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
    probs: probs,
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
  use board <- decode.optional_field("board", [], decode.list(decode.int))
  decode.success(Candidate(rank, notation, equity, equity_diff, probs, board))
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
      // The search depth the engine used, for moves and for the cube.
      #("levels", case review.levels {
        Some(Levels(moves, cube)) ->
          json.object([
            #("moves", json.string(moves)),
            #("cube", json.string(cube)),
          ])
        None -> json.null()
      }),
      #("timing_ms", json.nullable(review.timing_ms, json.int)),
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
  let candidate = fn(c: Candidate, played_rank: Int) {
    candidate_json(c, played_rank, turn)
  }
  json.object([
    #("number", json.int(number)),
    #("log_index", json.int(turn.log_index)),
    // The lines of the game's record this turn's verdicts are about.
    #("entry", json.nullable(turn.entry, json.int)),
    #("double_entry", json.nullable(turn.double_entry, json.int)),
    #("answer_entry", json.nullable(turn.answer_entry, json.int)),
    #("seat", json.int(turn.player)),
    #("player_id", json.string(turn.player_id)),
    #("color", json.string(seat.color)),
    #("dice", case turn.dice {
      Some(#(a, b)) -> json.array([a, b], json.int)
      None -> json.null()
    }),
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
          #("played", candidate(played, played.rank)),
          #("best", candidate(best, played.rank)),
          #("top", json.array(top, fn(c) { candidate(c, played.rank) })),
        ])
    }),
    // The engine grades "no double" on every turn, the opening roll and a
    // cube the mover did not hold included. A verdict on a double that
    // could not have been offered is nothing a page should show.
    #("cube", case graded.cube {
      None -> json.null()
      Some(cube) ->
        case
          cube.action == "no_double"
          && { number == 1 || !analysis.engine_can_double(turn.position) }
        {
          True -> json.null()
          False ->
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
              #("probs", case cube.probs {
                Some(probs) -> probs_json(probs)
                None -> json.null()
              }),
              #("doubler", verdict_json(cube.doubler, turn.player)),
              #("taker", case cube.taker {
                Some(verdict) -> verdict_json(verdict, other)
                None -> json.null()
              }),
            ])
        }
    }),
    #("luck", case graded.luck {
      Some(luck) -> json.float(luck)
      None -> json.null()
    }),
  ])
}

fn candidate_json(c: Candidate, played_rank: Int, turn: Turn) -> Json {
  // The board the move leaves, as the record draws a position, and where
  // its checkers land: what a page needs to put this move on the board
  // without reading its notation.
  let mover = case turn.player {
    0 -> board.White
    _ -> board.Black
  }
  let #(position, landed) = case analysis.decode(c.board, mover) {
    Ok(#(white, black)) -> #(
      json.object([
        #("white", record.side_to_json(white)),
        #("black", record.side_to_json(black)),
      ]),
      json.array(
        analysis.landings(turn.position.board, c.board, mover),
        json.int,
      ),
    )
    Error(_) -> #(json.null(), json.null())
  }
  json.object([
    #("position", position),
    #("landed", landed),
    #("rank", json.int(c.rank)),
    #("notation", json.string(c.notation)),
    #("equity", json.float(c.equity)),
    // The engine's diff is best-relative and negative for worse plays
    #("equity_lost", json.float(float.max(0.0, float.negate(c.equity_diff)))),
    #("played", json.bool(c.rank == played_rank)),
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
