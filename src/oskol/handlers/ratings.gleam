//// GET /papi/games/:slug/rooms/:id/ratings
////
//// How the two people at this table have played *in this match*: one
//// performance rating per seat, averaged over the games of this room the
//// analysis engine has already graded. The table prints it beside each
//// name ("Match PR: 8.4"), which is the number a backgammon player reads
//// first.
////
//// It needs nothing new: the engine's answers are already kept per room,
//// one row per game (`game_reviews`, the `analysis.ratings` cap), with a PR
//// per player in each. A game that is still pending, failed, or not over
//// yet simply does not count; a match with nothing graded yet has no
//// number to show, and one graded game shows its own PR.
////
//// It is open, like the record and the reviews: a match PR is a fact about
//// the games both players just played, and the room is the whole
//// credential. A room that is not there, or a slug that is not its game,
//// is the same one refusal -- a caller learns nothing about a room it did
//// not ask for.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/analysis.{type Stored, Done, Failed, Pending, Stored}
import oskol/caps/records.{type Setup}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/handlers/home
import oskol/handlers/reviews
import oskol/reviews/report

pub const not_found_message = "No ratings for that game"

/// One entry per seat, in seat order: the player id, how many games of this
/// match have been graded, the PR to print (null while none have), and
/// `career`, the same seat's rating over every graded game of the account
/// that owns it (null for a seat no account owns, or one with too few).
/// Plus `pending`, which says the engine still owes this room an answer, so
/// a table watching the number knows to ask again rather than poll forever.
/// And `games`: each graded game's PRs by seat, for the match panel.
pub fn ratings_json(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
) -> Result(String, ApiError) {
  use game <- result.try(room(ctx, game_slug, game_id))
  // Seat order is persisted. Looking up a running instance would wake a
  // cold room and replay its whole log merely to name these two seats.
  let seats = case game_slug == reviews.slug {
    True -> game.seats
    False -> []
  }
  let stored = ctx.analysis.ratings(game_id)
  let by_game = graded_by_game(stored)
  let graded = list.map(by_game, fn(g) { g.1 })
  Ok(
    envelope.ok([
      #("pending", json.bool(owed(stored))),
      #(
        "players",
        json.array(list.index_map(seats, fn(s, i) { #(s, i) }), fn(pair) {
          let #(#(player_id, _name, _guest_id, account_id), index) = pair
          let prs = list.filter_map(graded, at(_, index))
          json.object([
            #("player_id", json.string(player_id)),
            #("games", json.int(list.length(prs))),
            #("pr", nullable_float(average(prs))),
            #("career", nullable_float(career(ctx, account_id))),
          ])
        }),
      ),
      #(
        "games",
        json.array(by_game, fn(game) {
          let #(number, prs) = game
          json.object([
            #("game_number", json.int(number)),
            #(
              "players",
              json.array(
                list.index_map(seats, fn(s, i) { #(s.0, at(prs, i)) }),
                fn(pair) {
                  json.object([
                    #("player_id", json.string(pair.0)),
                    #("pr", case pair.1 {
                      Ok(pr) -> json.float(pr)
                      Error(_) -> json.null()
                    }),
                  ])
                },
              ),
            ),
          ])
        }),
      ),
    ]),
  )
}

/// The same, with each game's number, in game order.
fn graded_by_game(stored: List(Stored)) -> List(#(Int, List(Float))) {
  stored
  |> list.filter_map(fn(s) {
    case s {
      Stored(status: Done, response_json: Some(body), game_number: n, ..) ->
        report.player_prs(body) |> result.map(fn(prs) { #(n, prs) })
      _ -> Error("not graded")
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

/// Is a grade still on its way? A row the queue has opened but the engine
/// has not answered, or one that failed and will be tried again. Cheap on
/// purpose: a table asks this every few seconds while it waits, and it must
/// not replay a log to find out.
fn owed(stored: List(Stored)) -> Bool {
  list.any(stored, fn(s) {
    case s {
      Stored(status: Pending, ..) -> True
      Stored(status: Failed, attempts: attempts, ..) ->
        attempts < reviews.max_attempts
      _ -> False
    }
  })
}

fn at(prs: List(Float), index: Int) -> Result(Float, Nil) {
  list.drop(prs, index) |> list.first
}

/// How the account that owns this seat has played *everywhere*: its PR over
/// every game the engine has graded for it, which is the number the home
/// page prints as "Career" and the one a player recognises from other
/// sites. The match PR beside it stays what it always was.
///
/// It is the home's own number, worked out by the home's own maths
/// (`home.counted`, then `home.window_pr` over every game, decision-weighted
/// exactly as the engine rates one), so the table, the replay and the home
/// can never print two different careers for the same person.
///
/// Nothing for a seat no account owns -- a guest is a browser, not a person,
/// and has no career to speak of -- and nothing under
/// `home.min_career_games`: this number is a stranger's first impression of
/// a player, so it is held to a higher floor than the home's own.
///
/// Cost: one query per **owned** seat, so at most two for a table, each the
/// same indexed read the home makes and bounded by `home.career_cap`. It
/// reads rows only: no room is woken, no log replayed, no engine time spent.
fn career(ctx: Ctx, account_id: String) -> Option(Float) {
  case account_id {
    "" -> None
    user_id ->
      ctx.analysis.graded_for(user_id, home.career_cap, None)
      |> home.counted
      |> home.window_pr(home.min_career_games)
  }
}

fn nullable_float(value: Option(Float)) -> json.Json {
  case value {
    Some(value) -> json.float(value)
    None -> json.null()
  }
}

/// The number to print, or nothing when the engine has graded no game of
/// this match yet.
///
/// The average is the plain mean of the per-game PRs the engine already
/// computed -- one vote per game, not per turn. A short game and a long one
/// are both one game of backgammon, and weighting by turns would quietly
/// let the longest game speak for the whole match.
///
/// One decimal: a PR is not precise enough to justify a second, and "8.4"
/// is how the books write it.
pub fn average(prs: List(Float)) -> Option(Float) {
  case prs {
    [] -> None
    _ -> {
      let mean =
        list.fold(prs, 0.0, float.add) /. int.to_float(list.length(prs))
      Some(int.to_float(float.round(mean *. 10.0)) /. 10.0)
    }
  }
}

/// The same door the record and the reviews open: a room playing this
/// game, or the one refusal.
fn room(ctx: Ctx, game_slug: String, game_id: String) -> Result(Setup, ApiError) {
  case ctx.records.setup(game_id) {
    Some(setup) if setup.slug == game_slug -> Ok(setup)
    _ -> Error(error.NotFound(not_found_message))
  }
}
