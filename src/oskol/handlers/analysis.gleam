//// Asking the engine about one position, on a player's say-so:
////
////     POST /papi/analysis        a set-up position (`analysis/setup`'s wire)
////     GET  /papi/analysis/:key   where that ask stands
////     POST /papi/analysis/moves  the legal plays of a set-up roll: no engine
////
//// **An analyzed position is a puzzle row.** The question is the key
//// (`oskol/puzzles.key`), so a position asked before -- by anyone, as a
//// mistake in a game, as a set's position, as an earlier ask -- is answered
//// from the row at once and costs nothing. Only a key with no complete row
//// is put to the engine, and only then is anybody's budget charged.
////
//// **Engine time is bounded four ways**, every one decided here: the cache
//// by key; one job per key (a second ask of a key in hand joins it, free);
//// the asker's line (`Oskol.Analysis.Asker`: two in flight, twenty
//// waiting, a circuit that stays open for a minute after the engine
//// fails); and the budgets (`buckets`): a guest 10 an hour and 30 a day, an
//// account 30 an hour and 150 a day, everybody 600 a day, all from
//// `config :oskol, :analysis_budget`.
////
//// The asker owns the queue and nothing else. It hands the engine's answer
//// back to `store`, which decides whether it can be trusted -- every legal
//// play and a board on every candidate, or the cube's chances -- and only
//// then writes the puzzle, with origin "analysis" so it never reaches TRY
//// ONE, and draws its picture.

import backgammon/analysis
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/analysis/setup.{type Setup}
import oskol/caps/analysis.{
  type Ask, type AskBudget, type Job, type Refused, Ask, Asked, Down, Free, Full,
  JobDone, JobFailed, JobPending,
} as _asker
import oskol/caps/auth.{type LimitBucket, LimitBucket}
import oskol/caps/puzzles.{type Keyed} as _puzzle_caps
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/handlers/puzzles as puzzle_page
import oskol/practice/openings
import oskol/puzzles.{type Question}
import oskol/puzzles/extract
import oskol/reviews/report

/// What an analyzed position's puzzle row says about where it came from.
/// Never in TRY ONE (`Oskol.Puzzles.sample/1`).
pub const origin = "analysis"

pub const not_a_position_message = "That is not a position"

pub const busy_message = "The engine is busy. Try again in a minute."

pub const engine_down_message = "The engine is asleep. Try again in a minute."

/// A job the engine answered and that could not be kept, or that crashed:
/// asking again may work, and costs the asker's budget again.
pub const failed_message = "The engine could not answer that one. Try again."

pub const rate_limited_code = "rate_limited"

pub const engine_down_code = "engine_down"

pub const dances_code = "dances"

/// How long a full line asks a player to wait: about one ask's worth.
const busy_retry_s = 60

const hour_s = 3600

const day_s = 86_400

/// "6-4 cannot be played from here": a roll that plays nothing, said before
/// any engine is asked.
pub fn dances_message(roll: #(Int, Int)) -> String {
  int.to_string(roll.0)
  <> "-"
  <> int.to_string(roll.1)
  <> " cannot be played from here"
}

// The sentences for Elixir, which cannot read a Gleam constant (they are
// inlined): the asker writes them on the jobs it fails.

pub fn engine_down_sentence() -> String {
  engine_down_message
}

pub fn failed_sentence() -> String {
  failed_message
}

/// The engine read the position and refused it (a 4xx): asking again will
/// not help, so the player is pointed back at the board.
pub const rejected_message = "The engine could not read this position. Check the board and try another."

pub fn rejected_sentence() -> String {
  rejected_message
}

// ---------- POST /papi/analysis ----------

/// What a POST comes to before anything is handed to the asker.
pub type Prepared {
  /// A complete row holds this question already: the answer, free.
  Cached(key: String, keyed: Keyed)
  /// The asker has this key in hand: the ask joins it, free.
  Joining(key: String)
  /// A new key, budget reserved: put it to the engine.
  ToAsk(ask: Ask)
}

/// Read and check the setup, find its key, and decide what asking it costs.
/// In order: a position that cannot be asked is refused with the setup's
/// own sentence (a roll that plays nothing is a 409 `dances`); a key with a
/// complete row is `Cached`; a key the asker already holds is `Joining`;
/// the asker asleep or full is a 503 or a 429; and then, and only then,
/// one ask is reserved from every bucket (`buckets`) -- refused, a 429
/// that says how long.
pub fn prepare(
  ctx: Ctx,
  session: Session,
  body_json: String,
) -> Result(Prepared, ApiError) {
  use s <- result.try(
    json.parse(body_json, setup.decoder())
    |> result.replace_error(error.validation_failed(not_a_position_message)),
  )
  use turn <- result.try(setup.turn(s) |> result.map_error(refusal(s, _)))
  let question = setup.question(s)
  let key = puzzles.key(question)
  case ctx.puzzles.by_key(key) {
    Some(keyed) if keyed.complete -> Ok(Cached(key, keyed))
    _ ->
      case ctx.analysis.asking(key) {
        Asked -> Ok(Joining(key))
        Down(seconds) -> Error(engine_down(seconds))
        Full -> Error(busy())
        Free -> {
          use charged <- result.try(reserve(ctx, session))
          Ok(
            ToAsk(Ask(
              key: key,
              ids: puzzles.ids(question),
              kind: puzzles.kind_name(question.kind),
              question_json: json.to_string(puzzles.question_json(question)),
              request_body: request(question, turn),
              buckets: charged,
            )),
          )
        }
      }
  }
}

/// The engine request for one set-up turn: the turn as the review's own
/// requests write one, at the engine's default depth, with every legal
/// play's result and the top five -- and no luck, which `store` never reads
/// and which would cost the engine a cube evaluation on every ask.
fn request(question: Question, turn: analysis.Turn) -> String {
  json.to_string(analysis.position_request(turn, 1, question.jacoby))
}

fn refusal(s: Setup, message: String) -> ApiError {
  case s.ask, message == setup.dances_message {
    setup.Move(roll), True -> error.Conflict(dances_code, dances_message(roll))
    _, _ -> error.validation_failed(message)
  }
}

/// The whole POST: `#(status, body)`. 200 with the answer when the key is
/// stored complete; 202 `pending` when it was handed to the asker or joins
/// a job already there.
pub fn ask_json(
  ctx: Ctx,
  session: Session,
  body_json: String,
) -> Result(#(Int, String), ApiError) {
  use prepared <- result.try(prepare(ctx, session, body_json))
  case prepared {
    Cached(key, keyed) ->
      done_body(ctx, key, keyed) |> result.map(fn(b) { #(200, b) })
    Joining(key) -> Ok(#(202, pending_body(key)))
    ToAsk(ask) ->
      // Charged, and not taken: the ask never reaches the engine, so the
      // budget it reserved is handed back.
      case ctx.analysis.submit(ask) {
        Asked | Free -> Ok(#(202, pending_body(ask.key)))
        Full -> {
          ctx.analysis.release_ask(ask.buckets)
          Error(busy())
        }
        Down(seconds) -> {
          ctx.analysis.release_ask(ask.buckets)
          Error(engine_down(seconds))
        }
      }
  }
}

fn pending_body(key: String) -> String {
  envelope.ok([
    #("status", json.string("pending")),
    #("key", json.string(key)),
  ])
}

fn done_body(ctx: Ctx, key: String, keyed: Keyed) -> Result(String, ApiError) {
  use puzzle <- result.try(puzzle_page.puzzle_object(ctx, keyed.stored))
  done_json(key, puzzle, keyed)
}

/// The same `done` answer with the puzzle's tree worked out fresh, for a
/// caller with no capabilities (the fixture task): byte for byte what a
/// page receives.
pub fn done_fixture(key: String, keyed: Keyed) -> Result(String, ApiError) {
  use puzzle <- result.try(puzzle_page.puzzle_object_fresh(keyed.stored))
  done_json(key, puzzle, keyed)
}

fn done_json(
  key: String,
  puzzle: json.Json,
  keyed: Keyed,
) -> Result(String, ApiError) {
  use reveal <- result.try(puzzle_page.reveal_json(
    keyed.stored,
    keyed.evaluated_by_json,
  ))
  Ok(
    envelope.ok([
      #("status", json.string("done")),
      #("key", json.string(key)),
      #("puzzle", puzzle),
      #("reveal", reveal),
    ]),
  )
}

// ---------- The budgets ----------

/// The buckets one ask is charged to: the caller's own (an account's when
/// signed in, else the browser's guest id), an hour and a day, and
/// everybody's day. A request with no guest cookie at all shares one guest
/// allowance with every other such request.
pub fn buckets(budget: AskBudget, session: Session) -> List(LimitBucket) {
  let #(who, hour, day) = case session.user_id, session.guest_id {
    Some(user_id), _ -> #(
      "analysis:user:" <> user_id,
      budget.user_hour,
      budget.user_day,
    )
    None, Some(guest_id) -> #(
      "analysis:guest:" <> guest_id,
      budget.guest_hour,
      budget.guest_day,
    )
    None, None -> #("analysis:guest:none", budget.guest_hour, budget.guest_day)
  }
  [
    LimitBucket(key: who <> ":hour", limit: hour, window_s: hour_s),
    LimitBucket(key: who <> ":day", limit: day, window_s: day_s),
    LimitBucket(
      key: "analysis:global:day",
      limit: budget.global_day,
      window_s: day_s,
    ),
  ]
}

/// Reserve one ask, and say which buckets it was charged to, so an ask that
/// never reaches the engine can be handed back.
fn reserve(ctx: Ctx, session: Session) -> Result(List(LimitBucket), ApiError) {
  let budget = ctx.analysis.ask_budget()
  let charged = buckets(budget, session)
  ctx.analysis.allow_ask(charged)
  |> result.map_error(limited(budget, _))
  |> result.replace(charged)
}

/// The key the limiter names when it could not be asked at all: it fails
/// closed for asks (the engine is what it guards), and the player is told
/// to wait a moment.
pub const limiter_unavailable_key = "analysis:limiter"

/// The sentence for a spent budget: whose, how many, and how long.
pub fn limited(budget: AskBudget, refused: Refused) -> ApiError {
  use <- bool.guard(
    refused.key == limiter_unavailable_key,
    error.Limited(rate_limited_code, busy_message, refused.retry_after_s),
  )
  let wait = duration(refused.retry_after_s)
  let key = refused.key
  let hourly = string.ends_with(key, ":hour")
  let per = case hourly {
    True -> " positions an hour."
    False -> " positions a day."
  }
  let message = case
    string.starts_with(key, "analysis:global"),
    string.starts_with(key, "analysis:user:")
  {
    True, _ ->
      "The engine has analyzed all it can today. Try again in " <> wait <> "."
    False, True ->
      "You can analyze "
      <> int.to_string(case hourly {
        True -> budget.user_hour
        False -> budget.user_day
      })
      <> per
      <> " Try again in "
      <> wait
      <> "."
    False, False ->
      "Guests can analyze "
      <> int.to_string(case hourly {
        True -> budget.guest_hour
        False -> budget.guest_day
      })
      <> per
      <> " Sign in for more, or try again in "
      <> wait
      <> "."
  }
  error.Limited(rate_limited_code, message, refused.retry_after_s)
}

/// A wait in words, rounded up: "a minute", "14 minutes", "an hour", "5
/// hours".
pub fn duration(seconds: Int) -> String {
  let minutes = { int.max(seconds, 1) + 59 } / 60
  case minutes {
    1 -> "a minute"
    m if m < 60 -> int.to_string(m) <> " minutes"
    m ->
      case { m + 59 } / 60 {
        1 -> "an hour"
        h -> int.to_string(h) <> " hours"
      }
  }
}

fn busy() -> ApiError {
  error.Limited(rate_limited_code, busy_message, busy_retry_s)
}

fn engine_down(seconds: Int) -> ApiError {
  error.Unavailable(engine_down_code, engine_down_message, int.max(seconds, 1))
}

// ---------- GET /papi/analysis/:key ----------

/// Where an ask stands. A complete row for the key is `done` whatever the
/// asker remembers; otherwise the asker's own word (`pending`, or `failed`
/// with the sentence); a key the asker has never seen and no row answers
/// is not found.
pub fn status_json(
  ctx: Ctx,
  key: String,
  job: Option(Job),
) -> Result(String, ApiError) {
  case ctx.puzzles.by_key(key), job {
    Some(keyed), _ if keyed.complete -> done_body(ctx, key, keyed)
    _, Some(JobPending) ->
      Ok(envelope.ok([#("status", json.string("pending"))]))
    _, Some(JobFailed(message)) -> Ok(failed_body(message))
    // Written and then gone, or written incomplete: neither should happen,
    // and either is a failure the player can retry.
    _, Some(JobDone(_)) -> Ok(failed_body(failed_message))
    _, None -> Error(error.NotFound(puzzle_page.not_found_message))
  }
}

fn failed_body(message: String) -> String {
  envelope.ok([
    #("status", json.string("failed")),
    #("message", json.string(message)),
  ])
}

// ---------- POST /papi/analysis/moves ----------

/// A cube question has no checkers to move.
pub const no_moves_message = "Only a roll has moves to play"

pub const moves_limited_message = "That is a lot of moves at once. Try again in a minute."

/// How many move trees one caller may ask for in a minute. A step of a
/// line is one; a turn too big to send whole is one more per checker.
pub const moves_per_minute = 120

/// Every caller's together, a minute: a guard against a loop, far above
/// what the site's players could press.
pub const moves_global_per_minute = 3000

const minute_s = 60

/// Every legal way to play a set-up position's roll, for the analysis
/// board's line (analysis-play-it-out): the puzzle page's own tree
/// (`puzzles/tree`, `handlers/puzzles.tree_of`), worked out on the server
/// from the setup, mover-relative as a puzzle's is. **Never the engine**:
/// it is move generation in Gleam, and the position need not have been
/// analyzed. The body is `{setup, node}`: with no node, the whole turn (or
/// its root, `lazy`, where it is too big to send); with a node, one level
/// of it, exactly as `GET /papi/puzzles/:id/tree?node=` serves one.
///
/// A position `check` refuses, or one that asks the cube, is a 422 with its
/// sentence. A roll that plays nothing is not refused: its root has no
/// children, which is the turn. The tree is kept under the question's key
/// (`setup:<key>`), so a level request is a lookup. Charged to the caller
/// (`moves_buckets`), because a turn too big to send whole is worked out in
/// full once, which is the only work here worth bounding.
pub fn moves_json(
  ctx: Ctx,
  session: Session,
  body_json: String,
) -> Result(String, ApiError) {
  let reader = {
    use s <- decode.field("setup", setup.decoder())
    use node <- decode.optional_field(
      "node",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(s, node))
  }
  use #(s, node) <- result.try(
    json.parse(body_json, reader)
    |> result.replace_error(error.validation_failed(not_a_position_message)),
  )
  use s <- result.try(
    setup.check(s) |> result.map_error(error.validation_failed),
  )
  use <- bool.guard(
    case s.ask {
      setup.Move(_) -> False
      _ -> True
    },
    Error(error.validation_failed(no_moves_message)),
  )
  use _ <- result.try(
    ctx.analysis.allow_ask(moves_buckets(session))
    |> result.map_error(fn(refused: Refused) {
      error.Limited(
        rate_limited_code,
        moves_limited_message,
        int.max(refused.retry_after_s, 1),
      )
    }),
  )
  let question = setup.question(s)
  let id = "setup:" <> puzzles.key(question)
  case node {
    None | Some("") ->
      Ok(
        envelope.ok([
          #("tree", puzzle_page.tree_of(ctx, id, question)),
        ]),
      )
    Some(node) -> puzzle_page.level_json(ctx, id, question, node)
  }
}

/// The buckets one moves request is charged to: the caller's minute (an
/// account's when signed in, else the browser's) and everybody's.
pub fn moves_buckets(session: Session) -> List(LimitBucket) {
  let who = case session.user_id, session.guest_id {
    Some(user_id), _ -> "moves:user:" <> user_id
    None, Some(guest_id) -> "moves:guest:" <> guest_id
    None, None -> "moves:guest:none"
  }
  [
    LimitBucket(
      key: who <> ":minute",
      limit: moves_per_minute,
      window_s: minute_s,
    ),
    LimitBucket(
      key: "moves:global:minute",
      limit: moves_global_per_minute,
      window_s: minute_s,
    ),
  ]
}

// ---------- The engine's answer, kept ----------

/// The engine answered one ask: read it, decide whether it can be trusted,
/// and write it as a puzzle. `Ok(puzzle id)`, or `Error(why)` with nothing
/// written. A move answer must hold every legal play and a board on every
/// candidate (`practice/openings.answer`, the sets' own rule); a cube
/// answer must carry the chances it was judged on. Either way the answer
/// is complete, so the row is never asked about again.
pub fn store(
  ctx: Ctx,
  ask: Ask,
  response_body: String,
) -> Result(String, String) {
  use review <- result.try(report.parse(response_body))
  use graded <- result.try(
    list.first(review.turns)
    |> result.replace_error("the engine graded no turn"),
  )
  use question <- result.try(puzzles.question_from_json(ask.question_json))
  use answer <- result.try(case question.kind {
    puzzles.Move -> openings.answer(graded)
    _ ->
      case graded.cube {
        Some(cube) ->
          case extract.cube_answer(cube) {
            puzzles.CubeAnswer(probs: Some(_), ..) as answer -> Ok(answer)
            _ -> Error("the engine sent the cube without its chances")
          }
        None -> Error("the engine graded no cube")
      }
  })
  use id <- result.try(ctx.puzzles.store_one(
    openings.new_puzzle(question, answer, review.levels),
    origin,
  ))
  ctx.puzzles.pictures_one(id)
  Ok(id)
}
