//// Which usernames a new account tries, in order.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/guests/username

pub fn the_guest_name_first_then_numbered_test() {
  let assert [first, second, third, ..] = username.candidates(Some("Arie"))
  assert #(first, second, third) == #("Arie", "Arie1", "Arie2")
}

pub fn no_guest_name_is_a_numbered_player_test() {
  let assert [first, second, ..] = username.candidates(None)
  assert #(first, second) == #("player1", "player2")
  // A bare "player" would read as nobody in particular.
  assert !list.contains(username.candidates(None), "player")
}

pub fn a_name_the_rules_refuse_falls_back_to_player_test() {
  let assert [first, ..] = username.candidates(Some("   "))
  assert first == "player1"
}

pub fn a_long_name_keeps_room_for_its_number_test() {
  let long = string.repeat("a", 24)
  username.candidates(Some(long))
  |> list.each(fn(candidate) {
    assert string.length(candidate) <= 24
  })
  let assert [_, numbered, ..] = username.candidates(Some(long))
  assert string.ends_with(numbered, "1")
}

pub fn past_the_numbered_names_the_account_id_breaks_the_tie_test() {
  let assert Ok(last) =
    username.candidates_for(None, "3f2a9c1e-0000-4000-8000-000000000000")
    |> list.last
  assert last == "player_3f2a9c"
}
