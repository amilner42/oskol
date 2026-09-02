import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import tilt/engine
import tilt/game as tilt
import tilt/player
import tilt/poker/hand
import tilt/shop/card as shop_card
import tilt/shop/state as shop_state
import tilt/state.{type GameState}

const p1 = "p1"

const p2 = "p2"

fn seats() {
  [Seat(p1, "Alice"), Seat(p2, "Bob")]
}

fn new_game(seed: Int) -> GameState {
  let assert Ok(format) = game.find_format(tilt.info(), "short")
  let assert Ok(state) = tilt.init(format.config, seats(), rng.seed(seed))
  state
}

fn hand_ids(state: GameState, id: String) -> List(String) {
  let assert Ok(p) = state.get_player(state, id)
  list.map(p.card_piles.hand, fn(c) { c.id })
}

fn get(state: GameState, id: String) -> player.Player {
  let assert Ok(p) = state.get_player(state, id)
  p
}

fn apply(
  state: GameState,
  id: String,
  action: engine.Action,
) -> #(GameState, List(event.Event)) {
  let assert Ok(result) = engine.apply(state, id, action)
  result
}

fn has_custom(events: List(event.Event), kind: String) -> Bool {
  list.any(events, fn(e) {
    case e {
      event.Custom(k, _) -> k == kind
      _ -> False
    }
  })
}

pub fn new_game_deals_eight_cards_each_test() {
  let state = new_game(1)
  assert list.length(hand_ids(state, p1)) == 8
  assert list.length(hand_ids(state, p2)) == 8
  assert list.length(player.get_all_cards(get(state, p1))) == 52
  assert state.phase == state.Playing
  assert get(state, p1).lives == 2
}

pub fn same_seed_same_deal_test() {
  assert hand_ids(new_game(5), p1) == hand_ids(new_game(5), p1)
  assert hand_ids(new_game(5), p1) != hand_ids(new_game(6), p1)
}

pub fn players_get_different_shuffles_test() {
  let state = new_game(3)
  assert hand_ids(state, p1) != hand_ids(state, p2)
}

pub fn play_hand_rejects_card_not_in_hand_test() {
  let state = new_game(1)
  assert engine.apply(state, p1, engine.PlayHand(["not-a-card"]))
    == Error("Card not in hand")
}

pub fn play_hand_rejects_more_than_five_cards_test() {
  let state = new_game(1)
  let six = list.take(hand_ids(state, p1), 6)
  assert engine.apply(state, p1, engine.PlayHand(six))
    == Error("Play between 1 and 5 cards")
}

pub fn play_hand_rejects_empty_test() {
  let state = new_game(1)
  assert engine.apply(state, p1, engine.PlayHand([]))
    == Error("Play between 1 and 5 cards")
}

pub fn cannot_lock_in_twice_test() {
  let state = new_game(1)
  let #(state, events) =
    apply(state, p1, engine.PlayHand(list.take(hand_ids(state, p1), 2)))
  assert has_custom(events, "hand_locked_in")
  assert player.has_locked_in(get(state, p1))
  assert engine.apply(
      state,
      p1,
      engine.PlayHand(list.take(hand_ids(state, p1), 1)),
    )
    == Error("Already locked in")
}

pub fn locked_in_player_has_no_legal_actions_test() {
  let state = new_game(1)
  let #(state, _) =
    apply(state, p1, engine.PlayHand(list.take(hand_ids(state, p1), 2)))
  assert engine.legal(state, p1) == []
  assert list.length(engine.legal(state, p2)) == 2
}

pub fn discard_draws_replacements_test() {
  let state = new_game(2)
  let before = hand_ids(state, p1)
  let #(state, events) = apply(state, p1, engine.Discard(list.take(before, 3)))
  let after = hand_ids(state, p1)
  assert list.length(after) == 8
  assert list.filter(after, fn(id) { list.contains(list.take(before, 3), id) })
    == []
  assert get(state, p1).discards_remaining == 2
  assert list.length(get(state, p1).card_piles.discard) == 3
  assert has_custom(events, "cards_discarded")
}

pub fn discard_limited_by_discards_remaining_test() {
  let state = new_game(2)
  let state =
    list.fold(list.range(1, 3), state, fn(s, _) {
      let #(s, _) = apply(s, p1, engine.Discard(list.take(hand_ids(s, p1), 1)))
      s
    })
  assert get(state, p1).discards_remaining == 0
  assert engine.apply(
      state,
      p1,
      engine.Discard(list.take(hand_ids(state, p1), 1)),
    )
    == Error("No discards remaining")
  assert list.length(engine.legal(state, p1)) == 1
}

pub fn cannot_discard_after_locking_in_test() {
  let state = new_game(2)
  let #(state, _) =
    apply(state, p1, engine.PlayHand(list.take(hand_ids(state, p1), 1)))
  assert engine.apply(
      state,
      p1,
      engine.Discard(list.drop(hand_ids(state, p1), 7)),
    )
    == Error("Cannot discard after locking in")
}

pub fn both_locking_in_resolves_the_hand_test() {
  let state = new_game(4)
  let #(state, _) =
    apply(state, p1, engine.PlayHand(list.take(hand_ids(state, p1), 1)))
  let #(state, events) =
    apply(state, p2, engine.PlayHand(list.take(hand_ids(state, p2), 1)))
  assert has_custom(events, "hands_resolved")
  assert get(state, p1).current_round_score > 0
  assert get(state, p2).current_round_score > 0
  assert get(state, p1).hands_remaining == 3
  assert list.length(hand_ids(state, p1)) == 8
  assert player.has_locked_in(get(state, p1)) == False
  assert list.length(state.round_hand_history) == 1
}

fn play_full_round(state: GameState) -> #(GameState, List(event.Event)) {
  list.fold(
    list.range(1, state.config.hands_per_round),
    #(state, []),
    fn(acc, _) {
      let #(s, _) = acc
      let #(s, _) = apply(s, p1, engine.PlayHand(list.take(hand_ids(s, p1), 1)))
      apply(s, p2, engine.PlayHand(list.take(hand_ids(s, p2), 1)))
    },
  )
}

pub fn round_end_opens_shop_and_costs_a_life_test() {
  let state = new_game(8)
  let #(state, events) = play_full_round(state)
  assert has_custom(events, "round_ended")
  assert state.phase == state.Shopping
  assert has_custom(events, "shop_opened")
  let lives = get(state, p1).lives + get(state, p2).lives
  let tie = state.last_round_winner_id == None
  assert lives == 4 || lives == 3
  assert tie || lives == 3
  assert state.shop_state != None
  assert engine.apply(
      state,
      p1,
      engine.PlayHand(list.take(hand_ids(state, p1), 1)),
    )
    == Error("Not in the playing phase")
}

pub fn errors_leave_state_untouched_test() {
  let state = new_game(1)
  let fingerprint = fn(s: GameState) {
    #(hand_ids(s, p1), get(s, p1).discards_remaining, s.phase)
  }
  let before = fingerprint(state)
  let _ = engine.apply(state, p1, engine.PlayHand(["bogus"]))
  let _ = engine.apply(state, p1, engine.ShopPick("x"))
  assert fingerprint(state) == before
}

// ---------- Shop ----------

fn with_shop(
  state: GameState,
  cards: List(shop_card.ShopCard),
  lives: List(#(String, Int)),
) -> GameState {
  let players =
    dict.map_values(state.players, fn(id, p) {
      let l =
        list.key_find(lives, id)
        |> fn(r) {
          case r {
            Ok(v) -> v
            Error(_) -> p.lives
          }
        }
      player.Player(..p, lives: l)
    })
  let #(shop, rng) =
    shop_state.new(
      p1,
      p2,
      False,
      1,
      cards,
      dict.map_values(players, fn(_, p) { p.lives }),
      state.rng,
    )
  state.GameState(
    ..state,
    players: players,
    phase: state.Shopping,
    shop_state: Some(shop),
    rng: rng,
  )
}

fn level_up(id: String) -> shop_card.ShopCard {
  shop_card.ShopCard(id, shop_card.Research(shop_card.LevelUp(hand.Pair)))
}

pub fn level_up_pick_upgrades_hand_and_completes_shop_test() {
  let state = with_shop(new_game(1), [level_up("s1"), level_up("s2")], [])
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  assert player.skill_level(get(state, p1), hand.Pair) == 2
  assert engine.apply(state, p1, engine.ShopPick("s2"))
    == Error("Not your turn")
  let #(state, events) = apply(state, p2, engine.ShopPick("s2"))
  assert state.phase == state.Playing
  assert state.round_number == 2
  assert has_custom(events, "round_started")
  assert get(state, p1).hands_remaining == 4
}

pub fn supply_drop_adds_a_card_to_the_deck_test() {
  let supply =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.SupplyDrop(1)))
  let state = with_shop(new_game(1), [supply, level_up("s2")], [])
  let #(state, events) = apply(state, p1, engine.ShopPick("s1"))
  assert has_custom(events, "shop_selection_started")
  let assert Some(shop) = state.shop_state
  let assert Some(pending) = shop.pending_deck_builder
  assert list.length(pending.available_cards) == 8
  let assert [schema] = engine.legal(state, p1)
  assert schema.name == "shop_select"
  let assert [first, ..] = pending.available_cards
  let #(state, _) = apply(state, p1, engine.ShopSelect([first.id]))
  assert list.length(player.get_all_cards(get(state, p1))) == 53
  let ids = list.map(player.get_all_cards(get(state, p1)), fn(c) { c.id })
  assert list.length(list.unique(ids)) == 53
}

pub fn skipping_a_deck_builder_selection_is_allowed_test() {
  let discharge =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.Discharge(2)))
  let state = with_shop(new_game(1), [discharge, level_up("s2")], [])
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  let #(state, _) = apply(state, p1, engine.ShopSelect([]))
  assert list.length(player.get_all_cards(get(state, p1))) == 52
  let assert Some(shop) = state.shop_state
  assert shop.first_pick_made
}

pub fn discharge_removes_selected_cards_test() {
  let discharge =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.Discharge(2)))
  let state = with_shop(new_game(1), [discharge, level_up("s2")], [])
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  let assert Some(shop) = state.shop_state
  let assert Some(pending) = shop.pending_deck_builder
  let chosen = list.take(pending.available_cards, 2) |> list.map(fn(c) { c.id })
  assert engine.apply(
      state,
      p1,
      engine.ShopSelect(list.take(
        list.map(pending.available_cards, fn(c) { c.id }),
        3,
      )),
    )
    == Error("Wrong number of cards selected")
  let #(state, _) = apply(state, p1, engine.ShopSelect(chosen))
  assert list.length(player.get_all_cards(get(state, p1))) == 50
}

pub fn plus_bomb_disables_opponent_rank_and_suit_test() {
  let bomb = shop_card.ShopCard("s1", shop_card.Sabotage(shop_card.PlusBomb(1)))
  let state = with_shop(new_game(1), [bomb, level_up("s2")], [])
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  let assert Some(shop) = state.shop_state
  let assert Some(pending) = shop.pending_plus_bomb
  assert engine.apply(state, p1, engine.ShopSelect([]))
    == Error("Wrong number of cards selected")
  let assert [target, ..] = pending.available_cards
  let #(state, _) = apply(state, p1, engine.ShopSelect([target.id]))
  assert get(state, p2).disabled_ranks == [target.rank]
  assert get(state, p2).disabled_suits == [target.suit]
}

pub fn sabotage_applies_to_opponent_and_clears_after_a_round_test() {
  let scrambler =
    shop_card.ShopCard("s1", shop_card.Sabotage(shop_card.Scrambler))
  let state = with_shop(new_game(1), [scrambler, level_up("s2")], [])
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  assert get(state, p2).scrambled
  let #(state, _) = apply(state, p2, engine.ShopPick("s2"))
  assert state.phase == state.Playing
  assert get(state, p2).scrambled
  let #(state, _) = play_full_round(state)
  assert get(state, p2).scrambled == False
}

pub fn destroy_phase_belongs_to_the_player_behind_test() {
  let state =
    with_shop(new_game(1), [level_up("s1"), level_up("s2"), level_up("s3")], [
      #(p1, 1),
      #(p2, 3),
    ])
  let assert Some(shop) = state.shop_state
  assert shop.destroyer_id == Some(p1)
  assert shop.destroys_allowed == 2
  assert engine.apply(state, p2, engine.ShopPick("s1"))
    == Error("Destroy phase not complete")
  assert list.map(engine.legal(state, p1), fn(s) { s.name })
    == ["shop_destroy", "shop_finish_destroy"]
  assert engine.legal(state, p2) == []
  let #(state, events) = apply(state, p1, engine.ShopDestroy("s3"))
  assert has_custom(events, "shop_destroy")
  let #(state, _) = apply(state, p1, engine.ShopFinishDestroy)
  assert engine.apply(state, p1, engine.ShopPick("s3"))
    == Error("Card destroyed")
  let #(state, _) = apply(state, p1, engine.ShopPick("s1"))
  let #(state, _) = apply(state, p2, engine.ShopPick("s2"))
  assert state.phase == state.Playing
}
