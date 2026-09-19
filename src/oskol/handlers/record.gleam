//// GET /papi/games/:slug/rooms/:id/record
////
//// A game's whole record, for anyone with the room: every game of the
//// match with every entry, where the scene carries only the game on the
//// board (so every update stays bounded by one game). The client asks for
//// it when a player opens a finished game; replay and analysis will read
//// it too. What it holds is the game's to decide (`Game.record`, public to
//// every seat); who may read it is decided here.
////
//// Every game of a room is written down as it ends, one row per game
//// (`oskol/handlers/reviews`). For a room nobody is at, that is what this
//// serves: the head of the record -- who played which colour, the match
//// length, the opening position -- from starting the room's game and
//// asking nobody to play it, and every finished game from its row. No log
//// is replayed and no room is woken up, which is the point: waking one
//// means replaying its whole log, and a room nobody is at is exactly the
//// one a replay page asks about.
////
//// A room still in memory is read from the room instead: it is free, and
//// it carries the game on the board, which is not written down anywhere
//// until it ends. A replay only ever reads the games that finished, so
//// either answer serves it.

import gamekit/host
import gamekit/instance.{type Instance}
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/records.{type Setup}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/raw
import oskol/core/session.{type Session}
import oskol/handlers/rooms
import oskol/rooms/seat

/// Nothing to read. The same answer for a room that is not there and a
/// slug that is not its game, so a caller learns nothing about a room that
/// is not the one it asked for.
pub const not_found_message = "No record for that game"

pub fn record_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
) -> Result(String, ApiError) {
  case stored_json(ctx, session, slug, game_id) {
    Ok(body) -> Ok(body)
    Error(Nil) -> live_json(ctx, session, slug, game_id)
  }
}

/// The record of a room nobody is at, assembled from its rows. Error(Nil)
/// when it cannot be: the room is still in memory (reading it there is free
/// and carries the game on the board too), or nothing was written down for
/// it yet.
fn stored_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
) -> Result(String, Nil) {
  // `find` is the registry, not `rooms.lookup`: looking a room up rebuilds
  // it from its log, which is the replay this exists to avoid.
  use _ <- result.try(case ctx.rooms.find(game_id) {
    None -> Ok(Nil)
    Some(_) -> Error(Nil)
  })
  use setup <- result.try(case ctx.records.setup(game_id) {
    Some(setup) if setup.slug == slug -> Ok(setup)
    _ -> Error(Nil)
  })
  // Rows made from a shorter log than the room has now are short of the
  // games played since: a match settled when its first game ended has only
  // that game written down. Reading them would silently serve half a match,
  // so a room in that state takes the slow path, which is always right, and
  // the reviews read settles it properly.
  use _ <- result.try(case setup.records_through >= setup.log_length {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use head <- result.try(case ctx.records.stored(game_id) {
    [] -> Error(Nil)
    rows -> head_fields(setup) |> result.map(fn(head) { #(head, rows) })
  })
  let #(fields, rows) = head
  let #(player_id, seated) = stored_viewer(setup, session)
  Ok(
    envelope.ok([
      #("slug", json.string(slug)),
      #("id", json.string(game_id)),
      #("you", json.string(player_id)),
      #("seated", json.bool(seated)),
      #("accounts", accounts_json(Some(setup))),
      #(
        "record",
        json.object(
          list.append(fields, [
            #(
              "games",
              json.array(rows, fn(row) {
                json.object([
                  #("number", json.int(row.game_number)),
                  #("entries", raw.json(row.entries_json)),
                ])
              }),
            ),
          ]),
        ),
      ),
    ]),
  )
}

/// The seats an account owns, by player id: what puts the badge beside a
/// name on the replay. Which account is never said.
fn accounts_json(setup: Option(Setup)) -> json.Json {
  let owned = case setup {
    Some(setup) ->
      list.filter_map(setup.seats, fn(s) {
        case s.3 {
          "" -> Error(Nil)
          _ -> Ok(s.0)
        }
      })
    None -> []
  }
  json.array(owned, json.string)
}

/// Everything a record says about a room other than its games: who played
/// which colour, the match length, the position it opened from. It is the
/// same for the first turn and the last, so it comes from the room's game
/// started and left alone, never from its log.
fn head_fields(setup: Setup) -> Result(List(#(String, json.Json)), Nil) {
  use started <- result.try(
    host.start(
      setup.slug,
      setup.format,
      list.map(setup.seats, fn(s) { #(s.0, s.1) }),
      setup.seed,
      host.clock_control(setup.clock),
      0,
    )
    |> result.replace_error(Nil),
  )
  use record <- result.try(instance.record(started) |> option.to_result(Nil))
  use fields <- result.try(
    json.parse(
      json.to_string(record),
      decode.dict(decode.string, decode.dynamic),
    )
    |> result.replace_error(Nil),
  )
  Ok(
    fields
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.filter(fn(pair) { pair.0 != "games" })
    |> list.map(fn(pair) { #(pair.0, raw.json(raw.text(pair.1))) }),
  )
}

/// Which way the board faces for a room read from its rows: the seat this
/// caller holds, if any, else the first. Held means the one holder rule
/// (`rooms/seat.holder`), the same as a live room: an owned seat is its
/// account's from any browser, and nobody else's whatever guest is on it.
fn stored_viewer(setup: Setup, session: Session) -> #(String, Bool) {
  let seats =
    list.map(setup.seats, fn(s) {
      seat.Seat(
        player_id: s.0,
        guest_id: some_unless_empty(s.2),
        user_id: some_unless_empty(s.3),
      )
    })
  case seat.held_by(seats, session), setup.seats {
    Some(player_id), _ -> #(player_id, True)
    None, [first, ..] -> #(first.0, False)
    None, [] -> #("", False)
  }
}

fn some_unless_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

fn live_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
) -> Result(String, ApiError) {
  use game <- result.try(room(ctx, slug, game_id))
  let #(player_id, seated) = viewer(ctx, game, game_id, session)
  case instance.record(game) {
    None -> Error(error.NotFound("This game keeps no record"))
    Some(record) ->
      Ok(
        envelope.ok([
          #("slug", json.string(slug)),
          #("id", json.string(game_id)),
          // The seat the board faces to begin with: the reader's own, so a
          // replay sits them where they played, else the seat that played
          // first.
          #("you", json.string(player_id)),
          // Whether that seat is really the reader's: a reader who holds no
          // seat here is looking at somebody else's game.
          #("seated", json.bool(seated)),
          #("accounts", accounts_json(ctx.records.setup(game_id))),
          #("record", record),
        ]),
      )
  }
}

/// The running game at a room playing `slug`, for anyone: a record is every
/// committed turn, which was on the board for both players and any
/// spectator, so a replay asks no one who they are. A room that is not
/// there, or a slug that is not its game, is the one `not_found_message`.
pub fn room(
  ctx: Ctx,
  slug: String,
  game_id: String,
) -> Result(Instance, ApiError) {
  let not_found = error.NotFound(not_found_message)
  case rooms.lookup(ctx, game_id) {
    None -> Error(not_found)
    Some(_) ->
      case ctx.rooms.slug_of(game_id) == Some(slug) {
        False -> Error(not_found)
        True ->
          ctx.rooms.game(game_id)
          |> result.replace_error(not_found)
      }
  }
}

/// Which way the board faces, and whether that seat is the reader's own:
/// the seat this guest holds, if they hold one here, else the seat that
/// played first. It is an orientation, never a key -- the reader can turn
/// the board over anyway.
pub fn viewer(
  ctx: Ctx,
  game: Instance,
  game_id: String,
  session: Session,
) -> #(String, Bool) {
  case seated_game(ctx, game_id, session) {
    Ok(#(player_id, _)) -> #(player_id, True)
    Error(_) ->
      case instance.seats(game) {
        [first, ..] -> #(first.id, False)
        [] -> #("", False)
      }
  }
}

/// The seat this caller holds at a room playing `slug`: its player id and
/// the running game. A caller at no seat here -- a stranger with the code,
/// a visitor with no guest cookie at all -- is the one `not_found_message`,
/// the same answer a room that is not there gives, so nobody learns
/// anything about a room they are not sitting at.
pub fn seat(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
) -> Result(#(String, Instance), ApiError) {
  let not_found = error.NotFound(not_found_message)
  case rooms.lookup(ctx, game_id) {
    None -> Error(not_found)
    Some(_) ->
      case ctx.rooms.slug_of(game_id) == Some(slug) {
        False -> Error(not_found)
        True ->
          seated_game(ctx, game_id, session)
          |> result.replace_error(not_found)
      }
  }
}

/// The running game behind the seat this session holds, if it holds one --
/// by guest, or by the account that owns the seat. A session with neither
/// holds nothing, and never asks the room.
fn seated_game(
  ctx: Ctx,
  game_id: String,
  session: Session,
) -> Result(#(String, Instance), Nil) {
  case session.guest_id, session.user_id {
    None, None -> Error(Nil)
    _, _ ->
      ctx.rooms.seated_game(game_id, session.guest_id, session.user_id)
      |> result.replace_error(Nil)
  }
}
