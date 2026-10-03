//// The game contract.
////
//// A game is a record of pure functions over its own state type. The host
//// (Elixir), the generic client, the bots, and the conformance tests only ever
//// talk to a game through this record, so adding a game never touches them.

import gamekit/action.{type Schema}
import gamekit/clock.{type Control}
import gamekit/event.{type Event}
import gamekit/rng.{type Rng}
import gamekit/scene.{type PlayerId, type Scene, type Viewer}
import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result

/// A format's configuration. Kept to integers so it is trivially JSON and
/// every game can read what it needs with a default.
pub type Config =
  Dict(String, Int)

/// A named preset offered in the lobby.
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
    /// Ids of the time controls this game offers, in display order: fixed
    /// presets (`gamekit/clock.presets`) and this game's own `tiers`. The
    /// default is always offered.
    clocks: List(String),
    default_clock: String,
    /// Time controls this game sizes to the format being played: a player
    /// picks a feel and the game does the arithmetic (`clock_for`). Their
    /// ids share one namespace with the fixed presets and never reuse one.
    tiers: List(Tier),
    /// A simple delay this game grants on every turn under every control it
    /// offers: the first `turn_delay_ms` of a turn are free, and unused
    /// delay is never banked. Zero leaves the controls exactly as they are.
    turn_delay_ms: Int,
  )
}

/// A time control a game sizes to the format being played: what a player
/// picks is a feel ("Standard"), and `size` turns a format's config into
/// the control and the words for it. Called when an instance starts, never
/// after, so a game's banks are fixed by its format and its clock id.
pub type Tier {
  Tier(
    id: String,
    name: String,
    description: String,
    size: fn(Config) -> Sizing,
  )
}

/// A tier sized for one format.
pub type Sizing {
  Sizing(
    control: Control,
    /// The bank in a few words: "14 min each", "5 min each per game".
    each: String,
    /// The bank and what it covers: "14 min each for this 7-point match".
    line: String,
  )
}

/// A clock id resolved for one format: a tier sized to it, or a fixed
/// preset, which is the same whatever the format.
pub type Clock {
  Clock(
    id: String,
    name: String,
    control: Control,
    each: String,
    line: String,
    /// One of the game's tiers, which a sentence names with what it is
    /// worth ("Standard · 14 min each"); a preset's name already says it.
    tier: Bool,
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

/// What happens when a player's clock runs out: the game is forfeit, or an
/// action is taken for the player and play goes on.
pub type Timeout(action) {
  Forfeit
  Act(action)
}

/// The analysis engine as a closure: a route under the engine's base URL and
/// a JSON request body in, the JSON response body out, or a sentence saying
/// why nothing came back. A game's `bot` is handed one so the brain stays
/// pure -- deciding what to ask and what the answer means -- while the
/// platform owns the socket, the timeout and the retries.
pub type Ask =
  fn(String, String) -> Result(String, String)

/// What kind of moment a bot's action is, for somebody watching it played.
/// The game names the moment; the platform owns the milliseconds (in Oskol,
/// `config :oskol, :bot`), so an operator can slow every bot down without a
/// game knowing, and a game never has to know how long its animations run.
pub type Pace {
  /// One step of a sequence -- a piece moved, a turn committed -- that
  /// follows the bot's previous action after the platform's usual gap.
  Step
  /// A decision the watcher should see coming rather than find already
  /// made (a double, a take): held a beat after the change that prompted
  /// it.
  Beat
  /// Sets something in motion the watcher has to see finish before anything
  /// else happens (dice in the air): the bot's next action waits for it to
  /// settle.
  Settle
}

/// One action a bot decided on: the same `{"name", "params"}` object a
/// browser sends, and the moment it is.
pub type BotAction {
  BotAction(action: Json, pace: Pace)
}

/// The pace's name on the wire to the platform.
pub fn pace_name(pace: Pace) -> String {
  case pace {
    Step -> "step"
    Beat -> "beat"
    Settle -> "settle"
  }
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
    /// Which period of play this state is in, as a number that only goes
    /// up. A control that refills per period (`clock.PerPeriod`) gives every
    /// player a full bank on the step that moves it on, and no other control
    /// looks at it. Backgammon's is the game number, so unlimited play
    /// refills when each new game begins. `one_period` for a game that is
    /// one period throughout.
    period: fn(state) -> Int,
    /// The game's whole record as public JSON, for replay and analysis
    /// (served on request, never in every update): `None` for a game that
    /// keeps none (`no_record`). It must hold only what every seat may see.
    record: fn(state) -> Option(Json),
    /// What this step committed, as public JSON: a unit of play the
    /// platform may start working on before the game is over. `None` for a
    /// step that committed nothing, and for a game that has no such unit
    /// (`no_committed`).
    ///
    /// Read from the state before the action, the action, and the state
    /// after, because a commit is a transition and not a state: backgammon's
    /// is a played turn, which the board the turn began on and the board it
    /// left both describe. Like `record` it must hold only what every seat
    /// has already seen -- it travels off the room, and nothing a player
    /// could not see may leave with it.
    committed: fn(state, action, state) -> Option(Json),
    /// What a bot seat does now: the actions to take, in order, as the same
    /// `{"name", "params"}` objects a browser sends, each with the moment it
    /// is for a watcher (`Pace`). Called only for a seat whose turn it is,
    /// off the room, with the engine as a closure.
    ///
    /// `attempts` is how many asks have already come back empty for this
    /// decision, so a game can give up in its own words rather than leave a
    /// board that never moves -- the platform never learns what giving up
    /// is called here. An empty list means there is nothing to do.
    bot: fn(state, PlayerId, Ask, Int) -> Result(List(BotAction), String),
  )
}

/// For a game with no bot: a seat nobody drives.
pub fn no_bot(
  _state: state,
  _player_id: PlayerId,
  _ask: Ask,
  _attempts: Int,
) -> Result(List(BotAction), String) {
  Ok([])
}

/// For a game that is one period of play throughout.
pub fn one_period(_state: state) -> Int {
  0
}

/// For a game that keeps no record beyond its scene.
pub fn no_record(_state: state) -> Option(Json) {
  None
}

/// For a game with no unit of play worth working on before it ends.
pub fn no_committed(
  _before: state,
  _action: action,
  _after: state,
) -> Option(Json) {
  None
}

pub fn format(
  id: String,
  name: String,
  description: String,
  config: Config,
) -> Format {
  Format(id: id, name: name, description: description, config: config)
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

/// The config a format starts with.
pub fn default_config(format: Format) -> Config {
  format.config
}

/// What a clock id means for one format of this game: one of its tiers
/// sized to the format, else a fixed preset. Error for an id that is
/// neither, and for a tier asked about a format the game does not have.
pub fn clock_for(
  info: Info,
  format_id: String,
  clock_id: String,
) -> Result(Clock, Nil) {
  case list.find(info.tiers, fn(t) { t.id == clock_id }) {
    Ok(tier) -> {
      use format <- result.try(find_format(info, format_id))
      let sized = tier.size(format.config)
      Ok(Clock(
        id: tier.id,
        name: tier.name,
        control: sized.control,
        each: sized.each,
        line: sized.line,
        tier: True,
      ))
    }
    Error(_) -> {
      use preset <- result.try(clock.preset(clock_id))
      Ok(Clock(
        id: preset.id,
        name: preset.name,
        control: preset.control,
        each: case preset.control {
          clock.NoClock -> ""
          _ -> preset.name <> " each"
        },
        line: preset.description,
        tier: False,
      ))
    }
  }
}

/// A tier as the clock picker reads it: its name, and for every format of
/// the game the line it sizes to (`"lines": {"match7": "14 min each for
/// this 7-point match"}`) and the same in a few words (`"each": {"match7":
/// "14 min each"}`), so the client can say what a choice means for the
/// format chosen without doing the arithmetic itself.
pub fn tier_to_json(info: Info, tier: Tier) -> Json {
  json.object([
    #("id", json.string(tier.id)),
    #("name", json.string(tier.name)),
    #("description", json.string(tier.description)),
    #(
      "lines",
      json.object(
        list.map(info.formats, fn(format) {
          #(format.id, json.string(tier.size(format.config).line))
        }),
      ),
    ),
    #(
      "each",
      json.object(
        list.map(info.formats, fn(format) {
          #(format.id, json.string(tier.size(format.config).each))
        }),
      ),
    ),
  ])
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
    #("turn_delay_ms", json.int(info.turn_delay_ms)),
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
