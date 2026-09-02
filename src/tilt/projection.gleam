//// Project Tilt state into the generic Scene protocol for one viewer.

import gamekit/scene.{type Scene, type Token, type Viewer, type Zone}
import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import tilt/codec
import tilt/engine
import tilt/player.{type Player}
import tilt/poker/card.{type Card}
import tilt/shop/state as shop_state
import tilt/state.{type GameState}

pub const slug = "tilt"

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  let viewer_id = scene.viewer_id(viewer)
  let players = state.players_in_order(state)
  scene.Scene(
    game: slug,
    phase: phase_name(state.phase),
    viewer: viewer,
    players: list.map(players, fn(p) { player_info(state, p) }),
    zones: list.flatten([
      list.flat_map(players, fn(p) {
        player_zones(
          p,
          viewer_id == Some(p.player_id),
          state.all_locked_in(state),
        )
      }),
      shop_zones(state),
    ]),
    data: scene_data(state),
  )
}

pub fn phase_name(phase: state.Phase) -> String {
  case phase {
    state.Playing -> "playing"
    state.Shopping -> "shop"
    state.Finished -> "game_over"
  }
}

// ---------- Players ----------

fn player_info(state: GameState, p: Player) -> scene.PlayerInfo {
  // Sorted: a dict keyed by a custom type iterates in atom-table order,
  // which differs between VMs, and scene JSON must be reproducible.
  let skill_tree =
    p.skill_tree
    |> dict.to_list
    |> list.map(fn(entry) {
      #(codec.hand_type_to_string(entry.0), json.int(entry.1))
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> json.object
  scene.player(p.player_id, state.name_of(state, p.player_id))
  |> scene.counter("lives", p.lives)
  |> scene.counter("score", p.current_round_score)
  |> scene.counter("hands_remaining", p.hands_remaining)
  |> scene.counter("discards_remaining", p.discards_remaining)
  |> scene.counter("deck_count", list.length(p.card_piles.deck))
  |> scene.counter("discard_count", list.length(p.card_piles.discard))
  |> scene.counter("hand_count", list.length(p.card_piles.hand))
  |> scene.flag("locked_in", player.has_locked_in(p))
  |> scene.flag("scrambled", p.scrambled)
  |> scene.flag("enhancements_disabled", p.enhancements_disabled)
  |> scene.flag("supply_chain_limited", p.supply_chain_limited)
  |> scene.flag("eliminated", p.status == player.Eliminated)
  |> scene.player_data("skill_tree", skill_tree)
  |> scene.player_data(
    "disabled_ranks",
    codec.int_list(list.map(p.disabled_ranks, card.rank_value)),
  )
  |> scene.player_data(
    "disabled_suits",
    codec.strings(list.map(p.disabled_suits, codec.suit_to_string)),
  )
  |> scene.player_data(
    "active_debuffs",
    codec.strings(list.map(p.active_debuffs, codec.hand_type_to_string)),
  )
  |> scene.player_data(
    "face_down_card_ids",
    codec.strings(p.face_down_card_ids),
  )
}

// ---------- Zones ----------

fn card_token(c: Card) -> Token {
  scene.token(c.id, "card")
  |> scene.with_props(list.filter(codec.card_fields(c), fn(f) { f.0 != "id" }))
}

fn player_zones(p: Player, is_viewer: Bool, revealed: Bool) -> List(Zone) {
  let id = p.player_id
  // Hands are open in Tilt. A scrambled card is face down to everyone,
  // holder included: the token keeps its (opaque) id so it can be played,
  // but carries no face.
  let hand =
    scene.owned_zone(
      engine.hand_zone(id),
      id,
      scene.Fan,
      list.map(p.card_piles.hand, fn(c) { masked(p, c) }),
    )
  // A locked-in hand stays secret until both players have locked in
  let locked = option.unwrap(p.locked_in_hand, [])
  let played = case is_viewer || revealed {
    True ->
      scene.owned_zone(
        engine.played_zone(id),
        id,
        scene.Row,
        list.map(locked, card_token),
      )
    False ->
      scene.hidden_zone(
        engine.played_zone(id),
        Some(id),
        scene.Row,
        list.length(locked),
      )
  }
  // The holder may know what is left in their draw pile, never in which
  // order: it is sent sorted by face. Others only get the count.
  let #(deck, discard) = case is_viewer {
    True -> #(
      scene.owned_zone(
        engine.deck_zone(id),
        id,
        scene.Stack,
        p.card_piles.deck |> list.sort(by_face) |> list.map(card_token),
      ),
      scene.owned_zone(
        engine.discard_zone(id),
        id,
        scene.Stack,
        list.map(p.card_piles.discard, card_token),
      ),
    )
    False -> #(
      scene.hidden_zone(
        engine.deck_zone(id),
        Some(id),
        scene.Stack,
        list.length(p.card_piles.deck),
      ),
      scene.hidden_zone(
        engine.discard_zone(id),
        Some(id),
        scene.Stack,
        list.length(p.card_piles.discard),
      ),
    )
  }
  [hand, played, deck, discard]
}

fn masked(p: Player, c: Card) -> Token {
  case list.contains(p.face_down_card_ids, c.id) {
    True -> scene.hidden(card_token(c))
    False -> card_token(c)
  }
}

fn by_face(a: Card, b: Card) -> order.Order {
  case int.compare(card.rank_value(a.rank), card.rank_value(b.rank)) {
    order.Eq ->
      string.compare(codec.suit_to_string(a.suit), codec.suit_to_string(b.suit))
    other -> other
  }
}

fn shop_zones(state: GameState) -> List(Zone) {
  case state.shop_state {
    None -> []
    Some(shop) -> {
      let shop_tokens =
        list.map(shop.available_cards, fn(c) {
          scene.token(c.id, "shop_card")
          |> scene.with_props(codec.shop_card_fields(c))
          |> scene.with_props([
            #("picked", json.bool(list.contains(shop.picked_card_ids, c.id))),
            #(
              "destroyed",
              json.bool(list.contains(shop.destroyed_card_ids, c.id)),
            ),
          ])
        })
      let selection = case shop.pending_deck_builder, shop.pending_plus_bomb {
        Some(pending), _ -> [
          scene.owned_zone(
            engine.selection_zone,
            pending.player_id,
            scene.Row,
            list.map(pending.available_cards, card_token),
          ),
        ]
        _, Some(pending) -> [
          scene.owned_zone(
            engine.selection_zone,
            pending.player_id,
            scene.Row,
            list.map(pending.available_cards, card_token),
          ),
        ]
        None, None -> []
      }
      [scene.zone(engine.shop_zone, scene.Row, shop_tokens), ..selection]
    }
  }
}

// ---------- Data ----------

fn scene_data(state: GameState) -> List(#(String, Json)) {
  [
    #("round_number", json.int(state.round_number)),
    #(
      "config",
      json.object([
        #("initial_lives", json.int(state.config.initial_lives)),
        #("hands_per_round", json.int(state.config.hands_per_round)),
        #("discards_per_round", json.int(state.config.discards_per_round)),
        #("shop_rounds", json.int(state.config.shop_rounds)),
      ]),
    ),
    #("winner_id", json.nullable(state.winner_id, json.string)),
    #(
      "last_round_winner_id",
      json.nullable(state.last_round_winner_id, json.string),
    ),
    #(
      "history",
      json.array(list.reverse(state.round_hand_history), fn(hand_results) {
        json.array(hand_results, fn(r) {
          json.object([
            #("player_id", json.string(r.player_id)),
            #(
              "hand_type",
              json.string(codec.hand_type_to_string(r.score.hand_type)),
            ),
            #("score", json.int(r.score.total_score)),
          ])
        })
      }),
    ),
    #("shop", case state.shop_state {
      Some(shop) -> shop_json(shop)
      None -> json.null()
    }),
  ]
}

fn shop_json(shop: shop_state.ShopState) -> Json {
  json.object([
    #("total_rounds", json.int(shop.total_rounds)),
    #("current_round", json.int(shop.current_round)),
    #("first_picker_id", json.string(shop.first_picker_id)),
    #("second_picker_id", json.string(shop.second_picker_id)),
    #("first_pick_made", json.bool(shop.first_pick_made)),
    #("second_pick_made", json.bool(shop.second_pick_made)),
    #("picked_card_ids", codec.strings(shop.picked_card_ids)),
    #("destroyed_card_ids", codec.strings(shop.destroyed_card_ids)),
    #("destroy_phase_complete", json.bool(shop.destroy_phase_complete)),
    #("destroyer_id", json.nullable(shop.destroyer_id, json.string)),
    #("destroys_allowed", json.int(shop.destroys_allowed)),
    #("pending_deck_builder", case shop.pending_deck_builder {
      Some(pending) ->
        json.object([
          #("player_id", json.string(pending.player_id)),
          #("shop_card_id", json.string(pending.shop_card_id)),
          #("card", codec.shop_card_to_json(pending.deck_builder_card)),
          #("available_cards", codec.cards_to_json(pending.available_cards)),
        ])
      None -> json.null()
    }),
    #("pending_plus_bomb", case shop.pending_plus_bomb {
      Some(pending) ->
        json.object([
          #("player_id", json.string(pending.player_id)),
          #("shop_card_id", json.string(pending.shop_card_id)),
          #("available_cards", codec.cards_to_json(pending.available_cards)),
        ])
      None -> json.null()
    }),
  ])
}
