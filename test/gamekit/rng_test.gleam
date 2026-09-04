import gamekit/rng
import gleam/int
import gleam/list

pub fn same_seed_same_sequence_test() {
  let #(xs, _) = take(rng.seed(42), 20)
  let #(ys, _) = take(rng.seed(42), 20)
  assert xs == ys
}

pub fn different_seeds_differ_test() {
  let #(xs, _) = take(rng.seed(1), 10)
  let #(ys, _) = take(rng.seed(2), 10)
  assert xs != ys
}

pub fn zero_seed_is_usable_test() {
  let #(xs, _) = take(rng.seed(0), 5)
  assert list.length(list.unique(xs)) > 1
}

pub fn int_stays_in_range_test() {
  let #(values, _) =
    list.fold(list.range(1, 500), #([], rng.seed(9)), fn(acc, _) {
      let #(vs, r) = acc
      let #(v, r) = rng.int(r, 13)
      #([v, ..vs], r)
    })
  assert list.all(values, fn(v) { v >= 0 && v < 13 })
  assert list.any(values, fn(v) { v == 0 })
  assert list.any(values, fn(v) { v == 12 })
}

pub fn shuffle_is_a_permutation_test() {
  let items = list.range(1, 52)
  let #(shuffled, _) = rng.shuffle(rng.seed(7), items)
  assert list.sort(shuffled, int.compare) == items
  assert shuffled != items
}

pub fn sample_takes_distinct_items_test() {
  let #(picked, _) = rng.sample(rng.seed(11), list.range(1, 52), 8)
  assert list.length(picked) == 8
  assert list.length(list.unique(picked)) == 8
}

pub fn weighted_respects_zero_weight_test() {
  let items = [#("never", 0), #("always", 5)]
  let #(picks, _) =
    list.fold(list.range(1, 50), #([], rng.seed(3)), fn(acc, _) {
      let #(ps, r) = acc
      let assert Ok(#(p, r)) = rng.weighted(r, items)
      #([p, ..ps], r)
    })
  assert list.all(picks, fn(p) { p == "always" })
}

fn take(r: rng.Rng, n: Int) -> #(List(Int), rng.Rng) {
  list.fold(list.range(1, n), #([], r), fn(acc, _) {
    let #(xs, r) = acc
    let #(x, r) = rng.next(r)
    #([x, ..xs], r)
  })
}
