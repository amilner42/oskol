//// What a plain invite link offers. The decision the LiveView's
//// `route_invite/2` used to make, on the facts of the table alone:
////
////   * no room answers to the code -> there is nothing left to join.
////   * a seat is free -> the normal join flow.
////   * full, everyone connected -> nothing at all: no seat, no scene.
////   * full, someone away -> offer their seat back (one name, or a choice
////     of both when the table emptied out).

import gleam/option.{type Option, None, Some}
import oskol/rooms/room.{type Table}

pub type InviteStep {
  NoRoom
  Open(inviter: Option(String), disconnected: List(#(String, String)))
  Full
  Reclaim(disconnected: List(#(String, String)))
}

pub fn step(table: Option(Table)) -> InviteStep {
  case table {
    None -> NoRoom
    Some(table) ->
      case table.full, table.disconnected {
        False, _ -> Open(table.inviter, table.disconnected)
        True, [] -> Full
        True, away -> Reclaim(away)
      }
  }
}

/// The name the client knows each step by.
pub fn state(step: InviteStep) -> String {
  case step {
    NoRoom -> "missing"
    Open(_, _) -> "open"
    Full -> "full"
    Reclaim(_) -> "away"
  }
}
