//// The signed-in home, in one answer:
////
////   GET /papi/me/home                    everything the page draws
////   GET /papi/me/games/graded?before=     the next page of recent rooms
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
////     come from the `games` rows (`landing.my_games`), the form and the
////     recent list from the stored reviews -- the same rows read twice,
////     once counted in games because that is what a rating is made of and
////     once counted in rooms because that is what a player remembers
////     playing -- practice and the streak from the deck. A home visit
////     costs a handful of reads however many games are behind it.
////   * **Everything is the account's**, by the one holder rule: a seat
////     whose `user_id` is theirs. A guest has no home of this kind -- their
////     games arrive when they sign in -- so a guest is told exactly that
////     (`signed_in: false`) and the client keeps the home it has.
////   * **Only graded games count.** A game the engine has not answered
////     for, or failed on, is worth nothing to a rating, exactly as it is
////     worth nothing to the match PR. Neither is a game whose stored
////     answer does not carry the totals a rating is made of: it counts for
////     nothing rather than as a zero.

import gamekit/registry
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import oskol/caps/analysis.{
  type Cursor, type GradedRoomGame, type RatedGame, Cursor,
}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/session.{type Session}
import oskol/handlers/landing
import oskol/practice/deck
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

/// How many recent **rooms** ride in the home answer, and how many a page
/// of `/papi/me/games/graded` carries. Rooms, not games: a match to seven
/// is one line of that list whether it ran two games or nine, which is
/// what a player remembers playing.
pub const page_size = 10

/// How far back the streak is counted. A streak is walked back from today
/// until the first day off, so the read is bounded by this and not by how
/// long the account has existed; a streak longer than this reads as this,
/// and nobody is within a year of it.
pub const streak_window = 366

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

/// One graded game as a **rating** counts it: which game it was, and the
/// numbers a rating over several games is made of. This is what the form,
/// the chart and the career number are worked out over, and it is all
/// those need.
pub type Rated {
  Rated(
    game_id: String,
    game_number: Int,
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

/// One graded game as the recent list **shows** it: its rating, plus how
/// it went and where its replay is.
pub type Game {
  Game(
    rated: Rated,
    slug: String,
    /// None where no record row says how the game ended.
    won: Option(Bool),
    points: Int,
    kind: String,
  )
}

/// A **room** as the recent list shows it: a match, an unlimited session or
/// a single game, with the games of it the engine has graded inside.
///
/// The score is added up from those games' own result lines, so a room
/// half-graded shows the half it knows and says nothing about the rest.
/// Who *won* is not read off that score but off the room's own row
/// (`won`): a match whose last game the engine has not answered for yet
/// would otherwise be handed to the wrong player.
pub type Room {
  Room(
    id: String,
    slug: String,
    /// The format in the words a player uses: "Match to 7", "Unlimited",
    /// "Single game".
    format: String,
    opponent: Option(String),
    /// Points, this account's first, over the graded games.
    yours: Int,
    theirs: Int,
    /// The room is finished.
    over: Bool,
    /// Whether this account won it, where it is over and its row says who
    /// did. None while it is still being played, and None rather than a
    /// guess where nothing recorded a winner.
    won: Option(Bool),
    /// This account's rating over the room's graded games, decision-weighted
    /// exactly as the form's windows are: a two-decision game does not weigh
    /// like a fifty-decision one, so a match PR is not the mean of its
    /// games' PRs.
    pr: Float,
    decisions: Int,
    /// The newest of its games' answers: what the list is ordered on.
    ended_at_ms: Int,
    /// The replay of the first game of it the engine has graded.
    path: String,
    /// Newest first, as the list shows them.
    games: List(Game),
  )
}

/// The rows of one room, as they arrived: the cap hands a room's games
/// together, so they are folded up as they come and the order the page is
/// paged on is the order they were read in.
type Grouped {
  Grouped(id: String, ended_at_ms: Int, rows: List(GradedRoomGame))
}

// ---------- GET /papi/me/home ----------

/// The whole page. A guest gets the one flag that says so.
pub fn home_json(ctx: Ctx, session: Session) -> String {
  case session.user_id {
    None -> guest_body
    Some(uid) -> {
      // Two reads of the same rows, counted two ways: a rating is made of
      // games, and the recent list is made of rooms. Both are bounded and
      // neither wakes anything.
      let games = counted(ctx.analysis.graded_for(uid, career_cap + 1))
      let page = recent_page(ctx, uid, None)
      envelope.ok([
        #("signed_in", json.bool(True)),
        #("live", json.preprocessed_array(landing.my_games(ctx, session))),
        #("form", form_json(games, streak(ctx, uid))),
        #("practice", practice_json(ctx, uid)),
        #("recent", json.preprocessed_array(list.map(page.rooms, room_json))),
        #("more", json.bool(page.more)),
        #("next", nullable_string(page.next)),
      ])
    }
  }
}

// ---------- GET /papi/me/games/graded ----------

/// The next ten rooms. `before` is the `next` of the answer before it;
/// nothing else is a page marker, and a mangled one is refused rather than
/// quietly read as "from the top" -- a client that thinks it is paging and
/// is being handed the first page again would loop for ever.
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
          #("rooms", json.preprocessed_array([])),
          #("more", json.bool(False)),
          #("next", json.null()),
        ]),
      )
    Some(uid) -> {
      let page = recent_page(ctx, uid, cursor)
      Ok(
        envelope.ok([
          #("rooms", json.preprocessed_array(list.map(page.rooms, room_json))),
          #("more", json.bool(page.more)),
          #("next", nullable_string(page.next)),
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
pub fn counted(rows: List(RatedGame)) -> List(Rated) {
  list.filter_map(rows, fn(row) {
    rated(
      row.game_id,
      row.game_number,
      row.seat,
      row.response_json,
      row.ended_at_ms,
    )
  })
}

/// The same, for the rows the recent list reads: the rating, and how the
/// game went with it.
fn counted_games(rows: List(GradedRoomGame)) -> List(Game) {
  list.filter_map(rows, fn(room) {
    let row = room.game
    use rating <- result.try(rated(
      row.game_id,
      row.game_number,
      row.seat,
      row.response_json,
      row.ended_at_ms,
    ))
    Ok(Game(
      rated: rating,
      slug: row.slug,
      won: option.map(row.winner, fn(w) { w == row.player_id }),
      points: row.points,
      kind: row.kind,
    ))
  })
}

fn rated(
  game_id: String,
  game_number: Int,
  seat: Int,
  response_json: String,
  ended_at_ms: Int,
) -> Result(Rated, Nil) {
  use totals <- result.try(seat_totals(response_json, seat))
  let decisions = totals.move_decisions + totals.cube_decisions
  case decisions {
    0 -> Error(Nil)
    _ ->
      Ok(Rated(
        game_id: game_id,
        game_number: game_number,
        pr: totals.pr,
        error: totals.error,
        decisions: decisions,
        ended_at_ms: ended_at_ms,
      ))
  }
}

/// This account's seat's totals out of the stored answer, when they are
/// there. `player_totals` has already taken off the opening roll's phantom
/// "no double", so these are the numbers the match PR is made of too.
fn seat_totals(response_json: String, seat: Int) -> Result(Totals, Nil) {
  report.player_totals(response_json)
  |> result.replace_error(Nil)
  |> result.try(fn(ratings) {
    list.drop(ratings, seat)
    |> list.first
    |> result.try(fn(rating) { option.to_result(rating.1, Nil) })
  })
}

// ---------- Form ----------

fn form_json(games: List(Rated), streak: Int) -> Json {
  let recent = window_pr(list.take(games, recent_window), min_games)
  let career = window_pr(games, min_games)
  json.object([
    #("games", json.int(list.length(games))),
    #("recent", nullable_float(recent)),
    #("career", nullable_float(career)),
    #("streak", json.int(streak)),
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
pub fn window_pr(games: List(Rated), minimum: Int) -> Option(Float) {
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

// ---------- The streak ----------

/// How many days running this account has been here. The long-term hook,
/// so what counts is the whole of what a player does: a puzzle answered or
/// a game of theirs that finished, in their own local day.
fn streak(ctx: Ctx, uid: String) -> Int {
  days_running(ctx.activity.days(uid, streak_window))
}

/// The run of active days ending today -- or ending yesterday, while today
/// is still young. `days` is oldest first and ends today, as the strip is
/// ordered.
///
/// Today counts as soon as the player is active, and until then the streak
/// is whatever it stood at yesterday: a number that reads 0 all morning and
/// jumps to 12 after one puzzle is a number that punishes people for not
/// having played yet. A whole day missed ends it. This is `Retain.streak`'s
/// own rule, applied to the two sources together, so the deck's number and
/// this one can never disagree.
pub fn days_running(days: List(Bool)) -> Int {
  case list.reverse(days) {
    [] -> 0
    [today, ..earlier] ->
      case today {
        True -> 1 + run(earlier)
        False -> run(earlier)
      }
  }
}

/// The unbroken run at the front of a newest-first list.
fn run(days: List(Bool)) -> Int {
  case days {
    [True, ..rest] -> 1 + run(rest)
    _ -> 0
  }
}

fn point_json(game: Rated) -> Json {
  json.object([
    #("game_id", json.string(game.game_id)),
    #("game_number", json.int(game.game_number)),
    #("pr", json.float(one_decimal(game.pr))),
    #("error", json.float(game.error)),
    #("decisions", json.int(game.decisions)),
    #("ended_at", json.int(game.ended_at_ms)),
  ])
}

// ---------- Recent rooms ----------

/// One page of the recent list, and where it stopped.
type Page {
  Page(rooms: List(Room), more: Bool, next: Option(String))
}

/// The newest rooms this account has graded games in, with the rest of the
/// page's answer. One room over the page is read, which is how `more` is
/// known without counting anything.
fn recent_page(ctx: Ctx, uid: String, cursor: Option(Cursor)) -> Page {
  let grouped = group(ctx.analysis.graded_rooms_for(uid, page_size + 1, cursor))
  let page = list.take(grouped, page_size)
  let more = list.length(grouped) > page_size
  Page(
    // A room whose every graded game turned out to have nothing to rate is
    // not shown -- but it was still read, so it is still stepped over: the
    // marker below is the last room *read*, never the last one shown.
    rooms: list.filter_map(page, room_of),
    more: more,
    next: case more {
      False -> None
      True ->
        list.last(page)
        |> result.map(marker)
        |> option.from_result
    },
  )
}

/// The rows folded back into rooms, in the order they were read. The cap
/// hands a room's games together and the rooms newest first, so this walks
/// the list once and never sorts: the order the page is paged on has to be
/// the order the query gave, or a marker would point into the middle of it.
fn group(rows: List(GradedRoomGame)) -> List(Grouped) {
  list.fold(rows, [], fn(acc, row) {
    case acc {
      [Grouped(id, at, rs), ..rest] if id == row.game.game_id -> [
        Grouped(id, int.max(at, row.game.ended_at_ms), [row, ..rs]),
        ..rest
      ]
      _ -> [Grouped(row.game.game_id, row.game.ended_at_ms, [row]), ..acc]
    }
  })
  |> list.reverse
  |> list.map(fn(g) { Grouped(..g, rows: list.reverse(g.rows)) })
}

/// One room, where there is anything to say about it. A room none of whose
/// graded games carry the totals a rating is made of has no rating and no
/// line: it is left out rather than drawn as a flawless nothing.
fn room_of(grouped: Grouped) -> Result(Room, Nil) {
  use head <- result.try(list.first(grouped.rows))
  let games = counted_games(grouped.rows)
  let ratings = list.map(games, fn(game) { game.rated })
  use pr <- result.try(option.to_result(window_pr(ratings, 1), Nil))
  use oldest <- result.try(list.last(games))
  let #(yours, theirs) = score(games)
  Ok(Room(
    id: grouped.id,
    slug: head.game.slug,
    format: format_name(head.game.slug, head.format),
    opponent: head.game.opponent,
    yours: yours,
    theirs: theirs,
    over: head.over,
    // Only where the row actually names a winner: a finished room with
    // nothing recorded says nothing, rather than reading as a loss.
    won: case head.over, head.winners {
      True, [_, ..] -> Some(list.contains(head.winners, head.game.player_id))
      _, _ -> None
    },
    pr: pr,
    decisions: list.fold(ratings, 0, fn(acc, rating) { acc + rating.decisions }),
    ended_at_ms: grouped.ended_at_ms,
    path: room.replay_path(oldest.slug, grouped.id, oldest.rated.game_number),
    games: games,
  ))
}

/// The points each side has, over the games the engine has graded. Each
/// game's `won` is already read against this account's own seat, so the
/// first number is always theirs. A game whose record line has not been
/// written says nothing about who won it, and so adds nothing to either
/// side rather than a point to the wrong one.
fn score(games: List(Game)) -> #(Int, Int) {
  list.fold(games, #(0, 0), fn(acc, game) {
    let #(yours, theirs) = acc
    case game.won {
      Some(True) -> #(yours + game.points, theirs)
      Some(False) -> #(yours, theirs + game.points)
      None -> acc
    }
  })
}

/// What was being played, in the words the game itself uses: "Match to 7",
/// "Unlimited", "Single game" -- the format's own name out of the registry,
/// exactly as an invite link reads it. A format the game no longer lists
/// falls back to the game's name, because the one thing still true about
/// it is which game it was.
pub fn format_name(slug: String, format: String) -> String {
  case registry.find(slug) {
    Error(_) -> "Backgammon"
    Ok(entry) ->
      case list.find(entry.info.formats, fn(f) { f.id == format }) {
        Ok(found) -> found.name
        Error(_) -> entry.info.name
      }
  }
}

fn room_json(value: Room) -> Json {
  json.object([
    #("id", json.string(value.id)),
    #("slug", json.string(value.slug)),
    #("format", json.string(value.format)),
    #("opponent", nullable_string(value.opponent)),
    #(
      "score",
      json.object([
        #("yours", json.int(value.yours)),
        #("theirs", json.int(value.theirs)),
      ]),
    ),
    #("over", json.bool(value.over)),
    #("won", case value.won {
      Some(won) -> json.bool(won)
      None -> json.null()
    }),
    #("pr", json.float(one_decimal(value.pr))),
    #("decisions", json.int(value.decisions)),
    #("ended_at", json.int(value.ended_at_ms)),
    #("path", json.string(value.path)),
    #("games", json.preprocessed_array(list.map(value.games, game_json))),
  ])
}

/// One game inside a room. The room names the opponent and the room, so a
/// game says only which game it was, how it went, what it was rated and
/// where its replay is.
fn game_json(game: Game) -> Json {
  json.object([
    #("game_number", json.int(game.rated.game_number)),
    #(
      "path",
      json.string(room.replay_path(
        game.slug,
        game.rated.game_id,
        game.rated.game_number,
      )),
    ),
    #("result", case game.won {
      None -> json.null()
      Some(won) ->
        json.object([
          #("won", json.bool(won)),
          #("points", json.int(game.points)),
          #("kind", json.string(game.kind)),
        ])
    }),
    #("pr", json.float(one_decimal(game.rated.pr))),
    #("decisions", json.int(game.rated.decisions)),
    #("ended_at", json.int(game.rated.ended_at_ms)),
  ])
}

// ---------- Practice ----------

/// What is due, how big the deck is, the ladder, the days practised,
/// where today stands, and the mistakes by band with how many are
/// patched and which tier to lead with.
/// Reading a deck never creates one: a player who has never practised has
/// an empty deck, not a new one.
fn practice_json(ctx: Ctx, uid: String) -> Json {
  let summary = ctx.practice.summary(uid, []) |> list.first
  let tiers = deck.tiers(ctx, uid)
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
    // The day's count: answers recorded in this account's own local day,
    // with nothing to measure them against. The same object
    // `/papi/practice` carries.
    #("today", deck.today_json(deck.today(ctx, uid))),
    // The deck by how bad the mistake was, worst band first: how much of
    // each band is patched and what each still has to do today, plus the
    // one tier to lead with. The practice hub's own answer, so the two
    // pages cannot choose differently.
    #("severity", json.array(tiers, deck.severity_json)),
    #("lead", case deck.lead(tiers) {
      Some(grade) -> json.string(grade)
      None -> json.null()
    }),
    // What "patched" means, so the page can say it in words without
    // keeping a second copy of the number.
    #("patched_level", json.int(deck.patched_level)),
  ])
}

// ---------- Paging ----------

/// Where this page stopped: the last **room** read, not the last one
/// shown. A room the page read and did not draw must still be stepped
/// over, or the next page would start on it again.
///
/// It names a room and never a game, which is what makes a page boundary
/// unable to fall inside a match: there is no marker that could point at
/// game five of nine.
fn marker(grouped: Grouped) -> String {
  int.to_string(grouped.ended_at_ms) <> ":" <> grouped.id
}

/// A page marker back into its two parts. Anything else is a refusal:
/// reading a mangled marker as "no marker" would hand a paging client the
/// first page for ever.
pub fn parse_cursor(before: Option(String)) -> Result(Option(Cursor), ApiError) {
  case before {
    None -> Ok(None)
    Some("") -> Ok(None)
    Some(raw) ->
      case string.split(raw, ":") {
        [at, room_id] if room_id != "" ->
          case int.parse(at) {
            // A marker names a moment this site could have existed at.
            // Anything else is not one, and it must be refused here rather
            // than handed on as a date nothing can be made of.
            Ok(at) if at >= 0 && at <= latest_cursor_ms ->
              Ok(Some(Cursor(ended_at_ms: at, room_id:)))
            _ -> Error(error.validation_failed(bad_cursor_message))
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
