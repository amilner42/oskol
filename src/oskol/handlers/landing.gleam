//// The landing pages as JSON: the library, one game's start page, and
//// creating a room from it. The same decisions LandingLive makes, served to
//// the Elm client under /papi.

import gamekit/clock
import gamekit/game.{type Info}
import gamekit/registry
import gleam/json.{type Json}
import gleam/list
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
import oskol/rooms/room.{Setup}

/// Games with no engine yet. They are plain HTML on the library and nothing
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
    #("guest", guest_json(identity.remembered_name(ctx, session))),
  ])
}

// ---------- GET /papi/games/:slug ----------

pub fn game_json(
  ctx: Ctx,
  session: Session,
  slug: String,
) -> Result(String, ApiError) {
  use info <- result.try(find_info(slug))
  let copy = ctx.copy.for_game(slug)

  Ok(
    envelope.ok([
      #("game", game_object(info, copy)),
      #("formats", json.array(info.formats, game.format_to_json)),
      #("guest", guest_json(identity.remembered_name(ctx, session))),
    ]),
  )
}

fn game_object(info: Info, copy: Copy) -> Json {
  json.object([
    #("slug", json.string(info.slug)),
    #("name", json.string(info.name)),
    #("tagline", json.string(info.tagline)),
    #("description", json.string(info.description)),
    #("min_players", json.int(info.min_players)),
    #("max_players", json.int(info.max_players)),
    #("default_clock", json.string(info.default_clock)),
    #("clocks", json.array(offered_clocks(info), clock.preset_to_json)),
    #("title", json.string(copy.title)),
    #("meta_description", json.string(copy.description)),
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

/// The time-control presets this game offers, in the game's own order —
/// the list the create page's clock chips are built from.
fn offered_clocks(info: Info) -> List(clock.Preset) {
  list.filter_map(info.clocks, clock.preset)
}

// ---------- POST /papi/games/:slug ----------

pub fn create_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  format: String,
  name: String,
) -> Result(String, ApiError) {
  use info <- result.try(find_info(slug))
  let setup = Setup(format: format, selections: [], clock: info.default_clock)

  case rooms.create(ctx, session, slug, setup, name) {
    Ok(seated) ->
      Ok(
        envelope.ok([
          #("id", json.string(seated.game_id)),
          #("path", json.string("/" <> slug <> "/" <> seated.game_id)),
        ]),
      )
    Error(rooms.Rejected(message)) -> Error(error.validation_failed(message))
    Error(rooms.Unavailable(reason)) ->
      Error(error.Internal(errors.message(reason)))
  }
}

// ---------- Shared ----------

fn find_info(slug: String) -> Result(Info, ApiError) {
  registry.find(slug)
  |> result.map(fn(entry) { entry.info })
  |> result.replace_error(error.NotFound("Unknown game: " <> slug))
}

fn guest_json(name: Option(String)) -> Json {
  json.object([
    #("name", case name {
      Some(name) -> json.string(name)
      None -> json.null()
    }),
  ])
}
