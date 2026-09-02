//// Tilt actions: validation, state transitions, and the events they emit.

import gamekit/action.{type Schema}
import gamekit/event.{type Event}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tilt/codec
import tilt/player.{type Player, type PlayerId}
import tilt/poker/card.{type Card}
import tilt/shop/card as shop_card
import tilt/shop/state.{type ShopState} as shop_state
import tilt/state.{type GameState, type Resolution, GameState, guard}

pub type Action {
  PlayHand(cards: List(String))
  Discard(cards: List(String))
  /// Pick a shop card. Cards that need a follow-up selection open one.
  ShopPick(card: String)
  /// Complete a pending selection (deck builder: 0..max cards, plus bomb: 1).
  ShopSelect(cards: List(String))
  ShopDestroy(card: String)
  ShopFinishDestroy
}

// ---------- Zone ids ----------

pub fn hand_zone(player_id: PlayerId) -> String {
  "hand:" <> player_id
}

pub fn played_zone(player_id: PlayerId) -> String {
  "played:" <> player_id
}

pub fn deck_zone(player_id: PlayerId) -> String {
  "deck:" <> player_id
}

pub fn discard_zone(player_id: PlayerId) -> String {
  "discard:" <> player_id
}

pub const shop_zone = "shop"

pub const selection_zone = "selection"

// ---------- Apply ----------

pub fn apply(
  state: GameState,
  player_id: PlayerId,
  action: Action,
) -> Result(#(GameState, List(Event)), String) {
  case action {
    PlayHand(ids) -> play_hand(state, player_id, ids)
    Discard(ids) -> discard(state, player_id, ids)
    ShopPick(id) -> shop_pick(state, player_id, id)
    ShopSelect(ids) -> shop_select(state, player_id, ids)
    ShopDestroy(id) -> shop_destroy(state, player_id, id)
    ShopFinishDestroy -> shop_finish_destroy(state, player_id)
  }
}

fn custom(kind: String, fields: List(#(String, Json))) -> Event {
  event.Custom(kind, json.object(fields))
}

fn play_hand(
  state: GameState,
  player_id: PlayerId,
  ids: List(String),
) -> Result(#(GameState, List(Event)), String) {
  use #(next, resolution) <- result.try(state.lock_in(state, player_id, ids))
  let events = [
    custom("hand_locked_in", [
      #("player_id", json.string(player_id)),
      #("cards", codec.strings(ids)),
    ]),
    ..list.map(ids, fn(id) {
      event.moved(id, hand_zone(player_id), played_zone(player_id))
    })
  ]
  case resolution {
    None -> Ok(#(next, events))
    Some(res) ->
      Ok(#(next, list.append(events, resolution_events(state, next, res))))
  }
}

fn resolution_events(
  before: GameState,
  after: GameState,
  res: Resolution,
) -> List(Event) {
  let is_tie = res.round_over && res.loser == None
  let resolved =
    custom("hands_resolved", [
      #(
        "results",
        json.array(res.results, fn(r) {
          json.object([
            #("player_id", json.string(r.player_id)),
            #("cards", codec.cards_to_json(r.hand)),
            #("score", codec.score_to_json(r.score)),
            #("level", json.int(r.level)),
          ])
        }),
      ),
      #("round_over", json.bool(res.round_over)),
      #("loser", json.nullable(res.loser, json.string)),
      #("round_winner", json.nullable(res.round_winner, json.string)),
      #("tie", json.bool(is_tie)),
      #("game_over", json.bool(res.game_over)),
      #("winner", json.nullable(res.winner, json.string)),
    ])

  let played_moves =
    list.flat_map(res.results, fn(r) {
      list.map(r.hand, fn(c) {
        event.moved(c.id, played_zone(r.player_id), discard_zone(r.player_id))
      })
    })
  let draw_moves =
    list.flat_map(res.drawn, fn(d) {
      list.map(d.1, fn(c) { event.moved(c.id, deck_zone(d.0), hand_zone(d.0)) })
    })
  let score_changes =
    list.filter_map(res.results, fn(r) {
      case
        state.get_player(before, r.player_id),
        state.get_player(after, r.player_id)
      {
        Ok(b), Ok(a) ->
          Ok(event.CounterChanged(
            r.player_id,
            "score",
            b.current_round_score,
            a.current_round_score,
          ))
        _, _ -> Error(Nil)
      }
    })

  let round_events = case res.round_over {
    False -> []
    True -> {
      let life_changes = case res.loser {
        Some(l) ->
          case state.get_player(before, l), state.get_player(after, l) {
            Ok(b), Ok(a) -> [event.CounterChanged(l, "lives", b.lives, a.lives)]
            _, _ -> []
          }
        None -> []
      }
      let ended =
        custom("round_ended", [
          #("round", json.int(before.round_number)),
          #("loser", json.nullable(res.loser, json.string)),
          #("round_winner", json.nullable(res.round_winner, json.string)),
          #("tie", json.bool(is_tie)),
          #(
            "scores",
            json.array(before.order, fn(id) {
              json.object([
                #("player_id", json.string(id)),
                #("score", json.int(state.round_score(after, id))),
              ])
            }),
          ),
        ])
      let phase_events = case res.game_over {
        True -> [
          custom("game_over", [
            #("winner", json.nullable(res.winner, json.string)),
          ]),
          event.PhaseChanged("game_over"),
        ]
        False -> [
          event.PhaseChanged("shop"),
          custom("shop_opened", [#("round", json.int(before.round_number))]),
        ]
      }
      list.flatten([life_changes, [ended], phase_events])
    }
  }

  list.flatten([
    [resolved],
    played_moves,
    draw_moves,
    score_changes,
    round_events,
  ])
}

fn discard(
  state: GameState,
  player_id: PlayerId,
  ids: List(String),
) -> Result(#(GameState, List(Event)), String) {
  use #(next, discarded, drawn) <- result.try(state.discard(
    state,
    player_id,
    ids,
  ))
  let events =
    list.flatten([
      [
        custom("cards_discarded", [
          #("player_id", json.string(player_id)),
          #("discarded", codec.cards_to_json(discarded)),
          #("drawn", codec.cards_to_json(drawn)),
        ]),
      ],
      list.map(discarded, fn(c) {
        event.moved(c.id, hand_zone(player_id), discard_zone(player_id))
      }),
      list.map(drawn, fn(c) {
        event.moved(c.id, deck_zone(player_id), hand_zone(player_id))
      }),
    ])
  Ok(#(next, events))
}

// ---------- Shop ----------

fn current_shop(state: GameState) -> Result(ShopState, String) {
  case state.shop_state {
    Some(shop) -> Ok(shop)
    None -> Error("No active shop")
  }
}

fn shop_error(err: shop_state.ShopError) -> String {
  case err {
    shop_state.DestroyPhaseNotComplete -> "Destroy phase not complete"
    shop_state.CardNotFound -> "Card not found"
    shop_state.CardAlreadyPicked -> "Card already picked"
    shop_state.CardDestroyed -> "Card destroyed"
    shop_state.NotYourTurn -> "Not your turn"
    shop_state.DestroyPhaseComplete -> "Destroy phase already complete"
    shop_state.NotDestroyer -> "Not the destroyer"
    shop_state.NoDestroysRemaining -> "No destroys remaining"
    shop_state.CardAlreadyDestroyed -> "Card already destroyed"
    shop_state.AlreadyComplete -> "Already complete"
  }
}

fn shop_card_event(
  kind: String,
  player_id: PlayerId,
  c: shop_card.ShopCard,
) -> Event {
  custom(kind, [
    #("player_id", json.string(player_id)),
    #("card", codec.shop_card_to_json(c)),
  ])
}

fn shop_pick(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> Result(#(GameState, List(Event)), String) {
  use shop <- result.try(current_shop(state))
  use selected <- result.try(
    list.find(shop.available_cards, fn(c) { c.id == card_id })
    |> result.replace_error("Card not found"),
  )
  use p <- result.try(state.get_player(state, player_id))
  use opponent_id <- result.try(state.opponent_of(state, player_id))
  use opponent <- result.try(state.get_player(state, opponent_id))
  let picked = shop_card_event("shop_pick", player_id, selected)

  case selected.kind {
    shop_card.Logistics(_) -> {
      use #(updated_shop, rng) <- result.try(
        shop_state.confirm_deck_builder_pick(
          shop,
          player_id,
          card_id,
          player.get_all_cards(p),
          state.rng,
        )
        |> result.map_error(shop_error),
      )
      let next = GameState(..state, shop_state: Some(updated_shop), rng: rng)
      Ok(
        #(next, [
          picked,
          selection_started(
            player_id,
            selected,
            updated_shop.pending_deck_builder
              |> option.map(fn(pd) { pd.available_cards }),
          ),
        ]),
      )
    }
    shop_card.Sabotage(shop_card.PlusBomb(_)) -> {
      use #(updated_shop, rng) <- result.try(
        shop_state.confirm_plus_bomb_pick(
          shop,
          player_id,
          card_id,
          player.get_all_cards(opponent),
          state.rng,
        )
        |> result.map_error(shop_error),
      )
      let next = GameState(..state, shop_state: Some(updated_shop), rng: rng)
      Ok(
        #(next, [
          picked,
          selection_started(
            player_id,
            selected,
            updated_shop.pending_plus_bomb
              |> option.map(fn(pb) { pb.available_cards }),
          ),
        ]),
      )
    }
    _ -> {
      use #(updated_shop, _) <- result.try(
        shop_state.make_pick(shop, player_id, card_id)
        |> result.map_error(shop_error),
      )
      let next =
        apply_immediate_effect(state, p, opponent, selected)
        |> fn(s) { GameState(..s, shop_state: Some(updated_shop)) }
      finish_shop_step(next, [picked])
    }
  }
}

fn selection_started(
  player_id: PlayerId,
  c: shop_card.ShopCard,
  available: Option(List(Card)),
) -> Event {
  custom("shop_selection_started", [
    #("player_id", json.string(player_id)),
    #("card", codec.shop_card_to_json(c)),
    #("max_cards", json.int(shop_card.max_selection(c))),
    #("available", codec.cards_to_json(option.unwrap(available, []))),
  ])
}

/// Effects of cards that resolve the moment they are picked
fn apply_immediate_effect(
  state: GameState,
  p: Player,
  opponent: Player,
  c: shop_card.ShopCard,
) -> GameState {
  case c.kind {
    shop_card.Sabotage(shop_card.Scrambler) ->
      state.put_player(state, player.Player(..opponent, scrambled: True))
    shop_card.Sabotage(shop_card.StaticField) ->
      state.put_player(
        state,
        player.Player(..opponent, enhancements_disabled: True),
      )
    shop_card.Sabotage(shop_card.SupplyChain) ->
      state.put_player(
        state,
        player.Player(..opponent, supply_chain_limited: True),
      )
    shop_card.Sabotage(shop_card.PlusBomb(_)) -> state
    shop_card.Research(shop_card.LevelUp(ht)) ->
      state.put_player(state, player.upgrade_hand(p, ht, 1))
    shop_card.Counter(shop_card.Denial(ht)) ->
      state.put_player(
        state,
        player.Player(..opponent, active_debuffs: [
          ht,
          ..opponent.active_debuffs
        ]),
      )
    shop_card.Logistics(_) -> state
  }
}

/// After any shop step: if the shop is done, roll into the next round.
fn finish_shop_step(
  state: GameState,
  events: List(Event),
) -> Result(#(GameState, List(Event)), String) {
  case state.shop_complete(state) {
    False -> Ok(#(state, events))
    True -> {
      let next = state.start_new_round(state)
      let round_events = [
        event.PhaseChanged("playing"),
        custom("round_started", [#("round", json.int(next.round_number))]),
      ]
      Ok(#(next, list.append(events, round_events)))
    }
  }
}

fn shop_select(
  state: GameState,
  player_id: PlayerId,
  ids: List(String),
) -> Result(#(GameState, List(Event)), String) {
  use shop <- result.try(current_shop(state))
  case shop.pending_deck_builder, shop.pending_plus_bomb {
    Some(pending), _ if pending.player_id == player_id ->
      complete_deck_builder(state, shop, pending, player_id, ids)
    _, Some(pending) if pending.player_id == player_id ->
      complete_plus_bomb(state, shop, pending, player_id, ids)
    _, _ -> Error("Nothing to select")
  }
}

fn validate_selection(
  available: List(Card),
  ids: List(String),
  min: Int,
  max: Int,
) -> Result(Nil, String) {
  let count = list.length(ids)
  let available_ids = list.map(available, fn(c) { c.id })
  use <- guard(count >= min && count <= max, "Wrong number of cards selected")
  use <- guard(list.length(list.unique(ids)) == count, "Duplicate selection")
  use <- guard(
    list.all(ids, fn(id) { list.contains(available_ids, id) }),
    "Card not available for selection",
  )
  Ok(Nil)
}

fn complete_deck_builder(
  state: GameState,
  shop: ShopState,
  pending: shop_state.PendingDeckBuilder,
  player_id: PlayerId,
  ids: List(String),
) -> Result(#(GameState, List(Event)), String) {
  let c = pending.deck_builder_card
  use _ <- result.try(validate_selection(
    pending.available_cards,
    ids,
    0,
    shop_card.max_selection(c),
  ))
  use #(updated_shop, _) <- result.try(
    shop_state.complete_deck_builder_selection(shop, player_id)
    |> result.map_error(shop_error),
  )
  use p <- result.try(state.get_player(state, player_id))
  let #(updated_player, state) = case c.kind {
    shop_card.Logistics(shop_card.Fortify(amount, _)) -> #(
      player.apply_enhancements_to_cards(p, ids, card.BonusChips(amount)),
      state,
    )
    shop_card.Logistics(shop_card.Amplify(amount, _)) -> #(
      player.apply_enhancements_to_cards(p, ids, card.BonusMult(amount)),
      state,
    )
    shop_card.Logistics(shop_card.SupplyDrop(_)) -> {
      let #(new_cards, state) =
        pending.available_cards
        |> list.filter(fn(c) { list.contains(ids, c.id) })
        |> list.fold(#([], state), fn(acc, source) {
          let #(cards, state) = acc
          let #(id, state) = state.next_card_id(state, source.rank, source.suit)
          #(list.append(cards, [card.new(id, source.rank, source.suit)]), state)
        })
      #(player.add_cards_to_deck(p, new_cards), state)
    }
    shop_card.Logistics(shop_card.Discharge(_)) -> #(
      player.remove_cards_from_deck(p, ids),
      state,
    )
    shop_card.Logistics(shop_card.Camo(suit, _)) -> #(
      player.change_cards_suit(p, ids, suit),
      state,
    )
    shop_card.Logistics(shop_card.Promote(_)) -> #(
      player.promote_cards(p, ids),
      state,
    )
    _ -> #(p, state)
  }
  let next =
    GameState(
      ..state.put_player(state, updated_player),
      shop_state: Some(updated_shop),
    )
  let events = [
    custom("shop_selection_completed", [
      #("player_id", json.string(player_id)),
      #("card", codec.shop_card_to_json(c)),
      #("cards", codec.strings(ids)),
    ]),
  ]
  finish_shop_step(next, events)
}

fn complete_plus_bomb(
  state: GameState,
  shop: ShopState,
  pending: shop_state.PendingPlusBomb,
  player_id: PlayerId,
  ids: List(String),
) -> Result(#(GameState, List(Event)), String) {
  use _ <- result.try(validate_selection(pending.available_cards, ids, 1, 1))
  use updated_shop <- result.try(
    shop_state.complete_plus_bomb_selection(shop, player_id)
    |> result.map_error(shop_error),
  )
  use opponent_id <- result.try(state.opponent_of(state, player_id))
  use opponent <- result.try(state.get_player(state, opponent_id))
  use chosen <- result.try(
    list.find(pending.available_cards, fn(c) { list.contains(ids, c.id) })
    |> result.replace_error("Card not available for selection"),
  )
  let updated_opponent =
    player.Player(
      ..opponent,
      disabled_ranks: [chosen.rank, ..opponent.disabled_ranks],
      disabled_suits: [chosen.suit, ..opponent.disabled_suits],
    )
  let next =
    GameState(
      ..state.put_player(state, updated_opponent),
      shop_state: Some(updated_shop),
    )
  let events = [
    custom("shop_selection_completed", [
      #("player_id", json.string(player_id)),
      #("card", json.object([#("id", json.string(pending.shop_card_id))])),
      #("cards", codec.strings(ids)),
      #("target", codec.card_to_json(chosen)),
    ]),
  ]
  finish_shop_step(next, events)
}

fn shop_destroy(
  state: GameState,
  player_id: PlayerId,
  card_id: String,
) -> Result(#(GameState, List(Event)), String) {
  use shop <- result.try(current_shop(state))
  use updated_shop <- result.try(
    shop_state.destroy_card(shop, player_id, card_id)
    |> result.map_error(shop_error),
  )
  let destroyed_card =
    list.find(shop.available_cards, fn(c) { c.id == card_id })
  let events = case destroyed_card {
    Ok(c) -> [
      shop_card_event("shop_destroy", player_id, c),
      event.destroyed(card_id, shop_zone),
    ]
    Error(_) -> [event.destroyed(card_id, shop_zone)]
  }
  Ok(#(GameState(..state, shop_state: Some(updated_shop)), events))
}

fn shop_finish_destroy(
  state: GameState,
  player_id: PlayerId,
) -> Result(#(GameState, List(Event)), String) {
  use shop <- result.try(current_shop(state))
  use updated_shop <- result.try(
    shop_state.complete_destroy_phase(shop, player_id)
    |> result.map_error(shop_error),
  )
  Ok(
    #(GameState(..state, shop_state: Some(updated_shop)), [
      custom("destroy_phase_complete", [#("player_id", json.string(player_id))]),
    ]),
  )
}

// ---------- Clocks ----------

/// Who is being charged time right now: anyone who still has to act.
pub fn on_the_clock(state: GameState) -> List(PlayerId) {
  case state.phase {
    state.Playing ->
      state.players_in_order(state)
      |> list.filter(fn(p) {
        !player.has_locked_in(p) && p.status == player.Active
      })
      |> list.map(fn(p) { p.player_id })
    state.Shopping ->
      list.filter(state.order, fn(id) { engine_legal_nonempty(state, id) })
    state.Finished -> []
  }
}

fn engine_legal_nonempty(state: GameState, player_id: PlayerId) -> Bool {
  legal(state, player_id) != []
}

// ---------- Legal actions ----------

pub fn legal(state: GameState, player_id: PlayerId) -> List(Schema) {
  case state.phase, state.get_player(state, player_id) {
    state.Playing, Ok(p) -> playing_legal(p)
    state.Shopping, Ok(_) ->
      case state.shop_state {
        Some(shop) -> shop_legal(shop, player_id)
        None -> []
      }
    _, _ -> []
  }
}

fn playing_legal(p: Player) -> List(Schema) {
  case player.has_locked_in(p) || p.status == player.Eliminated {
    True -> []
    False -> {
      let hand_ids = list.map(p.card_piles.hand, fn(c) { c.id })
      let zone = hand_zone(p.player_id)
      let play =
        action.Schema("play_hand", "Play hand", [
          action.select("cards", zone, hand_ids, 1, 5),
        ])
      case p.discards_remaining > 0 && hand_ids != [] {
        True -> [
          play,
          action.Schema("discard", "Discard", [
            action.select("cards", zone, hand_ids, 1, list.length(hand_ids)),
          ]),
        ]
        False -> [play]
      }
    }
  }
}

fn shop_legal(shop: ShopState, player_id: PlayerId) -> List(Schema) {
  let available_ids =
    shop.available_cards
    |> list.filter(fn(c) { !shop_state.card_unavailable(shop, c.id) })
    |> list.map(fn(c) { c.id })
  case shop.destroy_phase_complete {
    False ->
      case shop_state.can_destroy(shop, player_id) {
        True -> [
          action.Schema("shop_destroy", "Destroy a card", [
            action.select("card", shop_zone, available_ids, 1, 1),
          ]),
          action.simple("shop_finish_destroy", "Finish destroying"),
        ]
        False ->
          case shop.destroyer_id == Some(player_id) {
            True -> [action.simple("shop_finish_destroy", "Finish destroying")]
            False -> []
          }
      }
    True ->
      case shop.pending_deck_builder, shop.pending_plus_bomb {
        Some(pending), _ if pending.player_id == player_id -> [
          action.Schema("shop_select", "Choose cards", [
            action.select(
              "cards",
              selection_zone,
              list.map(pending.available_cards, fn(c) { c.id }),
              0,
              shop_card.max_selection(pending.deck_builder_card),
            ),
          ]),
        ]
        _, Some(pending) if pending.player_id == player_id -> [
          action.Schema("shop_select", "Choose a card", [
            action.select(
              "cards",
              selection_zone,
              list.map(pending.available_cards, fn(c) { c.id }),
              1,
              1,
            ),
          ]),
        ]
        Some(_), _ -> []
        _, Some(_) -> []
        None, None ->
          case shop_state.can_pick(shop, player_id) {
            True -> [
              action.Schema("shop_pick", "Pick a card", [
                action.select("card", shop_zone, available_ids, 1, 1),
              ]),
            ]
            False -> []
          }
      }
  }
}
