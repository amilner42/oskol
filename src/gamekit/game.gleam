//// The game contract.
////
//// A game is a record of pure functions over its own state type. The host
//// (Elixir), the generic client, the bots, and the conformance tests only ever
//// talk to a game through this record, so adding a game never touches them.

import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gamekit/rng.{type Rng}
import gamekit/scene.{type PlayerId, type Scene, type Viewer}
import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list

/// Lobby-chosen settings. Kept to integers so it is trivially JSON and every
/// game can read what it needs with a default.
pub type Config =
  Dict(String, Int)

/// A named preset of settings offered in the lobby.
pub type Format {
  Format(id: String, name: String, description: String, config: Config)
}

pub type Info {
  Info(
    slug: String,
    name: String,
    tagline: String,
    description: String,
    min_players: Int,
    max_players: Int,
    formats: List(Format),
  )
}

pub type Seat {
  Seat(id: PlayerId, name: String)
}

pub type Outcome {
  Ongoing
  /// An empty winners list is a draw.
  Finished(winners: List(PlayerId))
}

pub type Game(state, action) {
  Game(
    info: Info,
    /// Build the initial state. All randomness comes from `rng`; store it in
    /// the state and thread it through `apply`.
    init: fn(Config, List(Seat), Rng) -> Result(state, String),
    /// Turn a raw incoming action into the game's own action type.
    decode_action: fn(action.Incoming) -> Result(action, String),
    /// Validate and apply. Must not change state when returning an error.
    apply: fn(state, PlayerId, action) -> Result(#(state, List(Event)), String),
    /// What this player may do right now, as schemas with candidates.
    legal: fn(state, PlayerId) -> List(Schema),
    /// Project the state for one viewer, resolving hidden information.
    scene: fn(state, Viewer) -> Scene,
    outcome: fn(state) -> Outcome,
  )
}

pub fn config_get(config: Config, key: String, default: Int) -> Int {
  case dict.get(config, key) {
    Ok(v) -> v
    Error(_) -> default
  }
}

pub fn find_format(info: Info, format_id: String) -> Result(Format, Nil) {
  list.find(info.formats, fn(f) { f.id == format_id })
}

pub fn info_to_json(info: Info) -> Json {
  json.object([
    #("slug", json.string(info.slug)),
    #("name", json.string(info.name)),
    #("tagline", json.string(info.tagline)),
    #("description", json.string(info.description)),
    #("min_players", json.int(info.min_players)),
    #("max_players", json.int(info.max_players)),
    #("formats", json.array(info.formats, format_to_json)),
  ])
}

pub fn format_to_json(format: Format) -> Json {
  json.object([
    #("id", json.string(format.id)),
    #("name", json.string(format.name)),
    #("description", json.string(format.description)),
    #("config", json.dict(format.config, fn(k) { k }, json.int)),
  ])
}

pub fn outcome_to_json(outcome: Outcome) -> Json {
  case outcome {
    Ongoing -> json.object([#("status", json.string("ongoing"))])
    Finished(winners) ->
      json.object([
        #("status", json.string("finished")),
        #("winners", json.array(winners, json.string)),
      ])
  }
}
