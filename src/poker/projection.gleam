//// Poker: the scene each viewer sees. Hole cards are the only secret:
//// yours are face up, the opponent's are a count until a showdown.

import gamekit/scene.{type Scene, type Viewer, type Zone}
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import poker/card.{type Card}
import poker/engine
import poker/state.{type GameState}

pub const slug = "poker"

pub fn build(state: GameState, viewer: Viewer) -> Scene {
  let viewer_id = scene.viewer_id(viewer)
  scene.Scene(
    game: slug,
    phase: phase_name(state),
    viewer: viewer,
    players: list.map(state.order, fn(id) { player_info(state, id) }),
    zones: list.flatten([
      [board_zone(state), deck_zone(state)],
      list.map(state.order, fn(id) { hole_zone(state, viewer_id, id) }),
    ]),
    data: scene_data(state, viewer_id),
  )
}

pub fn phase_name(state: GameState) -> String {
  case state.phase, state.hand {
    state.Finished(_), _ -> "game_over"
    state.HandOver, _ -> "hand_over"
    state.Betting, Some(hand) -> state.street_name(hand.street)
    state.Betting, None -> "betting"
  }
}

fn player_info(state: GameState, id: String) -> scene.PlayerInfo {
  let hand = state.hand
  let in_hand = fn(f: fn(state.Hand) -> Bool) {
    case hand {
      Some(h) -> f(h)
      None -> False
    }
  }
  scene.player(id, state.name_of(state, id))
  |> scene.counter("stack", state.stack(state, id))
  |> scene.counter("bet", case hand {
    Some(h) -> state.bet_of(h, id)
    None -> 0
  })
  |> scene.counter("committed", case hand {
    Some(h) -> state.committed_of(h, id)
    None -> 0
  })
  |> scene.counter("net", state.net(state, id))
  |> scene.flag("button", in_hand(fn(h) { h.button == id }))
  |> scene.flag("to_act", state.to_act(state) == Some(id))
  |> scene.flag("folded", in_hand(fn(h) { h.folded == Some(id) }))
  |> scene.flag(
    "all_in",
    state.phase == state.Betting
      && state.stack(state, id) == 0
      && in_hand(fn(h) { h.folded == None }),
  )
  |> scene.flag("revealed", in_hand(fn(h) { list.contains(h.revealed, id) }))
}

fn card_token(c: Card) -> scene.Token {
  scene.token(c.id, "card") |> scene.with_props(card.props(c))
}

fn board_zone(state: GameState) -> Zone {
  let cards = case state.hand {
    Some(h) -> h.board
    None -> []
  }
  scene.zone(engine.board_zone, scene.Row, list.map(cards, card_token))
}

fn deck_zone(state: GameState) -> Zone {
  let count = case state.hand {
    Some(h) -> list.length(h.deck)
    None -> 0
  }
  scene.hidden_zone(engine.deck_zone, None, scene.Stack, count)
}

fn hole_zone(state: GameState, viewer_id: Option(String), owner: String) -> Zone {
  let id = engine.hole_zone(owner)
  case engine.visible_hole(state, viewer_id, owner) {
    Some(cards) ->
      scene.owned_zone(id, owner, scene.Fan, list.map(cards, card_token))
    None ->
      scene.hidden_zone(
        id,
        Some(owner),
        scene.Fan,
        list.length(state.hole_cards(state, owner)),
      )
  }
}

fn scene_data(
  state: GameState,
  viewer_id: Option(String),
) -> List(#(String, json.Json)) {
  let #(small, big) = state.blinds(state)
  let viewer_numbers = case viewer_id {
    Some(id) ->
      case state.is_player(state, id) {
        True -> {
          let #(min, max) = case state.raise_bounds(state, id) {
            Ok(#(min, max)) -> #(json.int(min), json.int(max))
            Error(_) -> #(json.null(), json.null())
          }
          [
            #("to_call", json.int(state.to_call(state, id))),
            #("min_raise", min),
            #("max_raise", max),
            #("can_check", json.bool(state.can_check(state, id))),
          ]
        }
        False -> []
      }
    None -> []
  }
  let hands_until_level_up = case
    state.config.format,
    state.config.hands_per_level
  {
    state.SitAndGo, per if per > 0 -> {
      let last_level = list.length(state.config.levels) - 1
      case state.level >= last_level {
        True -> json.null()
        False -> json.int(per - state.hands_played % per)
      }
    }
    _, _ -> json.null()
  }
  list.flatten([
    [
      #(
        "format",
        json.string(case state.config.format {
          state.Cash -> "cash"
          state.SitAndGo -> "sng"
        }),
      ),
      #(
        "phase",
        json.string(case state.phase {
          state.Betting -> "betting"
          state.HandOver -> "hand_over"
          state.Finished(_) -> "game_over"
        }),
      ),
      #("street", case state.hand {
        Some(h) -> json.string(state.street_name(h.street))
        None -> json.null()
      }),
      #(
        "hand_number",
        json.int(case state.hand {
          Some(h) -> h.number
          None -> 0
        }),
      ),
      #("hands_played", json.int(state.hands_played)),
      #(
        "pot",
        json.int(case state.hand {
          Some(h) -> state.pot(h)
          None -> 0
        }),
      ),
      #("small_blind", json.int(small)),
      #("big_blind", json.int(big)),
      #("level", json.int(state.level + 1)),
      #("hands_until_level_up", hands_until_level_up),
      #("buy_in", json.int(state.config.buy_in)),
      #("top_up", json.bool(state.config.top_up)),
      #("to_act", json.nullable(state.to_act(state), json.string)),
      #("button", case state.hand {
        Some(h) -> json.string(h.button)
        None -> json.string(state.next_button)
      }),
      #("next_button", json.string(state.next_button)),
      #("last_result", case state.last_result {
        Some(r) -> result_json(r)
        None -> json.null()
      }),
      #("winner_id", case state.phase {
        state.Finished(Some(id)) -> json.string(id)
        _ -> json.null()
      }),
    ],
    viewer_numbers,
  ])
}

fn result_json(r: state.HandResult) -> json.Json {
  json.object([
    #("number", json.int(r.number)),
    #(
      "winners",
      json.array(r.winners, fn(w) {
        json.object([
          #("player_id", json.string(w.0)),
          #("amount", json.int(w.1)),
        ])
      }),
    ),
    #(
      "won",
      json.string(case r.won {
        state.ByFold -> "fold"
        state.ByShowdown -> "showdown"
        state.Split -> "split"
      }),
    ),
    #(
      "descriptions",
      json.object(
        dict.to_list(r.descriptions)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(d) { #(d.0, json.string(d.1)) }),
      ),
    ),
  ])
}

/// Chips as text for messages: "1,500".
pub fn chips(n: Int) -> String {
  int.to_string(n)
}
