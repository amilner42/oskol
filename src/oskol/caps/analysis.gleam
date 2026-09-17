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
    selections: List(#(String, String)),
    /// The clock preset id.
    clock: String,
    seed: Int,
    /// #(player_id, display name), in seat order.
    seats: List(#(String, String)),
    entries: List(LogEntry),
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

pub type AnalysisCaps {
  AnalysisCaps(
    /// The room's log, or None when no started game has this code.
    log: fn(String) -> Option(GameLog),
    /// Every stored review of a room, with the engine's answers. The
    /// expensive read: only the write path and the match ratings use it.
    stored: fn(String) -> List(Stored),
    /// Every stored review of a room, without the bodies: what a read needs
    /// to say where each game's analysis stands.
    summaries: fn(String) -> List(Stored),
    /// One game's rendered analysis, as JSON text: the whole of what a
    /// per-game read sends, and the only place it is read from.
    report: fn(String, Int) -> Option(String),
    /// Upsert one review row: (game_id, game_number, what to write).
    save: fn(String, Int, Save) -> Nil,
    /// Ask for a room's owed reviews to be run, off the request. Idempotent:
    /// a room already queued, running or waiting on a retry is not queued
    /// twice.
    enqueue: fn(String) -> Nil,
    /// POST a review request body to the engine; the response body, or why
    /// there is none (a status, a timeout, a refused connection).
    review: fn(String) -> Result(String, String),
  )
}

pub fn stub() -> AnalysisCaps {
  AnalysisCaps(
    log: fn(_) { panic as "stub analysis.log" },
    stored: fn(_) { panic as "stub analysis.stored" },
    summaries: fn(_) { panic as "stub analysis.summaries" },
    report: fn(_, _) { panic as "stub analysis.report" },
    save: fn(_, _, _) { panic as "stub analysis.save" },
    enqueue: fn(_) { panic as "stub analysis.enqueue" },
    review: fn(_) { panic as "stub analysis.review" },
  )
}
