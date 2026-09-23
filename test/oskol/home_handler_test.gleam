//// What the signed-in home decides, on stub capabilities: which games
//// count, the two windows and how they are weighted, the sentence in
//// words, what an empty page says, what a guest gets, and how the rest of
//// the graded games are paged.
////
//// Every capability not arranged for panics, so a section that read
//// something it had no business reading -- a room, a log, the engine --
//// fails here rather than in production.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/caps/analysis.{type GradedGame, GradedGame}
import oskol/core/ctx.{type Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/home

const uid = "user-1"

// ---------- Rows, as the query hands them over ----------

/// One seat's totals as the engine stores them. `error` is equity lost and
/// `decisions` how many decisions it was lost over; `pr` is the engine's
/// own rating for that game.
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
    #("pr", json.float(pr_of(error, decisions))),
  ])
}

fn pr_of(error: Float, decisions: Int) -> Float {
  case decisions {
    0 -> 0.0
    _ -> error /. int.to_float(decisions) *. 500.0
  }
}

/// A row: this account sits in seat 0 unless told otherwise.
fn row(
  game_id: String,
  number: Int,
  error: Float,
  decisions: Int,
  at: Int,
) -> GradedGame {
  seated_row(game_id, number, error, decisions, at, 0)
}

fn seated_row(
  game_id: String,
  number: Int,
  error: Float,
  decisions: Int,
  at: Int,
  seat: Int,
) -> GradedGame {
  let mine = totals(error, decisions)
  let theirs = totals(1.0, 10)
  let players = case seat {
    0 -> [mine, theirs]
    _ -> [theirs, mine]
  }
  GradedGame(
    game_id: game_id,
    game_number: number,
    slug: "backgammon",
    seat: seat,
    player_id: "p" <> int.to_string(seat + 1),
    opponent: Some("Bob"),
    winner: Some("p" <> int.to_string(seat + 1)),
    points: 2,
    kind: "gammon",
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #("players", json.preprocessed_array(players)),
      ]),
    ),
    ended_at_ms: at,
  )
}

/// A row whose stored answer carries a rating but no totals: there is
/// nothing to add up in it.
fn ratingless_row(game_id: String, at: Int) -> GradedGame {
  GradedGame(
    ..row(game_id, 1, 1.0, 10, at),
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #(
          "players",
          json.preprocessed_array([
            json.object([#("pr", json.float(4.0))]),
            json.object([#("pr", json.float(9.0))]),
          ]),
        ),
      ]),
    ),
  )
}

// ---------- A context with only what the home may read ----------

fn ctx_with(rows: List(GradedGame)) -> Ctx {
  fakes.ctx()
  |> fakes.with_active_rooms([])
  |> fakes.with_graded(uid, rows)
  |> fakes.with_deck(3, 12, [5, 4, 3, 0, 0, 0, 0, 0], practised_days())
}

fn practised_days() -> List(Bool) {
  list.map(list.range(1, 30), fn(i) { i % 2 == 0 })
}

fn home(rows: List(GradedGame)) -> String {
  home.home_json(ctx_with(rows), fakes.signed_in("guest-1", uid))
}

// ---------- Reading the answer ----------

fn field(body: String, path: List(String), of: decode.Decoder(a)) -> a {
  let decoder =
    list.fold(list.reverse(path), of, fn(inner, key) { decode.at([key], inner) })
  let assert Ok(value) = json.parse(body, decoder)
  value
}

fn optional_float(body: String, path: List(String)) -> Option(Float) {
  field(body, path, decode.optional(decode.float))
}

fn count(body: String, path: List(String)) -> Int {
  list.length(field(body, path, decode.list(decode.dynamic)))
}

// ---------- A guest ----------

pub fn a_guest_is_told_there_is_no_home_for_them_test() {
  let body = home.home_json(fakes.ctx(), fakes.guest("guest-1"))
  let assert False = field(body, ["signed_in"], decode.bool)
  // Nothing else is sent, and nothing was read to find that out: every
  // capability in `fakes.ctx()` panics.
  let assert False = string.contains(body, "form")
}

pub fn a_guest_paging_graded_games_is_given_none_test() {
  let assert Ok(body) =
    home.graded_json(fakes.ctx(), fakes.guest("guest-1"), None)
  let assert 0 = count(body, ["games"])
  // The same shape a signed-in page has, so one decoder reads both.
  let assert False = field(body, ["more"], decode.bool)
  let assert None =
    field(body, [], decode.at(["next"], decode.optional(decode.string)))
}

// ---------- The empty home ----------

pub fn a_new_account_has_no_form_and_says_so_test() {
  let body = home([])
  let assert None = optional_float(body, ["form", "recent"])
  let assert None = optional_float(body, ["form", "career"])
  let assert 0 = field(body, ["form", "games"], decode.int)
  let assert 0 = count(body, ["form", "series"])
  let assert 0 = count(body, ["recent"])
  let assert False = field(body, ["more"], decode.bool)
  let assert "Play 3 games and your PR appears here." =
    field(body, ["form", "sentence"], decode.string)
}

pub fn the_live_games_and_the_deck_are_still_there_with_no_graded_games_test() {
  let body = home([])
  let assert 0 = count(body, ["live"])
  let assert 3 = field(body, ["practice", "due"], decode.int)
  let assert 12 = field(body, ["practice", "deck"], decode.int)
  let assert [5, 4, 3, 0, 0, 0, 0, 0] =
    field(body, ["practice", "ladder"], decode.list(decode.int))
  let assert 30 = count(body, ["practice", "days"])
}

// ---------- The three-game minimum ----------

pub fn two_graded_games_show_no_rating_test() {
  let body =
    home([row("aaaaaa", 1, 1.0, 10, 2000), row("aaaaaa", 2, 1.0, 10, 1000)])
  let assert None = optional_float(body, ["form", "recent"])
  let assert None = optional_float(body, ["form", "career"])
  // The games themselves are still listed: only the rating waits.
  let assert 2 = count(body, ["recent"])
  let assert 2 = count(body, ["form", "series"])
}

pub fn three_graded_games_show_a_rating_test() {
  let body =
    home([
      row("aaaaaa", 1, 1.0, 10, 3000),
      row("aaaaaa", 2, 1.0, 10, 2000),
      row("aaaaaa", 3, 1.0, 10, 1000),
    ])
  // 3.0 of error over 30 decisions, times 500.
  let assert Some(50.0) = optional_float(body, ["form", "recent"])
}

/// The number beside a name at a table waits for five, not three. The rule
/// is the same function with a different floor.
pub fn the_career_number_beside_a_name_waits_for_five_games_test() {
  let games = fn(n) {
    home.counted(
      list.map(list.range(1, n), fn(i) { row("aaaaaa", i, 1.0, 10, 1000 + i) }),
    )
  }
  let assert None = home.window_pr(games(4), home.min_career_games)
  let assert Some(50.0) = home.window_pr(games(5), home.min_career_games)
  let assert 5 = home.min_career_games
}

// ---------- The windows, and how they are weighted ----------

/// A nine-decision game and a ninety-decision one, each with the same
/// error: weighted by game the pair would read 27.8, and the long game --
/// where nearly all the backgammon was played -- would count for as little
/// as the short one.
pub fn the_windows_are_weighted_by_decision_not_by_game_test() {
  let rows = [
    row("aaaaaa", 1, 1.0, 9, 3000),
    row("aaaaaa", 2, 1.0, 90, 2000),
    row("aaaaaa", 3, 1.0, 9, 1000),
  ]
  let games = home.counted(rows)
  // 3.0 over 108 decisions, times 500.
  let assert Some(13.9) = home.window_pr(games, home.min_games)
  // Weighted by game it would be the mean of 55.6, 5.6 and 55.6.
  let assert Some(55.6) =
    home.window_pr(home.counted([row("aaaaaa", 1, 1.0, 9, 1)]), 1)
}

/// Recent reads the newest twenty; career reads everything behind them.
pub fn recent_is_the_last_twenty_and_career_is_all_of_them_test() {
  // Twenty recent games at 2.0 error per 10 decisions, then ten older ones
  // at 10.0 per 10: recent is 100.0, career is well above it.
  let recent =
    list.map(list.range(1, 20), fn(i) { row("aaaaaa", i, 2.0, 10, 10_000 - i) })
  let older =
    list.map(list.range(21, 30), fn(i) {
      row("bbbbbb", i, 10.0, 10, 10_000 - i)
    })
  let body = home(list.append(recent, older))
  let assert Some(100.0) = optional_float(body, ["form", "recent"])
  // (20 * 2.0 + 10 * 10.0) / 300 * 500
  let assert Some(233.3) = optional_float(body, ["form", "career"])
  let assert 30 = field(body, ["form", "games"], decode.int)
}

// ---------- The sentence ----------

pub fn the_sentence_says_which_way_the_numbers_go_test() {
  let assert "Recent 6.2, better than your career 7.8." =
    home.sentence(Some(6.2), Some(7.8))
  let assert "Recent 9.1, worse than your career 7.8." =
    home.sentence(Some(9.1), Some(7.8))
  let assert "Recent 6.2, the same as your career 6.2." =
    home.sentence(Some(6.2), Some(6.2))
  let assert "Play 3 games and your PR appears here." =
    home.sentence(None, None)
}

// ---------- Which games count ----------

/// A stored answer with a rating but no totals has nothing to add up. It
/// counts for nothing -- never as a game played without error.
pub fn a_game_without_totals_counts_for_nothing_test() {
  let rows = [
    row("aaaaaa", 1, 1.0, 10, 3000),
    ratingless_row("bbbbbb", 2000),
    row("cccccc", 1, 1.0, 10, 1000),
  ]
  let body = home(rows)
  let assert 2 = field(body, ["form", "games"], decode.int)
  let assert 2 = count(body, ["recent"])
  // Two games is under the floor, so there is still no rating: the third
  // row did not quietly make one.
  let assert None = optional_float(body, ["form", "career"])
}

/// The account's rating is the one at its own seat, whichever seat that is.
pub fn the_rating_read_is_the_accounts_own_seat_test() {
  let rows = [
    seated_row("aaaaaa", 1, 6.0, 10, 3000, 1),
    seated_row("aaaaaa", 2, 6.0, 10, 2000, 1),
    seated_row("aaaaaa", 3, 6.0, 10, 1000, 1),
  ]
  // The other seat is 1.0 over 10 every game (a PR of 50); this seat is
  // 6.0 over 10 (a PR of 300).
  let assert Some(300.0) = optional_float(home(rows), ["form", "career"])
}

// ---------- Recent games ----------

pub fn a_recent_game_carries_its_result_its_rating_and_its_replay_test() {
  let body = home([row("aaaaaa", 2, 1.0, 10, 3000)])
  let assert "/backgammon/aaaaaa/replay?game=2" =
    field(body, ["recent"], decode.at([0], decode.at(["path"], decode.string)))
  let assert True =
    field(
      body,
      ["recent"],
      decode.at([0], decode.at(["result", "won"], decode.bool)),
    )
  let assert "Bob" =
    field(
      body,
      ["recent"],
      decode.at([0], decode.at(["opponent"], decode.string)),
    )
  let assert 50.0 =
    field(body, ["recent"], decode.at([0], decode.at(["pr"], decode.float)))
}

/// A graded game whose record row has not been written says nothing about
/// who won rather than guessing.
pub fn a_game_with_no_record_line_shows_no_result_test() {
  let body = home([GradedGame(..row("aaaaaa", 1, 1.0, 10, 3000), winner: None)])
  let assert None =
    field(
      body,
      ["recent"],
      decode.at(
        [0],
        decode.at(
          ["result"],
          decode.optional(decode.dict(decode.string, decode.dynamic)),
        ),
      ),
    )
}

/// The result is read against this account's own seat: the same winner is
/// a loss from the other chair.
pub fn losing_is_told_apart_from_winning_test() {
  let lost =
    GradedGame(..seated_row("aaaaaa", 1, 1.0, 10, 3000, 1), winner: Some("p1"))
  let body = home([lost])
  let assert False =
    field(
      body,
      ["recent"],
      decode.at([0], decode.at(["result", "won"], decode.bool)),
    )
}

// ---------- Paging ----------

fn many(n: Int) -> List(GradedGame) {
  list.map(list.range(1, n), fn(i) { row("aaaaaa", i, 1.0, 10, 10_000 - i) })
}

pub fn the_home_carries_ten_games_and_says_there_are_more_test() {
  let body = home(many(25))
  let assert 10 = count(body, ["recent"])
  let assert True = field(body, ["more"], decode.bool)
  // The whole form is still read over all of them.
  let assert 25 = field(body, ["form", "games"], decode.int)
}

pub fn a_home_with_ten_games_exactly_offers_no_more_test() {
  let body = home(many(10))
  let assert 10 = count(body, ["recent"])
  let assert False = field(body, ["more"], decode.bool)
  let assert None =
    field(body, [], decode.at(["next"], decode.optional(decode.string)))
}

pub fn the_next_page_carries_on_where_the_home_stopped_test() {
  let rows = many(25)
  let ctx = ctx_with(rows)
  let session = fakes.signed_in("guest-1", uid)
  let first = home.home_json(ctx, session)
  let assert Some(cursor) =
    field(first, [], decode.at(["next"], decode.optional(decode.string)))
  let assert Ok(second) = home.graded_json(ctx, session, Some(cursor))
  let assert 10 = count(second, ["games"])
  let assert True = field(second, ["more"], decode.bool)
  // Game 11 is the first of the second page: nothing was shown twice and
  // nothing was skipped.
  let assert 11 =
    field(
      second,
      ["games"],
      decode.at([0], decode.at(["game_number"], decode.int)),
    )
  let assert Some(next) =
    field(second, [], decode.at(["next"], decode.optional(decode.string)))
  let assert Ok(third) = home.graded_json(ctx, session, Some(next))
  let assert 5 = count(third, ["games"])
  let assert False = field(third, ["more"], decode.bool)
  let assert 21 =
    field(
      third,
      ["games"],
      decode.at([0], decode.at(["game_number"], decode.int)),
    )
}

/// A marker that is not one is refused. Reading it as "no marker" would
/// hand a paging client the first page again, for ever.
pub fn a_mangled_page_marker_is_refused_test() {
  let ctx = ctx_with(many(25))
  let session = fakes.signed_in("guest-1", uid)
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("nonsense"))
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("100:2"))
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("abc:2:aaaaaa"))
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("100:2:"))
  // A moment outside every date this site can hold is not a marker either.
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("99999999999999:2:aaaaaa"))
  // No marker at all is the first page, not a refusal.
  let assert Ok(_) = home.graded_json(ctx, session, None)
}

// ---------- The chart ----------

pub fn the_series_is_oldest_first_and_capped_test() {
  let numbers =
    field(
      home(many(250)),
      ["form", "series"],
      decode.list(decode.at(["game_number"], decode.int)),
    )
  let assert 200 = list.length(numbers)
  // Oldest first: the line is drawn left to right. The rows are newest
  // first with game 1 the newest, so the 200 kept are games 1..200 and the
  // left end of the line is game 200.
  let assert Ok(200) = list.first(numbers)
  let assert Ok(1) = list.last(numbers)
}
