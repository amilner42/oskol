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
import gleam/result

/// Lobby-chosen settings. Kept to integers so it is trivially JSON and every
/// game can read what it needs with a default.
pub type Config =
  Dict(String, Int)

/// One value a setting can take. Picking it merges `config` into the
/// format's config.
pub type Choice {
  Choice(id: String, name: String, config: Config)
}

/// A setting the game's creator picks within a format: a stake, a speed, a
/// twist. Every setting has a default so a format always starts.
pub type Setting {
  Setting(id: String, name: String, choices: List(Choice), default: String)
}

/// A named preset of settings offered in the lobby, with the settings the
/// creator may still tune.
pub type Format {
  Format(
    id: String,
    name: String,
    description: String,
    config: Config,
    settings: List(Setting),
  )
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
    /// Ids of the time-control presets (see `gamekit/clock`) this game
    /// offers, in display order. The default is always offered.
    clocks: List(String),
    default_clock: String,
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

/// What happens when a player's clock runs out. Most games forfeit; poker
/// checks or folds for the player and the hand goes on.
pub type Timeout(action) {
  Forfeit
  Act(action)
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
    /// Players whose clock should be running right now. Return an empty
    /// list whenever nobody should be charged (a reveal, a pause, game over).
    /// The framework owns the clocks themselves; see `gamekit/clock`.
    clocks: fn(state) -> List(PlayerId),
    /// What to do when this player's clock runs out on their turn.
    timeout: fn(state, PlayerId) -> Timeout(action),
  )
}

/// A format with nothing to tune.
pub fn format(
  id: String,
  name: String,
  description: String,
  config: Config,
) -> Format {
  Format(
    id: id,
    name: name,
    description: description,
    config: config,
    settings: [],
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

/// The config for a format with the creator's selections (setting id to
/// choice id) applied over the defaults. Unknown choices are an error;
/// unknown settings are ignored.
pub fn configure(
  format: Format,
  selections: Dict(String, String),
) -> Result(Config, String) {
  list.try_fold(format.settings, format.config, fn(config, setting) {
    let chosen = case dict.get(selections, setting.id) {
      Ok(id) -> id
      Error(_) -> setting.default
    }
    case list.find(setting.choices, fn(c) { c.id == chosen }) {
      Ok(choice) -> Ok(dict.merge(config, choice.config))
      Error(_) -> Error("Unknown " <> setting.name <> ": " <> chosen)
    }
  })
}

/// The config a format starts with when nothing is tuned.
pub fn default_config(format: Format) -> Config {
  configure(format, dict.new()) |> result.unwrap(format.config)
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
    #("clocks", json.array(info.clocks, json.string)),
    #("default_clock", json.string(info.default_clock)),
  ])
}

pub fn format_to_json(format: Format) -> Json {
  json.object([
    #("id", json.string(format.id)),
    #("name", json.string(format.name)),
    #("description", json.string(format.description)),
    #("config", json.dict(format.config, fn(k) { k }, json.int)),
    #(
      "settings",
      json.array(format.settings, fn(s) {
        json.object([
          #("id", json.string(s.id)),
          #("name", json.string(s.name)),
          #("default", json.string(s.default)),
          #(
            "choices",
            json.array(s.choices, fn(c) {
              json.object([
                #("id", json.string(c.id)),
                #("name", json.string(c.name)),
              ])
            }),
          ),
        ])
      }),
    ),
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
