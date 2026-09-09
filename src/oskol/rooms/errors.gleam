//// Every way a room can say no, and the sentence a player is shown for it.
////
//// The constructors are named so that each compiles to the atom the Elixir
//// room already returns (`GameFull` -> `:game_full`), which is what lets the
//// capability layer pass a reason straight through. `message` is the old
//// `LandingLive.format_error/1`, verbatim.

pub type RoomError {
  GameFull
  NameTaken
  InvalidName
  UnknownFormat
  UnknownClock
  UnknownSetting
  UnknownChoice
  GameAlreadyStarted
  SeatConnected
  InvalidToken
  PlayerNotFound
  GameNotStarted
  GameNotFinished
  NotEnoughPlayers
  UnknownGame
  NoFreeId
  /// Anything else the platform reported, already rendered as text.
  Other(reason: String)
}

pub fn message(error: RoomError) -> String {
  case error {
    GameFull -> "That game is full"
    NameTaken -> "That name is already taken"
    InvalidName -> "Invalid name"
    UnknownFormat -> "Unknown game mode"
    UnknownClock -> "Unknown time control"
    UnknownSetting -> "Unknown setting"
    UnknownChoice -> "Unknown choice"
    GameAlreadyStarted -> "That game already started"
    SeatConnected -> "That player is back at the table"
    InvalidToken -> "That link is no longer valid"
    PlayerNotFound -> "That player is not at this table"
    // The rest have no sentence of their own: they fall through to the
    // generic "Error: <reason>" the LiveView has always shown.
    GameNotStarted -> "Error: game_not_started"
    GameNotFinished -> "Error: game_not_finished"
    NotEnoughPlayers -> "Error: not_enough_players"
    UnknownGame -> "Error: unknown_game"
    NoFreeId -> "Error: no_free_id"
    Other(reason) -> "Error: " <> reason
  }
}
