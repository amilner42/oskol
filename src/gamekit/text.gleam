//// Render a scene as plain text.
////
//// This is how agents and tests "see" a game without a browser. It is
//// deliberately generic: players, then zones with their tokens.

import gamekit/action.{type Schema}
import gamekit/scene.{type Scene, type Token, type Zone}
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn render(scene: Scene) -> String {
  let header = "== " <> scene.game <> " | phase: " <> scene.phase <> " =="
  let players = list.map(scene.players, render_player)
  let zones = list.map(scene.zones, render_zone)
  let data = case scene.data {
    [] -> []
    fields -> ["data: " <> json.to_string(json.object(fields))]
  }
  string.join(list.flatten([[header], players, zones, data]), "\n")
}

pub fn render_with_actions(scene: Scene, schemas: List(Schema)) -> String {
  let actions = case schemas {
    [] -> ["actions: (none)"]
    _ -> ["actions:", ..list.map(schemas, render_schema)]
  }
  render(scene) <> "\n" <> string.join(actions, "\n")
}

fn render_player(p: scene.PlayerInfo) -> String {
  let counters =
    p.counters
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(c) { c.0 <> "=" <> int.to_string(c.1) })
    |> string.join(" ")
  let flags = case p.flags {
    [] -> ""
    fs -> " [" <> string.join(fs, ",") <> "]"
  }
  "player " <> p.name <> " (" <> p.id <> "): " <> counters <> flags
}

fn render_zone(z: Zone) -> String {
  let owner = case z.owner {
    Some(id) -> " (" <> id <> ")"
    None -> ""
  }
  let tokens = case z.tokens {
    [] -> " x" <> int.to_string(z.count)
    ts -> ": " <> string.join(list.map(ts, render_token), " ")
  }
  "zone " <> z.id <> owner <> tokens
}

fn render_token(t: Token) -> String {
  case t.face {
    scene.Down -> "[" <> t.kind <> "?]"
    scene.Up -> {
      let props =
        t.props
        |> list.map(fn(p) { p.0 <> "=" <> json.to_string(p.1) })
        |> string.join(",")
      case props {
        "" -> "[" <> t.kind <> ":" <> t.id <> "]"
        _ -> "[" <> t.kind <> ":" <> t.id <> " " <> props <> "]"
      }
    }
  }
}

fn render_schema(s: Schema) -> String {
  let params =
    list.map(s.params, fn(p) {
      case p.kind {
        action.Select(zone, candidates, min, max) ->
          p.name
          <> ": select "
          <> int.to_string(min)
          <> ".."
          <> int.to_string(max)
          <> " from "
          <> zone
          <> " {"
          <> string.join(candidates, ",")
          <> "}"
        action.Choice(options) ->
          p.name
          <> ": one of {"
          <> string.join(list.map(options, fn(o) { o.0 }), ",")
          <> "}"
        action.Number(min, max) ->
          p.name
          <> ": number "
          <> int.to_string(min)
          <> ".."
          <> int.to_string(max)
      }
    })
  case params {
    [] -> "  - " <> s.name
    _ -> "  - " <> s.name <> " (" <> string.join(params, "; ") <> ")"
  }
}
