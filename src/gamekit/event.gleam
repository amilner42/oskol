//// Events are the animation script.
////
//// A game emits an ordered list of events for every action it applies. The
//// client plays them in sequence, then snaps to the new scene. Generic kinds
//// cover the common cases so a generic client can animate any game; `Custom`
//// carries game-specific payloads for bespoke views.

import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

pub type Event {
  /// A token left one zone for another. Either zone may be None when a token
  /// is created or destroyed.
  TokenMoved(token_id: String, from: Option(String), to: Option(String))
  /// A player counter changed (lives, score, chips...).
  CounterChanged(player_id: String, counter: String, from: Int, to: Int)
  /// A previously hidden token is now visible.
  Revealed(token_id: String, zone_id: String)
  /// The game moved to a new phase (playing, shop, game_over...).
  PhaseChanged(phase: String)
  /// A human-readable line for the log.
  Message(text: String)
  /// Game-specific payload for a bespoke client.
  Custom(kind: String, payload: Json)
}

pub fn to_json(event: Event) -> Json {
  case event {
    TokenMoved(token_id, from, to) ->
      json.object([
        #("type", json.string("token_moved")),
        #("token_id", json.string(token_id)),
        #("from", json.nullable(from, json.string)),
        #("to", json.nullable(to, json.string)),
      ])
    CounterChanged(player_id, counter, from, to) ->
      json.object([
        #("type", json.string("counter_changed")),
        #("player_id", json.string(player_id)),
        #("counter", json.string(counter)),
        #("from", json.int(from)),
        #("to", json.int(to)),
      ])
    Revealed(token_id, zone_id) ->
      json.object([
        #("type", json.string("revealed")),
        #("token_id", json.string(token_id)),
        #("zone_id", json.string(zone_id)),
      ])
    PhaseChanged(phase) ->
      json.object([
        #("type", json.string("phase_changed")),
        #("phase", json.string(phase)),
      ])
    Message(text) ->
      json.object([
        #("type", json.string("message")),
        #("text", json.string(text)),
      ])
    Custom(kind, payload) ->
      json.object([
        #("type", json.string("custom")),
        #("kind", json.string(kind)),
        #("payload", payload),
      ])
  }
}

pub fn moved(token_id: String, from: String, to: String) -> Event {
  TokenMoved(token_id, Some(from), Some(to))
}

pub fn created(token_id: String, to: String) -> Event {
  TokenMoved(token_id, None, Some(to))
}

pub fn destroyed(token_id: String, from: String) -> Event {
  TokenMoved(token_id, Some(from), None)
}

/// A short human-readable description, used by the text renderer and logs.
pub fn describe(event: Event) -> String {
  case event {
    TokenMoved(token_id, from, to) ->
      token_id
      <> " moved "
      <> option.unwrap(from, "nowhere")
      <> " -> "
      <> option.unwrap(to, "nowhere")
    CounterChanged(player_id, counter, from, to) ->
      player_id
      <> " "
      <> counter
      <> ": "
      <> int.to_string(from)
      <> " -> "
      <> int.to_string(to)
    Revealed(token_id, zone_id) -> token_id <> " revealed in " <> zone_id
    PhaseChanged(phase) -> "phase -> " <> phase
    Message(text) -> text
    Custom(kind, _) -> "[" <> kind <> "]"
  }
}
