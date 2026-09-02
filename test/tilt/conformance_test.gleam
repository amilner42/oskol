import gamekit/conformance
import gamekit/game.{Seat}
import gamekit/rng
import gleam/list
import tilt/game as tilt
import tilt/player
import tilt/state.{type GameState}

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

/// Invariants that must hold after every action
fn invariant(state: GameState) -> Result(Nil, String) {
  list.try_each(state.players_in_order(state), fn(p) {
    let all = player.get_all_cards(p)
    let ids = list.map(all, fn(c) { c.id })
    case
      list.length(p.card_piles.hand) <= player.hand_size,
      list.length(list.unique(ids)) == list.length(ids),
      p.lives >= 0 && p.lives <= state.config.initial_lives,
      p.hands_remaining >= 0
      && p.hands_remaining <= state.config.hands_per_round,
      p.discards_remaining >= 0
    {
      True, True, True, True, True -> Ok(Nil)
      False, _, _, _, _ -> Error("hand larger than " <> "8")
      _, False, _, _, _ -> Error("duplicate card ids")
      _, _, False, _, _ -> Error("lives out of range")
      _, _, _, False, _ -> Error("hands_remaining out of range")
      _, _, _, _, False -> Error("negative discards")
    }
  })
}

pub fn random_playouts_terminate_test() {
  list.each(list.range(1, 30), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout(
        tilt.game(),
        "short",
        seats(),
        seed,
        3000,
        invariant,
      )
    assert report.finished
    assert report.state.phase == state.Finished
  })
}

pub fn standard_format_playouts_terminate_test() {
  list.each(list.range(100, 110), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout(
        tilt.game(),
        "standard",
        seats(),
        seed,
        6000,
        invariant,
      )
    assert report.finished
  })
}

pub fn replay_reproduces_the_same_state_test() {
  list.each([5, 17, 23], fn(seed) {
    let assert Ok(report) =
      conformance.random_playout(
        tilt.game(),
        "short",
        seats(),
        seed,
        3000,
        invariant,
      )
    let assert Ok(replayed) =
      conformance.replay(tilt.game(), "short", seats(), seed, report.steps)
    assert conformance.fingerprint(tilt.game(), replayed, seats())
      == conformance.fingerprint(tilt.game(), report.state, seats())
  })
}

pub fn malformed_actions_are_rejected_test() {
  let assert Ok(format) = game.find_format(tilt.info(), "short")
  let assert Ok(state) = tilt.init(format.config, seats(), rng.seed(1))
  assert conformance.apply_json(tilt.game(), state, "p1", "{\"name\":\"fly\"}")
    == Error(
      "Legal action rejected (Unknown action: fly): p1 {\"name\":\"fly\"}",
    )
    || conformance.apply_json(tilt.game(), state, "p1", "{\"name\":\"fly\"}")
    != Ok(state)
  let assert Error(_) =
    conformance.apply_json(
      tilt.game(),
      state,
      "p1",
      "{\"name\":\"play_hand\",\"params\":{\"cards\":[\"zz\"]}}",
    )
  let assert Error(_) =
    conformance.apply_json(tilt.game(), state, "p1", "not json")
  let assert Error(_) =
    conformance.apply_json(
      tilt.game(),
      state,
      "ghost",
      "{\"name\":\"discard\",\"params\":{\"cards\":[]}}",
    )
}
