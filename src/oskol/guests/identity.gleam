//// Silent guest identity. Every visitor gets an opaque id in a year-long
//// cookie and a row the site uses only to remember the name they last
//// played under. The id authenticates nothing: losing it costs a prefilled
//// form and nothing else.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oskol/core/ctx.{type Ctx}
import oskol/core/session.{type Session}

/// 16 crypto-random bytes, URL-safe base64, unpadded: exactly 22 chars.
pub const id_length = 22

const id_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

/// The id this request carries: the cookie's, when it is one we minted, or
/// a fresh one. A mangled cookie is replaced, never trusted.
pub fn for_request(ctx: Ctx, cookie: Option(String)) -> String {
  case cookie {
    Some(id) ->
      case valid_id(id) {
        True -> id
        False -> ctx.guests.mint()
      }
    None -> ctx.guests.mint()
  }
}

pub fn valid_id(id: String) -> Bool {
  let characters = string.to_graphemes(id)

  list.length(characters) == id_length
  && list.all(characters, string.contains(id_alphabet, _))
}

/// The name this visitor last played under, if the site remembers them.
/// Touching the row is what keeps a returning guest alive.
pub fn remembered_name(ctx: Ctx, session: Session) -> Option(String) {
  case session.guest_id {
    Some(id) -> ctx.guests.touch(id)
    None -> None
  }
}

/// A seat was taken under this name: remember it, so the next create or
/// join form is prefilled with it.
pub fn remember(ctx: Ctx, session: Session, name: String) -> Nil {
  case session.guest_id {
    Some(id) -> ctx.guests.save_name(id, name)
    None -> Nil
  }
}
