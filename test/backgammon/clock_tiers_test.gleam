//// Backgammon's clock tiers: a feel a player picks (Bullet, Blitz,
//// Standard, Classic), sized to what is being played. A match keeps one
//// bank for the whole match at minutes per point of its length; unlimited
//// play and a single game give every game a fresh bank. Every tier keeps
//// the 12 s free delay on every turn.

import backgammon/game as backgammon
import gamekit/clock
import gamekit/game
import gamekit/host
import gamekit/instance.{type Instance}
import gamekit/replay
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

fn seats() {
  [#("p1", "Alice"), #("p2", "Bob")]
}

fn other(id: String) -> String {
  case id {
    "p1" -> "p2"
    _ -> "p1"
  }
}

/// Whoever holds a `move` schema is the player to move.
fn mover(inst: Instance) -> String {
  case list.any(instance.legal(inst, "p1"), fn(s) { s.name == "move" }) {
    True -> "p1"
    False -> "p2"
  }
}

fn raw(name: String) -> Dynamic {
  let assert Ok(value) =
    json.object([#("name", json.string(name)), #("params", json.object([]))])
    |> json.to_string
    |> json.parse(decode.dynamic)
  value
}

fn act(inst: Instance, id: String, name: String, now: Int) -> Instance {
  let assert Ok(#(next, _)) = host.apply(inst, id, raw(name), now)
  next
}

/// End the game on the board at `now`: the player not to move resigns a
/// single game and the mover accepts. One point to the mover.
fn resign_game(inst: Instance, now: Int) -> Instance {
  let m = mover(inst)
  inst
  |> act(other(m), "resign", now)
  |> act(m, "accept_resign", now)
}

fn phase(inst: Instance) -> String {
  let text = host.summary_json(inst, 0)
  case string.contains(text, "\"phase\":\"between_games\"") {
    True -> "between_games"
    False -> "playing"
  }
}

fn start(format: String, tier: String, seed: Int) -> Instance {
  let assert Ok(inst) =
    host.start(
      "backgammon",
      format,
      seats(),
      seed,
      host.clock_control("backgammon", format, tier),
      0,
    )
  inst
}

fn left(inst: Instance, id: String, now: Int) -> Int {
  clock.remaining(instance.clocks(inst), id, now)
}

// ---------- The banks ----------

pub fn the_tiers_are_offered_after_no_clock_and_keep_the_delay_test() {
  let info = backgammon.info()
  assert info.clocks
    == ["none", "bg_bullet", "bg_blitz", "bg_standard", "bg_classic"]
  assert info.default_clock == "none"
  assert info.turn_delay_ms == 12_000
  assert list.map(info.tiers, fn(t) { t.name })
    == ["Bullet", "Blitz", "Standard", "Classic"]
  // A tier's id never collides with a preset that old rooms carry ("blitz"
  // is one), and every id a room may carry is known to the host.
  list.each(info.tiers, fn(t) {
    let assert Error(_) = clock.preset(t.id)
    assert list.contains(host.clock_ids(), t.id)
  })
  let inst = start("match7", "bg_standard", 3)
  assert instance.clocks(inst).turn_delay_ms == 12_000
}

pub fn a_match_banks_minutes_per_point_of_its_length_test() {
  let bank = fn(format, tier) { host.clock_control("backgammon", format, tier) }
  assert bank("match3", "bg_bullet") == clock.Fischer(180_000, 0)
  assert bank("match3", "bg_blitz") == clock.Fischer(270_000, 0)
  assert bank("match3", "bg_standard") == clock.Fischer(360_000, 0)
  assert bank("match3", "bg_classic") == clock.Fischer(540_000, 0)
  assert bank("match7", "bg_bullet") == clock.Fischer(420_000, 0)
  assert bank("match7", "bg_blitz") == clock.Fischer(630_000, 0)
  assert bank("match7", "bg_standard") == clock.Fischer(840_000, 0)
  assert bank("match7", "bg_classic") == clock.Fischer(1_260_000, 0)
  assert bank("match21", "bg_bullet") == clock.Fischer(1_260_000, 0)
  assert bank("match21", "bg_standard") == clock.Fischer(2_520_000, 0)
  assert bank("match21", "bg_classic") == clock.Fischer(3_780_000, 0)
}

/// A match to 1 is one game, so it gets a game's bank, not a point's: the
/// single game is exactly that format.
pub fn a_one_point_match_is_a_single_game_and_banks_a_games_worth_test() {
  let one_point = dict.from_list([#("target", 1), #("cube", 1)])
  let assert [bullet, blitz, standard, classic] = backgammon.tiers()
  assert bullet.size(one_point).control == clock.PerPeriod(120_000)
  assert blitz.size(one_point).control == clock.PerPeriod(180_000)
  assert standard.size(one_point).control == clock.PerPeriod(300_000)
  assert classic.size(one_point).control == clock.PerPeriod(480_000)
  assert host.clock_control("backgammon", "single", "bg_standard")
    == clock.PerPeriod(300_000)
}

pub fn unlimited_banks_a_fresh_allowance_per_game_test() {
  let bank = fn(tier) { host.clock_control("backgammon", "unlimited", tier) }
  assert bank("bg_bullet") == clock.PerPeriod(120_000)
  assert bank("bg_blitz") == clock.PerPeriod(180_000)
  assert bank("bg_standard") == clock.PerPeriod(300_000)
  assert bank("bg_classic") == clock.PerPeriod(480_000)
}

pub fn the_words_say_the_bank_for_the_format_test() {
  let info = backgammon.info()
  let line = fn(format, tier) {
    let assert Ok(c) = game.clock_for(info, format, tier)
    c.line
  }
  assert line("match7", "bg_standard") == "14 min each for this 7-point match"
  assert line("match7", "bg_blitz") == "10.5 min each for this 7-point match"
  assert line("match3", "bg_bullet") == "3 min each for this 3-point match"
  assert line("match21", "bg_classic") == "63 min each for this 21-point match"
  assert line("unlimited", "bg_standard") == "5 min each per game"
  assert line("single", "bg_classic") == "8 min each for this game"
  assert host.clock_line("backgammon", "match7", "bg_standard")
    == "Standard clock · 14 min each"
  assert host.clock_line("backgammon", "unlimited", "bg_bullet")
    == "Bullet clock · 2 min each per game"
  assert host.clock_line("backgammon", "match7", "none") == ""
  // An old room's flat bank is still named as it was.
  assert host.clock_line("backgammon", "match7", "bg5") == "5 min clock"
}

/// Rooms made before the tiers carry the flat banks and the older presets:
/// they resolve exactly as they did, whatever the format, and are no
/// longer offered.
pub fn old_presets_still_resolve_unchanged_test() {
  let offered = backgammon.info().clocks
  [
    #("bg3", clock.Fischer(180_000, 0)),
    #("bg5", clock.Fischer(300_000, 0)),
    #("bg10", clock.Fischer(600_000, 0)),
    #("bg15", clock.Fischer(900_000, 0)),
    #("bg30", clock.Fischer(1_800_000, 0)),
    #("bg60", clock.Fischer(3_600_000, 0)),
    #("blitz", clock.Fischer(180_000, 2000)),
    #("rapid", clock.Fischer(600_000, 5000)),
    #("delay", clock.Bronstein(300_000, 10_000)),
    #("per_move", clock.PerMove(30_000)),
  ]
  |> list.each(fn(pair) {
    let #(id, control) = pair
    assert !list.contains(offered, id)
    assert list.contains(host.clock_ids(), id)
    assert host.clock_control("backgammon", "unlimited", id) == control
    assert host.clock_control("backgammon", "match7", id) == control
  })
  assert host.clock_control("backgammon", "match7", "nonsense") == clock.NoClock
}

// ---------- Across games ----------

/// Unlimited play refills both banks when the next game begins: the opening
/// roll of game two finds both players on a full bank, whatever game one
/// cost them.
pub fn unlimited_refills_both_banks_when_each_new_game_begins_test() {
  let inst = start("unlimited", "bg_standard", 11)
  let m = mover(inst)
  // The mover thinks for 100 s: 12 free, 88 from the bank.
  let inst = resign_game(inst, 100_000)
  assert phase(inst) == "between_games"
  assert left(inst, m, 150_000) == 212_000
  assert left(inst, other(m), 150_000) == 300_000
  // Between games nobody is charged and nothing is refilled yet.
  let inst = act(inst, "p1", "ready", 150_000)
  assert left(inst, m, 190_000) == 212_000
  let inst = act(inst, "p2", "ready", 200_000)
  assert phase(inst) == "playing"
  assert left(inst, "p1", 200_000) == 300_000
  assert left(inst, "p2", 200_000) == 300_000
  // And game two charges from the fresh bank after its delay.
  let m2 = mover(inst)
  assert left(inst, m2, 232_000) == 280_000
  // Game three refills again.
  let inst = resign_game(inst, 250_000)
  let inst = act(act(inst, "p1", "ready", 260_000), "p2", "ready", 260_000)
  assert left(inst, "p1", 260_000) == 300_000
  assert left(inst, "p2", 260_000) == 300_000
}

/// A match keeps one bank for the whole match: the next game does not
/// refill it.
pub fn a_match_carries_its_bank_across_games_test() {
  let inst = start("match3", "bg_standard", 11)
  let m = mover(inst)
  let inst = resign_game(inst, 100_000)
  let inst = act(act(inst, "p1", "ready", 200_000), "p2", "ready", 200_000)
  assert phase(inst) == "playing"
  assert left(inst, m, 200_000) == 360_000 - 88_000
  assert left(inst, other(m), 200_000) == 360_000
}

/// A single game is one game on one fresh bank: run it out and it is lost.
pub fn a_single_game_runs_out_on_its_own_bank_test() {
  let inst = start("single", "bg_bullet", 5)
  let m = mover(inst)
  assert left(inst, m, 0) == 120_000
  assert host.next_deadline(inst, 0) == Ok(132_000)
  let assert Error(Nil) = host.expire(inst, 131_999)
  let assert Ok(#(over, _)) = host.expire(inst, 132_000)
  assert host.outcome(over) == game.Finished([other(m)])
}

/// Late in a match the bank is what is left of the whole match's: a player
/// who spent it in game one loses the match on time in game two the moment
/// the delay and the rest run out.
pub fn a_timeout_late_in_a_match_spends_what_the_match_left_test() {
  let inst = start("match3", "bg_bullet", 11)
  let m = mover(inst)
  // Game one costs the mover 150 s of their 180.
  let inst = resign_game(inst, 162_000)
  let inst = act(act(inst, "p1", "ready", 200_000), "p2", "ready", 200_000)
  assert left(inst, m, 200_000) == 30_000
  // Whoever moves first in game two is charged from what they have left.
  let m2 = mover(inst)
  let rest = left(inst, m2, 200_000)
  assert rest
    == case m2 == m {
      True -> 30_000
      False -> 180_000
    }
  let deadline = 200_000 + 12_000 + rest
  assert host.next_deadline(inst, 200_000) == Ok(12_000 + rest)
  let assert Error(Nil) = host.expire(inst, deadline - 1)
  let assert Ok(#(over, _)) = host.expire(inst, deadline)
  assert host.outcome(over) == game.Finished([other(m2)])
  assert host.finished(over)
}

// ---------- Rehydration ----------

/// A game is its seed plus its log: replaying the log at its offsets lands
/// on the very banks the live room had, refills included.
pub fn a_replayed_log_lands_on_the_same_banks_test() {
  let control = host.clock_control("backgammon", "unlimited", "bg_blitz")
  let inst = start("unlimited", "bg_blitz", 11)
  let m = mover(inst)
  let steps = [
    #(other(m), "resign", 70_000),
    #(m, "accept_resign", 70_000),
    #("p1", "ready", 90_000),
    #("p2", "ready", 95_000),
  ]
  let live =
    list.fold(steps, inst, fn(acc, step) { act(acc, step.0, step.1, step.2) })
  let log =
    replay.Log(
      format_id: "unlimited",
      seats: list.map(seats(), fn(s) { game.Seat(id: s.0, name: s.1) }),
      seed: 11,
      control: control,
      entries: list.map(steps, fn(step) {
        replay.Act(step.0, raw(step.1), step.2)
      }),
    )
  let assert Ok(#(_, replayed)) =
    replay.fold(backgammon.game(), log, fn(_) { Nil }, fn(_, _) { Nil })
  assert instance.running_clocks(replayed) == instance.clocks(live)
  assert left(live, "p1", 95_000) == 180_000
  assert left(live, "p2", 95_000) == 180_000
}
