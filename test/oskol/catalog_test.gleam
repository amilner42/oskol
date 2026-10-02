//// The five decks on the wire, on stub capabilities: the catalog, what
//// `GET /papi/practice/decks` says to an account, a guest and a stranger,
//// which deck leads, a deck's own page, and KEEP GOING through a set.
////
//// Everything a branch is not supposed to reach still panics
//// (fakes.ctx()), so "reading writes nothing" is a test here.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/activity.{ActivityCaps}
import oskol/caps/analysis.{AnalysisCaps, MistakeCost, RatedGame}
import oskol/caps/decks.{DeckCaps, Member, OwnDeck}
import oskol/caps/practice.{
  type Cell, type Day, type PracticeCaps, Active, Card, Cell, Day, New,
  PracticeCaps, Session, Summary, Suspended,
} as _
import oskol/caps/puzzles.{DeckSource, PuzzlesCaps}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/core/session
import oskol/fakes
import oskol/handlers/decks as decks_handler
import oskol/handlers/practice
import oskol/practice/catalog
import oskol/practice/deck
import oskol/rooms/seat

const now = 1_800_000_000_000

const ladder = [1, 1, 3, 7, 21, 58, 145, 365]

// ---------- The catalog ----------

pub fn the_five_decks_in_hub_order_test() {
  assert list.map(catalog.five(), fn(d) { #(d.id, d.slug, d.name, d.mark) })
    == [
      #("very_bad", "very-bad", "Very bad moves", "??"),
      #("bad", "bad", "Bad moves", "?"),
      #("doubtful", "dubious", "Dubious moves", "?!"),
      #("openings", "openings", "Openings", ""),
      #("opening_replies", "opening-replies", "Opening replies", ""),
    ]
  assert list.map(catalog.five(), catalog.kind_name)
    == ["mistakes", "mistakes", "mistakes", "set", "set"]
}

pub fn a_deck_is_found_by_its_slug_and_by_its_id_test() {
  let assert Ok(d) =
    catalog.find_slug(fakes.ctx(), session.anonymous(), "dubious")
  assert d.id == "doubtful"
  assert d.kind == catalog.Mistakes("doubtful")
  let assert Ok(r) =
    catalog.find_id(fakes.ctx(), session.anonymous(), "opening_replies")
  assert r.slug == "opening-replies"
  // The id is not a slug and the slug is not an id.
  assert catalog.find_slug(fakes.ctx(), session.anonymous(), "doubtful")
    == Error(Nil)
  assert catalog.find_id(fakes.ctx(), session.anonymous(), "very-bad")
    == Error(Nil)
  assert catalog.find_slug(fakes.ctx(), session.anonymous(), "brilliant")
    == Error(Nil)
}

// ---------- A world to read ----------

fn cell(key: String, band: String, level: Int, due: Int, status) -> Cell {
  Cell(
    key: key,
    band: band,
    level: level,
    due_ms: due,
    status: status,
    position: Some(0),
  )
}

/// A ladder that reads these cells and this day, and nothing else.
fn reading(
  cells: List(Cell),
  day: Day,
  by_band: List(#(String, Int)),
) -> PracticeCaps {
  PracticeCaps(
    ..fakes.ctx().practice,
    cells: fn(uid) {
      assert uid == "u1"
      cells
    },
    day: fn(_) { day },
    answered_today_by_band: fn(_) { by_band },
    intervals: fn() { ladder },
    days: fn(_, n) { list.repeat(True, n) },
  )
}

/// An account: its mistakes, and each set's cells (absent: never added).
fn account(
  mistakes: List(Cell),
  day: Day,
  by_band: List(#(String, Int)),
  sets: List(#(String, List(Cell), Day)),
  sizes: List(#(String, Int)),
) -> Ctx {
  Ctx(
    ..fakes.ctx(),
    practice: reading(mistakes, day, by_band),
    decks: DeckCaps(
      ..fakes.ctx().decks,
      own: fn(uid) {
        assert uid == "u1"
        []
      },
      size: fn(id) { list.key_find(sizes, id) |> result.unwrap(0) },
      practice: fn(scope) {
        case list.find(sets, fn(s) { "deck:" <> s.0 == scope }) {
          Ok(#(_, cells, day)) -> reading(cells, day, [])
          Error(Nil) -> reading([], Day(0, 0), [])
        }
      },
    ),
    activity: ActivityCaps(days: fn(uid, n) {
      assert uid == "u1"
      // Three days running, today among them.
      list.append(list.repeat(False, n - 3), [True, True, True])
    }),
    // No graded games and no mistakes behind them: every cost is null.
    analysis: AnalysisCaps(
      ..fakes.ctx().analysis,
      graded_for: fn(uid, _) {
        assert uid == "u1"
        []
      },
      mistake_costs: fn(uid) {
        assert uid == "u1"
        []
      },
    ),
  )
}

fn built() -> List(#(String, Int)) {
  [#("openings", 15), #("opening_replies", 315)]
}

/// One deck of the answer, by id.
type Read {
  Read(
    id: String,
    slug: String,
    kind: String,
    size: Int,
    joined: Bool,
    standing: Option(List(Int)),
  )
}

fn decks_of(body: String) -> List(Read) {
  let standing = {
    use total <- decode.field("total", decode.int)
    use untouched <- decode.field("untouched", decode.int)
    use in_progress <- decode.field("in_progress", decode.int)
    use patched <- decode.field("patched", decode.int)
    use due <- decode.field("due", decode.int)
    use new_left <- decode.field("new_left", decode.int)
    use done <- decode.field("done_today", decode.int)
    use target <- decode.field("target_today", decode.int)
    use levels <- decode.field("levels", decode.list(decode.int))
    decode.success(list.append(
      [total, untouched, in_progress, patched, due, new_left, done, target],
      levels,
    ))
  }
  let one = {
    use id <- decode.field("id", decode.string)
    use slug <- decode.field("slug", decode.string)
    use kind <- decode.field("kind", decode.string)
    use size <- decode.field("size", decode.int)
    use joined <- decode.field("joined", decode.bool)
    use s <- decode.field("standing", decode.optional(standing))
    use _ <- decode.field("cost", decode.optional(decode.int))
    decode.success(Read(id, slug, kind, size, joined, s))
  }
  let assert Ok(decks) =
    json.parse(body, decode.at(["decks"], decode.list(one)))
  decks
}

fn find(body: String, id: String) -> Read {
  let assert Ok(d) = list.find(decks_of(body), fn(d) { d.id == id })
  d
}

fn lead_of(body: String) -> Option(String) {
  let assert Ok(lead) =
    json.parse(body, decode.at(["lead"], decode.optional(decode.string)))
  lead
}

fn int_at(body: String, path: List(String)) -> Int {
  let assert Ok(n) = json.parse(body, decode.at(path, decode.int))
  n
}

fn signed_in() {
  fakes.signed_in("g1", "u1")
}

// ---------- An account's five ----------

pub fn an_account_reads_every_deck_from_its_cells_test() {
  let mistakes = [
    // Very bad: one untouched, one in progress and due, one patched.
    cell("v1", "very_bad", 0, 0, New),
    cell("v2", "very_bad", 2, now - 1, Active),
    cell("v3", "very_bad", 5, now + 1, Active),
    // Bad: two never shown.
    cell("b1", "bad", 0, 0, New),
    cell("b2", "bad", 0, 0, New),
  ]
  let ctx =
    account(
      mistakes,
      // One new left in the day's budget, four answered today.
      Day(answered: 4, new_remaining: 1),
      [#("very_bad", 3), #("bad", 1)],
      [#("openings", [cell("o1", "", 1, now + 9, Active)], Day(2, 5))],
      built(),
    )
  let body = practice.decks_json(ctx, signed_in(), now)

  assert list.map(decks_of(body), fn(d) { #(d.id, d.slug, d.kind) })
    == [
      #("very_bad", "very-bad", "mistakes"),
      #("bad", "bad", "mistakes"),
      #("doubtful", "dubious", "mistakes"),
      #("openings", "openings", "set"),
      #("opening_replies", "opening-replies", "set"),
    ]

  let very_bad = find(body, "very_bad")
  assert very_bad.size == 3
  assert very_bad.joined
  // total, untouched, in progress, patched, due, new left (the budget's
  // one), done today, target (5 = 3 done + 1 due + 1 new), then the
  // rungs.
  assert very_bad.standing
    == Some([3, 1, 1, 1, 1, 1, 3, 5, 1, 0, 1, 0, 0, 1, 0, 0])

  // The budget is the deck's: each tier offers what is left of it.
  let assert Some([2, 2, 0, 0, 0, 1, 1, 2, ..]) = find(body, "bad").standing

  // A tier with nothing in it: there, and empty, never missing.
  let doubtful = find(body, "doubtful")
  assert doubtful.size == 0
  assert !doubtful.joined
  let assert Some([0, 0, 0, 0, 0, 0, 0, 0, ..]) = doubtful.standing

  // A set added: its own cells, its own day.
  let openings = find(body, "openings")
  assert openings.size == 15
  assert openings.joined
  let assert Some([1, 0, 1, 0, 0, 0, 2, 2, 0, 1, ..]) = openings.standing

  // A set not added: its size, and a standing of nothing.
  let replies = find(body, "opening_replies")
  assert replies.size == 315
  assert !replies.joined
  let assert Some([0, 0, 0, 0, 0, 0, 0, 0, ..]) = replies.standing

  // Today across every deck: the mistakes' day and the set's.
  assert int_at(body, ["today", "done"]) == 6
  assert int_at(body, ["streak"]) == 3
  assert string.contains(body, "\"cost\":null")
}

pub fn levels_count_every_card_on_its_rung_test() {
  let s =
    deck.standing(
      [
        cell("a", "bad", 0, 0, New),
        cell("b", "bad", 3, 0, Active),
        cell("c", "bad", 3, 0, Suspended),
        cell("d", "bad", 7, 0, Active),
      ],
      0,
      0,
      now,
      8,
    )
  assert s.levels == [1, 0, 0, 2, 0, 0, 0, 1]
  assert int_sum(s.levels) == s.total
  // A paused card is still a card: counted, but never due.
  assert s.due == 2
}

fn int_sum(xs: List(Int)) -> Int {
  list.fold(xs, 0, fn(a, b) { a + b })
}

pub fn target_today_is_done_plus_due_plus_new_left_test() {
  let cells = [
    cell("a", "bad", 1, now - 5, Active),
    cell("b", "bad", 1, now, Active),
    cell("c", "bad", 1, now + 5, Active),
    cell("n1", "bad", 0, 0, New),
    cell("n2", "bad", 0, 0, New),
    cell("n3", "bad", 0, 0, New),
  ]
  // Due now is at or before now; two of three new ones the budget allows.
  let s = deck.standing(cells, 2, 5, now, 8)
  assert s.due == 2
  assert s.new_left == 2
  assert s.target_today == 5 + 2 + 2
  // A spent budget: nothing new left, and the ring is the day's answers
  // plus what is due.
  let spent = deck.standing(cells, 0, 5, now, 8)
  assert spent.target_today == 7
  // A negative budget reads as none.
  assert deck.standing(cells, -3, 0, now, 8).new_left == 0
}

// ---------- Which deck leads ----------

fn lead_with(
  mistakes: List(Cell),
  budget: Int,
  sets: List(#(String, List(Cell), Day)),
) -> Option(String) {
  let ctx = account(mistakes, Day(0, budget), [], sets, built())
  lead_of(practice.decks_json(ctx, signed_in(), now))
}

pub fn the_worst_tier_with_work_leads_test() {
  // Very bad has nothing to do today; bad has one due.
  let mistakes = [
    cell("v1", "very_bad", 2, now + 99, Active),
    cell("b1", "bad", 1, now - 1, Active),
    cell("d1", "doubtful", 0, 0, New),
  ]
  assert lead_with(mistakes, 0, []) == Some("bad")
  // With the day's budget not spent, an untouched very bad one is work.
  assert lead_with([cell("v0", "very_bad", 0, 0, New), ..mistakes], 1, [])
    == Some("very_bad")
}

pub fn a_set_with_work_leads_when_no_tier_has_any_test() {
  let quiet = [cell("v1", "very_bad", 2, now + 99, Active)]
  let set = fn(due) { [cell("o1", "", 1, due, Active)] }
  assert lead_with(quiet, 0, [
      #("openings", set(now + 99), Day(0, 0)),
      #("opening_replies", set(now - 1), Day(0, 0)),
    ])
    == Some("opening_replies")
  // Openings before replies when both have work.
  assert lead_with(quiet, 0, [
      #("openings", set(now - 1), Day(0, 0)),
      #("opening_replies", set(now - 1), Day(0, 0)),
    ])
    == Some("openings")
}

pub fn the_worst_tier_there_is_leads_when_nothing_has_work_test() {
  let quiet = [
    cell("b1", "bad", 2, now + 99, Active),
    cell("d1", "doubtful", 2, now + 99, Active),
  ]
  assert lead_with(quiet, 0, [#("openings", [], Day(0, 0))]) == Some("bad")
}

pub fn nothing_leads_an_account_with_nothing_test() {
  assert lead_with([], 3, []) == None
}

// ---------- A set nobody has built ----------

pub fn a_set_with_nothing_built_is_not_offered_test() {
  let ctx =
    account([], Day(0, 0), [], [], [#("openings", 15), #("opening_replies", 0)])
  let body = practice.decks_json(ctx, signed_in(), now)
  assert list.map(decks_of(body), fn(d) { d.id })
    == ["very_bad", "bad", "doubtful", "openings"]
  // And its page is the same 404 as a deck that is not there at all.
  assert practice.deck_page_json(ctx, signed_in(), "opening-replies", now)
    == Error(error.NotFound("There is no such set of puzzles."))
  assert practice.deck_page_json(ctx, signed_in(), "brilliant", now)
    == Error(error.NotFound("There is no such set of puzzles."))
  // A slug is not an id.
  let assert Error(error.NotFound(_)) =
    practice.deck_page_json(ctx, signed_in(), "very_bad", now)
}

// ---------- A guest, and a stranger ----------

fn guest_source(id: String, grade: String, index: Int) {
  DeckSource(
    source_id: index,
    puzzle_id: id,
    game_id: "room1",
    game_number: 1,
    kind: "move",
    grade: grade,
    turn: index + 1,
    question_json: "{}",
    ended_ms: now - index,
    seat: seat.of_row(player_id: "p1", guest_id: Some("g1"), user_id: None),
  )
}

fn guest_ctx() -> Ctx {
  // Every practice cap panics: a guest has no deck to read.
  Ctx(
    ..fakes.ctx(),
    puzzles: PuzzlesCaps(..fakes.ctx().puzzles, guest_sources: fn(guest) {
      assert guest == "g1"
      [
        guest_source("a", "very_bad", 0),
        guest_source("b", "bad", 1),
        guest_source("c", "bad", 2),
        // `b` again, worse: it counts once, as very bad.
        guest_source("b", "very_bad", 3),
      ]
    }),
    decks: DeckCaps(..fakes.ctx().decks, size: fn(id) {
      list.key_find(built(), id) |> result.unwrap(0)
    }),
  )
}

pub fn a_guest_reads_their_own_tier_sizes_and_no_standing_test() {
  let body = practice.decks_json(guest_ctx(), fakes.guest("g1"), now)
  assert list.map(decks_of(body), fn(d) { #(d.id, d.size, d.joined) })
    == [
      #("very_bad", 2, False),
      #("bad", 1, False),
      #("doubtful", 0, False),
      #("openings", 15, False),
      #("opening_replies", 315, False),
    ]
  assert list.all(decks_of(body), fn(d) { d.standing == None })
  // Their worst tier with anything in it is the one in front.
  assert lead_of(body) == Some("very_bad")
  assert string.contains(body, "\"today\":null")
  assert int_at(body, ["streak"]) == 0
}

pub fn a_guest_reads_what_is_theirs_from_how_many_games_test() {
  let body = practice.decks_json(guest_ctx(), fakes.guest("g1"), now)
  // Three puzzles (b twice is one), all from the one room.
  assert int_at(body, ["mistakes", "puzzles"]) == 3
  assert int_at(body, ["mistakes", "games"]) == 1
}

pub fn every_deck_says_its_pace_and_a_set_its_line_test() {
  let body = practice.decks_json(guest_ctx(), fakes.guest("g1"), now)
  let read = {
    use id <- decode.field("id", decode.string)
    use pace <- decode.field("pace", decode.int)
    use blurb <- decode.field("blurb", decode.string)
    decode.success(#(id, pace, blurb != ""))
  }
  let assert Ok(decks) =
    json.parse(body, decode.at(["decks"], decode.list(read)))
  assert decks
    == [
      #("very_bad", deck.keep_going_new, False),
      #("bad", deck.keep_going_new, False),
      #("doubtful", deck.keep_going_new, False),
      #("openings", 5, True),
      #("opening_replies", 10, True),
    ]
}

pub fn an_account_and_a_stranger_have_no_guest_line_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      decks: DeckCaps(..fakes.ctx().decks, size: fn(id) {
        list.key_find(built(), id) |> result.unwrap(0)
      }),
    )
  assert string.contains(
    practice.decks_json(ctx, fakes.no_guest(), now),
    "\"mistakes\":null",
  )
}

pub fn a_guest_tier_page_is_their_count_and_nothing_kept_test() {
  let assert Ok(body) =
    practice.deck_page_json(guest_ctx(), fakes.guest("g1"), "bad", now)
  assert int_at(body, ["deck", "size"]) == 1
  assert string.contains(body, "\"standing\":null")
  assert string.contains(body, "\"cells\":[]")
  let assert Ok(days) =
    json.parse(body, decode.at(["days"], decode.list(decode.bool)))
  assert days == list.repeat(False, practice.month)
}

pub fn a_stranger_reads_the_five_and_nothing_of_anybody_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      decks: DeckCaps(..fakes.ctx().decks, size: fn(id) {
        list.key_find(built(), id) |> result.unwrap(0)
      }),
    )
  let body = practice.decks_json(ctx, fakes.no_guest(), now)
  assert list.map(decks_of(body), fn(d) { d.size }) == [0, 0, 0, 15, 315]
  assert lead_of(body) == None
  let assert Ok(page) =
    practice.deck_page_json(ctx, fakes.no_guest(), "openings", now)
  assert int_at(page, ["deck", "size"]) == 15
  assert string.contains(page, "\"cells\":[]")
}

fn list_len(body: String, path: List(String)) -> Int {
  let assert Ok(xs) =
    json.parse(body, decode.at(path, decode.list(decode.dynamic)))
  list.length(xs)
}

// ---------- A deck's page ----------

pub fn a_tier_page_draws_that_tier_s_cells_and_the_mistakes_month_test() {
  let ctx =
    account(
      [
        cell("v1", "very_bad", 2, now - 1, Active),
        cell("b1", "bad", 0, 0, New),
        Cell("b2", "bad", 5, now + 9, Suspended, None),
      ],
      Day(1, 3),
      [#("bad", 1)],
      [],
      built(),
    )
  let assert Ok(body) = practice.deck_page_json(ctx, signed_in(), "bad", now)
  assert int_at(body, ["deck", "size"]) == 2
  let cell_ids = {
    let assert Ok(ids) =
      json.parse(
        body,
        decode.at(["cells"], decode.list(decode.at(["id"], decode.string))),
      )
    ids
  }
  assert cell_ids == ["b1", "b2"]
  assert string.contains(
    body,
    "{\"id\":\"b2\",\"level\":5,\"due\":1800000000009,\"status\":\"suspended\",\"position\":null,\"band\":\"bad\"}",
  )
  assert string.contains(body, "\"status\":\"new\"")
  assert list_len(body, ["days"]) == 30
}

pub fn a_set_page_reads_the_set_s_own_scope_test() {
  let ctx =
    account(
      [],
      Day(0, 0),
      [],
      [#("openings", [cell("o1", "", 1, now + 9, Active)], Day(1, 4))],
      built(),
    )
  let assert Ok(body) =
    practice.deck_page_json(ctx, signed_in(), "openings", now)
  assert int_at(body, ["deck", "size"]) == 15
  assert string.contains(body, "\"id\":\"o1\"")
  assert string.contains(body, "\"band\":\"\"")
  // A set nobody added: the page is there, with nothing of theirs on it.
  let assert Ok(replies) =
    practice.deck_page_json(ctx, signed_in(), "opening-replies", now)
  assert string.contains(replies, "\"cells\":[]")
  assert string.contains(replies, "\"joined\":false")
}

// ---------- KEEP GOING through a set ----------

fn set_ctx(joined: Bool, started: fn(Int) -> Int) -> Ctx {
  Ctx(
    ..fakes.ctx(),
    decks: DeckCaps(
      ..fakes.ctx().decks,
      own: fn(_) { [] },
      size: fn(_) { 15 },
      practice: fn(scope) {
        assert scope == "deck:openings"
        PracticeCaps(
          ..fakes.ctx().practice,
          summary: fn(_, _) {
            case joined {
              True -> [Summary([], 15, 10, 5, 0, 0, 0.5)]
              False -> []
            }
          },
          ladder: fn(_) { [10, 5, 0, 0, 0, 0, 0, 0] },
          day: fn(_) { Day(answered: 5, new_remaining: 0) },
          start_new: fn(uid, n) {
            assert uid == "u1"
            started(n)
          },
          queue: fn(_, _) {
            Session(
              reviews: [
                Card("o1", [#("kind", "move")], "{}", 0, 0, 0, 0, Active),
              ],
              fresh: [],
              new_remaining_today: 0,
            )
          },
        )
      },
    ),
  )
}

pub fn keep_going_through_a_set_starts_its_own_pace_test() {
  let ctx =
    set_ctx(True, fn(n) {
      // The set's pace: five openings.
      assert n == 5
      n
    })
  let assert Ok(body) = decks_handler.more_json(ctx, signed_in(), "openings")
  assert string.contains(body, "\"id\":\"o1\"")
}

pub fn keep_going_through_a_set_needs_an_account_that_added_it_test() {
  let never = fn(_) { panic as "started a set nobody may start" }
  assert decks_handler.more_json(
      set_ctx(True, never),
      fakes.guest("g1"),
      "openings",
    )
    == Error(error.Conflict("sign_in", decks_handler.sign_in_message))
  assert decks_handler.more_json(set_ctx(False, never), signed_in(), "openings")
    == Error(error.Conflict("not_joined", "Add it first."))
  let assert Error(error.NotFound(_)) =
    decks_handler.more_json(set_ctx(True, never), signed_in(), "chess")
}

pub fn practice_anyway_through_a_set_only_once_its_queue_is_empty_test() {
  let empty_queue =
    Ctx(
      ..fakes.ctx(),
      decks: DeckCaps(..fakes.ctx().decks, size: fn(_) { 15 }, practice: fn(_) {
        PracticeCaps(
          ..fakes.ctx().practice,
          summary: fn(_, _) { [Summary([], 2, 0, 2, 0, 0, 1.0)] },
          ladder: fn(_) { [0, 2, 0, 0, 0, 0, 0, 0] },
          day: fn(_) { Day(answered: 2, new_remaining: 0) },
          queue: fn(_, _) {
            Session(reviews: [], fresh: [], new_remaining_today: 0)
          },
          cells: fn(_) {
            [
              cell("late", "", 1, now + 50, Active),
              cell("soon", "", 1, now + 10, Active),
            ]
          },
          cards: fn(_, keys) {
            list.map(keys, fn(k) {
              Card(k, [#("kind", "move")], "{}", 1, 0, 0, 0, Active)
            })
          },
        )
      }),
    )
  let assert Ok(plain) =
    decks_handler.session_all_json(empty_queue, signed_in(), "openings", False)
  assert string.contains(plain, "\"puzzles\":[]")
  let assert Ok(anyway) =
    decks_handler.session_all_json(empty_queue, signed_in(), "openings", True)
  let assert Ok(ids) =
    json.parse(
      anyway,
      decode.at(["puzzles"], decode.list(decode.at(["id"], decode.string))),
    )
  assert ids == ["soon", "late"]
  assert !string.contains(anyway, "\"due\":true")
  // A page further on: the rotation past the first one.
  let assert Ok(further) =
    decks_handler.session_from_json(
      empty_queue,
      signed_in(),
      "openings",
      True,
      1,
    )
  let assert Ok(rest) =
    json.parse(
      further,
      decode.at(["puzzles"], decode.list(decode.at(["id"], decode.string))),
    )
  assert rest == ["late"]
}

// ---------- What the mistakes cost ----------

fn totals(error: Float, decisions: Int) -> json.Json {
  json.object([
    #(
      "moves",
      json.object([
        #("decisions", json.int(decisions)),
        #("forced", json.int(0)),
        #("error", json.float(error)),
        #("grades", json.object([])),
      ]),
    ),
    #(
      "cube",
      json.object([
        #("decisions", json.int(0)),
        #("error", json.float(0.0)),
        #("mistakes", json.object([])),
      ]),
    ),
    #("luck", json.float(0.0)),
    #("error", json.float(error)),
    #("pr", json.float(0.0)),
  ])
}

fn graded(id: String, error: Float, decisions: Int) {
  RatedGame(
    game_id: id,
    game_number: 1,
    seat: 0,
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #(
          "players",
          json.preprocessed_array([totals(error, decisions), totals(1.0, 10)]),
        ),
      ]),
    ),
    ended_at_ms: 0,
  )
}

fn mistake(puzzle: String, band: String, game_id: String, lost: Float) {
  MistakeCost(
    puzzle_id: puzzle,
    band: band,
    game_id: game_id,
    game_number: 1,
    seat: seat.of_row(
      player_id: "p1",
      guest_id: Some("g1"),
      user_id: Some("u1"),
    ),
    equity_lost: lost,
  )
}

/// An account with three graded games behind it -- 100 decisions, 2.0
/// lost, PR 10.0 -- and these mistakes in them.
fn costed(cells: List(Cell)) -> Ctx {
  let ctx = account(cells, Day(0, 3), [], [], built())
  Ctx(
    ..ctx,
    analysis: AnalysisCaps(
      ..ctx.analysis,
      graded_for: fn(uid, _) {
        assert uid == "u1"
        [
          graded("g1", 0.75, 40),
          graded("g2", 0.625, 30),
          graded("g3", 0.625, 30),
        ]
      },
      mistake_costs: fn(uid) {
        assert uid == "u1"
        [
          mistake("v1", "very_bad", "g1", 0.375),
          mistake("v2", "very_bad", "g2", 0.125),
          // A bad move whose puzzle became a very bad card elsewhere:
          // costed in its own band, patched by its card wherever it sits.
          mistake("v2", "bad", "g3", 0.25),
        ]
      },
    ),
  )
}

fn cost_of(body: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.dynamic))
  let assert Ok(cost) =
    decode.run(
      value,
      decode.optional({
        use pr <- decode.field("pr", decode.float)
        use without <- decode.field("pr_without", decode.float)
        use patched <- decode.field("pr_patched", decode.float)
        decode.success(#(pr, without, patched))
      }),
    )
  string.inspect(cost)
}

pub fn a_tier_carries_what_its_mistakes_cost_and_a_set_does_not_test() {
  let ctx =
    costed([
      cell("v1", "very_bad", 1, now + 9, Active),
      // Patched: the fourth rung, still in rotation.
      cell("v2", "very_bad", 4, now + 9, Active),
    ])
  let body = practice.decks_json(ctx, signed_in(), now)
  assert string.contains(
    body,
    "\"cost\":{\"games\":2,\"lost\":0.5,\"lost_patched\":0.13,\"pr\":10.0,\"pr_without\":7.5,\"pr_patched\":9.4}",
  )
  // (2.0 - 0.25) / 100 * 500, and all of it patched.
  assert string.contains(
    body,
    "\"cost\":{\"games\":1,\"lost\":0.25,\"lost_patched\":0.25,\"pr\":10.0,\"pr_without\":8.8,\"pr_patched\":8.8}",
  )
  // Dubious: nothing lost, and the line still has its numbers.
  assert string.contains(
    body,
    "\"cost\":{\"games\":0,\"lost\":0.0,\"lost_patched\":0.0,\"pr\":10.0,\"pr_without\":10.0,\"pr_patched\":10.0}",
  )
  // The sets have none.
  assert string.contains(body, "\"id\":\"openings\"")
  assert list.length(string.split(body, "\"cost\":null")) == 3
  // And the headline: every band at once. (2.0 - 0.75) and (2.0 - 0.375).
  assert cost_of(body, ["cost_all"]) == "Some(#(10.0, 6.3, 8.1))"
}

pub fn a_card_put_away_is_not_patched_test() {
  let ctx =
    costed([
      cell("v1", "very_bad", 1, now + 9, Active),
      // NEVER at the top of the ladder: put away, not fixed.
      cell("v2", "very_bad", 7, now + 9, Suspended),
    ])
  let body = practice.decks_json(ctx, signed_in(), now)
  assert cost_of(body, ["cost_all"]) == "Some(#(10.0, 6.3, 10.0))"
}

pub fn a_tier_page_carries_its_cost_from_the_whole_deck_test() {
  let ctx =
    costed([
      cell("v1", "very_bad", 1, now + 9, Active),
      cell("v2", "very_bad", 4, now + 9, Active),
    ])
  // The bad tier's own cells are none, but its one row's puzzle is a very
  // bad card that is patched.
  let assert Ok(page) = practice.deck_page_json(ctx, signed_in(), "bad", now)
  assert cost_of(page, ["deck", "cost"]) == "Some(#(10.0, 8.8, 8.8))"
}

pub fn under_three_graded_games_there_is_no_cost_test() {
  let ctx =
    account(
      [cell("v1", "very_bad", 1, now + 9, Active)],
      Day(0, 3),
      [],
      [],
      built(),
    )
  let body = practice.decks_json(ctx, signed_in(), now)
  assert cost_of(body, ["cost_all"]) == "None"
  assert list.length(string.split(body, "\"cost\":null")) == 6
}

pub fn a_set_page_and_a_guest_read_no_rating_test() {
  // The analysis caps panic: neither may reach for a rating.
  let ctx =
    Ctx(
      ..account([], Day(0, 0), [], [#("openings", [], Day(0, 5))], built()),
      analysis: fakes.ctx().analysis,
    )
  let assert Ok(page) =
    practice.deck_page_json(ctx, signed_in(), "openings", now)
  assert cost_of(page, ["deck", "cost"]) == "None"

  let body = practice.decks_json(guest_ctx(), fakes.guest("g1"), now)
  assert cost_of(body, ["cost_all"]) == "None"
  assert list.length(string.split(body, "\"cost\":null")) == 6
}

// ---------- A deck page's head ----------

fn sized(built: List(#(String, Int))) -> Ctx {
  Ctx(
    ..fakes.ctx(),
    decks: DeckCaps(..fakes.ctx().decks, size: fn(id) {
      list.key_find(built, id) |> result.unwrap(0)
    }),
  )
}

pub fn a_tier_page_is_named_and_kept_out_of_search_test() {
  let assert Ok(head) =
    practice.deck_head(sized(built()), session.anonymous(), "very-bad")
  assert head
    == practice.DeckHead(
      title: "Very bad moves · Practice",
      description: "Your very bad moves, and how many you have stopped making.",
      indexable: False,
    )
  let assert Ok(dubious) =
    practice.deck_head(sized(built()), session.anonymous(), "dubious")
  assert dubious.title == "Dubious moves · Practice"
  assert dubious.indexable == False
}

pub fn a_set_page_is_its_blurb_and_indexable_test() {
  let assert Ok(head) =
    practice.deck_head(sized(built()), session.anonymous(), "openings")
  assert head
    == practice.DeckHead(
      title: "Openings · Practice",
      description: "The fifteen opening rolls, and the play for each.",
      indexable: True,
    )
  let assert Ok(replies) =
    practice.deck_head(sized(built()), session.anonymous(), "opening-replies")
  assert replies.title == "Opening replies · Practice"
  assert replies.indexable
}

pub fn a_head_for_nothing_is_a_404_test() {
  let missing = Error(error.NotFound("There is no such set of puzzles."))
  assert practice.deck_head(sized(built()), session.anonymous(), "nothing")
    == missing
  // A slug is not an id.
  assert practice.deck_head(sized(built()), session.anonymous(), "very_bad")
    == missing
  // A set nobody has built has no page.
  assert practice.deck_head(
      sized([#("openings", 15)]),
      session.anonymous(),
      "opening-replies",
    )
    == missing
}

pub fn the_sitemap_lists_the_built_sets_only_test() {
  assert practice.indexed_slugs(sized(built()))
    == ["openings", "opening-replies"]
  assert practice.indexed_slugs(sized([#("openings", 15)])) == ["openings"]
  assert practice.indexed_slugs(sized([])) == []
}

// ---------- A player's own sets ----------

const own_id = "K7M2Q9XA"

/// The account of `account`, with two sets of its own (the cap answers
/// them oldest first): one with a position in it, one empty.
fn with_own() -> Ctx {
  let ctx =
    account(
      [],
      Day(0, 0),
      [],
      [#(own_id, [cell("p1", "", 2, now + 9, Active)], Day(1, 4))],
      [#("openings", 15), #("opening_replies", 315), #(own_id, 1)],
    )
  Ctx(
    ..ctx,
    decks: DeckCaps(
      ..ctx.decks,
      own: fn(uid) {
        assert uid == "u1"
        [
          OwnDeck(own_id, "u1", "Back games", 5),
          OwnDeck("Z3W8R1PB", "u1", "Primes", 5),
        ]
      },
      members: fn(id) {
        case id {
          "K7M2Q9XA" -> [Member("p1", 1, "move", "{}")]
          _ -> []
        }
      },
    ),
  )
}

pub fn an_account_has_the_five_then_its_own_sets_by_creation_test() {
  assert list.map(catalog.all(with_own(), signed_in()), fn(d) { d.id })
    == [
      "very_bad", "bad", "doubtful", "openings", "opening_replies", own_id,
      "Z3W8R1PB",
    ]
  // A guest and a stranger have the five, and nobody's sets are read.
  assert list.length(catalog.all(fakes.ctx(), fakes.guest("g1"))) == 5
  assert list.length(catalog.all(fakes.ctx(), session.anonymous())) == 5
  let assert Ok(own) = catalog.find_slug(with_own(), signed_in(), own_id)
  assert catalog.kind_name(own) == "own"
  assert own.slug == own_id
}

pub fn the_hub_draws_an_own_set_as_kind_own_joined_even_empty_test() {
  let body = practice.decks_json(with_own(), signed_in(), now)
  let back = find(body, own_id)
  assert back.kind == "own"
  assert back.slug == own_id
  assert back.size == 1
  assert back.joined
  let primes = find(body, "Z3W8R1PB")
  assert primes.size == 0
  assert primes.joined
  assert string.contains(body, "\"name\":\"Back games\"")
  assert string.contains(body, "\"mark\":\"\"")
}

pub fn an_own_set_s_page_lists_what_is_in_it_for_its_owner_test() {
  let assert Ok(body) =
    practice.deck_page_json(with_own(), signed_in(), own_id, now)
  assert string.contains(
    body,
    "\"members\":[{\"id\":\"p1\",\"kind\":\"move\",\"prompt\":\"What's your play?\",\"position\":1,\"level\":2}]",
  )
  // An empty one has a page too, rather than a 404.
  let assert Ok(empty) =
    practice.deck_page_json(with_own(), signed_in(), "Z3W8R1PB", now)
  assert string.contains(empty, "\"members\":[]")
  // A universal set's page has no members list.
  let assert Ok(openings) =
    practice.deck_page_json(with_own(), signed_in(), "openings", now)
  assert string.contains(openings, "\"members\":null")
}

pub fn an_own_set_s_page_is_its_owner_s_alone_test() {
  let missing = Error(error.NotFound("There is no such set of puzzles."))
  let stranger = fakes.signed_in("g2", "u2")
  let ctx =
    Ctx(
      ..with_own(),
      decks: DeckCaps(..with_own().decks, own: fn(uid) {
        case uid {
          "u1" -> [OwnDeck(own_id, "u1", "Back games", 5)]
          _ -> []
        }
      }),
    )
  assert practice.deck_page_json(ctx, stranger, own_id, now) == missing
  assert practice.deck_page_json(ctx, fakes.guest("g1"), own_id, now) == missing
  let assert Error(error.NotFound(_)) =
    practice.deck_head(ctx, stranger, own_id)
  let assert Error(error.NotFound(_)) =
    practice.deck_head(ctx, session.anonymous(), own_id)
  // Its owner's head names it, and keeps it out of search.
  let assert Ok(head) = practice.deck_head(ctx, signed_in(), own_id)
  assert head.title == "Back games · Practice"
  assert !head.indexable
}

pub fn the_sitemap_never_reads_an_own_set_test() {
  // `sized`'s own cap panics: listing the sitemap asks nobody's sets.
  assert practice.indexed_slugs(sized(built()))
    == ["openings", "opening-replies"]
}
