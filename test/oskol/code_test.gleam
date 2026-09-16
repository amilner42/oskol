import gleam/list
import gleam/string
import oskol/rooms/code

pub fn a_code_is_six_characters_of_the_alphabet_test() {
  assert code.from_random(0) == "000000"
  assert code.from_random(1234) == "00016J"
  assert code.from_random(31) == "00000Z"
  assert code.from_random(32) == "000010"
}

pub fn a_code_wraps_into_the_space_test() {
  assert code.from_random(code.space()) == "000000"
  assert code.from_random(code.space() + 31) == "00000Z"
  assert string.length(code.from_random(18_446_744_073_709_551_615)) == 6
}

pub fn the_alphabet_drops_the_four_lookalikes_test() {
  // Crockford's: no I, no L, no O, no U, so nothing read down the phone is
  // ambiguous. Every digit stays, which is why the six-digit codes minted
  // before this are still codes.
  assert string.length(code.alphabet) == 32
  assert string.contains(code.alphabet, "I") == False
  assert string.contains(code.alphabet, "L") == False
  assert string.contains(code.alphabet, "O") == False
  assert string.contains(code.alphabet, "U") == False
  assert string.contains(code.alphabet, "0123456789")
}

pub fn every_code_is_six_characters_of_the_alphabet_test() {
  let letters = string.to_graphemes(code.alphabet)

  assert list.all(list.range(0, 200), fn(n) {
    let minted = code.from_random(n * 7_919_311)
    string.length(minted) == 6
    && list.all(string.to_graphemes(minted), list.contains(letters, _))
  })
}

pub fn a_typed_code_is_normalised_before_it_is_looked_up_test() {
  // What a friend reads down the phone, however it is typed back.
  assert code.normalise("abc123") == "ABC123"
  assert code.normalise("O0oO") == "0000"
  assert code.normalise("IlL1") == "1111"
  assert code.normalise("uU") == "VV"
  assert code.normalise("000001") == "000001"
}
