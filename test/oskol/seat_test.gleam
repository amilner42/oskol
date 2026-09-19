//// Who holds a seat. Every door into a seat — the game channel attaching,
//// a claim from the invite link, the record's "which way does the board
//// face", the home page's list — asks these two functions, so this is the
//// file that says what a browser may open.

import gleam/option.{None, Some}
import oskol/core/session.{type Session, Session}
import oskol/rooms/seat.{type Seat, Seat}

fn guest(id: String) -> Session {
  Session(guest_id: Some(id), user_id: None)
}

fn signed_in(id: String, user_id: String) -> Session {
  Session(guest_id: Some(id), user_id: Some(user_id))
}

fn unowned(guest_id: String) -> Seat {
  Seat(player_id: "p1", guest_id: Some(guest_id), user_id: None)
}

fn owned(guest_id: String, user_id: String) -> Seat {
  Seat(player_id: "p1", guest_id: Some(guest_id), user_id: Some(user_id))
}

// ---------- An unowned seat: the guest that took it, and nobody else ----------

pub fn an_unowned_seat_is_held_by_the_guest_that_took_it_test() {
  assert seat.holder(unowned("g1"), guest("g1"))
}

pub fn an_unowned_seat_is_not_held_by_another_guest_test() {
  assert !seat.holder(unowned("g1"), guest("g2"))
}

pub fn an_unowned_seat_is_not_held_by_a_visitor_with_no_guest_test() {
  assert !seat.holder(unowned("g1"), session.anonymous())
}

pub fn an_account_does_not_reach_a_seat_it_does_not_own_test() {
  // Signing in does not hand anyone somebody else's seat: only the guest
  // on an unowned seat matters, whoever the browser is signed in as.
  assert !seat.holder(unowned("g1"), signed_in("g2", "u1"))
  assert seat.holder(unowned("g1"), signed_in("g1", "u1"))
}

pub fn a_seat_nobody_took_is_nobodys_test() {
  let empty = Seat(player_id: "p1", guest_id: None, user_id: None)

  assert !seat.holder(empty, guest("g1"))
  assert !seat.holder(empty, session.anonymous())
  // A seeded room writes "" rather than nothing; it is the same seat.
  let blank = Seat(player_id: "p1", guest_id: Some(""), user_id: None)
  assert !seat.holder(blank, Session(guest_id: Some(""), user_id: None))
}

// ---------- An owned seat: the account, and the guest ignored ----------

pub fn an_owned_seat_is_held_by_its_account_test() {
  assert seat.holder(owned("g1", "u1"), signed_in("g1", "u1"))
}

pub fn an_owned_seat_opens_from_any_browser_signed_into_it_test() {
  // A second device: another guest entirely, the same account.
  assert seat.holder(owned("g1", "u1"), signed_in("g9", "u1"))
}

pub fn an_owned_seat_is_not_held_by_the_guest_on_it_test() {
  // The browser that played the seat and then logged out, or the next
  // person on a shared laptop: the guest on an owned seat is history.
  assert !seat.holder(owned("g1", "u1"), guest("g1"))
}

pub fn an_owned_seat_is_not_held_by_another_account_test() {
  assert !seat.holder(owned("g1", "u1"), signed_in("g1", "u2"))
}

pub fn an_owned_seat_is_not_held_by_a_visitor_with_no_account_test() {
  assert !seat.holder(owned("g1", "u1"), session.anonymous())
}

// ---------- Claiming ----------

pub fn an_unowned_seat_may_be_claimed_test() {
  assert seat.claimable(unowned("g1"))
  assert !seat.owned(unowned("g1"))
}

pub fn an_owned_seat_may_never_be_claimed_test() {
  assert !seat.claimable(owned("g1", "u1"))
  assert seat.owned(owned("g1", "u1"))
}

// ---------- The seat a caller holds at a table ----------

pub fn held_by_answers_in_seat_order_test() {
  let seats = [
    Seat(player_id: "p1", guest_id: Some("g1"), user_id: None),
    Seat(player_id: "p2", guest_id: Some("g2"), user_id: Some("u1")),
  ]

  assert seat.held_by(seats, guest("g1")) == Some("p1")
  assert seat.held_by(seats, signed_in("g9", "u1")) == Some("p2")
  // The guest on the owned seat holds nothing here any more.
  assert seat.held_by(seats, guest("g2")) == None
  assert seat.held_by(seats, guest("nobody")) == None
  assert seat.held_by([], guest("g1")) == None
}

pub fn a_browser_whose_account_owns_a_seat_holds_that_one_not_its_guests_test() {
  // One browser, two seats at one table, would be a table nobody could
  // play: the room refuses the second, and this is the rule it refuses by.
  let seats = [
    Seat(player_id: "p1", guest_id: Some("g1"), user_id: Some("u1")),
    Seat(player_id: "p2", guest_id: Some("g1"), user_id: None),
  ]

  assert seat.held_by(seats, signed_in("g1", "u1")) == Some("p1")
}
