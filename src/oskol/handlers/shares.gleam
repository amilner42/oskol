//// Share with my mistake.
////
////     POST /papi/puzzles/:id/shares           mint a story link
////     /puzzles/:id?s=<token>                   the same page, with a story
////
//// A puzzle is anonymous: the page, the head and the reveal name nobody.
//// The story is the sharer's choice, and it names only them. "Arie got
//// this wrong. What's your play?" is what the tokened link unfurls as, and
//// "Arie played 24/23 13/11 (a bad move) and lost 2 points." is what the
//// friend reads once they have tried it themselves -- never before, because
//// the story says what was played and how it was graded, and that is the
//// answer's neighbourhood.
////
//// **Only the seat that made the mistake may share it.** The one holder
//// rule (`rooms/seat`) says who holds a seat; the source says which seat
//// made the decision; a share is minted only when they are the same seat.
//// The opponent, who sees the memory line, may not: it is not their
//// mistake to tell. A stranger holds nothing and gets the same refusal.
////
//// **A token is nothing but a token.** It is looked up whole, checked
//// against the puzzle it was minted for, and ignored -- silently, the page
//// is the plain one -- where it is unknown, spent on some other puzzle, or
//// simply absent. Nothing a caller types into `?s=` is an error, and
//// nothing in it is a credential: the story it opens is what the sharer
//// chose to tell anyone with the link.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/puzzles as caps
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/puzzles.{type Question}
import oskol/puzzles/game_over
import oskol/rooms/seat

pub const not_found_message = "No such puzzle"

/// One sentence, the same for the opponent and for a stranger: neither may
/// tell this story, and the sentence does not say which of the two the
/// caller is.
pub const not_yours_message = "Only the player who made this mistake can share it"

/// How long a token is: twelve characters of the room-code alphabet, which
/// is 32^12 -- a token is a link anyone may open, not a seat, but it
/// should not be guessable either.
pub const token_length = 12

// ---------- POST /papi/puzzles/:id/shares ----------

/// Mint the caller's story link for this puzzle, or hand back the one they
/// already have.
///
/// The sources of this puzzle in rooms the caller could be seated in come
/// from `puzzles.mine` (a coarse, indexed narrowing); the holder rule then
/// says which seat the caller really holds in each, and only a room where
/// that seat is the source's own seat qualifies. The sharer is recorded as
/// whatever holds the seat -- the account that owns it, else the guest that
/// took it -- so an account's link is one link from every browser, and the
/// name is frozen now, from the seat's display name as it is today.
pub fn mint_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  use _ <- result.try(
    ctx.puzzles.get(id)
    |> option.to_result(error.NotFound(not_found_message)),
  )
  use own <- result.try(
    own_source(ctx, session, id)
    |> option.to_result(error.Forbidden(not_yours_message)),
  )
  let #(room, sharer) = own
  let token =
    ctx.puzzles.mint_share(
      id,
      room.source.id,
      sharer,
      name_of(room, room.source.player_id),
      ctx.ids.share_token(),
    )
  Ok(
    envelope.ok([
      #("token", json.string(token)),
      #("url", json.string(path(id, token))),
    ]),
  )
}

/// The room where the caller holds the very seat that made this mistake,
/// and the id that holds it there (the account for an owned seat, the
/// guest for an unowned one). Newest game first, so a position reached
/// twice tells the latest story.
fn own_source(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Option(#(caps.SourceRoom, String)) {
  case session.guest_id, session.user_id {
    None, None -> None
    _, _ ->
      ctx.puzzles.mine(
        id,
        option.unwrap(session.guest_id, ""),
        option.unwrap(session.user_id, ""),
      )
      |> list.filter_map(fn(room) {
        let seats = seats_of(room)
        case seat.held_by(seats, session) {
          Some(player_id) if player_id == room.source.player_id ->
            case list.find(seats, fn(s) { s.player_id == player_id }) {
              Ok(seat.Seat(user_id: Some(owner), ..)) -> Ok(#(room, owner))
              Ok(seat.Seat(guest_id: Some(guest), ..)) -> Ok(#(room, guest))
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> list.first
      |> option.from_result
  }
}

/// The tokened link, site-relative: the client puts its origin in front,
/// exactly as it does for the clean one.
pub fn path(id: String, token: String) -> String {
  "/puzzles/" <> id <> "?s=" <> token
}

// ---------- The story a token opens ----------

/// What the friend is told, once they have tried: who, what they played,
/// how it was graded, and how that game went for them.
pub type Story {
  Story(
    name: String,
    /// "move", "double" or "take".
    kind: String,
    played: String,
    grade: String,
    equity_lost: Float,
    /// The day the game ended, as "2026-09-12".
    date: String,
    /// Whether the sharer won that game, and by how many points; nothing
    /// where the record has no game-over line.
    result: Option(#(Bool, Int)),
  )
}

/// The share `token` names for `puzzle_id`, or nothing: an empty token,
/// one nobody minted, or one minted for some other puzzle all open the
/// plain page. One row read, and none at all for a page with no token.
fn share_for(ctx: Ctx, puzzle_id: String, token: String) -> Option(caps.Share) {
  case token {
    "" -> None
    _ ->
      case ctx.puzzles.share(token) {
        Some(share) if share.puzzle_id == puzzle_id -> Some(share)
        _ -> None
      }
  }
}

/// Who shared this puzzle under `token`, by the name frozen on the link:
/// all the head needs, so it reads nothing else.
pub fn sharer(ctx: Ctx, puzzle_id: String, token: String) -> Option(String) {
  share_for(ctx, puzzle_id, token)
  |> option.map(fn(share) { share.shared_name })
}

/// The story `token` tells about `puzzle_id`, or nothing. The result comes
/// from the game's record, read only here, on the reveal that shows it.
pub fn story(ctx: Ctx, puzzle_id: String, token: String) -> Option(Story) {
  use share <- option.then(share_for(ctx, puzzle_id, token))
  let source = share.source
  Some(
    Story(
      name: share.shared_name,
      kind: source.kind,
      played: source.played,
      grade: source.grade,
      equity_lost: source.equity_lost,
      date: source.date,
      result: case ctx.records.entries_of(source.game_id, source.game_number) {
        None -> None
        Some(entries) ->
          game_over.of(entries)
          |> option.map(fn(over) { #(over.0 == source.player_id, over.1) })
      },
    ),
  )
}

/// The story as the attempt's answer carries it: the facts, and the two
/// sentences already written, so the page and the head cannot drift.
pub fn story_json(
  ctx: Ctx,
  puzzle_id: String,
  question: Question,
  token: String,
) -> Json {
  case story(ctx, puzzle_id, token) {
    None -> json.null()
    Some(s) ->
      json.object([
        #("name", json.string(s.name)),
        #("kind", json.string(s.kind)),
        #("played", json.string(s.played)),
        #("grade", json.string(s.grade)),
        #("equity_lost", json.float(s.equity_lost)),
        #("date", json.string(s.date)),
        #("result", case s.result {
          None -> json.null()
          Some(#(won, points)) ->
            json.object([
              #("won", json.bool(won)),
              #("points", json.int(points)),
            ])
        }),
        #("headline", json.string(headline(s.name, question))),
        #("line", json.string(line(s))),
      ])
  }
}

/// What the tokened link unfurls as: "Arie got this wrong. What's your
/// play?" -- the name, and the question the plain prompt ends on ("Double?",
/// "Take?"), asked from the same side the prompt asks it.
pub fn headline(name: String, question: Question) -> String {
  let prompt = puzzles.prompt(question)
  let question_part =
    string.split(prompt, ". ")
    |> list.last
    |> result.unwrap(prompt)
  name <> " got this wrong. " <> question_part
}

/// "Arie played 24/23 13/11 (a bad move) and lost 2 points." The sharer's
/// name and the sharer's decision; the opponent is not in it, by rule.
pub fn line(story: Story) -> String {
  story.name
  <> " "
  <> decision(story)
  <> " ("
  <> graded(story)
  <> ")"
  <> outcome(story)
  <> "."
}

fn decision(story: Story) -> String {
  case story.kind, story.played {
    "double", "no_double" -> "didn't double"
    "double", "double" -> "doubled"
    "double", "redouble" -> "redoubled"
    "take", "take" -> "took"
    "take", "pass" -> "passed"
    _, played -> "played " <> played
  }
}

fn graded(story: Story) -> String {
  let thing = case story.kind {
    "move" -> "move"
    _ -> "decision"
  }
  case story.grade {
    "doubtful" -> "a dubious " <> thing
    "bad" -> "a bad " <> thing
    "very_bad" -> "a very bad " <> thing
    other -> other
  }
}

fn outcome(story: Story) -> String {
  case story.result {
    None -> ""
    Some(#(True, _)) -> " and won anyway"
    Some(#(False, points)) ->
      " and lost "
      <> int.to_string(points)
      <> case points {
        1 -> " point"
        _ -> " points"
      }
  }
}

// ---------- The seats, as the holder rule reads them ----------

fn seats_of(room: caps.SourceRoom) -> List(seat.Seat) {
  list.map(room.seats, fn(s) {
    seat.Seat(
      player_id: s.0,
      guest_id: unless_empty(s.2),
      user_id: unless_empty(s.3),
    )
  })
}

fn unless_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

fn name_of(room: caps.SourceRoom, player_id: String) -> String {
  list.find(room.seats, fn(s) { s.0 == player_id })
  |> result.map(fn(s) { s.1 })
  |> result.unwrap("")
}
