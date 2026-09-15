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

/// One `game_reviews` row.
pub type Stored {
  Stored(
    game_number: Int,
    status: Status,
    /// Engine calls made for this game so far.
    attempts: Int,
    /// The engine's response body, when done.
    response_json: Option(String),
  )
}

pub type AnalysisCaps {
  AnalysisCaps(
    /// The room's log, or None when no started game has this code.
    log: fn(String) -> Option(GameLog),
    /// Every stored review of a room.
    stored: fn(String) -> List(Stored),
    /// Upsert one review row: (game_id, game_number, status, attempts,
    /// response body, error text).
    save: fn(String, Int, Status, Int, Option(String), Option(String)) -> Nil,
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
    save: fn(_, _, _, _, _, _) { panic as "stub analysis.save" },
    enqueue: fn(_) { panic as "stub analysis.enqueue" },
    review: fn(_) { panic as "stub analysis.review" },
  )
}
