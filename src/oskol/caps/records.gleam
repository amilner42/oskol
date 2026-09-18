//// A room's stored record: what a finished game left behind, written once
//// when that game ends and read back instead of replaying the action log.
//// Built for real in lib/oskol/gleam/caps/records.ex -- that file and this
//// one must agree on constructor tags and field order.

import gleam/option.{type Option}

/// What started a room, without its log: enough to build the head of a
/// record (who played, the match length, the opening position) by starting
/// the game and asking nobody to play it.
pub type Setup {
  Setup(
    slug: String,
    format: String,
    /// The clock preset id.
    clock: String,
    seed: Int,
    /// #(player_id, display name, guest id), in seat order. The guest id is
    /// "" for a seat no guest was recorded against.
    seats: List(#(String, String, String)),
    /// The room is over: every game it will ever have is played. A room
    /// that is not over yet may still have nothing stored simply because
    /// nothing has finished, which is not a reason to go and look.
    finished: Bool,
    /// How long the action log is now, and how long it was when this
    /// room's records were last written. Rows made from a shorter log are
    /// missing whatever was played after it: a match whose rows were
    /// written when its first game ended has only that game in them.
    log_length: Int,
    records_through: Int,
  )
}

/// One `game_records` row: a finished game's record entries, as JSON text.
pub type StoredRecord {
  StoredRecord(game_number: Int, entries_json: String)
}

pub type RecordsCaps {
  RecordsCaps(
    /// What started the room, or None when no started game has this code.
    setup: fn(String) -> Option(Setup),
    /// Every stored record row of a room, by game number.
    stored: fn(String) -> List(StoredRecord),
    /// Write rows for a room's finished games: #(game_number, entries as
    /// JSON text). A game already stored is left exactly as it is -- a
    /// finished game never changes.
    save: fn(String, List(#(Int, String))) -> Nil,
  )
}

pub fn stub() -> RecordsCaps {
  RecordsCaps(
    setup: fn(_) { panic as "stub records.setup" },
    stored: fn(_) { panic as "stub records.stored" },
    save: fn(_, _) { panic as "stub records.save" },
  )
}
