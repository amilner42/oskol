//// What your mistakes cost you, in PR (`oskol/practice/cost`): the maths on
//// hand-made rows, the holder rule over the rows the query hands back, and
//// the two reads a page makes, on stub capabilities -- every one not
//// arranged for panics, so a read that reached the engine, a log or a
//// room fails here.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import oskol/caps/analysis.{
  type MistakeCost, type RatedGame, AnalysisCaps, MistakeCost, RatedGame,
}
import oskol/core/ctx.{Ctx}
import oskol/fakes
import oskol/handlers/home.{type Rated, Rated}
import oskol/practice/cost.{Cost, Window}
import oskol/rooms/seat

const uid = "user-1"

// ---------- Rows ----------

fn game(id: String, error: Float, decisions: Int) -> Rated {
  Rated(
    game_id: id,
    game_number: 1,
    pr: error /. int.to_float(decisions) *. 500.0,
    error: error,
    decisions: decisions,
    ended_at_ms: 0,
  )
}

/// The worked example: three games (the floor), 100 decisions, 2.0 lost
/// -- PR 10.0. Amounts a float holds exactly, so equality means equality.
fn window() -> List(Rated) {
  [game("g1", 0.75, 40), game("g2", 0.625, 30), game("g3", 0.625, 30)]
}

fn mistake(
  puzzle: String,
  band: String,
  game_id: String,
  lost: Float,
) -> MistakeCost {
  MistakeCost(
    puzzle_id: puzzle,
    band: band,
    game_id: game_id,
    game_number: 1,
    seat: seat.of_row(player_id: "p1", guest_id: Some("g"), user_id: Some(uid)),
    equity_lost: lost,
  )
}

// ---------- The maths ----------

pub fn the_worked_example_test() {
  let costs = [
    mistake("a", "very_bad", "g1", 0.3),
    mistake("b", "very_bad", "g2", 0.2),
    // Another band: not this one's to take away.
    mistake("c", "bad", "g1", 0.4),
  ]
  assert cost.of_band(window(), costs, ["b"], "very_bad")
    == Some(Cost(
      games: 2,
      decisions: 100,
      error: 2.0,
      lost: 0.5,
      lost_patched: 0.2,
      pr: 10.0,
      pr_without: 7.5,
      pr_patched: 9.0,
    ))
}

/// The number here and the career number beside a name are one number.
pub fn pr_is_the_careers_own_test() {
  let assert Some(c) = cost.of_band(window(), [], [], "bad")
  assert Some(c.pr) == home.window_pr(window(), home.min_games)
}

pub fn a_mistake_outside_the_window_is_dropped_test() {
  let costs = [
    mistake("a", "very_bad", "g1", 0.5),
    // A game nobody graded, or past the cap: never added to the window.
    mistake("z", "very_bad", "elsewhere", 1.5),
  ]
  let assert Some(c) = cost.of_band(window(), costs, ["z"], "very_bad")
  assert c.games == 1
  assert c.lost == 0.5
  assert c.lost_patched == 0.0
  assert c.pr_without == 7.5
  assert c.decisions == 100
}

pub fn the_same_game_number_matters_test() {
  // Game 2 of a match the window holds only game 1 of.
  let other = MistakeCost(..mistake("a", "bad", "g1", 0.5), game_number: 2)
  let assert Some(c) = cost.of_band(window(), [other], [], "bad")
  assert c.lost == 0.0
}

pub fn nothing_under_three_games_test() {
  let two = [game("g1", 1.0, 50), game("g2", 1.0, 50)]
  assert cost.of_band(two, [mistake("a", "bad", "g1", 0.1)], [], "bad") == None
  assert cost.of_all(two, [], []) == None
  assert cost.of_band([], [], [], "bad") == None
}

pub fn nothing_over_no_decisions_test() {
  let empty = [game("g1", 0.0, 0), game("g2", 0.0, 0), game("g3", 0.0, 0)]
  // `game` divides by zero for the engine's own pr; the window never does.
  let empty = list.map(empty, fn(g) { Rated(..g, pr: 0.0) })
  assert cost.of_band(empty, [], [], "bad") == None
}

pub fn a_band_with_no_mistakes_costs_nothing_test() {
  assert cost.of_band(
      window(),
      [mistake("a", "bad", "g1", 0.4)],
      [],
      "doubtful",
    )
    == Some(Cost(
      games: 0,
      decisions: 100,
      error: 2.0,
      lost: 0.0,
      lost_patched: 0.0,
      pr: 10.0,
      pr_without: 10.0,
      pr_patched: 10.0,
    ))
}

pub fn never_below_zero_test() {
  // The rows and the stored totals are rounded apart: what is taken away
  // can come out a hair over what was there.
  let costs = [mistake("a", "very_bad", "g1", 2.0001)]
  let assert Some(c) = cost.of_band(window(), costs, ["a"], "very_bad")
  assert c.pr_without == 0.0
  assert c.pr_patched == 0.0
}

pub fn all_bands_count_each_row_once_test() {
  let costs = [
    mistake("a", "very_bad", "g1", 0.25),
    // The same puzzle reached again in another game: the engine charged
    // both, so both count.
    mistake("a", "very_bad", "g2", 0.25),
    mistake("b", "bad", "g2", 0.125),
    mistake("c", "doubtful", "g3", 0.0625),
    // Not a band: nothing a deck holds, nothing to take away.
    mistake("d", "", "g3", 0.5),
  ]
  let assert Some(all) = cost.of_all(window(), costs, ["a"])
  assert all.games == 3
  assert all.lost == 0.6875
  assert all.lost_patched == 0.5
  // (2.0 - 0.6875) / 100 * 500 = 6.5625, and (2.0 - 0.5) / 100 * 500.
  assert all.pr_without == 6.6
  assert all.pr_patched == 7.5
  // And the bands add up to it.
  let lost =
    ["very_bad", "bad", "doubtful"]
    |> list.map(fn(band) {
      let assert Some(c) = cost.of_band(window(), costs, ["a"], band)
      c.lost
    })
    |> list.fold(0.0, fn(a, b) { a +. b })
  assert lost == all.lost
}

pub fn patched_is_the_fourth_rung_test() {
  assert cost.patched_ids([#("a", 3), #("b", 4), #("c", 7), #("d", 0)])
    == ["b", "c"]
}

// ---------- Whose rows ----------

pub fn the_holder_rule_decides_test() {
  let theirs =
    MistakeCost(
      ..mistake("x", "bad", "g1", 0.1),
      seat: seat.of_row(
        player_id: "p2",
        guest_id: Some("g"),
        user_id: Some("someone-else"),
      ),
    )
  // A seat no account owns is a guest's, whatever guest is on it.
  let unowned =
    MistakeCost(
      ..mistake("y", "bad", "g1", 0.1),
      seat: seat.of_row(player_id: "p1", guest_id: Some("g"), user_id: None),
    )
  let bot =
    MistakeCost(
      ..mistake("z", "bad", "g1", 0.1),
      seat: seat.Seat(
        player_id: "p2",
        guest_id: None,
        user_id: Some(uid),
        bot: True,
      ),
    )
  let mine = mistake("a", "bad", "g1", 0.1)
  assert cost.mine([theirs, unowned, bot, mine], uid) == [mine]
}

// ---------- The reads, on stubs ----------

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

fn rated_row(id: String, error: Float, decisions: Int) -> RatedGame {
  RatedGame(
    game_id: id,
    game_number: 1,
    seat: 0,
    response_json: json.to_string(
      json.object([
        #("turns", json.preprocessed_array([])),
        #(
          "players",
          json.preprocessed_array([totals(error, decisions), totals(1.0, 10)]),
        ),
      ]),
    ),
    ended_at_ms: 0,
  )
}

fn account_ctx(costs: List(MistakeCost)) {
  let ctx =
    fakes.ctx()
    |> fakes.with_graded(uid, [
      rated_row("g1", 0.75, 40),
      rated_row("g2", 0.625, 30),
      rated_row("g3", 0.625, 30),
    ])
  Ctx(
    ..ctx,
    analysis: AnalysisCaps(..ctx.analysis, mistake_costs: fn(asked) {
      case asked == uid {
        True -> costs
        False -> panic as "analysis.mistake_costs asked for another account"
      }
    }),
  )
}

pub fn a_guest_has_no_cost_and_reads_nothing_test() {
  // The stub caps panic: a guest's answer must not touch either read.
  let window = cost.read(fakes.ctx(), fakes.guest("guest-a"))
  assert window == None
  assert json.to_string(cost.tier_json(window, [], "very_bad")) == "null"
  assert json.to_string(cost.all_json(window, [])) == "null"
}

pub fn an_account_reads_its_window_and_its_rows_test() {
  let theirs =
    MistakeCost(
      ..mistake("x", "very_bad", "g1", 1.0),
      seat: seat.of_row(player_id: "p2", guest_id: None, user_id: Some("bob")),
    )
  let ctx =
    account_ctx([
      mistake("a", "very_bad", "g1", 0.3),
      mistake("b", "very_bad", "g2", 0.2),
      theirs,
    ])
  let window = cost.read(ctx, fakes.signed_in("guest-a", uid))
  let assert Some(Window(rated: rated, costs: costs)) = window
  assert list.length(rated) == 3
  // The other seat's row is dropped by the holder rule.
  assert list.length(costs) == 2
  assert json.to_string(cost.tier_json(window, ["b"], "very_bad"))
    == "{\"games\":2,\"lost\":0.5,\"lost_patched\":0.2,\"pr\":10.0,\"pr_without\":7.5,\"pr_patched\":9.0}"
  assert json.to_string(cost.all_json(window, ["b"]))
    == "{\"pr\":10.0,\"pr_without\":7.5,\"pr_patched\":9.0}"
}

pub fn an_account_under_three_games_reads_null_test() {
  let ctx = account_ctx([])
  let ctx = fakes.with_graded(ctx, uid, [rated_row("g1", 0.75, 40)])
  let window = cost.read(ctx, fakes.signed_in("guest-a", uid))
  assert json.to_string(cost.tier_json(window, [], "bad")) == "null"
  assert json.to_string(cost.all_json(window, [])) == "null"
}
