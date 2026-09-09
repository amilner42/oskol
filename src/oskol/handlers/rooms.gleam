//// The room lifecycle: minting a code, finding a room, and the two ways a
//// player takes a seat. Ports `Oskol.Game` and the decision half of
//// `LandingLive`'s create and join events; the LiveView and the JSON API
//// both come through here, so they cannot drift.

import gleam/list
import gleam/option.{type Option, None, Some}
import oskol/caps/rooms.{AlreadyStarted, SpawnFailed}
import oskol/core/ctx.{type Ctx}
import oskol/core/session.{type Session}
import oskol/guests/identity
import oskol/rooms/errors.{type RoomError}
import oskol/rooms/invite.{type InviteStep}
import oskol/rooms/name as display_name
import oskol/rooms/room.{type Room, type Seated, type Setup, type Table, Seated}

/// How many codes to try before giving up. A function, not a constant, so
/// the Elixir facade can read it instead of keeping its own copy.
pub fn attempts() -> Int {
  50
}

/// An invite to a room that is gone (idle for an hour, or a restart) says
/// so, rather than quietly seating the guest as the host of a fresh game.
pub const gone_message = "That game is over. Start a new one and send a fresh link."

pub type CreateError {
  /// Show this sentence on the form; the visitor can fix it.
  Rejected(message: String)
  /// No room could be minted at all. Nothing the visitor did.
  Unavailable(reason: RoomError)
}

pub type JoinError {
  /// Show this sentence and stay on the join form.
  Refused(message: String)
  /// The table moved on (it filled, or the game started): work out what the
  /// invite link offers now, from scratch.
  Reroute
  /// No live room answers to this code any more.
  Gone(message: String)
}

// ---------- Codes and lookup ----------

/// Mint a fresh code and start a room for `slug` under it.
///
/// The registry's unique keys make the claim atomic: a collision with a live
/// room comes back as `AlreadyStarted` and we mint again. Persisted games
/// (finished ones are kept) also hold their codes, so a code with a row is
/// taken too.
pub fn create_room(
  ctx: Ctx,
  slug: String,
  attempts_left: Int,
) -> Result(String, RoomError) {
  case attempts_left <= 0 {
    True -> Error(errors.NoFreeId)
    False -> {
      let game_id = ctx.ids.game_code()

      case ctx.persistence.game_exists(game_id) {
        True -> create_room(ctx, slug, attempts_left - 1)
        False ->
          case ctx.rooms.spawn(game_id, slug) {
            Ok(Nil) -> Ok(game_id)
            Error(AlreadyStarted) -> create_room(ctx, slug, attempts_left - 1)
            Error(SpawnFailed(reason)) -> Error(reason)
          }
      }
    }
  }
}

/// The live room for a code. When no process answers but the database still
/// has the game, the room is rehydrated before answering — this is how games
/// survive deploys and idle shutdowns.
pub fn lookup(ctx: Ctx, game_id: String) -> Option(Room) {
  case ctx.rooms.find(game_id) {
    Some(room) -> Some(room)
    None -> ctx.rooms.resume(game_id)
  }
}

/// Resolve a game code to the slug of its live room, so a bare code can be
/// turned into the game's normal invite link. Says only whether a live room
/// answers to the code — nothing else about it.
pub fn lookup_slug(ctx: Ctx, game_id: String) -> Option(String) {
  case lookup(ctx, game_id) {
    Some(_) -> ctx.rooms.slug_of(game_id)
    None -> None
  }
}

/// The table behind an invite link, if a room still answers to the code.
/// Looking it up rehydrates a room that was only sleeping.
pub fn table(ctx: Ctx, game_id: String) -> Option(Table) {
  case lookup(ctx, game_id) {
    Some(_) -> ctx.rooms.table(game_id)
    None -> None
  }
}

/// What that invite link offers.
pub fn offer(ctx: Ctx, game_id: String) -> #(InviteStep, Option(Table)) {
  let table = table(ctx, game_id)
  #(invite.step(table), table)
}

// ---------- Taking a seat ----------

/// Create a room, set it up, and seat the creator in it.
pub fn create(
  ctx: Ctx,
  session: Session,
  slug: String,
  setup: Setup,
  name: String,
) -> Result(Seated, CreateError) {
  case display_name.clean(name) {
    Error(message) -> Error(Rejected(message))
    Ok(name) ->
      case create_room(ctx, slug, attempts()) {
        Error(reason) -> Error(Unavailable(reason))
        Ok(game_id) -> {
          ctx.rooms.subscribe(game_id)

          case ctx.rooms.configure(game_id, setup) {
            Error(reason) -> Error(Rejected(errors.message(reason)))
            Ok(Nil) ->
              case ctx.rooms.join(game_id, name, session.guest_id) {
                Error(reason) -> Error(Rejected(errors.message(reason)))
                Ok(seat) -> {
                  identity.remember(ctx, session, name)
                  Ok(seated(game_id, name, seat))
                }
              }
          }
        }
      }
  }
}

/// Take a seat in a room somebody else made. Joining never creates one.
pub fn join(
  ctx: Ctx,
  session: Session,
  game_id: String,
  name: String,
) -> Result(Seated, JoinError) {
  case display_name.clean(name) {
    Error(message) -> Error(Refused(message))
    Ok(name) ->
      case lookup(ctx, game_id) {
        None -> Error(Gone(gone_message))
        Some(_) -> {
          ctx.rooms.subscribe(game_id)

          case ctx.rooms.join(game_id, name, session.guest_id) {
            Ok(seat) -> {
              identity.remember(ctx, session, name)
              Ok(seated(game_id, name, seat))
            }
            // A name is not a seat: a clash is just a clash, and the table
            // decides on its own whether there is anything else to offer.
            Error(errors.NameTaken) ->
              Error(Refused(errors.message(errors.NameTaken)))
            Error(errors.GameFull) -> Error(Reroute)
            Error(errors.GameAlreadyStarted) -> Error(Reroute)
            Error(reason) -> Error(Refused(errors.message(reason)))
          }
        }
      }
  }
}

/// Take a seat back from the invite link. The seat's token is rotated by
/// the room, so whatever link its previous occupant held is dead and only
/// the one we are about to hand out opens it.
pub fn claim(
  ctx: Ctx,
  game_id: String,
  player_id: String,
) -> Result(Seated, JoinError) {
  // The table is read before the seat is claimed: afterwards the seat is
  // no longer one of the empty ones, and its name would be gone with it.
  case table(ctx, game_id) {
    None -> Error(Gone(gone_message))
    Some(table) -> {
      ctx.rooms.subscribe(game_id)

      case ctx.rooms.claim(game_id, player_id) {
        Ok(seat) -> Ok(seated(game_id, seat_name(table, player_id), seat))
        Error(reason) -> Error(Refused(errors.message(reason)))
      }
    }
  }
}

/// A reclaimed seat keeps the name it was taken under; the room knows it,
/// and it is not ours to change.
fn seat_name(table: Table, player_id: String) -> String {
  case list.key_find(table.disconnected, player_id) {
    Ok(name) -> name
    Error(_) -> ""
  }
}

fn seated(game_id: String, name: String, seat: room.Seat) -> Seated {
  Seated(
    game_id: game_id,
    player_id: seat.player_id,
    token: seat.token,
    name: name,
    started: seat.started,
  )
}
