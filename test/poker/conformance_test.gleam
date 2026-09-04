//// Poker through the contract: random play never breaks the chip count,
//// sit-and-gos end, replays are exact, and hole cards stay hidden until a
//// showdown, in scenes and in events.

import gamekit/conformance
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import poker/engine
import poker/game as poker
import poker/state.{type GameState}

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

fn other(id: String) -> String {
  case id {
    "p1" -> "p2"
    _ -> "p1"
  }
}

/// Chips never appear or vanish: stacks plus the pot equal what was bought in.
fn chips_conserved(s: GameState) -> Result(Nil, String) {
  let stacks = dict.values(s.stacks) |> int.sum
  let in_pot = case s.phase, s.hand {
    state.Betting, Some(hand) -> state.pot(hand)
    _, _ -> 0
  }
  let invested = dict.values(s.invested) |> int.sum
  case
    stacks + in_pot == invested,
    list.all(dict.values(s.stacks), fn(n) { n >= 0 })
  {
    True, True -> Ok(Nil)
    False, _ ->
      Error(
        "chips changed: stacks "
        <> int.to_string(stacks)
        <> " + pot "
        <> int.to_string(in_pot)
        <> " != invested "
        <> int.to_string(invested),
      )
    _, False -> Error("a stack went negative")
  }
}

/// Hole cards are a count to everyone but their holder until shown.
fn scenes_keep_secrets(s: GameState) -> Result(Nil, String) {
  let g = poker.game()
  list.try_each(s.order, fn(me) {
    let revealed = case s.hand {
      Some(hand) -> list.contains(hand.revealed, me)
      _ -> False
    }
    list.try_each([scene.Player(other(me)), scene.Spectator], fn(viewer) {
      let sc = g.scene(s, viewer)
      let assert Ok(zone) = scene.find_zone(sc, engine.hole_zone(me))
      let assert Ok(deck) = scene.find_zone(sc, engine.deck_zone)
      case zone.tokens, revealed, deck.tokens {
        [], _, [] -> Ok(Nil)
        _, True, [] -> Ok(Nil)
        _, False, _ -> Error("hole cards of " <> me <> " are visible")
        _, _, _ -> Error("the deck is visible")
      }
    })
  })
}

fn invariant(s: GameState) -> Result(Nil, String) {
  use _ <- result.try(chips_conserved(s))
  scenes_keep_secrets(s)
}

/// The opponent's events never name a hole card that was not shown.
fn events_keep_secrets(
  _before: GameState,
  actor: String,
  action_json: String,
  after: GameState,
  events: List(event.Event),
) -> Result(Nil, String) {
  let g = poker.game()
  list.try_each(after.order, fn(me) {
    let secret = case engine.visible_hole(after, Some(other(me)), me) {
      Some(_) -> []
      None -> list.map(state.hole_cards(after, me), fn(c) { c.id })
    }
    list.try_each([scene.Player(other(me)), scene.Spectator], fn(viewer) {
      let visible = event.for_viewer(events, g.scene(after, viewer))
      let text = json.to_string(json.array(visible, event.to_json))
      case
        list.find(secret, fn(id) { string.contains(text, "\"" <> id <> "\"") })
      {
        Ok(id) ->
          Error(
            "after "
            <> actor
            <> " "
            <> action_json
            <> ": "
            <> id
            <> " leaked in "
            <> text,
          )
        Error(_) -> Ok(Nil)
      }
    })
  })
}

pub fn sit_and_gos_end_with_every_chip_accounted_for_test() {
  list.each(list.range(1, 12), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        poker.game(),
        "sng",
        seats(),
        seed,
        20_000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
    let assert state.Finished(Some(winner)) = report.state.phase
    assert state.stack(report.state, winner) == 3000
    assert state.stack(report.state, other(winner)) == 0
  })
}

pub fn cash_games_go_on_and_keep_the_chip_count_test() {
  list.each(list.range(1, 6), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        poker.game(),
        "cash",
        seats(),
        seed,
        1500,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished == False
    assert list.length(report.steps) == 1500
  })
}

pub fn hole_cards_never_leak_in_events_test() {
  list.each(list.range(1, 6), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        poker.game(),
        "sng",
        seats(),
        seed,
        1000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    let assert Ok(_) =
      conformance.walk(
        poker.game(),
        "sng",
        seats(),
        seed,
        report.steps,
        events_keep_secrets,
      )
  })
}

pub fn replay_reproduces_the_same_state_test() {
  list.each([4, 9], fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        poker.game(),
        "sng",
        seats(),
        seed,
        20_000,
        invariant,
        conformance.Options(exclude: ["resign"]),
      )
    let assert Ok(replayed) =
      conformance.replay(poker.game(), "sng", seats(), seed, report.steps)
    assert conformance.fingerprint(poker.game(), replayed, seats())
      == conformance.fingerprint(poker.game(), report.state, seats())
  })
}

pub fn settings_shape_the_game_test() {
  let assert Ok(cash) = game.find_format(poker.info(), "cash")
  let assert Ok(config) =
    game.configure(
      cash,
      dict.from_list([#("stake", "5-10"), #("top_up", "no")]),
    )
  let assert Ok(s) = poker.init(config, seats(), rng.seed(1))
  assert state.blinds(s) == #(5, 10)
  assert s.config.buy_in == 1000 && s.config.top_up == False
  let assert Ok(sng) = game.find_format(poker.info(), "sng")
  let assert Ok(config) =
    game.configure(sng, dict.from_list([#("speed", "hyper")]))
  let assert Ok(s) = poker.init(config, seats(), rng.seed(1))
  assert s.config.hands_per_level == 3 && s.config.buy_in == 1500
  assert s.config.levels == poker.levels
  let assert Ok(config) =
    game.configure(sng, dict.from_list([#("speed", "turbo")]))
  let assert Ok(s) = poker.init(config, seats(), rng.seed(1))
  assert s.config.hands_per_level == 6
  let assert Ok(config) = game.configure(sng, dict.new())
  let assert Ok(s) = poker.init(config, seats(), rng.seed(1))
  assert s.config.hands_per_level == 10
  assert game.configure(sng, dict.from_list([#("speed", "ludicrous")]))
    == Error("Unknown Speed: ludicrous")
}

pub fn malformed_actions_are_rejected_test() {
  let assert Ok(format) = game.find_format(poker.info(), "sng")
  let assert Ok(s) =
    poker.init(game.default_config(format), seats(), rng.seed(1))
  let assert Some(mover) = state.to_act(s)
  let assert Error(_) =
    conformance.apply_json(poker.game(), s, mover, "{\"name\":\"raise\"}")
  let assert Error(_) =
    conformance.apply_json(
      poker.game(),
      s,
      mover,
      "{\"name\":\"raise\",\"params\":{\"amount\":\"lots\"}}",
    )
  let assert Error(_) =
    conformance.apply_json(poker.game(), s, mover, "{\"name\":\"bluff\"}")
  let assert Error(_) =
    conformance.apply_json(
      poker.game(),
      s,
      other(mover),
      "{\"name\":\"check\"}",
    )
}
