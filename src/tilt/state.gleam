//// Tilt game state and the pure transitions over it.
////
//// Nothing here knows about the client, animation, or JSON. Every random
//// choice comes from the seeded Rng stored in the state.

import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tilt/player.{type Player, type PlayerId}
import tilt/poker/card.{type Card}
import tilt/poker/deck
import tilt/poker/hand
import tilt/poker/score
import tilt/shop/generator as shop_gen
import tilt/shop/state.{type ShopState} as shop_state

pub type Phase {
  Playing
  Shopping
  Finished
}

pub type Config {
  Config(
    initial_lives: Int,
    hands_per_round: Int,
    discards_per_round: Int,
    shop_rounds: Int,
  )
}

/// One player's scored hand
pub type HandResult {
  HandResult(
    player_id: PlayerId,
    hand: List(Card),
    score: score.ScoreResult,
    level: Int,
  )
}

/// Everything that happened when both players' hands resolved
pub type Resolution {
  Resolution(
    results: List(HandResult),
    /// Cards each player drew to refill after playing
    drawn: List(#(PlayerId, List(Card))),
    round_over: Bool,
    /// Player who lost a life (None on a tie or mid-round)
    loser: Option(PlayerId),
    round_winner: Option(PlayerId),
    game_over: Bool,
    winner: Option(PlayerId),
  )
}

pub type GameState {
  GameState(
    config: Config,
    /// Seat order, used for every iteration so the game is deterministic
    order: List(PlayerId),
    names: Dict(PlayerId, String),
    players: Dict(PlayerId, Player),
    round_number: Int,
    phase: Phase,
    round_hand_history: List(List(HandResult)),
    winner_id: Option(PlayerId),
    last_round_winner_id: Option(PlayerId),
    shop_state: Option(ShopState),
    rng: Rng,
    /// Counter for ids of cards created mid-game (Supply Drop)
    card_serial: Int,
  )
}

pub fn new(
  config: Config,
  seats: List(#(PlayerId, String)),
  rng: Rng,
) -> GameState {
  let #(players, rng) =
    list.fold(seats, #(dict.new(), rng), fn(acc, seat) {
      let #(players, rng) = acc
      let #(shuffled, rng) = rng.shuffle(rng, deck.create_standard_deck())
      // Ids are opaque labels shuffled independently of the deck, so an id
      // reveals neither a card's face nor where it sits in the draw pile.
      let #(labels, rng) = rng.shuffle(rng, list.range(1, 52))
      let shuffled =
        list.map2(shuffled, labels, fn(c, n) {
          card.Card(..c, id: seat.0 <> "-c" <> int.to_string(n))
        })
      let p =
        player.new(
          seat.0,
          config.initial_lives,
          config.hands_per_round,
          config.discards_per_round,
          shuffled,
        )
      #(dict.insert(players, seat.0, p), rng)
    })
  GameState(
    config: config,
    order: list.map(seats, fn(s) { s.0 }),
    names: dict.from_list(seats),
    players: players,
    round_number: 1,
    phase: Playing,
    round_hand_history: [],
    winner_id: None,
    last_round_winner_id: None,
    shop_state: None,
    rng: rng,
    card_serial: 0,
  )
}

// ---------- Helpers ----------

pub fn guard(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

pub fn get_player(
  state: GameState,
  player_id: PlayerId,
) -> Result(Player, String) {
  dict.get(state.players, player_id) |> result.replace_error("Player not found")
}

pub fn opponent_of(
  state: GameState,
  player_id: PlayerId,
) -> Result(PlayerId, String) {
  list.find(state.order, fn(id) { id != player_id })
  |> result.replace_error("Opponent not found")
}

pub fn put_player(state: GameState, p: Player) -> GameState {
  GameState(..state, players: dict.insert(state.players, p.player_id, p))
}

pub fn players_in_order(state: GameState) -> List(Player) {
  list.filter_map(state.order, fn(id) { dict.get(state.players, id) })
}

pub fn name_of(state: GameState, player_id: PlayerId) -> String {
  dict.get(state.names, player_id) |> result.unwrap(player_id)
}

pub fn all_locked_in(state: GameState) -> Bool {
  list.all(players_in_order(state), player.has_locked_in)
}

/// Mint a unique id for a card created during the game
pub fn next_card_id(state: GameState) -> #(String, GameState) {
  // Opaque like every card id: the serial says nothing about the face
  let serial = state.card_serial + 1
  #("c" <> int.to_string(serial), GameState(..state, card_serial: serial))
}

// ---------- Playing ----------

/// Lock in a hand. When both players have locked in, the hands resolve.
pub fn lock_in(
  state: GameState,
  player_id: PlayerId,
  card_ids: List(String),
) -> Result(#(GameState, Option(Resolution)), String) {
  use <- guard(state.phase == Playing, "Not in the playing phase")
  use p <- result.try(get_player(state, player_id))
  use <- guard(!player.has_locked_in(p), "Already locked in")
  use <- guard(p.hands_remaining > 0, "No hands remaining")
  let count = list.length(card_ids)
  use <- guard(count >= 1 && count <= 5, "Play between 1 and 5 cards")
  use cards <- result.try(player.cards_in_hand(p, card_ids))
  let state = put_player(state, player.lock_in_hand(p, cards))
  case all_locked_in(state) {
    True -> {
      let #(state, resolution) = resolve_hands(state)
      Ok(#(state, Some(resolution)))
    }
    False -> Ok(#(state, None))
  }
}

/// Discard cards and draw replacements. Returns the discarded and drawn cards.
pub fn discard(
  state: GameState,
  player_id: PlayerId,
  card_ids: List(String),
) -> Result(#(GameState, List(Card), List(Card)), String) {
  use <- guard(state.phase == Playing, "Not in the playing phase")
  use p <- result.try(get_player(state, player_id))
  use <- guard(!player.has_locked_in(p), "Cannot discard after locking in")
  use <- guard(
    list.length(card_ids) >= 1,
    "Select at least one card to discard",
  )
  use cards <- result.try(player.cards_in_hand(p, card_ids))
  use #(updated, drawn, rng) <- result.try(player.discard_and_draw(
    p,
    cards,
    state.rng,
  ))
  Ok(#(GameState(..put_player(state, updated), rng: rng), cards, drawn))
}

fn score_hand(p: Player, cards: List(Card)) -> HandResult {
  let evaluation = hand.evaluate(cards)
  let card_debuffs =
    score.CardDebuffs(
      disabled_ranks: p.disabled_ranks,
      disabled_suits: p.disabled_suits,
      enhancements_disabled: p.enhancements_disabled,
    )
  let result =
    score.calculate(evaluation, p.skill_tree, p.active_debuffs, card_debuffs)
  HandResult(
    player_id: p.player_id,
    hand: cards,
    score: result,
    level: player.skill_level(p, result.hand_type),
  )
}

fn resolve_hands(state: GameState) -> #(GameState, Resolution) {
  let results =
    players_in_order(state)
    |> list.filter_map(fn(p) {
      case p.locked_in_hand {
        Some(cards) -> Ok(score_hand(p, cards))
        None -> Error(Nil)
      }
    })
  let history = [results, ..state.round_hand_history]

  let #(players, drawn, rng) =
    list.fold(
      players_in_order(state),
      #(state.players, [], state.rng),
      fn(acc, p) {
        let #(players, drawn, rng) = acc
        let gained =
          list.find(results, fn(r) { r.player_id == p.player_id })
          |> result.map(fn(r) { r.score.total_score })
          |> result.unwrap(0)
        let #(updated, cards, rng) = player.reset_for_next_hand(p, gained, rng)
        #(
          dict.insert(players, p.player_id, updated),
          list.append(drawn, [#(p.player_id, cards)]),
          rng,
        )
      },
    )

  let state =
    GameState(..state, players: players, round_hand_history: history, rng: rng)
  let round_over =
    list.all(players_in_order(state), fn(p) { p.hands_remaining == 0 })

  case round_over {
    True -> end_round(state, results, drawn)
    False -> #(
      state,
      Resolution(
        results: results,
        drawn: drawn,
        round_over: False,
        loser: None,
        round_winner: None,
        game_over: False,
        winner: None,
      ),
    )
  }
}

/// Round total for a player across the hands played this round
pub fn round_score(state: GameState, player_id: PlayerId) -> Int {
  state.round_hand_history
  |> list.flatten
  |> list.filter(fn(r) { r.player_id == player_id })
  |> list.fold(0, fn(acc, r) { acc + r.score.total_score })
}

fn end_round(
  state: GameState,
  results: List(HandResult),
  drawn: List(#(PlayerId, List(Card))),
) -> #(GameState, Resolution) {
  let scores = list.map(state.order, fn(id) { #(id, round_score(state, id)) })
  let lowest =
    scores
    |> list.map(fn(s) { s.1 })
    |> list.reduce(fn(a, b) {
      case a < b {
        True -> a
        False -> b
      }
    })
    |> result.unwrap(0)
  let losers =
    scores |> list.filter(fn(s) { s.1 == lowest }) |> list.map(fn(s) { s.0 })
  let is_tie = list.length(losers) > 1
  let loser = case is_tie {
    True -> None
    False -> list.first(losers) |> option.from_result
  }
  let round_winner = case loser {
    Some(l) -> list.find(state.order, fn(id) { id != l }) |> option.from_result
    None -> None
  }

  let players = case loser {
    Some(l) ->
      dict.map_values(state.players, fn(id, p) {
        case id == l {
          True -> player.lose_life(p)
          False -> p
        }
      })
    None -> state.players
  }

  let game_over =
    players |> dict.values |> list.any(fn(p) { p.status == player.Eliminated })
  let winner = case game_over {
    True ->
      list.find(state.order, fn(id) {
        case dict.get(players, id) {
          Ok(p) -> p.status == player.Active
          Error(_) -> False
        }
      })
      |> option.from_result
    False -> None
  }

  let resolution =
    Resolution(
      results: results,
      drawn: drawn,
      round_over: True,
      loser: loser,
      round_winner: round_winner,
      game_over: game_over,
      winner: winner,
    )

  case game_over {
    True -> #(
      GameState(
        ..state,
        players: players,
        phase: Finished,
        winner_id: winner,
        last_round_winner_id: round_winner,
        shop_state: None,
      ),
      resolution,
    )
    False -> {
      // Sabotage lasts exactly one round: clear before the shop hands out new ones
      let players =
        dict.map_values(players, fn(_id, p) { player.clear_sabotage(p) })
      let #(shop_cards, rng) =
        shop_gen.generate_shop_cards(state.rng, state.round_number)
      let #(first, second) = case round_winner, loser {
        Some(w), Some(l) -> #(w, l)
        _, _ -> two_ids(state.order)
      }
      let lives = dict.map_values(players, fn(_id, p) { p.lives })
      let #(shop, rng) =
        shop_state.new(
          first,
          second,
          is_tie,
          state.config.shop_rounds,
          shop_cards,
          lives,
          rng,
        )
      #(
        GameState(
          ..state,
          players: players,
          phase: Shopping,
          last_round_winner_id: round_winner,
          shop_state: Some(shop),
          rng: rng,
        ),
        resolution,
      )
    }
  }
}

fn two_ids(order: List(PlayerId)) -> #(PlayerId, PlayerId) {
  case order {
    [a, b, ..] -> #(a, b)
    [a] -> #(a, a)
    [] -> #("", "")
  }
}

/// Start the next round after the shop completes
pub fn start_new_round(state: GameState) -> GameState {
  let #(players, rng) =
    list.fold(players_in_order(state), #(state.players, state.rng), fn(acc, p) {
      let #(players, rng) = acc
      let #(updated, rng) =
        player.reset_for_new_round(
          p,
          state.config.hands_per_round,
          state.config.discards_per_round,
          rng,
        )
      #(dict.insert(players, p.player_id, updated), rng)
    })
  GameState(
    ..state,
    round_number: state.round_number + 1,
    players: players,
    phase: Playing,
    shop_state: None,
    round_hand_history: [],
    last_round_winner_id: None,
    rng: rng,
  )
}

pub fn shop_complete(state: GameState) -> Bool {
  case state.shop_state {
    Some(shop) -> shop_state.shop_complete(shop)
    None -> False
  }
}
