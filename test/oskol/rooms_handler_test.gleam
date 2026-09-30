//// The room lifecycle handler, on stub capabilities: every branch of
//// minting a code, looking a room up, reading an invite, creating a room
//// and taking a seat in one.

import gleam/option.{None, Some}
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/fakes
import oskol/handlers/rooms
import oskol/rooms/errors
import oskol/rooms/invite
import oskol/rooms/room.{Seat, Seated, Setup}

const backgammon = "backgammon"

fn setup() -> room.Setup {
  Setup(format: "single", clock: "none")
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
    ids: ids_caps.IdsCaps(..ids_caps.stub(), game_code: fn() { code }),
    persistence: persistence_caps.PersistenceCaps(
      ..ctx.persistence,
      game_exists: fn(_) { taken },
    ),
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
      join: fn(_, _, _, _) { join },
    ),
  )
}

fn seating_a_bot(ctx: Ctx, seat: Result(room.Seat, errors.RoomError)) -> Ctx {
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(..ctx.rooms, seat_bot: fn(_, name) {
      case name {
        "Sage" -> seat
        other -> panic as { "the bot was seated as " <> other }
      }
    }),
  )
}

pub fn creating_a_game_seats_its_creator_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", started: False)))

  assert rooms.create(
      ctx,
      fakes.guest("g1"),
      backgammon,
      setup(),
      " Alice ",
      rooms.AFriend,
    )
    == Ok(Seated(
      game_id: "123456",
      player_id: "p1",
      name: "Alice",
      started: False,
    ))
}

pub fn creating_a_game_with_no_guest_id_still_seats_test() {
  let ctx =
    fakes.ctx()
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", started: True)))

  assert rooms.create(
      ctx,
      fakes.no_guest(),
      backgammon,
      setup(),
      "Alice",
      rooms.AFriend,
    )
    == Ok(Seated(
      game_id: "123456",
      player_id: "p1",
      name: "Alice",
      started: True,
    ))
}

pub fn creating_a_game_against_the_bot_seats_the_bot_too_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", started: False)))
    |> seating_a_bot(Ok(Seat(player_id: "p2", started: True)))

  // The bot fills the table, so what comes back is a game already going.
  assert rooms.create(
      ctx,
      fakes.guest("g1"),
      backgammon,
      setup(),
      "Alice",
      rooms.TheBot,
    )
    == Ok(Seated(
      game_id: "123456",
      player_id: "p1",
      name: "Alice",
      started: True,
    ))
}

pub fn a_bot_game_refuses_a_creator_called_sage_test() {
  // The room refuses a name already at the table, so a player called Sage
  // would keep the bot from sitting down at all. Nothing is minted: the
  // remaining capabilities still panic if they are reached.
  assert rooms.create(
      fakes.ctx(),
      fakes.no_guest(),
      backgammon,
      setup(),
      " sage ",
      rooms.TheBot,
    )
    == Error(rooms.Rejected(
      "Sage is the bot's name. Pick another one to play it.",
    ))
}

pub fn a_friend_game_does_not_mind_a_player_called_sage_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", started: False)))

  let assert Ok(seated) =
    rooms.create(
      ctx,
      fakes.guest("g1"),
      backgammon,
      setup(),
      "Sage",
      rooms.AFriend,
    )
  assert seated.name == "Sage"
}

pub fn a_bot_that_will_not_sit_down_is_said_out_loud_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> creating(Ok(Nil), Ok(Seat(player_id: "p1", started: False)))
    |> seating_a_bot(Error(errors.GameFull))

  // Better a sentence than a table that can never start.
  assert rooms.create(
      ctx,
      fakes.guest("g1"),
      backgammon,
      setup(),
      "Alice",
      rooms.TheBot,
    )
    == Error(rooms.Rejected(errors.message(errors.GameFull)))
}

// A bad name never mints a code: every other capability still panics.
pub fn creating_a_game_needs_a_name_test() {
  assert rooms.create(
      fakes.ctx(),
      fakes.no_guest(),
      backgammon,
      setup(),
      "  ",
      rooms.AFriend,
    )
    == Error(rooms.Rejected("Pick a display name first"))
}

pub fn a_setup_the_game_does_not_offer_is_refused_test() {
  let ctx =
    fakes.ctx()
    |> creating(Error(errors.UnknownFormat), Ok(Seat("p1", False)))

  assert rooms.create(
      ctx,
      fakes.no_guest(),
      backgammon,
      setup(),
      "Alice",
      rooms.AFriend,
    )
    == Error(rooms.Rejected("Unknown game mode"))
}

pub fn a_seat_the_room_refuses_is_reported_test() {
  let ctx = fakes.ctx() |> creating(Ok(Nil), Error(errors.NameTaken))

  assert rooms.create(
      ctx,
      fakes.no_guest(),
      backgammon,
      setup(),
      "Alice",
      rooms.AFriend,
    )
    == Error(rooms.Rejected("That name is already taken"))
}

pub fn no_free_code_is_not_the_visitors_fault_test() {
  let ctx = minting(fakes.ctx(), "123456", True, Ok(Nil))

  assert rooms.create(
      ctx,
      fakes.no_guest(),
      backgammon,
      setup(),
      "Alice",
      rooms.AFriend,
    )
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
      join: fn(_, _, _, _) { join },
    ),
  )
}

pub fn joining_a_lobby_takes_the_free_seat_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_guests(None)
    |> joining(Ok(Seat(player_id: "p2", started: True)))

  assert rooms.join(ctx, fakes.guest("g2"), "123456", "Bob")
    == Ok(Seated(game_id: "123456", player_id: "p2", name: "Bob", started: True))
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

// ---------- Reclaiming a seat ----------

fn a_table() -> room.Table {
  room.Table(full: True, inviter: None, summary: "Single game", disconnected: [
    #("p2", "Bob", False),
  ])
}

fn reclaiming(ctx: Ctx, claim: Result(room.Seat, errors.RoomError)) -> Ctx {
  let ctx = fakes.with_room(ctx, Some(fakes.room()), Some(a_table()))

  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      subscribe: fn(_) { Nil },
      claim: fn(_, _, _, _) { claim },
    ),
  )
}

// The seat keeps the name it was taken under: it is the room's, not the
// visitor's, and it is read before the seat stops being an empty one.
pub fn a_reclaimed_seat_keeps_its_name_test() {
  let ctx =
    fakes.ctx()
    |> reclaiming(Ok(Seat(player_id: "p2", started: True)))

  assert rooms.claim(ctx, fakes.guest("g2"), "123456", "p2")
    == Ok(Seated(game_id: "123456", player_id: "p2", name: "Bob", started: True))
}

pub fn reclaiming_a_seat_in_a_room_that_is_over_test() {
  let ctx = fakes.with_room(fakes.ctx(), None, None)

  assert rooms.claim(ctx, fakes.guest("g2"), "123456", "p2")
    == Error(rooms.Gone(rooms.gone_message))
}

pub fn reclaiming_a_seat_whose_player_came_back_test() {
  let ctx = fakes.ctx() |> reclaiming(Error(errors.SeatConnected))

  assert rooms.claim(ctx, fakes.guest("g2"), "123456", "p2")
    == Error(rooms.Refused("That player is back at the table"))
}

// ---------- What an invite is worth ----------

pub fn an_invite_reads_the_table_behind_the_code_test() {
  let ctx = fakes.with_room(fakes.ctx(), Some(fakes.room()), Some(a_table()))

  assert rooms.offer(ctx, "123456")
    == #(invite.Reclaim([#("p2", "Bob", False)]), Some(a_table()))
}

// A code with no room never asks a room anything: the table capability
// panics.
pub fn an_invite_to_a_room_that_is_gone_is_worth_nothing_test() {
  let ctx = fakes.with_room(fakes.ctx(), None, None)

  assert rooms.offer(ctx, "123456") == #(invite.NoRoom, None)
}

pub fn any_other_refusal_is_shown_as_it_is_test() {
  let ctx = fakes.ctx() |> joining(Error(errors.Other("boom")))

  assert rooms.join(ctx, fakes.no_guest(), "123456", "Bob")
    == Error(rooms.Refused("Error: boom"))
}

// ---------- Closing a lobby ----------

/// A row for a lobby Alice (guest g1) made and nobody has joined.
fn a_lobby_row(status: String) -> room.ActiveRoom {
  room.ActiveRoom(
    slug: backgammon,
    game_id: "123456",
    status: status,
    format: "single",
    clock: "none",
    seats: [#("p1", "Alice", "g1", "")],
    to_act: [],
    clocks: [],
    clock_s: 0,
    idle_s: 90,
  )
}

/// The row, plus a room that answers a lookup and a close.
fn closing(
  ctx: Ctx,
  row: room.ActiveRoom,
  answer: Result(Nil, errors.RoomError),
) -> Ctx {
  let ctx = fakes.with_row(ctx, Some(row))
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      find: fn(_) { Some(fakes.room()) },
      close: fn(_, _, _) { answer },
    ),
  )
}

pub fn closing_a_lobby_ends_it_test() {
  let ctx = closing(fakes.ctx(), a_lobby_row("waiting"), Ok(Nil))

  assert rooms.close(ctx, fakes.guest("g1"), "123456") == Ok(Nil)
}

pub fn closing_a_room_with_no_row_says_it_is_over_test() {
  // Nothing is woken to find that out: the rooms capabilities all panic.
  let ctx = fakes.with_row(fakes.ctx(), None)

  assert rooms.close(ctx, fakes.guest("g1"), "123456")
    == Error(rooms.Gone(rooms.gone_message))
}

pub fn a_stranger_is_refused_without_waking_a_cold_room_test() {
  // No live room, so the row alone answers. `resume` -- which would
  // rebuild somebody else's lobby from its log -- panics if reached.
  let ctx = fakes.with_row(fakes.ctx(), Some(a_lobby_row("waiting")))
  let ctx =
    Ctx(..ctx, rooms: rooms_caps.RoomsCaps(..ctx.rooms, find: fn(_) { None }))

  assert rooms.close(ctx, fakes.guest("stranger"), "123456")
    == Error(rooms.Refused("You are not at this table"))
}

pub fn a_live_room_answers_for_itself_test() {
  // The row is written behind the room, so a lobby made a moment ago may
  // not carry its seat yet. A room that is already live is asked instead:
  // that wakes nothing, and its memory is the newer copy.
  let ctx =
    closing(
      fakes.ctx(),
      room.ActiveRoom(..a_lobby_row("waiting"), seats: []),
      Ok(Nil),
    )

  assert rooms.close(ctx, fakes.guest("g1"), "123456") == Ok(Nil)
}

pub fn a_room_with_a_game_in_it_is_refused_without_waking_it_test() {
  let ctx = fakes.with_row(fakes.ctx(), Some(a_lobby_row("playing")))

  assert rooms.close(ctx, fakes.guest("g1"), "123456")
    == Error(rooms.Refused("That game already started"))
}

pub fn closing_a_closed_room_again_is_the_same_yes_test() {
  // A second press, or a retry of a request that timed out after the write
  // landed: the same answer, and nothing woken to give it.
  let ctx = fakes.with_row(fakes.ctx(), Some(a_lobby_row("closed")))

  assert rooms.close(ctx, fakes.guest("g1"), "123456") == Ok(Nil)
}

pub fn closing_a_room_the_row_still_has_but_no_process_will_start_test() {
  let ctx = fakes.with_row(fakes.ctx(), Some(a_lobby_row("waiting")))
  let ctx =
    Ctx(
      ..ctx,
      rooms: rooms_caps.RoomsCaps(
        ..ctx.rooms,
        find: fn(_) { None },
        resume: fn(_) { None },
      ),
    )

  assert rooms.close(ctx, fakes.guest("g1"), "123456")
    == Error(rooms.Gone(rooms.gone_message))
}

pub fn a_room_that_stopped_mid_close_is_gone_rather_than_closed_test() {
  // Nothing was written, so the caller is told the room is over rather
  // than that the close landed.
  let ctx =
    closing(fakes.ctx(), a_lobby_row("waiting"), Error(errors.UnknownGame))

  assert rooms.close(ctx, fakes.guest("g1"), "123456")
    == Error(rooms.Gone(rooms.gone_message))
}

pub fn the_room_has_the_last_word_on_a_close_test() {
  // The row said waiting; the room has started since. Its answer stands.
  let ctx =
    closing(
      fakes.ctx(),
      a_lobby_row("waiting"),
      Error(errors.GameAlreadyStarted),
    )

  assert rooms.close(ctx, fakes.guest("g1"), "123456")
    == Error(rooms.Refused("That game already started"))
}
