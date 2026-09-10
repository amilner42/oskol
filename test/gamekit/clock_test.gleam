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

pub fn move_bank_gives_every_action_fresh_time_and_dips_into_the_bank_test() {
  let c =
    clock.new(clock.MoveBank(5000, 10_000), [a, b])
    |> clock.set_running([a], 0, None)
  // Within the action allowance nothing is charged
  assert clock.remaining(c, a, 4000) == 10_000
  assert clock.next_deadline(c, 0) == Some(15_000)
  // Past it, the bank pays
  assert clock.remaining(c, a, 8000) == 7000
  // a acts at 8000 and is still to act (a new hand): fresh action time,
  // the bank as it was
  let c = clock.set_running(c, [a], 8000, Some(a))
  assert clock.remaining(c, a, 12_000) == 7000
  assert clock.remaining(c, a, 14_000) == 6000
  // b's turn: b has a full bank, a is settled
  let c = clock.set_running(c, [b], 14_000, Some(a))
  assert clock.remaining(c, a, 99_000) == 6000
  assert clock.remaining(c, b, 18_000) == 10_000
  assert clock.remaining(c, b, 20_000) == 9000
}

pub fn move_bank_restarts_the_allowance_when_the_opponent_acts_test() {
  // a (the button) is on the clock between hands; b deals at 3000. a now
  // faces a new decision and gets the full action time again.
  let c =
    clock.new(clock.MoveBank(5000, 10_000), [a, b])
    |> clock.set_running([a], 0, None)
  let c = clock.set_running(c, [a], 3000, Some(b))
  assert clock.remaining(c, a, 8000) == 10_000
  assert clock.remaining(c, a, 9000) == 9000
  assert clock.next_deadline(c, 3000) == Some(15_000)
}

pub fn move_bank_expires_only_when_action_time_and_bank_are_both_gone_test() {
  let c =
    clock.new(clock.MoveBank(5000, 3000), [a, b])
    |> clock.set_running([a], 0, None)
  assert clock.expired(c, 7999) == []
  assert clock.expired(c, 8000) == [a]
  // An empty bank still leaves the action time for the next action
  let c = clock.set_running(c, [a], 8000, Some(a))
  assert clock.remaining(c, a, 8000) == 0
  assert clock.expired(c, 12_999) == []
  assert clock.expired(c, 13_000) == [a]
  assert clock.next_deadline(c, 8000) == Some(5000)
}

// ---------- a game's turn delay (backgammon's twelve seconds) ----------

const delay = 12_000

pub fn a_turn_delay_leaves_no_clock_alone_test() {
  let c =
    clock.new(clock.NoClock, [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  assert clock.enabled(c) == False
  assert clock.next_deadline(c, 0) == None
  assert clock.expired(c, 999_999) == []
}

pub fn a_turn_delay_is_free_time_before_a_fischer_bank_test() {
  let c =
    clock.new(clock.Fischer(10_000, 2000), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  // Nothing is charged inside the delay, however long the turn takes to
  // start moving.
  assert clock.remaining(c, a, 11_999) == 10_000
  assert clock.remaining(c, a, 12_000) == 10_000
  assert clock.remaining(c, a, 15_000) == 7000
  assert clock.next_deadline(c, 0) == Some(22_000)
  assert clock.expired(c, 21_999) == []
  assert clock.expired(c, 22_000) == [a]
}

pub fn an_unused_turn_delay_is_never_banked_test() {
  let c =
    clock.new(clock.Fischer(10_000, 0), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  // a moves after two seconds: the ten unused seconds of delay evaporate.
  let c = clock.set_running(c, [b], 2000, Some(a))
  assert clock.remaining(c, a, 99_999) == 10_000
  // ...and the next turn gets its own fresh twelve, not twenty-two.
  let c = clock.set_running(c, [a], 3000, Some(b))
  assert clock.remaining(c, a, 15_000) == 10_000
  assert clock.remaining(c, a, 16_000) == 9000
}

pub fn a_turn_delay_and_a_bronstein_delay_overlap_test() {
  // The longer of the two wins; they do not stack.
  let short =
    clock.new(clock.Bronstein(10_000, 3000), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  assert clock.remaining(short, a, 12_000) == 10_000
  assert clock.remaining(short, a, 13_000) == 9000
  let long =
    clock.new(clock.Bronstein(10_000, 20_000), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  assert clock.remaining(long, a, 20_000) == 10_000
  assert clock.remaining(long, a, 21_000) == 9000
}

pub fn a_turn_delay_precedes_a_per_move_allowance_test() {
  let c =
    clock.new(clock.PerMove(5000), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 12_000) == 5000
  assert clock.remaining(c, a, 14_000) == 3000
  assert clock.expired(c, 16_999) == []
  assert clock.expired(c, 17_000) == [a]
  // The next turn starts the pair over again
  let c = clock.set_running(c, [b], 8000, Some(a))
  let c = clock.set_running(c, [a], 9000, Some(b))
  assert clock.remaining(c, a, 21_000) == 5000
  assert clock.remaining(c, a, 23_000) == 3000
}

pub fn a_turn_delay_takes_over_a_shorter_move_bank_allowance_test() {
  let c =
    clock.new(clock.MoveBank(5000, 10_000), [a, b])
    |> clock.with_turn_delay(delay)
    |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 12_000) == 10_000
  assert clock.remaining(c, a, 14_000) == 8000
  assert clock.next_deadline(c, 0) == Some(22_000)
  // Acting again restarts the free time at the longer of the two
  let c = clock.set_running(c, [a], 14_000, Some(a))
  assert clock.remaining(c, a, 26_000) == 8000
  assert clock.remaining(c, a, 27_000) == 7000
}

pub fn a_negative_turn_delay_is_no_delay_test() {
  let c =
    clock.new(clock.Fischer(10_000, 0), [a, b])
    |> clock.with_turn_delay(-5000)
    |> clock.set_running([a], 0, None)
  assert clock.remaining(c, a, 1000) == 9000
}

pub fn the_clock_label_names_the_turn_delay_test() {
  let c = clock.new(clock.Fischer(180_000, 2000), [a, b])
  assert clock.label(c) == "3 min + 2 s"
  assert clock.label(clock.with_turn_delay(c, delay))
    == "3 min + 2 s, 12 s delay every turn"
  assert clock.label(clock.with_turn_delay(clock.new(clock.NoClock, [a]), delay))
    == "No clock"
}

pub fn poker_presets_exist_test() {
  let assert Ok(p) = clock.preset("poker")
  assert clock.control_label(p.control) == "20 s per action + 60 s bank"
  let assert Ok(_) = clock.preset("poker_fast")
  let assert Ok(_) = clock.preset("poker_slow")
}

pub fn presets_start_with_none_test() {
  let assert [first, ..] = clock.presets()
  assert first.id == "none"
  let assert Ok(blitz) = clock.preset("blitz")
  assert clock.control_label(blitz.control) == "3 min + 2 s"
}
