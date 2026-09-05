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
  assert list.map(registry.infos(), fn(i) { i.slug })
    == ["poker", "backgammon", "chess", "go"]
  assert host.game_exists("backgammon")
  assert host.game_exists("go")
  assert host.game_exists("chess")
  assert host.game_exists("checkers") == False
  assert host.format_ids("go") == ["9x9", "13x13", "19x19"]
  assert host.format_ids("chess") == ["standard"]
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
  assert clock.remaining(instance.clocks(inst), me, 9000) == 1000
  assert clock.remaining(instance.clocks(inst), them, 9000) == 10_000
  assert host.next_deadline(inst, 9000) == Ok(1000)
  // They never play and run out
  assert host.expire(inst, 9999) == Error(Nil)
  let assert Ok(#(over, events)) = host.expire(inst, 10_000)
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
  let assert Error(_) = host.apply(over, me, raw, 10_500)
  assert string.contains(
    host.player_update_json(over, me, [], 10_500),
    "\"timed_out\":\"" <> me <> "\"",
  )
}
