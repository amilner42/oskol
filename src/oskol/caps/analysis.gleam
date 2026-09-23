//// Post-game analysis capabilities: the persisted log a review is built
//// from, the stored reviews, the queue that runs them, and the HTTP call
//// to the analysis engine. Built for real in lib/oskol/gleam/caps/analysis.ex
//// -- that file and this one must agree on constructor tags and field order.

import gleam/option.{type Option}

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
    /// The clock preset id.
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

/// Where a page of graded games stopped, so the next one carries on from
/// exactly there: the moment the engine's answer was stored, and the game
/// it was for. The two ids break the tie when several answers land in the
/// same millisecond, which is what a finished match does.
pub type Cursor {
  Cursor(ended_at_ms: Int, game_number: Int, game_id: String)
}

/// One graded game of one account's, as the home reads it: which game it
/// was, which seat of it is theirs, who was across the board, how it ended
/// for them, and the engine's answer projected down to the seats' totals.
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
    /// The graded games of one **account**, newest answer first: (user id,
    /// how many, where the previous page stopped). One query over the
    /// review rows joined to the seats an account owns, so the home reads
    /// a player's whole form without waking a room or touching a log.
    ///
    /// The account is the caller's own, never a parameter a client chose:
    /// the cursor only says where to carry on, and the rows it can reach
    /// are the same ones either way.
    graded_for: fn(String, Int, Option(Cursor)) -> List(GradedGame),
  )
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
    graded_for: fn(_, _, _) { panic as "stub analysis.graded_for" },
  )
}
