import gamekit/clock
import gleam/option.{None, Some}

const a = "a"

const b = "b"

pub fn no_clock_never_expires_test() {
  let c = clock.new(clock.NoClock, [a, b]) |> clock.set_running([a], 0, None)
  assert clock.enabled(c) == False
  assert clock.expired(c, 1_000_000) == []
  assert clock.next_deadline(c, 0) == None
}

pub fn fischer_charges_running_player_and_credits_increment_test() {
  let c =
    clock.new(clock.Fischer(10_000, 2000), [a, b])
    |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 4000) == 6000
  assert clock.remaining(c, b, 4000) == 10_000
  // a moves at t=4000: a stops (+2000), b starts
  let c = clock.set_running(c, [b], 4000, Some(a))
  assert clock.remaining(c, a, 9000) == 8000
  assert clock.remaining(c, b, 9000) == 5000
  assert clock.running(c, a) == False
  assert clock.running(c, b)
}

pub fn increment_only_for_the_actor_test() {
  // Both clocks run (simultaneous play); b's action stops a's clock too.
  let c =
    clock.new(clock.Fischer(10_000, 2000), [a, b])
    |> clock.set_running([a, b], 0, None)
  let c = clock.set_running(c, [], 1000, Some(b))
  assert clock.remaining(c, a, 5000) == 9000
  assert clock.remaining(c, b, 5000) == 11_000
}

pub fn bronstein_delay_is_free_but_not_banked_test() {
  let c =
    clock.new(clock.Bronstein(10_000, 3000), [a, b])
    |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 2000) == 10_000
  assert clock.remaining(c, a, 5000) == 8000
  let c = clock.set_running(c, [b], 5000, Some(a))
  assert clock.remaining(c, a, 99_000) == 8000
  // Next move gets a fresh delay
  let c = clock.set_running(c, [a], 6000, Some(b))
  assert clock.remaining(c, a, 8000) == 8000
  assert clock.remaining(c, a, 10_000) == 7000
}

pub fn per_move_resets_each_turn_test() {
  let c =
    clock.new(clock.PerMove(5000), [a, b]) |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 4000) == 1000
  let c = clock.set_running(c, [b], 4000, Some(a))
  let c = clock.set_running(c, [a], 4500, Some(b))
  assert clock.remaining(c, a, 4500) == 5000
}

pub fn expiry_and_deadline_test() {
  let c =
    clock.new(clock.Fischer(3000, 0), [a, b]) |> clock.set_running([a], 0, None)
  assert clock.next_deadline(c, 1000) == Some(2000)
  assert clock.expired(c, 2999) == []
  assert clock.expired(c, 3000) == [a]
  let assert Some(#(loser, stopped)) = clock.expire(c, 3500)
  assert loser == a
  assert stopped.timed_out == Some(a)
  assert clock.remaining(stopped, a, 10_000) == 0
  assert clock.running(stopped, a) == False
  // Nothing more happens once someone timed out
  assert clock.expire(stopped, 20_000) == None
  assert clock.set_running(stopped, [b], 20_000, None) == stopped
}

pub fn paused_clocks_do_not_tick_test() {
  let c =
    clock.new(clock.Fischer(3000, 0), [a, b]) |> clock.set_running([], 0, None)
  assert clock.next_deadline(c, 0) == None
  assert clock.remaining(c, a, 999_999) == 3000
}

pub fn presets_start_with_none_test() {
  let assert [first, ..] = clock.presets()
  assert first.id == "none"
  let assert Ok(blitz) = clock.preset("blitz")
  assert clock.control_label(blitz.control) == "3 min + 2 s"
}
