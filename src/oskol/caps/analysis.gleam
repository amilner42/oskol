//// Post-game analysis capabilities: the persisted log a review is built
//// from, the stored reviews, the queue that runs them, and the HTTP call
//// to the analysis engine. Built for real in lib/oskol/gleam/caps/analysis.ex
//// -- that file and this one must agree on constructor tags and field order.

import gleam/option.{type Option}
import oskol/caps/auth.{type LimitBucket}
import oskol/rooms/seat.{type Seat}

/// One `game_actions` row. `payload_json` is the payload as JSON text (the
/// payload is whatever the client sent; it crosses as text, not Dynamic).
pub type LogEntry {
  LogEntry(
    /// "action" or "expire".
    kind: String,
    player_id: Option(String),
    payload_json: String,
    at_ms: Int,
  )
}

/// A persisted room that has started: its setup, seats and whole log.
pub type GameLog {
  GameLog(
    slug: String,
    format: String,
    /// The clock id (a preset, or a tier the format sizes).
    clock: String,
    seed: Int,
    /// #(player_id, display name), in seat order.
    seats: List(#(String, String)),
    entries: List(LogEntry),
    /// Completed-game work marker captured before reading the log. A later
    /// completion must not be marked settled by this older snapshot.
    record_generation: Int,
  )
}

pub type Status {
  /// Owed and not yet settled: queued, running, or waiting on a retry.
  Pending
  Done
  Failed
}

/// One `game_reviews` row. The two big columns -- the engine's answer and
/// the page rendered from it -- are hundreds of kilobytes each, so a row
/// says whether they are there and they are fetched only by what needs
/// them: `summaries` leaves `response_json` out, and the rendered page is
/// never in a row at all (`report`).
pub type Stored {
  Stored(
    game_number: Int,
    status: Status,
    /// Engine calls made for this game so far.
    attempts: Int,
    /// The engine's response body -- only from `stored`; `summaries`
    /// leaves it None whether there is one or not.
    response_json: Option(String),
    /// The engine has answered for this game.
    answered: Bool,
    /// That answer has been rendered into the page a read serves.
    rendered: Bool,
    /// How many turns this game had. Zero is a game that ended before
    /// anyone completed one: nothing to grade.
    turns: Int,
  )
}

/// What one `save` writes to a row. A row is always written whole, so a
/// retry (`Pending`, no report) clears what a previous answer left.
pub type Save {
  Save(
    status: Status,
    attempts: Int,
    response_json: Option(String),
    error: Option(String),
    report_json: Option(String),
    turns: Int,
  )
}

/// Where a page of graded **rooms** stopped, so the next one carries on
/// from exactly there: the moment the newest of that room's answers was
/// stored, and the room it was for. The id breaks the tie when two rooms'
/// last answers land in the same millisecond. A marker names a room and
/// never a game inside one, so a page can never stop in the middle of a
/// match.
pub type Cursor {
  Cursor(ended_at_ms: Int, room_id: String)
}

/// One graded game of one account's, as a **rating** counts it: which game
/// it was, which seat of it is theirs, and the engine's answer projected
/// down to the seats' totals. Nothing else -- a rating has no use for who
/// was across the board or how the game ended, and asking for those means
/// two more joins per game on the query that reads a whole career.
pub type RatedGame {
  RatedGame(
    game_id: String,
    game_number: Int,
    /// The account's seat, counting from 0.
    seat: Int,
    response_json: String,
    /// When the engine's answer was stored, in Unix milliseconds. The
    /// order the list comes in.
    ended_at_ms: Int,
  )
}

/// One graded game of one account's, as the recent list **shows** it:
/// which game it was, which seat of it is theirs, who was across the
/// board, how it ended for them, and the engine's answer projected down to
/// the seats' totals.
///
/// `response_json` is not the whole answer -- that is hundreds of kilobytes
/// a game -- but the same projection `ratings` takes: every seat's totals
/// plus the opening turn's cube verdict, which is all `report.player_totals`
/// needs to leave out the one decision nobody could have made.
///
/// The result comes from the game's record row (`won`, `points`, `kind`).
/// A graded game whose record has not been written yet has none, and the
/// page says nothing rather than guessing.
pub type GradedGame {
  GradedGame(
    game_id: String,
    game_number: Int,
    slug: String,
    /// The account's seat, counting from 0.
    seat: Int,
    /// That seat's player id, which is what the record's result line names.
    player_id: String,
    /// What the other seat plays under -- the account's username where an
    /// account owns it. None at a table that never had a second player.
    opponent: Option(String),
    /// The record's result line for this game, as it was written: who won,
    /// for how many points, and how ("single", "gammon", "backgammon",
    /// "resigned"). None where no record row has been written yet -- whose
    /// game it was is then something the page says nothing about rather
    /// than guessing.
    winner: Option(String),
    points: Int,
    kind: String,
    response_json: String,
    /// When the engine's answer was stored, in Unix milliseconds. The
    /// order the list comes in, and half of its cursor.
    ended_at_ms: Int,
  )
}

/// One graded game with the little the page needs to know about the **room**
/// it was played in. A match is the unit a player remembers, so the recent
/// list is one entry per room and this is a row of it: the room's format as
/// it was stored, whether the room is over, and who its row says won it.
///
/// The room's own fields repeat on every game of it -- one flat list, one
/// query -- and the handler folds the rows back into rooms.
pub type GradedRoomGame {
  GradedRoomGame(
    /// The format id out of the room's config ("match7", "unlimited",
    /// "single"), as stored. What that is in words is the handler's call.
    format: String,
    /// The room is finished: the match (or session, or single game) is over
    /// and the score below it is the final one.
    over: Bool,
    /// The player ids the room's row says won it -- empty while it is not
    /// over. This, and not the score added up from the graded games, is
    /// what says who won: a match whose last game the engine has not
    /// answered for yet would otherwise be reported to the wrong player.
    winners: List(String),
    game: GradedGame,
  )
}

/// One mistake an account's seat made, as what it **cost**: which puzzle it
/// became, its band (`very_bad`, `bad`, `doubtful`: the source row's own
/// grade, not the worst its puzzle was ever reached at), the game it was
/// made in, the seat that made it, and the equity it gave up -- the same
/// unit the engine's totals count a seat's error in, so the two can be
/// subtracted.
///
/// The seat rides along because the query finds these rows by asking which
/// seats *name* the account, and the holder rule (`rooms/seat.holder`), not
/// the query, says whose a seat is.
pub type MistakeCost {
  MistakeCost(
    puzzle_id: String,
    band: String,
    game_id: String,
    game_number: Int,
    seat: Seat,
    equity_lost: Float,
  )
}

// ---------- Asking about one position (the analysis board) ----------

/// How many positions may be asked of the engine, out of
/// `config :oskol, :analysis_budget`: a guest an hour and a day, an account
/// an hour and a day, and everybody together a day. The handler turns these
/// into buckets (`handlers/analysis.buckets`); the numbers are only numbers.
pub type AskBudget {
  AskBudget(
    guest_hour: Int,
    guest_day: Int,
    user_hour: Int,
    user_day: Int,
    global_day: Int,
    /// A per-roll grid is 0.2 s of engine and is answered in the request, so
    /// it is bounded by the minute as the move trees are, not by the day: one
    /// caller's minute, then everybody's. Appended last, so every field
    /// before keeps its place.
    rolls_minute: Int,
    rolls_global_minute: Int,
  )
}

/// A bucket that had no room: its key, and how long until it has.
pub type Refused {
  Refused(key: String, retry_after_s: Int)
}

/// Why a grid could not be had.
pub type RollsFailure {
  /// The engine read the board and would not answer it (a 4xx): asking again
  /// will not help, so the player is pointed back at the board.
  RollsRefused(detail: String)
  /// The engine itself is in trouble (a 5xx, a timeout, no connection). The
  /// circuit is open for this long, as it is after a failed ask, so a
  /// sleeping desktop is asked once and not once per keen player.
  RollsUnreachable(retry_after_s: Int)
}

/// One position to put to the engine, as the asker (`Oskol.Analysis.Asker`)
/// holds it: the puzzle it becomes (its key, candidate ids, kind and
/// question as stored) and the request body. The asker keys its work on
/// `key` and hands the whole thing back to `handlers/analysis.store` with
/// the engine's answer; it never looks inside.
pub type Ask {
  Ask(
    key: String,
    ids: List(String),
    kind: String,
    question_json: String,
    request_body: String,
    /// The budget this ask was charged to, so one that never reaches the
    /// engine (the line full, the circuit open) can be handed back.
    buckets: List(LimitBucket),
  )
}

/// Where the asker stands for one key, or after taking one.
pub type Asker {
  /// Nothing for this key, and room for one more.
  Free
  /// This key is queued or being asked now: a second ask joins it.
  Asked
  /// Every waiting place is taken.
  Full
  /// The engine failed a moment ago and is not asked again for this long.
  Down(retry_after_s: Int)
}

/// What the asker remembers of a key it was given (for ten minutes).
pub type Job {
  JobPending
  JobDone(puzzle_id: String)
  JobFailed(message: String)
}

pub type AnalysisCaps {
  AnalysisCaps(
    /// The room's log, or None when no started game has this code.
    log: fn(String) -> Option(GameLog),
    /// Every stored review of a room, with the engine's answers. The
    /// expensive read: only the write/backfill path uses it.
    stored: fn(String) -> List(Stored),
    /// Review metadata with only the response's player totals, no turns.
    ratings: fn(String) -> List(Stored),
    /// Every stored review of a room, without the bodies: what a read needs
    /// to say where each game's analysis stands.
    summaries: fn(String) -> List(Stored),
    /// One game's rendered analysis, as JSON text: the whole of what a
    /// per-game read sends, and the only place it is read from.
    report: fn(String, Int) -> Option(String),
    /// Upsert one review row: (game_id, game_number, what to write).
    save: fn(String, Int, Save) -> Nil,
    /// Fill in the count a row from before turn counts were stored lacks.
    /// This is deliberately not `save`: a queue worker may have changed the
    /// row since the reader took its snapshot, so only this one field moves.
    backfill_turns: fn(String, Int, Int) -> Nil,
    /// Ask for a room's owed reviews to be run, off the request. Idempotent:
    /// a room already queued, running or waiting on a retry is not queued
    /// twice.
    enqueue: fn(String) -> Nil,
    /// POST a review request body to the engine; the response body, or why
    /// there is none (a status, a timeout, a refused connection).
    review: fn(String) -> Result(String, String),
    /// One turn of one game's rendered analysis, as JSON text: (game_id,
    /// game_number, turn counting from 1). Projected in the database,
    /// because a report is hundreds of kilobytes and a caller that only
    /// wants to know which line of the record a turn sits on wants three
    /// integers out of it.
    report_turn: fn(String, Int, Int) -> Option(String),
    /// Charge a call against a row that keeps everything else it has:
    /// (game_id, game_number, attempts, error). What the backfill writes
    /// when re-asking a `done` game fails or its answer cannot be trusted,
    /// so the page keeps the answer it had and the row still says what
    /// happened and stops being asked once its tries are spent.
    charge: fn(String, Int, Int, Option(String)) -> Nil,
    /// Write a fresh answer over an old one and owe the game its puzzles
    /// again, in one transaction: (game_id, game_number, what to write).
    /// The row is written whole as `save` writes it; its extraction marker,
    /// error and attempts are cleared; and the sources written for turns
    /// skipped as `post_take_cube` are dropped, since the fresh answer
    /// grades those on the right cube. One write, so there is never a
    /// moment when the old answer is stored and the game is owed puzzles
    /// -- which the live sweep would take as an invitation to extract the
    /// old answer again. Only the backfill calls this.
    replace: fn(String, Int, Save) -> Nil,
    /// The grades already stored for a game's turns: (game_id, game_number,
    /// one request body per turn, in turn order). The answer is one entry
    /// per body, in the same order: the engine's reply where that exact
    /// question has been asked and answered already, None where it has not.
    ///
    /// The bodies are the key. A grade is found by the question it answers
    /// and by nothing else, so a turn can only ever be served a grade of
    /// itself, and a stale one cannot be dressed up as a fresh one.
    ///
    /// This cap is **not** on the request path: the context a handler is
    /// given holds `no_grades`, which panics. Nothing a player can reach
    /// may count, list or hint at the grades of a game still being played,
    /// and the only way to be sure of that is for the capability not to be
    /// there.
    grades: fn(String, Int, List(String)) -> List(Option(String)),
    /// Drop a game's stored grades: (game_id, game_number). Called once the
    /// game's whole answer is written, when they are spent.
    forget_grades: fn(String, Int) -> Nil,
    /// The graded games of one **account**, newest answer first: (user id,
    /// how many). One query over the review rows joined to the seats an
    /// account owns, so the home reads a player's whole form without waking
    /// a room or touching a log. This one counts in games, because a rating
    /// is made of games: it is what the form and the career number are read
    /// over, and it carries only what a rating is made of.
    ///
    /// The account is the caller's own, never a parameter a client chose.
    graded_for: fn(String, Int) -> List(RatedGame),
    /// The same rows counted in **rooms**: (user id, how many rooms, where
    /// the previous page stopped). Every graded game of the newest N rooms
    /// this account holds a seat in, the rooms newest answer first and each
    /// room's games together, newest game first inside.
    ///
    /// The recent list is one entry per room, so the limit is rooms and not
    /// games: ten rooms is ten lines whether they are ten single games or
    /// ten matches to seven, and no page boundary falls inside a match.
    graded_rooms_for: fn(String, Int, Option(Cursor)) -> List(GradedRoomGame),
    /// Every mistake the seats this account holds have made, in any game
    /// (user id). Rows only: the `puzzle_sources` an extraction wrote,
    /// never a skipped one, each with its seat so the caller can ask the
    /// holder rule. What `practice/cost` subtracts from the window
    /// `graded_for` reads. Last, so every field before it keeps its place.
    mistake_costs: fn(String) -> List(MistakeCost),
    /// The analysis board's budgets, from config. Appended after
    /// `mistake_costs`, so every field before keeps its place.
    ask_budget: fn() -> AskBudget,
    /// Where the asker stands for this puzzle key: a read of its table,
    /// never a wait.
    asking: fn(String) -> Asker,
    /// Hand one position to the asker. `Asked` when it is queued or joins
    /// the same key already in hand; `Full` or `Down` when it was not taken.
    submit: fn(Ask) -> Asker,
    /// Reserve one ask from every bucket at once, or from none of them:
    /// the limiter's atomic reservation (`Oskol.Limiter.allow/1`). The
    /// refusal names the bucket that had no room and how long until it has.
    allow_ask: fn(List(LimitBucket)) -> Result(Nil, Refused),
    /// Hand back one reserved ask from each bucket (`Oskol.Limiter.release/1`):
    /// an ask that was charged and never reached the engine.
    release_ask: fn(List(LimitBucket)) -> Nil,
    /// One game's review row with the engine's answer: (game_id,
    /// game_number). What sharing a replay step reads -- one game's answer,
    /// not a whole match's (`stored`). Appended after `release_ask`, so
    /// every field before keeps its place.
    stored_one: fn(String, Int) -> Option(Stored),
    /// The per-roll grids already stored for these engine request bodies, in
    /// the order they were asked about: the engine's answer where that exact
    /// board has been asked already, None where it has not. The bodies are
    /// the key, hashed over the bytes Gleam built, exactly as a turn's grade
    /// is keyed.
    ///
    /// A read and nothing else, because a grid already stored must cost no
    /// engine time **and no budget**, and only the handler can know that
    /// before it charges anybody.
    cached_rolls: fn(List(String)) -> List(Option(String)),
    /// Ask the engine for these grids, keep each answer under its own
    /// request's key, and hand them back in the order asked. One
    /// `POST /backgammon/rolls`, or a `/batch` of `rolls` items for more than
    /// one, answered inside the request: a grid is about 0.2 s, so there is
    /// no queue and nothing to poll. A stored grid is never rewritten.
    ask_rolls: fn(List(String)) -> Result(List(String), RollsFailure),
  )
}

/// The `grades` cap for every context that is not the review job's: it
/// panics. A handler that reads it is a loud 500 and not a quiet leak, which
/// is the point -- nothing a player can reach may know that a game still
/// being played has been graded at all.
pub fn no_grades() -> fn(String, Int, List(String)) -> List(Option(String)) {
  fn(_, _, _) { panic as "analysis.grades is the review job's alone" }
}

pub fn stub() -> AnalysisCaps {
  AnalysisCaps(
    log: fn(_) { panic as "stub analysis.log" },
    stored: fn(_) { panic as "stub analysis.stored" },
    ratings: fn(_) { panic as "stub analysis.ratings" },
    summaries: fn(_) { panic as "stub analysis.summaries" },
    report: fn(_, _) { panic as "stub analysis.report" },
    save: fn(_, _, _) { panic as "stub analysis.save" },
    backfill_turns: fn(_, _, _) { panic as "stub analysis.backfill_turns" },
    enqueue: fn(_) { panic as "stub analysis.enqueue" },
    review: fn(_) { panic as "stub analysis.review" },
    report_turn: fn(_, _, _) { panic as "stub analysis.report_turn" },
    charge: fn(_, _, _, _) { panic as "stub analysis.charge" },
    replace: fn(_, _, _) { panic as "stub analysis.replace" },
    grades: no_grades(),
    forget_grades: fn(_, _) { panic as "stub analysis.forget_grades" },
    graded_for: fn(_, _) { panic as "stub analysis.graded_for" },
    graded_rooms_for: fn(_, _, _) { panic as "stub analysis.graded_rooms_for" },
    mistake_costs: fn(_) { panic as "stub analysis.mistake_costs" },
    ask_budget: fn() { panic as "stub analysis.ask_budget" },
    asking: fn(_) { panic as "stub analysis.asking" },
    submit: fn(_) { panic as "stub analysis.submit" },
    allow_ask: fn(_) { panic as "stub analysis.allow_ask" },
    release_ask: fn(_) { panic as "stub analysis.release_ask" },
    stored_one: fn(_, _) { panic as "stub analysis.stored_one" },
    cached_rolls: fn(_) { panic as "stub analysis.cached_rolls" },
    ask_rolls: fn(_) { panic as "stub analysis.ask_rolls" },
  )
}
