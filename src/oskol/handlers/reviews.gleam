//// Post-game reviews: backgammon games graded by the analysis engine.
////
////   GET /papi/games/:slug/rooms/:id/reviews
////     {ok, players, games: [{game_number, status, turns}]} -- the index
////   GET /papi/games/:slug/rooms/:id/reviews/:game_number
////     {ok, game_number, status, turns, review} -- one game's analysis
////   POST /papi/games/:slug/rooms/:id/reviews/retry  {game_number}
////     the index, after a failed game is queued again (a seat only)
////
//// Every game of a room is reviewed on its own once it is over -- each
//// game of a match, and the last. The room asks for it when a game ends
//// (`game_ended`, off the room process, through the review queue); `run`
//// is the queue's one job: review what a room is owed.
////
//// A finished game never changes, so the answer about it is written, not
//// rebuilt. Reading a review used to replay the room's whole action log
//// and render every graded turn again, which cost the server a match on
//// 2026-09-16. Now the two moments that already do the replay write what
//// they produced: the record of each game when a game ends, and the
//// rendered analysis when the engine's answer lands. A read is a SELECT
//// and nothing else. A room stored before that (every room finished
//// before this change) builds once on its first read and writes the rows,
//// so there is no data to migrate.
////
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
  type GameLog, type Stored, Done, Failed, Pending, Save, Stored,
} as caps
import oskol/caps/puzzles as puzzles_caps
import oskol/caps/records
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/raw
import oskol/core/session.{type Session}
import oskol/handlers/record
import oskol/practice/sync
import oskol/puzzles/extract
import oskol/reviews/report
import oskol/rooms/seat

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
///
/// The replay this needs also settles what a read will want: the record of
/// every finished game, and the rendering of any answer the engine had
/// already given. That is `settle`, and it runs first.
pub fn run(ctx: Ctx, game_id: String) -> Option(Int) {
  // The queue is the only caller that writes puzzles. A read may still
  // settle a room (rendering an answer it finds unrendered), but it never
  // extracts: that would put a write and an attempt budget behind a GET
  // anyone with the link can make, and race this job on the same game.
  case settle(ctx, game_id, Extracting) {
    None -> None
    Some(#(games, seats, _)) -> {
      let stored = ctx.analysis.stored(game_id)
      games
      |> list.filter(fn(g) { owed(g, stored) })
      |> list.filter_map(fn(g) { review_one(ctx, game_id, g, seats, stored) })
      |> list.fold(None, fn(soonest, delay) {
        case soonest {
          Some(ms) -> Some(int.min(ms, delay))
          None -> Some(delay)
        }
      })
    }
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

/// Ask the engine about one game and store the answer, rendered. Error(Nil)
/// when there is nothing more to do; Ok(delay) when it failed and may be
/// tried again after `delay`.
fn review_one(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  stored: List(Stored),
) -> Result(Int, Nil) {
  let before = case find(stored, g.number) {
    Some(row) -> row.attempts
    None -> 0
  }
  // A pending attempt belongs to the earlier worker. If its last allowed
  // request was lost to a crash, expose failure without buying a fourth
  // request. Only the queue does this, never a reader of a running job.
  case before >= max_attempts {
    True -> {
      ctx.analysis.save(
        game_id,
        g.number,
        Save(
          Failed,
          before,
          None,
          Some("Analysis worker stopped before storing its answer"),
          None,
          list.length(g.turns),
        ),
      )
      Error(Nil)
    }
    False -> attempt_review(ctx, game_id, g, seats, before + 1)
  }
}

fn attempt_review(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  attempts: Int,
) -> Result(Int, Nil) {
  let turns = list.length(g.turns)
  ctx.analysis.save(
    game_id,
    g.number,
    // Charge before IO so task crashes cannot reset the attempt budget.
    Save(Pending, attempts, None, None, None, turns),
  )
  let body = json.to_string(analysis.request_json(g))
  let outcome =
    ctx.analysis.review(body)
    // Stored only once it renders: a done review is one the page can read
    // back without doing any of this again.
    |> result.try(fn(response) {
      rendered(response, g, seats)
      |> result.map(fn(both) { #(response, both.0, both.1) })
    })
  case outcome {
    Ok(#(response, review, page)) -> {
      ctx.analysis.save(
        game_id,
        g.number,
        Save(Done, attempts, Some(response), None, Some(page), turns),
      )
      // The only moment the board each decision was made *on* exists: the
      // stored answer keeps the boards moves lead to, never the one they
      // start from. Puzzles are written here or they are not written.
      write_puzzles(ctx, game_id, g, seats, review)
      Error(Nil)
    }
    Error(reason) -> {
      ctx.analysis.save(
        game_id,
        g.number,
        Save(Failed, attempts, None, Some(reason), None, turns),
      )
      case attempts < max_attempts {
        True -> Ok(backoff_ms(attempts))
        False -> Error(Nil)
      }
    }
  }
}

/// The engine's answer read once: the review itself, and the page rendered
/// from it, zipped against the turns the game really had. Both come out of
/// one parse because both callers want both -- the page to store, the
/// review to take puzzles from.
pub fn rendered(
  response: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
) -> Result(#(report.Review, String), String) {
  use review <- result.try(report.parse(response))
  use page <- result.try(report.to_json(review, g.turns, seats))
  Ok(#(review, json.to_string(page)))
}

/// Write down this game's puzzles: the mistakes the engine just found, the
/// question each one asks and whose mistake it was, in one transaction with
/// the marker that says this game is done with.
///
/// A failure here never fails a review, but it is always charged for and
/// always logged. Otherwise a game whose answer no longer lines up with its
/// turns -- an old row whose turn count moved under it -- would be owed
/// puzzles for ever, and the sweep would replay its whole log every minute
/// without saying a word.
fn write_puzzles(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  review: report.Review,
) -> Nil {
  case extracted(ctx, game_id, g, seats, review) {
    // The mistakes exist now, so the decks that own them can have them.
    // Here and not in the room: this is the review job's own task, which
    // is already off every hot path, and a deck that does not fill is
    // never a reason for a review to fail. A sync that does not happen at
    // all is the sweep's to find.
    Ok(_) -> sync.sync_game(ctx, game_id)
    Error(_) -> Nil
  }
}

/// This game's puzzles, decided and stored: what `store` wrote, or why
/// nothing was. Every path that gives up is charged and logged on the
/// row, so a game that cannot be extracted is never owed for ever.
pub fn extracted(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  review: report.Review,
) -> Result(puzzles_caps.Written, String) {
  case extract.from_review(g, seats, review) {
    Ok(#(puzzles, sources)) ->
      ctx.puzzles.store(game_id, g.number, puzzles, sources)
    Error(reason) -> {
      ctx.puzzles.failed(game_id, g.number, reason)
      Error(reason)
    }
  }
}

/// A room replayed for something other than a review: its games, its
/// seats and its stored reviews as the replay found them, with the record
/// rows and the rendered answers a read wants settled on the way and
/// nothing extracted. What the backfill starts from. None when the room
/// is not a started backgammon room, or its log does not replay.
pub fn replayed_room(
  ctx: Ctx,
  game_id: String,
) -> Option(#(List(analysis.GameTurns), List(report.Seat), List(Stored))) {
  settle(ctx, game_id, ReadOnly)
}

/// This game was owed puzzles and is not getting them. Charge the try and
/// log the reason; once the budget is spent the row is marked so the sweep
/// lets it go.
fn no_puzzles(
  ctx: Ctx,
  game_id: String,
  number: Int,
  reason: String,
  owed_puzzles: Bool,
) -> Nil {
  case owed_puzzles {
    True -> ctx.puzzles.failed(game_id, number, reason)
    False -> Nil
  }
}

// ---------- Writing down what a read will want ----------

/// Replay the room once and write down everything a read of it needs: the
/// record of each finished game, a terminal row for a game with nothing to
/// grade, and the rendered analysis of any answer the engine has already
/// given. Returns the room's games and seats for the caller that goes on
/// to ask the engine. None when the room is not a started backgammon room,
/// or its log does not replay.
///
/// Called by the queue when a game ends (the replay is the review's own),
/// and by a read that finds nothing stored -- the one time an old room
/// pays for itself.
/// Whether this settle may write puzzles. Only the queue's job may: a read
/// renders what it finds unrendered, as it always has, and leaves the
/// puzzles owed for the sweep.
type Extraction {
  Extracting
  ReadOnly
}

fn settle(
  ctx: Ctx,
  game_id: String,
  extraction: Extraction,
) -> Option(#(List(analysis.GameTurns), List(report.Seat), List(Stored))) {
  case ctx.analysis.log(game_id) {
    Some(log) if log.slug == slug ->
      case replayed(log) {
        Ok(#(games, record)) -> {
          let seats = seats(log)
          let finished = list.filter(games, fn(g) { g.finished })
          store_records(ctx, game_id, record, finished, log)
          let stored = ctx.analysis.stored(game_id)
          // Which games are graded but have no puzzles yet: a crash between
          // the two, or a room reviewed before puzzles existed. Reading it
          // costs one small query and spends no engine time -- and a read
          // does not ask at all, so it cannot touch the puzzle tables.
          let unextracted = case extraction {
            Extracting -> ctx.puzzles.unextracted(game_id)
            ReadOnly -> []
          }
          list.each(finished, fn(g) {
            store_review(ctx, game_id, g, seats, stored, unextracted)
          })
          Some(#(games, seats, stored))
        }
        // The log does not replay: nothing to ask the engine about.
        Error(_) -> None
      }
    _ -> None
  }
}

/// A finished game's row, brought up to what a read expects: a game with no
/// turns is settled for good as `empty`, an answer that has never been
/// rendered is rendered now (or given up on, if it is not this game's), and
/// a row from before turn counts were stored gets its count.
fn store_review(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  stored: List(Stored),
  unextracted: List(Int),
) -> Nil {
  let turns = list.length(g.turns)
  case find(stored, g.number), turns {
    // Nothing to grade, and nothing ever will be: settle it.
    None, 0 ->
      ctx.analysis.save(game_id, g.number, Save(Done, 0, None, None, None, 0))
    None, _ -> Nil
    Some(row), _ -> {
      let owed_puzzles = list.contains(unextracted, g.number)
      case row.status, row.response_json, row.rendered, owed_puzzles {
        // Never rendered, or rendered but never turned into puzzles:
        // either way the stored answer is read once and both are settled.
        Done, Some(response), False, _ | Done, Some(response), True, True ->
          settle_answer(
            ctx,
            game_id,
            g,
            seats,
            row,
            response,
            turns,
            owed_puzzles,
          )
        _, _, _, _ -> backfill_turns(ctx, game_id, g.number, row, turns)
      }
    }
  }
}

/// A stored engine answer, read once and settled: the page rendered if it
/// never was, the puzzles written if they never were.
///
/// Rendering is the expensive half and is wanted only once, so a row that
/// already has its page back is not put through it again merely because
/// its puzzles are owed.
fn settle_answer(
  ctx: Ctx,
  game_id: String,
  g: analysis.GameTurns,
  seats: List(report.Seat),
  row: Stored,
  response: String,
  turns: Int,
  owed_puzzles: Bool,
) -> Nil {
  case report.parse(response) {
    Error(reason) -> {
      unusable(ctx, game_id, g.number, row, reason, turns)
      // A rendered row keeps its answer, so nothing else would ever take
      // this game off the sweep's list. Charge for the try and say why.
      no_puzzles(ctx, game_id, g.number, reason, owed_puzzles)
    }
    Ok(review) -> {
      let usable = case row.rendered {
        True -> {
          backfill_turns(ctx, game_id, g.number, row, turns)
          True
        }
        False ->
          case report.to_json(review, g.turns, seats) {
            Ok(page) -> {
              ctx.analysis.save(
                game_id,
                g.number,
                Save(
                  Done,
                  row.attempts,
                  Some(response),
                  None,
                  Some(json.to_string(page)),
                  turns,
                ),
              )
              True
            }
            Error(reason) -> {
              unusable(ctx, game_id, g.number, row, reason, turns)
              no_puzzles(ctx, game_id, g.number, reason, owed_puzzles)
              False
            }
          }
      }
      // Only a game that is actually owed its puzzles: a report re-rendered
      // by a migration must not re-extract every done row, spend its
      // attempts and move its marker.
      case usable && owed_puzzles {
        True -> write_puzzles(ctx, game_id, g, seats, review)
        False -> Nil
      }
    }
  }
}

/// The answer is not this game's and never will be: say so once rather
/// than trying to render it on every read. A row whose page is already
/// stored keeps it -- whatever is wrong with the answer now, the page was
/// built from it once.
fn unusable(
  ctx: Ctx,
  game_id: String,
  number: Int,
  row: Stored,
  reason: String,
  turns: Int,
) -> Nil {
  case row.rendered {
    False ->
      ctx.analysis.save(
        game_id,
        number,
        Save(Failed, max_attempts, None, Some(reason), None, turns),
      )
    True -> backfill_turns(ctx, game_id, number, row, turns)
  }
}

/// A row from before turn counts were stored. Everything else about it
/// stays as it is, the rendered page included.
fn backfill_turns(
  ctx: Ctx,
  game_id: String,
  number: Int,
  row: Stored,
  turns: Int,
) -> Nil {
  case row.turns == turns {
    True -> Nil
    False -> ctx.analysis.backfill_turns(game_id, number, turns)
  }
}

/// The record rows a room's finished games are stored as, from the record
/// its last state holds. A game already stored is left alone by the write.
fn store_records(
  ctx: Ctx,
  game_id: String,
  record: Option(Json),
  finished: List(analysis.GameTurns),
  log: GameLog,
) -> Nil {
  case record {
    None -> Nil
    Some(record) -> {
      let numbers = list.map(finished, fn(g) { g.number })
      case
        split_record(record)
        |> list.filter(fn(row) { list.contains(numbers, row.0) })
      {
        [] -> Nil
        rows ->
          ctx.records.save(
            game_id,
            rows,
            list.length(log.entries),
            log.record_generation,
          )
      }
    }
  }
}

/// A record's `games` array as one #(number, entries as JSON text) per
/// game. The record is the game's own shape (`Game.record`); all this knows
/// about it is that it lists its games under `games`, each with a `number`
/// and its `entries`, which is what `GET /record` serves.
pub fn split_record(record: Json) -> List(#(Int, String)) {
  let row = {
    use number <- decode.field("number", decode.int)
    use entries <- decode.field("entries", decode.dynamic)
    decode.success(#(number, raw.text(entries)))
  }
  json.parse(json.to_string(record), decode.at(["games"], decode.list(row)))
  |> result.unwrap([])
}

// ---------- Reading ----------

/// Everything a read needs, from rows. A room with nothing written for it
/// replays once, writes its rows and reads them back; after that a read
/// touches the action log no more.
fn read(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
) -> Result(#(records.Setup, List(Int), List(Stored)), ApiError) {
  let not_found = error.NotFound(record.not_found_message)
  use setup <- result.try(case game_slug == slug, ctx.records.setup(game_id) {
    True, Some(setup) if setup.slug == slug -> Ok(setup)
    _, _ -> Error(not_found)
  })
  let numbers = ctx.records.numbers(game_id)
  let summaries = ctx.analysis.summaries(game_id)
  case stale(setup, numbers, summaries) {
    False -> Ok(#(setup, numbers, summaries))
    True -> {
      let _ = settle(ctx, game_id, ReadOnly)
      Ok(#(setup, ctx.records.numbers(game_id), ctx.analysis.summaries(game_id)))
    }
  }
}

/// Is anything a read wants missing? Nothing written at all (a room from
/// before this), or an engine answer that has never been rendered.
///
/// A room with nothing behind it yet -- still in its first game, no review
/// of any kind -- has nothing missing: its index is empty because there is
/// nothing to index, and going to look would replay its whole log on every
/// read, which is the thing this endpoint exists to stop doing.
fn stale(
  setup: records.Setup,
  numbers: List(Int),
  summaries: List(Stored),
) -> Bool {
  // Only completed-game work invalidates records. Staging and playing
  // ordinary turns must not turn index polling into full-match replay.
  setup.records_stale
  || { setup.finished && numbers == [] }
  || list.any(summaries, fn(row) {
    row.status == Done && row.answered && !row.rendered
  })
}

/// The index: which games this room has, and where each one's analysis
/// stands. Small and flat -- a few hundred bytes for a match -- so a page
/// can ask for it as often as it likes and fetch the analysis of the one
/// game it is showing.
///
/// Open to anyone who has the room: a review reads back what was already on
/// the board for both players and any spectator, and a replay does not ask
/// its reader who they are. Trying a failed one again (`retry_json`) still
/// takes a seat, since that spends engine time on demand.
///
/// Statuses: `done` (its analysis is stored), `pending` (owed, or on its
/// way), `failed` (the engine was tried and gave up), `empty` (the game
/// ended before anyone completed a turn: nothing to grade).
pub fn reviews_json(
  ctx: Ctx,
  _session: Session,
  game_slug: String,
  game_id: String,
) -> Result(String, ApiError) {
  use #(setup, rows, stored) <- result.try(read(ctx, game_slug, game_id))
  Ok(
    envelope.ok([
      #("players", players_json(setup)),
      #(
        "games",
        json.array(rows, fn(number) {
          let found = find(stored, number)
          json.object([
            #("game_number", json.int(number)),
            #("status", json.string(status_of(found))),
            #("turns", json.int(turns_of(found))),
          ])
        }),
      ),
    ]),
  )
}

/// One game's analysis, as the page renders it: the biggest thing this
/// server sends, and the only thing it sends that is worth its size. Read
/// straight out of the row it was written to when the engine answered.
pub fn review_json(
  ctx: Ctx,
  _session: Session,
  game_slug: String,
  game_id: String,
  number: Int,
) -> Result(String, ApiError) {
  use #(_setup, rows, stored) <- result.try(read(ctx, game_slug, game_id))
  // A game this room has no record of -- a number nobody has, or the one
  // still being played -- is nothing to read, and says so like any other
  // room that is not there.
  use _ <- result.try(case list.contains(rows, number) {
    True -> Ok(Nil)
    False -> Error(error.NotFound(record.not_found_message))
  })
  let found = find(stored, number)
  let status = status_of(found)
  Ok(
    envelope.ok([
      #("game_number", json.int(number)),
      #("status", json.string(status)),
      #("turns", json.int(turns_of(found))),
      // The one column worth its size, fetched only here and sent as it
      // was written: never taken apart, never built again.
      #("review", case status == "done", ctx.analysis.report(game_id, number) {
        True, Some(page) -> raw.json(page)
        _, _ -> json.null()
      }),
    ]),
  )
}

/// Where one game's analysis stands, from its row alone.
fn status_of(found: Option(Stored)) -> String {
  case found {
    // A game that ended and whose row the queue has not written yet.
    None -> "pending"
    Some(Stored(status: Done, turns: 0, ..)) -> "empty"
    Some(Stored(status: Done, rendered: True, ..)) -> "done"
    // Done with nothing a page can read: the answer was not this game's.
    Some(Stored(status: Done, ..)) -> "failed"
    Some(Stored(status: Failed, attempts: attempts, ..))
      if attempts >= max_attempts
    -> "failed"
    Some(_) -> "pending"
  }
}

fn turns_of(found: Option(Stored)) -> Int {
  case found {
    Some(row) -> row.turns
    None -> 0
  }
}

fn players_json(setup: records.Setup) -> Json {
  json.array(list.index_map(setup.seats, fn(s, i) { #(s, i) }), fn(pair) {
    let #(seat, index) = pair
    json.object([
      #("seat", json.int(index)),
      #("player_id", json.string(seat.0)),
      #("name", json.string(seat.1)),
      #("color", json.string(color_at(index))),
    ])
  })
}

fn color_at(index: Int) -> String {
  case index {
    0 -> "white"
    _ -> "black"
  }
}

// ---------- POST /papi/games/:slug/rooms/:id/reviews/retry ----------

/// A player asks for a game whose review failed to be tried again: the
/// engine was down, or its answer did not fit the game. The game starts
/// over with a full set of attempts and the room is queued; any other game
/// (done, pending, still being played) is left as it is. Only a seat may
/// ask -- it costs engine time -- so the asking guest has to hold one of
/// this room's seats. Answers what GET answers, the retried game now
/// `pending`.
pub fn retry_json(
  ctx: Ctx,
  session: Session,
  game_slug: String,
  game_id: String,
  number: Int,
) -> Result(String, ApiError) {
  use _ <- result.try(stored_seat(ctx, session, game_slug, game_id))
  use #(_setup, rows, stored) <- result.try(read(ctx, game_slug, game_id))
  let found = case list.contains(rows, number) {
    True -> find(stored, number)
    False -> None
  }
  case status_of(found) == "failed" && found != None {
    True -> {
      ctx.analysis.save(
        game_id,
        number,
        Save(Pending, 0, None, None, None, turns_of(found)),
      )
      ctx.analysis.enqueue(game_id)
    }
    False -> Nil
  }
  reviews_json(ctx, session, game_slug, game_id)
}

/// Authorize a retry from the persisted seats, not the room. A stopped room
/// is deliberately left stopped: rehydrating it would replay its whole log
/// merely to check an identity the `games` row already has.
fn stored_seat(
  ctx: Ctx,
  session: Session,
  game_slug: String,
  game_id: String,
) -> Result(Nil, ApiError) {
  let not_found = error.NotFound(record.not_found_message)
  use setup <- result.try(case game_slug == slug, ctx.records.setup(game_id) {
    True, Some(setup) if setup.slug == slug -> Ok(setup)
    _, _ -> Error(not_found)
  })
  let seats =
    list.map(setup.seats, fn(s) {
      seat.Seat(
        player_id: s.0,
        guest_id: some_unless_empty(s.2),
        user_id: some_unless_empty(s.3),
      )
    })
  case seat.held_by(seats, session) {
    Some(_) -> Ok(Nil)
    None -> Error(not_found)
  }
}

fn some_unless_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

// ---------- Shared ----------

fn find(stored: List(Stored), number: Int) -> Option(Stored) {
  list.find(stored, fn(row) { row.game_number == number })
  |> option.from_result
}

fn seats(log: GameLog) -> List(report.Seat) {
  list.index_map(log.seats, fn(seat, index) {
    report.Seat(seat.0, seat.1, color_at(index))
  })
}

/// Every game of a persisted room, replayed from its log.
pub fn games(log: GameLog) -> Result(List(analysis.GameTurns), String) {
  replayed(log) |> result.map(fn(both) { both.0 })
}

/// Every game of a persisted room and the record it left, from one replay.
fn replayed(
  log: GameLog,
) -> Result(#(List(analysis.GameTurns), Option(Json)), String) {
  use entries <- result.try(list.try_map(log.entries, entry_of))
  analysis.games_with_record(replay.Log(
    format_id: log.format,
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
