//// Filling the deck, on stub capabilities: whose mistakes go in, in what
//// order, what is stamped afterwards, and what happens when the deck says
//// no.
////
//// Every capability the sync does not use still panics (fakes.ctx()), so a
//// change that reaches for IO this layer has no business doing -- a room, a
//// record, the engine -- fails loudly rather than quietly working.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/practice.{type Item, PracticeCaps}
import oskol/caps/puzzles.{type DeckSource, DeckSource, Pending, PuzzlesCaps} as _
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/fakes
import oskol/practice/sync
import oskol/puzzles.{type Question, Centered, Move, Question} as puzzle
import oskol/rooms/seat.{type Seat, Seat}

// ---------- The little world these tests run in ----------

/// A mistake on a seat: whose seat it is, which puzzle, and when the game
/// it came from ended.
fn source(id: Int, puzzle_id: String, owner: Seat, ended_ms: Int) -> DeckSource {
  DeckSource(
    source_id: id,
    puzzle_id: puzzle_id,
    kind: "move",
    question_json: json.to_string(puzzle.question_json(question())),
    ended_ms: ended_ms,
    seat: owner,
  )
}

fn question() -> Question {
  Question(
    kind: Move,
    board: list.repeat(0, 26),
    dice: Some(#(6, 4)),
    cube_value: 1,
    cube_owner: Centered,
    away_mover: 0,
    away_opponent: 0,
    crawford: False,
    jacoby: False,
  )
}

fn owned(player_id: String, user_id: String) -> Seat {
  Seat(player_id: player_id, guest_id: Some("a-guest"), user_id: Some(user_id))
}

fn unowned(player_id: String) -> Seat {
  Seat(player_id: player_id, guest_id: Some("a-guest"), user_id: None)
}

/// A deck that takes everything it is offered and a store that answers with
/// these sources, both of them writing down what they were asked.
fn with_deck(ctx: Ctx, sources: List(DeckSource)) -> Ctx {
  Ctx(
    ..ctx,
    practice: PracticeCaps(
      ..ctx.practice,
      put_user: fn(uid, tz, per_day) {
        record("opened", uid <> "/" <> tz <> "/" <> int.to_string(per_day))
        Ok(Nil)
      },
      put_items: fn(_uid, items) {
        list.each(items, fn(item: Item) {
          record(
            "enrolled",
            item.key
              <> " "
              <> tags(item)
              <> " @"
              <> int.to_string(option.unwrap(item.position, 0)),
          )
        })
        Ok(list.length(items))
      },
    ),
    puzzles: PuzzlesCaps(
      ..ctx.puzzles,
      owned_sources: fn(uid, game_ids) {
        record("asked", uid <> "/" <> string.join(game_ids, ","))
        sources
      },
      mark_synced: fn(ids) {
        list.each(ids, fn(id) { record("stamped", int.to_string(id)) })
        Nil
      },
      sync_failed: fn(ids, reason) {
        list.each(ids, fn(id) {
          record("failed", int.to_string(id) <> ": " <> reason)
        })
        Nil
      },
    ),
  )
}

fn tags(item: Item) -> String {
  item.tags
  |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
  |> string.join(",")
}

// ---------- Whose mistakes go in ----------

pub fn only_the_seats_an_account_owns_are_enrolled_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [
      source(1, "aaa", owned("p1", "arie"), 2000),
      // The opponent's seat in the same game, and a seat of this account's
      // that nobody owns: neither is this account's mistake.
      source(2, "bbb", owned("p2", "someone-else"), 2000),
      source(3, "ccc", unowned("p1"), 2000),
    ])

  assert sync.sync_deck(ctx, "arie", []) == Ok(1)
  assert recorded("enrolled") |> list.length == 1
  assert recorded("enrolled") |> list.any(string.starts_with(_, "aaa "))
  // Only the row that went in is stamped: the others are still nobody's.
  assert recorded("stamped") == ["1"]
}

pub fn an_account_with_nothing_owed_opens_no_deck_test() {
  forget()
  // put_user and put_items are the panicking stubs: reaching either would
  // fail this test, which is the point. An account that has never made a
  // mistake must not get a row merely for signing in.
  let ctx =
    Ctx(
      ..fakes.ctx(),
      puzzles: PuzzlesCaps(..fakes.ctx().puzzles, owned_sources: fn(_, _) { [] }),
    )

  assert sync.sync_deck(ctx, "arie", ["room1"]) == Ok(0)
}

pub fn nobody_is_never_synced_test() {
  forget()
  // Every capability panics: a sync with no account must not ask anything.
  assert sync.sync_deck(fakes.ctx(), "", []) == Ok(0)
}

// ---------- The order they are introduced in ----------

pub fn the_newest_game_comes_first_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [
      source(1, "old", owned("p1", "arie"), 1_600_000_000_000),
      source(2, "new", owned("p1", "arie"), 1_790_000_000_000),
      source(3, "middle", owned("p1", "arie"), 1_700_000_000_000),
    ])

  assert sync.sync_deck(ctx, "arie", []) == Ok(3)
  assert positions()
    == [
      #("new", -212_163_200),
      #("middle", -122_163_200),
      #("old", -22_163_200),
    ]
}

pub fn a_position_fits_the_column_it_is_stored_in_test() {
  // A 32-bit column: negated Unix milliseconds would not fit, and this is
  // what the sync stores instead. Both ends of the site's lifetime.
  let now = sync.position_of(1_790_000_000_000)
  let far = sync.position_of(3_000_000_000_000)
  assert now > -2_147_483_648 && now < 2_147_483_647
  assert far > -2_147_483_648 && far < 2_147_483_647
  // Newer is lower, which is what "newest first" means to the deck.
  assert far < now
}

pub fn one_card_per_puzzle_however_many_games_reached_it_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [
      source(1, "same", owned("p1", "arie"), 1_600_000_000_000),
      source(2, "same", owned("p1", "arie"), 1_790_000_000_000),
    ])

  assert sync.sync_deck(ctx, "arie", []) == Ok(1)
  // The newest of the two decides where it sits in the queue...
  assert positions() == [#("same", -212_163_200)]
  // ...and both rows are stamped, because the deck does hold them.
  assert list.sort(recorded("stamped"), string.compare) == ["1", "2"]
}

// ---------- What a card carries ----------

pub fn a_card_is_tagged_with_its_deck_and_its_kind_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [source(1, "aaa", owned("p1", "arie"), 2000)])
  let _ = sync.sync_deck(ctx, "arie", [])

  assert recorded("enrolled")
    |> list.any(string.contains(_, "deck=mistakes,kind=move"))
}

pub fn filling_a_deck_never_names_a_timezone_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [source(1, "aaa", owned("p1", "arie"), 2000)])
  let _ = sync.sync_deck(ctx, "arie", [])

  // An empty zone is "leave whatever this deck has alone": a sync has no
  // opinion about where its owner is, and saying UTC would undo the one
  // request that does.
  assert recorded("opened") == ["arie//10"]
}

// ---------- Idempotence, and giving up ----------

pub fn a_second_run_with_nothing_left_writes_nothing_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [source(1, "aaa", owned("p1", "arie"), 2000)])
  assert sync.sync_deck(ctx, "arie", []) == Ok(1)

  // The rows are stamped now, so the query offers nothing the second time
  // -- and the deck is not opened again.
  forget()
  let empty =
    Ctx(
      ..ctx,
      puzzles: PuzzlesCaps(..ctx.puzzles, owned_sources: fn(_, _) { [] }),
    )
  assert sync.sync_deck(empty, "arie", []) == Ok(0)
  assert recorded("opened") == []
  assert recorded("enrolled") == []
}

pub fn a_deck_that_refuses_leaves_the_rows_to_be_tried_again_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [
      source(1, "aaa", owned("p1", "arie"), 2000),
      source(2, "bbb", owned("p1", "arie"), 1000),
    ])
  let refusing =
    Ctx(
      ..ctx,
      practice: PracticeCaps(..ctx.practice, put_items: fn(_, _) {
        Error(practice.BadContent)
      }),
    )

  let assert Error(_) = sync.sync_deck(refusing, "arie", [])
  // Nothing is stamped, and both rows are told why, so the tries they have
  // been charged for can run out rather than the sweep coming back for
  // ever.
  assert recorded("stamped") == []
  assert list.length(recorded("failed")) == 2
}

// ---------- One game, and the sweep ----------

pub fn a_graded_game_syncs_the_accounts_that_own_its_seats_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [source(1, "aaa", owned("p1", "arie"), 2000)])
  let scoped =
    Ctx(
      ..ctx,
      puzzles: PuzzlesCaps(..ctx.puzzles, deck_pending: fn(games, _limit) {
        record("pending", string.join(games, ","))
        [Pending(user_id: "arie", game_ids: games, sources: 1)]
      }),
    )

  sync.sync_game(scoped, "room1")
  // It asks about that one game and no other, both times.
  assert recorded("pending") == ["room1"]
  assert recorded("asked") == ["arie/room1"]
  assert recorded("stamped") == ["1"]
}

pub fn the_sweep_asks_about_every_game_of_every_account_it_names_test() {
  forget()
  let ctx =
    with_deck(fakes.ctx(), [source(1, "aaa", owned("p1", "arie"), 2000)])
  let sweeping =
    Ctx(
      ..ctx,
      puzzles: PuzzlesCaps(..ctx.puzzles, deck_pending: fn(games, _limit) {
        record("pending", string.join(games, ","))
        [Pending(user_id: "arie", game_ids: ["room1"], sources: 1)]
      }),
    )

  assert sync.sweep(sweeping, 60) == [#("arie", Ok(1))]
  // Not narrowed to a game: the sweep is for whatever is left anywhere.
  assert recorded("pending") == [""]
  assert recorded("asked") == ["arie/"]
}

// ---------- Recording what the stubs were asked ----------

@external(erlang, "erlang", "put")
fn put(key: String, value: a) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

fn record(key: String, value: String) -> Nil {
  let _ = put(key, [value, ..newest_first(key)])
  Nil
}

/// In the order they happened. The process dictionary is written to head
/// first, which is the cheap way to keep a list, so reading it is the other
/// way round.
fn recorded(key: String) -> List(String) {
  list.reverse(newest_first(key))
}

fn newest_first(key: String) -> List(String) {
  case decode.run(get(key), decode.list(decode.string)) {
    Ok(values) -> values
    Error(_) -> []
  }
}

fn forget() -> Nil {
  list.each(
    ["opened", "enrolled", "asked", "stamped", "failed", "pending"],
    fn(key) {
      let _ = put(key, [])
      Nil
    },
  )
}

/// Each enrolled card as `#(key, position)`, in the order they were offered.
fn positions() -> List(#(String, Int)) {
  list.filter_map(recorded("enrolled"), fn(line) {
    case string.split(line, " @") {
      [head, position] ->
        case string.split(head, " "), int.parse(position) {
          [key, ..], Ok(value) -> Ok(#(key, value))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}
