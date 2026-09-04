//// Hold'em rules in controlled spots: who acts, min-raises, folds and
//// uncalled bets, short all-ins, splits, run-outs, blind levels, top-ups,
//// and what a timeout does.

import gamekit/action
import gamekit/event
import gamekit/game
import gamekit/rng
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import poker/card
import poker/engine
import poker/state.{type GameState}

const p1 = "p1"

const p2 = "p2"

fn cards(text: String) -> List(card.Card) {
  string.split(text, " ")
  |> list.map(fn(code) {
    let assert Ok(c) = card.parse(code)
    c
  })
}

fn sng_config() -> state.Config {
  state.Config(
    format: state.SitAndGo,
    buy_in: 1000,
    top_up: False,
    levels: [#(10, 20), #(15, 30), #(25, 50)],
    hands_per_level: 0,
  )
}

/// A hand after the blinds (10/20) with spelled-out cards. `deck` is what
/// will come off the top: the flop, turn and river in order.
fn spot(
  stacks: #(Int, Int),
  button: String,
  hole1: String,
  hole2: String,
  deck: String,
) -> GameState {
  spot_with(sng_config(), stacks, button, hole1, hole2, deck)
}

fn spot_with(
  config: state.Config,
  stacks: #(Int, Int),
  button: String,
  hole1: String,
  hole2: String,
  deck: String,
) -> GameState {
  let #(s, _) = state.new(config, [#(p1, "Alice"), #(p2, "Bob")], rng.seed(1))
  let other = case button {
    "p1" -> p2
    _ -> p1
  }
  let #(stack1, stack2) = stacks
  let blind = fn(id) {
    case id == button {
      True -> 10
      False -> 20
    }
  }
  state.GameState(
    ..s,
    stacks: dict.from_list([
      #(p1, stack1 - blind(p1)),
      #(p2, stack2 - blind(p2)),
    ]),
    invested: dict.from_list([#(p1, stack1), #(p2, stack2)]),
    phase: state.Betting,
    hand: Some(
      state.Hand(
        number: 1,
        button: button,
        deck: cards(deck),
        hole: dict.from_list([#(p1, cards(hole1)), #(p2, cards(hole2))]),
        board: [],
        street: state.Preflop,
        bets: dict.from_list([#(button, 10), #(other, 20)]),
        committed: dict.from_list([#(button, 10), #(other, 20)]),
        pending: [button, other],
        last_raise: 20,
        folded: None,
        revealed: [],
      ),
    ),
  )
}

fn play(s: GameState, id: String, a: engine.Action) -> GameState {
  let assert Ok(#(next, _)) = engine.apply(s, id, a)
  next
}

fn names(s: GameState, id: String) -> List(String) {
  list.map(engine.legal(s, id), fn(schema) { schema.name })
}

fn board(s: GameState) -> Int {
  let assert Some(hand) = s.hand
  list.length(hand.board)
}

pub fn the_button_acts_first_preflop_and_last_after_the_flop_test() {
  let s = spot(#(1000, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  assert state.to_act(s) == Some(p1)
  assert names(s, p1) == ["fold", "call", "raise", "all_in", "resign"]
  assert names(s, p2) == ["resign"]
  assert state.to_call(s, p1) == 10
  // Limping gives the big blind the option
  let s = play(s, p1, engine.Call)
  assert state.to_act(s) == Some(p2)
  assert names(s, p2) == ["check", "raise", "all_in", "resign"]
  let s = play(s, p2, engine.Check)
  // Flop: the big blind (out of position) acts first
  assert board(s) == 3
  assert state.to_act(s) == Some(p2)
  assert names(s, p2) == ["check", "bet", "all_in", "resign"]
  let s = play(s, p2, engine.Check)
  let s = play(s, p1, engine.Check)
  assert board(s) == 4
  let s = play(s, p2, engine.Check)
  let s = play(s, p1, engine.Check)
  assert board(s) == 5
  let s = play(s, p2, engine.Check)
  let s = play(s, p1, engine.Check)
  // Showdown: aces hold
  assert s.phase == state.HandOver
  let assert Some(result) = s.last_result
  assert result.winners == [#(p1, 20)]
  assert result.won == state.ByShowdown
  assert dict.get(result.descriptions, p1) == Ok("a pair of aces")
  assert state.stack(s, p1) == 1020 && state.stack(s, p2) == 980
  assert s.next_button == p2
}

pub fn raises_respect_the_minimum_and_the_stack_test() {
  let s = spot(#(1000, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  assert state.raise_bounds(s, p1) == Ok(#(40, 1000))
  assert engine.apply(s, p1, engine.Raise(30))
    == Error("A raise must be between 40 and 1000")
  assert engine.apply(s, p1, engine.Bet(40))
    == Error("There is a bet: raise instead")
  let s = play(s, p1, engine.Raise(60))
  assert state.to_call(s, p2) == 40
  // The last raise was 40, so the re-raise must add at least 40
  assert state.raise_bounds(s, p2) == Ok(#(100, 1000))
  let s = play(s, p2, engine.Raise(200))
  assert state.raise_bounds(s, p1) == Ok(#(340, 1000))
  assert engine.apply(s, p1, engine.Raise(1001))
    == Error("A raise must be between 340 and 1000")
  // The schema carries the same bounds
  let assert Ok(raise) =
    list.find(engine.legal(s, p1), fn(sc) { sc.name == "raise" })
  assert raise.params == [action.number("amount", 340, 1000)]
}

pub fn a_fold_hands_over_the_pot_and_the_uncalled_bet_comes_back_test() {
  let s = spot(#(1000, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.Raise(60))
  assert names(s, p2) == ["fold", "call", "raise", "all_in", "resign"]
  let assert Ok(#(s, events)) = engine.apply(s, p2, engine.Fold)
  assert s.phase == state.HandOver
  assert state.stack(s, p1) == 1020 && state.stack(s, p2) == 980
  let assert Some(result) = s.last_result
  assert result == state.HandResult(1, [#(p1, 20)], state.ByFold, dict.new())
  // The folded hand stays hidden from everyone
  assert engine.visible_hole(s, Some(p1), p2) == None
  assert list.any(events, fn(e) {
    case e {
      event.Custom("hand_over", _) -> True
      _ -> False
    }
  })
}

pub fn a_short_all_in_only_plays_for_what_was_matched_test() {
  // Alice has 300, Bob 1000. Bob shoves, Alice calls all in: Bob's extra
  // 700 comes back and the aces take a 600 pot.
  let s = spot(#(300, 1000), p1, "AS AD", "7C 2D", "3H 8D 9S KC QD")
  let s = play(s, p1, engine.Call)
  let s = play(s, p2, engine.AllIn)
  assert state.to_call(s, p1) == 280
  assert names(s, p1) == ["fold", "call", "resign"]
  let s = play(s, p1, engine.Call)
  assert s.phase == state.HandOver
  assert board(s) == 5
  assert state.stack(s, p1) == 600 && state.stack(s, p2) == 700
  let assert Some(result) = s.last_result
  assert result.winners == [#(p1, 300)]
}

pub fn the_board_runs_out_when_both_are_all_in_test() {
  let s = spot(#(500, 500), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.AllIn)
  assert names(s, p2) == ["fold", "call", "resign"]
  let assert Ok(#(s, events)) = engine.apply(s, p2, engine.Call)
  assert board(s) == 5
  // Aces hold, Bob is felted, the sit-and-go is over
  assert s.phase == state.Finished(Some(p1))
  assert state.stack(s, p1) == 1000 && state.stack(s, p2) == 0
  let assert Some(hand) = s.hand
  assert hand.revealed == [p1, p2]
  // Both hands are face up for everyone at showdown
  assert engine.visible_hole(s, Some(p2), p1) != None
  assert engine.visible_hole(s, None, p2) != None
  assert list.count(events, fn(e) {
      case e {
        event.PhaseChanged(_) -> True
        _ -> False
      }
    })
    >= 4
}

pub fn a_tie_splits_the_pot_test() {
  let s = spot(#(1000, 1000), p1, "2S 3D", "2H 3C", "AS KS QS JS 10S")
  let s = play(s, p1, engine.AllIn)
  let s = play(s, p2, engine.Call)
  assert state.stack(s, p1) == 1000 && state.stack(s, p2) == 1000
  let assert Some(result) = s.last_result
  assert result.won == state.Split
}

pub fn a_sit_and_go_ends_when_a_stack_is_gone_test() {
  let s = spot(#(20, 1980), p2, "7C 2D", "AS AD", "3H 8D 9S KC QD")
  // p2 has the button and posted 10; p1 posted the full 20 and is all in
  assert state.stack(s, p1) == 0
  assert state.to_act(s) == Some(p2)
  let s = play(s, p2, engine.Call)
  assert board(s) == 5
  assert s.phase == state.Finished(Some(p2))
  assert engine.legal(s, p2) == []
  assert state.stack(s, p2) == 2000
}

pub fn blinds_rise_with_the_hands_played_test() {
  let config = state.Config(..sng_config(), hands_per_level: 2)
  let #(s, _) = state.new(config, [#(p1, "Alice"), #(p2, "Bob")], rng.seed(3))
  assert state.blinds(s) == #(10, 20)
  let fold_and_deal = fn(s: GameState) {
    let assert Some(mover) = state.to_act(s)
    let s = play(s, mover, engine.Fold)
    let assert Ok(#(s, happenings)) = state.next_hand(s, p1)
    #(s, happenings)
  }
  let #(s, _) = fold_and_deal(s)
  assert state.blinds(s) == #(10, 20)
  let #(s, happenings) = fold_and_deal(s)
  assert s.hands_played == 2
  assert state.blinds(s) == #(15, 30)
  assert list.contains(happenings, state.LevelUp(1, 15, 30))
  // The last level is the ceiling
  let #(s, _) = fold_and_deal(s)
  let #(s, _) = fold_and_deal(s)
  let #(s, _) = fold_and_deal(s)
  let #(s, _) = fold_and_deal(s)
  assert state.blinds(s) == #(25, 50)
}

pub fn a_cash_game_tops_up_short_stacks_and_tracks_the_net_test() {
  let config =
    state.Config(
      format: state.Cash,
      buy_in: 200,
      top_up: True,
      levels: [#(1, 2)],
      hands_per_level: 0,
    )
  let s = spot_with(config, #(150, 250), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.Raise(60))
  let s = play(s, p2, engine.Fold)
  assert state.stack(s, p1) == 170 && state.stack(s, p2) == 230
  let assert Ok(#(s, happenings)) = state.next_hand(s, p2)
  assert list.contains(happenings, state.ToppedUp(p1, 30))
  // Alice sits with 200 again; she bought 180 in all and is up the 20 she won
  assert state.net(s, p1) == 20
  assert state.net(s, p2) == -20
  // Leaving ends the session in Alice's favour: her big blind is folded
  // to Bob, which does not change who is ahead
  let assert Ok(#(s, _)) = state.leave(s, p1)
  assert s.phase == state.Finished(Some(p1))
  assert state.stack(s, p1) == 198 && state.stack(s, p2) == 232
}

pub fn leaving_a_cash_table_mid_hand_is_a_fold_test() {
  let config =
    state.Config(
      format: state.Cash,
      buy_in: 200,
      top_up: False,
      levels: [#(10, 20)],
      hands_per_level: 0,
    )
  let s = spot_with(config, #(150, 250), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.Raise(60))
  let s = play(s, p2, engine.AllIn)
  // Walking out rather than folding must not get the 60 back
  let assert Ok(#(s, happenings)) = state.leave(s, p1)
  assert s.phase == state.Finished(Some(p2))
  assert state.stack(s, p1) == 90 && state.stack(s, p2) == 310
  assert list.contains(happenings, state.Acted(p1, "fold", 0))
}

pub fn all_in_is_a_call_when_there_is_nothing_to_raise_into_test() {
  // Bob (the button) is all in for 300; Alice may call or fold, not shove 1000
  let s = spot(#(1000, 300), p2, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p2, engine.AllIn)
  assert names(s, p1) == ["fold", "call", "resign"]
  assert state.act(s, p1, state.AllIn)
    == Error("Nothing to raise into: call instead")
}

pub fn nobody_is_asked_to_decide_nothing_after_a_short_call_test() {
  // The button has 15: posts 10 and calls 5 all in. The big blind is owed
  // nothing by an opponent with no chips, so the board runs out at once.
  let s = spot(#(15, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.Call)
  assert state.to_act(s) == None
  assert s.phase == state.HandOver
}

pub fn a_cash_game_without_top_up_ends_when_someone_is_felted_test() {
  let config =
    state.Config(
      format: state.Cash,
      buy_in: 200,
      top_up: False,
      levels: [#(1, 2)],
      hands_per_level: 0,
    )
  let s = spot_with(config, #(100, 100), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  let s = play(s, p1, engine.AllIn)
  let s = play(s, p2, engine.Call)
  assert s.phase == state.Finished(Some(p1))
  assert state.stack(s, p1) == 200 && state.stack(s, p2) == 0
}

pub fn a_timeout_checks_when_it_is_free_and_folds_otherwise_test() {
  let s = spot(#(1000, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  assert engine.timeout(s, p1) == game.Act(engine.Fold)
  assert engine.timeout(s, p2) == game.Forfeit
  let s = play(s, p1, engine.Call)
  assert engine.timeout(s, p2) == game.Act(engine.Check)
  let s = play(s, p2, engine.Check)
  // Flop: Bob bets, Alice is facing a bet again
  let s = play(s, p2, engine.Bet(40))
  let s = play(s, p1, engine.Fold)
  assert s.phase == state.HandOver
  assert engine.timeout(s, p2) == game.Act(engine.Deal)
  assert engine.on_the_clock(s) == [s.next_button]
}

pub fn out_of_turn_and_out_of_range_actions_are_refused_test() {
  let s = spot(#(1000, 1000), p1, "AS AD", "KS KD", "2C 7D 9H 4S JC")
  assert engine.apply(s, p2, engine.Check) == Error("Not your turn")
  assert engine.apply(s, "ghost", engine.Check) == Error("Not at this table")
  assert engine.apply(s, p1, engine.Check) == Error("You must call or fold")
  assert engine.apply(s, p1, engine.Deal) == Error("A hand is in progress")
  let s = play(s, p1, engine.Call)
  assert engine.apply(s, p2, engine.Fold) == Error("Nothing to fold to")
  assert engine.apply(s, p2, engine.Call) == Error("Nothing to call")
}
