//// Sharing a replay step (`oskol/handlers/positions`), on stubs, over the
//// seeded match at 821900 (`priv/dev/rooms/821900.json`): its stored
//// records, its stored reviews and its action log. The log is replayed
//// here, and only here, to say what the review job itself asked at each
//// step (`analysis.games`), so a share is held to the very question
//// `extract` writes for a mistake there.
////
//// The seeded reviews predate `all_results`, so every checker play in them
//// is short of the whole list of plays: exactly the old answer a share
//// must refuse. `completed` gives a copy every legal play, which is what an
//// answer from today's engine carries.

import backgammon/analysis.{type GameTurns, type Turn}
import backgammon/game as backgammon
import backgammon/record
import gamekit/clock
import gamekit/game.{Seat}
import gamekit/replay
import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/analysis as analysis_caps
import oskol/caps/puzzles.{type NewPuzzle, type ReplayLink, ReplayLink} as puzzles_caps
import oskol/caps/records
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/core/raw
import oskol/fakes
import oskol/handlers/positions
import oskol/puzzles

@external(erlang, "oskol_test_files", "read")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "erlang", "put")
fn put_writes(
  key: String,
  value: List(#(NewPuzzle, String, Option(ReplayLink))),
) -> Dynamic

@external(erlang, "erlang", "get")
fn get_writes(key: String) -> List(#(NewPuzzle, String, Option(ReplayLink)))

@external(erlang, "erlang", "put")
fn put_drawn(key: String, value: List(String)) -> Dynamic

@external(erlang, "erlang", "get")
fn get_drawn(key: String) -> List(String)

const room = "821900"

// ---------- The seeded room ----------

type Fixture {
  Fixture(
    seats: List(#(String, String)),
    seed: Int,
    format: String,
    records: List(records.StoredRecord),
    /// Each game's stored engine answer, as text.
    answers: List(#(Int, String)),
    actions: List(replay.Entry),
  )
}

fn fixture() -> Fixture {
  let assert Ok(bytes) = read_file("priv/dev/rooms/" <> room <> ".json")
  let assert Ok(text) = bit_array.to_string(bytes)
  let shape = {
    use seats <- decode.subfield(
      ["game", "players"],
      decode.list({
        use id <- decode.field("id", decode.string)
        use name <- decode.field("name", decode.string)
        decode.success(#(id, name))
      }),
    )
    use seed <- decode.subfield(["game", "seed"], decode.int)
    use format <- decode.subfield(["game", "config", "format"], decode.string)
    use rows <- decode.field(
      "records",
      decode.list({
        use number <- decode.field("game_number", decode.int)
        use entries <- decode.field("entries", decode.dynamic)
        decode.success(records.StoredRecord(number, raw.text(entries)))
      }),
    )
    use answers <- decode.field(
      "reviews",
      decode.list({
        use number <- decode.field("game_number", decode.int)
        use response <- decode.field("response", decode.dynamic)
        decode.success(#(number, raw.text(response)))
      }),
    )
    use actions <- decode.field(
      "actions",
      decode.list({
        use player_id <- decode.field("player_id", decode.string)
        use payload <- decode.field("payload", decode.dynamic)
        use at <- decode.field("at_ms", decode.int)
        decode.success(replay.Act(player_id, payload, at))
      }),
    )
    decode.success(Fixture(seats, seed, format, rows, answers, actions))
  }
  let assert Ok(f) = json.parse(text, shape)
  f
}

/// What the review job asked about each game: the room's log replayed.
fn replayed(f: Fixture) -> List(GameTurns) {
  let assert Ok(games) =
    analysis.games(
      backgammon.game(),
      replay.Log(
        format_id: f.format,
        seats: list.map(f.seats, fn(s) { Seat(id: s.0, name: s.1) }),
        seed: f.seed,
        control: clock.NoClock,
        entries: f.actions,
      ),
    )
  games
}

fn setup_of(f: Fixture, format: String) -> records.Setup {
  records.Setup(
    slug: "backgammon",
    format: format,
    clock: "none",
    seed: f.seed,
    seats: list.map(f.seats, fn(s) { #(s.0, s.1, "", "") }),
    finished: False,
    records_stale: False,
  )
}

fn done(number: Int, response: String) -> analysis_caps.Stored {
  analysis_caps.Stored(
    game_number: number,
    status: analysis_caps.Done,
    attempts: 1,
    response_json: Some(response),
    answered: True,
    rendered: True,
    turns: 0,
  )
}

/// Every game's stored answer, each checker play given every legal play.
fn graded(f: Fixture) -> fn(Int) -> Option(analysis_caps.Stored) {
  fn(number) {
    list.key_find(f.answers, number)
    |> result.map(fn(text) { done(number, completed(text)) })
    |> option.from_result
  }
}

/// A context over one room: its setup and record rows, one game's review
/// row as `review` says, and a puzzle store that writes down what it was
/// asked to write. Everything else panics -- `puzzles.store` among it, the
/// only way a source row is ever written.
fn ctx_over(
  setup: records.Setup,
  rows: List(records.StoredRecord),
  review: fn(Int) -> Option(analysis_caps.Stored),
) -> Ctx {
  let _ = put_writes("writes", [])
  let _ = put_drawn("drawn", [])
  let base = fakes.ctx()
  Ctx(
    ..base,
    records: records.RecordsCaps(
      ..records.stub(),
      setup: fn(_) { Some(setup) },
      stored: fn(_) { rows },
    ),
    analysis: analysis_caps.AnalysisCaps(
      ..analysis_caps.stub(),
      stored_one: fn(_, number) { review(number) },
    ),
    puzzles: puzzles_caps.PuzzlesCaps(
      ..puzzles_caps.stub(),
      store_one: fn(p, origin, link) {
        let _ =
          put_writes("writes", [#(p, origin, link), ..get_writes("writes")])
        Ok(list.first(p.ids) |> result.unwrap(""))
      },
      pictures_one: fn(id) {
        let _ = put_drawn("drawn", [id, ..get_drawn("drawn")])
        Nil
      },
    ),
  )
}

fn seeded() -> #(Fixture, Ctx) {
  let f = fixture()
  #(f, ctx_over(setup_of(f, f.format), f.records, graded(f)))
}

// ---------- Giving an old answer every legal play ----------

/// The stored answer with `results` on every checker play: `n_legal` of
/// them, the best play's board first. What a share reads them for is that
/// they are all there.
fn completed(response: String) -> String {
  let assert Ok(top) =
    json.parse(response, decode.dict(decode.string, decode.dynamic))
  let assert Ok(turns) =
    dict.get(top, "turns")
    |> result.try(fn(t) {
      decode.run(t, decode.list(decode.dict(decode.string, decode.dynamic)))
      |> result.replace_error(Nil)
    })
  let turns =
    list.map(turns, fn(turn) {
      let move =
        dict.get(turn, "move")
        |> result.try(fn(m) {
          decode.run(m, decode.dict(decode.string, decode.dynamic))
          |> result.replace_error(Nil)
        })
      let fields = case move {
        Ok(m) ->
          case
            dict.get(m, "n_legal")
            |> result.try(fn(n) {
              decode.run(n, decode.int) |> result.replace_error(Nil)
            }),
            dict.get(m, "best")
            |> result.try(fn(b) {
              decode.run(b, decode.at(["board"], decode.list(decode.int)))
              |> result.replace_error(Nil)
            })
          {
            Ok(n), Ok(board) -> {
              let results =
                json.array(list.range(0, n - 1), fn(i) {
                  json.object([
                    #("board", json.array(board, json.int)),
                    #("equity_diff", json.float(0.0 -. int.to_float(i) *. 0.01)),
                  ])
                })
              list.map(dict.to_list(turn), fn(kv) {
                case kv.0 {
                  "move" -> #(
                    "move",
                    object([#("results", results), ..as_json(m)]),
                  )
                  _ -> #(kv.0, raw.json(raw.text(kv.1)))
                }
              })
            }
            _, _ -> as_json(turn)
          }
        Error(_) -> as_json(turn)
      }
      json.object(fields)
    })
  json.to_string(
    object([#("turns", json.preprocessed_array(turns)), ..as_json(top)]),
  )
}

fn as_json(d: dict.Dict(String, Dynamic)) -> List(#(String, Json)) {
  dict.to_list(d) |> list.map(fn(kv) { #(kv.0, raw.json(raw.text(kv.1))) })
}

/// An object whose first field of a name wins.
fn object(fields: List(#(String, Json))) -> Json {
  fields
  |> list.fold([], fn(kept, field) {
    case list.key_find(kept, field.0) {
      Ok(_) -> kept
      Error(_) -> [field, ..kept]
    }
  })
  |> list.reverse
  |> json.object
}

// ---------- Finding a step worth sharing ----------

/// The first turn of the room matching `wanted`, with the game it is in.
fn find_turn(
  games: List(GameTurns),
  wanted: fn(Turn) -> Bool,
) -> #(GameTurns, Turn) {
  let assert Ok(found) =
    list.find_map(games, fn(g) {
      case g.finished {
        False -> Error(Nil)
        True -> list.find(g.turns, wanted) |> result.map(fn(t) { #(g, t) })
      }
    })
  found
}

/// What the share wrote, the one write it made.
fn the_write() -> #(NewPuzzle, String, Option(ReplayLink)) {
  let assert [write] = get_writes("writes")
  write
}

fn key_of(kind: puzzles.Kind, g: GameTurns, turn: Turn) -> String {
  puzzles.key(puzzles.question_of(kind, turn.position, turn.dice, g.jacoby))
}

// ---------- A step of each kind ----------

pub fn a_roll_is_shared_as_the_play_the_review_asked_about_test() {
  let #(f, ctx) = seeded()
  // A roll with a choice: not forced, not a dance, a few plays to pick from.
  let #(g, turn) =
    find_turn(replayed(f), fn(t) {
      t.dice != None
      && !analysis.danced(t)
      && t.entry != None
      && t.double == None
      && t.player == 1
    })
  let assert Some(line) = turn.entry
  let step = line + 1
  let assert Ok(id) = positions.share(ctx, "backgammon", room, g.number, step)
  let #(p, origin, link) = the_write()
  assert p.kind == "move"
  assert p.key == key_of(puzzles.Move, g, turn)
  assert p.complete
  assert origin == "replay"
  assert link == Some(ReplayLink("backgammon", room, g.number, step))
  assert Ok(id) == list.first(p.ids)
  // Its picture is drawn now, so the link unfurls with the board.
  assert get_drawn("drawn") == [id]
}

pub fn a_double_is_shared_as_the_doublers_call_test() {
  let #(f, ctx) = seeded()
  let #(g, turn) = find_turn(replayed(f), fn(t) { t.double_entry != None })
  let assert Some(line) = turn.double_entry
  let assert Ok(_) =
    positions.share(ctx, "backgammon", room, g.number, line + 1)
  let #(p, origin, _) = the_write()
  assert p.kind == "double"
  assert p.key == key_of(puzzles.Double, g, turn)
  assert origin == "replay"
}

pub fn a_take_and_a_drop_are_shared_as_the_answer_to_the_double_test() {
  let #(f, ctx) = seeded()
  let games = replayed(f)
  let #(g, took) = find_turn(games, fn(t) { t.double == Some(analysis.Took) })
  let assert Some(line) = took.answer_entry
  let assert Ok(_) =
    positions.share(ctx, "backgammon", room, g.number, line + 1)
  let #(p, _, _) = the_write()
  assert p.kind == "take"
  assert p.key == key_of(puzzles.Take, g, took)
  // A drop asks the same question of its own position.
  let ctx = ctx_over(setup_of(f, f.format), f.records, graded(f))
  let #(g, passed) =
    find_turn(games, fn(t) { t.double == Some(analysis.Passed) })
  let assert Some(line) = passed.answer_entry
  let assert Ok(_) =
    positions.share(ctx, "backgammon", room, g.number, line + 1)
  let #(p, _, _) = the_write()
  assert p.kind == "take"
  assert p.key == key_of(puzzles.Take, g, passed)
}

pub fn every_decision_of_a_game_is_the_question_the_review_asked_test() {
  // Game 1 of the seeded match: three cubes offered on the way. Every
  // line that is a decision shares to the key its turn asks.
  let f = fixture()
  let assert Ok(g) = list.find(replayed(f), fn(g) { g.number == 1 })
  let shared =
    list.flat_map(g.turns, fn(turn) {
      list.filter_map(
        [
          #(turn.entry, puzzles.Move),
          #(turn.double_entry, puzzles.Double),
          #(turn.answer_entry, puzzles.Take),
        ],
        fn(pair) {
          case pair.0 {
            None -> Error(Nil)
            Some(line) -> {
              let ctx = ctx_over(setup_of(f, f.format), f.records, graded(f))
              case positions.share(ctx, "backgammon", room, 1, line + 1) {
                Ok(_) -> {
                  let #(p, _, _) = the_write()
                  assert p.key == key_of(pair.1, g, turn)
                  Ok(Nil)
                }
                // A forced roll or a dance is no decision.
                Error(error.Conflict(code, _)) -> {
                  assert code == positions.no_decision_code
                  Error(Nil)
                }
                Error(_) -> panic as "a step of a graded game failed"
              }
            }
          }
        },
      )
    })
  assert list.length(shared) > 20
}

// ---------- Steps that are not decisions, and games not graded ----------

pub fn the_opening_position_a_resignation_and_the_result_are_no_decision_test() {
  let #(f, ctx) = seeded()
  let no_decision = fn(number, step) {
    case positions.share(ctx, "backgammon", room, number, step) {
      Error(error.Conflict(code, _)) -> code == positions.no_decision_code
      _ -> False
    }
  }
  assert no_decision(1, 0)
  // Game 10 ends on a resignation, then its result line.
  let assert Ok(row) = list.find(f.records, fn(r) { r.game_number == 10 })
  let assert Ok(entries) =
    json.parse(row.entries_json, decode.list(record.decoder()))
  let n = list.length(entries)
  let assert Ok(record.Resign(..)) = list.drop(entries, n - 2) |> list.first
  assert no_decision(10, n - 1)
  assert no_decision(10, n)
  // Nothing was written for any of them.
  assert get_writes("writes") == []
}

pub fn a_step_or_a_game_that_names_nothing_is_a_404_test() {
  let #(_, ctx) = seeded()
  let missing = fn(slug, number, step) {
    case positions.share(ctx, slug, room, number, step) {
      Error(error.NotFound(_)) -> True
      _ -> False
    }
  }
  assert missing("backgammon", 1, 9999)
  assert missing("backgammon", 1, -1)
  assert missing("backgammon", 99, 1)
  assert missing("backgammon", 0, 1)
  assert missing("chess", 1, 1)
}

pub fn the_game_on_the_board_and_an_ungraded_game_wait_test() {
  let f = fixture()
  let not_graded = fn(ctx, number, step) {
    case positions.share(ctx, "backgammon", room, number, step) {
      Error(error.Conflict(code, message)) ->
        code == positions.not_graded_code
        && message == "This position will be shareable once the game is graded."
      _ -> False
    }
  }
  // Twelve games are written down; the thirteenth is being played.
  let ctx = ctx_over(setup_of(f, f.format), f.records, graded(f))
  assert not_graded(ctx, 13, 1)
  // A review pending, or failed, or never asked for.
  let pending = fn(number) {
    Some(
      analysis_caps.Stored(
        ..done(number, ""),
        status: analysis_caps.Pending,
        response_json: None,
      ),
    )
  }
  let ctx = ctx_over(setup_of(f, f.format), f.records, pending)
  assert not_graded(ctx, 1, 1)
  let ctx = ctx_over(setup_of(f, f.format), f.records, fn(_) { None })
  assert not_graded(ctx, 1, 1)
  assert get_writes("writes") == []
}

pub fn an_answer_short_of_every_play_is_incomplete_and_writes_nothing_test() {
  let f = fixture()
  // The seeded answers as they were stored, before `all_results`.
  let old = fn(number) {
    list.key_find(f.answers, number)
    |> result.map(done(number, _))
    |> option.from_result
  }
  let ctx = ctx_over(setup_of(f, f.format), f.records, old)
  let #(g, turn) =
    find_turn(replayed(f), fn(t) {
      t.dice != None && !analysis.danced(t) && t.entry != None
    })
  let assert Some(line) = turn.entry
  let assert Error(error.Conflict(code, message)) =
    positions.share(ctx, "backgammon", room, g.number, line + 1)
  assert code == positions.incomplete_code
  assert message
    == "This position's answer is incomplete; open it in the analysis board instead."
  assert get_writes("writes") == []
  assert get_drawn("drawn") == []
}

pub fn a_body_is_read_and_answered_with_the_puzzles_link_test() {
  let #(f, ctx) = seeded()
  let #(g, turn) =
    find_turn(replayed(f), fn(t) {
      t.dice != None && !analysis.danced(t) && t.entry != None
    })
  let assert Some(line) = turn.entry
  let body =
    json.to_string(
      json.object([
        #("game", json.int(g.number)),
        #("step", json.int(line + 1)),
      ]),
    )
  let assert Ok(text) = positions.share_json(ctx, "backgammon", room, body)
  let assert Ok(#(id, url)) =
    json.parse(text, {
      use id <- decode.field("id", decode.string)
      use url <- decode.field("url", decode.string)
      decode.success(#(id, url))
    })
  assert url == "/puzzles/" <> id
  let assert Error(error.Invalid(_, _)) =
    positions.share_json(ctx, "backgammon", room, "{\"game\":1}")
}

// ---------- Crawford ----------

/// A match to 3 whose first game left White's seat two points up, so the
/// second is the Crawford game; its one line is the seeded match's opening
/// roll, graded by the seeded match's answer for it.
pub fn the_crawford_game_is_asked_as_the_crawford_game_test() {
  let f = fixture()
  let assert [#(white, _), #(black, _)] = f.seats
  let assert Ok(first_game) = list.find(f.records, fn(r) { r.game_number == 1 })
  let assert Ok([opening, ..]) =
    json.parse(first_game.entries_json, decode.list(record.decoder()))
  let assert record.Turn(player: mover, dice: [a, b], ..) = opening
  let game_over =
    record.GameOver(
      number: 1,
      winner: white,
      kind: "single",
      points: 2,
      cube: 2,
      scores: [#(white, 2), #(black, 0)],
    )
  let rows = [
    records.StoredRecord(
      1,
      json.to_string(json.array([game_over], record.to_json)),
    ),
    records.StoredRecord(
      2,
      json.to_string(json.array([opening], record.to_json)),
    ),
  ]
  // Game 1's answer cut to its opening turn: the answer for game 2's one.
  let assert Ok(answer) = list.key_find(f.answers, 1)
  let answer = first_turn_only(completed(answer))
  let review = fn(number) {
    case number {
      2 -> Some(done(2, answer))
      _ -> None
    }
  }
  let ctx = ctx_over(setup_of(f, "match3"), rows, review)
  let assert Ok(_) = positions.share(ctx, "backgammon", room, 2, 1)
  let #(p, _, _) = the_write()
  let assert Ok(q) = puzzles.question_from_json(p.question_json)
  assert q.crawford
  // The mover needs 3 and the other side 1, or the other way round.
  let #(mine, theirs) = case mover == white {
    True -> #(1, 3)
    False -> #(3, 1)
  }
  assert #(q.away_mover, q.away_opponent) == #(mine, theirs)
  assert q.jacoby == False
  assert q.dice == Some(#(int.max(a, b), int.min(a, b)))
  // A match to 3 before anyone is two up has no Crawford game.
  let early = [
    records.StoredRecord(
      1,
      json.to_string(json.array(
        [
          record.GameOver(..game_over, points: 1, scores: [
            #(white, 1),
            #(black, 0),
          ]),
        ],
        record.to_json,
      )),
    ),
    records.StoredRecord(
      2,
      json.to_string(json.array([opening], record.to_json)),
    ),
  ]
  let ctx = ctx_over(setup_of(f, "match3"), early, review)
  let assert Ok(_) = positions.share(ctx, "backgammon", room, 2, 1)
  let #(p, _, _) = the_write()
  let assert Ok(q) = puzzles.question_from_json(p.question_json)
  assert !q.crawford
}

fn first_turn_only(response: String) -> String {
  let assert Ok(top) =
    json.parse(response, decode.dict(decode.string, decode.dynamic))
  let assert Ok(turns) =
    dict.get(top, "turns")
    |> result.try(fn(t) {
      decode.run(t, decode.list(decode.dynamic)) |> result.replace_error(Nil)
    })
  let first = list.take(turns, 1) |> list.map(fn(t) { raw.json(raw.text(t)) })
  json.to_string(
    object([#("turns", json.preprocessed_array(first)), ..as_json(top)]),
  )
}
