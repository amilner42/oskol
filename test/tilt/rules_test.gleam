//// Tilt rules that need a controlled setup: fixed hands, sabotage effects,
//// round scoring, ties, game over, and the shop's deck-building cards.

import gamekit/action
import gamekit/game.{Seat}
import gamekit/rng
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import tilt/engine
import tilt/game as tilt
import tilt/player
import tilt/poker/card.{type Card, Card}
import tilt/poker/hand
import tilt/shop/card as shop_card
import tilt/shop/state as shop_state
import tilt/state.{type GameState}

const p1 = "p1"

const p2 = "p2"

fn seats() {
  [Seat(p1, "Alice"), Seat(p2, "Bob")]
}

fn new_game(seed: Int, format: String) -> GameState {
  let assert Ok(f) = game.find_format(tilt.info(), format)
  let assert Ok(s) = tilt.init(f.config, seats(), rng.seed(seed))
  s
}

fn get(state: GameState, id: String) -> player.Player {
  let assert Ok(p) = state.get_player(state, id)
  p
}

fn apply(state: GameState, id: String, action: engine.Action) -> GameState {
  let assert Ok(#(next, _)) = engine.apply(state, id, action)
  next
}

fn plain(id: String, rank, suit) -> Card {
  Card(id: id, rank: rank, suit: suit, enhancement: None)
}

/// Replace a player's hand with specific cards (the rest of the deck stays).
fn with_hand(state: GameState, id: String, cards: List(Card)) -> GameState {
  let p = get(state, id)
  let ids = list.map(cards, fn(c) { c.id })
  let deck =
    list.filter(player.get_all_cards(p), fn(c) { !list.contains(ids, c.id) })
  state.put_player(
    state,
    player.Player(
      ..p,
      card_piles: player.CardPiles(deck: deck, hand: cards, discard: []),
    ),
  )
}

fn tweak(
  state: GameState,
  id: String,
  f: fn(player.Player) -> player.Player,
) -> GameState {
  state.put_player(state, f(get(state, id)))
}

fn pair_of_fives() -> List(Card) {
  [plain("5H", card.Five, card.Hearts), plain("5C", card.Five, card.Clubs)]
}

fn play_both(
  state: GameState,
  mine: List(String),
  theirs: List(String),
) -> GameState {
  state
  |> apply(p1, engine.PlayHand(mine))
  |> apply(p2, engine.PlayHand(theirs))
}

// ---------- Sabotage ----------

pub fn supply_chain_limits_refills_to_four_test() {
  let state =
    new_game(1, "short")
    |> tweak(p1, fn(p) { player.Player(..p, supply_chain_limited: True) })
  let hand = list.map(get(state, p1).card_piles.hand, fn(c) { c.id })
  let state = apply(state, p1, engine.Discard(list.take(hand, 6)))
  // 2 kept + at most 4 drawn
  assert list.length(get(state, p1).card_piles.hand) == 6
  // Playing five then refilling is capped too
  let state =
    new_game(1, "short")
    |> tweak(p1, fn(p) { player.Player(..p, supply_chain_limited: True) })
  let mine =
    list.take(list.map(get(state, p1).card_piles.hand, fn(c) { c.id }), 5)
  let theirs =
    list.take(list.map(get(state, p2).card_piles.hand, fn(c) { c.id }), 5)
  let state = play_both(state, mine, theirs)
  assert list.length(get(state, p1).card_piles.hand) == 7
  assert list.length(get(state, p2).card_piles.hand) == 8
}

pub fn scrambler_marks_some_drawn_cards_face_down_test() {
  // Across several seeds a scrambled player ends up with face-down cards; an unscrambled one never does.
  let face_down_total =
    list.range(1, 8)
    |> list.map(fn(seed) {
      let state =
        new_game(seed, "short")
        |> tweak(p2, fn(p) { player.Player(..p, scrambled: True) })
      let hand = list.map(get(state, p2).card_piles.hand, fn(c) { c.id })
      let state = apply(state, p2, engine.Discard(list.take(hand, 8)))
      assert get(state, p1).face_down_card_ids == []
      let ids = get(state, p2).face_down_card_ids
      assert list.all(ids, fn(id) {
        list.contains(
          list.map(get(state, p2).card_piles.hand, fn(c) { c.id }),
          id,
        )
      })
      list.length(ids)
    })
    |> list.fold(0, fn(a, b) { a + b })
  assert face_down_total > 0
}

pub fn static_field_ignores_enhancements_when_scoring_test() {
  let boosted = [
    Card(
      id: "5H",
      rank: card.Five,
      suit: card.Hearts,
      enhancement: Some(card.BonusChips(100)),
    ),
    Card(
      id: "5C",
      rank: card.Five,
      suit: card.Clubs,
      enhancement: Some(card.BonusMult(5)),
    ),
  ]
  let base =
    new_game(2, "short")
    |> with_hand(p1, boosted)
    |> with_hand(p2, pair_of_fives_for_p2())
  let normal = play_both(base, ["5H", "5C"], ["5S", "5D"])
  let jammed =
    base
    |> tweak(p1, fn(p) { player.Player(..p, enhancements_disabled: True) })
    |> play_both(["5H", "5C"], ["5S", "5D"])
  assert get(normal, p1).current_round_score
    == { 140 + 5 + 5 + 100 } * { 1 + 5 }
  assert get(jammed, p1).current_round_score == 150
}

fn pair_of_fives_for_p2() -> List(Card) {
  [plain("5S", card.Five, card.Spades), plain("5D", card.Five, card.Diamonds)]
}

pub fn denial_makes_the_hand_type_score_zero_test() {
  let state =
    new_game(3, "short")
    |> with_hand(p1, pair_of_fives())
    |> with_hand(p2, pair_of_fives_for_p2())
    |> tweak(p1, fn(p) { player.Player(..p, active_debuffs: [hand.Pair]) })
    |> play_both(["5H", "5C"], ["5S", "5D"])
  assert get(state, p1).current_round_score == 0
  assert get(state, p2).current_round_score == 150
}

pub fn plus_bomb_disables_rank_and_suit_when_scoring_test() {
  let state =
    new_game(3, "short")
    |> with_hand(p1, pair_of_fives())
    |> with_hand(p2, pair_of_fives_for_p2())
    |> tweak(p1, fn(p) {
      player.Player(..p, disabled_ranks: [card.Five], disabled_suits: [])
    })
    |> play_both(["5H", "5C"], ["5S", "5D"])
  // Pair still recognised, but both fives contribute 0 chips
  assert get(state, p1).current_round_score == 140
}

// ---------- Rounds, ties, game over ----------

pub fn round_score_is_the_sum_of_hands_and_loser_drops_a_life_test() {
  // p1 always plays a pair of fives (150); p2 a single deuce (127) -> p2 loses the round.
  let state =
    list.fold(list.range(1, 4), new_game(4, "short"), fn(s, _) {
      s
      |> with_hand(p1, pair_of_fives())
      |> with_hand(p2, [plain("2S", card.Two, card.Spades)])
      |> play_both(["5H", "5C"], ["2S"])
    })
  assert state.round_score(state, p1) == 600
  assert state.round_score(state, p2) == 508
  assert state.phase == state.Shopping
  assert get(state, p2).lives == 1
  assert get(state, p1).lives == 2
  assert state.last_round_winner_id == Some(p1)
  let assert Some(shop) = state.shop_state
  assert shop.first_picker_id == p1
  assert shop.second_picker_id == p2
  // Loser is one life behind, so they get one destroy
  assert shop.destroyer_id == Some(p2)
  assert shop.destroys_allowed == 1
}

pub fn tied_round_costs_nobody_a_life_test() {
  let state =
    list.fold(list.range(1, 4), new_game(5, "short"), fn(s, _) {
      s
      |> with_hand(p1, pair_of_fives())
      |> with_hand(p2, pair_of_fives_for_p2())
      |> play_both(["5H", "5C"], ["5S", "5D"])
    })
  assert state.phase == state.Shopping
  assert get(state, p1).lives == 2 && get(state, p2).lives == 2
  assert state.last_round_winner_id == None
  let assert Some(shop) = state.shop_state
  assert shop.destroy_phase_complete
  assert shop.destroys_allowed == 0
}

pub fn losing_the_last_life_ends_the_game_test() {
  let state =
    new_game(6, "short")
    |> tweak(p2, fn(p) { player.Player(..p, lives: 1) })
  let state =
    list.fold(list.range(1, 4), state, fn(s, _) {
      s
      |> with_hand(p1, pair_of_fives())
      |> with_hand(p2, [plain("2S", card.Two, card.Spades)])
      |> play_both(["5H", "5C"], ["2S"])
    })
  assert state.phase == state.Finished
  assert state.winner_id == Some(p1)
  assert get(state, p2).status == player.Eliminated
  assert state.shop_state == None
  assert tilt.outcome(state) == game.Finished([p1])
  assert engine.legal(state, p1) == [] && engine.legal(state, p2) == []
  assert engine.on_the_clock(state) == []
  let assert Error(_) = engine.apply(state, p1, engine.PlayHand(["5H"]))
}

pub fn new_round_resets_hands_scores_and_reshuffles_test() {
  let state =
    list.fold(list.range(1, 4), new_game(7, "short"), fn(s, _) {
      let mine =
        list.take(list.map(get(s, p1).card_piles.hand, fn(c) { c.id }), 3)
      let theirs =
        list.take(list.map(get(s, p2).card_piles.hand, fn(c) { c.id }), 3)
      play_both(s, mine, theirs)
    })
  assert state.phase == state.Shopping
  assert list.length(get(state, p1).card_piles.discard) == 12
  let next = state.start_new_round(state)
  assert next.round_number == 2
  assert next.phase == state.Playing
  assert next.round_hand_history == []
  list.each([p1, p2], fn(id) {
    let p = get(next, id)
    assert p.hands_remaining == 4
    assert p.discards_remaining == 3
    assert p.current_round_score == 0
    assert p.locked_in_hand == None
    assert list.length(p.card_piles.hand) == 8
    assert list.length(p.card_piles.deck) == 44
    assert p.card_piles.discard == []
    assert list.length(
        list.unique(list.map(player.get_all_cards(p), fn(c) { c.id })),
      )
      == 52
  })
  // Lives and skill trees persist across rounds
  assert get(next, p1).lives + get(next, p2).lives
    == get(state, p1).lives + get(state, p2).lives
}

// ---------- Shop cards ----------

fn with_shop(state: GameState, cards: List(shop_card.ShopCard)) -> GameState {
  let lives = dict.map_values(state.players, fn(_, p) { p.lives })
  let #(shop, rng) = shop_state.new(p1, p2, False, 1, cards, lives, state.rng)
  state.GameState(
    ..state,
    phase: state.Shopping,
    shop_state: Some(shop),
    rng: rng,
  )
}

fn level_up(id: String) -> shop_card.ShopCard {
  shop_card.ShopCard(id, shop_card.Research(shop_card.LevelUp(hand.Pair)))
}

fn pending_ids(state: GameState) -> List(String) {
  let assert Some(shop) = state.shop_state
  let assert Some(pending) = shop.pending_deck_builder
  list.map(pending.available_cards, fn(c) { c.id })
}

fn find_card(state: GameState, id: String, card_id: String) -> Card {
  let assert Ok(c) =
    list.find(player.get_all_cards(get(state, id)), fn(c) { c.id == card_id })
  c
}

pub fn fortify_and_amplify_stack_on_the_same_card_test() {
  let fortify =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.Fortify(40, 2)))
  let state = with_shop(new_game(8, "short"), [fortify, level_up("s2")])
  let state = apply(state, p1, engine.ShopPick("s1"))
  let assert [a, b, ..] = pending_ids(state)
  let state = apply(state, p1, engine.ShopSelect([a, b]))
  assert find_card(state, p1, a).enhancement == Some(card.BonusChips(40))
  assert find_card(state, p1, b).enhancement == Some(card.BonusChips(40))
  // Fortify again on the same card: stacks to 80. Amplify replaces a different enhancement type.
  let p = get(state, p1)
  let stacked = player.apply_enhancements_to_cards(p, [a], card.BonusChips(40))
  let assert Ok(c) =
    list.find(player.get_all_cards(stacked), fn(c) { c.id == a })
  assert c.enhancement == Some(card.BonusChips(80))
  let replaced =
    player.apply_enhancements_to_cards(stacked, [a], card.BonusMult(1))
  let assert Ok(c) =
    list.find(player.get_all_cards(replaced), fn(c) { c.id == a })
  assert c.enhancement == Some(card.BonusMult(1))
}

pub fn camo_changes_suit_and_promote_raises_rank_test() {
  let camo =
    shop_card.ShopCard(
      "s1",
      shop_card.Logistics(shop_card.Camo(card.Spades, 3)),
    )
  let state = with_shop(new_game(9, "short"), [camo, level_up("s2")])
  let state = apply(state, p1, engine.ShopPick("s1"))
  let chosen = list.take(pending_ids(state), 3)
  let state = apply(state, p1, engine.ShopSelect(chosen))
  list.each(chosen, fn(id) {
    assert find_card(state, p1, id).suit == card.Spades
  })

  let promote =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.Promote(2)))
  let state = with_shop(new_game(9, "short"), [promote, level_up("s2")])
  let state = apply(state, p1, engine.ShopPick("s1"))
  let assert [a, ..] = pending_ids(state)
  let before = find_card(state, p1, a).rank
  let state = apply(state, p1, engine.ShopSelect([a]))
  assert find_card(state, p1, a).rank == card.next_rank(before)
  // Aces wrap to twos, as the shop card says
  assert card.next_rank(card.Ace) == card.Two
}

pub fn selection_must_come_from_the_offered_cards_test() {
  let discharge =
    shop_card.ShopCard("s1", shop_card.Logistics(shop_card.Discharge(2)))
  let state = with_shop(new_game(10, "short"), [discharge, level_up("s2")])
  let state = apply(state, p1, engine.ShopPick("s1"))
  let offered = pending_ids(state)
  let not_offered =
    player.get_all_cards(get(state, p1))
    |> list.map(fn(c) { c.id })
    |> list.filter(fn(id) { !list.contains(offered, id) })
  let assert [outsider, ..] = not_offered
  assert engine.apply(state, p1, engine.ShopSelect([outsider]))
    == Error("Card not available for selection")
  let assert [a, ..] = offered
  assert engine.apply(state, p1, engine.ShopSelect([a, a]))
    == Error("Duplicate selection")
  // The opponent cannot answer someone else's selection
  assert engine.apply(state, p2, engine.ShopSelect([a]))
    == Error("Nothing to select")
  // Offered cards are 8 distinct cards from the whole deck
  assert list.length(offered) == 8 && list.length(list.unique(offered)) == 8
}

pub fn second_shop_round_alternates_picks_again_test() {
  let lives =
    dict.map_values(new_game(11, "standard").players, fn(_, p) { p.lives })
  let base = new_game(11, "standard")
  let cards = [level_up("s1"), level_up("s2"), level_up("s3"), level_up("s4")]
  let #(shop, rng) = shop_state.new(p1, p2, False, 2, cards, lives, base.rng)
  let state =
    state.GameState(
      ..base,
      phase: state.Shopping,
      shop_state: Some(shop),
      rng: rng,
    )
  let state = apply(state, p1, engine.ShopPick("s1"))
  let state = apply(state, p2, engine.ShopPick("s2"))
  let assert Some(shop) = state.shop_state
  assert shop.current_round == 2
  assert shop.first_pick_made == False && shop.second_pick_made == False
  assert state.phase == state.Shopping
  assert engine.apply(state, p1, engine.ShopPick("s1"))
    == Error("Card already picked")
  assert engine.apply(state, p2, engine.ShopPick("s3"))
    == Error("Not your turn")
  let state = apply(state, p1, engine.ShopPick("s3"))
  let state = apply(state, p2, engine.ShopPick("s4"))
  assert state.phase == state.Playing
  assert player.skill_level(get(state, p1), hand.Pair) == 3
  assert player.skill_level(get(state, p2), hand.Pair) == 3
}

pub fn destroy_phase_auto_completes_when_destroys_run_out_test() {
  let state =
    new_game(12, "short")
    |> tweak(p1, fn(p) { player.Player(..p, lives: 1) })
    |> tweak(p2, fn(p) { player.Player(..p, lives: 3) })
    |> with_shop([
      level_up("s1"),
      level_up("s2"),
      level_up("s3"),
      level_up("s4"),
    ])
  let assert Some(shop) = state.shop_state
  assert shop.destroys_allowed == 2
  let state = apply(state, p1, engine.ShopDestroy("s3"))
  assert engine.apply(state, p1, engine.ShopDestroy("s3"))
    == Error("Card already destroyed")
  assert engine.apply(state, p2, engine.ShopDestroy("s4"))
    == Error("Not the destroyer")
  let state = apply(state, p1, engine.ShopDestroy("s4"))
  let assert Some(shop) = state.shop_state
  assert shop.destroy_phase_complete
  assert engine.apply(state, p1, engine.ShopDestroy("s1"))
    == Error("Destroy phase already complete")
  assert engine.apply(state, p1, engine.ShopFinishDestroy)
    == Error("Already complete")
  // Destroyed cards are gone from the legal picks
  let assert [pick] = engine.legal(state, p1)
  assert pick.name == "shop_pick"
}

pub fn shop_pick_of_the_wrong_kind_of_card_is_rejected_test() {
  let state = with_shop(new_game(13, "short"), [level_up("s1")])
  assert engine.apply(state, p1, engine.ShopPick("nope"))
    == Error("Card not found")
  assert engine.apply(state, p2, engine.ShopPick("s1"))
    == Error("Not your turn")
  assert engine.apply(state, p1, engine.ShopSelect(["x"]))
    == Error("Nothing to select")
}

pub fn legal_schemas_describe_the_hand_precisely_test() {
  let state = new_game(14, "short")
  let hand = list.map(get(state, p1).card_piles.hand, fn(c) { c.id })
  let assert [play, discard] = engine.legal(state, p1)
  let assert [p] = play.params
  let assert [d] = discard.params
  assert p.kind == action.Select("hand:p1", hand, 1, 5)
  assert d.kind == action.Select("hand:p1", hand, 1, 8)
}

// ---------- Deck exhaustion ----------

pub fn an_empty_deck_reshuffles_the_discard_pile_test() {
  let state = new_game(15, "short")
  let p = get(state, p1)
  let all = player.get_all_cards(p)
  let hand = list.take(all, 8)
  let deck = list.take(list.drop(all, 8), 2)
  let discard = list.drop(all, 10)
  let state =
    state.put_player(
      state,
      player.Player(
        ..p,
        card_piles: player.CardPiles(deck: deck, hand: hand, discard: discard),
      ),
    )
  let state =
    apply(
      state,
      p1,
      engine.Discard(list.take(list.map(hand, fn(c) { c.id }), 5)),
    )
  let after = get(state, p1)
  assert list.length(after.card_piles.hand) == 8
  assert list.length(after.card_piles.deck) == 52 - 8
  assert after.card_piles.discard == []
  assert list.length(
      list.unique(list.map(player.get_all_cards(after), fn(c) { c.id })),
    )
    == 52
}

pub fn a_tiny_deck_still_plays_to_the_end_of_the_round_test() {
  // Ten cards in total: the hand can never exceed what exists, but it never runs dry either.
  let state = new_game(16, "short")
  let p = get(state, p1)
  let ten = list.take(player.get_all_cards(p), 10)
  let state =
    state.put_player(
      state,
      player.Player(
        ..p,
        card_piles: player.CardPiles(
          deck: list.drop(ten, 8),
          hand: list.take(ten, 8),
          discard: [],
        ),
      ),
    )
  let state =
    list.fold(list.range(1, 4), state, fn(s, _) {
      let mine =
        list.take(list.map(get(s, p1).card_piles.hand, fn(c) { c.id }), 5)
      let theirs =
        list.take(list.map(get(s, p2).card_piles.hand, fn(c) { c.id }), 5)
      assert list.length(mine) == 5
      play_both(s, mine, theirs)
    })
  assert state.phase == state.Shopping
  assert list.length(player.get_all_cards(get(state, p1))) == 10
}

// ---------- Clocks and generation ----------

pub fn only_the_acting_players_are_on_the_clock_in_the_shop_test() {
  let state =
    new_game(17, "short")
    |> tweak(p1, fn(p) { player.Player(..p, lives: 1) })
    |> tweak(p2, fn(p) { player.Player(..p, lives: 2) })
    |> with_shop([
      level_up("s1"),
      level_up("s2"),
      shop_card.ShopCard("s3", shop_card.Logistics(shop_card.Discharge(2))),
    ])
  // Destroy phase: only the destroyer
  assert engine.on_the_clock(state) == [p1]
  let state = apply(state, p1, engine.ShopFinishDestroy)
  // First picker only
  assert engine.on_the_clock(state) == [p1]
  let state = apply(state, p1, engine.ShopPick("s3"))
  // Pending selection: still p1
  assert engine.on_the_clock(state) == [p1]
  let state = apply(state, p1, engine.ShopSelect([]))
  assert engine.on_the_clock(state) == [p2]
  let state = apply(state, p2, engine.ShopPick("s1"))
  // Back to play: both
  assert engine.on_the_clock(state) == [p1, p2]
}

pub fn shop_generation_is_seeded_and_well_formed_test() {
  list.each(list.range(1, 20), fn(seed) {
    let #(cards, _) = tilt_shop_generate(rng.seed(seed), 1)
    assert list.length(cards) == 16
    let ids = list.map(cards, fn(c) { c.id })
    assert list.length(list.unique(ids)) == 16
    let category = fn(c: shop_card.ShopCard) { shop_card.category(c) }
    let arsenal =
      list.filter(cards, fn(c) {
        category(c) == "research" || category(c) == "logistics"
      })
    let actions =
      list.filter(cards, fn(c) {
        category(c) == "sabotage" || category(c) == "counter"
      })
    assert list.length(arsenal) == 8 && list.length(actions) == 8
  })
  let #(a, _) = tilt_shop_generate(rng.seed(5), 2)
  let #(b, _) = tilt_shop_generate(rng.seed(5), 2)
  assert a == b
  assert list.all(a, fn(c) { string_starts_with(c.id, "shop-2-") })
}

@external(erlang, "tilt@shop@generator", "generate_shop_cards")
fn tilt_shop_generate(
  r: rng.Rng,
  round: Int,
) -> #(List(shop_card.ShopCard), rng.Rng)

@external(erlang, "gleam@string", "starts_with")
fn string_starts_with(s: String, prefix: String) -> Bool
