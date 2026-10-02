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
import oskol/core/raw
import oskol/puzzles

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
    /// The seat on roll, as the engine numbers them. Kept because the
    /// seats' totals are worked out from the turns when a review is
    /// assembled out of them (`totals_of`), and every verdict of a turn is
    /// charged to one seat or the other.
    player: Int,
    cube: Option(CubeReview),
    move: Option(MoveReview),
    luck: Option(Float),
  )
}

pub type CubeReview {
  CubeReview(
    action: String,
    response: Option(String),
    /// The three equities, the doubler's payoff. The call is read off
    /// these (`puzzles.cube_call`); the engine's own label,
    /// `optimal_action`, is not read at all.
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
    /// Every legal play the engine evaluated -- the board it leaves and
    /// how much worse than the best it is -- when the request asked for
    /// them (`all_results`). Empty for an answer written before that, and
    /// never rendered into the page: this is what lets a puzzle grade any
    /// answer exactly, and it would only make a review bigger.
    results: List(MoveResult),
    n_legal: Int,
    forced: Bool,
    error: Float,
    grade: String,
  )
}

/// One legal play, compactly: where it leaves the checkers and what it
/// gives up. `equity_diff` is best-relative, so zero or negative.
pub type MoveResult {
  MoveResult(board: List(Int), equity_diff: Float)
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
/// PR needs two numbers out of it, and asks for only those: each seat's
/// totals and the first turn's cube verdict, which is all it takes to leave
/// out the one decision the engine grades that nobody could have made (see
/// `unofferable`). A whole response reads the same way.
pub fn player_prs(body: String) -> Result(List(Float), String) {
  player_totals(body) |> result.map(list.map(_, fn(rating) { rating.0 }))
}

/// The same read, keeping the totals themselves: each seat's rating and,
/// where the row stores them, the whole totals behind it -- the error and
/// the decision counts a PR over several games is worked out from.
///
/// A row written before totals were stored carries only the number, so its
/// seat is `#(pr, None)`: there is a rating to print but nothing to add up,
/// and a caller that is adding up must skip it rather than count it as no
/// error over no decisions.
///
/// The phantom opening "no double" is off both, so the totals agree with
/// the rating beside them.
pub fn player_totals(
  body: String,
) -> Result(List(#(Float, Option(Totals))), String) {
  json.parse(body, {
    use players <- decode.field("players", decode.list(rating_decoder()))
    use first <- decode.optional_field(
      "turns",
      [],
      decode.list(opening_decoder()),
    )
    let phantom = case first {
      [#(Some(seat), Some(cube)), ..] ->
        case unofferable(1, cube, True) {
          True -> Some(#(seat, cube.doubler))
          False -> None
        }
      _ -> None
    }
    decode.success(
      list.index_map(players, fn(rating, seat) {
        case rating, phantom {
          #(_, Some(totals)), Some(#(s, verdict)) if s == seat -> {
            let corrected = without_verdicts(totals, [verdict])
            #(corrected.pr, Some(corrected))
          }
          rating, _ -> rating
        }
      }),
    )
  })
  |> result.replace_error("The engine's review named no ratings")
}

/// A seat's rating as stored: its whole totals when they are there, else
/// just the number.
fn rating_decoder() -> Decoder(#(Float, Option(Totals))) {
  decode.one_of(totals_decoder() |> decode.map(fn(t) { #(t.pr, Some(t)) }), [
    {
      use pr <- decode.field("pr", number())
      decode.success(#(pr, None))
    },
  ])
}

/// The seat on roll and the cube verdict of a turn, and nothing else.
fn opening_decoder() -> Decoder(#(Option(Int), Option(CubeReview))) {
  use seat <- decode.optional_field("player", None, decode.optional(decode.int))
  use cube <- decode.optional_field(
    "cube",
    None,
    decode.one_of(decode.optional(cube_decoder()), [decode.success(None)]),
  )
  decode.success(#(seat, cube))
}

// ---------- A review assembled from its turns ----------

/// One turn's answer as it is stored on its own, before there is a review to
/// put it in: the engine's own object for that turn, verbatim, the depths it
/// was graded at, and what it cost.
///
/// `turn` is text because an assembled review hands the engine's answer
/// straight back rather than rebuilding it: every number a page shows about
/// a turn is the engine's, whether the turn was graded as it was played or
/// with the rest of the game at the end.
pub type Graded {
  Graded(
    /// Where the turn sits in its game, as the engine echoed it back.
    index: Int,
    turn: String,
    /// The whole `levels` object the engine sent, kept verbatim so an
    /// assembled answer says exactly what a whole-game one would, and
    /// decoded beside it so a caller can ask for the rest of the game at
    /// the same depth.
    levels: Option(Levels),
    levels_json: Option(String),
    timing_ms: Option(Int),
    /// The same turn decoded, for the seats' totals.
    review: TurnReview,
  )
}

/// The turns of an engine response, each on its own. What a one-turn grade
/// is read as when it is stored, and what a request for the turns a game is
/// missing is read as when it comes back.
pub fn graded_turns(body: String) -> Result(List(Graded), String) {
  let shape = {
    use turns <- decode.field("turns", decode.list(decode.dynamic))
    use levels <- decode.optional_field(
      "levels",
      None,
      decode.optional(decode.dynamic),
    )
    use timing <- decode.optional_field(
      "timing_ms",
      None,
      decode.optional(number()),
    )
    decode.success(#(turns, levels, timing))
  }
  use #(turns, levels, timing) <- result.try(
    json.parse(body, shape)
    |> result.replace_error("A graded turn did not read as a review"),
  )
  let named = case levels {
    Some(data) -> decode.run(data, levels_decoder()) |> option.from_result
    None -> None
  }
  // The engine times a request, not a turn, so the parts of one request
  // share its time. Nothing reads it but the total a page prints.
  let each = case timing, list.length(turns) {
    Some(ms), count if count > 0 -> Some(float.round(ms) / count)
    _, _ -> None
  }
  list.try_map(turns, fn(data) {
    use review <- result.try(
      decode.run(data, turn_decoder())
      |> result.replace_error("A graded turn did not read as a graded turn"),
    )
    Ok(Graded(
      index: review.index,
      turn: raw.text(data),
      levels: named,
      levels_json: option.map(levels, raw.text),
      timing_ms: each,
      review: review,
    ))
  })
}

/// One game's review built out of the engine's answers for its turns, in the
/// shape a whole-game answer has.
///
/// Every turn is the engine's own answer for it, verbatim and in order; the
/// seats' totals are worked out here (`totals_of`), since they are the one
/// part of a review that is about the game rather than about a turn. The
/// engine time is what the parts cost between them, and `assembled` says
/// where the answer came from, so a stored response is never mistaken for
/// one the engine gave whole.
///
/// `Error` when the parts are not this game's turns in order: the caller has
/// mixed up a cache, and a review built on that would grade the wrong
/// positions.
pub fn assemble(parts: List(Graded)) -> Result(Json, String) {
  use _ <- result.try(
    case
      list.index_map(parts, fn(part, index) { part.index == index })
      |> list.all(fn(right) { right })
    {
      True -> Ok(Nil)
      False -> Error("The graded turns are not this game's turns in order")
    },
  )
  let timing =
    list.fold(parts, 0, fn(total, part) {
      total + option.unwrap(part.timing_ms, 0)
    })
  let levels =
    list.find_map(parts, fn(part) { option.to_result(part.levels_json, Nil) })
  let totals = totals_of(list.map(parts, fn(part) { part.review }))
  Ok(
    json.object([
      #("assembled", json.bool(True)),
      #("levels", case levels {
        Ok(text) -> raw.json(text)
        Error(_) -> json.null()
      }),
      #("timing_ms", json.int(timing)),
      #("players", json.array(totals, totals_to_json)),
      #("turns", json.array(parts, fn(part) { raw.json(part.turn) })),
    ]),
  )
}

/// The seats' totals over a game's graded turns, the engine's own way
/// (`review_game` in the engine's app/review.py, which is the spec): a
/// turn's cube verdicts charged to the doubler and to the taker, its luck
/// and its move to the mover, a forced move counted but not graded; then,
/// per seat, the error summed and XG's Performance Rating -- equity lost per
/// unforced decision, times 500.
///
/// This is the one number in an assembled review that is not the engine's
/// own answer, so it has to agree with it exactly, down to the order the
/// floats are added in. `report_test` holds it to every stored response the
/// suite keeps: `totals_of(turns) == players`.
pub fn totals_of(turns: List(TurnReview)) -> List(Totals) {
  let #(first, second) =
    list.fold(turns, #(no_totals(), no_totals()), fn(seats, turn) {
      let #(me, them) = case turn.player {
        0 -> #(seats.0, seats.1)
        _ -> #(seats.1, seats.0)
      }
      let #(me, them) = charge(me, them, turn)
      case turn.player {
        0 -> #(me, them)
        _ -> #(them, me)
      }
    })
  [rated(first), rated(second)]
}

/// One turn charged to the mover and, where a double was answered, to the
/// other seat.
fn charge(me: Totals, them: Totals, turn: TurnReview) -> #(Totals, Totals) {
  let #(me, them) = case turn.cube {
    None -> #(me, them)
    Some(cube) -> #(
      Totals(
        ..me,
        cube_decisions: me.cube_decisions + 1,
        cube_error: me.cube_error +. cube.doubler.error,
        mistakes: counted(me.mistakes, cube.doubler.mistake),
      ),
      case cube.taker {
        None -> them
        Some(taker) ->
          Totals(
            ..them,
            cube_decisions: them.cube_decisions + 1,
            cube_error: them.cube_error +. taker.error,
            mistakes: counted(them.mistakes, taker.mistake),
          )
      },
    )
  }
  let me = case turn.luck {
    Some(luck) -> Totals(..me, luck: me.luck +. luck)
    None -> me
  }
  let me = case turn.move {
    // A dance is not a decision and the engine counts it as neither.
    None | Some(Danced) -> me
    Some(Moved(forced: True, ..)) -> Totals(..me, forced: me.forced + 1)
    Some(Moved(error: error, grade: grade, ..)) ->
      Totals(
        ..me,
        move_decisions: me.move_decisions + 1,
        move_error: me.move_error +. error,
        grades: counted(me.grades, Some(grade)),
      )
  }
  #(me, them)
}

fn counted(bucket: Dict(String, Int), name: Option(String)) -> Dict(String, Int) {
  case name {
    None -> bucket
    Some(name) ->
      dict.insert(
        bucket,
        name,
        1 + { dict.get(bucket, name) |> result.unwrap(0) },
      )
  }
}

/// A seat's error and rating, once every turn has been charged to it.
fn rated(t: Totals) -> Totals {
  let error = t.move_error +. t.cube_error
  let decisions = t.move_decisions + t.cube_decisions
  Totals(..t, error: error, pr: case decisions {
    0 -> 0.0
    _ -> error /. int.to_float(decisions) *. 500.0
  })
}

fn no_totals() -> Totals {
  Totals(
    move_decisions: 0,
    forced: 0,
    move_error: 0.0,
    grades: dict.new(),
    cube_decisions: 0,
    cube_error: 0.0,
    mistakes: dict.new(),
    luck: 0.0,
    error: 0.0,
    pr: 0.0,
  )
}

/// A seat's totals in the engine's own shape, so everything that reads a
/// stored response -- this module's own decoder, the ratings query, the
/// recent list -- reads an assembled one the same way.
fn totals_to_json(t: Totals) -> Json {
  json.object([
    #(
      "moves",
      json.object([
        #("decisions", json.int(t.move_decisions)),
        #("forced", json.int(t.forced)),
        #("error", json.float(t.move_error)),
        #("grades", json.dict(t.grades, fn(name) { name }, json.int)),
      ]),
    ),
    #(
      "cube",
      json.object([
        #("decisions", json.int(t.cube_decisions)),
        #("error", json.float(t.cube_error)),
        #("mistakes", json.dict(t.mistakes, fn(name) { name }, json.int)),
      ]),
    ),
    #("luck", json.float(t.luck)),
    #("error", json.float(t.error)),
    #("pr", json.float(t.pr)),
  ])
}

// ---------- Performance rating ----------

/// A "no double" the engine graded where the mover could not have doubled.
/// The engine grades the cube on every turn its own rules allow, and that
/// includes the opening roll, which is thrown before anyone holds the cube.
/// After Crawford that verdict is a missed double charged to whoever opens
/// behind, on a decision that never existed. The page shows no verdict
/// there, and a PR counts no decision there. `number` is the turn's place in
/// the game, from 1; `can_double` is `analysis.engine_can_double` of it.
pub fn unofferable(number: Int, cube: CubeReview, can_double: Bool) -> Bool {
  cube.action == "no_double" && { number == 1 || !can_double }
}

/// A seat's totals without cube verdicts the engine counted but should not
/// have: each leaves the cube decisions, the error and the mistakes, and the
/// PR is worked out again the engine's way (equity lost per unforced
/// decision, times 500).
pub fn without_verdicts(t: Totals, verdicts: List(Verdict)) -> Totals {
  case verdicts {
    [] -> t
    _ -> {
      let cube_error =
        list.fold(verdicts, t.cube_error, fn(acc, v) { acc -. v.error })
        |> float.max(0.0)
      let cube_decisions = int.max(0, t.cube_decisions - list.length(verdicts))
      let mistakes =
        list.fold(verdicts, t.mistakes, fn(acc, v) {
          case v.mistake {
            Some(name) ->
              case dict.get(acc, name) {
                Ok(n) if n > 1 -> dict.insert(acc, name, n - 1)
                Ok(_) -> dict.delete(acc, name)
                Error(_) -> acc
              }
            None -> acc
          }
        })
      let error = t.move_error +. cube_error
      let decisions = t.move_decisions + cube_decisions
      Totals(
        ..t,
        cube_decisions: cube_decisions,
        cube_error: cube_error,
        mistakes: mistakes,
        error: error,
        pr: case decisions {
          0 -> 0.0
          _ -> error /. int.to_float(decisions) *. 500.0
        },
      )
    }
  }
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
    decode.one_of(levels_decoder() |> decode.map(Some), [decode.success(None)]),
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

/// The depths the engine searched at. It has called the move level both
/// "move" and "moves".
fn levels_decoder() -> Decoder(Levels) {
  decode.one_of(
    {
      use moves <- decode.field(
        "move",
        decode.one_of(decode.string, [decode.at(["moves"], decode.string)]),
      )
      use cube <- decode.field("cube", decode.string)
      decode.success(Levels(moves, cube))
    },
    [
      {
        use moves <- decode.field("moves", decode.string)
        use cube <- decode.field("cube", decode.string)
        decode.success(Levels(moves, cube))
      },
    ],
  )
}

fn turn_decoder() -> Decoder(TurnReview) {
  use index <- decode.field("index", decode.int)
  // The engine names the seat on roll on every turn it grades. Optional
  // here for the same reason everything else is: a response is read for
  // what a page needs, and one written before this decoder must not stop
  // reading. Only an assembled review's totals depend on it, and those are
  // built from answers the engine gave today.
  use player <- decode.optional_field("player", 0, decode.int)
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
  decode.success(TurnReview(index, player, cube, move, luck))
}

fn cube_decoder() -> Decoder(CubeReview) {
  use action <- decode.field("action", decode.string)
  use response <- decode.optional_field(
    "response",
    None,
    decode.optional(decode.string),
  )
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
      // Absent from every answer the engine gave before `all_results` was
      // asked for, and that is not an error: the review renders the same
      // either way, and a puzzle made from one simply says its answer is
      // incomplete.
      use results <- decode.optional_field(
        "results",
        [],
        decode.list(result_decoder()),
      )
      use n_legal <- decode.field("n_legal", decode.int)
      use forced <- decode.field("forced", decode.bool)
      use error <- decode.field("error", number())
      use grade <- decode.field("grade", decode.string)
      decode.success(Moved(
        played,
        best,
        top,
        results,
        n_legal,
        forced,
        error,
        grade,
      ))
    }
  }
}

fn result_decoder() -> Decoder(MoveResult) {
  use board <- decode.field("board", decode.list(decode.int))
  use equity_diff <- decode.field("equity_diff", number())
  decode.success(MoveResult(board, equity_diff))
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
  let hidden =
    list.index_map(pairs, fn(pair, i) {
      let #(turn, graded) = pair
      case graded.cube {
        Some(cube) ->
          case
            unofferable(i + 1, cube, analysis.engine_can_double(turn.position))
          {
            True -> [#(turn.player, cube.doubler)]
            False -> []
          }
        None -> []
      }
    })
    |> list.flatten
  let players =
    list.index_map(review.players, fn(t, seat) {
      without_verdicts(
        t,
        list.filter_map(hidden, fn(h) {
          case h.0 == seat {
            True -> Ok(h.1)
            False -> Error(Nil)
          }
        }),
      )
    })
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
        json.array(list.index_map(players, fn(t, i) { #(t, i) }), fn(pair) {
          totals_json(pair.0, pair.1, seat_of(pair.1))
        }),
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
      Some(Moved(played, best, top, _results, n_legal, forced, error, grade)),
        False
      ->
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
    // A verdict on a double that could not have been offered is nothing a
    // page should show (`unofferable`); the seat's totals leave it out too.
    #("cube", case graded.cube {
      None -> json.null()
      Some(cube) ->
        case
          unofferable(number, cube, analysis.engine_can_double(turn.position))
        {
          True -> json.null()
          False ->
            json.object([
              #("action", json.string(cube.action)),
              #("response", nullable_string(cube.response)),
              // The call from the equities beside it. A report written
              // before this carries the engine's label here instead
              // ("No Double"); the page reads neither and works the call
              // out from the equities (`Replay.cubeCall`).
              #(
                "optimal",
                json.string(
                  puzzles.optimal_name(puzzles.cube_call(
                    cube.no_double,
                    cube.double_take,
                    cube.double_pass,
                  )),
                ),
              ),
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
