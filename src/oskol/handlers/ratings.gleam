//// GET /papi/games/:slug/rooms/:id/ratings
////
//// How the two people at this table have played *in this match*: one
//// performance rating per seat, averaged over the games of this room the
//// analysis engine has already graded. The table prints it beside each
//// name ("Match PR: 8.4"), which is the number a backgammon player reads
//// first.
////
//// It needs nothing new: the engine's answers are already kept per room,
//// one row per game (`game_reviews`, the `analysis.stored` cap), with a PR
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
import oskol/caps/analysis.{type Stored, Done, Stored}
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/handlers/record
import oskol/handlers/reviews
import oskol/reviews/report

pub const not_found_message = "No ratings for that game"

/// One entry per seat, in seat order: the player id, how many games of this
/// match have been graded, and the PR to print (null while none have).
pub fn ratings_json(
  ctx: Ctx,
  game_slug: String,
  game_id: String,
) -> Result(String, ApiError) {
  use _ <- result.try(room(ctx, game_slug, game_id))
  let seats = case game_slug == reviews.slug, ctx.analysis.log(game_id) {
    True, Some(log) if log.slug == reviews.slug -> log.seats
    _, _ -> []
  }
  let graded = graded(ctx.analysis.stored(game_id))
  Ok(
    envelope.ok([
      #(
        "players",
        json.array(list.index_map(seats, fn(s, i) { #(s.0, i) }), fn(pair) {
          let #(player_id, index) = pair
          let prs = list.filter_map(graded, at(_, index))
          json.object([
            #("player_id", json.string(player_id)),
            #("games", json.int(list.length(prs))),
            #("pr", case average(prs) {
              Some(pr) -> json.float(pr)
              None -> json.null()
            }),
          ])
        }),
      ),
    ]),
  )
}

/// The PRs of every game of this room the engine has graded, each as its
/// players' ratings in seat order. A stored answer that does not read as a
/// review is skipped, exactly as the reviews page skips it.
fn graded(stored: List(Stored)) -> List(List(Float)) {
  list.filter_map(stored, fn(s) {
    case s {
      Stored(status: Done, response_json: Some(body), ..) ->
        report.player_prs(body)
      _ -> Error("not graded")
    }
  })
}

fn at(prs: List(Float), index: Int) -> Result(Float, Nil) {
  list.drop(prs, index) |> list.first
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
fn room(ctx: Ctx, game_slug: String, game_id: String) -> Result(Nil, ApiError) {
  record.room(ctx, game_slug, game_id)
  |> result.replace(Nil)
  |> result.replace_error(error.NotFound(not_found_message))
}
