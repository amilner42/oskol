//// Who holds a seat, and what it means for a connection to attach to it.
////
//// A seat is held by the guest who took it, or -- once an account has it --
//// by that account. `holder` is the one rule, and every door into a seat
//// asks it: the game channel attaching, a claim from the invite link, the
//// record's "which way does the board face", the home page's list of games
//// to pick back up. Elixir never compares an id itself.
////
//// The two arms are deliberately exclusive. An owned seat is the account's
//// and the guest on it is history: the browser that played it before signing
//// in, or the one that signed in and has since been rotated. Reading the
//// guest on an owned seat would let a logged-out tab, or the next person on
//// a shared laptop, walk straight back in. An unowned seat is exactly as it
//// always was: the guest cookie, and nothing else.
////
//// Once a connection is at the right seat, what is left to decide is what
//// the seat should make of the connection that was already there -- and the
//// answer turns on whether it belongs to the same client.
////
//// A client is one browser tab, for as long as it is open. It comes back
//// more often than anyone would guess -- moving between the client's own
//// routes, a duplicate join, a reload, a socket the phone brought back
//// from sleep -- and every one of those is the same person picking their
//// game back up, not a second player. Only a genuinely different client
//// (another tab, another device, the same guest on a second phone, a seat
//// reclaimed from the invite link)
//// takes a seat over, and only then is there anything to tell the
//// connection that had it.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/core/session.{type Session}

/// One seat, as the holder rule needs to see it: its player id, the guest
/// that took it, and the account that owns it if one does.
///
/// (The room's own `rooms/room.Seat` is a different thing -- a seat that was
/// just taken, on its way back to a caller. This one is a seat sitting at a
/// table being asked who may open it.)
pub type Seat {
  Seat(player_id: String, guest_id: Option(String), user_id: Option(String))
}

/// Does this session hold that seat?
///
///   * an **owned** seat (it has a `user_id`) is held by that account and
///     nobody else: the guest on it is ignored entirely, so a browser that
///     logged out, or a second person on the same laptop, holds nothing;
///   * an **unowned** seat is held by the guest that took it, which is how
///     every seat has always worked.
///
/// An empty id on either side holds nothing: a seat taken by tooling (no
/// guest at all) is nobody's until somebody claims it.
pub fn holder(seat: Seat, session: Session) -> Bool {
  case seat.user_id {
    Some(owner) -> same_secret(session.user_id, owner)
    None -> same_secret(session.guest_id, seat.guest_id |> option.unwrap(""))
  }
}

/// The seat this session holds at a table, if it holds one. Asked in seat
/// order, so the answer never depends on how the seats happen to be stored.
pub fn held_by(seats: List(Seat), session: Session) -> Option(String) {
  list.find(seats, holder(_, session))
  |> option.from_result
  |> option.map(fn(seat) { seat.player_id })
}

/// Is this seat owned by an account?
pub fn owned(seat: Seat) -> Bool {
  seat.user_id != None
}

/// May a seat whose player is away be taken back from the invite link?
///
/// Only an unowned one. An owned seat belongs to its account for good: the
/// invite page says so and offers nothing, and the room refuses the claim
/// even if something asks for it anyway.
pub fn claimable(seat: Seat) -> Bool {
  !owned(seat)
}

/// An id against an id, without stopping at the first character that
/// differs: these are credentials, and how long a comparison took is not
/// something a stranger should be able to read a seat out of. Only the
/// length is visible, and both are fixed-length ids.
fn same_secret(offered: Option(String), expected: String) -> Bool {
  case offered {
    None -> False
    Some(offered) ->
      case offered != "" && expected != "" {
        False -> False
        True -> {
          let a = string.to_utf_codepoints(offered)
          let b = string.to_utf_codepoints(expected)

          list.length(a) == list.length(b)
          && list.zip(a, b)
          |> list.fold(True, fn(same, pair) { same && pair.0 == pair.1 })
        }
      }
  }
}

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

/// What a sign-in does to one table's seats, and how many became the
/// account's. The one copy of the rule: the row (`Oskol.Persistence`) and a
/// live room's memory (`Oskol.Game.GameServer`) both call this.
///
///   * every seat the browser's old guest holds that no account owns moves
///     to its fresh guest id, because the old id opens nothing any more and
///     the browser must keep what it was playing;
///   * and becomes the account's, unless the account already owns a seat
///     at this table (one person playing both sides from two devices): one
///     account, one seat per table, and the other stays a guest seat;
///   * the opponent's seat, a seat some other account owns, and a seat with
///     no guest at all (tooling, rows from before guests) are untouched.
///
/// An empty id anywhere stamps nothing.
pub fn stamp(
  seats: List(Seat),
  old_guest: String,
  new_guest: String,
  user: String,
) -> #(List(Seat), Int) {
  case old_guest == "" || new_guest == "" || user == "" {
    True -> #(seats, 0)
    False -> {
      let owns_one_here =
        list.any(seats, fn(seat) { seat.user_id == Some(user) })
      let #(count, stamped) =
        list.map_fold(seats, 0, fn(count, seat) {
          case seat.guest_id == Some(old_guest) && seat.user_id == None {
            False -> #(count, seat)
            True ->
              case owns_one_here {
                True -> #(count, Seat(..seat, guest_id: Some(new_guest)))
                False -> #(
                  count + 1,
                  Seat(..seat, guest_id: Some(new_guest), user_id: Some(user)),
                )
              }
          }
        })
      #(stamped, count)
    }
  }
}

/// A seat list a room is about to write, against the one already on disk:
/// an owner never comes off a seat. Ownership is permanent (an owned seat
/// cannot be claimed), so a write that says a seat is unowned when the row
/// says it is owned is a room writing from memory that has not heard of the
/// sign-in yet, and the row's owner (and the guest id that came with it)
/// stands. This is what makes a sign-in safe against a room rewriting its
/// seats at the same moment, whatever order the two land in.
pub fn keep_owners(incoming: List(Seat), stored: List(Seat)) -> List(Seat) {
  list.map(incoming, fn(seat) {
    case seat.user_id {
      Some(_) -> seat
      None ->
        case list.find(stored, fn(s) { s.player_id == seat.player_id }) {
          Ok(Seat(user_id: Some(owner), guest_id: guest, ..)) ->
            Seat(..seat, guest_id: guest, user_id: Some(owner))
          _ -> seat
        }
    }
  })
}
