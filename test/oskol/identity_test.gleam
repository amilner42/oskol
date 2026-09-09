import gleam/option.{None, Some}
import oskol/fakes
import oskol/guests/identity

pub fn a_minted_id_is_valid_test() {
  assert identity.valid_id(fakes.minted_id)
}

pub fn a_mangled_id_is_not_test() {
  assert !identity.valid_id("not!a!valid!guest!id!!")
  // Right shape, wrong length.
  assert !identity.valid_id("abcdefghijklmnopqrstu")
  assert !identity.valid_id("abcdefghijklmnopqrstuvw")
  assert !identity.valid_id("")
}

pub fn a_valid_cookie_is_kept_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(None)

  assert identity.for_request(ctx, Some(fakes.minted_id)) == fakes.minted_id
}

pub fn a_mangled_cookie_is_replaced_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(None)

  assert identity.for_request(ctx, Some("not!a!valid!guest!id"))
    == fakes.minted_id
}

pub fn no_cookie_mints_one_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(None)

  assert identity.for_request(ctx, None) == fakes.minted_id
}

pub fn a_guest_we_remember_prefills_their_name_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(Some("Renée"))

  assert identity.remembered_name(ctx, fakes.guest("g1")) == Some("Renée")
}

pub fn a_guest_we_do_not_remember_has_no_name_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(None)

  assert identity.remembered_name(ctx, fakes.guest("g1")) == None
}

// The stub caps panic, so this also proves no row is touched for a visitor
// with no guest id at all.
pub fn a_visitor_with_no_guest_id_is_never_looked_up_test() {
  assert identity.remembered_name(fakes.ctx(), fakes.no_guest()) == None
}

pub fn a_seat_taken_with_no_guest_id_saves_nothing_test() {
  assert identity.remember(fakes.ctx(), fakes.no_guest(), "Alice") == Nil
}

pub fn a_seat_taken_by_a_guest_is_remembered_test() {
  let ctx = fakes.ctx() |> fakes.with_guests(None)

  assert identity.remember(ctx, fakes.guest("g1"), "Alice") == Nil
}
