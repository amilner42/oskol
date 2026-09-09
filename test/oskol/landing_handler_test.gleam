//// The JSON the Elm client reads. The shapes are asserted here, on the
//// real registry (games are pure Gleam) and stub capabilities.

import gleam/option.{None, Some}
import gleam/string
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/envelope
import oskol/core/error
import oskol/fakes
import oskol/handlers/landing
import oskol/rooms/errors
import oskol/rooms/room.{type Table, Seat, Table}

fn reading() -> Ctx {
  fakes.ctx()
  |> fakes.with_guests(None)
  |> fakes.with_copy(fakes.sample_copy())
}

// ---------- GET /papi/library ----------

pub fn the_library_lists_every_registered_game_test() {
  let body = landing.library_json(reading(), fakes.no_guest())

  assert string.starts_with(body, "{\"ok\":true,\"games\":[")
  assert string.contains(body, "\"slug\":\"poker\"")
  assert string.contains(body, "\"slug\":\"backgammon\"")
  assert string.contains(body, "\"slug\":\"chess\"")
  assert string.contains(body, "\"slug\":\"go\"")
  // A game map carries what the library grid draws with.
  assert string.contains(body, "\"name\":\"Backgammon\"")
  assert string.contains(body, "\"tagline\":")
  assert string.contains(body, "\"coming_soon\":[]")
}

pub fn the_library_carries_the_guest_it_remembers_test() {
  let ctx = reading() |> fakes.with_guests(Some("Renée"))
  let body = landing.library_json(ctx, fakes.guest("g1"))

  assert string.contains(body, "\"guest_name\":\"Renée\"")
}

pub fn a_visitor_we_do_not_know_has_no_name_test() {
  let body = landing.library_json(reading(), fakes.no_guest())

  assert string.contains(body, "\"guest_name\":null")
}

// ---------- GET /papi/games/:slug ----------

pub fn a_game_page_carries_its_copy_its_formats_and_the_clocks_test() {
  let assert Ok(body) =
    landing.game_json(reading(), fakes.no_guest(), "backgammon")

  assert string.starts_with(body, "{\"ok\":true,\"game\":{")
  assert string.contains(body, "\"slug\":\"backgammon\"")
  assert string.contains(body, "\"min_players\":2")
  assert string.contains(body, "\"max_players\":2")
  assert string.contains(body, "\"default_clock\":")
  // The game's own clocks are preset ids; the presets themselves come with
  // the page, so the picker can name them.
  assert string.contains(body, "\"clocks\":[\"none\"")
  assert string.contains(body, "\"clock_presets\":[{\"id\":\"none\"")
  // Formats, with the settings the creator may tune.
  assert string.contains(body, "\"formats\":[{\"id\":\"single\"")
  assert string.contains(body, "\"settings\":[")
  // Copy, in one object of its own.
  assert string.contains(
    body,
    "\"copy\":{\"title\":\"Play backgammon online with a friend\"",
  )
  assert string.contains(
    body,
    "\"description\":\"Backgammon for two, free, no accounts.\"",
  )
  assert string.contains(
    body,
    "\"intro\":\"The race game with the doubling cube.\"",
  )
  assert string.contains(body, "\"rules\":[\"Fifteen checkers each.\"")
  assert string.contains(
    body,
    "\"faq\":[{\"question\":\"Do we need accounts?\",\"answer\":\"No.\"}]",
  )
  assert string.contains(body, "\"guest_name\":null")
}

pub fn an_unknown_slug_is_a_not_found_envelope_test() {
  let assert Error(err) =
    landing.game_json(reading(), fakes.no_guest(), "checkers")

  assert envelope.error(err)
    == #(
      404,
      "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"No game with that name\"}}",
    )
}

// ---------- POST /papi/games/:slug ----------

/// Caps that mint one code and seat one player — and refuse any setup but
/// `expected`, so what the handler configured the room with is what the
/// test says it is.
fn creating(ctx: Ctx, expected: room.Setup) -> Ctx {
  Ctx(
    ..ctx,
    ids: ids_caps.IdsCaps(game_code: fn() { "123456" }),
    persistence: persistence_caps.PersistenceCaps(game_exists: fn(_) { False }),
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      spawn: fn(_, _) { Ok(Nil) },
      subscribe: fn(_) { Nil },
      configure: fn(_, setup) {
        case setup == expected {
          True -> Ok(Nil)
          False ->
            Error(errors.Other("configured with " <> string.inspect(setup)))
        }
      },
      join: fn(_, _, _) {
        Ok(Seat(player_id: "p1", token: "tok", started: False))
      },
    ),
  )
}

pub fn creating_a_game_answers_with_its_code_and_the_seat_url_test() {
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", selections: [], clock: "blitz"))

  assert landing.create_json(
      ctx,
      fakes.guest("g1"),
      "backgammon",
      "single",
      "Alice",
      "blitz",
      [],
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456?t=tok\",\"player_id\":\"p1\"}",
    )
}

pub fn the_creators_settings_reach_the_room_test() {
  let selections = [#("stakes", "deep"), #("twist", "off")]
  let ctx =
    reading()
    |> creating(room.Setup(
      format: "cash",
      selections: selections,
      clock: "poker_fast",
    ))

  let assert Ok(_) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "poker",
      "cash",
      "Alice",
      "poker_fast",
      selections,
    )
}

pub fn no_clock_asked_for_means_the_games_default_test() {
  // Backgammon's default preset, straight from its own Info.
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", selections: [], clock: "none"))

  let assert Ok(_) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "single",
      "Alice",
      "",
      [],
    )
}

pub fn creating_a_game_needs_a_name_test() {
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", selections: [], clock: "none"))

  let assert Error(err) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "single",
      " ",
      "none",
      [],
    )

  assert envelope.error(err)
    == #(
      422,
      "{\"ok\":false,\"error\":{\"code\":\"validation_failed\",\"message\":\"Pick a display name first\"}}",
    )
}

pub fn creating_a_game_in_a_mode_it_has_not_got_is_refused_test() {
  let ctx = reading() |> creating(room.Setup("single", [], "none"))
  let ctx =
    Ctx(
      ..ctx,
      rooms: rooms_caps.RoomsCaps(..ctx.rooms, configure: fn(_, _) {
        Error(errors.UnknownFormat)
      }),
    )

  let assert Error(err) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "nope",
      "Alice",
      "none",
      [],
    )

  assert error.code(err) == "validation_failed"
  assert error.message(err) == "Unknown game mode"
}

pub fn creating_a_game_of_a_game_that_does_not_exist_is_not_found_test() {
  let assert Error(err) =
    landing.create_json(
      reading(),
      fakes.no_guest(),
      "checkers",
      "x",
      "Alice",
      "none",
      [],
    )

  assert error.status(err) == 404
}

// ---------- GET /papi/games/:slug/rooms/:id ----------

fn table(ctx: Ctx, table: Table) -> Ctx {
  fakes.with_room(ctx, Some(fakes.room()), Some(table))
}

pub fn an_invite_to_a_free_seat_is_open_test() {
  let ctx =
    reading()
    |> table(
      Table(
        full: False,
        inviter: Some("Alice"),
        summary: "Match to 3 · Blitz clock",
        disconnected: [],
      ),
    )

  assert landing.room_json(ctx, "123456")
    == "{\"ok\":true,\"state\":\"open\",\"inviter_name\":\"Alice\",\"summary\":\"Match to 3 · Blitz clock\",\"disconnected\":[]}"
}

pub fn an_invite_to_a_full_table_offers_nothing_test() {
  let ctx =
    reading()
    |> table(
      Table(
        full: True,
        inviter: Some("Alice"),
        summary: "Single game",
        disconnected: [],
      ),
    )

  assert landing.room_json(ctx, "123456")
    == "{\"ok\":true,\"state\":\"full\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[]}"
}

pub fn an_invite_to_a_table_someone_left_offers_their_seat_test() {
  let ctx =
    reading()
    |> table(
      Table(full: True, inviter: None, summary: "Single game", disconnected: [
        #("p2", "Bob"),
      ]),
    )

  assert landing.room_json(ctx, "123456")
    == "{\"ok\":true,\"state\":\"away\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[{\"id\":\"p2\",\"name\":\"Bob\"}]}"
}

pub fn an_invite_to_a_room_that_is_over_is_missing_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  assert landing.room_json(ctx, "123456")
    == "{\"ok\":true,\"state\":\"missing\",\"inviter_name\":null,\"summary\":null,\"disconnected\":[]}"
}

// ---------- POST /papi/games/:slug/rooms/:id ----------

fn seating(ctx: Ctx, seat: Result(room.Seat, errors.RoomError)) -> Ctx {
  let ctx = fakes.with_room(ctx, Some(fakes.room()), Some(a_table()))

  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      subscribe: fn(_) { Nil },
      join: fn(_, _, _) { seat },
      claim: fn(_, _) { seat },
    ),
  )
}

fn a_table() -> Table {
  Table(full: True, inviter: None, summary: "Single game", disconnected: [
    #("p2", "Bob"),
  ])
}

pub fn joining_answers_with_the_url_that_opens_the_seat_test() {
  let ctx =
    reading()
    |> fakes.with_guests(None)
    |> seating(Ok(Seat(player_id: "p2", token: "tok2", started: True)))

  assert landing.join_json(
      ctx,
      fakes.guest("g2"),
      "backgammon",
      "123456",
      "Bob",
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456?t=tok2\",\"player_id\":\"p2\"}",
    )
}

pub fn joining_a_room_that_is_over_is_not_found_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Bob")

  assert error.status(err) == 404
  assert error.message(err)
    == "That game is over. Start a new one and send a fresh link."
}

pub fn joining_a_table_that_filled_up_says_so_test() {
  let ctx = reading() |> seating(Error(errors.GameFull))

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Bob")

  assert error.code(err) == "validation_failed"
  assert error.message(err) == "That game is full"
}

pub fn a_name_clash_is_refused_test() {
  let ctx = reading() |> seating(Error(errors.NameTaken))

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Alice")

  assert error.message(err) == "That name is already taken"
}

pub fn reclaiming_a_seat_hands_out_its_new_token_test() {
  let ctx =
    reading()
    |> seating(Ok(Seat(player_id: "p2", token: "fresh", started: True)))

  assert landing.claim_json(ctx, "backgammon", "123456", "p2")
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456?t=fresh\",\"player_id\":\"p2\"}",
    )
}

pub fn reclaiming_a_seat_whose_player_came_back_is_refused_test() {
  let ctx = reading() |> seating(Error(errors.SeatConnected))

  let assert Error(err) = landing.claim_json(ctx, "backgammon", "123456", "p2")

  assert error.message(err) == "That player is back at the table"
}

// ---------- GET /papi/codes/:code ----------

pub fn a_code_resolves_to_the_game_it_belongs_to_test() {
  let ctx =
    reading()
    |> fakes.with_room(Some(fakes.room()), None)
    |> fakes.with_slug(Some("poker"))

  assert landing.code_json(ctx, "123456")
    == Ok("{\"ok\":true,\"slug\":\"poker\"}")
}

pub fn a_code_nothing_answers_to_is_not_found_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  let assert Error(err) = landing.code_json(ctx, "123456")

  assert envelope.error(err)
    == #(
      404,
      "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"No game with that code\"}}",
    )
}
