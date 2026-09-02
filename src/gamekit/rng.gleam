//// Deterministic pseudo-random number generator.
////
//// Games must never call `int.random` or `list.shuffle` directly. All
//// randomness flows through an `Rng` value that lives inside game state, so a
//// game is fully determined by its seed plus its action log. That is what makes
//// replays, property tests, and bug repros possible.
////
//// The generator is xorshift32, masked to 32 bits so it behaves identically on
//// the Erlang and JavaScript targets.

import gleam/int
import gleam/list

pub opaque type Rng {
  Rng(state: Int)
}

const mask32 = 0xFFFFFFFF

/// Create a generator from an integer seed. Any integer works; zero is
/// remapped because xorshift cannot leave the zero state.
pub fn seed(seed: Int) -> Rng {
  let s = int.bitwise_and(int.absolute_value(seed), mask32)
  case s {
    0 -> Rng(0x9E3779B9)
    _ -> Rng(s)
  }
}

/// Advance the generator and return the next raw 32-bit value.
pub fn next(rng: Rng) -> #(Int, Rng) {
  let x = rng.state
  let x =
    int.bitwise_and(
      int.bitwise_exclusive_or(x, int.bitwise_shift_left(x, 13)),
      mask32,
    )
  let x = int.bitwise_exclusive_or(x, int.bitwise_shift_right(x, 17))
  let x =
    int.bitwise_and(
      int.bitwise_exclusive_or(x, int.bitwise_shift_left(x, 5)),
      mask32,
    )
  #(x, Rng(x))
}

/// Integer in the range `0..max-1`. Returns 0 when `max <= 0`.
pub fn int(rng: Rng, max: Int) -> #(Int, Rng) {
  case max <= 0 {
    True -> #(0, rng)
    False -> {
      let #(x, next_rng) = next(rng)
      #(x % max, next_rng)
    }
  }
}

/// True with probability `numerator / denominator`.
pub fn chance(rng: Rng, numerator: Int, denominator: Int) -> #(Bool, Rng) {
  let #(x, next_rng) = int(rng, denominator)
  #(x < numerator, next_rng)
}

/// Fisher-Yates shuffle over a list.
pub fn shuffle(rng: Rng, items: List(a)) -> #(List(a), Rng) {
  do_shuffle(rng, items, list.length(items), [])
}

fn do_shuffle(
  rng: Rng,
  remaining: List(a),
  count: Int,
  acc: List(a),
) -> #(List(a), Rng) {
  case count {
    0 -> #(acc, rng)
    _ -> {
      let #(index, next_rng) = int(rng, count)
      let #(picked, rest) = remove_at(remaining, index)
      do_shuffle(next_rng, rest, count - 1, [picked, ..acc])
    }
  }
}

fn remove_at(items: List(a), index: Int) -> #(a, List(a)) {
  let before = list.take(items, index)
  case list.drop(items, index) {
    [picked, ..after] -> #(picked, list.append(before, after))
    [] -> panic as "rng.remove_at: index out of range"
  }
}

/// Pick one element uniformly. Errors on an empty list.
pub fn pick(rng: Rng, items: List(a)) -> Result(#(a, Rng), Nil) {
  case items {
    [] -> Error(Nil)
    _ -> {
      let #(index, next_rng) = int(rng, list.length(items))
      case list.drop(items, index) {
        [picked, ..] -> Ok(#(picked, next_rng))
        [] -> Error(Nil)
      }
    }
  }
}

/// Weighted pick. Each item carries a positive integer weight.
pub fn weighted(rng: Rng, items: List(#(a, Int))) -> Result(#(a, Rng), Nil) {
  let total = list.fold(items, 0, fn(acc, item) { acc + item.1 })
  case total <= 0 {
    True -> Error(Nil)
    False -> {
      let #(roll, next_rng) = int(rng, total)
      Ok(#(find_weighted(items, roll), next_rng))
    }
  }
}

fn find_weighted(items: List(#(a, Int)), roll: Int) -> a {
  case items {
    [#(item, weight)] -> {
      let _ = weight
      item
    }
    [#(item, weight), ..rest] ->
      case roll < weight {
        True -> item
        False -> find_weighted(rest, roll - weight)
      }
    [] -> panic as "rng.weighted: empty list"
  }
}

/// Split off an independent generator, useful for per-player streams.
pub fn split(rng: Rng) -> #(Rng, Rng) {
  let #(a, rng1) = next(rng)
  let #(b, rng2) = next(rng1)
  #(seed(int.bitwise_exclusive_or(a, int.bitwise_shift_left(b, 7))), rng2)
}

/// Draw `count` items from a list without replacement.
pub fn sample(rng: Rng, items: List(a), count: Int) -> #(List(a), Rng) {
  let #(shuffled, next_rng) = shuffle(rng, items)
  #(list.take(shuffled, count), next_rng)
}
