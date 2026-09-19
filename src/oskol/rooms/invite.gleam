//// What a plain invite link offers. The decision the LiveView's
//// `route_invite/2` used to make, on the facts of the table alone:
////
////   * no room answers to the code -> there is nothing left to join.
////   * a seat is free -> the normal join flow.
////   * full, everyone connected -> nothing at all: no seat, no scene.
////   * full, someone away and their seat unowned -> offer it back (one
////     name, or a choice of both when the table emptied out).
////   * full, and every away seat belongs to an account -> say so and offer
////     nothing: an owned seat is its account's, and no code opens it.

import gleam/list
import gleam/option.{type Option, None, Some}
import oskol/rooms/room.{type Table}

pub type InviteStep {
  NoRoom
  Open(inviter: Option(String), disconnected: List(#(String, String, Bool)))
  Full
  Reclaim(disconnected: List(#(String, String, Bool)))
  /// Somebody is away, but every away seat is owned: there is nothing here
  /// for a visitor with the code.
  Owned
}

pub fn step(table: Option(Table)) -> InviteStep {
  case table {
    None -> NoRoom
    Some(table) ->
      case table.full, claimable(table.disconnected) {
        False, _ -> Open(table.inviter, claimable(table.disconnected))
        True, [] ->
          case table.disconnected {
            // Everyone is at the table.
            [] -> Full
            // Somebody is away, and their seat is an account's.
            _ -> Owned
          }
        True, away -> Reclaim(away)
      }
  }
}

/// The away seats an invite link may actually offer: the unowned ones. An
/// owned seat is never named to a visitor, so nothing can be typed at it.
pub fn claimable(
  disconnected: List(#(String, String, Bool)),
) -> List(#(String, String, Bool)) {
  list.filter(disconnected, fn(seat) { !seat.2 })
}

/// The name the client knows each step by.
pub fn state(step: InviteStep) -> String {
  case step {
    NoRoom -> "missing"
    Open(_, _) -> "open"
    Full -> "full"
    Reclaim(_) -> "away"
    Owned -> "owned"
  }
}
