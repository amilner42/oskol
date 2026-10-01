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
import oskol/caps/decks.{DeckCaps}
import oskol/caps/practice.{
  type Cell, type Day, type PracticeCaps, Active, Card, Cell, Day, New,
  PracticeCaps, Session, Summary, Suspended,
} as _
import oskol/caps/puzzles.{DeckSource, PuzzlesCaps}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
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
  assert list.map(catalog.all(), fn(d) { #(d.id, d.slug, d.name, d.mark) })
    == [
      #("very_bad", "very-bad", "Very bad moves", "??"),
      #("bad", "bad", "Bad moves", "?"),
      #("doubtful", "dubious", "Dubious moves", "?!"),
      #("openings", "openings", "Openings", ""),
      #("opening_replies", "opening-replies", "Opening replies", ""),
    ]
  assert list.map(catalog.all(), catalog.kind_name)
    == ["mistakes", "mistakes", "mistakes", "set", "set"]
}

pub fn a_deck_is_found_by_its_slug_and_by_its_id_test() {
  let assert Ok(d) = catalog.find_slug("dubious")
  assert d.id == "doubtful"
  assert d.kind == catalog.Mistakes("doubtful")
  let assert Ok(r) = catalog.find_id("opening_replies")
  assert r.slug == "opening-replies"
  // The id is not a slug and the slug is not an id.
  assert catalog.find_slug("doubtful") == Error(Nil)
  assert catalog.find_id("very-bad") == Error(Nil)
  assert catalog.find_slug("brilliant") == Error(Nil)
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
}
