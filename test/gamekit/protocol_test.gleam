//// The host surface as Elixir sees it, exercised with backgammon.

import gamekit/action
import gamekit/clock
import gamekit/event
import gamekit/game
import gamekit/host
import gamekit/instance.{type Instance}
import gamekit/registry
import gamekit/scene
import gamekit/text
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn seats() {
  [#("p1", "Alice"), #("p2", "Bob")]
}

/// Whoever holds a `move` schema is the player to move.
fn mover(inst: Instance) -> #(String, String) {
  case list.any(instance.legal(inst, "p1"), fn(s) { s.name == "move" }) {
    True -> #("p1", "p2")
    False -> #("p2", "p1")
  }
}

/// The first legal move as raw JSON, the way the channel delivers it.
fn first_move_json(inst: Instance, player: String) -> Dynamic {
  let assert Ok(move) =
    list.find(instance.legal(inst, player), fn(s) { s.name == "move" })
  let params =
    list.map(move.params, fn(p) {
      let assert action.Choice([#(id, _), ..]) = p.kind
      #(p.name, json.string(id))
    })
  let assert Ok(raw) =
    json.parse(
      json.to_string(
        json.object([
          #("name", json.string("move")),
          #("params", json.object(params)),
        ]),
      ),
      decode.dynamic,
    )
  raw
}

pub fn registry_lists_the_games_test() {
  assert list.map(registry.infos(), fn(i) { i.slug }) == ["backgammon"]
  assert host.game_exists("backgammon")
  assert host.game_exists("poker") == False
  assert host.game_exists("checkers") == False
  assert host.format_ids("backgammon")
    == ["single", "match3", "match5", "match7", "unlimited"]
  assert string.contains(host.games_json(), "\"slug\":\"backgammon\"")
}

pub fn host_starts_and_updates_test() {
  let assert Ok(inst) =
    host.start("backgammon", "single", [], seats(), 42, clock.NoClock, 0)
  assert host.slug(inst) == "backgammon"
  assert host.finished(inst) == False
  let payload = host.player_update_json(inst, "p1", [], 0)
  let assert Ok(keys) =
    json.parse(payload, decode.dict(decode.string, decode.dynamic))
  assert list.sort(dict.keys(keys), string.compare)
    == ["clock", "events", "legal", "outcome", "scene"]
  let spectator = host.spectator_update_json(inst, [event.Message("hi")], 0)
  assert string.contains(spectator, "\"viewer\":null")
  assert string.contains(spectator, "\"text\":\"hi\"")
}

pub fn host_rejects_bad_starts_test() {
  assert host.start("nope", "single", [], seats(), 1, clock.NoClock, 0)
    == Error("Unknown game: nope")
  assert host.start("backgammon", "epic", [], seats(), 1, clock.NoClock, 0)
    == Error("Unknown format: epic")
  let assert Error(_) =
    host.start(
      "backgammon",
      "single",
      [],
      [#("p1", "Solo")],
      1,
      clock.NoClock,
      0,
    )
}

pub fn apply_through_host_uses_legal_schema_test() {
  let assert Ok(inst) =
    host.start("backgammon", "single", [], seats(), 7, clock.NoClock, 0)
  let #(me, them) = mover(inst)
  // The waiting player can only resign
  assert list.map(instance.legal(inst, them), fn(s) { s.name }) == ["resign"]
  let raw = first_move_json(inst, me)
  let assert Ok(#(next, events)) = host.apply(inst, me, raw, 0)
  assert events != []
  // The original instance is untouched
  assert instance.legal(inst, me) != instance.legal(next, me)
  // Out of turn is refused with the game's own message
  assert host.apply(inst, them, raw, 0) == Error("Not your turn")
}

pub fn scene_has_expected_zones_test() {
  let assert Ok(inst) =
    host.start("backgammon", "single", [], seats(), 3, clock.NoClock, 0)
  let s = instance.scene(inst, scene.Player("p1"))
  assert s.game == "backgammon"
  assert s.phase == "moving"
  let ids = list.map(s.zones, fn(z) { z.id })
  assert list.contains(ids, "point:1")
  assert list.contains(ids, "point:24")
  assert list.contains(ids, "dice")
  let checkers =
    list.flat_map(s.zones, fn(z) { z.tokens })
    |> list.filter(fn(t) { t.kind == "checker" })
  assert list.length(checkers) == 30
  let assert [me, them] = s.players
  assert me.name == "Alice" && them.name == "Bob"
  assert scene.viewer_id(s.viewer) == Some("p1")
  assert scene.viewer_id(instance.scene(inst, scene.Spectator).viewer) == None
}

pub fn text_render_is_readable_test() {
  let assert Ok(inst) =
    host.start("backgammon", "single", [], seats(), 3, clock.NoClock, 0)
  let #(me, _) = mover(inst)
  let rendered = host.text(inst, me)
  assert string.contains(rendered, "== backgammon | phase: moving ==")
  assert string.contains(rendered, "player Alice (p1)")
  assert string.contains(rendered, "zone point:24")
  assert string.contains(rendered, "- move")
  let _ = text.render(instance.scene(inst, scene.Spectator))
  Nil
}

pub fn event_json_shapes_test() {
  assert json.to_string(
      event.to_json(event.moved("w1", "point:24", "point:18")),
    )
    == "{\"type\":\"token_moved\",\"token_id\":\"w1\",\"from\":\"point:24\",\"to\":\"point:18\"}"
  assert json.to_string(event.to_json(event.PhaseChanged("rolling")))
    == "{\"type\":\"phase_changed\",\"phase\":\"rolling\"}"
  assert event.describe(event.CounterChanged("p1", "pips", 167, 160))
    == "p1 pips: 167 -> 160"
}

pub fn clocks_follow_the_game_and_forfeit_on_timeout_test() {
  let assert Ok(inst) =
    host.start(
      "backgammon",
      "single",
      [],
      seats(),
      5,
      clock.Fischer(10_000, 0),
      0,
    )
  let #(me, them) = mover(inst)
  // Only the player to move is charged
  assert clock.running(instance.clocks(inst), me)
  assert clock.running(instance.clocks(inst), them) == False
  let raw = first_move_json(inst, me)
  let assert Ok(#(inst, _)) = host.apply(inst, me, raw, 4000)
  // Staging a move does not end the turn: still their clock
  assert clock.running(instance.clocks(inst), me)
  // Backgammon runs on a twelve-second delay every turn, so nine seconds in
  // the bank is untouched and three seconds of delay are left.
  assert clock.remaining(instance.clocks(inst), me, 9000) == 10_000
  assert clock.remaining(instance.clocks(inst), them, 9000) == 10_000
  assert host.next_deadline(inst, 9000) == Ok(13_000)
  // The bank only starts draining once the delay is spent
  assert clock.remaining(instance.clocks(inst), me, 14_000) == 8000
  // They never play and run out: twelve seconds of delay, then ten of bank
  assert host.expire(inst, 21_999) == Error(Nil)
  let assert Ok(#(over, events)) = host.expire(inst, 22_000)
  assert host.outcome(over) == game.Finished([them])
  assert instance.legal(over, me) == []
  let loser = case me {
    "p1" -> "Alice"
    _ -> "Bob"
  }
  assert list.any(events, fn(e) {
    e == event.Message(loser <> " ran out of time")
  })
  // Further actions are refused
  let assert Error(_) = host.apply(over, me, raw, 22_500)
  assert string.contains(
    host.player_update_json(over, me, [], 22_500),
    "\"timed_out\":\"" <> me <> "\"",
  )
}

/// The snapshot the platform writes beside every step: it is the mover's
/// turn (the waiting player may resign, and that is not their turn), nobody
/// is on a clock without one, and the players carry their public counters.
pub fn summary_json_is_the_public_state_test() {
  let assert Ok(inst) =
    host.start("backgammon", "single", [], seats(), 42, clock.NoClock, 0)
  let #(me, them) = mover(inst)
  let assert Ok(summary) =
    json.parse(
      host.summary_json(inst, 0),
      decode.dict(decode.string, decode.dynamic),
    )
  assert list.sort(dict.keys(summary), string.compare)
    == ["clocks", "on_clock", "outcome", "phase", "players", "to_act"]
  let assert Ok(to_act) = dict.get(summary, "to_act")
  assert decode.run(to_act, decode.list(decode.string)) == Ok([me])
  assert instance.legal(inst, them) != []
  let assert Ok(on_clock) = dict.get(summary, "on_clock")
  assert decode.run(on_clock, decode.list(decode.string)) == Ok([])
  let text = host.summary_json(inst, 0)
  // No clock: no times to report.
  assert string.contains(text, "\"clocks\":null")
  assert string.contains(text, "\"outcome\":{\"status\":\"ongoing\"}")
  assert string.contains(text, "\"counters\":{")
  assert string.contains(text, "\"score\":0")
  // Nothing hidden and nothing heavy: no zones, no tokens.
  assert !string.contains(text, "\"zones\"")
  assert !string.contains(text, "\"tokens\"")
}

/// With a clock, the mover's clock runs and `on_clock` says so.
pub fn summary_json_names_the_running_clock_test() {
  let assert Ok(inst) =
    host.start(
      "backgammon",
      "single",
      [],
      seats(),
      42,
      clock.Fischer(180_000, 0),
      0,
    )
  let #(me, _) = mover(inst)
  let assert Ok(summary) =
    json.parse(
      host.summary_json(inst, 0),
      decode.dict(decode.string, decode.dynamic),
    )
  let assert Ok(on_clock) = dict.get(summary, "on_clock")
  assert decode.run(on_clock, decode.list(decode.string)) == Ok([me])
  // Each seat's time as of `now`: the whole bank, the mover's free 12 s
  // still untouched at 0, and only the mover running. Five seconds in,
  // the delay has absorbed it and the bank is whole.
  let at_zero = host.summary_json(inst, 0)
  assert string.contains(
    at_zero,
    "{\"id\":\""
      <> me
      <> "\",\"remaining_ms\":180000,\"move_ms\":12000,\"running\":true}",
  )
  let later = host.summary_json(inst, 5000)
  assert string.contains(
    later,
    "{\"id\":\""
      <> me
      <> "\",\"remaining_ms\":180000,\"move_ms\":7000,\"running\":true}",
  )
  assert string.contains(later, "\"move_ms\":0,\"running\":false}")
}

/// Between the games of a match the game charges nobody, but it waits on
/// whoever has not pressed READY: that is whose turn the summary says it
/// is, so the home page can say "come back, it's on you" in exactly the
/// state a match sits in longest.
pub fn summary_names_who_owes_a_ready_between_games_test() {
  let assert Ok(inst) =
    host.start("backgammon", "match3", [], seats(), 3, clock.NoClock, 0)
  let between = play_until_between_games(inst, 600)
  assert string.contains(
    host.summary_json(between, 0),
    "\"phase\":\"between_games\"",
  )
  // Nobody is charged, and both still have to say they are ready.
  assert instance.to_act(between) == ["p1", "p2"]
  let assert Ok(#(after_one, _)) =
    host.apply(between, "p1", simple_json("ready"), 0)
  assert instance.to_act(after_one) == ["p2"]
}

fn simple_json(name: String) -> Dynamic {
  json.object([#("name", json.string(name)), #("params", json.object([]))])
  |> json.to_string
  |> json.parse(decode.dynamic)
  |> result_or_panic
}

fn result_or_panic(r: Result(a, b)) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> panic as "bad json"
  }
}

/// Play the first legal action that is not a resign, a double or a READY,
/// for whichever seat has one, until the match is between games.
fn play_until_between_games(inst: Instance, left: Int) -> Instance {
  case
    left,
    string.contains(host.summary_json(inst, 0), "\"phase\":\"between_games\"")
  {
    _, True -> inst
    0, _ -> panic as "never reached the end of a game"
    _, False -> {
      let pick =
        ["p1", "p2"]
        |> list.flat_map(fn(id) {
          instance.legal(inst, id)
          |> list.filter(fn(s) {
            !list.contains(["resign", "double", "ready", "undo"], s.name)
          })
          |> list.map(fn(s) { #(id, s) })
        })
      let assert [#(id, schema), ..] = pick
      let raw = schema_json(inst, id, schema)
      let assert Ok(#(next, _)) = host.apply(inst, id, raw, 0)
      play_until_between_games(next, left - 1)
    }
  }
}

/// A schema as raw JSON: the first candidate of every param.
fn schema_json(_inst: Instance, _id: String, schema: action.Schema) -> Dynamic {
  let params =
    list.map(schema.params, fn(p) {
      case p.kind {
        action.Choice([#(id, _), ..]) -> #(p.name, json.string(id))
        action.Select(_, [id, ..], _, _) -> #(p.name, json.string(id))
        _ -> #(p.name, json.null())
      }
    })
  json.object([
    #("name", json.string(schema.name)),
    #("params", json.object(params)),
  ])
  |> json.to_string
  |> json.parse(decode.dynamic)
  |> result_or_panic
}
