//// Poker: actions in, events out, and what each player may do now.

import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gamekit/game
import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import poker/card.{type Card}
import poker/state.{type GameState, type Happening}

pub type Action {
  Fold
  Check
  Call
  /// Total for this street.
  Bet(Int)
  /// Total for this street.
  Raise(Int)
  AllIn
  Deal
  Resign
}

pub const board_zone = "board"

pub const deck_zone = "deck"

pub fn hole_zone(id: String) -> String {
  "hole:" <> id
}

fn custom(kind: String, fields: List(#(String, Json))) -> Event {
  event.Custom(kind, json.object(fields))
}

pub fn apply(
  state: GameState,
  id: String,
  action: Action,
) -> Result(#(GameState, List(Event)), String) {
  let result = case action {
    Fold -> state.act(state, id, state.Fold)
    Check -> state.act(state, id, state.Check)
    Call -> state.act(state, id, state.Call)
    Bet(to) -> state.act(state, id, state.Bet(to))
    Raise(to) -> state.act(state, id, state.Raise(to))
    AllIn -> state.act(state, id, state.AllIn)
    Deal -> state.next_hand(state, id)
    Resign -> state.leave(state, id)
  }
  use #(next, happenings) <- result.try(result)
  Ok(#(next, list.flat_map(happenings, fn(h) { events(next, h) })))
}

fn events(after: GameState, happening: Happening) -> List(Event) {
  let name = fn(id) { state.name_of(after, id) }
  case happening {
    state.Dealt(number, button) -> {
      let #(small, big) = state.blinds(after)
      let deals = case after.hand {
        Some(hand) ->
          list.flat_map(after.order, fn(id) {
            dict.get(hand.hole, id)
            |> result.unwrap([])
            |> list.map(fn(c) { event.moved(c.id, deck_zone, hole_zone(id)) })
          })
        None -> []
      }
      list.flatten([
        [
          event.PhaseChanged("preflop"),
          custom("hand_started", [
            #("number", json.int(number)),
            #("button", json.string(button)),
            #("small_blind", json.int(small)),
            #("big_blind", json.int(big)),
            #("level", json.int(after.level + 1)),
          ]),
          event.Message("Hand " <> int.to_string(number)),
        ],
        deals,
      ])
    }
    state.ToppedUp(id, amount) -> [
      custom("topped_up", [
        #("player_id", json.string(id)),
        #("amount", json.int(amount)),
      ]),
      event.Message(name(id) <> " tops up " <> int.to_string(amount)),
    ]
    state.LevelUp(level, small, big) -> [
      custom("level_up", [
        #("level", json.int(level + 1)),
        #("small_blind", json.int(small)),
        #("big_blind", json.int(big)),
      ]),
      event.Message(
        "Blinds go up to " <> int.to_string(small) <> "/" <> int.to_string(big),
      ),
    ]
    state.BlindPosted(id, amount, big) -> [
      custom("blind", [
        #("player_id", json.string(id)),
        #("amount", json.int(amount)),
        #("big", json.bool(big)),
      ]),
      event.Message(
        name(id)
        <> " posts the "
        <> case big {
          True -> "big"
          False -> "small"
        }
        <> " blind "
        <> int.to_string(amount),
      ),
    ]
    state.Acted(id, kind, amount) -> [
      custom("action", [
        #("player_id", json.string(id)),
        #("kind", json.string(kind)),
        #("amount", json.int(amount)),
      ]),
      event.Message(case kind {
        "check" -> name(id) <> " checks"
        "call" -> name(id) <> " calls " <> int.to_string(amount)
        "bet" -> name(id) <> " bets " <> int.to_string(amount)
        "raise" -> name(id) <> " raises to " <> int.to_string(amount)
        "all_in" -> name(id) <> " is all in for " <> int.to_string(amount)
        _ -> name(id) <> " folds"
      }),
    ]
    state.StreetDealt(street, cards) -> {
      let street_name = state.street_name(street)
      list.flatten([
        [event.PhaseChanged(street_name)],
        list.map(cards, fn(c) { event.moved(c.id, deck_zone, board_zone) }),
        [
          custom("street", [
            #("street", json.string(street_name)),
            #("cards", json.array(cards, card.to_json)),
          ]),
          event.Message(
            string.capitalise(street_name)
            <> ": "
            <> string.join(list.map(cards, card.code), " "),
          ),
        ],
      ])
    }
    state.Showdown(reveals) ->
      list.flatten([
        list.flat_map(reveals, fn(r) {
          list.map(r.1, fn(c) { event.Revealed(c.id, hole_zone(r.0)) })
        }),
        [
          custom("showdown", [
            #(
              "reveals",
              json.array(reveals, fn(r) {
                json.object([
                  #("player_id", json.string(r.0)),
                  #("cards", json.array(r.1, card.to_json)),
                  #("description", json.string(r.2)),
                ])
              }),
            ),
          ]),
        ],
        list.map(reveals, fn(r) {
          event.Message(
            name(r.0)
            <> " shows "
            <> string.join(list.map(r.1, card.code), " ")
            <> ": "
            <> r.2,
          )
        }),
      ])
    state.HandEnded(result) -> {
      let won = case result.won {
        state.ByFold -> "fold"
        state.ByShowdown -> "showdown"
        state.Split -> "split"
      }
      let message = case result.won, result.winners {
        state.Split, _ -> "Split pot"
        _, [#(winner, amount), ..] ->
          name(winner) <> " wins " <> int.to_string(amount)
        _, [] -> "Hand over"
      }
      [
        custom("hand_over", [
          #("number", json.int(result.number)),
          #(
            "winners",
            json.array(result.winners, fn(w) {
              json.object([
                #("player_id", json.string(w.0)),
                #("amount", json.int(w.1)),
              ])
            }),
          ),
          #("won", json.string(won)),
          #(
            "descriptions",
            json.object(
              dict.to_list(result.descriptions)
              |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
              |> list.map(fn(d) { #(d.0, json.string(d.1)) }),
            ),
          ),
        ]),
        event.PhaseChanged("hand_over"),
        event.Message(message),
      ]
    }
    state.Left(id) -> [event.Message(name(id) <> " left the table")]
    state.GameOver(winner) -> [
      event.PhaseChanged("game_over"),
      event.Message(case winner {
        Some(id) -> name(id) <> " wins"
        None -> "Session over: all square"
      }),
    ]
  }
}

// ---------- Legal actions ----------

pub fn legal(state: GameState, id: String) -> List(Schema) {
  case state.is_player(state, id) {
    False -> []
    True ->
      case state.phase {
        state.Finished(_) -> []
        state.HandOver -> [action.simple("deal", "Next hand"), leave(state)]
        state.Betting ->
          case state.to_act(state) == Some(id) {
            True -> list.append(betting_options(state, id), [leave(state)])
            False -> [leave(state)]
          }
      }
  }
}

fn leave(state: GameState) -> Schema {
  case state.config.format {
    state.Cash -> action.simple("resign", "Leave the table")
    state.SitAndGo -> action.simple("resign", "Resign")
  }
}

fn betting_options(state: GameState, id: String) -> List(Schema) {
  let call = state.to_call(state, id)
  let my_stack = state.stack(state, id)
  let assert Some(hand) = state.hand
  let check_or_call = case call {
    0 -> [action.simple("check", "Check")]
    n -> [
      action.simple("call", case n == my_stack {
        True -> "Call " <> int.to_string(n) <> " (all in)"
        False -> "Call " <> int.to_string(n)
      }),
    ]
  }
  let fold = case call {
    0 -> []
    _ -> [action.simple("fold", "Fold")]
  }
  let sizing = case state.raise_bounds(state, id) {
    Ok(#(min, max)) ->
      case state.current_bet(hand) {
        0 -> [
          action.Schema("bet", "Bet", [action.number("amount", min, max)]),
        ]
        _ -> [
          action.Schema("raise", "Raise to", [action.number("amount", min, max)]),
        ]
      }
    Error(_) -> []
  }
  let all_in = case sizing, call == my_stack && my_stack > 0 {
    [_], _ -> [
      action.simple(
        "all_in",
        "All in (" <> int.to_string(state.bet_of(hand, id) + my_stack) <> ")",
      ),
    ]
    _, _ -> []
  }
  list.flatten([fold, check_or_call, sizing, all_in])
}

// ---------- Clocks ----------

/// The player to act is on the clock; between hands, whoever deals next.
pub fn on_the_clock(state: GameState) -> List(String) {
  case state.phase {
    state.Betting ->
      case state.to_act(state) {
        Some(id) -> [id]
        None -> []
      }
    state.HandOver -> [state.next_button]
    state.Finished(_) -> []
  }
}

/// Out of time: deal, check when free, otherwise fold. Play goes on.
pub fn timeout(state: GameState, id: String) -> game.Timeout(Action) {
  case state.phase {
    state.HandOver -> game.Act(Deal)
    state.Betting ->
      case state.to_act(state) == Some(id) {
        True ->
          case state.to_call(state, id) {
            0 -> game.Act(Check)
            _ -> game.Act(Fold)
          }
        False -> game.Forfeit
      }
    state.Finished(_) -> game.Forfeit
  }
}

/// Hole cards a viewer may see face up: their own, and any shown.
pub fn visible_hole(
  state: GameState,
  viewer: option.Option(String),
  owner: String,
) -> option.Option(List(Card)) {
  case state.hand {
    Some(hand) ->
      case viewer == Some(owner) || list.contains(hand.revealed, owner) {
        True -> Some(state.hole_cards(state, owner))
        False -> None
      }
    None -> None
  }
}
