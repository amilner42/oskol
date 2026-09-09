import gleam/option.{None, Some}
import oskol/rooms/invite

pub fn no_room_asks_for_a_name_anyway_test() {
  assert invite.step(None) == invite.NoRoom
}

pub fn a_free_seat_offers_the_join_flow_test() {
  let table =
    invite.Table(full: False, inviter: Some("Alice"), disconnected: [])

  assert invite.step(Some(table)) == invite.Open(Some("Alice"), [])
}

pub fn a_free_seat_with_nobody_at_the_table_still_offers_it_test() {
  let table =
    invite.Table(full: False, inviter: None, disconnected: [#("p1", "Alice")])

  assert invite.step(Some(table)) == invite.Open(None, [#("p1", "Alice")])
}

pub fn a_full_and_connected_table_offers_nothing_test() {
  let table = invite.Table(full: True, inviter: Some("Alice"), disconnected: [])

  assert invite.step(Some(table)) == invite.Full
}

pub fn a_full_table_with_someone_away_offers_their_seat_back_test() {
  let away = [#("p2", "Bob")]
  let table =
    invite.Table(full: True, inviter: Some("Alice"), disconnected: away)

  assert invite.step(Some(table)) == invite.Reclaim(away)
}

pub fn an_emptied_out_table_offers_both_seats_test() {
  let away = [#("p1", "Alice"), #("p2", "Bob")]
  let table = invite.Table(full: True, inviter: None, disconnected: away)

  assert invite.step(Some(table)) == invite.Reclaim(away)
}
