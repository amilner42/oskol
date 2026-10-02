//// A player's own sets: made, named, filled and emptied by the account
//// that owns them, and practiced exactly as the universal sets are
//// (`handlers/decks`, `handlers/practice`) -- a `decks` row with an owner,
//// `deck_puzzles` rows for its positions, and a retain scope of its own.
////
////   GET    /papi/decks/mine                     the caller's sets
////   POST   /papi/decks/mine            {name}   make one
////   PATCH  /papi/decks/:id             {name}   rename it
////   DELETE /papi/decks/:id                      delete it
////   GET    /papi/decks/:id/puzzles              it, and what is in it
////   POST   /papi/decks/:id/puzzles     {puzzle_id}  put a position in
////   DELETE /papi/decks/:id/puzzles/:puzzle_id   take one out
////
//// A set is private. Every door but the list and making one names a set,
//// and a set that is not the caller's is not found -- the same 404 as an
//// id that names nothing, so nobody learns that it exists. A guest has no
//// sets: the list is empty and making one asks them to sign in.
////
//// To a player these are "sets"; in code and on the wire they are decks.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oskol/caps/decks.{type OwnDeck, IdTaken, Member, NameTaken} as _
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/handlers/puzzles as puzzles_handler
import oskol/practice/deck
import oskol/practice/decks.{type Deck}

/// New positions a day an own set introduces, like Openings.
pub const new_per_day = 5

/// How many live sets one account may have.
pub const most_sets = 50

/// The longest name, in characters, after trimming.
pub const longest_name = 40

pub const sign_in_message = "Sign in to make a set of your own."

pub const no_name_message = "Give it a name"

pub const long_name_message = "40 characters at most"

pub const name_taken_message = "You already have a set called that"

pub const too_many_message = "That is a lot of sets"

/// How many fresh ids to try before giving up. A collision in eight
/// characters of a 32-letter alphabet is one in a trillion; three in a row
/// is the database telling us something else.
const id_tries = 3

// ---------- GET /papi/decks/mine ----------

/// The caller's sets, oldest first, each with its size and the caller's
/// standing on it. Empty for a guest and a stranger.
pub fn mine_json(ctx: Ctx, session: Session) -> String {
  let sets = case session.user_id {
    Some(uid) -> list.map(decks.own(ctx, uid), set_json(ctx, _, uid))
    None -> []
  }
  envelope.ok([#("decks", json.preprocessed_array(sets))])
}

/// `GET /papi/decks/mine?puzzle=<id>`: the same list, each set saying
/// whether it holds that puzzle (`holds`) -- the save sheet's checks.
pub fn mine_holding_json(
  ctx: Ctx,
  session: Session,
  puzzle_id: String,
) -> String {
  let sets = case session.user_id {
    Some(uid) ->
      list.map(decks.own(ctx, uid), fn(set) {
        let holds =
          list.any(ctx.decks.members(set.id), fn(m) { m.puzzle_id == puzzle_id })
        json.object([#("holds", json.bool(holds)), ..set_fields(ctx, set, uid)])
      })
    None -> []
  }
  envelope.ok([#("decks", json.preprocessed_array(sets))])
}

// ---------- POST /papi/decks/mine ----------

pub fn create_json(
  ctx: Ctx,
  session: Session,
  name: String,
) -> Result(String, ApiError) {
  use uid <- result.try(signed_in(session))
  let mine = decks.own(ctx, uid)
  use name <- result.try(checked_name(name, mine, ""))
  use _ <- result.try(case list.length(mine) >= most_sets {
    True -> Error(error.Invalid("too_many_sets", too_many_message))
    False -> Ok(Nil)
  })
  use row <- result.try(create(ctx, uid, name, id_tries))
  Ok(envelope.ok([#("deck", set_json(ctx, decks.from_row(row), uid))]))
}

fn create(
  ctx: Ctx,
  uid: String,
  name: String,
  tries: Int,
) -> Result(OwnDeck, ApiError) {
  case ctx.decks.create(uid, ctx.ids.deck_id(), name, new_per_day) {
    Ok(row) -> Ok(row)
    Error(NameTaken) -> Error(error.Invalid("name_taken", name_taken_message))
    Error(IdTaken) ->
      case tries > 1 {
        True -> create(ctx, uid, name, tries - 1)
        False -> Error(error.Internal("no free set id"))
      }
  }
}

// ---------- PATCH /papi/decks/:id ----------

pub fn rename_json(
  ctx: Ctx,
  session: Session,
  id: String,
  name: String,
) -> Result(String, ApiError) {
  use #(uid, _, mine) <- result.try(owned(ctx, session, id))
  use name <- result.try(checked_name(name, mine, id))
  use row <- result.try(
    ctx.decks.rename(id, name)
    |> result.replace_error(error.Invalid("name_taken", name_taken_message)),
  )
  Ok(envelope.ok([#("deck", set_json(ctx, decks.from_row(row), uid))]))
}

// ---------- DELETE /papi/decks/:id ----------

/// Soft: the row leaves every list and every door, and what the owner
/// learned in it stays on its ladder, as a suspended card's does.
pub fn delete_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use _ <- result.try(owned(ctx, session, id))
  ctx.decks.delete(id)
  Ok(envelope.ok([]))
}

// ---------- GET /papi/decks/:id/puzzles ----------

/// The set, its standing, and its positions with the rung each stands on.
pub fn show_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use #(uid, set, _) <- result.try(owned(ctx, session, id))
  let cells = decks.shown_cells(set, decks.practice(ctx, set).cells(uid))
  Ok(
    envelope.ok([
      #("deck", set_json(ctx, set, uid)),
      #(
        "members",
        decks.members_json(
          ctx,
          set,
          cells,
          puzzles_handler.stored_question_json,
        ),
      ),
    ]),
  )
}

// ---------- POST /papi/decks/:id/puzzles ----------

/// Put a stored puzzle into the set, at the end, and onto its owner's
/// ladder at once, so it is due today as a new position. Idempotent: the
/// second time is `added: false` and changes nothing (beyond putting back
/// on the ladder a card that somehow is not there).
pub fn add_json(
  ctx: Ctx,
  session: Session,
  id: String,
  puzzle_id: String,
) -> Result(String, ApiError) {
  use #(uid, set, _) <- result.try(owned(ctx, session, id))
  use stored <- result.try(
    ctx.puzzles.get(puzzle_id)
    |> option.to_result(error.NotFound(puzzles_handler.not_found_message)),
  )
  let added = ctx.decks.add_member(set.id, stored.id)
  let member =
    Member(
      puzzle_id: stored.id,
      position: added.position,
      kind: stored.kind,
      question_json: stored.question_json,
    )
  use _ <- result.try(
    decks.enroll_one(ctx, set, uid, member)
    |> result.map_error(fn(e) { error.Internal(deck.message(e)) }),
  )
  Ok(
    envelope.ok([
      #("deck", set_json(ctx, set, uid)),
      #("added", json.bool(added.added)),
    ]),
  )
}

// ---------- DELETE /papi/decks/:id/puzzles/:puzzle_id ----------

/// Take a position out of the set. Its card is suspended rather than
/// dropped, so saving it again brings back the level it had. The card goes
/// first and the row second, so a remove that fails half-way is finished
/// by the next one; a position that is not in the set touches nothing.
pub fn remove_json(
  ctx: Ctx,
  session: Session,
  id: String,
  puzzle_id: String,
) -> Result(String, ApiError) {
  use #(uid, set, _) <- result.try(owned(ctx, session, id))
  case list.any(ctx.decks.members(set.id), fn(m) { m.puzzle_id == puzzle_id }) {
    True -> {
      let _ = decks.practice(ctx, set).suspend(uid, [puzzle_id])
      let _ = ctx.decks.remove_member(set.id, puzzle_id)
      Nil
    }
    False -> Nil
  }
  Ok(envelope.ok([#("deck", set_json(ctx, set, uid))]))
}

// ---------- Shared ----------

fn signed_in(session: Session) -> Result(String, ApiError) {
  session.user_id
  |> option.to_result(error.Conflict("sign_in", sign_in_message))
}

/// The caller's set by id, with the caller and all their sets (a rename
/// checks the name against the others). Anything else is not found.
fn owned(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(#(String, Deck, List(Deck)), ApiError) {
  let missing = error.NotFound(decks.unknown_deck_message)
  use uid <- result.try(session.user_id |> option.to_result(missing))
  let mine = decks.own(ctx, uid)
  use set <- result.try(
    list.find(mine, fn(d) { d.id == id }) |> result.replace_error(missing),
  )
  Ok(#(uid, set, mine))
}

/// A name as it is kept: trimmed, 1..40 characters, and not the name of
/// another of the caller's sets in any case. `except` is the set being
/// renamed, which may keep its own name or change only its case.
pub fn checked_name(
  name: String,
  mine: List(Deck),
  except: String,
) -> Result(String, ApiError) {
  let name = string.trim(name)
  let folded = string.lowercase(name)
  case string.length(name) {
    0 -> Error(error.Invalid("name_missing", no_name_message))
    n if n > longest_name ->
      Error(error.Invalid("name_too_long", long_name_message))
    _ ->
      case
        list.any(mine, fn(d) {
          d.id != except && string.lowercase(d.name) == folded
        })
      {
        True -> Error(error.Invalid("name_taken", name_taken_message))
        False -> Ok(name)
      }
  }
}

/// One set as the save sheet and the list read it.
fn set_json(ctx: Ctx, set: Deck, uid: String) -> Json {
  json.object(set_fields(ctx, set, uid))
}

fn set_fields(ctx: Ctx, set: Deck, uid: String) -> List(#(String, Json)) {
  [
    #("id", json.string(set.id)),
    #("name", json.string(set.name)),
    #("size", json.int(ctx.decks.size(set.id))),
    #("new_per_day", json.int(set.new_per_day)),
    #("standing", decks.standing_json(decks.standing(ctx, set, uid))),
  ]
}
