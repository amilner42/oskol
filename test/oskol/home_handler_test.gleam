//// What the signed-in home decides, on stub capabilities: which games
//// count, the two windows and how they are weighted, the streak beside
//// them, the sentence in words, what an empty page says, what a guest
//// gets, and how the recent list is folded into rooms and paged by them.
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
import oskol/caps/analysis.{
  type GradedGame, type GradedRoomGame, type RatedGame, GradedGame,
  GradedRoomGame, RatedGame,
}
import oskol/caps/practice
import oskol/core/ctx.{type Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/home
import oskol/practice/deck

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

/// The same row as a rating counts it. The two queries read the same
/// games, so a test arranges one list and both halves of the answer are
/// drawn from it.
fn rated_of(game: GradedGame) -> RatedGame {
  RatedGame(
    game_id: game.game_id,
    game_number: game.game_number,
    seat: game.seat,
    response_json: game.response_json,
    ended_at_ms: game.ended_at_ms,
  )
}

/// One game of a room, won or lost by this account for so many points.
fn played(
  game_id: String,
  number: Int,
  error: Float,
  decisions: Int,
  at: Int,
  won: Bool,
  points: Int,
) -> GradedGame {
  GradedGame(
    ..row(game_id, number, error, decisions, at),
    winner: Some(case won {
      True -> "p1"
      False -> "p2"
    }),
    points: points,
    kind: "single",
  )
}

/// The games of one room, as the rooms query hands them over: newest game
/// first, each carrying the room's own format, whether it is over and who
/// its row says won it.
fn room_rows(
  format: String,
  over: Bool,
  winners: List(String),
  games: List(GradedGame),
) -> List(GradedRoomGame) {
  games
  |> list.sort(fn(a, b) { int.compare(b.game_number, a.game_number) })
  |> list.map(fn(game) {
    GradedRoomGame(format: format, over: over, winners: winners, game: game)
  })
}

/// A finished match to seven: nine games, four of them lost by a point and
/// five won for seven points in all, so the score reads 7-4.
///
/// The last game is a long one -- a hundred decisions against ten -- which
/// is what makes the match's rating tell a weighted one from a mean.
fn match_to_seven(game_id: String) -> List(GradedRoomGame) {
  let lost =
    list.map([1, 2, 3, 4], fn(n) {
      played(game_id, n, 0.2, 10, 1000 + n * 10, False, 1)
    })
  let won =
    list.map([5, 6, 7], fn(n) {
      played(game_id, n, 0.2, 10, 1000 + n * 10, True, 1)
    })
  let last = [
    played(game_id, 8, 0.2, 10, 1080, True, 2),
    played(game_id, 9, 0.2, 100, 1090, True, 2),
  ]
  room_rows("match7", True, ["p1"], list.flatten([lost, won, last]))
}

// ---------- A context with only what the home may read ----------

fn ctx_with(rows: List(GradedGame)) -> Ctx {
  ctx_of(rows, one_room_each(rows))
}

/// Every game in a room of its own, which is what a list of single games
/// is: the shape the form's own tests are written on.
fn one_room_each(rows: List(GradedGame)) -> List(GradedRoomGame) {
  list.map(rows, fn(game) {
    GradedRoomGame(format: "single", over: True, winners: ["p1"], game: game)
  })
}

fn ctx_of(rows: List(GradedGame), rooms: List(GradedRoomGame)) -> Ctx {
  fakes.ctx()
  |> fakes.with_active_rooms([])
  |> fakes.with_graded(uid, list.map(rows, rated_of))
  |> fakes.with_graded_rooms(uid, rooms)
  |> fakes.with_active_days(uid, [])
  |> fakes.with_deck(
    3,
    12,
    [5, 4, 3, 0, 0, 0, 0, 0],
    practised_days(),
    practice.Day(answered: 4, new_remaining: 2),
    [
      practice.Severity(
        grade: "very_bad",
        total: 61,
        in_progress: 30,
        patched: 23,
      ),
      practice.Severity(grade: "bad", total: 118, in_progress: 44, patched: 40),
      practice.Severity(
        grade: "doubtful",
        total: 96,
        in_progress: 9,
        patched: 12,
      ),
    ],
  )
}

fn practised_days() -> List(Bool) {
  list.map(list.range(1, 30), fn(i) { i % 2 == 0 })
}

fn home(rows: List(GradedGame)) -> String {
  home.home_json(ctx_with(rows), fakes.signed_in("guest-1", uid))
}

/// A home whose recent list is these rooms. The form reads the same games,
/// so the two halves of the answer cannot be arranged to disagree.
fn home_of(rooms: List(GradedRoomGame)) -> String {
  let games = list.map(rooms, fn(room) { room.game })
  home.home_json(ctx_of(games, rooms), fakes.signed_in("guest-1", uid))
}

// ---------- Reading the answer ----------

fn field(body: String, path: List(String), of: decode.Decoder(a)) -> a {
  let decoder =
    list.fold(list.reverse(path), of, fn(inner, key) { decode.at([key], inner) })
  let assert Ok(value) = json.parse(body, decoder)
  value
}

/// The nth entry of a list at `path`.
fn at(body: String, path: List(String), index: Int, of: decode.Decoder(a)) -> a {
  field(body, path, decode.at([index], of))
}

/// The first room of the recent list, read at `keys`.
fn first_room(body: String, keys: List(String), of: decode.Decoder(a)) -> a {
  at(body, ["recent"], 0, decode.at(keys, of))
}

fn optional_float(body: String, path: List(String)) -> Option(Float) {
  field(body, path, decode.optional(decode.float))
}

fn count(body: String, path: List(String)) -> Int {
  list.length(field(body, path, decode.list(decode.dynamic)))
}

/// How many games the first room of `path` carries.
fn games_in(body: String, path: List(String)) -> Int {
  list.length(at(
    body,
    path,
    0,
    decode.at(["games"], decode.list(decode.dynamic)),
  ))
}

// ---------- A guest ----------

pub fn a_guest_is_told_there_is_no_home_for_them_test() {
  let body = home.home_json(fakes.ctx(), fakes.guest("guest-1"))
  let assert False = field(body, ["signed_in"], decode.bool)
  // Nothing else is sent, and nothing was read to find that out: every
  // capability in `fakes.ctx()` panics.
  let assert False = string.contains(body, "form")
}

pub fn a_guest_paging_recent_rooms_is_given_none_test() {
  let assert Ok(body) =
    home.graded_json(fakes.ctx(), fakes.guest("guest-1"), None)
  let assert 0 = count(body, ["rooms"])
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

/// The day's ring, beside the strip: the streak is the days, this is
/// today. The target is the day's actual work -- what has been answered,
/// what is still due, and the new ones the day still allows -- so it does
/// not shrink under the player as they answer.
pub fn the_practice_block_carries_the_days_ring_test() {
  let body = home([])
  let assert 4 = field(body, ["practice", "today", "done"], decode.int)
  // 4 answered + 3 due + 2 new the budget still allows.
  let assert 9 = field(body, ["practice", "today", "target"], decode.int)
}

/// The three lines the practice section leads with: the deck by how bad
/// the mistake was, worst first, each band in its three states -- made,
/// being worked on, patched.
pub fn the_practice_block_counts_the_deck_by_severity_test() {
  let body = home([])
  let assert "very_bad" =
    at(body, ["practice", "severity"], 0, decode.at(["grade"], decode.string))
  let assert 61 =
    at(body, ["practice", "severity"], 0, decode.at(["total"], decode.int))
  let assert 30 =
    at(
      body,
      ["practice", "severity"],
      0,
      decode.at(["in_progress"], decode.int),
    )
  let assert 23 =
    at(body, ["practice", "severity"], 0, decode.at(["patched"], decode.int))
  let assert "bad" =
    at(body, ["practice", "severity"], 1, decode.at(["grade"], decode.string))
  let assert "doubtful" =
    at(body, ["practice", "severity"], 2, decode.at(["grade"], decode.string))
  // What "patched" means, so the page never keeps a second copy of it.
  let assert 4 = field(body, ["practice", "patched_level"], decode.int)
  let assert True = deck.patched_level == 4
}

/// A deck the cap knows nothing about still reads as three bands: a line
/// that vanished would shift the two beside it.
pub fn a_deck_with_no_bands_still_names_all_three_test() {
  let body =
    home.home_json(
      fakes.ctx()
        |> fakes.with_active_rooms([])
        |> fakes.with_graded(uid, [])
        |> fakes.with_graded_rooms(uid, [])
        |> fakes.with_active_days(uid, [])
        |> fakes.with_deck(
          0,
          0,
          [],
          list.repeat(False, 30),
          practice.Day(answered: 0, new_remaining: 0),
          [],
        ),
      fakes.signed_in("guest-1", uid),
    )
  let assert 3 = count(body, ["practice", "severity"])
  let assert 0 =
    at(body, ["practice", "severity"], 0, decode.at(["total"], decode.int))
  let assert 0 =
    at(
      body,
      ["practice", "severity"],
      0,
      decode.at(["in_progress"], decode.int),
    )
}

// ---------- The three-game minimum ----------

pub fn two_graded_games_show_no_rating_test() {
  let body =
    home([row("aaaaaa", 1, 1.0, 10, 2000), row("bbbbbb", 1, 1.0, 10, 1000)])
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
      row("bbbbbb", 1, 1.0, 10, 2000),
      row("cccccc", 1, 1.0, 10, 1000),
    ])
  // 3.0 of error over 30 decisions, times 500.
  let assert Some(50.0) = optional_float(body, ["form", "recent"])
}

/// The number beside a name at a table waits for five, not three. The rule
/// is the same function with a different floor.
pub fn the_career_number_beside_a_name_waits_for_five_games_test() {
  let games = fn(n) {
    home.counted(
      list.map(list.range(1, n), fn(i) {
        rated_of(row("aaaaaa", i, 1.0, 10, 1000 + i))
      }),
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
    row("bbbbbb", 2, 1.0, 90, 2000),
    row("cccccc", 3, 1.0, 9, 1000),
  ]
  let games = home.counted(list.map(rows, rated_of))
  // 3.0 over 108 decisions, times 500.
  let assert Some(13.9) = home.window_pr(games, home.min_games)
  // Weighted by game it would be the mean of 55.6, 5.6 and 55.6.
  let assert Some(55.6) =
    home.window_pr(home.counted([rated_of(row("aaaaaa", 1, 1.0, 9, 1))]), 1)
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
  // The room whose only graded game has nothing to rate is not a line
  // either: a room with no rating is left out rather than drawn as a
  // flawless one.
  let assert 2 = count(body, ["recent"])
  // Two games is under the floor, so there is still no rating: the third
  // row did not quietly make one.
  let assert None = optional_float(body, ["form", "career"])
}

/// The account's rating is the one at its own seat, whichever seat that is.
pub fn the_rating_read_is_the_accounts_own_seat_test() {
  let rows = [
    seated_row("aaaaaa", 1, 6.0, 10, 3000, 1),
    seated_row("bbbbbb", 1, 6.0, 10, 2000, 1),
    seated_row("cccccc", 1, 6.0, 10, 1000, 1),
  ]
  // The other seat is 1.0 over 10 every game (a PR of 50); this seat is
  // 6.0 over 10 (a PR of 300).
  let assert Some(300.0) = optional_float(home(rows), ["form", "career"])
}

// ---------- A match is one entry ----------

/// The whole point of the list: nine games of a match to seven are one
/// line that says what it was, how it ended and how it was played.
pub fn a_match_is_one_entry_with_its_score_test() {
  let body = home_of(match_to_seven("mmmmmm"))
  let assert 1 = count(body, ["recent"])
  let assert "Match to 7" = first_room(body, ["format"], decode.string)
  let assert "mmmmmm" = first_room(body, ["id"], decode.string)
  let assert 7 = first_room(body, ["score", "yours"], decode.int)
  let assert 4 = first_room(body, ["score", "theirs"], decode.int)
  let assert True = first_room(body, ["over"], decode.bool)
  let assert True = first_room(body, ["won"], decode.bool)
  // Nine games, newest first, inside the one line.
  let assert 9 = games_in(body, ["recent"])
  let assert [9, 8, 7, 6, 5, 4, 3, 2, 1] =
    first_room(
      body,
      ["games"],
      decode.list(decode.at(["game_number"], decode.int)),
    )
  // The line opens at the first game of the match; each game inside opens
  // at its own.
  let assert "/backgammon/mmmmmm/replay?game=1" =
    first_room(body, ["path"], decode.string)
  let assert "/backgammon/mmmmmm/replay?game=9" =
    first_room(
      body,
      ["games"],
      decode.at([0], decode.at(["path"], decode.string)),
    )
}

/// A match's rating is its error over its decisions, not the mean of its
/// games' ratings: the long ninth game is where most of the backgammon was
/// played, and it has to weigh accordingly.
pub fn a_matchs_rating_is_weighted_by_decision_not_by_game_test() {
  let body = home_of(match_to_seven("mmmmmm"))
  // 1.8 of error over 180 decisions, times 500.
  let assert 5.0 = first_room(body, ["pr"], decode.float)
  let assert 180 = first_room(body, ["decisions"], decode.int)
  // The mean of the nine games' own ratings is 9.0 -- eight of them at
  // 10.0 and the long one at 1.0 -- which is what this must not be.
  let assert [1.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0] =
    first_room(body, ["games"], decode.list(decode.at(["pr"], decode.float)))
}

pub fn an_unlimited_session_reads_as_one_room_test() {
  let games = [
    played("uuuuuu", 1, 0.2, 10, 1010, True, 2),
    played("uuuuuu", 2, 0.2, 10, 1020, False, 1),
    played("uuuuuu", 3, 0.2, 10, 1030, True, 1),
  ]
  // Still being played: nobody has won it, and the score is where it
  // stands.
  let body = home_of(room_rows("unlimited", False, [], games))
  let assert 1 = count(body, ["recent"])
  let assert "Unlimited" = first_room(body, ["format"], decode.string)
  let assert 3 = first_room(body, ["score", "yours"], decode.int)
  let assert 1 = first_room(body, ["score", "theirs"], decode.int)
  let assert False = first_room(body, ["over"], decode.bool)
  let assert None = first_room(body, ["won"], decode.optional(decode.bool))
}

pub fn a_single_game_is_one_entry_that_opens_its_replay_test() {
  let body =
    home_of(
      room_rows("single", True, ["p2"], [
        played("ssssss", 1, 0.2, 10, 1000, False, 2),
      ]),
    )
  let assert 1 = count(body, ["recent"])
  let assert "Single game" = first_room(body, ["format"], decode.string)
  let assert 1 = games_in(body, ["recent"])
  let assert "/backgammon/ssssss/replay?game=1" =
    first_room(body, ["path"], decode.string)
  let assert False = first_room(body, ["won"], decode.bool)
  let assert 2 = first_room(body, ["score", "theirs"], decode.int)
}

/// Half a match graded shows the half it knows and says nothing about the
/// rest -- but who won is read off the room's own row, so a match whose
/// last game the engine has not answered for is still not handed to the
/// wrong player.
pub fn a_room_half_graded_shows_the_graded_games_test() {
  let games = [
    played("hhhhhh", 1, 0.2, 10, 1010, False, 2),
    played("hhhhhh", 2, 0.2, 10, 1020, False, 2),
  ]
  let body = home_of(room_rows("match7", True, ["p1"], games))
  let assert 1 = count(body, ["recent"])
  let assert 2 = games_in(body, ["recent"])
  // Both graded games were losses, so the score it can see reads 0-4 --
  // and it still says this account won the match, because the room's row
  // says so and the score is only what has been graded.
  let assert 0 = first_room(body, ["score", "yours"], decode.int)
  let assert 4 = first_room(body, ["score", "theirs"], decode.int)
  let assert True = first_room(body, ["won"], decode.bool)
}

/// A finished room whose row names nobody says nothing, rather than
/// reading as a loss.
pub fn a_finished_room_with_no_winner_recorded_says_nothing_test() {
  let body =
    home_of(
      room_rows("match3", True, [], [
        played("nnnnnn", 1, 0.2, 10, 1000, True, 1),
      ]),
    )
  let assert None = first_room(body, ["won"], decode.optional(decode.bool))
  let assert True = first_room(body, ["over"], decode.bool)
}

/// A format the game no longer lists is still backgammon, and says so
/// rather than printing a stored id at a player.
pub fn a_format_the_game_no_longer_lists_reads_as_the_game_test() {
  let body =
    home_of(
      room_rows("match11", True, ["p1"], [
        played("oooooo", 1, 0.2, 10, 1000, True, 1),
      ]),
    )
  let assert "Backgammon" = first_room(body, ["format"], decode.string)
}

// ---------- Paging, by room ----------

/// Rooms of one game each, newest first.
fn many_rooms(n: Int) -> List(GradedRoomGame) {
  list.range(1, n)
  |> list.map(fn(i) {
    let id = "r" <> string.pad_start(int.to_string(i), 5, "0")
    GradedRoomGame(
      format: "single",
      over: True,
      winners: ["p1"],
      game: row(id, 1, 1.0, 10, 100_000 - i),
    )
  })
}

fn ctx_rooms(rooms: List(GradedRoomGame)) -> Ctx {
  ctx_of(list.map(rooms, fn(room) { room.game }), rooms)
}

pub fn the_home_carries_ten_rooms_and_says_there_are_more_test() {
  let body = home_of(many_rooms(12))
  let assert 10 = count(body, ["recent"])
  let assert True = field(body, ["more"], decode.bool)
  // The form is still read over every game behind them.
  let assert 12 = field(body, ["form", "games"], decode.int)
}

pub fn a_home_with_ten_rooms_exactly_offers_no_more_test() {
  let body = home_of(many_rooms(10))
  let assert 10 = count(body, ["recent"])
  let assert False = field(body, ["more"], decode.bool)
  let assert None =
    field(body, [], decode.at(["next"], decode.optional(decode.string)))
}

pub fn the_next_page_carries_on_where_the_home_stopped_test() {
  let ctx = ctx_rooms(many_rooms(25))
  let session = fakes.signed_in("guest-1", uid)
  let first = home.home_json(ctx, session)
  let assert Some(cursor) =
    field(first, [], decode.at(["next"], decode.optional(decode.string)))
  let assert Ok(second) = home.graded_json(ctx, session, Some(cursor))
  let assert 10 = count(second, ["rooms"])
  let assert True = field(second, ["more"], decode.bool)
  // The eleventh room is the first of the second page: nothing was shown
  // twice and nothing was skipped.
  let assert "r00011" =
    at(second, ["rooms"], 0, decode.at(["id"], decode.string))
  let assert Some(next) =
    field(second, [], decode.at(["next"], decode.optional(decode.string)))
  let assert Ok(third) = home.graded_json(ctx, session, Some(next))
  let assert 5 = count(third, ["rooms"])
  let assert False = field(third, ["more"], decode.bool)
  let assert "r00021" =
    at(third, ["rooms"], 0, decode.at(["id"], decode.string))
}

/// A page boundary cannot fall inside a match: a marker names a room, so
/// every page carries each of its rooms whole.
pub fn a_page_never_stops_in_the_middle_of_a_match_test() {
  // Ten single games, then a nine-game match behind them: eleven rooms,
  // twenty games.
  let ctx = ctx_rooms(list.append(many_rooms(10), match_to_seven("mmmmmm")))
  let session = fakes.signed_in("guest-1", uid)
  let first = home.home_json(ctx, session)
  // Ten rooms, not ten games, and the match is not among them.
  let assert 10 = count(first, ["recent"])
  let assert True = field(first, ["more"], decode.bool)
  let assert Some(cursor) =
    field(first, [], decode.at(["next"], decode.optional(decode.string)))

  let assert Ok(second) = home.graded_json(ctx, session, Some(cursor))
  let assert 1 = count(second, ["rooms"])
  let assert "mmmmmm" =
    at(second, ["rooms"], 0, decode.at(["id"], decode.string))
  // The whole match came on the second page: no game of it was left on
  // the first, and none was dropped between them.
  let assert 9 = games_in(second, ["rooms"])
  let assert 7 =
    at(second, ["rooms"], 0, decode.at(["score", "yours"], decode.int))
  let assert False = field(second, ["more"], decode.bool)
}

/// A marker that is not one is refused. Reading it as "no marker" would
/// hand a paging client the first page again, for ever.
pub fn a_mangled_page_marker_is_refused_test() {
  let ctx = ctx_rooms(many_rooms(25))
  let session = fakes.signed_in("guest-1", uid)
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("nonsense"))
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("abc:r00001"))
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("100:"))
  // The marker games used to be paged on is not a marker any more.
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("100:2:r00001"))
  // A moment outside every date this site can hold is not a marker either.
  let assert Error(error.Invalid("validation_failed", _)) =
    home.graded_json(ctx, session, Some("99999999999999:r00001"))
  // No marker at all is the first page, not a refusal.
  let assert Ok(_) = home.graded_json(ctx, session, None)
}

// ---------- The streak ----------
//
// `days` is oldest first and ends today, as the practice strip is
// ordered. What each of the two sources counts as a day -- a puzzle
// answered, a game finished -- is the capability's, and is tested on real
// rows in test/oskol_web/controllers/api/home_api_test.exs. The rule for
// counting them into a run is here.

fn streak_of(days: List(Bool)) -> Int {
  let ctx =
    fakes.ctx()
    |> fakes.with_active_rooms([])
    |> fakes.with_graded(uid, [])
    |> fakes.with_graded_rooms(uid, [])
    |> fakes.with_active_days(uid, days)
    |> fakes.with_deck(
      0,
      0,
      [],
      list.repeat(False, 30),
      practice.Day(answered: 0, new_remaining: 0),
      [],
    )
  field(
    home.home_json(ctx, fakes.signed_in("guest-1", uid)),
    ["form", "streak"],
    decode.int,
  )
}

pub fn a_day_here_today_counts_today_test() {
  let assert 3 = streak_of([False, True, True, True])
}

/// The one that matters: at nine in the morning nobody has played yet, and
/// a streak that reads 0 until they do punishes them for the time of day.
pub fn yesterday_without_today_keeps_the_streak_test() {
  let assert 3 = streak_of([False, True, True, True, False])
}

pub fn a_missed_day_ends_the_streak_test() {
  // Four days on, one off, then today: the run is today alone.
  let assert 1 = streak_of([True, True, True, True, False, True])
}

pub fn two_days_off_is_no_streak_at_all_test() {
  let assert 0 = streak_of([True, True, True, False, False])
}

pub fn a_player_who_has_never_been_here_has_no_streak_test() {
  let assert 0 = streak_of([False, False, False])
  let assert 0 = streak_of([])
}

/// The window bounds the read, so a streak as long as the window reads as
/// the window rather than running away with the query.
pub fn the_streak_is_bounded_by_its_window_test() {
  let assert True =
    home.days_running(list.repeat(True, home.streak_window))
    == home.streak_window
  let assert 366 = home.streak_window
}

// ---------- The chart ----------

pub fn the_series_is_oldest_first_and_capped_test() {
  let rows =
    list.map(list.range(1, 250), fn(i) { row("aaaaaa", i, 1.0, 10, 10_000 - i) })
  let numbers =
    field(
      home(rows),
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
