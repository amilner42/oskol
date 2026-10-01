//// The universal decks' rules on stub caps: which positions the opening
//// decks hold, what a player's standing on a deck is, what adding one
//// writes, and who gets a queue rather than a walk. The whole build against
//// the real tables is test/oskol/decks_build_test.exs.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/decks.{DeckCaps, Member}
import oskol/caps/practice.{Card, Day, New, PracticeCaps, Session, Summary}
import oskol/core/ctx.{Ctx}
import oskol/fakes
import oskol/handlers/decks as handler
import oskol/practice/decks as registry
import oskol/practice/openings
import oskol/puzzles as puzzle
import oskol/reviews/report

// ---------- The positions ----------

pub fn there_are_fifteen_openings_and_no_double_among_them_test() {
  let rolls = openings.opening_rolls()
  assert list.length(rolls) == 15
  assert list.length(list.unique(rolls)) == 15
  assert list.all(rolls, fn(r) { r.0 > r.1 && r.1 >= 1 && r.0 <= 6 })
  assert list.first(rolls) == Ok(#(2, 1))
  assert list.last(rolls) == Ok(#(6, 5))
}

pub fn a_reply_can_be_any_of_the_twenty_one_rolls_test() {
  let rolls = openings.all_rolls()
  assert list.length(rolls) == 21
  assert list.length(list.unique(rolls)) == 21
  assert list.count(rolls, fn(r) { r.0 == r.1 }) == 6
}

pub fn an_opening_is_money_play_with_jacoby_and_the_cube_in_the_middle_test() {
  let q = openings.question(openings.start(), #(6, 4))
  assert q.kind == puzzle.Move
  assert q.dice == Some(#(6, 4))
  assert q.cube_value == 1
  assert q.cube_owner == puzzle.Centered
  assert q.away_mover == 0 && q.away_opponent == 0
  assert q.jacoby
  assert !q.crawford
  assert puzzle.prompt(q) == "White to play 6-4. What's your play?"
}

pub fn a_turn_names_a_legal_play_of_the_roll_test() {
  let assert Ok(turn) = openings.turn(openings.start(), #(6, 5))
  let assert Some(played) = turn.played
  // Eleven pips moved: the mover's checkers are the positive cells, each
  // counted by the point it sits on.
  let pips = fn(board: List(Int)) {
    board
    |> list.index_map(fn(n, i) { int.max(n, 0) * i })
    |> int.sum
  }
  assert pips(openings.start()) - pips(played) == 11
  assert turn.dice == Some(#(6, 5))
}

pub fn a_reply_is_played_from_the_openers_board_turned_round_test() {
  // Turned round twice is where it started.
  let board = openings.start()
  assert openings.after(openings.after(board)) == board
  // The starting position is the same from either side.
  assert openings.after(board) == board
}

pub fn replies_are_grouped_by_the_opening_they_answer_test() {
  assert openings.reply_position(1, 1) < openings.reply_position(1, 21)
  assert openings.reply_position(1, 21) < openings.reply_position(2, 1)
}

// ---------- Trusting an answer ----------

fn candidate(rank: Int, board: List(Int)) -> report.Candidate {
  report.Candidate(
    rank: rank,
    notation: "13/7 8/7",
    equity: 0.1,
    equity_diff: 0.0 -. int.to_float(rank - 1) *. 0.01,
    probs: report.Probs(0.5, 0.1, 0.0, 0.1, 0.0),
    board: board,
  )
}

fn moved(results: Int, n_legal: Int, top: List(report.Candidate)) {
  let assert [best, ..] = top
  report.TurnReview(
    index: 0,
    player: 0,
    cube: None,
    move: Some(report.Moved(
      played: best,
      best: best,
      top: top,
      results: list.repeat(report.MoveResult([0], 0.0), results),
      n_legal: n_legal,
      forced: False,
      error: 0.0,
      grade: "best",
    )),
    luck: None,
  )
}

pub fn an_answer_with_every_legal_play_is_trusted_test() {
  let top = list.map(list.range(1, 7), candidate(_, [1, 2, 3]))
  let assert Ok(puzzle.MoveAnswer(complete: True, candidates: kept, ..)) =
    openings.answer(moved(12, 12, top))
  // The top five, and never the play the request happened to name.
  assert list.all(kept, fn(c) { c.rank <= 5 })
}

pub fn an_answer_short_of_every_legal_play_is_not_test() {
  let top = [candidate(1, [1])]
  let assert Error(why) = openings.answer(moved(3, 12, top))
  assert string.contains(why, "every legal play")
}

pub fn a_candidate_without_its_board_is_not_test() {
  let top = [candidate(1, [1]), candidate(2, [])]
  let assert Error(_) = openings.answer(moved(2, 2, top))
}

// ---------- A player's standing ----------

fn ladder_ctx(summary, ladder: List(Int), new_remaining: Int) {
  Ctx(
    ..fakes.ctx(),
    decks: DeckCaps(..fakes.ctx().decks, practice: fn(_) {
      PracticeCaps(
        ..fakes.ctx().practice,
        summary: fn(_, _) { summary },
        ladder: fn(_) { ladder },
        day: fn(_) { Day(answered: 0, new_remaining: new_remaining) },
      )
    }),
  )
}

pub fn standing_is_untouched_in_progress_and_patched_test() {
  // 15 positions: 6 never shown, 5 on the lower rungs, 4 at level 4 and up.
  let ctx =
    ladder_ctx([Summary([], 15, 6, 9, 0, 3, 1.2)], [7, 1, 2, 1, 2, 1, 1, 0], 2)
  let assert Ok(openings_deck) = registry.find(registry.openings_id)
  let s = registry.standing(ctx, openings_deck, "u1")
  assert s.total == 15
  assert s.patched == 4
  assert s.in_progress == 5
  assert s.due == 3
  // Six never shown, but the day allows two more.
  assert s.new_left == 2
  assert registry.left(s) == 11
  assert registry.joined(s)
}

pub fn a_deck_nobody_added_stands_at_nothing_test() {
  let ctx = ladder_ctx([], [0, 0, 0, 0, 0, 0, 0, 0], 0)
  let assert Ok(openings_deck) = registry.find(registry.openings_id)
  let s = registry.standing(ctx, openings_deck, "u1")
  assert !registry.joined(s)
  assert s == registry.Standing(0, 0, 0, 0, 0)
}

// ---------- Adding a deck, and playing one ----------

fn member(id: String, position: Int) {
  let q = openings.question(openings.start(), #(2, 1))
  Member(
    puzzle_id: id,
    position: position,
    kind: "move",
    question_json: json.to_string(puzzle.question_json(q)),
  )
}

pub fn adding_a_deck_puts_every_position_in_it_in_order_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      decks: DeckCaps(
        ..fakes.ctx().decks,
        members: fn(deck) {
          assert deck == "openings"
          [member("AAAAAAAA", 1), member("BBBBBBBB", 2)]
        },
        size: fn(_) { 2 },
        practice: fn(scope) {
          assert scope == "deck:openings"
          PracticeCaps(
            ..fakes.ctx().practice,
            put_user: fn(uid, tz, per_day) {
              assert uid == "u1"
              assert tz == "Europe/Paris"
              assert per_day == 5
              Ok(Nil)
            },
            put_items: fn(uid, items) {
              assert uid == "u1"
              assert list.map(items, fn(i: practice.Item) { i.key })
                == ["AAAAAAAA", "BBBBBBBB"]
              assert list.map(items, fn(i: practice.Item) { i.position })
                == [Some(1), Some(2)]
              assert list.all(items, fn(i: practice.Item) {
                i.tags == [#("deck", "openings"), #("kind", "move")]
              })
              Ok(2)
            },
            // After adding: the queue, the standing and the day.
            queue: fn(_, _) {
              Session(
                reviews: [],
                fresh: [
                  Card(
                    "AAAAAAAA",
                    [#("deck", "openings"), #("kind", "move")],
                    member("AAAAAAAA", 1).question_json,
                    0,
                    0,
                    0,
                    0,
                    New,
                  ),
                ],
                new_remaining_today: 5,
              )
            },
            summary: fn(_, _) { [Summary([], 2, 2, 0, 0, 0, 0.0)] },
            ladder: fn(_) { [2, 0, 0, 0, 0, 0, 0, 0] },
            day: fn(_) { Day(answered: 0, new_remaining: 5) },
          )
        },
      ),
    )
  let assert Ok(body) =
    handler.join_json(
      ctx,
      fakes.signed_in("g1", "u1"),
      "openings",
      "Europe/Paris",
    )
  assert string.contains(body, "\"id\":\"AAAAAAAA\"")
  assert string.contains(body, "\"joined\":true")
  assert string.contains(body, "White to play 2-1. What's your play?")
}

pub fn a_guest_walks_the_deck_and_cannot_add_it_test() {
  let ctx =
    Ctx(
      ..fakes.ctx(),
      decks: DeckCaps(
        ..fakes.ctx().decks,
        members: fn(_) { [member("AAAAAAAA", 1), member("BBBBBBBB", 2)] },
        size: fn(_) { 2 },
      ),
    )
  // Nothing scheduled and nothing written: the deck in its order.
  let assert Ok(body) = handler.session_json(ctx, fakes.guest("g1"), "openings")
  assert string.contains(body, "\"standing\":null")
  let assert Ok(a) = string.split_once(body, "AAAAAAAA")
  assert string.contains(a.1, "BBBBBBBB")
  let assert Error(_) =
    handler.join_json(ctx, fakes.guest("g1"), "openings", "")
}

pub fn a_deck_with_nothing_built_is_not_offered_test() {
  let ctx =
    Ctx(..fakes.ctx(), decks: DeckCaps(..fakes.ctx().decks, size: fn(_) { 0 }))
  assert handler.list_json(ctx, fakes.guest("g1"))
    == "{\"ok\":true,\"decks\":[],\"patched_level\":4}"
  let assert Error(_) = handler.session_json(ctx, fakes.guest("g1"), "openings")
  let assert Error(_) = handler.session_json(ctx, fakes.guest("g1"), "no-such")
}

pub fn a_decks_scope_is_never_the_mistakes_one_test() {
  list.each(registry.all(), fn(d) {
    assert string.starts_with(registry.scope(d), "deck:")
  })
}
