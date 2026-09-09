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
import oskol/rooms/room.{Seat}

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

  assert string.contains(body, "\"guest\":{\"name\":\"Renée\"}")
}

pub fn a_visitor_we_do_not_know_has_no_name_test() {
  let body = landing.library_json(reading(), fakes.no_guest())

  assert string.contains(body, "\"guest\":{\"name\":null}")
}

// ---------- GET /papi/games/:slug ----------

pub fn a_game_page_carries_its_copy_and_its_formats_test() {
  let assert Ok(body) =
    landing.game_json(reading(), fakes.no_guest(), "backgammon")

  assert string.starts_with(body, "{\"ok\":true,\"game\":{")
  assert string.contains(body, "\"slug\":\"backgammon\"")
  assert string.contains(body, "\"min_players\":2")
  assert string.contains(body, "\"max_players\":2")
  assert string.contains(body, "\"default_clock\":")
  // The clock presets this game offers, resolved.
  assert string.contains(body, "\"clocks\":[{\"id\":")
  // Copy.
  assert string.contains(
    body,
    "\"title\":\"Play backgammon online with a friend\"",
  )
  assert string.contains(
    body,
    "\"meta_description\":\"Backgammon for two, free, no accounts.\"",
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
  // Formats, with the settings the creator may tune.
  assert string.contains(body, "\"formats\":[{\"id\":\"single\"")
  assert string.contains(body, "\"description\":")
  assert string.contains(body, "\"settings\":[")
  assert string.contains(body, "\"guest\":{\"name\":null}")
}

pub fn an_unknown_slug_is_a_not_found_envelope_test() {
  let assert Error(err) =
    landing.game_json(reading(), fakes.no_guest(), "checkers")

  assert envelope.error(err)
    == #(
      404,
      "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Unknown game: checkers\"}}",
    )
}

// ---------- POST /papi/games/:slug ----------

fn creating(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    ids: ids_caps.IdsCaps(game_code: fn() { "123456" }),
    persistence: persistence_caps.PersistenceCaps(game_exists: fn(_) { False }),
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      spawn: fn(_, _) { Ok(Nil) },
      subscribe: fn(_) { Nil },
      configure: fn(_, _) { Ok(Nil) },
      join: fn(_, _, _) {
        Ok(Seat(player_id: "p1", token: "tok", started: False))
      },
    ),
  )
}

pub fn creating_a_game_answers_with_its_code_and_path_test() {
  let ctx = reading() |> creating()

  assert landing.create_json(
      ctx,
      fakes.guest("g1"),
      "backgammon",
      "single",
      "Alice",
    )
    == Ok("{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456\"}")
}

pub fn creating_a_game_needs_a_name_test() {
  let ctx = reading() |> creating()

  let assert Error(err) =
    landing.create_json(ctx, fakes.no_guest(), "backgammon", "single", " ")

  assert envelope.error(err)
    == #(
      422,
      "{\"ok\":false,\"error\":{\"code\":\"validation_failed\",\"message\":\"Pick a display name first\"}}",
    )
}

pub fn creating_a_game_in_a_mode_it_has_not_got_is_refused_test() {
  let ctx = reading() |> creating()
  let ctx =
    Ctx(
      ..ctx,
      rooms: rooms_caps.RoomsCaps(..ctx.rooms, configure: fn(_, _) {
        Error(errors.UnknownFormat)
      }),
    )

  let assert Error(err) =
    landing.create_json(ctx, fakes.no_guest(), "backgammon", "nope", "Alice")

  assert error.code(err) == "validation_failed"
  assert error.message(err) == "Unknown game mode"
}

pub fn creating_a_game_of_a_game_that_does_not_exist_is_not_found_test() {
  let assert Error(err) =
    landing.create_json(reading(), fakes.no_guest(), "checkers", "x", "Alice")

  assert error.status(err) == 404
}
