//// The landing API the Elm client reads (/papi):
////
////   GET  /papi/library                 {ok, games, coming_soon, guest_name}
////   GET  /papi/games/:slug             {ok, game, formats, clock_presets,
////                                       copy, guest_name}
////   POST /papi/games/:slug             {ok, id, path, player_id}
////   GET  /papi/games/:slug/rooms/:id   {ok, state, inviter_name, summary,
////                                       disconnected}
////   POST /papi/games/:slug/rooms/:id   {ok, id, path, player_id}
////   GET  /papi/codes/:code             {ok, slug}
////
//// Every decision behind these lives in Gleam — what a page carries, what a
//// name has to be, what an invite link is worth. The Elixir controller only
//// picks a status and writes the body.

import gamekit/clock
import gamekit/game.{type Info}
import gamekit/registry
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/guests/identity
import oskol/handlers/rooms
import oskol/landing/copy.{type Copy}
import oskol/rooms/errors
import oskol/rooms/invite
import oskol/rooms/room.{type Seated, type Table, Setup}

/// Games with no engine yet. They are a poster on the library and nothing
/// else: no route, no sitemap entry. Empty today: every catalog game has an
/// engine.
pub fn coming_soon() -> List(Info) {
  []
}

// ---------- GET /papi/library ----------

pub fn library_json(ctx: Ctx, session: Session) -> String {
  envelope.ok([
    #("games", json.array(registry.infos(), game.info_to_json)),
    #("coming_soon", json.array(coming_soon(), game.info_to_json)),
    #("guest_name", guest_name(ctx, session)),
  ])
}

// ---------- GET /papi/games/:slug ----------

pub fn game_json(
  ctx: Ctx,
  session: Session,
  slug: String,
) -> Result(String, ApiError) {
  use info <- result.try(find_info(slug))

  Ok(
    envelope.ok([
      #("game", game.info_to_json(info)),
      #("formats", json.array(info.formats, game.format_to_json)),
      // Every preset, in preset order: the client filters them by the ones
      // this game offers (`game.clocks`) for the picker, and walks
      // `game.clocks` for the panel that lists them.
      #("clock_presets", json.array(clock.presets(), clock.preset_to_json)),
      #("copy", copy_json(ctx.copy.for_game(slug))),
      #("guest_name", guest_name(ctx, session)),
    ]),
  )
}

fn copy_json(copy: Copy) -> Json {
  json.object([
    #("title", json.string(copy.title)),
    #("description", json.string(copy.description)),
    #("intro", json.string(copy.intro)),
    #("rules", json.array(copy.rules, json.string)),
    #(
      "faq",
      json.array(copy.faq, fn(entry) {
        json.object([
          #("question", json.string(entry.0)),
          #("answer", json.string(entry.1)),
        ])
      }),
    ),
  ])
}

// ---------- POST /papi/games/:slug ----------

pub fn create_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  format: String,
  name: String,
  clock_id: String,
  selections: List(#(String, String)),
) -> Result(String, ApiError) {
  use info <- result.try(find_info(slug))

  let setup =
    Setup(format: format, selections: selections, clock: case clock_id {
      "" -> info.default_clock
      chosen -> chosen
    })

  case rooms.create(ctx, session, slug, setup, name) {
    Ok(seated) -> Ok(seat_taken(slug, seated))
    Error(rooms.Rejected(message)) -> Error(error.validation_failed(message))
    Error(rooms.Unavailable(reason)) ->
      Error(error.Internal(errors.message(reason)))
  }
}

// ---------- GET /papi/games/:slug/rooms/:id ----------

/// What the invite link for this room is worth. A read, so it never claims
/// anything: a visitor is never shown a join form the table has no room for.
pub fn room_json(ctx: Ctx, game_id: String) -> String {
  let #(step, table) = rooms.offer(ctx, game_id)

  let #(inviter, disconnected) = case step {
    invite.Open(inviter, disconnected) -> #(inviter, disconnected)
    invite.Reclaim(disconnected) -> #(None, disconnected)
    invite.Full -> #(None, [])
    invite.NoRoom -> #(None, [])
  }

  envelope.ok([
    #("state", json.string(invite.state(step))),
    #("inviter_name", nullable(inviter)),
    #("summary", nullable(summary(table))),
    #(
      "disconnected",
      json.array(disconnected, fn(seat) {
        json.object([
          #("id", json.string(seat.0)),
          #("name", json.string(seat.1)),
        ])
      }),
    ),
  ])
}

fn summary(table: Option(Table)) -> Option(String) {
  case table {
    Some(table) -> Some(table.summary)
    None -> None
  }
}

// ---------- POST /papi/games/:slug/rooms/:id ----------

pub fn join_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
  name: String,
) -> Result(String, ApiError) {
  rooms.join(ctx, session, game_id, name)
  |> seat_result(slug)
}

pub fn claim_json(
  ctx: Ctx,
  slug: String,
  game_id: String,
  player_id: String,
) -> Result(String, ApiError) {
  rooms.claim(ctx, game_id, player_id)
  |> seat_result(slug)
}

fn seat_result(
  result: Result(Seated, rooms.JoinError),
  slug: String,
) -> Result(String, ApiError) {
  case result {
    Ok(seated) -> Ok(seat_taken(slug, seated))
    Error(rooms.Refused(message)) -> Error(error.validation_failed(message))
    // The table moved on. There is no seat and nothing to fix by typing
    // again: the client reads the invite afresh.
    Error(rooms.Reroute) ->
      Error(error.validation_failed(errors.message(errors.GameFull)))
    Error(rooms.Gone(message)) -> Error(error.NotFound(message))
  }
}

/// The one answer to every write: the room's code, and the URL that opens
/// the seat that was just taken.
fn seat_taken(slug: String, seated: Seated) -> String {
  envelope.ok([
    #("id", json.string(seated.game_id)),
    #("path", json.string(room.seat_path(slug, seated.game_id, seated.token))),
    #("player_id", json.string(seated.player_id)),
  ])
}

// ---------- GET /papi/codes/:code ----------

/// The 6-digit code prompt. Says only which game answers to the code —
/// nothing else about the room.
pub fn code_json(ctx: Ctx, code: String) -> Result(String, ApiError) {
  case rooms.lookup_slug(ctx, code) {
    Some(slug) -> Ok(envelope.ok([#("slug", json.string(slug))]))
    None -> Error(error.NotFound("No game with that code"))
  }
}

// ---------- Shared ----------

fn find_info(slug: String) -> Result(Info, ApiError) {
  registry.find(slug)
  |> result.map(fn(entry) { entry.info })
  |> result.replace_error(error.NotFound("No game with that name"))
}

fn guest_name(ctx: Ctx, session: Session) -> Json {
  nullable(identity.remembered_name(ctx, session))
}

fn nullable(value: Option(String)) -> Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}
