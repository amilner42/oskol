//// GET /papi/games/:slug/rooms/:id/record?t=<seat token>
////
//// A game's whole record, for the players at its table: every game of the
//// match with every entry, where the scene carries only the game on the
//// board (so every update stays bounded by one game). The client asks for
//// it when a player opens a finished game; replay and analysis will read
//// it too. What it holds is the game's to decide (`Game.record`, public to
//// every seat); who may read it is decided here.
////
//// It reads the live room -- rehydrated from its seed and log first, like
//// every other lookup, if only the database has it -- rather than replaying
//// the log itself: the room already holds the state, and includes any step
//// the write-behind has not put on disk yet.

import gamekit/instance.{type Instance}
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/handlers/rooms

/// Nothing to read. The same answer for a room that is not there, a slug
/// that is not its game, and a token that opens no seat in it, so a caller
/// learns nothing about a room it cannot sit at -- the game channel refuses
/// the same way.
pub const not_found_message = "No record for that game"

pub fn record_json(
  ctx: Ctx,
  slug: String,
  game_id: String,
  token: String,
) -> Result(String, ApiError) {
  use #(player_id, game) <- result.try(seat(ctx, slug, game_id, token))
  case instance.record(game) {
    None -> Error(error.NotFound("This game keeps no record"))
    Some(record) ->
      Ok(
        envelope.ok([
          #("slug", json.string(slug)),
          #("id", json.string(game_id)),
          // The seat the token opens: a replay sits its reader where they
          // played.
          #("you", json.string(player_id)),
          #("record", record),
        ]),
      )
  }
}

/// The seat a token opens at a room playing `slug`: its player id and the
/// running game. Anything else is the one `not_found_message`, so a caller
/// learns nothing about a room it cannot sit at.
pub fn seat(
  ctx: Ctx,
  slug: String,
  game_id: String,
  token: String,
) -> Result(#(String, Instance), ApiError) {
  let not_found = error.NotFound(not_found_message)
  case token, rooms.lookup(ctx, game_id) {
    "", _ -> Error(not_found)
    _, None -> Error(not_found)
    _, Some(_) ->
      case ctx.rooms.slug_of(game_id) == Some(slug) {
        False -> Error(not_found)
        True ->
          ctx.rooms.seated_game(game_id, token)
          |> result.replace_error(not_found)
      }
  }
}
