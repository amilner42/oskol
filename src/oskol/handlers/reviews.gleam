//// Post-game reviews: backgammon games graded by the analysis engine.
////
////   GET /papi/games/:slug/rooms/:id/reviews?t=<seat token>
////     {ok, players, games: [{game_number, status, review}]}
////   POST /papi/games/:slug/rooms/:id/reviews/retry  {t, game_number}
////     the same, after a failed game is queued again (a seat only)
////
//// Every game of a room is reviewed on its own once it is over -- each
//// game of a match, and the last. The room asks for it when a game ends
//// (`game_ended`, off the room process, through the review queue); a game
//// finished before reviews existed is asked for the first time someone
//// requests it. `run` is the queue's one job: review what a room is owed.
//// Every decision is here; Elixir does the queueing, the storage and the
//// HTTP.

import backgammon/analysis
import gamekit/event.{type Event}
import gamekit/game.{Seat}
import gamekit/host
import gamekit/replay
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/analysis.{
  type GameLog, type Stored, Done, Failed, Pending, Stored,
} as caps
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/handlers/record
import oskol/reviews/report

/// The only game with an engine.
pub const slug = "backgammon"

/// Engine calls per game, the first included: a failure is retried at most
/// twice.
pub const max_attempts = 3

/// How long the queue waits before trying a room again, after `attempts`
/// calls for one of its games have failed.
pub fn backoff_ms(attempts: Int) -> Int {
  case attempts {
    1 -> 30_000
    _ -> 120_000
  }
}

// ---------- When to ask ----------

/// Did this step end a game worth reviewing? A backgammon game is won
/// (a game within a match, or the match), or the room is over (a clock
/// ran out). The room calls this with the events of every step it applies.
pub fn game_ended(game_slug: String, events: List(Event)) -> Bool {
  game_slug == slug
  && list.any(events, fn(e) {
    case e {
      event.Custom("game_won", _) -> True
      event.PhaseChanged("game_over") -> True
      _ -> False
    }
  })
}

// ---------- The queue's job ----------

/// Review every game of the room that is over and still owed one: never
/// reviewed, pending, or failed with attempts to spare. One engine call per
/// game, in order; the outcome of each is stored as it lands. Returns when
/// to try again, if something failed and may be retried.
pub fn run(ctx: Ctx, game_id: String) -> Option(Int) {
  case ctx.analysis.log(game_id) {
    Some(log) if log.slug == slug ->
      case games(log) {
        Ok(games) -> {
          let stored = ctx.analysis.stored(game_id)
          games
          |> list.filter(fn(g) { owed(g, stored) })
          |> list.filter_map(fn(g) { review_one(ctx, game_id, g, stored) })
          |> list.fold(None, fn(soonest, delay) {
            case soonest {
              Some(ms) -> Some(int.min(ms, delay))
              None -> Some(delay)
            }
          })
        }
        // The log does not replay: nothing to ask the engine about.
        Error(_) -> None
      }
    _ -> None
  }
}

/// A game still owed a review.
fn owed(g: analysis.GameTurns, stored: List(Stored)) -> Bool {
  g.finished
  && g.turns != []
  && case find(stored, g.number) {
    None -> True
    Some(Stored(status: Pending, ..)) -> True
    Some(Stored(status: Failed, attempts: attempts, ..)) ->
      attempts < max_attempts
    Some(Stored(status: Done, ..)) -> False
  }
}

/// Ask the engine about one game and store the answer. Error(Nil) when
/// there is nothing more to do; Ok(delay) when it failed and may be tried
/// again after `delay`.
fn review_one(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  stored: List(Stored),
) -> Result(Int, Nil) {
  let before = case find(stored, g.number) {
    Some(row) -> row.attempts
    None -> 0
  }
  let attempts = before + 1
  ctx.analysis.save(game_id, g.number, Pending, before, None, None)
  let body = json.to_string(analysis.request_json(g))
  let outcome =
    ctx.analysis.review(body)
    |> result.try(fn(response) {
      // Stored only once it reads: a done review always renders.
      report.parse(response) |> result.replace(response)
    })
  case outcome {
    Ok(response) -> {
      ctx.analysis.save(game_id, g.number, Done, attempts, Some(response), None)
      Error(Nil)
    }
    Error(reason) -> {
      ctx.analysis.save(game_id, g.number, Failed, attempts, None, Some(reason))
      case attempts < max_attempts {
        True -> Ok(backoff_ms(attempts))
        False -> Error(Nil)
      }
    }
  }
}

// ---------- GET /papi/games/:slug/rooms/:id/reviews ----------

/// Every game of the room, with its review when it has one. A game over
/// and not yet reviewed is queued and answers `pending`; the client asks
/// again.
///
/// Open to anyone who has the room: a review reads back what was already on
/// the board for both players and any spectator, and a replay does not ask
/// its reader who they are. Asking for one sets the engine working; trying
/// a failed one again (`retry_json`) still takes a seat, since that spends
/// engine time on demand. A room that is not there is the record's own
/// `not_found_message`.
///
/// Statuses: `done` (with `review`), `pending`, `failed` (the engine was
/// tried and gave up), `empty` (the game ended before anyone completed a
/// turn: nothing to grade) and `playing` (the game is not over yet).
pub fn reviews_json(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
  _token: String,
) -> Result(String, ApiError) {
  use _ <- result.try(record.room(ctx, game_slug, game_id))
  use log <- result.try(case game_slug == slug, ctx.analysis.log(game_id) {
    True, Some(log) if log.slug == slug -> Ok(log)
    _, _ -> Error(error.NotFound(record.not_found_message))
  })
  use games <- result.try(
    games(log) |> result.map_error(fn(reason) { error.Internal(reason) }),
  )
  let stored = ctx.analysis.stored(game_id)
  let seats = seats(log)
  let entries = list.map(games, fn(g) { entry(g, stored, seats) })
  case list.any(games, fn(g) { owed(g, stored) }) {
    True -> ctx.analysis.enqueue(game_id)
    False -> Nil
  }
  Ok(
    envelope.ok([
      #(
        "players",
        json.array(list.index_map(seats, fn(s, i) { #(s, i) }), fn(pair) {
          let #(seat, index) = pair
          json.object([
            #("seat", json.int(index)),
            #("player_id", json.string(seat.player_id)),
            #("name", json.string(seat.name)),
            #("color", json.string(seat.color)),
          ])
        }),
      ),
      #("games", json.array(entries, fn(e) { e })),
    ]),
  )
}

fn entry(
  g: analysis.GameTurns,
  stored: List(Stored),
  seats: List(report.Seat),
) -> Json {
  let #(status, review) = settled(g, stored, seats)
  json.object([
    #("game_number", json.int(g.number)),
    #("status", json.string(status)),
    #("turns", json.int(list.length(g.turns))),
    #("review", option.unwrap(review, json.null())),
  ])
}

/// What a game's review stands at, as the endpoint names it, and the review
/// when it has one that renders.
fn settled(
  g: analysis.GameTurns,
  stored: List(Stored),
  seats: List(report.Seat),
) -> #(String, Option(Json)) {
  case g.finished, g.turns, find(stored, g.number) {
    False, _, _ -> #("playing", None)
    True, [], _ -> #("empty", None)
    True, _, Some(Stored(status: Done, response_json: Some(body), ..)) ->
      case report.parse(body) |> result.try(report.to_json(_, g.turns, seats)) {
        Ok(review) -> #("done", Some(review))
        Error(_) -> #("failed", None)
      }
    True, _, Some(Stored(status: Failed, attempts: attempts, ..))
      if attempts >= max_attempts
    -> #("failed", None)
    True, _, _ -> #("pending", None)
  }
}

// ---------- POST /papi/games/:slug/rooms/:id/reviews/retry ----------

/// A player asks for a game whose review failed to be tried again: the
/// engine was down, or its answer did not fit the game. The game starts
/// over with a full set of attempts and the room is queued; any other game
/// (done, pending, still being played) is left as it is. Only a seat may
/// ask -- it costs engine time -- so the seat token is checked the way the
/// record's is. Answers what GET answers, the retried game now `pending`.
pub fn retry_json(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
  token: String,
  number: Int,
) -> Result(String, ApiError) {
  use _ <- result.try(record.seat(ctx, game_slug, game_id, token))
  use log <- result.try(case game_slug == slug, ctx.analysis.log(game_id) {
    True, Some(log) if log.slug == slug -> Ok(log)
    _, _ -> Error(error.NotFound(record.not_found_message))
  })
  use games <- result.try(
    games(log) |> result.map_error(fn(reason) { error.Internal(reason) }),
  )
  let stored = ctx.analysis.stored(game_id)
  case list.find(games, fn(g) { g.number == number }) {
    Ok(g) ->
      case settled(g, stored, seats(log)) {
        #("failed", _) -> {
          ctx.analysis.save(game_id, number, Pending, 0, None, None)
          ctx.analysis.enqueue(game_id)
        }
        _ -> Nil
      }
    Error(_) -> Nil
  }
  reviews_json(ctx, game_slug, game_id, token)
}

// ---------- Shared ----------

fn find(stored: List(Stored), number: Int) -> Option(Stored) {
  list.find(stored, fn(row) { row.game_number == number })
  |> option.from_result
}

fn seats(log: GameLog) -> List(report.Seat) {
  list.index_map(log.seats, fn(seat, index) {
    report.Seat(seat.0, seat.1, case index {
      0 -> "white"
      _ -> "black"
    })
  })
}

/// Every game of a persisted room, replayed from its log.
pub fn games(log: GameLog) -> Result(List(analysis.GameTurns), String) {
  use entries <- result.try(list.try_map(log.entries, entry_of))
  analysis.games(replay.Log(
    format_id: log.format,
    selections: log.selections,
    seats: list.map(log.seats, fn(s) { Seat(id: s.0, name: s.1) }),
    seed: log.seed,
    control: host.clock_control(log.clock),
    entries: entries,
  ))
}

fn entry_of(e: caps.LogEntry) -> Result(replay.Entry, String) {
  case e.kind, e.player_id {
    "expire", _ -> Ok(replay.Expire(e.at_ms))
    "action", Some(player_id) ->
      json.parse(e.payload_json, decode.dynamic)
      |> result.map(fn(payload) { replay.Act(player_id, payload, e.at_ms) })
      |> result.replace_error("An action in the log is not JSON")
    other, _ -> Error("Unknown log entry: " <> other)
  }
}
