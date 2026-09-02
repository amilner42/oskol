//// The Scene protocol: the only description of a game the client ever sees.
////
//// A scene is game-agnostic. Every board and card game is tokens in zones,
//// plus per-player counters and flags. A generic client can render any scene;
//// a bespoke client can read the same structure and style it however it likes.
//// The `data` field is a deliberately narrow escape hatch for game-specific
//// details that only a bespoke view understands.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type PlayerId =
  String

/// Who a scene is being rendered for. Hidden information is resolved
/// against the viewer before the scene leaves the server.
pub type Viewer {
  Player(PlayerId)
  Spectator
}

/// How a zone lays its tokens out. The generic renderer uses this; a bespoke
/// view may ignore it.
pub type Layout {
  /// Overlapping cards fanned in a row (a hand).
  Fan
  /// A pile where only the top is meaningful (deck, discard).
  Stack
  /// Tokens in a straight row (a played hand, a shop shelf).
  Row
  /// A rectangular board; tokens carry a position.
  Grid(columns: Int, rows: Int)
  /// Free placement; tokens carry a position.
  Free
}

pub type Face {
  Up
  Down
}

/// A card, piece, tile, or shop item. `id` is stable for the life of the game
/// so the client can animate a token moving between zones.
pub type Token {
  Token(
    id: String,
    kind: String,
    face: Face,
    position: Option(#(Int, Int)),
    props: List(#(String, Json)),
  )
}

pub type Zone {
  Zone(
    id: String,
    owner: Option(PlayerId),
    layout: Layout,
    tokens: List(Token),
    /// For hidden zones the viewer may only learn the count.
    count: Int,
  )
}

pub type PlayerInfo {
  PlayerInfo(
    id: PlayerId,
    name: String,
    counters: Dict(String, Int),
    flags: List(String),
    data: List(#(String, Json)),
  )
}

pub type Scene {
  Scene(
    game: String,
    phase: String,
    viewer: Viewer,
    players: List(PlayerInfo),
    zones: List(Zone),
    data: List(#(String, Json)),
  )
}

// ---------- Constructors ----------

pub fn token(id: String, kind: String) -> Token {
  Token(id: id, kind: kind, face: Up, position: None, props: [])
}

pub fn face_down(token: Token) -> Token {
  Token(..token, face: Down)
}

pub fn at(token: Token, column: Int, row: Int) -> Token {
  Token(..token, position: Some(#(column, row)))
}

pub fn with_props(token: Token, props: List(#(String, Json))) -> Token {
  Token(..token, props: list.append(token.props, props))
}

/// Hide a token's identity from the viewer: face down and no props.
pub fn hidden(token: Token) -> Token {
  Token(..token, face: Down, props: [])
}

pub fn zone(id: String, layout: Layout, tokens: List(Token)) -> Zone {
  Zone(
    id: id,
    owner: None,
    layout: layout,
    tokens: tokens,
    count: list.length(tokens),
  )
}

pub fn owned_zone(
  id: String,
  owner: PlayerId,
  layout: Layout,
  tokens: List(Token),
) -> Zone {
  Zone(..zone(id, layout, tokens), owner: Some(owner))
}

/// A zone whose contents are hidden from the viewer: only the count is sent.
pub fn hidden_zone(
  id: String,
  owner: Option(PlayerId),
  layout: Layout,
  count: Int,
) -> Zone {
  Zone(id: id, owner: owner, layout: layout, tokens: [], count: count)
}

pub fn player(id: PlayerId, name: String) -> PlayerInfo {
  PlayerInfo(id: id, name: name, counters: dict.new(), flags: [], data: [])
}

pub fn counter(info: PlayerInfo, name: String, value: Int) -> PlayerInfo {
  PlayerInfo(..info, counters: dict.insert(info.counters, name, value))
}

pub fn flag(info: PlayerInfo, name: String, on: Bool) -> PlayerInfo {
  case on {
    True -> PlayerInfo(..info, flags: list.append(info.flags, [name]))
    False -> info
  }
}

pub fn player_data(info: PlayerInfo, key: String, value: Json) -> PlayerInfo {
  PlayerInfo(..info, data: list.append(info.data, [#(key, value)]))
}

// ---------- Queries ----------

pub fn find_zone(scene: Scene, id: String) -> Result(Zone, Nil) {
  list.find(scene.zones, fn(z) { z.id == id })
}

pub fn zone_token_ids(scene: Scene, zone_id: String) -> List(String) {
  case find_zone(scene, zone_id) {
    Ok(z) -> list.map(z.tokens, fn(t) { t.id })
    Error(_) -> []
  }
}

pub fn viewer_id(viewer: Viewer) -> Option(PlayerId) {
  case viewer {
    Player(id) -> Some(id)
    Spectator -> None
  }
}

// ---------- JSON ----------

pub fn to_json(scene: Scene) -> Json {
  json.object([
    #("game", json.string(scene.game)),
    #("phase", json.string(scene.phase)),
    #("viewer", viewer_to_json(scene.viewer)),
    #("players", json.array(scene.players, player_to_json)),
    #("zones", json.array(scene.zones, zone_to_json)),
    #("data", json.object(scene.data)),
  ])
}

pub fn viewer_to_json(viewer: Viewer) -> Json {
  case viewer {
    Player(id) -> json.string(id)
    Spectator -> json.null()
  }
}

pub fn player_to_json(info: PlayerInfo) -> Json {
  json.object([
    #("id", json.string(info.id)),
    #("name", json.string(info.name)),
    #("counters", json.dict(info.counters, fn(k) { k }, json.int)),
    #("flags", json.array(info.flags, json.string)),
    #("data", json.object(info.data)),
  ])
}

pub fn zone_to_json(zone: Zone) -> Json {
  json.object([
    #("id", json.string(zone.id)),
    #("owner", json.nullable(zone.owner, json.string)),
    #("layout", layout_to_json(zone.layout)),
    #("tokens", json.array(zone.tokens, token_to_json)),
    #("count", json.int(zone.count)),
  ])
}

pub fn layout_to_json(layout: Layout) -> Json {
  case layout {
    Fan -> json.object([#("type", json.string("fan"))])
    Stack -> json.object([#("type", json.string("stack"))])
    Row -> json.object([#("type", json.string("row"))])
    Grid(columns, rows) ->
      json.object([
        #("type", json.string("grid")),
        #("columns", json.int(columns)),
        #("rows", json.int(rows)),
      ])
    Free -> json.object([#("type", json.string("free"))])
  }
}

pub fn token_to_json(token: Token) -> Json {
  json.object([
    #("id", json.string(token.id)),
    #("kind", json.string(token.kind)),
    #("face", case token.face {
      Up -> json.string("up")
      Down -> json.string("down")
    }),
    #("position", case token.position {
      Some(#(c, r)) -> json.preprocessed_array([json.int(c), json.int(r)])
      None -> json.null()
    }),
    #("props", json.object(token.props)),
  ])
}
