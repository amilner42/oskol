//// What the ratings endpoint decides, on stub capabilities: which of a
//// room's games count toward a player's match PR, what the average is,
//// whose career goes beside it, and what a room that is not there answers.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/analysis.{
  type RatedGame, type Stored, AnalysisCaps, Done, Failed, Pending, RatedGame,
  Stored,
}
import oskol/caps/records as records_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/ratings

/// The engine's answer, cut down to the one field a match PR reads.
fn answer(first: Float, second: Float) -> String {
  json.to_string(
    json.object([
      #("turns", json.preprocessed_array([])),
      #(
        "players",
        json.preprocessed_array([
          json.object([#("pr", json.float(first))]),
          json.object([#("pr", json.float(second))]),
        ]),
      ),
    ]),
  )
}

fn done(number: Int, first: Float, second: Float) -> Stored {
  Stored(
    game_number: number,
    status: Done,
    attempts: 1,
    response_json: Some(answer(first, second)),
    answered: True,
    rendered: False,
    turns: 1,
  )
}

/// A game the engine has not answered for: nothing to read a rating out of.
fn owed(number: Int, status: analysis.Status, attempts: Int) -> Stored {
  Stored(
    game_number: number,
    status: status,
    attempts: attempts,
    response_json: None,
    answered: False,
    rendered: False,
    turns: 1,
  )
}

/// A persisted backgammon room. All room and full-response capabilities
/// panic: ratings may read only stored seats and the small player totals.
fn room_with(slug: String, stored: List(Stored)) -> Ctx {
  seated(slug, stored, "", "")
}

/// The same room with an account named against either seat ("" for a seat
/// no account owns).
fn seated(
  slug: String,
  stored: List(Stored),
  first: String,
  second: String,
) -> Ctx {
  let ctx =
    fakes.ctx()
    |> fakes.with_records(
      Some(records_caps.Setup(
        slug: slug,
        format: "match5",
        clock: "none",
        seed: 7,
        seats: [#("p1", "Alice", "g1", first), #("p2", "Bob", "g2", second)],
        finished: False,
        records_stale: False,
      )),
      [],
    )
  Ctx(..ctx, analysis: AnalysisCaps(..ctx.analysis, ratings: fn(_) { stored }))
}

fn body(stored: List(Stored)) -> String {
  let assert Ok(body) =
    ratings.ratings_json(
      room_with("backgammon", stored),
      "backgammon",
      "000007",
    )
  body
}

/// The answer without its per-game list (`games`, the last key), which the
/// match-PR tests do not read.
fn players(stored: List(Stored)) -> String {
  // A seat's own `"games":1` count is a number; the list is the one
  // followed by `[`.
  let assert Ok(#(head, _)) = string.split_once(body(stored), ",\"games\":[")
  head <> "}"
}

pub fn each_graded_game_lists_its_prs_by_seat_in_game_order_test() {
  let answer =
    body([done(3, 6.0, 9.5), done(1, 8.4, 12.1), owed(2, Pending, 1)])
  assert string.ends_with(
    answer,
    ",\"games\":[{\"game_number\":1,\"players\":[{\"player_id\":\"p1\",\"pr\":8.4},{\"player_id\":\"p2\",\"pr\":12.1}]},{\"game_number\":3,\"players\":[{\"player_id\":\"p1\",\"pr\":6.0},{\"player_id\":\"p2\",\"pr\":9.5}]}]}",
  )
}

fn expected(entries: List(#(String, Int, Option(Float)))) -> String {
  expecting(False, entries)
}

fn expecting(
  pending: Bool,
  entries: List(#(String, Int, Option(Float))),
) -> String {
  careers(
    pending,
    list.map(entries, fn(entry) {
      let #(player_id, games, pr) = entry
      #(player_id, games, pr, None)
    }),
  )
}

/// The same, spelling out each seat's career as well.
fn careers(
  pending: Bool,
  entries: List(#(String, Int, Option(Float), Option(Float))),
) -> String {
  json.to_string(
    json.object([
      #("ok", json.bool(True)),
      #("pending", json.bool(pending)),
      #(
        "players",
        json.array(entries, fn(entry) {
          let #(player_id, games, pr, career) = entry
          json.object([
            #("player_id", json.string(player_id)),
            #("games", json.int(games)),
            #("pr", nullable(pr)),
            #("career", nullable(career)),
          ])
        }),
      ),
    ]),
  )
}

fn nullable(value: Option(Float)) -> json.Json {
  case value {
    Some(value) -> json.float(value)
    None -> json.null()
  }
}

pub fn one_graded_game_shows_its_own_pr_test() {
  assert players([done(1, 8.4, 12.1)])
    == expected([#("p1", 1, Some(8.4)), #("p2", 1, Some(12.1))])
}

pub fn a_match_averages_the_games_it_has_test() {
  // The plain mean over the games, to one decimal, per seat.
  assert players([done(1, 8.0, 12.0), done(2, 9.0, 13.0), done(3, 8.2, 11.0)])
    == expected([#("p1", 3, Some(8.4)), #("p2", 3, Some(12.0))])
}

pub fn a_match_with_nothing_graded_shows_no_number_test() {
  assert players([]) == expected([#("p1", 0, None), #("p2", 0, None)])
}

pub fn pending_and_failed_games_do_not_count_test() {
  // The match is three games in; only the one the engine answered counts,
  // so the number is that game's own PR and the count says so.
  let stored = [
    done(1, 6.0, 10.0),
    owed(2, Pending, 0),
    owed(3, Failed, 3),
  ]
  assert players(stored)
    == expecting(True, [#("p1", 1, Some(6.0)), #("p2", 1, Some(10.0))])
}

pub fn a_failure_that_will_be_tried_again_is_still_owed_test() {
  // The page is told to ask again while a retry is coming, and told to
  // stop once the engine has given up.
  let retryable = [owed(1, Failed, 1)]
  assert players(retryable)
    == expecting(True, [#("p1", 0, None), #("p2", 0, None)])

  let given_up = [owed(1, Failed, 3)]
  assert players(given_up) == expected([#("p1", 0, None), #("p2", 0, None)])
}

pub fn an_answer_that_names_no_ratings_is_skipped_test() {
  let nonsense =
    Stored(
      game_number: 1,
      status: Done,
      attempts: 1,
      response_json: Some("{\"turns\":[]}"),
      answered: True,
      rendered: False,
      turns: 1,
    )
  assert players([nonsense, done(2, 5.0, 5.0)])
    == expected([#("p1", 1, Some(5.0)), #("p2", 1, Some(5.0))])
}

pub fn the_average_is_one_vote_per_game_test() {
  assert ratings.average([4.0, 5.0, 6.0]) == Some(5.0)
  assert ratings.average([1.0, 2.0, 2.0, 2.0]) == Some(1.8)
  assert ratings.average([0.11, 0.11, 0.11]) == Some(0.1)
  assert ratings.average([]) == None
}

pub fn a_room_that_is_not_there_says_so_and_nothing_else_test() {
  // No room, a room still in its lobby, and a slug that is not the room's
  // game: one answer for all three, so a caller learns nothing about a room
  // it did not ask for.
  let gone = fakes.ctx() |> fakes.with_records(None, [])
  assert ratings.ratings_json(gone, "backgammon", "000007")
    == Error(error.NotFound(ratings.not_found_message))

  assert ratings.ratings_json(room_with("chess", []), "backgammon", "000007")
    == Error(error.NotFound(ratings.not_found_message))

  let lobby = room_with("backgammon", []) |> fakes.with_records(None, [])
  assert result.is_error(ratings.ratings_json(lobby, "backgammon", "000007"))
}

// ---------- The career beside the match PR ----------
//
// The match PR is this room's graded games. Beside it goes the career: the
// account that owns the seat, over every graded game it has anywhere. It is
// the home page's number, worked out by the home page's maths, so the two
// pages can never disagree about the same person.

/// One seat's totals as the engine stores them: the equity lost and the
/// decisions it was lost over, which is what a career is added up from.
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
    #("pr", json.float(error /. int.to_float(decisions) *. 500.0)),
  ])
}

/// A graded game of this account's, somewhere on the site: its own seat's
/// totals is all the career reads, and all the query carries.
fn graded(number: Int, error: Float, decisions: Int) -> RatedGame {
  RatedGame(
    game_id: "000042",
    game_number: number,
    seat: 0,
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #("players", json.preprocessed_array([totals(error, decisions)])),
      ]),
    ),
    ended_at_ms: 1_700_000_000_000 + number,
  )
}

/// A graded game whose stored answer carries a rating but no totals (a row
/// written before they were stored): there is nothing in it to add up.
fn ratingless(number: Int) -> RatedGame {
  RatedGame(
    ..graded(number, 1.0, 10),
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #(
          "players",
          json.preprocessed_array([json.object([#("pr", json.float(4.0))])]),
        ),
      ]),
    ),
  )
}

/// Five ordinary games, of `n` decisions each, losing `error` in every one.
fn history(count: Int, error: Float, decisions: Int) -> List(RatedGame) {
  list.range(1, count)
  |> list.map(fn(number) { graded(number, error, decisions) })
}

/// A room whose first seat belongs to `alice`, with that account's graded
/// games behind it, and whose second seat belongs to nobody.
fn owned(rows: List(RatedGame), stored: List(Stored)) -> Ctx {
  seated("backgammon", stored, "alice", "")
  |> fakes.with_graded_accounts([#("alice", rows)])
}

/// The answer's seats alone, without the per-game list these tests do not
/// read.
fn seat_lines(ctx: Ctx) -> String {
  let assert Ok(body) = ratings.ratings_json(ctx, "backgammon", "000007")
  let assert Ok(#(head, _)) = string.split_once(body, ",\"games\":[")
  head <> "}"
}

pub fn an_owned_seat_shows_its_accounts_career_test() {
  // Five games, each losing 0.2 equity over 10 decisions: 1.0 over 50,
  // which is a PR of 10.0. The seat beside it belongs to no account, so
  // there is nothing to print there -- and asking for one would have
  // panicked in the stub.
  let ctx = owned(history(5, 0.2, 10), [done(1, 8.4, 12.1)])
  assert seat_lines(ctx)
    == careers(False, [
      #("p1", 1, Some(8.4), Some(10.0)),
      #("p2", 1, Some(12.1), None),
    ])
}

pub fn four_graded_games_are_not_a_career_yet_test() {
  // The floor is five: a number a stranger reads off a bar must not be
  // made of an evening.
  let ctx = owned(history(4, 0.2, 10), [])
  assert seat_lines(ctx)
    == careers(False, [#("p1", 0, None, None), #("p2", 0, None, None)])
}

pub fn a_career_is_weighted_by_decisions_not_by_game_test() {
  // One short game played badly and four long ones played well. Averaging
  // the five PRs gives 14.0 and lets the three-decision game speak for the
  // whole career; the equity lost over the decisions it was lost over
  // gives 6.1, which is how the engine rates one game.
  let rows = [graded(1, 0.5, 5), ..history(4, 0.5, 50)]
  let ctx = owned(rows, [])
  assert seat_lines(ctx)
    == careers(False, [#("p1", 0, None, Some(6.1)), #("p2", 0, None, None)])
}

pub fn a_game_whose_totals_are_missing_counts_for_nothing_test() {
  // It is not a zero and it is not a free game toward the floor: four
  // countable games and a row nothing can be read out of is still four.
  let short = owned([ratingless(9), ..history(4, 0.2, 10)], [])
  assert seat_lines(short)
    == careers(False, [#("p1", 0, None, None), #("p2", 0, None, None)])

  // With five countable games behind it, the uncountable one changes
  // neither the number nor the fact that there is one.
  let enough = owned([ratingless(9), ..history(5, 0.2, 10)], [])
  assert seat_lines(enough)
    == careers(False, [#("p1", 0, None, Some(10.0)), #("p2", 0, None, None)])
}

pub fn each_seat_reads_its_own_accounts_games_test() {
  // Two accounts at one table. The stub panics on any account a test did
  // not arrange for, so a seat that read the other one's history -- or the
  // same one twice -- fails here.
  let ctx =
    seated("backgammon", [], "alice", "bob")
    |> fakes.with_graded_accounts([
      #("alice", history(5, 0.2, 10)),
      #("bob", history(6, 0.5, 20)),
    ])
  assert seat_lines(ctx)
    == careers(False, [
      #("p1", 0, None, Some(10.0)),
      #("p2", 0, None, Some(12.5)),
    ])
}
