//// The landing API the Elm client reads (/papi):
////
////   GET  /papi/library                 {ok, games, coming_soon, guest_name}
////   GET  /papi/games/:slug             {ok, game, formats, clock_presets,
////                                       copy, guest_name}
////   POST /papi/games/:slug             {ok, id, path, player_id}
////   GET  /papi/games/:slug/rooms/:id   {ok, state, inviter_name, summary,
////                                       disconnected}
////   POST /papi/games/:slug/rooms/:id   {ok, id, path, player_id}
////   GET  /papi/codes/:code             {ok, slug, code}
////   GET  /papi/me/prefs                {ok, prefs}
////   POST /papi/me/prefs                {key, value} -> {ok, prefs}
////   GET  /papi/me/games                {ok, games}
////
//// Every decision behind these lives in Gleam — what a page carries, what a
//// name has to be, what an invite link is worth. The Elixir controller only
//// picks a status and writes the body.

import gamekit/clock
import gamekit/game.{type Info}
import gamekit/registry
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/guests/identity
import oskol/guests/prefs
import oskol/handlers/rooms
import oskol/landing/copy.{type Copy}
import oskol/rooms/code as room_code
import oskol/rooms/errors
import oskol/rooms/invite
import oskol/rooms/room.{type ActiveRoom, type Seated, type Table, Setup}

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
  session: Session,
  slug: String,
  game_id: String,
  player_id: String,
) -> Result(String, ApiError) {
  rooms.claim(ctx, session, game_id, player_id)
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

/// The one answer to every write: the room's code, and the URL of the seat
/// that was just taken. It carries nothing secret -- the seat is held by
/// the guest cookie the write came with -- so it is the same URL anyone
/// would be given for that room.
fn seat_taken(slug: String, seated: Seated) -> String {
  envelope.ok([
    #("id", json.string(seated.game_id)),
    #("path", json.string(room.seat_path(slug, seated.game_id))),
    #("player_id", json.string(seated.player_id)),
  ])
}

// ---------- GET/POST /papi/me/prefs ----------
//
// The visitor's own display preferences: which board they like to look at.
// Display only — nothing here reaches a room, a scene or an opponent, and a
// visitor with no guest cookie simply has none (their browser keeps the
// pick itself).

pub fn prefs_json(ctx: Ctx, session: Session) -> String {
  envelope.ok([#("prefs", prefs_object(identity.preferences(ctx, session)))])
}

/// Write one preference. The whitelist is the point: an unknown key or a
/// value that names no theme is refused, so the column only ever holds
/// things this release knows how to honour.
pub fn save_pref_json(
  ctx: Ctx,
  session: Session,
  key: String,
  value: String,
) -> Result(String, ApiError) {
  case prefs.validate(key, value) {
    Ok(#(key, value)) -> {
      identity.remember_preference(ctx, session, key, value)
      // Answer with what the site now holds for this visitor, so the client
      // never has to guess whether the write landed.
      Ok(prefs_json(ctx, session))
    }
    Error(message) -> Error(error.validation_failed(message))
  }
}

fn prefs_object(kept: prefs.Prefs) -> Json {
  json.object(list.map(kept, fn(pair) { #(pair.0, json.string(pair.1)) }))
}

// ---------- GET /papi/codes/:code ----------

/// The six-character code prompt. A code is looked up as typed first, since
/// a room's own name is the truth about it; only if nothing answers is it
/// normalised (upper case, and the lookalikes the alphabet drops folded onto
/// their twins) and tried again, which is what makes a code read down the
/// phone findable however it was written down. The code that answered comes
/// back, because that is the room's real name and the client needs it for
/// the invite link. Says only which game answers — nothing else about the
/// room.
pub fn code_json(ctx: Ctx, typed: String) -> Result(String, ApiError) {
  let candidates = case room_code.normalise(typed) {
    same if same == typed -> [typed]
    normalised -> [typed, normalised]
  }

  case first_match(ctx, candidates) {
    Some(#(code, slug)) ->
      Ok(
        envelope.ok([
          #("slug", json.string(slug)),
          #("code", json.string(code)),
        ]),
      )
    None -> Error(error.NotFound("No game with that code"))
  }
}

fn first_match(ctx: Ctx, codes: List(String)) -> Option(#(String, String)) {
  case codes {
    [] -> None
    [code, ..rest] ->
      case rooms.lookup_slug(ctx, code) {
        Some(slug) -> Some(#(code, slug))
        None -> first_match(ctx, rest)
      }
  }
}

// ---------- Shared ----------

fn find_info(slug: String) -> Result(Info, ApiError) {
  registry.find(slug)
  |> result.map(fn(entry) { entry.info })
  |> result.replace_error(error.NotFound("No game with that name"))
}

// ---------- GET /papi/me/games ----------

/// The games this visitor can pick back up: every unfinished room their
/// guest holds a seat in, newest activity first. A visitor with no guest
/// holds no seat anywhere, so their list is empty. Read from the rows: a
/// home visit wakes no room.
pub fn my_games_json(ctx: Ctx, session: Session) -> String {
  let rooms = case session.guest_id {
    Some(id) -> ctx.persistence.seated_rooms(id)
    None -> []
  }
  envelope.ok([
    #("games", json.array(rooms, fn(r) { active_room_json(r, session) })),
  ])
}

/// One resumable game as the home page lists it: where it is (`path`),
/// who it is against (`opponent`, null while nobody has joined), what is
/// being played (the format's and the clock's names), whether the visitor
/// is the one to act, the two clocks as the room last read them (`time`:
/// the visitor's and the opponent's ms, whose is running, the free time
/// left on the move, and `age_s`, how long ago that was, so the running
/// one can be charged for it; null under no clock), and how long since the
/// room was touched.
fn active_room_json(room: ActiveRoom, session: Session) -> Json {
  let info = registry.find(room.slug) |> result.map(fn(e) { e.info })
  let mine =
    list.find(room.seats, fn(seat) { Some(seat.2) == session.guest_id })
  let my_id = case mine {
    Ok(seat) -> seat.0
    Error(_) -> ""
  }
  let opponent =
    list.find(room.seats, fn(seat) { seat.0 != my_id })
    |> result.map(fn(seat) { seat.1 })
    |> option.from_result
  let format = case info {
    Ok(info) ->
      list.find(info.formats, fn(f) { f.id == room.format })
      |> result.map(fn(f) { f.name })
      |> result.unwrap(room.format)
    Error(_) -> room.format
  }
  let clock = case clock.preset(room.clock) {
    Ok(p) if p.control != clock.NoClock -> Some(p.name)
    _ -> None
  }
  json.object([
    #("slug", json.string(room.slug)),
    #("id", json.string(room.game_id)),
    #("path", json.string(room.seat_path(room.slug, room.game_id))),
    #("status", json.string(room.status)),
    #("opponent", nullable(opponent)),
    #("format", json.string(format)),
    #("clock", nullable(clock)),
    #("your_move", json.bool(my_id != "" && list.contains(room.to_act, my_id))),
    #("time", time_json(room.clocks, room.clock_s, my_id)),
    #("idle_s", json.int(room.idle_s)),
  ])
}

fn time_json(
  clocks: List(#(String, Int, Int, Bool)),
  age_s: Int,
  my_id: String,
) -> Json {
  let mine = list.find(clocks, fn(c) { c.0 == my_id })
  let theirs = list.find(clocks, fn(c) { c.0 != my_id })
  case mine, theirs {
    Ok(mine), Ok(theirs) ->
      json.object([
        #("mine_ms", json.int(mine.1)),
        #("theirs_ms", json.int(theirs.1)),
        #("running", case mine.3, theirs.3 {
          True, _ -> json.string("mine")
          _, True -> json.string("theirs")
          _, _ -> json.null()
        }),
        #("free_ms", json.int(int.max(mine.2, theirs.2))),
        #("age_s", json.int(age_s)),
      ])
    _, _ -> json.null()
  }
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
