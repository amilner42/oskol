//// The signed-in home, in one answer:
////
////   GET /papi/me/home                    everything the page draws
////   GET /papi/me/games/graded?before=     the next page of graded games
////
//// Today's home is built for a stranger: a board and four buttons. A
//// player with an account has games waiting, a rating and a deck, and the
//// page shows none of it -- so signing in looks like it did nothing. This
//// is the answer that page is drawn from: the rooms they can pick back up,
//// how they are playing, what is due to practice, and the games behind
//// them.
////
//// Three rules hold it together:
////
////   * **It is one request, and it is all rows.** Nothing here wakes a
////     room, replays a log or spends a second of engine time. Live games
////     come from the `games` rows (`landing.my_games`), form and recent
////     games from one query over the stored reviews, practice from the
////     deck. A home visit costs a handful of reads however many games are
////     behind it.
////   * **Everything is the account's**, by the one holder rule: a seat
////     whose `user_id` is theirs. A guest has no home of this kind -- their
////     games arrive when they sign in -- so a guest is told exactly that
////     (`signed_in: false`) and the client keeps the home it has.
////   * **Only graded games count.** A game the engine has not answered
////     for, or failed on, is worth nothing to a rating, exactly as it is
////     worth nothing to the match PR. Neither is a game whose stored
////     answer does not carry the totals a rating is made of: it counts for
////     nothing rather than as a zero.

import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import oskol/caps/analysis.{type Cursor, type GradedGame, Cursor}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/handlers/landing
import oskol/reviews/report.{type Totals}
import oskol/rooms/room

/// The games "Recent" is read over. Twenty is a few evenings of
/// backgammon: long enough that one bad game does not own the number, short
/// enough that it moves when you get better.
pub const recent_window = 20

/// Nothing is shown until there are this many graded games. Two games is
/// noise, and a number that swings from 3.0 to 14.0 teaches nothing.
pub const min_games = 3

/// The same floor for the career number printed beside a name at a table
/// and on a replay, which is a stranger's first impression of a player and
/// so is held to a little more.
pub const min_career_games = 5

/// How many games the chart draws. Past this the line is a smear, and the
/// answer is kilobytes of points nobody can see.
pub const series_cap = 200

/// How many graded games ride in the home answer, and how many a page of
/// `/papi/me/games/graded` carries.
pub const page_size = 10

/// The strip under the practice section: one mark per day.
pub const practice_days = 30

/// How far back "career" actually reaches. A page must not run an
/// unbounded read, and nobody on the site is within two orders of
/// magnitude of this; when somebody is, the number becomes a rolling one
/// and says so rather than growing without limit.
pub const career_cap = 1000

/// What the client is told when it has no account: everything else on this
/// page belongs to one, so there is nothing to send and nothing to
/// apologise for. The guest home is unchanged.
pub const guest_body = "{\"ok\":true,\"signed_in\":false}"

pub const bad_cursor_message = "That page marker does not read as one."

/// The 1st of January 2100, in Unix milliseconds. A page marker is a
/// moment, and a moment outside every date this site can hold is a mangled
/// marker, not a very patient reader.
pub const latest_cursor_ms = 4_102_444_800_000

/// One graded game as the home counts it: what it was, how it went, and
/// the two numbers a rating over several games is made of.
pub type Game {
  Game(
    game_id: String,
    game_number: Int,
    slug: String,
    opponent: Option(String),
    /// None where no record row says how the game ended.
    won: Option(Bool),
    points: Int,
    kind: String,
    /// This seat's rating for this game, as the engine graded it.
    pr: Float,
    /// Equity lost, and the decisions it was lost over. A rating across
    /// games is the first divided by the second: a nine-decision game must
    /// not weigh the same as an eighty-nine-decision one.
    error: Float,
    decisions: Int,
    ended_at_ms: Int,
  )
}

// ---------- GET /papi/me/home ----------

/// The whole page. A guest gets the one flag that says so.
pub fn home_json(ctx: Ctx, session: Session) -> String {
  case session.user_id {
    None -> guest_body
    Some(uid) -> {
      // One read of the account's graded games serves both the form and
      // the recent list: the first page of one is the front of the other.
      let rows = ctx.analysis.graded_for(uid, career_cap + 1, None)
      let page = list.take(rows, page_size)
      let games = counted(rows)
      envelope.ok([
        #("signed_in", json.bool(True)),
        #("live", json.preprocessed_array(landing.my_games(ctx, session))),
        #("form", form_json(games)),
        #("practice", practice_json(ctx, uid)),
        #("recent", json.preprocessed_array(list.map(counted(page), game_json))),
        #("more", json.bool(list.length(rows) > page_size)),
        #("next", nullable_string(next_cursor(page, list.length(rows)))),
      ])
    }
  }
}

// ---------- GET /papi/me/games/graded ----------

/// The next ten graded games. `before` is the `next` of the answer before
/// it; nothing else is a page marker, and a mangled one is refused rather
/// than quietly read as "from the top" -- a client that thinks it is paging
/// and is being handed the first page again would loop for ever.
///
/// The account is the caller's own. `before` only says where to carry on:
/// every row it can reach is a row the same caller could have paged to.
pub fn graded_json(
  ctx: Ctx,
  session: Session,
  before: Option(String),
) -> Result(String, ApiError) {
  use cursor <- result.try(parse_cursor(before))
  case session.user_id {
    // The same three fields, so one decoder reads every answer this
    // endpoint gives.
    None ->
      Ok(
        envelope.ok([
          #("games", json.preprocessed_array([])),
          #("more", json.bool(False)),
          #("next", json.null()),
        ]),
      )
    Some(uid) -> {
      let rows = ctx.analysis.graded_for(uid, page_size + 1, cursor)
      let page = list.take(rows, page_size)
      Ok(
        envelope.ok([
          #(
            "games",
            json.preprocessed_array(list.map(counted(page), game_json)),
          ),
          #("more", json.bool(list.length(rows) > page_size)),
          #("next", nullable_string(next_cursor(page, list.length(rows)))),
        ]),
      )
    }
  }
}

// ---------- The rows, as the page counts them ----------

/// The graded games this account's rating is made of, newest first.
///
/// A game is dropped where the stored answer does not carry this seat's
/// totals (a row written before they were stored), or where it graded no
/// decision at all: either would otherwise enter the sum as no error over
/// no decisions, which is a perfect game that was never played.
pub fn counted(rows: List(GradedGame)) -> List(Game) {
  list.filter_map(rows, counted_game)
}

fn counted_game(row: GradedGame) -> Result(Game, Nil) {
  use totals <- result.try(seat_totals(row))
  let decisions = totals.move_decisions + totals.cube_decisions
  case decisions {
    0 -> Error(Nil)
    _ ->
      Ok(Game(
        game_id: row.game_id,
        game_number: row.game_number,
        slug: row.slug,
        opponent: row.opponent,
        won: option.map(row.winner, fn(w) { w == row.player_id }),
        points: row.points,
        kind: row.kind,
        pr: totals.pr,
        error: totals.error,
        decisions: decisions,
        ended_at_ms: row.ended_at_ms,
      ))
  }
}

/// This account's seat's totals out of the stored answer, when they are
/// there. `player_totals` has already taken off the opening roll's phantom
/// "no double", so these are the numbers the match PR is made of too.
fn seat_totals(row: GradedGame) -> Result(Totals, Nil) {
  report.player_totals(row.response_json)
  |> result.replace_error(Nil)
  |> result.try(fn(ratings) {
    list.drop(ratings, row.seat)
    |> list.first
    |> result.try(fn(rating) { option.to_result(rating.1, Nil) })
  })
}

// ---------- Form ----------

fn form_json(games: List(Game)) -> Json {
  let recent = window_pr(list.take(games, recent_window), min_games)
  let career = window_pr(games, min_games)
  json.object([
    #("games", json.int(list.length(games))),
    #("recent", nullable_float(recent)),
    #("career", nullable_float(career)),
    #("sentence", json.string(sentence(recent, career))),
    // Oldest first: the order the line is drawn in.
    #(
      "series",
      json.preprocessed_array(
        list.take(games, series_cap) |> list.reverse |> list.map(point_json),
      ),
    ),
  ])
}

/// A rating over a window of games: the equity lost across all of them
/// over the decisions it was lost over, times 500 -- the engine's own
/// definition of a PR, applied to more than one game. Weighting by game
/// instead would let a three-turn game speak as loudly as a fifty-turn one.
///
/// Nothing under `minimum` games, and nothing for a window that graded no
/// decision: there is no rating there to round.
pub fn window_pr(games: List(Game), minimum: Int) -> Option(Float) {
  let decisions = list.fold(games, 0, fn(acc, g) { acc + g.decisions })
  case list.length(games) >= minimum && decisions > 0 {
    False -> None
    True -> {
      let error = list.fold(games, 0.0, fn(acc, g) { acc +. g.error })
      Some(one_decimal(error /. int.to_float(decisions) *. 500.0))
    }
  }
}

/// The line under the two numbers, in words. A lower PR is a better one,
/// which is exactly the thing a number alone does not say.
pub fn sentence(recent: Option(Float), career: Option(Float)) -> String {
  case recent, career {
    Some(recent), Some(career) -> {
      let comparison = case float.compare(recent, career) {
        order.Lt -> "better than"
        order.Gt -> "worse than"
        order.Eq -> "the same as"
      }
      "Recent "
      <> one_decimal_string(recent)
      <> ", "
      <> comparison
      <> " your career "
      <> one_decimal_string(career)
      <> "."
    }
    _, _ ->
      "Play " <> int.to_string(min_games) <> " games and your PR appears here."
  }
}

fn point_json(game: Game) -> Json {
  json.object([
    #("game_id", json.string(game.game_id)),
    #("game_number", json.int(game.game_number)),
    #("pr", json.float(one_decimal(game.pr))),
    #("error", json.float(game.error)),
    #("decisions", json.int(game.decisions)),
    #("ended_at", json.int(game.ended_at_ms)),
  ])
}

// ---------- Recent games ----------

fn game_json(game: Game) -> Json {
  json.object([
    #("game_id", json.string(game.game_id)),
    #("game_number", json.int(game.game_number)),
    #("slug", json.string(game.slug)),
    #(
      "path",
      json.string(room.replay_path(game.slug, game.game_id, game.game_number)),
    ),
    #("opponent", nullable_string(game.opponent)),
    #("result", case game.won {
      None -> json.null()
      Some(won) ->
        json.object([
          #("won", json.bool(won)),
          #("points", json.int(game.points)),
          #("kind", json.string(game.kind)),
        ])
    }),
    #("pr", json.float(one_decimal(game.pr))),
    #("error", json.float(game.error)),
    #("decisions", json.int(game.decisions)),
    #("ended_at", json.int(game.ended_at_ms)),
  ])
}

// ---------- Practice ----------

/// What is due, how big the deck is, the ladder, and the days practised.
/// Reading a deck never creates one: a player who has never practised has
/// an empty deck, not a new one.
fn practice_json(ctx: Ctx, uid: String) -> Json {
  let summary = ctx.practice.summary(uid, []) |> list.first
  json.object([
    #(
      "due",
      json.int(case summary {
        Ok(row) -> row.due_count
        Error(_) -> 0
      }),
    ),
    #(
      "deck",
      json.int(case summary {
        Ok(row) -> row.count
        Error(_) -> 0
      }),
    ),
    #("ladder", json.array(ctx.practice.ladder(uid), json.int)),
    #("days", json.array(ctx.practice.days(uid, practice_days), json.bool)),
  ])
}

// ---------- Paging ----------

/// Where this page stopped, when there is another one after it. It is the
/// last **row** read, not the last game shown: a row the page did not count
/// must still be stepped over, or the next page would start on it again.
fn next_cursor(page: List(GradedGame), rows: Int) -> Option(String) {
  case rows > page_size {
    False -> None
    True ->
      list.last(page)
      |> result.map(fn(row) {
        int.to_string(row.ended_at_ms)
        <> ":"
        <> int.to_string(row.game_number)
        <> ":"
        <> row.game_id
      })
      |> option.from_result
  }
}

/// A page marker back into its three parts. Anything else is a refusal:
/// reading a mangled marker as "no marker" would hand a paging client the
/// first page for ever.
pub fn parse_cursor(before: Option(String)) -> Result(Option(Cursor), ApiError) {
  case before {
    None -> Ok(None)
    Some("") -> Ok(None)
    Some(raw) ->
      case string.split(raw, ":") {
        [at, number, game_id] if game_id != "" ->
          case int.parse(at), int.parse(number) {
            // A marker names a moment this site could have existed at.
            // Anything else is not one, and it must be refused here rather
            // than handed on as a date nothing can be made of.
            Ok(at), Ok(number) if at >= 0 && at <= latest_cursor_ms ->
              Ok(Some(Cursor(ended_at_ms: at, game_number: number, game_id:)))
            _, _ -> Error(error.validation_failed(bad_cursor_message))
          }
        _ -> Error(error.validation_failed(bad_cursor_message))
      }
  }
}

// ---------- Numbers ----------

/// One decimal. A PR is not precise enough to justify a second, and "8.4"
/// is how the books write it.
pub fn one_decimal(value: Float) -> Float {
  int.to_float(float.round(value *. 10.0)) /. 10.0
}

/// The same number as the page prints it, so the sentence can never
/// disagree with the figures above it.
fn one_decimal_string(value: Float) -> String {
  float.to_string(one_decimal(value))
}

fn nullable_float(value: Option(Float)) -> Json {
  case value {
    Some(value) -> json.float(value)
    None -> json.null()
  }
}

fn nullable_string(value: Option(String)) -> Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}
