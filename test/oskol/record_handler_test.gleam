//// The record endpoint's decisions, on stub capabilities: who may read a
//// room's record, and what a game that keeps none answers.

import gamekit/clock
import gamekit/game.{Seat}
import gamekit/instance.{type Instance}
import gamekit/registry
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oskol/caps/records as records_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/record
import oskol/rooms/errors

fn started(slug: String, format: String) -> Instance {
  let assert Ok(entry) = registry.find(slug)
  let assert Ok(game) =
    entry.start(
      format,
      [],
      [Seat("p1", "Alice"), Seat("p2", "Bob")],
      7,
      clock.NoClock,
      0,
    )
  game
}

/// A live room playing `slug`, where the guest "g1" holds the seat "p1".
/// Nothing is written down for it, so every read goes to the room.
fn room_with(slug: String, game: Result(Instance, errors.RoomError)) -> Ctx {
  let ctx =
    fakes.ctx()
    |> fakes.with_room(Some(fakes.room()), None)
    |> fakes.with_slug(Some(slug))
    |> fakes.with_records(None, [])
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      seated_game: fn(_, guest_id) {
        case guest_id {
          "g1" -> result.map(game, fn(g) { #("p1", g) })
          _ -> Error(errors.NoSeat)
        }
      },
      game: fn(_) { game },
    ),
  )
}

pub fn a_seat_reads_the_whole_record_test() {
  let game = started("backgammon", "match5")
  let ctx = room_with("backgammon", Ok(game))
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
  let assert Some(expected) = instance.record(game)
  assert body
    == json.to_string(
      json.object([
        #("ok", json.bool(True)),
        #("slug", json.string("backgammon")),
        #("id", json.string("000007")),
        #("you", json.string("p1")),
        #("seated", json.bool(True)),
        #("record", expected),
      ]),
    )
  // A game whose first turn is not committed yet has nothing to list
  assert string.contains(body, "\"target\":5,\"cube\":true,")
  assert string.contains(body, "\"games\":[]")
}

pub fn a_guest_at_no_seat_here_still_reads_the_record_test() {
  // A record is every committed turn, which both players and any spectator
  // already saw: the reader's guest only says which way the board faces.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("stranger"), "backgammon", "000007")
  assert string.contains(body, "\"you\":\"p1\"")
  // ...and that the seat it faces is not the reader's own.
  assert string.contains(body, "\"seated\":false")
}

pub fn no_guest_at_all_reads_the_record_from_the_first_seat_test() {
  // A visitor with no guest cookie: the record opens, facing the seat that
  // played first, and the room is never asked who they are.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  let assert Ok(body) =
    record.record_json(ctx, fakes.no_guest(), "backgammon", "000007")
  assert string.contains(body, "\"you\":\"p1\"")
  assert string.contains(body, "\"seated\":false")
}

pub fn a_guest_on_a_seat_is_told_the_record_is_their_own_test() {
  // The one thing the reader's guest still decides: the board opens on
  // their own seat, and the page may say so.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
  assert string.contains(body, "\"seated\":true")
}

pub fn a_room_asked_for_under_another_game_reads_nothing_test() {
  // A backgammon room, asked for as a game it is not (poker was one; it is
  // gone, and its old URLs redirect home): the same not-found as any refusal.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  assert record.record_json(ctx, fakes.guest("g1"), "poker", "000007")
    == Error(error.NotFound(record.not_found_message))
}

pub fn a_room_that_is_gone_reads_nothing_test() {
  let ctx =
    fakes.ctx() |> fakes.with_room(None, None) |> fakes.with_records(None, [])
  assert record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
    == Error(error.NotFound(record.not_found_message))
}

pub fn a_lobby_has_no_record_yet_test() {
  let ctx = room_with("backgammon", Error(errors.GameNotStarted))
  assert record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
    == Error(error.NotFound(record.not_found_message))
}

// ---------- `record.seat`: the gate on anything that costs ----------

pub fn only_a_guest_on_a_seat_passes_the_seat_gate_test() {
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))

  let assert Ok(#(player_id, _)) =
    record.seat(ctx, fakes.guest("g1"), "backgammon", "000007")
  assert player_id == "p1"

  // A stranger who walked into the room code, and a visitor with no guest
  // cookie at all, both get the answer a room that is not there gives.
  assert record.seat(ctx, fakes.guest("stranger"), "backgammon", "000007")
    == Error(error.NotFound(record.not_found_message))
  assert record.seat(ctx, fakes.no_guest(), "backgammon", "000007")
    == Error(error.NotFound(record.not_found_message))
}

// ---------- A room that is over reads its record out of rows ----------

/// What the persisted `games` row says about a finished backgammon match.
fn finished_setup() -> records_caps.Setup {
  records_caps.Setup(
    slug: "backgammon",
    format: "match5",
    selections: [],
    clock: "none",
    seed: 7,
    seats: [#("p1", "Alice", "g1"), #("p2", "Bob", "g2")],
    finished: True,
    log_length: 0,
    records_through: 0,
  )
}

/// A room nobody is at, whose games are written down. Every room cap but
/// the registry lookup panics: reading a stored record must never wake a
/// room up, which is the whole point -- waking one replays its log, and a
/// room nobody is at is exactly the one a replay page asks about.
fn stored_room(rows: List(records_caps.StoredRecord)) -> Ctx {
  fakes.ctx()
  |> fakes.with_records(Some(finished_setup()), rows)
  |> fakes.with_room(None, None)
}

fn one_row() -> List(records_caps.StoredRecord) {
  [records_caps.StoredRecord(1, "[{\"kind\":\"result\",\"winner\":\"p1\"}]")]
}

pub fn a_finished_room_reads_its_record_from_rows_test() {
  let assert Ok(body) =
    record.record_json(
      stored_room(one_row()),
      fakes.guest("g1"),
      "backgammon",
      "000007",
    )
  // The head is the room's game started and left alone: who played which
  // colour, the match length, the position it opened from.
  assert string.contains(body, "\"target\":5")
  assert string.contains(body, "\"cube\":true")
  assert string.contains(
    body,
    "{\"color\":\"white\",\"id\":\"p1\",\"name\":\"Alice\"}",
  )
  // ...and the games are the rows, verbatim.
  assert string.contains(
    body,
    "\"games\":[{\"number\":1,\"entries\":[{\"kind\":\"result\",\"winner\":\"p1\"}]}]",
  )
  assert string.contains(body, "\"seated\":true")
  assert string.contains(body, "\"you\":\"p1\"")
}

pub fn a_stored_record_faces_the_readers_own_seat_test() {
  let rows = one_row()
  let assert Ok(mine) =
    record.record_json(
      stored_room(rows),
      fakes.guest("g2"),
      "backgammon",
      "000007",
    )
  assert string.contains(mine, "\"you\":\"p2\"")
  assert string.contains(mine, "\"seated\":true")

  // A stranger, and a visitor with no guest cookie at all: the seat that
  // played first, and told it is not theirs.
  let assert Ok(theirs) =
    record.record_json(
      stored_room(rows),
      fakes.guest("nobody"),
      "backgammon",
      "000007",
    )
  assert string.contains(theirs, "\"you\":\"p1\"")
  assert string.contains(theirs, "\"seated\":false")

  let assert Ok(anon) =
    record.record_json(
      stored_room(rows),
      fakes.no_guest(),
      "backgammon",
      "000007",
    )
  assert string.contains(anon, "\"seated\":false")
}

pub fn a_stored_room_asked_for_under_another_game_reads_nothing_test() {
  // It falls through to the room, which is not there: the one not-found.
  let ctx =
    stored_room(one_row())
    |> fakes.with_room(None, None)
  assert record.record_json(ctx, fakes.guest("g1"), "poker", "000007")
    == Error(error.NotFound(record.not_found_message))
}

pub fn a_room_still_in_memory_is_read_from_the_room_test() {
  // Reading a live room is free and carries the game on the board, which
  // is not written down anywhere until it ends. Rows or no rows.
  let ctx =
    room_with("backgammon", Ok(started("backgammon", "single")))
    |> fakes.with_records(Some(finished_setup()), one_row())
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
  assert string.contains(body, "\"games\":[]")
}
