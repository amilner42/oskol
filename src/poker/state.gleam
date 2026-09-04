//// Heads-up No-Limit Texas Hold'em: the rules, with no presentation.
////
//// Two players, a button that alternates every hand. The button posts the
//// small blind and acts first before the flop, last after it. Betting
//// follows no-limit rules: a bet is at least the big blind, a raise at
//// least the size of the last raise, and all-in is always available. An
//// uncalled bet goes back to the bettor; a short all-in only plays for the
//// part the other player matched.
////
//// Every state change returns `Happening`s: the facts the engine turns into
//// events. Randomness (the shuffle) comes only from the stored rng.

import gamekit/rng.{type Rng}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import poker/card.{type Card}
import poker/evaluator

pub type PlayerId =
  String

pub type Format {
  Cash
  SitAndGo
}

pub type Config {
  Config(
    format: Format,
    /// Cash: the buy-in every player starts with (and tops up to).
    /// Sit-and-go: the starting stack.
    buy_in: Int,
    /// Cash only: refill a short stack to the buy-in before a hand.
    top_up: Bool,
    /// Blind levels as (small, big). Cash has exactly one.
    levels: List(#(Int, Int)),
    /// Sit-and-go: hands per blind level. 0 means blinds never rise.
    hands_per_level: Int,
  )
}

pub type Street {
  Preflop
  Flop
  Turn
  River
}

pub type Hand {
  Hand(
    number: Int,
    button: PlayerId,
    deck: List(Card),
    hole: Dict(PlayerId, List(Card)),
    board: List(Card),
    street: Street,
    /// Chips put in this street.
    bets: Dict(PlayerId, Int),
    /// Chips put in this hand.
    committed: Dict(PlayerId, Int),
    /// Players who still have to act this street, in order.
    pending: List(PlayerId),
    /// The size of the last bet or raise increment this street (min-raise).
    last_raise: Int,
    folded: Option(PlayerId),
    /// Players whose hole cards are face up (showdown).
    revealed: List(PlayerId),
  )
}

pub type Won {
  ByFold
  ByShowdown
  Split
}

pub type HandResult {
  HandResult(
    number: Int,
    /// Winners and what each collected from the opponent's chips.
    winners: List(#(PlayerId, Int)),
    won: Won,
    /// Best-hand descriptions for the players who showed.
    descriptions: Dict(PlayerId, String),
  )
}

pub type Phase {
  /// A hand is in progress; someone is to act (or the board is running out).
  Betting
  /// The last hand is on the table; the next one is dealt on `deal`.
  HandOver
  Finished(winner: Option(PlayerId))
}

pub type GameState {
  GameState(
    config: Config,
    order: List(PlayerId),
    names: Dict(PlayerId, String),
    stacks: Dict(PlayerId, Int),
    /// Cash: chips bought in so far (buy-in plus top-ups), for net results.
    invested: Dict(PlayerId, Int),
    hands_played: Int,
    /// Sit-and-go: the current blind level (index into levels).
    level: Int,
    hand: Option(Hand),
    last_result: Option(HandResult),
    /// Who has the button for the next hand.
    next_button: PlayerId,
    phase: Phase,
    rng: Rng,
  )
}

/// What an action did, for the engine to narrate.
pub type Happening {
  Dealt(hand_number: Int, button: PlayerId)
  ToppedUp(player: PlayerId, amount: Int)
  LevelUp(level: Int, small: Int, big: Int)
  BlindPosted(player: PlayerId, amount: Int, big: Bool)
  Acted(player: PlayerId, kind: String, amount: Int)
  StreetDealt(street: Street, cards: List(Card))
  Showdown(reveals: List(#(PlayerId, List(Card), String)))
  HandEnded(result: HandResult)
  Left(player: PlayerId)
  GameOver(winner: Option(PlayerId))
}

// ---------- Construction ----------

pub fn new(
  config: Config,
  seats: List(#(PlayerId, String)),
  rng: Rng,
) -> #(GameState, List(Happening)) {
  let order = list.map(seats, fn(s) { s.0 })
  let assert [first, ..] = order
  let state =
    GameState(
      config: config,
      order: order,
      names: dict.from_list(seats),
      stacks: dict.from_list(list.map(order, fn(id) { #(id, config.buy_in) })),
      invested: dict.from_list(list.map(order, fn(id) { #(id, config.buy_in) })),
      hands_played: 0,
      level: 0,
      hand: None,
      last_result: None,
      next_button: first,
      phase: HandOver,
      rng: rng,
    )
  deal(state)
}

// ---------- Queries ----------

pub fn stack(state: GameState, id: PlayerId) -> Int {
  dict.get(state.stacks, id) |> result.unwrap(0)
}

pub fn name_of(state: GameState, id: PlayerId) -> String {
  dict.get(state.names, id) |> result.unwrap(id)
}

pub fn other(state: GameState, id: PlayerId) -> PlayerId {
  case state.order {
    [a, b] if a == id -> b
    [a, _] -> a
    _ -> id
  }
}

pub fn is_player(state: GameState, id: PlayerId) -> Bool {
  list.contains(state.order, id)
}

pub fn blinds(state: GameState) -> #(Int, Int) {
  list.drop(state.config.levels, state.level)
  |> list.first
  |> result.unwrap(list.last(state.config.levels) |> result.unwrap(#(1, 2)))
}

pub fn big_blind(state: GameState) -> Int {
  blinds(state).1
}

pub fn to_act(state: GameState) -> Option(PlayerId) {
  case state.phase, state.hand {
    Betting, Some(hand) -> list.first(hand.pending) |> option.from_result
    _, _ -> None
  }
}

pub fn bet_of(hand: Hand, id: PlayerId) -> Int {
  dict.get(hand.bets, id) |> result.unwrap(0)
}

pub fn committed_of(hand: Hand, id: PlayerId) -> Int {
  dict.get(hand.committed, id) |> result.unwrap(0)
}

pub fn pot(hand: Hand) -> Int {
  dict.values(hand.committed) |> int.sum
}

pub fn current_bet(hand: Hand) -> Int {
  dict.values(hand.bets) |> list.fold(0, int.max)
}

/// What this player must add to match the bet (capped by their stack).
pub fn to_call(state: GameState, id: PlayerId) -> Int {
  case state.hand {
    Some(hand) ->
      int.min(current_bet(hand) - bet_of(hand, id), stack(state, id))
      |> int.max(0)
    None -> 0
  }
}

/// Bounds for a bet or raise as a total for this street: (min, max).
/// `Error` when no bet or raise is possible (nothing left, or the opponent
/// cannot call anything more).
pub fn raise_bounds(state: GameState, id: PlayerId) -> Result(#(Int, Int), Nil) {
  case state.hand {
    Some(hand) -> {
      let my_bet = bet_of(hand, id)
      let my_stack = stack(state, id)
      let opp = other(state, id)
      let max = my_bet + my_stack
      let current = current_bet(hand)
      let increment = int.max(hand.last_raise, big_blind(state))
      let min = int.min(current + increment, max)
      case my_stack > 0 && stack(state, opp) > 0 && max > current {
        True -> Ok(#(min, max))
        False -> Error(Nil)
      }
    }
    None -> Error(Nil)
  }
}

pub fn can_check(state: GameState, id: PlayerId) -> Bool {
  to_act(state) == Some(id) && to_call(state, id) == 0
}

pub fn can_deal(state: GameState, id: PlayerId) -> Bool {
  state.phase == HandOver && is_player(state, id)
}

/// Cash: chips won or lost since sitting down. Chips in the current pot
/// still count as the player's until the hand decides them.
pub fn net(state: GameState, id: PlayerId) -> Int {
  let in_pot = case state.phase, state.hand {
    Betting, Some(hand) -> committed_of(hand, id)
    _, _ -> 0
  }
  stack(state, id)
  + in_pot
  - { dict.get(state.invested, id) |> result.unwrap(0) }
}

pub fn hole_cards(state: GameState, id: PlayerId) -> List(Card) {
  case state.hand {
    Some(hand) -> dict.get(hand.hole, id) |> result.unwrap([])
    None -> []
  }
}

pub fn street_name(street: Street) -> String {
  case street {
    Preflop -> "preflop"
    Flop -> "flop"
    Turn -> "turn"
    River -> "river"
  }
}

// ---------- Dealing ----------

/// Deal the next hand: top-ups, the blind level, cards, blinds. Ends the
/// game instead when someone is out of chips.
pub fn deal(state: GameState) -> #(GameState, List(Happening)) {
  let #(state, topped) = top_up(state)
  case list.filter(state.order, fn(id) { stack(state, id) <= 0 }) {
    [broke, ..] -> {
      let winner = Some(other(state, broke))
      #(
        GameState(..state, phase: Finished(winner), hand: None),
        list.append(topped, [GameOver(winner)]),
      )
    }
    [] -> {
      let #(state, levelled) = advance_level(state)
      let number = state.hands_played + 1
      let button = state.next_button
      let opponent = other(state, button)
      let #(deck, rng) = card.shuffled_deck(number, state.rng)
      // Heads-up deal: the non-button gets the first card
      let assert [c1, c2, c3, c4, ..rest] = deck
      let hole = dict.from_list([#(opponent, [c1, c3]), #(button, [c2, c4])])
      let #(small, big) = blinds(state)
      let hand =
        Hand(
          number: number,
          button: button,
          deck: rest,
          hole: hole,
          board: [],
          street: Preflop,
          bets: dict.new(),
          committed: dict.new(),
          pending: [button, opponent],
          last_raise: big,
          folded: None,
          revealed: [],
        )
      let state = GameState(..state, hand: Some(hand), rng: rng, phase: Betting)
      let #(state, sb) = post_blind(state, button, small, False)
      let #(state, bb) = post_blind(state, opponent, big, True)
      let happenings =
        list.flatten([topped, levelled, [Dealt(number, button)], sb, bb])
      // A blind that put someone all in may leave nothing to decide
      let #(state, more) = settle_if_nobody_can_act(state)
      #(state, list.append(happenings, more))
    }
  }
}

fn top_up(state: GameState) -> #(GameState, List(Happening)) {
  case state.config.format, state.config.top_up {
    Cash, True ->
      list.fold(state.order, #(state, []), fn(acc, id) {
        let #(state, happenings) = acc
        let short = state.config.buy_in - stack(state, id)
        case short > 0 {
          True -> #(
            GameState(
              ..state,
              stacks: dict.insert(state.stacks, id, state.config.buy_in),
              invested: dict.insert(
                state.invested,
                id,
                { dict.get(state.invested, id) |> result.unwrap(0) } + short,
              ),
            ),
            list.append(happenings, [ToppedUp(id, short)]),
          )
          False -> acc
        }
      })
    _, _ -> #(state, [])
  }
}

fn advance_level(state: GameState) -> #(GameState, List(Happening)) {
  case state.config.format, state.config.hands_per_level {
    SitAndGo, per if per > 0 -> {
      let wanted =
        int.min(state.hands_played / per, list.length(state.config.levels) - 1)
      case wanted > state.level {
        True -> {
          let next = GameState(..state, level: wanted)
          let #(small, big) = blinds(next)
          #(next, [LevelUp(wanted, small, big)])
        }
        False -> #(state, [])
      }
    }
    _, _ -> #(state, [])
  }
}

fn post_blind(
  state: GameState,
  id: PlayerId,
  amount: Int,
  big: Bool,
) -> #(GameState, List(Happening)) {
  let posted = int.min(amount, stack(state, id))
  #(put_chips(state, id, posted), [BlindPosted(id, posted, big)])
}

/// Move chips from a stack into this street's bet and the hand's pot.
fn put_chips(state: GameState, id: PlayerId, amount: Int) -> GameState {
  let assert Some(hand) = state.hand
  let hand =
    Hand(
      ..hand,
      bets: dict.insert(hand.bets, id, bet_of(hand, id) + amount),
      committed: dict.insert(
        hand.committed,
        id,
        committed_of(hand, id) + amount,
      ),
    )
  GameState(
    ..state,
    hand: Some(hand),
    stacks: dict.insert(state.stacks, id, stack(state, id) - amount),
  )
}

// ---------- Betting ----------

pub type Move {
  Fold
  Check
  Call
  /// Total for this street.
  Bet(to: Int)
  /// Total for this street.
  Raise(to: Int)
  AllIn
}

fn require(condition: Bool, message: String, next: fn() -> Result(a, String)) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

/// Act in the current hand.
pub fn act(
  state: GameState,
  id: PlayerId,
  move: Move,
) -> Result(#(GameState, List(Happening)), String) {
  use <- require(is_player(state, id), "Not at this table")
  use <- require(state.phase == Betting, "No hand in progress")
  use <- require(to_act(state) == Some(id), "Not your turn")
  let assert Some(hand) = state.hand
  let call = to_call(state, id)
  let opp = other(state, id)
  let acted = case move {
    Check -> {
      use <- require(call == 0, "You must call or fold")
      Ok(#(state, Acted(id, "check", 0), False))
    }
    Fold -> {
      use <- require(call > 0, "Nothing to fold to")
      Ok(#(
        GameState(..state, hand: Some(Hand(..hand, folded: Some(id)))),
        Acted(id, "fold", 0),
        False,
      ))
    }
    Call -> {
      use <- require(call > 0, "Nothing to call")
      Ok(#(put_chips(state, id, call), Acted(id, "call", call), False))
    }
    Bet(to) -> {
      use <- require(current_bet(hand) == 0, "There is a bet: raise instead")
      use #(min, max) <- result.try(
        raise_bounds(state, id) |> result.replace_error("You cannot bet"),
      )
      use <- require(to >= min && to <= max, bounds_message("bet", min, max))
      Ok(#(put_chips(state, id, to), Acted(id, "bet", to), True))
    }
    Raise(to) -> {
      use <- require(current_bet(hand) > 0, "Nothing to raise: bet instead")
      use #(min, max) <- result.try(
        raise_bounds(state, id) |> result.replace_error("You cannot raise"),
      )
      use <- require(to >= min && to <= max, bounds_message("raise", min, max))
      Ok(#(
        put_chips(state, id, to - bet_of(hand, id)),
        Acted(id, "raise", to),
        True,
      ))
    }
    AllIn -> {
      let my_stack = stack(state, id)
      use <- require(my_stack > 0, "You have no chips")
      let total = bet_of(hand, id) + my_stack
      case raise_bounds(state, id) {
        Ok(_) ->
          Ok(#(put_chips(state, id, my_stack), Acted(id, "all_in", total), True))
        // Calling for less than the bet. When nothing can be raised into
        // and the stack covers the call, this would over-commit: call.
        Error(_) -> {
          use <- require(
            my_stack <= to_call(state, id),
            "Nothing to raise into: call instead",
          )
          Ok(#(
            put_chips(state, id, my_stack),
            Acted(id, "all_in", total),
            False,
          ))
        }
      }
    }
  }
  use #(state, happening, aggressive) <- result.try(acted)
  let assert Some(hand) = state.hand
  let hand = case aggressive {
    True -> {
      let increment = bet_of(hand, id) - current_bet_before(hand, id)
      Hand(
        ..hand,
        last_raise: int.max(hand.last_raise, increment),
        pending: case stack(state, opp) > 0 {
          True -> [opp]
          False -> []
        },
      )
    }
    False ->
      // Whoever is left to act must still have chips, and a decision: a
      // player owed nothing by an opponent who is all in has none.
      Hand(
        ..hand,
        pending: list.filter(hand.pending, fn(p) {
          p != id
          && stack(state, p) > 0
          && { to_call(state, p) > 0 || stack(state, other(state, p)) > 0 }
        }),
      )
  }
  let state = GameState(..state, hand: Some(hand))
  let #(state, more) = case hand.folded {
    Some(_) -> end_by_fold(state)
    None ->
      case hand.pending {
        [] -> next_street(state)
        _ -> #(state, [])
      }
  }
  Ok(#(state, [happening, ..more]))
}

fn current_bet_before(hand: Hand, id: PlayerId) -> Int {
  dict.delete(hand.bets, id) |> dict.values |> list.fold(0, int.max)
}

fn bounds_message(what: String, min: Int, max: Int) -> String {
  "A "
  <> what
  <> " must be between "
  <> int.to_string(min)
  <> " and "
  <> int.to_string(max)
}

/// Everyone still to act has acted: deal the next street, run the board
/// out when nobody can act, or go to showdown.
fn next_street(state: GameState) -> #(GameState, List(Happening)) {
  let assert Some(hand) = state.hand
  let nobody_can_act =
    list.count(state.order, fn(id) { stack(state, id) > 0 }) <= 1
  case hand.street {
    River -> showdown(state)
    street -> {
      let #(next, cards) = case street {
        Preflop -> #(Flop, 3)
        Flop -> #(Turn, 1)
        _ -> #(River, 1)
      }
      let dealt = list.take(hand.deck, cards)
      let button = hand.button
      let first = other(state, button)
      let hand =
        Hand(
          ..hand,
          deck: list.drop(hand.deck, cards),
          board: list.append(hand.board, dealt),
          street: next,
          bets: dict.new(),
          last_raise: big_blind(state),
          pending: case nobody_can_act {
            True -> []
            False -> [first, button]
          },
        )
      let state = GameState(..state, hand: Some(hand))
      let happening = StreetDealt(next, dealt)
      case nobody_can_act {
        True -> {
          let #(state, more) = next_street(state)
          #(state, [happening, ..more])
        }
        False -> #(state, [happening])
      }
    }
  }
}

/// After the blinds, a player may already be all in with nothing to decide.
fn settle_if_nobody_can_act(state: GameState) -> #(GameState, List(Happening)) {
  let assert Some(hand) = state.hand
  // Players with chips who face a decision keep the hand going
  let pending =
    list.filter(hand.pending, fn(id) {
      stack(state, id) > 0
      && { to_call(state, id) > 0 || stack(state, other(state, id)) > 0 }
    })
  let hand = Hand(..hand, pending: pending)
  let state = GameState(..state, hand: Some(hand))
  case pending {
    [] -> next_street(state)
    _ -> #(state, [])
  }
}

fn end_by_fold(state: GameState) -> #(GameState, List(Happening)) {
  let assert Some(hand) = state.hand
  let assert Some(loser) = hand.folded
  let winner = other(state, loser)
  let won = committed_of(hand, loser)
  let result =
    HandResult(
      number: hand.number,
      winners: [#(winner, won)],
      won: ByFold,
      descriptions: dict.new(),
    )
  finish_hand(state, [#(winner, pot(hand))], result, [])
}

fn showdown(state: GameState) -> #(GameState, List(Happening)) {
  let assert Some(hand) = state.hand
  let assert [a, b] = state.order
  let strength = fn(id) {
    evaluator.best(list.append(hole_cards(state, id), hand.board))
  }
  let sa = strength(a)
  let sb = strength(b)
  let descriptions =
    dict.from_list([
      #(a, evaluator.describe(sa)),
      #(b, evaluator.describe(sb)),
    ])
  let reveals =
    list.map(state.order, fn(id) {
      #(
        id,
        hole_cards(state, id),
        dict.get(descriptions, id) |> result.unwrap(""),
      )
    })
  // A short all-in only plays for what the other player matched
  let ca = committed_of(hand, a)
  let cb = committed_of(hand, b)
  let matched = int.min(ca, cb)
  let refund = fn(id) {
    case id == a {
      True -> ca - matched
      False -> cb - matched
    }
  }
  let #(payouts, result) = case evaluator.compare(sa, sb) {
    order.Gt -> #(
      [#(a, matched * 2 + refund(a)), #(b, refund(b))],
      HandResult(hand.number, [#(a, matched)], ByShowdown, descriptions),
    )
    order.Lt -> #(
      [#(b, matched * 2 + refund(b)), #(a, refund(a))],
      HandResult(hand.number, [#(b, matched)], ByShowdown, descriptions),
    )
    order.Eq ->
      // Each side takes its own chips back
      #(
        [#(a, matched + refund(a)), #(b, matched + refund(b))],
        HandResult(hand.number, [#(a, 0), #(b, 0)], Split, descriptions),
      )
  }
  let state =
    GameState(..state, hand: Some(Hand(..hand, revealed: state.order)))
  finish_hand(state, payouts, result, [Showdown(reveals)])
}

fn finish_hand(
  state: GameState,
  payouts: List(#(PlayerId, Int)),
  result: HandResult,
  before: List(Happening),
) -> #(GameState, List(Happening)) {
  let assert Some(hand) = state.hand
  let stacks =
    list.fold(payouts, state.stacks, fn(stacks, p) {
      dict.insert(stacks, p.0, stack(state, p.0) + p.1)
    })
  let state =
    GameState(
      ..state,
      stacks: stacks,
      hands_played: hand.number,
      next_button: other(state, hand.button),
      last_result: Some(result),
      phase: HandOver,
      hand: Some(Hand(..hand, pending: [])),
    )
  let happenings = list.append(before, [HandEnded(result)])
  // Out of chips (and no top-up coming) ends the match now
  let broke =
    list.filter(state.order, fn(id) { stack(state, id) <= 0 })
    |> list.first
  let refill = state.config.format == Cash && state.config.top_up
  case broke, refill {
    Ok(loser), False -> {
      let winner = Some(other(state, loser))
      #(
        GameState(..state, phase: Finished(winner)),
        list.append(happenings, [GameOver(winner)]),
      )
    }
    _, _ -> #(state, happenings)
  }
}

// ---------- Between hands ----------

/// Deal the next hand (either player may push things along).
pub fn next_hand(
  state: GameState,
  id: PlayerId,
) -> Result(#(GameState, List(Happening)), String) {
  use <- require(is_player(state, id), "Not at this table")
  case state.phase {
    Finished(_) -> Error("The game is over")
    Betting -> Error("A hand is in progress")
    HandOver -> Ok(deal(state))
  }
}

/// Leave the table: in a sit-and-go that concedes; at a cash table the
/// session ends and the bigger net result wins.
pub fn leave(
  state: GameState,
  id: PlayerId,
) -> Result(#(GameState, List(Happening)), String) {
  use <- require(is_player(state, id), "Not at this table")
  case state.phase {
    Finished(_) -> Error("The game is over")
    _ -> {
      let opp = other(state, id)
      // Walking out of a live hand at a cash table is a fold: the chips in
      // the pot go to the opponent, exactly as folding would. In a
      // sit-and-go the leaver concedes, so the hand's chips do not matter.
      let #(state, happenings) = case
        state.config.format,
        state.hand,
        state.phase
      {
        Cash, Some(hand), Betting -> {
          let folded =
            GameState(
              ..state,
              hand: Some(Hand(..hand, folded: Some(id), pending: [])),
            )
          let #(state, ended) = end_by_fold(folded)
          #(state, [Acted(id, "fold", 0), ..ended])
        }
        _, Some(hand), Betting -> #(
          GameState(
            ..state,
            stacks: list.fold(state.order, state.stacks, fn(stacks, p) {
              dict.insert(stacks, p, stack(state, p) + committed_of(hand, p))
            }),
            hand: Some(Hand(..hand, pending: [])),
          ),
          [],
        )
        _, _, _ -> #(state, [])
      }
      let winner = case state.config.format {
        SitAndGo -> Some(opp)
        Cash ->
          case int.compare(net(state, id), net(state, opp)) {
            order.Gt -> Some(id)
            order.Lt -> Some(opp)
            order.Eq -> None
          }
      }
      Ok(#(
        GameState(..state, phase: Finished(winner)),
        list.append(happenings, [Left(id), GameOver(winner)]),
      ))
    }
  }
}
