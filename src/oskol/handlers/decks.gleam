//// The universal decks, for the practice home and a run through one.
////
////   GET  /papi/decks             every deck that has positions, with the
////                                caller's standing on each (an account's)
////   GET  /papi/decks/:id         a session: what to play next
////   POST /papi/decks/:id/join    {tz} -- add the deck, then the session
////
//// Anybody may play a deck: a guest, a stranger, an account that has not
//// added it. They get it in its own order, unscheduled, and nothing is
//// written -- the same promise a guest's mistakes make. Adding it is an
//// account's, and is what puts it on the ladder.
////
//// A deck nobody has built yet (no positions) is not offered at all, so the
//// page cannot show a set of puzzles with nothing in it.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/practice/deck
import oskol/practice/decks.{type Deck}

pub const sign_in_message = "Sign in to keep your place in these."

pub fn list_json(ctx: Ctx, session: Session) -> String {
  let offered =
    decks.all()
    |> list.filter_map(fn(d) {
      case ctx.decks.size(d.id) {
        0 -> Error(Nil)
        size ->
          Ok(decks.deck_json(
            d,
            size,
            option.map(session.user_id, decks.standing(ctx, d, _)),
          ))
      }
    })
  envelope.ok([
    #("decks", json.preprocessed_array(offered)),
    #("patched_level", json.int(deck.patched_level)),
  ])
}

pub fn session_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use d <- result.try(offered(ctx, id))
  Ok(session_body(ctx, session, d))
}

pub fn join_json(
  ctx: Ctx,
  session: Session,
  id: String,
  tz: String,
) -> Result(String, ApiError) {
  use d <- result.try(offered(ctx, id))
  use uid <- result.try(
    session.user_id
    |> option.to_result(error.Conflict("sign_in", sign_in_message)),
  )
  use _ <- result.try(
    decks.enroll(ctx, d, uid, tz)
    |> result.map_error(fn(e) { error.Internal(deck.message(e)) }),
  )
  Ok(session_body(ctx, session, d))
}

fn offered(ctx: Ctx, id: String) -> Result(Deck, ApiError) {
  case decks.find(id) {
    Ok(d) ->
      case ctx.decks.size(d.id) {
        0 -> Error(error.NotFound(decks.unknown_deck_message))
        _ -> Ok(d)
      }
    Error(Nil) -> Error(error.NotFound(decks.unknown_deck_message))
  }
}

/// An account that has added the deck gets its queue; everybody else walks
/// the deck in its order, with nothing kept.
fn session_body(ctx: Ctx, session: Session, d: Deck) -> String {
  let standing = option.map(session.user_id, decks.standing(ctx, d, _))
  let #(entries, today) = case session.user_id, standing {
    Some(uid), Some(s) ->
      case decks.joined(s) {
        True -> #(
          decks.queue(ctx, d, uid),
          Some(deck.today_json(deck.today(decks.in_deck(ctx, d), uid))),
        )
        False -> #(decks.walk(ctx, d), None)
      }
    _, _ -> #(decks.walk(ctx, d), None)
  }
  envelope.ok([
    #("deck", decks.deck_json(d, ctx.decks.size(d.id), standing)),
    #("puzzles", json.array(entries, decks.entry_json)),
    #("today", option.unwrap(today, json.null())),
  ])
}
