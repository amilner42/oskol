//// Share with my mistake, on stub capabilities: who may mint a story link,
//// what is written when they do, and the words a story is told in.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/ids as ids_caps
import oskol/caps/puzzles as puzzles_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/core/session.{type Session, Session}
import oskol/fakes
import oskol/handlers/shares as handler
import oskol/puzzles.{
  type Kind, type Question, Centered, Double, Move, Question, Take,
}

// ---------- The little database ----------

/// The share rows: #(source_id, shared_by, shared_name, token).
@external(erlang, "erlang", "put")
fn put_rows(key: String, value: List(#(Int, String, String, String))) -> Dynamic

@external(erlang, "erlang", "get")
fn rows_at(key: String) -> List(#(Int, String, String, String))

@external(erlang, "erlang", "put")
fn put_tokens(key: String, value: List(String)) -> Dynamic

@external(erlang, "erlang", "get")
fn tokens_at(key: String) -> List(String)

fn reset() -> Nil {
  let _ = put_rows("shares", [])
  let _ = put_tokens("tokens", ["TOKEN0000001", "TOKEN0000002"])
  Nil
}

// ---------- The rooms ----------

fn question(kind: Kind) -> Question {
  Question(
    kind: kind,
    board: list.repeat(0, 26),
    dice: case kind {
      Move -> Some(#(6, 4))
      _ -> None
    },
    cube_value: 1,
    cube_owner: Centered,
    away_mover: 3,
    away_opponent: 5,
    crawford: False,
    jacoby: False,
  )
}

fn source(
  kind: String,
  player_id: String,
  played: String,
) -> puzzles_caps.Source {
  puzzles_caps.Source(
    id: 7,
    puzzle_id: "p1",
    kind: kind,
    game_id: "000011",
    game_number: 2,
    turn: 3,
    seat: 0,
    player_id: player_id,
    played: played,
    equity_lost: 0.14,
    grade: "bad",
    date: "2026-09-12",
    question_json: "",
  )
}

fn room(
  seats: List(#(String, String, String, String)),
  source: puzzles_caps.Source,
) -> puzzles_caps.SourceRoom {
  puzzles_caps.SourceRoom(source: source, slug: "backgammon", seats: seats)
}

const guests_only = [
  #("p1", "Arie", "guest-a", ""),
  #("p2", "Charlie", "guest-c", ""),
]

const p1_owned = [
  #("p1", "arie1", "old-guest", "user-1"),
  #("p2", "Charlie", "guest-c", ""),
]

fn ctx_with(rooms: List(puzzles_caps.SourceRoom)) -> Ctx {
  let base = fakes.ctx()
  Ctx(
    ..base,
    ids: ids_caps.IdsCaps(..ids_caps.stub(), share_token: fn() {
      let assert [next, ..rest] = tokens_at("tokens")
      let _ = put_tokens("tokens", rest)
      next
    }),
    puzzles: puzzles_caps.PuzzlesCaps(
      ..puzzles_caps.stub(),
      get: fn(id) {
        case id {
          "p1" ->
            Some(puzzles_caps.Stored(
              id: "p1",
              kind: "move",
              question_json: "",
              answer_json: "",
            ))
          _ -> None
        }
      },
      mine: fn(_, _, _) { rooms },
      // One row per (source, sharer), whichever token got there first: the
      // real cap's contract.
      mint_share: fn(_puzzle_id, source_id, shared_by, shared_name, token) {
        case
          list.find(rows_at("shares"), fn(r) {
            r.0 == source_id && r.1 == shared_by
          })
        {
          Ok(existing) -> existing.3
          Error(_) -> {
            let _ =
              put_rows("shares", [
                #(source_id, shared_by, shared_name, token),
                ..rows_at("shares")
              ])
            token
          }
        }
      },
    ),
  )
}

fn guest(id: String) -> Session {
  Session(guest_id: Some(id), user_id: None)
}

fn text_at(body: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.string))
  value
}

// ---------- Minting ----------

pub fn the_guest_on_the_seat_that_made_the_mistake_may_share_it_test() {
  reset()
  let ctx = ctx_with([room(guests_only, source("move", "p1", "24/23 13/11"))])
  let assert Ok(body) = handler.mint_json(ctx, guest("guest-a"), "p1")
  assert text_at(body, ["token"]) == "TOKEN0000001"
  assert text_at(body, ["url"]) == "/puzzles/p1?s=TOKEN0000001"
  // Written as the guest's, under the name typed at the door.
  assert rows_at("shares") == [#(7, "guest-a", "Arie", "TOKEN0000001")]
}

pub fn an_owned_seat_shares_as_its_account_from_any_browser_test() {
  reset()
  let ctx = ctx_with([room(p1_owned, source("move", "p1", "24/23 13/11"))])
  let assert Ok(body) =
    handler.mint_json(
      ctx,
      Session(guest_id: Some("some-other-browser"), user_id: Some("user-1")),
      "p1",
    )
  assert text_at(body, ["token"]) == "TOKEN0000001"
  // The sharer is the account, and the name is the username.
  assert rows_at("shares") == [#(7, "user-1", "arie1", "TOKEN0000001")]
  // The browser whose guest used to hold the seat holds nothing now.
  assert handler.mint_json(ctx, guest("old-guest"), "p1")
    == Error(error.Forbidden(handler.not_yours_message))
}

/// The opponent sees the memory line; they may not tell this story.
pub fn the_opponent_may_not_share_it_test() {
  reset()
  let ctx = ctx_with([room(guests_only, source("move", "p1", "24/23 13/11"))])
  assert handler.mint_json(ctx, guest("guest-c"), "p1")
    == Error(error.Forbidden(handler.not_yours_message))
  assert rows_at("shares") == []
}

pub fn a_stranger_may_not_share_it_test() {
  reset()
  let ctx = ctx_with([room(guests_only, source("move", "p1", "24/23 13/11"))])
  assert handler.mint_json(ctx, guest("nobody"), "p1")
    == Error(error.Forbidden(handler.not_yours_message))
  assert handler.mint_json(ctx, session.anonymous(), "p1")
    == Error(error.Forbidden(handler.not_yours_message))
  // A puzzle nobody stored is not there to share.
  assert handler.mint_json(ctx, guest("guest-a"), "nope")
    == Error(error.NotFound(handler.not_found_message))
  assert rows_at("shares") == []
}

pub fn sharing_twice_is_the_same_link_test() {
  reset()
  let ctx = ctx_with([room(guests_only, source("move", "p1", "24/23 13/11"))])
  let assert Ok(first) = handler.mint_json(ctx, guest("guest-a"), "p1")
  let assert Ok(again) = handler.mint_json(ctx, guest("guest-a"), "p1")
  assert text_at(first, ["token"]) == text_at(again, ["token"])
  assert list.length(rows_at("shares")) == 1
}

// ---------- The words ----------

fn story(kind: String, played: String, won: Bool) -> handler.Story {
  handler.Story(
    name: "Arie",
    kind: kind,
    played: played,
    grade: "bad",
    equity_lost: 0.14,
    date: "2026-09-12",
    result: Some(#(won, 2)),
  )
}

pub fn the_head_words_for_a_move_and_the_cube_test() {
  assert handler.headline("Arie", question(Move))
    == "Arie got this wrong. What's your play?"
  assert handler.headline("Arie", question(Double))
    == "Arie got this wrong. Double?"
  assert handler.headline("arie1", question(Take))
    == "arie1 got this wrong. Take?"
}

pub fn the_story_line_test() {
  assert handler.line(story("move", "24/23 13/11", False))
    == "Arie played 24/23 13/11 (a bad move) and lost 2 points."
  assert handler.line(story("move", "24/23 13/11", True))
    == "Arie played 24/23 13/11 (a bad move) and won anyway."
  assert handler.line(story("double", "no_double", False))
    == "Arie didn't double (a bad decision) and lost 2 points."
  assert handler.line(story("double", "double", True))
    == "Arie doubled (a bad decision) and won anyway."
  assert handler.line(story("take", "pass", False))
    == "Arie passed (a bad decision) and lost 2 points."
  assert handler.line(story("take", "take", False))
    == "Arie took (a bad decision) and lost 2 points."
  let one_point =
    handler.Story(..story("move", "8/2 6/2", False), result: Some(#(False, 1)))
  assert handler.line(one_point)
    == "Arie played 8/2 6/2 (a bad move) and lost 1 point."
  let unfinished =
    handler.Story(
      ..story("move", "8/2 6/2", False),
      grade: "doubtful",
      result: None,
    )
  assert handler.line(unfinished) == "Arie played 8/2 6/2 (a dubious move)."
  // The opponent is in none of them.
  assert !string.contains(
    handler.line(story("move", "24/23 13/11", False)),
    "Charlie",
  )
}
