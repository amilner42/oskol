//// What it means for a connection to attach to a seat.
////
//// A seat is opened by its token and nothing else, so every attach is the
//// right player by definition. What is left to decide is what the seat
//// should make of the connection that was already there -- and the answer
//// turns on whether it belongs to the same client.
////
//// A client is one browser tab, for as long as it is open. It comes back
//// more often than anyone would guess -- moving between the client's own
//// routes, a duplicate join, a reload, a socket the phone brought back
//// from sleep -- and every one of those is the same person picking their
//// game back up, not a second player. Only a genuinely different client
//// (another tab, another device, a seat reclaimed from the invite link)
//// takes a seat over, and only then is there anything to tell the
//// connection that had it.

import gleam/option.{type Option, None, Some}

/// What attaching does to the seat.
pub type Attach {
  /// Nobody was holding it: the seat comes back to life, quietly.
  Resumed
  /// The same client again: this is a reconnect. Quietly too -- in
  /// particular, the connection it replaces is not told it lost anything,
  /// because the client it would be telling is the one arriving.
  Rejoined
  /// Another live client now holds the seat. The one that had it is told,
  /// and stops rather than lingering as a second live view of the seat.
  TakenOver
}

/// Decide an attach. `holder` is the client whose connection holds the seat
/// right now, and only while it is still alive; `arriving` is the client
/// attaching. Clients are compared by identity, whatever the host uses for
/// one.
pub fn attach(holder: Option(client), arriving: client) -> Attach {
  case holder {
    None -> Resumed
    Some(who) ->
      case who == arriving {
        True -> Rejoined
        False -> TakenOver
      }
  }
}

/// Does the connection being replaced need to be told it was replaced?
pub fn displaces_holder(attach: Attach) -> Bool {
  attach == TakenOver
}
