//// What `GET /papi/practice` puts in front of each kind of caller, on stub
//// capabilities: an account's deck, a guest's own mistakes, and a stranger
//// with nothing. Plus the two small writes the page makes -- the browser's
//// timezone and burying a puzzle the session left ungraded.
////
//// Everything the endpoint does not use still panics (fakes.ctx()), which
//// is how "a guest's session writes nothing" is a test and not a promise.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/practice.{
  type Ask, type Card, Active, Card, CardNotStarted, Graded, PracticeCaps,
  Session, Summary, UnknownCard, UnknownTimezone,
} as _
import oskol/caps/puzzles.{DeckSource, PuzzlesCaps}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/practice
import oskol/puzzles.{type Question, Centered, Double, Move, Question} as puzzle
import oskol/rooms/seat.{type Seat, Seat}

// ---------- A little deck, and a little pile of a guest's mistakes ----------

fn question(kind: puzzle.Kind) -> Question {
  Question(
    kind: kind,
    board: list.repeat(0, 26),
    dice: case kind {
      Move -> Some(#(6, 4))
      _ -> None
    },
    cube_value: 1,
    cube_owner: Centered,
    away_mover: 0,
    away_opponent: 0,
    crawford: False,
    jacoby: False,
  )
}

fn question_json(kind: puzzle.Kind) -> String {
  json.to_string(puzzle.question_json(question(kind)))
}

fn card(key: String, kind: puzzle.Kind) -> Card {
  Card(
    key: key,
    tags: [#("deck", "mistakes"), #("kind", puzzle.kind_name(kind))],
    content_json: question_json(kind),
    level: 2,
    due_ms: 0,
    reps: 3,
    lapses: 1,
    status: Active,
  )
}

/// A deck that answers with these many due and new cards, and records the
/// ask so a test can say what a page asked for.
fn with_deck(ctx: Ctx, due: Int, fresh: Int) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(
      ..ctx.practice,
      queue: fn(_uid, ask: Ask) {
        Session(
          reviews: keys("due", due, ask.offset),
          fresh: keys("new", fresh, 0),
          new_remaining_today: 7,
        )
      },
      summary: fn(_uid, _group) {
        [
          Summary(
            group: [],
            count: 42,
            new_count: 20,
            active_count: 22,
            suspended_count: 0,
            due_count: 9,
            mean_level: 1.5,
          ),
        ]
      },
    ),
  )
}

fn keys(prefix: String, count: Int, offset: Int) -> List(Card) {
  case count {
    0 -> []
    _ ->
      list.map(list.range(1, count), fn(n) {
        card(prefix <> int.to_string(offset + n), Move)
      })
  }
}

/// A store that answers a guest with these mistakes, newest first.
fn with_guest_mistakes(ctx: Ctx, sources: List(#(String, Seat))) -> Ctx {
  Ctx(
    ..ctx,
    puzzles: PuzzlesCaps(..ctx.puzzles, guest_sources: fn(_guest_id) {
      list.index_map(sources, fn(entry, index) {
        DeckSource(
          source_id: index,
          puzzle_id: entry.0,
          kind: "move",
          question_json: question_json(Move),
          ended_ms: 1_790_000_000_000 - index,
          seat: entry.1,
        )
      })
    }),
  )
}

fn guest_seat(guest_id: String) -> Seat {
  Seat(player_id: "p1", guest_id: Some(guest_id), user_id: None)
}

fn owned_seat(user_id: String) -> Seat {
  Seat(player_id: "p1", guest_id: Some("g1"), user_id: Some(user_id))
}

// ---------- An account ----------

pub fn an_account_gets_everything_due_before_anything_new_test() {
  let ctx = with_deck(fakes.ctx(), 2, 3)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 0)

  // Due first, in the order the deck gave them, then the new ones.
  assert ids(body) == ["due1", "due2", "new1", "new2", "new3"]
  assert string.contains(body, "\"due\":true")
  assert string.contains(body, "\"due\":false")
}

pub fn an_account_is_told_what_is_due_what_is_left_today_and_how_big_the_deck_is_test() {
  let ctx = with_deck(fakes.ctx(), 1, 1)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 0)

  assert string.contains(
    body,
    "\"counts\":{\"due\":9,\"new_today\":7,\"deck\":42}",
  )
  // This endpoint is never one game's mistakes.
  assert string.contains(body, "\"game\":null")
}

pub fn a_full_page_of_reviews_offers_the_next_one_test() {
  let ctx = with_deck(fakes.ctx(), 20, 0)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 0)
  assert string.contains(body, "\"cursor\":\"20\"")

  // And the page after it walks further down the same ordering.
  let assert Ok(next) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 20)
  assert list.first(ids(next)) == Ok("due21")
  assert string.contains(next, "\"cursor\":\"40\"")
}

pub fn a_short_page_is_the_end_of_the_session_test() {
  let ctx = with_deck(fakes.ctx(), 3, 2)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 0)
  // "Done for today" waits on a fetch that comes back with nothing, so a
  // page that is not full must not pretend there is more.
  assert string.contains(body, "\"cursor\":null")
}

pub fn a_puzzle_is_asked_in_its_own_words_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        queue: fn(_, _) {
          Session(
            reviews: [card("aaa", Move)],
            fresh: [card("bbb", Double)],
            new_remaining_today: 0,
          )
        },
        summary: fn(_, _) { [] },
      ),
    )
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), 0)

  assert string.contains(body, "White to play 6-4. What's your play?")
  assert string.contains(body, "White to play. Double?")
  assert string.contains(body, "\"kind\":\"move\"")
  assert string.contains(body, "\"kind\":\"double\"")
}

pub fn keep_going_starts_more_and_answers_the_session_test() {
  let ctx = with_deck(fakes.ctx(), 0, 2)
  let started =
    Ctx(
      ..ctx,
      practice: PracticeCaps(..ctx.practice, start_new: fn(_uid, count) {
        assert count == 10
        count
      }),
    )
  let assert Ok(body) =
    practice.more_json(started, fakes.signed_in("g1", "u1"), 0)
  assert ids(body) == ["new1", "new2"]
}

// ---------- A guest ----------

pub fn a_guest_gets_the_mistakes_on_the_seats_their_cookie_holds_test() {
  // Every practice capability panics: a guest has no deck, and touching one
  // would be a write nobody asked for.
  let ctx =
    with_guest_mistakes(fakes.ctx(), [
      #("mine", guest_seat("g1")),
      // A seat an account took over -- this browser's cookie is history on
      // it -- and a seat that was never this browser's at all.
      #("theirs", owned_seat("u1")),
      #("stranger", guest_seat("g2")),
    ])
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), 0)

  assert ids(body) == ["mine"]
  // No schedule and no counts: only an account has a deck.
  assert string.contains(body, "\"due\":false")
  assert string.contains(body, "\"counts\":null")
}

pub fn a_guest_sees_one_card_per_puzzle_test() {
  let ctx =
    with_guest_mistakes(fakes.ctx(), [
      #("same", guest_seat("g1")),
      #("same", guest_seat("g1")),
    ])
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), 0)
  assert ids(body) == ["same"]
}

pub fn keep_going_writes_nothing_for_a_guest_test() {
  // The practice caps all panic, so reaching the deck at all fails here.
  let ctx = with_guest_mistakes(fakes.ctx(), [#("mine", guest_seat("g1"))])
  let assert Ok(body) = practice.more_json(ctx, fakes.guest("g1"), 0)
  assert ids(body) == ["mine"]
}

pub fn nobody_gets_an_empty_session_and_not_an_error_test() {
  // Nothing is asked of anything: a stranger has no seat and no deck.
  let assert Ok(body) = practice.practice_json(fakes.ctx(), fakes.no_guest(), 0)
  assert ids(body) == []
  assert string.contains(body, "\"counts\":null")
  assert string.contains(body, "\"cursor\":null")
}

// ---------- Where the browser is ----------

pub fn a_timezone_is_written_once_for_the_account_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        put_user: fn(uid, tz, per_day) {
          assert uid == "u1"
          assert tz == "America/Vancouver"
          assert per_day == 10
          Ok(Nil)
        },
      ),
    )
  let assert Ok(body) =
    practice.timezone_json(
      ctx,
      fakes.signed_in("g1", "u1"),
      "America/Vancouver",
    )
  assert string.contains(body, "\"tz\":\"America/Vancouver\"")
}

pub fn a_name_that_is_not_a_timezone_is_refused_before_it_is_written_test() {
  // put_user panics: nothing that is not a zone name may reach the deck.
  // A name with too many parts, one with characters no zone name has, and
  // no name at all. ("Europe" is shape-valid and the zone database is what
  // turns it down, the same way it turns down "Mars/Olympus".)
  let names = [
    "", "not a zone", "../../etc/passwd", "Europe/Paris/Extra/More", "<script>",
    "Europe/Paris?x=1",
  ]
  list.each(names, fn(name) {
    let assert Error(refusal) =
      practice.timezone_json(fakes.ctx(), fakes.signed_in("g1", "u1"), name)
    assert error.status(refusal) == 422
  })
}

pub fn the_zone_names_the_world_has_are_accepted_test() {
  let names = [
    "UTC", "Etc/UTC", "Europe/Paris", "America/Vancouver", "Etc/GMT+5",
    "America/Argentina/Buenos_Aires",
  ]
  list.each(names, fn(name) {
    let ctx =
      Ctx(
        ..fakes.ctx(),
        practice: PracticeCaps(..fakes.ctx().practice, put_user: fn(_, _, _) {
          Ok(Nil)
        }),
      )
    let assert Ok(_) =
      practice.timezone_json(ctx, fakes.signed_in("g1", "u1"), name)
  })
}

pub fn a_zone_the_deck_does_not_know_is_the_browsers_mistake_not_a_crash_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(..fakes.ctx().practice, put_user: fn(_, _, _) {
        Error(UnknownTimezone)
      }),
    )
  let assert Error(refusal) =
    practice.timezone_json(ctx, fakes.signed_in("g1", "u1"), "Mars/Olympus")
  // 422 and not the 500 an unopenable deck gets: the browser told us
  // something wrong about itself, and that is a thing it can be told.
  assert error.status(refusal) == 422
}

// ---------- Burying ----------

pub fn burying_moves_a_puzzle_to_tomorrow_and_keeps_its_level_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(
        ..fakes.ctx().practice,
        defer_tomorrow: fn(uid, key) {
          assert uid == "u1"
          assert key == "aaa"
          Ok(Graded(
            level_before: 3,
            level_after: 3,
            due_ms: 1_790_000_000_000,
            review_id: 7,
          ))
        },
      ),
    )
  let assert Ok(body) =
    practice.bury_json(ctx, fakes.signed_in("g1", "u1"), "aaa")
  assert string.contains(body, "\"level\":3")
  assert string.contains(body, "\"due\":1790000000000")
}

pub fn burying_a_puzzle_that_is_not_in_rotation_is_a_409_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(..fakes.ctx().practice, defer_tomorrow: fn(_, _) {
        Error(CardNotStarted)
      }),
    )
  let assert Error(refusal) =
    practice.bury_json(ctx, fakes.signed_in("g1", "u1"), "aaa")
  assert error.status(refusal) == 409
}

pub fn burying_a_puzzle_that_is_not_in_the_deck_is_a_404_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      practice: PracticeCaps(..fakes.ctx().practice, defer_tomorrow: fn(_, _) {
        Error(UnknownCard)
      }),
    )
  let assert Error(refusal) =
    practice.bury_json(ctx, fakes.signed_in("g1", "u1"), "aaa")
  assert error.status(refusal) == 404
}

pub fn a_guest_has_no_rotation_to_bury_anything_in_test() {
  // Every practice capability panics: a guest must reach none of them.
  let assert Error(refusal) =
    practice.bury_json(fakes.ctx(), fakes.guest("g1"), "aaa")
  assert error.status(refusal) == 409
}

// ---------- Reading the answer ----------

/// The puzzle ids in the order the session listed them.
fn ids(body: String) -> List(String) {
  body
  |> string.split("{\"id\":\"")
  |> list.drop(1)
  |> list.filter_map(fn(rest) {
    case string.split(rest, "\"") {
      [id, ..] -> Ok(id)
      [] -> Error(Nil)
    }
  })
}
