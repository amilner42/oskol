//// What your mistakes cost you, in PR.
////
//// "Had you not made these, your PR would be 7.4, not 11." A player's rating
//// is the equity they gave up over the decisions they made, times 500 -- the
//// engine's own definition, applied across games exactly as the home's
//// career number does (`home.window_pr`). Every mistake an account has made
//// is a `puzzle_sources` row with the equity it gave up, in the same unit as
//// the error that rating is made of. So the rating a band of mistakes left
//// behind is the same sum with that band's equity taken out:
////
////   pr          = error / decisions * 500
////   pr_without  = (error - lost) / decisions * 500
////   pr_patched  = (error - lost_patched) / decisions * 500
////
//// where the window is the account's counted games (`home.counted` over
//// `analysis.graded_for(uid, home.career_cap + 1)`, the very rows and
//// weighting the career number beside a name is made of, so this `pr` and
//// that one can never disagree), `lost` the equity the band's mistakes gave
//// up in games of that window, and `lost_patched` the same over the ones
//// the player has patched -- the number that moves as they practise.
////
//// Rows only. Nothing here spends engine time, replays a log, or writes.
////
//// Two choices worth knowing:
////
////   * A mistake belongs to the band of **its own row** -- how bad that
////     decision was in that game -- not to the worst band its puzzle was
////     ever reached at. A puzzle reached in two games is two rows and both
////     count: the engine charged both.
////   * A mistake in a game outside the window (not graded, its totals not
////     stored, or past the career cap) is dropped. It is never added to the
////     window: a game counts for the rating whole or not at all.

import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import oskol/caps/analysis.{type MistakeCost}
import oskol/core/ctx.{type Ctx}
import oskol/core/session.{type Session, Session}
import oskol/handlers/home.{type Rated}
import oskol/practice/deck
import oskol/rooms/seat

/// What one band of mistakes (or all of them) cost, over the account's
/// window of graded games.
pub type Cost {
  Cost(
    /// Games of the window holding at least one of these mistakes.
    games: Int,
    /// The window's decisions and the equity lost over them: what `pr` is.
    decisions: Int,
    error: Float,
    /// Equity these mistakes gave up, inside the window.
    lost: Float,
    /// The part of `lost` the player has since patched.
    lost_patched: Float,
    /// The rating as it is, as it would be without these mistakes, and as
    /// it would be without the ones patched. One decimal; never below 0.
    pr: Float,
    pr_without: Float,
    pr_patched: Float,
  )
}

/// Everything the cost of any band is worked out from: one account's
/// window and its mistakes, read once and shared by every tier of a page.
pub type Window {
  Window(rated: List(Rated), costs: List(MistakeCost))
}

// ---------- Reading ----------

/// The two reads, for a signed-in session; None for anybody else (a guest
/// has no rating to speak of -- a guest is a browser, not a person).
///
/// `graded_for` is the expensive one: it reaches into each stored answer
/// for two numbers, bounded by `home.career_cap`. Read once per answer and
/// hand the result to `tier_json` for each tier.
pub fn read(ctx: Ctx, session: Session) -> Option(Window) {
  case session.user_id {
    None -> None
    Some(uid) ->
      Some(Window(
        rated: home.counted(ctx.analysis.graded_for(uid, home.career_cap + 1)),
        costs: mine(ctx.analysis.mistake_costs(uid), uid),
      ))
  }
}

/// The holder rule, against the account alone: the query finds rows by
/// asking which seats name this account, and this is where a seat named
/// that way is confirmed theirs.
pub fn mine(costs: List(MistakeCost), user_id: String) -> List(MistakeCost) {
  let me = Session(guest_id: None, user_id: Some(user_id))
  list.filter(costs, fn(cost) { seat.holder(cost.seat, me) })
}

// ---------- The maths ----------

/// What one band's mistakes cost. `patched` is the puzzle ids the player has
/// patched (at or above `deck.patched_level`). None under `home.min_games`
/// counted games, or where the window graded no decision: there is no
/// rating there to take anything from. A band with no mistakes in the
/// window is `Some` with nothing lost.
pub fn of_band(
  rated: List(Rated),
  costs: List(MistakeCost),
  patched: List(String),
  band: String,
) -> Option(Cost) {
  cost(rated, list.filter(costs, fn(c) { c.band == band }), patched)
}

/// The same over the three bands together, for the one headline line. Each
/// row counts once, in the band it was graded in.
pub fn of_all(
  rated: List(Rated),
  costs: List(MistakeCost),
  patched: List(String),
) -> Option(Cost) {
  cost(
    rated,
    list.filter(costs, fn(c) { list.contains(deck.bands, c.band) }),
    patched,
  )
}

fn cost(
  rated: List(Rated),
  costs: List(MistakeCost),
  patched: List(String),
) -> Option(Cost) {
  let decisions = list.fold(rated, 0, fn(acc, g) { acc + g.decisions })
  case list.length(rated) >= home.min_games && decisions > 0 {
    False -> None
    True -> {
      let error = list.fold(rated, 0.0, fn(acc, g) { acc +. g.error })
      let window = set.from_list(list.map(rated, game_key))
      let inside = list.filter(costs, fn(c) { set.contains(window, key(c)) })
      let patched = set.from_list(patched)
      let lost = sum(inside)
      let lost_patched =
        sum(list.filter(inside, fn(c) { set.contains(patched, c.puzzle_id) }))
      let games = list.map(inside, key) |> set.from_list |> set.size
      Some(Cost(
        games: games,
        decisions: decisions,
        error: error,
        lost: lost,
        lost_patched: lost_patched,
        pr: rating(error, decisions),
        pr_without: rating(error -. lost, decisions),
        pr_patched: rating(error -. lost_patched, decisions),
      ))
    }
  }
}

fn game_key(game: Rated) -> #(String, Int) {
  #(game.game_id, game.game_number)
}

fn key(cost: MistakeCost) -> #(String, Int) {
  #(cost.game_id, cost.game_number)
}

fn sum(costs: List(MistakeCost)) -> Float {
  list.fold(costs, 0.0, fn(acc, c) { acc +. c.equity_lost })
}

/// The home's own arithmetic and rounding (`home.window_pr`), floored at
/// zero: a stored error and the rows taken from it are rounded separately,
/// and "-0.1" is not a rating.
fn rating(error: Float, decisions: Int) -> Float {
  float.max(0.0, home.one_decimal(error /. int.to_float(decisions) *. 500.0))
}

// ---------- The wire ----------

/// A mistakes tier's `cost`: `{games, lost, lost_patched, pr, pr_without,
/// pr_patched}`, or null where there is no window (a guest, a stranger, an
/// account under three graded games). `patched` is the tier's own patched
/// puzzle ids, or every patched id: only this band's rows are counted.
pub fn tier_json(
  window: Option(Window),
  patched: List(String),
  band: String,
) -> Json {
  case window {
    None -> json.null()
    Some(w) ->
      case of_band(w.rated, w.costs, patched, band) {
        None -> json.null()
        Some(c) -> cost_json(c)
      }
  }
}

/// The list answer's `cost_all`: `{pr, pr_without, pr_patched}` over every
/// band at once, or null.
pub fn all_json(window: Option(Window), patched: List(String)) -> Json {
  case window {
    None -> json.null()
    Some(w) ->
      case of_all(w.rated, w.costs, patched) {
        None -> json.null()
        Some(c) ->
          json.object([
            #("pr", json.float(c.pr)),
            #("pr_without", json.float(c.pr_without)),
            #("pr_patched", json.float(c.pr_patched)),
          ])
      }
  }
}

pub fn cost_json(c: Cost) -> Json {
  json.object([
    #("games", json.int(c.games)),
    #("lost", json.float(two_decimals(c.lost))),
    #("lost_patched", json.float(two_decimals(c.lost_patched))),
    #("pr", json.float(c.pr)),
    #("pr_without", json.float(c.pr_without)),
    #("pr_patched", json.float(c.pr_patched)),
  ])
}

/// Equity to the hundredth: "11.33 points" is as fine as anybody reads it.
fn two_decimals(value: Float) -> Float {
  int.to_float(float.round(value *. 100.0)) /. 100.0
}

/// The puzzle ids to hand as `patched`, from (puzzle id, level) pairs: the
/// ones at or above the rung the whole site calls patched.
pub fn patched_ids(levels: List(#(String, Int))) -> List(String) {
  list.filter_map(levels, fn(pair) {
    case pair.1 >= deck.patched_level {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
}
