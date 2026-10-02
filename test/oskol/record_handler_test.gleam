//// The record endpoint's decisions, on stub capabilities: who may read a
//// room's record, and what a game that keeps none answers.

import gamekit/clock
import gamekit/conformance
import gamekit/game.{Seat}
import gamekit/instance.{type Instance}
import gamekit/registry
import gleam/int
import gleam/list
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
      seated_game: fn(_, guest_id, user_id) {
        case guest_id, user_id {
          // The seat is g1's, and the account u1 owns it: either reaches it.
          Some("g1"), _ | _, Some("u1") ->
            result.map(game, fn(g) { #("p1", g) })
          _, _ -> Error(errors.NoSeat)
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
  assert string.starts_with(
    body,
    "{\"ok\":true,\"slug\":\"backgammon\",\"id\":\"000007\",\"you\":\"p1\","
      <> "\"seated\":true,\"accounts\":[],\"names\":{},\"record\":{",
  )
  // The record is the game's own, its fields in key order and its games
  // last (with whether each is the Crawford game).
  assert string.contains(
    body,
    "{\"color\":\"white\",\"id\":\"p1\",\"name\":\"Alice\"}",
  )
  assert string.contains(body, "\"target\":5")
  assert string.contains(body, "\"cube\":true")
  assert string.contains(body, "\"start\":{")
  // A game whose first turn is not committed yet has nothing to list
  assert string.contains(body, "\"games\":[]")
}

fn send(game: Instance, who: String, action: String) -> Instance {
  let assert Ok(raw) = conformance.parse(action)
  let assert Ok(#(next, _)) = instance.apply(game, who, raw, 0)
  next
}

fn other(id: String) -> String {
  case id {
    "p1" -> "p2"
    _ -> "p1"
  }
}

/// `who` resigns at `stakes` and the other accepts; then both press READY
/// for the next game.
fn resigned(game: Instance, who: String, stakes: String) -> Instance {
  let game =
    send(
      game,
      who,
      "{\"name\":\"resign\",\"params\":{\"stakes\":\"" <> stakes <> "\"}}",
    )
  let game =
    send(game, other(who), "{\"name\":\"accept_resign\",\"params\":{}}")
  let game = send(game, "p1", "{\"name\":\"ready\",\"params\":{}}")
  send(game, "p2", "{\"name\":\"ready\",\"params\":{}}")
}

pub fn a_live_record_names_the_crawford_game_test() {
  // A match to 3: the first mover resigns a gammon (2-0, one away), the
  // leader resigns the next game (2-1, the Crawford game), and the third
  // game begins.
  let game = started("backgammon", "match3")
  let assert [first] = instance.to_act(game)
  let game = resigned(game, first, "gammon")
  let game = resigned(game, other(first), "single")
  let ctx = room_with("backgammon", Ok(game))
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
  assert string.contains(body, "{\"number\":1,\"crawford\":false,\"entries\"")
  assert string.contains(body, "{\"number\":2,\"crawford\":true,\"entries\"")
}

/// One finished game's rows: a result line with the score it left.
fn result_row(number: Int, p1: Int, p2: Int) -> records_caps.StoredRecord {
  records_caps.StoredRecord(
    number,
    "[{\"kind\":\"take\",\"player\":\"p2\"},{\"kind\":\"game_over\",\"number\":"
      <> int.to_string(number)
      <> ",\"winner\":\"p1\",\"result\":\"single\",\"points\":1,\"cube\":1,"
      <> "\"scores\":{\"p1\":"
      <> int.to_string(p1)
      <> ",\"p2\":"
      <> int.to_string(p2)
      <> "}}]",
  )
}

pub fn a_stored_record_names_the_crawford_game_test() {
  // A match to 3 played to 2-2: 2-0, the Crawford game to 2-1, 2-2, and
  // the decider, which is no Crawford game though both are one away.
  let ctx =
    fakes.ctx()
    |> fakes.with_records(
      Some(records_caps.Setup(..finished_setup(), format: "match3")),
      [
        result_row(1, 2, 0),
        result_row(2, 2, 1),
        result_row(3, 2, 2),
        result_row(4, 3, 2),
      ],
    )
    |> fakes.with_room(None, None)
  let assert Ok(body) =
    record.record_json(ctx, fakes.guest("g1"), "backgammon", "000007")
  assert string.contains(body, "\"target\":3")
  let flags =
    list.map([1, 2, 3, 4], fn(n) {
      let on = "{\"number\":" <> int.to_string(n) <> ",\"crawford\":true,"
      let off = "{\"number\":" <> int.to_string(n) <> ",\"crawford\":false,"
      assert string.contains(body, on) != string.contains(body, off)
      string.contains(body, on)
    })
  assert flags == [False, True, False, False]
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
    clock: "none",
    seed: 7,
    seats: [#("p1", "Alice", "g1", ""), #("p2", "Bob", "g2", "")],
    finished: True,
    records_stale: False,
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
    "\"games\":[{\"number\":1,\"crawford\":false,\"entries\":[{\"kind\":\"result\",\"winner\":\"p1\"}]}]",
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

pub fn a_stored_record_faces_an_owned_seat_to_its_account_only_test() {
  // p2 was played by guest g2 and then its player signed in: the seat is
  // owned by u2 now, and the guest on it is history.
  let owned =
    records_caps.Setup(..finished_setup(), seats: [
      #("p1", "Alice", "g1", ""),
      #("p2", "Bob", "g2", "u2"),
    ])
  let ctx =
    fakes.ctx()
    |> fakes.with_records(Some(owned), one_row())
    |> fakes.with_room(None, None)

  // The account, from a browser that never played it: its own seat.
  let assert Ok(mine) =
    record.record_json(
      ctx,
      fakes.signed_in("a-new-phone", "u2"),
      "backgammon",
      "000007",
    )
  assert string.contains(mine, "\"you\":\"p2\"")
  assert string.contains(mine, "\"seated\":true")

  // The browser that played it, logged out (or the next person on that
  // laptop): not its seat any more.
  let assert Ok(old) =
    record.record_json(ctx, fakes.guest("g2"), "backgammon", "000007")
  assert string.contains(old, "\"seated\":false")
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
