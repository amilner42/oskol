//// The universal decks, for the practice home and a run through one.
////
////   GET  /papi/decks             every deck that has positions, with the
////                                caller's standing on each (an account's)
////   GET  /papi/decks/:id         a session: what to play next
////   POST /papi/decks/:id/join    {tz} -- add the deck, then the session
////   POST /papi/decks/:id/more    KEEP GOING: the set's pace again, then the
////                                session (an account that added it)
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
  session_all_json(ctx, session, id, False)
}

/// The same, with PRACTICE ANYWAY: `all` asks, only when an account's
/// queue for the set is empty, for its positions in rotation soonest due
/// first, nothing written. Ignored while the queue has anything in it, and
/// for anybody walking the set (whose walk is never empty).
pub fn session_all_json(
  ctx: Ctx,
  session: Session,
  id: String,
  all: Bool,
) -> Result(String, ApiError) {
  use d <- result.try(offered(ctx, id))
  Ok(session_body(ctx, session, d, all))
}

pub const not_joined_message = "Add it first."

/// KEEP GOING through a set: the set's own pace again of positions never
/// shown, over the day's budget, then the session. An account that has
/// added the set only: there is nothing to start for anybody else.
pub fn more_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use d <- result.try(offered(ctx, id))
  use uid <- result.try(
    session.user_id
    |> option.to_result(error.Conflict("sign_in", sign_in_message)),
  )
  let caps = decks.practice(ctx, d)
  // Added means the set's ladder holds something: one read of its totals.
  use _ <- result.try(case caps.summary(uid, []) {
    [row, ..] if row.count > 0 -> Ok(Nil)
    _ -> Error(error.Conflict("not_joined", not_joined_message))
  })
  let _ = caps.start_new(uid, d.new_per_day)
  Ok(session_body(ctx, session, d, False))
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
  Ok(session_body(ctx, session, d, False))
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
fn session_body(ctx: Ctx, session: Session, d: Deck, all: Bool) -> String {
  let standing = option.map(session.user_id, decks.standing(ctx, d, _))
  let #(entries, today) = case session.user_id, standing {
    Some(uid), Some(s) ->
      case decks.joined(s) {
        True -> #(
          case decks.queue(ctx, d, uid), all {
            [], True -> decks.anyway(ctx, d, uid)
            queued, _ -> queued
          },
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
