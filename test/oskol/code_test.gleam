import gleam/string
import oskol/rooms/code

pub fn a_code_is_six_digits_test() {
  assert code.from_random(1234) == "001234"
  assert code.from_random(0) == "000000"
  assert code.from_random(999_999) == "999999"
}

pub fn a_code_wraps_into_the_space_test() {
  assert code.from_random(1_000_000) == "000000"
  assert code.from_random(1_000_042) == "000042"
  assert code.from_random(18_446_744_073_709_551_615) == "551615"
}

pub fn every_code_is_six_characters_long_test() {
  assert list_every(0, 60, fn(n) {
    string.length(code.from_random(n * 7919)) == 6
  })
}

fn list_every(from: Int, to: Int, predicate: fn(Int) -> Bool) -> Bool {
  case from >= to {
    True -> True
    False ->
      case predicate(from) {
        True -> list_every(from + 1, to, predicate)
        False -> False
      }
  }
}
