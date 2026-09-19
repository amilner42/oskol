import gleam/option.{None, Some}
import oskol/rooms/invite
import oskol/rooms/room.{Table}

pub fn no_room_asks_for_a_name_anyway_test() {
  assert invite.step(None) == invite.NoRoom
}

pub fn a_free_seat_offers_the_join_flow_test() {
  let table =
    Table(
      full: False,
      inviter: Some("Alice"),
      summary: "Single game",
      disconnected: [],
    )

  assert invite.step(Some(table)) == invite.Open(Some("Alice"), [])
}

pub fn a_free_seat_with_nobody_at_the_table_still_offers_it_test() {
  let table =
    Table(full: False, inviter: None, summary: "Single game", disconnected: [
      #("p1", "Alice", False),
    ])

  assert invite.step(Some(table))
    == invite.Open(None, [#("p1", "Alice", False)])
}

pub fn a_full_and_connected_table_offers_nothing_test() {
  let table =
    Table(
      full: True,
      inviter: Some("Alice"),
      summary: "Single game",
      disconnected: [],
    )

  assert invite.step(Some(table)) == invite.Full
}

pub fn a_full_table_with_someone_away_offers_their_seat_back_test() {
  let away = [#("p2", "Bob", False)]
  let table =
    Table(
      full: True,
      inviter: Some("Alice"),
      summary: "Single game",
      disconnected: away,
    )

  assert invite.step(Some(table)) == invite.Reclaim(away)
}

pub fn an_emptied_out_table_offers_both_seats_test() {
  let away = [#("p1", "Alice", False), #("p2", "Bob", False)]
  let table =
    Table(full: True, inviter: None, summary: "Single game", disconnected: away)

  assert invite.step(Some(table)) == invite.Reclaim(away)
}

// ---------- Owned seats ----------

pub fn a_seat_an_account_owns_is_offered_to_nobody_test() {
  let table =
    Table(full: True, inviter: None, summary: "Single game", disconnected: [
      #("p2", "Bob", True),
    ])

  // Not "away": there is nothing here for whoever has the code.
  assert invite.step(Some(table)) == invite.Owned
}

pub fn an_emptied_out_table_of_owned_seats_offers_nothing_test() {
  let table =
    Table(full: True, inviter: None, summary: "Single game", disconnected: [
      #("p1", "Alice", True),
      #("p2", "Bob", True),
    ])

  assert invite.step(Some(table)) == invite.Owned
}

pub fn only_the_unowned_away_seats_are_offered_back_test() {
  let table =
    Table(full: True, inviter: None, summary: "Single game", disconnected: [
      #("p1", "Alice", True),
      #("p2", "Bob", False),
    ])

  // One of the two is an account's: the other is still there to be taken,
  // and the owned one is not even named.
  assert invite.step(Some(table)) == invite.Reclaim([#("p2", "Bob", False)])
}

pub fn a_lobby_never_names_an_owned_seat_either_test() {
  let table =
    Table(full: False, inviter: None, summary: "Single game", disconnected: [
      #("p1", "Alice", True),
    ])

  assert invite.step(Some(table)) == invite.Open(None, [])
}

// ---------- The names the client knows ----------

pub fn every_step_has_a_name_test() {
  assert invite.state(invite.NoRoom) == "missing"
  assert invite.state(invite.Open(None, [])) == "open"
  assert invite.state(invite.Full) == "full"
  assert invite.state(invite.Reclaim([])) == "away"
  assert invite.state(invite.Owned) == "owned"
}
