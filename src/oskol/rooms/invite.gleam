//// What a plain invite link offers. The decision the old
//// `LandingLive.route_invite/2` made, on the facts of the table alone:
////
////   * no room answers to the code -> ask for a name anyway (the code may
////     be typed, and joining will say if the game is gone).
////   * a seat is free -> the normal join flow.
////   * full, everyone connected -> nothing at all: no seat, no scene.
////   * full, someone away -> offer their seat back (one name, or a choice
////     of both when the table emptied out).

import gleam/option.{type Option}

/// The table, as much of it as a decision needs.
pub type Table {
  Table(
    full: Bool,
    /// The name of a player who is at the table right now, if any.
    inviter: Option(String),
    /// Seats whose player is away, as #(player_id, name) in seat order.
    disconnected: List(#(String, String)),
  )
}

pub type InviteStep {
  NoRoom
  Open(inviter: Option(String), disconnected: List(#(String, String)))
  Full
  Reclaim(disconnected: List(#(String, String)))
}

pub fn step(table: Option(Table)) -> InviteStep {
  case table {
    option.None -> NoRoom
    option.Some(table) ->
      case table.full, table.disconnected {
        False, _ -> Open(table.inviter, table.disconnected)
        True, [] -> Full
        True, away -> Reclaim(away)
      }
  }
}
