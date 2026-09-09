//// The room lifecycle handler, on stub capabilities: every branch of
//// minting a code, looking a room up, creating one and joining one.

import gleam/option.{None, Some}
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/fakes
import oskol/handlers/rooms
import oskol/rooms/errors
import oskol/rooms/room.{Seat, Seated, Setup}

const backgammon = "backgammon"

fn setup() -> room.Setup {
  Setup(format: "single", selections: [], clock: "none")
}

// ---------- Codes ----------

fn minting(
  ctx: Ctx,
  code: String,
  taken: Bool,
  spawn: Result(Nil, rooms_caps.SpawnError),
) -> Ctx {
  Ctx(
    ..ctx,
    ids: ids_caps.IdsCaps(game_code: fn() { code }),
    persistence: persistence_caps.PersistenceCaps(game_exists: fn(_) { taken }),
    rooms: rooms_caps.RoomsCaps(..ctx.rooms, spawn: fn(_, _) { spawn }),
  )
}

pub fn a_free_code_starts_a_room_test() {
  let ctx = minting(fakes.ctx(), "123456", False, Ok(Nil))

  assert rooms.create_room(ctx, backgammon, 50) == Ok("123456")
}

pub fn a_code_a_persisted_game_holds_is_skipped_test() {
  // Every code this generator offers is taken, so the attempts run out
  // rather than handing out a code a finished game still holds.
  let ctx = minting(fakes.ctx(), "123456", True, Ok(Nil))

  assert rooms.create_room(ctx, backgammon, 3) == Error(errors.NoFreeId)
}

pub fn a_collision_with_a_live_room_mints_again_test() {
  let ctx =
    minting(fakes.ctx(), "123456", False, Error(rooms_caps.AlreadyStarted))

  assert rooms.create_room(ctx, backgammon, 4) == Error(errors.NoFreeId)
}

pub fn no_attempts_left_gives_up_rather_than_looping_test() {
  assert rooms.create_room(fakes.ctx(), backgammon, 0) == Error(errors.NoFreeId)
}

pub fn a_room_that_will_not_start_reports_why_test() {
  let ctx =
    minting(
      fakes.ctx(),
      "123456",
      False,
      Error(rooms_caps.SpawnFailed(errors.UnknownGame)),
    )

  assert rooms.create_room(ctx, "checkers", 50) == Error(errors.UnknownGame)
}

// ---------- Lookup ----------

pub fn a_live_room_is_found_test() {
  let ctx = with_rooms(fakes.ctx(), find: Some(fakes.room()), resume: None)

  assert rooms.lookup(ctx, "123456") == Some(fakes.room())
}

pub fn a_room_with_no_process_is_rehydrated_test() {
  let ctx = with_rooms(fakes.ctx(), find: None, resume: Some(fakes.room()))

  assert rooms.lookup(ctx, "123456") == Some(fakes.room())
}

pub fn a_code_nothing_answers_to_is_not_found_test() {
  let ctx = with_rooms(fakes.ctx(), find: None, resume: None)

  assert rooms.lookup(ctx, "123456") == None
}

pub fn a_live_room_resolves_its_code_to_a_slug_test() {
  let ctx =
    with_rooms(fakes.ctx(), find: Some(fakes.room()), resume: None)
    |> slug_of(Some(backgammon))

  assert rooms.lookup_slug(ctx, "123456") == Some(backgammon)
}

// The slug capability panics here: a code with no room must never ask a
// room anything.
pub fn a_dead_code_resolves_to_nothing_test() {
  let ctx = with_rooms(fakes.ctx(), find: None, resume: None)

  assert rooms.lookup_slug(ctx, "123456") == None
}

fn with_rooms(
  ctx: Ctx,
  find find: option.Option(room.Room),
  resume resume: option.Option(room.Room),
) -> Ctx {
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      find: fn(_) { find },
      resume: fn(_) { resume },
    ),
  )
}

fn slug_of(ctx: Ctx, slug: option.Option(String)) -> Ctx {
  Ctx(..ctx, rooms: rooms_caps.RoomsCaps(..ctx.rooms, slug_of: fn(_) { slug }))
}

// ---------- Creating ----------

fn creating(
  ctx: Ctx,
  configure: Result(Nil, errors.RoomError),
  join: Result(room.Seat, errors.RoomError),
) -> Ctx {
  let ctx = minting(ctx, "123456", False, Ok(Nil))

  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      subscribe: fn(_) { Nil },
      configure: fn(_, _) { configure },
      join: fn(_, _, _) { join },
    ),
  )
}

pub fn creating_a_game_seats_its_creator_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> creating(
      Ok(Nil),
      Ok(Seat(player_id: "p1", token: "tok", started: False)),
    )

  assert rooms.create(ctx, fakes.guest("g1"), backgammon, setup(), " Alice ")
    == Ok(Seated(
      game_id: "123456",
      player_id: "p1",
      token: "tok",
      name: "Alice",
      started: False,
    ))
}

pub fn creating_a_game_with_no_guest_id_still_seats_test() {
  let ctx =
    fakes.ctx()
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", token: "tok", started: True)))

  assert rooms.create(ctx, fakes.no_guest(), backgammon, setup(), "Alice")
    == Ok(Seated(
      game_id: "123456",
      player_id: "p1",
      token: "tok",
      name: "Alice",
      started: True,
    ))
}

// A bad name never mints a code: every other capability still panics.
pub fn creating_a_game_needs_a_name_test() {
  assert rooms.create(fakes.ctx(), fakes.no_guest(), backgammon, setup(), "  ")
    == Error(rooms.Rejected("Pick a display name first"))
}

pub fn a_setup_the_game_does_not_offer_is_refused_test() {
  let ctx =
    fakes.ctx()
    |> creating(Error(errors.UnknownFormat), Ok(Seat("p1", "tok", False)))

  assert rooms.create(ctx, fakes.no_guest(), backgammon, setup(), "Alice")
    == Error(rooms.Rejected("Unknown game mode"))
}

pub fn a_seat_the_room_refuses_is_reported_test() {
  let ctx = fakes.ctx() |> creating(Ok(Nil), Error(errors.NameTaken))

  assert rooms.create(ctx, fakes.no_guest(), backgammon, setup(), "Alice")
    == Error(rooms.Rejected("That name is already taken"))
}

pub fn no_free_code_is_not_the_visitors_fault_test() {
  let ctx = minting(fakes.ctx(), "123456", True, Ok(Nil))

  assert rooms.create(ctx, fakes.no_guest(), backgammon, setup(), "Alice")
    == Error(rooms.Unavailable(errors.NoFreeId))
}

// ---------- Joining ----------

fn joining(ctx: Ctx, join: Result(room.Seat, errors.RoomError)) -> Ctx {
  let ctx = with_rooms(ctx, find: Some(fakes.room()), resume: None)

  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      subscribe: fn(_) { Nil },
      join: fn(_, _, _) { join },
    ),
  )
}

pub fn joining_a_lobby_takes_the_free_seat_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> joining(Ok(Seat(player_id: "p2", token: "tok2", started: True)))

  assert rooms.join(ctx, fakes.guest("g2"), "123456", "Bob")
    == Ok(Seated(
      game_id: "123456",
      player_id: "p2",
      token: "tok2",
      name: "Bob",
      started: True,
    ))
}

pub fn joining_needs_a_name_test() {
  assert rooms.join(fakes.ctx(), fakes.no_guest(), "123456", "")
    == Error(rooms.Refused("Pick a display name first"))
}

pub fn joining_never_creates_a_room_test() {
  let ctx = with_rooms(fakes.ctx(), find: None, resume: None)

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Bob")
    == Error(rooms.Gone(rooms.gone_message))
}

pub fn a_name_clash_is_just_a_clash_test() {
  let ctx = fakes.ctx() |> joining(Error(errors.NameTaken))

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Alice")
    == Error(rooms.Refused("That name is already taken"))
}

pub fn a_table_that_filled_up_is_re_routed_test() {
  let ctx = fakes.ctx() |> joining(Error(errors.GameFull))

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Bob")
    == Error(rooms.Reroute)
}

pub fn a_game_that_already_started_is_re_routed_test() {
  let ctx = fakes.ctx() |> joining(Error(errors.GameAlreadyStarted))

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Bob")
    == Error(rooms.Reroute)
}

pub fn any_other_refusal_is_shown_as_it_is_test() {
  let ctx = fakes.ctx() |> joining(Error(errors.Other("boom")))

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Bob")
    == Error(rooms.Refused("Error: boom"))
}
