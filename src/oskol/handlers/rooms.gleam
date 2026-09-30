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
import oskol/rooms/seat

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

/// Who the creator wants across the table: a friend they send the link to,
/// or the bot, which sits down at once and the game starts.
pub type Opponent {
  AFriend
  TheBot
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

/// Create a room, set it up, and seat the creator in it. Against the bot the
/// other seat is filled in the same breath, so the answer is a game already
/// under way rather than a link to send.
pub fn create(
  ctx: Ctx,
  session: Session,
  slug: String,
  setup: Setup,
  name: String,
  opponent: Opponent,
) -> Result(Seated, CreateError) {
  case display_name.clean(name) {
    Error(message) -> Error(Rejected(message))
    Ok(name) ->
      case opponent, display_name.is_bot_name(name) {
        // One table, two names: the room refuses a name it already has, so a
        // player called Sage would keep the bot from sitting down at all.
        TheBot, True ->
          Error(Rejected(
            display_name.bot_name
            <> " is the bot's name. Pick another one to play it.",
          ))
        _, _ ->
          case create_room(ctx, slug, attempts()) {
            Error(reason) -> Error(Unavailable(reason))
            Ok(game_id) -> {
              ctx.rooms.subscribe(game_id)

              case ctx.rooms.configure(game_id, setup) {
                Error(reason) -> Error(Rejected(errors.message(reason)))
                Ok(Nil) ->
                  case
                    ctx.rooms.join(
                      game_id,
                      name,
                      session.guest_id,
                      session.user_id,
                    )
                  {
                    Error(reason) -> Error(Rejected(errors.message(reason)))
                    Ok(seat) -> {
                      identity.remember(ctx, session, name)
                      sit_opponent(ctx, game_id, name, seat, opponent)
                    }
                  }
              }
            }
          }
      }
  }
}

/// The other seat, where the creator asked for the bot in it. A room that
/// will not have the bot is a room with nobody to play: better to say so
/// than to hand back a table that can never start.
fn sit_opponent(
  ctx: Ctx,
  game_id: String,
  name: String,
  seat: room.Seat,
  opponent: Opponent,
) -> Result(Seated, CreateError) {
  case opponent {
    AFriend -> Ok(seated(game_id, name, seat))
    TheBot ->
      case ctx.rooms.seat_bot(game_id, display_name.bot_name) {
        Error(reason) -> Error(Rejected(errors.message(reason)))
        // The bot filled the table, so the game started with it: the answer
        // is that game, under the creator's own seat.
        Ok(bot) ->
          Ok(seated(game_id, name, room.Seat(..seat, started: bot.started)))
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

          case
            ctx.rooms.join(game_id, name, session.guest_id, session.user_id)
          {
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

/// Take a seat back from the invite link. The seat passes to the claiming
/// guest, so it is theirs from here: whoever sat there before holds it no
/// longer. Only a seat whose player is away can be claimed, which is the
/// room's own rule.
pub fn claim(
  ctx: Ctx,
  session: Session,
  game_id: String,
  player_id: String,
) -> Result(Seated, JoinError) {
  // The table is read before the seat is claimed: afterwards the seat is
  // no longer one of the empty ones, and its name would be gone with it.
  case table(ctx, game_id) {
    None -> Error(Gone(gone_message))
    Some(table) -> {
      ctx.rooms.subscribe(game_id)

      case
        ctx.rooms.claim(game_id, player_id, session.guest_id, session.user_id)
      {
        Ok(seat) -> Ok(seated(game_id, seat_name(table, player_id), seat))
        Error(reason) -> Error(Refused(errors.message(reason)))
      }
    }
  }
}

// ---------- Closing a lobby ----------

/// Close a room nobody joined. A lobby a friend never opens has no way of
/// ending on its own: nothing prunes rooms, so it sits in LIVE GAMES for
/// ever unless the player who made it says it is over.
///
/// Only a lobby. A room with a game in it is the table's business: a game
/// in play is left by resigning, and unlimited play is ended between games
/// by the `close` action, which the game itself decides on (a match to a
/// target is never closable -- it ends when somebody reaches it).
///
/// Nothing a stranger presses may rebuild a room from its log. A lookup
/// rehydrates, so the row answers first: it says whether there is a room at
/// all, whether it has a game in it (in which case nothing needs waking),
/// and -- for a cold lobby -- whether this browser holds a seat there.
///
/// A room that is already live is asked directly, because asking it wakes
/// nothing and its memory is the newer copy: the row is written behind, so
/// a lobby made a moment ago may not carry its seat yet. Either way the
/// room's own check is the one that decides.
pub fn close(
  ctx: Ctx,
  session: Session,
  game_id: String,
) -> Result(Nil, JoinError) {
  case ctx.persistence.room(game_id) {
    None -> Error(Gone(gone_message))
    Some(row) ->
      case row.status {
        "waiting" ->
          case ctx.rooms.find(game_id) {
            Some(_) -> shut(ctx, session, game_id)
            None ->
              case held_in(row, session) {
                False -> Error(Refused(errors.message(errors.NoSeat)))
                True ->
                  case ctx.rooms.resume(game_id) {
                    None -> Error(Gone(gone_message))
                    Some(_) -> shut(ctx, session, game_id)
                  }
              }
          }
        // Closed already: a second press, or a retry of a request that
        // timed out after the write landed, is the same yes. Nothing is
        // woken to say so -- the rehydrator would refuse the row anyway.
        status if status == closed_status -> only_a_seat(row, session, Ok(Nil))
        // There is a game in it, or there was. A game is left at the table
        // -- by resigning, or between the games of unlimited play by
        // ending the session -- and a room that is over is over.
        _ ->
          only_a_seat(
            row,
            session,
            Error(Refused(errors.message(errors.GameAlreadyStarted))),
          )
      }
  }
}

fn shut(ctx: Ctx, session: Session, game_id: String) -> Result(Nil, JoinError) {
  case ctx.rooms.close(game_id, session.guest_id, session.user_id) {
    Ok(Nil) -> Ok(Nil)
    // The room stopped between the lookup and the close: nothing was
    // written, and there is nothing to fix by pressing again.
    Error(errors.UnknownGame) -> Error(Gone(gone_message))
    Error(reason) -> Error(Refused(errors.message(reason)))
  }
}

/// Does this browser hold a seat in the room as the row has it? A bot's
/// seat carries neither a guest nor an account, so it answers nobody --
/// which is what keeps a browser with no cookie of its own from matching it.
fn held_in(row: room.ActiveRoom, session: Session) -> Bool {
  seat.held_by(seat.of_rows(row.seats), session) != None
}

/// The verdict, but only for a seat: wherever the row alone decides,
/// somebody who holds no seat there reads the one sentence a stranger
/// reads anywhere else, and learns nothing about the room.
fn only_a_seat(
  row: room.ActiveRoom,
  session: Session,
  verdict: Result(Nil, JoinError),
) -> Result(Nil, JoinError) {
  case held_in(row, session) {
    True -> verdict
    False -> Error(Refused(errors.message(errors.NoSeat)))
  }
}

/// The status a closed lobby's row carries. Its own, not `finished`: no
/// game was played there, so it belongs in no recent list, no rating and no
/// replay -- and the rehydrator refuses it, so the code opens nothing ever
/// again. `Oskol.Persistence.mark_closed/1` writes it.
pub const closed_status = "closed"

/// A reclaimed seat keeps the name it was taken under; the room knows it,
/// and it is not ours to change.
fn seat_name(table: Table, player_id: String) -> String {
  case list.find(table.disconnected, fn(seat) { seat.0 == player_id }) {
    Ok(seat) -> seat.1
    Error(_) -> ""
  }
}

fn seated(game_id: String, name: String, seat: room.Seat) -> Seated {
  Seated(
    game_id: game_id,
    player_id: seat.player_id,
    name: name,
    started: seat.started,
  )
}
