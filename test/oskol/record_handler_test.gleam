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

/// A live room playing `slug`, whose seat token "good" opens `game`.
fn room_with(slug: String, game: Result(Instance, errors.RoomError)) -> Ctx {
  let ctx =
    fakes.ctx()
    |> fakes.with_room(Some(fakes.room()), None)
    |> fakes.with_slug(Some(slug))
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      seated_game: fn(_, token) {
        case token {
          "good" -> result.map(game, fn(g) { #("p1", g) })
          _ -> Error(errors.InvalidToken)
        }
      },
      game: fn(_) { game },
    ),
  )
}

pub fn a_seat_reads_the_whole_record_test() {
  let game = started("backgammon", "match5")
  let ctx = room_with("backgammon", Ok(game))
  let assert Ok(body) = record.record_json(ctx, "backgammon", "000007", "good")
  let assert Some(expected) = instance.record(game)
  assert body
    == json.to_string(
      json.object([
        #("ok", json.bool(True)),
        #("slug", json.string("backgammon")),
        #("id", json.string("000007")),
        #("you", json.string("p1")),
        #("record", expected),
      ]),
    )
  // A game whose first turn is not committed yet has nothing to list
  assert string.contains(body, "\"target\":5,\"cube\":true,")
  assert string.contains(body, "\"games\":[]")
}

pub fn a_token_that_opens_no_seat_still_reads_the_record_test() {
  // A record is every committed turn, which both players and any spectator
  // already saw: a token only says which way the board faces.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  let assert Ok(body) =
    record.record_json(ctx, "backgammon", "000007", "stolen")
  assert string.contains(body, "\"you\":\"p1\"")
}

pub fn no_token_reads_the_record_from_the_first_seat_test() {
  // No token at all: the record opens, facing the seat that played first.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  let assert Ok(body) = record.record_json(ctx, "backgammon", "000007", "")
  assert string.contains(body, "\"you\":\"p1\"")
}

pub fn a_room_asked_for_under_another_game_reads_nothing_test() {
  // A backgammon room, asked for as a game it is not (poker was one; it is
  // gone, and its old URLs redirect home): the same not-found as any refusal.
  let ctx = room_with("backgammon", Ok(started("backgammon", "single")))
  assert record.record_json(ctx, "poker", "000007", "good")
    == Error(error.NotFound(record.not_found_message))
}

pub fn a_room_that_is_gone_reads_nothing_test() {
  let ctx = fakes.ctx() |> fakes.with_room(None, None)
  assert record.record_json(ctx, "backgammon", "000007", "good")
    == Error(error.NotFound(record.not_found_message))
}

pub fn a_lobby_has_no_record_yet_test() {
  let ctx = room_with("backgammon", Error(errors.GameNotStarted))
  assert record.record_json(ctx, "backgammon", "000007", "good")
    == Error(error.NotFound(record.not_found_message))
}
