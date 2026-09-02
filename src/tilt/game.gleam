//// Tilt: a two-player poker roguelike. This module is the game's entry in the
//// gamekit contract; everything the platform needs lives behind it.

import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tilt/engine.{type Action}
import tilt/projection
import tilt/state.{type GameState}

pub fn game() -> Game(GameState, Action) {
  game.Game(
    info: info(),
    init: init,
    decode_action: decode_action,
    apply: engine.apply,
    legal: engine.legal,
    scene: projection.build,
    outcome: outcome,
  )
}

pub fn info() -> game.Info {
  game.Info(
    slug: projection.slug,
    name: "Tilt",
    tagline: "Head-to-head poker roguelike",
    description: "Build poker hands, upgrade them in the shop, sabotage your opponent, and take their last life.",
    min_players: 2,
    max_players: 2,
    formats: [
      format("short", "Short", "2 lives, 1 shop pick", 2, 4, 3, 1),
      format("standard", "Standard", "3 lives, 2 shop picks", 3, 4, 3, 2),
      format("extended", "Extended", "5 lives, 2 shop picks", 5, 4, 3, 2),
    ],
  )
}

fn format(
  id: String,
  name: String,
  description: String,
  lives: Int,
  hands: Int,
  discards: Int,
  shop_rounds: Int,
) -> game.Format {
  game.Format(
    id: id,
    name: name,
    description: description,
    config: dict.from_list([
      #("lives", lives),
      #("hands_per_round", hands),
      #("discards_per_round", discards),
      #("shop_rounds", shop_rounds),
    ]),
  )
}

pub fn config_from(config: game.Config) -> state.Config {
  state.Config(
    initial_lives: game.config_get(config, "lives", 3),
    hands_per_round: game.config_get(config, "hands_per_round", 4),
    discards_per_round: game.config_get(config, "discards_per_round", 3),
    shop_rounds: game.config_get(config, "shop_rounds", 2),
  )
}

pub fn init(
  config: game.Config,
  seats: List(game.Seat),
  rng: Rng,
) -> Result(GameState, String) {
  case list.length(seats) {
    2 ->
      Ok(state.new(
        config_from(config),
        list.map(seats, fn(s) { #(s.id, s.name) }),
        rng,
      ))
    _ -> Error("Tilt needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  let params = incoming.params
  case incoming.name {
    "play_hand" ->
      action.ids_param(params, "cards") |> result.map(engine.PlayHand)
    "discard" -> action.ids_param(params, "cards") |> result.map(engine.Discard)
    "shop_pick" -> single(params, "card") |> result.map(engine.ShopPick)
    "shop_select" ->
      Ok(engine.ShopSelect(action.optional_ids_param(params, "cards")))
    "shop_destroy" -> single(params, "card") |> result.map(engine.ShopDestroy)
    "shop_finish_destroy" -> Ok(engine.ShopFinishDestroy)
    other -> Error("Unknown action: " <> other)
  }
}

/// A one-token selection: accepts either `"card": "id"` or `"card": ["id"]`,
/// since Select params are arrays on the wire.
fn single(params, name: String) -> Result(String, String) {
  case action.string_param(params, name) {
    Ok(id) -> Ok(id)
    Error(_) ->
      case action.ids_param(params, name) {
        Ok([id]) -> Ok(id)
        Ok(_) -> Error("Select exactly one " <> name)
        Error(e) -> Error(e)
      }
  }
}

pub fn outcome(state: GameState) -> game.Outcome {
  case state.phase {
    state.Finished ->
      case state.winner_id {
        Some(w) -> game.Finished([w])
        None -> game.Finished([])
      }
    _ -> game.Ongoing
  }
}
