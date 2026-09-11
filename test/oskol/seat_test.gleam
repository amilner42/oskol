import gleam/option.{None, Some}
import oskol/rooms/seat

pub fn an_empty_seat_just_comes_back_to_life_test() {
  assert seat.attach(None, "phone") == seat.Resumed
  assert seat.displaces_holder(seat.Resumed) == False
}

pub fn the_same_client_coming_back_is_a_reconnect_test() {
  // A reload, a route change, a duplicate join, a socket back from a phone
  // that went to sleep: all the same browser, all quiet.
  assert seat.attach(Some("phone"), "phone") == seat.Rejoined
  assert seat.displaces_holder(seat.Rejoined) == False
}

pub fn another_live_client_takes_the_seat_over_test() {
  // A second tab, another device, a seat reclaimed from the invite link.
  assert seat.attach(Some("phone"), "laptop") == seat.TakenOver
  assert seat.displaces_holder(seat.TakenOver)
}

pub fn a_client_is_whatever_the_host_calls_one_test() {
  // The rule compares identities and cares about nothing else about them.
  assert seat.attach(Some(#(1, 2)), #(1, 2)) == seat.Rejoined
  assert seat.attach(Some(#(1, 2)), #(1, 3)) == seat.TakenOver
}
