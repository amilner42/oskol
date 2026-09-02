import gamekit/action
import gamekit/event
import gamekit/host
import gamekit/instance
import gamekit/registry
import gamekit/scene
import gamekit/text
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn seats() {
  [#("p1", "Alice"), #("p2", "Bob")]
}

pub fn registry_lists_tilt_test() {
  assert list.map(registry.infos(), fn(i) { i.slug }) == ["tilt"]
  assert host.game_exists("tilt")
  assert host.game_exists("chess") == False
  assert host.format_ids("tilt") == ["short", "standard", "extended"]
  assert string.contains(host.games_json(), "\"slug\":\"tilt\"")
}

pub fn host_starts_and_updates_test() {
  let assert Ok(inst) = host.start("tilt", "standard", seats(), 42)
  assert host.slug(inst) == "tilt"
  assert host.finished(inst) == False
  let payload = host.player_update_json(inst, "p1", [])
  let assert Ok(keys) =
    json.parse(payload, decode.dict(decode.string, decode.dynamic))
  assert list.sort(dict.keys(keys), string.compare)
    == ["events", "legal", "outcome", "scene"]
  let spectator = host.spectator_update_json(inst, [event.Message("hi")])
  assert string.contains(spectator, "\"viewer\":null")
  assert string.contains(spectator, "\"text\":\"hi\"")
}

pub fn host_rejects_bad_starts_test() {
  assert host.start("nope", "standard", seats(), 1)
    == Error("Unknown game: nope")
  assert host.start("tilt", "epic", seats(), 1) == Error("Unknown format: epic")
  let assert Error(_) = host.start("tilt", "short", [#("p1", "Solo")], 1)
}

pub fn apply_through_host_uses_legal_schema_test() {
  let assert Ok(inst) = host.start("tilt", "short", seats(), 7)
  let assert [play, discard] = instance.legal(inst, "p1")
  assert play.name == "play_hand"
  assert discard.name == "discard"
  let assert [action.Param("cards", action.Select(zone, candidates, 1, 5))] =
    play.params
  assert zone == "hand:p1"
  assert list.length(candidates) == 8
  let raw_json =
    json.to_string(
      json.object([
        #("name", json.string("play_hand")),
        #(
          "params",
          json.object([
            #("cards", json.array(list.take(candidates, 2), json.string)),
          ]),
        ),
      ]),
    )
  let assert Ok(raw) = json.parse(raw_json, decode.dynamic)
  let assert Ok(#(next, events)) = host.apply(inst, "p1", raw)
  assert events != []
  assert instance.legal(next, "p1") == []
  // The original instance is untouched
  assert list.length(instance.legal(inst, "p1")) == 2
}

pub fn scene_has_expected_zones_test() {
  let assert Ok(inst) = host.start("tilt", "short", seats(), 3)
  let s = instance.scene(inst, scene.Player("p1"))
  assert s.game == "tilt"
  assert s.phase == "playing"
  assert list.map(s.zones, fn(z) { z.id })
    == [
      "hand:p1",
      "played:p1",
      "deck:p1",
      "discard:p1",
      "hand:p2",
      "played:p2",
      "deck:p2",
      "discard:p2",
    ]
  let assert Ok(own_deck) = scene.find_zone(s, "deck:p1")
  assert list.length(own_deck.tokens) == 44
  let assert Ok(their_deck) = scene.find_zone(s, "deck:p2")
  assert their_deck.tokens == []
  assert their_deck.count == 44
  let assert [me, them] = s.players
  assert me.name == "Alice" && them.name == "Bob"
  assert scene.viewer_id(s.viewer) == Some("p1")
  assert scene.viewer_id(instance.scene(inst, scene.Spectator).viewer) == None
}

pub fn text_render_is_readable_test() {
  let assert Ok(inst) = host.start("tilt", "short", seats(), 3)
  let rendered = host.text(inst, "p1")
  assert string.contains(rendered, "== tilt | phase: playing ==")
  assert string.contains(rendered, "player Alice (p1)")
  assert string.contains(rendered, "zone hand:p1")
  assert string.contains(rendered, "- play_hand")
  let _ = text.render(instance.scene(inst, scene.Spectator))
  Nil
}

pub fn action_validation_helpers_test() {
  let param = action.select("cards", "hand:p1", ["a", "b", "c"], 1, 2)
  assert action.validate_select(param, ["a"]) == Ok(Nil)
  assert action.validate_select(param, ["a", "b"]) == Ok(Nil)
  let assert Error(_) = action.validate_select(param, [])
  let assert Error(_) = action.validate_select(param, ["a", "b", "c"])
  let assert Error(_) = action.validate_select(param, ["a", "a"])
  let assert Error(_) = action.validate_select(param, ["z"])
}

pub fn event_json_shapes_test() {
  assert json.to_string(
      event.to_json(event.moved("AS", "hand:p1", "played:p1")),
    )
    == "{\"type\":\"token_moved\",\"token_id\":\"AS\",\"from\":\"hand:p1\",\"to\":\"played:p1\"}"
  assert json.to_string(event.to_json(event.PhaseChanged("shop")))
    == "{\"type\":\"phase_changed\",\"phase\":\"shop\"}"
  assert event.describe(event.CounterChanged("p1", "lives", 3, 2))
    == "p1 lives: 3 -> 2"
}
