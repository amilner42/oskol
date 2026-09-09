import gleam/string
import oskol/rooms/name

pub fn a_plain_name_is_kept_test() {
  assert name.clean("Alice") == Ok("Alice")
}

pub fn a_name_is_trimmed_test() {
  assert name.clean("  Alice \n") == Ok("Alice")
}

pub fn an_empty_name_is_refused_test() {
  assert name.clean("") == Error("Pick a display name first")
  assert name.clean("   ") == Error("Pick a display name first")
}

pub fn a_long_name_is_refused_test() {
  // 24 graphemes is the limit, 25 is one too many.
  assert name.clean("123456789012345678901234")
    == Ok("123456789012345678901234")
  assert name.clean("1234567890123456789012345")
    == Error("Names are 24 characters at most")
}

pub fn the_limit_counts_graphemes_not_bytes_test() {
  // 24 two-byte characters is 48 bytes and still a legal name.
  let just_long_enough = string.repeat("é", 24)
  let one_too_many = string.repeat("é", 25)

  assert name.clean(just_long_enough) == Ok(just_long_enough)
  assert name.clean(one_too_many) == Error("Names are 24 characters at most")
  assert name.clean("Renée") == Ok("Renée")
}

pub fn control_characters_are_refused_test() {
  assert name.clean("Ali\u{0000}ce") == Error("Invalid name")
  assert name.clean("Ali\nce") == Error("Invalid name")
  // A right-to-left override could make a name lie about itself.
  assert name.clean("Ali\u{202E}ce") == Error("Invalid name")
  // Private use.
  assert name.clean("Ali\u{E000}ce") == Error("Invalid name")
}

pub fn ordinary_unicode_is_fine_test() {
  assert name.clean("Ali ce") == Ok("Ali ce")
  assert name.clean("日本") == Ok("日本")
  assert name.clean("Zoë-Ann") == Ok("Zoë-Ann")
}
