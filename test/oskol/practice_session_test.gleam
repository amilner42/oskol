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
  type Ask, type Card, type Severity, Active, Card, CardNotStarted, Day, Graded,
  PracticeCaps, Session, Severity, Summary, UnknownCard, UnknownTimezone,
} as _
import oskol/caps/puzzles.{DeckSource, PuzzlesCaps}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/practice
import oskol/practice/deck
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
        let reviews = keys("due", due, 0)
        Session(
          reviews: reviews,
          // Exactly what retain does with `new: :after_reviews`, so a
          // handler that asked for the wrong thing fails here.
          fresh: case ask.new_after_reviews && reviews != [] {
            True -> []
            False -> keys("new", fresh, 0)
          },
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
      day: fn(_uid) { Day(answered: 0, new_remaining: 3) },
      severity: fn(_uid, _level) { [] },
    ),
  )
}

/// The same deck, with this many answers recorded in the player's own day
/// and this much of the day's new budget left.
fn with_day(ctx: Ctx, done: Int, new_remaining: Int) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(..ctx.practice, day: fn(uid) {
      case uid {
        "u1" -> Day(answered: done, new_remaining: new_remaining)
        _ -> panic as "practice.day asked for another account"
      }
    }),
  )
}

/// The same deck with this many cards due: what the day's goal is made
/// of, before the ceiling on it.
fn with_due(ctx: Ctx, due: Int) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(..ctx.practice, summary: fn(_uid, _group) {
      [
        Summary(
          group: [],
          count: 42,
          new_count: 20,
          active_count: 42,
          suspended_count: 0,
          due_count: due,
          mean_level: 1.5,
        ),
      ]
    }),
  )
}

/// One band's queue, as the cap answers it: the band asked for is
/// handed back in the keys, so a handler that asked for the wrong one
/// fails here rather than quietly serving the whole deck.
fn with_band_queue(ctx: Ctx) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(..ctx.practice, band_queue: fn(uid, band, limit) {
      case uid {
        "u1" -> Nil
        _ -> panic as "practice.band_queue asked for another account"
      }
      assert limit == deck.page
      Session(
        reviews: [card(band <> "-due1", Move)],
        fresh: [card(band <> "-new1", Move)],
        new_remaining_today: 3,
      )
    }),
  )
}

/// The deck counted by band, as the cap answers it.
fn with_severity(ctx: Ctx, rows: List(Severity)) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(..ctx.practice, severity: fn(_uid, level) {
      case level {
        4 -> rows
        _ -> panic as "practice.severity asked with another patched level"
      }
    }),
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
          game_id: "room1",
          game_number: 1,
          kind: "move",
          grade: "bad",
          turn: index + 1,
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
  // Anything due at all, and the day's new cards wait their turn: that is
  // what the deck is asked for, and the page hands back what it answered.
  let ctx = with_deck(fakes.ctx(), 2, 3)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert ids(body) == ["due1", "due2"]
  assert string.contains(body, "\"due\":true")
  assert !string.contains(body, "\"due\":false")
}

pub fn a_new_card_says_it_is_not_due_test() {
  let ctx = with_deck(fakes.ctx(), 0, 2)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert ids(body) == ["new1", "new2"]
  assert string.contains(body, "\"due\":false")
  assert !string.contains(body, "\"due\":true")
}

pub fn an_account_is_told_what_is_due_what_is_left_today_and_how_big_the_deck_is_test() {
  let ctx = with_deck(fakes.ctx(), 1, 1)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  // Tomorrow brings the day's budget: the deck has 20 never seen, which is
  // more than a day's three.
  assert string.contains(
    body,
    "\"counts\":{\"due\":9,\"new_today\":7,\"new_tomorrow\":3,\"deck\":42}",
  )
  // An account's mistakes are its deck: the guest's count is not sent.
  assert string.contains(body, "\"mistakes\":null")
  // This endpoint is never one game's mistakes.
  assert string.contains(body, "\"game\":null")
}

// ---------- The day's count ----------

/// The day is a plain count of what has been answered, and nothing else.
/// There is no target on the wire, so nothing can draw a ring round it
/// or call a day short.
pub fn the_day_is_a_plain_count_test() {
  let ctx = with_due(with_day(with_deck(fakes.ctx(), 1, 1), 4, 3), 2)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert string.contains(body, "\"today\":{\"done\":4}")
  assert !string.contains(body, "target")
}

/// A backlog is not a quota. Twenty-three due asks for nothing in
/// particular: the day still reads what has actually been answered.
pub fn a_backlog_does_not_become_a_target_test() {
  let ctx = with_due(with_day(with_deck(fakes.ctx(), 1, 1), 0, 3), 23)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert string.contains(body, "\"today\":{\"done\":0}")
}

// ---------- The deck by severity, and the tier to lead with ----------

/// Worst first, every band named in its three states with what it still
/// has to do, and the rung that means patched sent with them so the page
/// keeps no second copy of it.
pub fn the_session_counts_the_deck_by_severity_test() {
  let ctx =
    with_severity(with_due(with_day(with_deck(fakes.ctx(), 1, 1), 0, 3), 5), [
      Severity(
        grade: "doubtful",
        total: 96,
        in_progress: 8,
        patched: 12,
        due: 0,
        fresh: 70,
      ),
      Severity(
        grade: "very_bad",
        total: 61,
        in_progress: 30,
        patched: 23,
        due: 5,
        fresh: 8,
      ),
    ])
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert string.contains(
    body,
    "\"severity\":[{\"grade\":\"very_bad\",\"total\":61,\"in_progress\":30,\"patched\":23,\"due\":5,\"new_left\":3},"
      <> "{\"grade\":\"bad\",\"total\":0,\"in_progress\":0,\"patched\":0,\"due\":0,\"new_left\":0},"
      <> "{\"grade\":\"doubtful\",\"total\":96,\"in_progress\":8,\"patched\":12,\"due\":0,\"new_left\":3}]",
  )
  assert string.contains(body, "\"patched_level\":4")
  // The worst band with work is the one the page puts in front.
  assert string.contains(body, "\"lead\":\"very_bad\"")
}

/// The human's own deck: nothing patched yet and fifty mistakes being
/// worked on. The band a player has not started is all zeros beside the
/// total, and a band with everything patched has nothing in progress --
/// three states that never overlap.
pub fn a_deck_being_worked_on_says_so_before_anything_is_patched_test() {
  let ctx =
    with_severity(with_due(with_day(with_deck(fakes.ctx(), 1, 1), 0, 3), 4), [
      Severity(
        grade: "very_bad",
        total: 111,
        in_progress: 50,
        patched: 0,
        due: 4,
        fresh: 61,
      ),
      Severity(
        grade: "bad",
        total: 12,
        in_progress: 0,
        patched: 12,
        due: 0,
        fresh: 0,
      ),
    ])
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert string.contains(
    body,
    "\"severity\":[{\"grade\":\"very_bad\",\"total\":111,\"in_progress\":50,\"patched\":0,\"due\":4,\"new_left\":3},"
      <> "{\"grade\":\"bad\",\"total\":12,\"in_progress\":0,\"patched\":12,\"due\":0,\"new_left\":0},"
      <> "{\"grade\":\"doubtful\",\"total\":0,\"in_progress\":0,\"patched\":0,\"due\":0,\"new_left\":0}]",
  )
}

/// A day whose budget of new mistakes is spent leaves a band that has
/// only untouched ones with nothing to offer: `new_left` is the deck's
/// budget, not the band's pile, so the hub cannot promise three new
/// very bad moves twice in one day.
pub fn a_spent_day_leaves_a_band_of_untouched_mistakes_with_no_work_test() {
  let ctx =
    with_severity(with_due(with_day(with_deck(fakes.ctx(), 0, 0), 3, 0), 2), [
      Severity(
        grade: "very_bad",
        total: 40,
        in_progress: 0,
        patched: 0,
        due: 0,
        fresh: 40,
      ),
      Severity(
        grade: "bad",
        total: 9,
        in_progress: 2,
        patched: 0,
        due: 2,
        fresh: 7,
      ),
    ])
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

  assert string.contains(
    body,
    "{\"grade\":\"very_bad\",\"total\":40,\"in_progress\":0,\"patched\":0,\"due\":0,\"new_left\":0}",
  )
  // Very bad has nothing left today, so the bad tier is what is offered.
  assert string.contains(body, "\"lead\":\"bad\"")
}

// ---------- One tier's own queue ----------

/// FIX ONE asks for one band, and gets that band's cards: the whole
/// deck's queue is never reached for.
pub fn a_band_session_asks_the_deck_for_that_band_test() {
  let ctx = with_band_queue(with_day(with_deck(fakes.ctx(), 9, 9), 0, 3))
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "bad")

  // The band queue's own cards, not the nine-and-nine the whole deck
  // would have answered with.
  assert ids(body) == ["bad-due1", "bad-new1"]
}

/// A band nobody has is refused rather than widened into the whole deck:
/// a page must not be able to ask for more than it named.
pub fn an_unknown_band_is_refused_test() {
  let ctx = with_band_queue(with_day(with_deck(fakes.ctx(), 1, 1), 0, 3))

  assert practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "brilliant")
    == Error(error.validation_failed("That is not one of your mistake tiers."))
}

/// A guest has no deck, so there is no day of theirs to count -- and
/// `answered_today` still panics on this ctx, so a handler that reached for
/// it would fail here rather than invent a ring.
pub fn a_guest_gets_no_ring_and_no_bands_test() {
  let ctx =
    with_guest_mistakes(fakes.ctx(), [
      #("p1", guest_seat("g1")),
      #("p2", guest_seat("g1")),
    ])
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), "")

  assert string.contains(body, "\"today\":null")
  assert string.contains(body, "\"severity\":null")
}

pub fn nobody_gets_no_ring_test() {
  let assert Ok(body) =
    practice.practice_json(fakes.ctx(), fakes.no_guest(), "")

  assert string.contains(body, "\"today\":null")
}

pub fn tomorrow_brings_what_is_left_when_that_is_less_than_a_day_test() {
  let ctx =
    Ctx(
      ..with_deck(fakes.ctx(), 0, 0),
      practice: PracticeCaps(
        ..with_deck(fakes.ctx(), 0, 0).practice,
        summary: fn(_uid, _group) {
          [
            Summary(
              group: [],
              count: 12,
              new_count: 2,
              active_count: 10,
              suspended_count: 0,
              due_count: 0,
              mean_level: 1.5,
            ),
          ]
        },
      ),
    )
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")
  assert string.contains(body, "\"new_tomorrow\":2")
}

pub fn a_session_is_never_paged_test() {
  // A full page and a short one alike: there is no cursor to follow. The
  // due set is live, so the next page is whatever is still due when the
  // client asks again -- an offset would skip exactly the cards the player
  // had just answered. "Done for today" is a fetch that comes back empty.
  let full = with_deck(fakes.ctx(), 20, 0)
  let assert Ok(body) =
    practice.practice_json(full, fakes.signed_in("g1", "u1"), "")
  assert list.length(ids(body)) == 20
  assert string.contains(body, "\"cursor\":null")

  let short = with_deck(fakes.ctx(), 3, 2)
  let assert Ok(rest) =
    practice.practice_json(short, fakes.signed_in("g1", "u1"), "")
  assert string.contains(rest, "\"cursor\":null")
}

pub fn new_cards_wait_until_nothing_is_due_test() {
  // The brief: everything due comes first. With one card still due the
  // day's new ones are not offered yet -- they arrive on the fetch after
  // it, which is why a session must keep asking rather than paging.
  let ctx = with_deck(fakes.ctx(), 1, 10)
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")
  assert ids(body) == ["due1"]

  let cleared = with_deck(fakes.ctx(), 0, 10)
  let assert Ok(after) =
    practice.practice_json(cleared, fakes.signed_in("g1", "u1"), "")
  assert list.length(ids(after)) == 10
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
        day: fn(_) { Day(answered: 0, new_remaining: 3) },
        severity: fn(_, _) { [] },
      ),
    )
  let assert Ok(body) =
    practice.practice_json(ctx, fakes.signed_in("g1", "u1"), "")

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
  let assert Ok(body) = practice.more_json(started, fakes.signed_in("g1", "u1"))
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
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), "")

  assert ids(body) == ["mine"]
  // No schedule and no counts: only an account has a deck.
  assert string.contains(body, "\"due\":false")
  assert string.contains(body, "\"counts\":null")
  // What the home says they have behind them: theirs only, from one room.
  assert string.contains(body, "\"mistakes\":{\"puzzles\":1,\"games\":1}")
}

pub fn a_guest_is_told_how_many_mistakes_from_how_many_games_test() {
  // More than a page of them, from two rooms: the count is the whole of
  // what is theirs, not the twenty the page carries, and the same puzzle
  // reached twice is one mistake.
  let sources =
    list.map(list.range(1, 23), fn(n) {
      #("p" <> int.to_string(n), guest_seat("g1"))
    })
  let ctx =
    Ctx(
      ..fakes.ctx(),
      puzzles: PuzzlesCaps(..fakes.ctx().puzzles, guest_sources: fn(_guest_id) {
        list.index_map(
          list.append(sources, [#("p1", guest_seat("g1"))]),
          fn(entry, index) {
            DeckSource(
              source_id: index,
              puzzle_id: entry.0,
              game_id: case index < 10 {
                True -> "room1"
                False -> "room2"
              },
              game_number: 1,
              kind: "move",
              grade: "bad",
              turn: index + 1,
              question_json: question_json(Move),
              ended_ms: 1_790_000_000_000 - index,
              seat: entry.1,
            )
          },
        )
      }),
    )
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), "")
  assert list.length(ids(body)) == 20
  assert string.contains(body, "\"mistakes\":{\"puzzles\":23,\"games\":2}")
}

pub fn a_guest_sees_one_card_per_puzzle_test() {
  let ctx =
    with_guest_mistakes(fakes.ctx(), [
      #("same", guest_seat("g1")),
      #("same", guest_seat("g1")),
    ])
  let assert Ok(body) = practice.practice_json(ctx, fakes.guest("g1"), "")
  assert ids(body) == ["same"]
}

pub fn keep_going_writes_nothing_for_a_guest_test() {
  // The practice caps all panic, so reaching the deck at all fails here.
  let ctx = with_guest_mistakes(fakes.ctx(), [#("mine", guest_seat("g1"))])
  let assert Ok(body) = practice.more_json(ctx, fakes.guest("g1"))
  assert ids(body) == ["mine"]
}

pub fn nobody_gets_an_empty_session_and_not_an_error_test() {
  // Nothing is asked of anything: a stranger has no seat and no deck.
  let assert Ok(body) =
    practice.practice_json(fakes.ctx(), fakes.no_guest(), "")
  assert ids(body) == []
  assert string.contains(body, "\"counts\":null")
  assert string.contains(body, "\"mistakes\":null")
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
          assert per_day == 3
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
