//// A context of stubs. Every capability panics, so a handler test that
//// reaches IO it did not arrange for fails loudly, and each test overrides
//// only the caps its branch is supposed to use.

import gleam/dynamic
import gleam/option.{type Option, Some}
import oskol/caps/copy as copy_caps
import oskol/caps/guests as guests_caps
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/session.{type Session, Session}
import oskol/landing/copy as prose
import oskol/rooms/room.{type Room, Room}

pub fn ctx() -> Ctx {
  Ctx(
    copy: copy_caps.stub(),
    guests: guests_caps.stub(),
    ids: ids_caps.stub(),
    persistence: persistence_caps.stub(),
    rooms: rooms_caps.stub(),
  )
}

/// A stand-in for a live room process.
pub fn room() -> Room {
  Room(process: dynamic.string("a room"))
}

pub fn guest(id: String) -> Session {
  Session(guest_id: Some(id))
}

pub fn no_guest() -> Session {
  session.anonymous()
}

/// Exactly 22 characters, like a real minted guest id.
pub const minted_id = "abcdefghijklmnopqrstuv"

/// Guest caps: `remembered` is the name the row holds, and saving a name
/// succeeds silently (as it does in production, where every write rescues).
pub fn with_guests(ctx: Ctx, remembered: Option(String)) -> Ctx {
  Ctx(
    ..ctx,
    guests: guests_caps.GuestsCaps(
      mint: fn() { minted_id },
      touch: fn(_) { remembered },
      save_name: fn(_, _) { Nil },
    ),
  )
}

/// Copy caps that answer with one fixed set of words.
pub fn with_copy(ctx: Ctx, words: prose.Copy) -> Ctx {
  Ctx(
    ..ctx,
    copy: copy_caps.CopyCaps(
      site: fn() {
        prose.Site(title: "Two-player games from a link", description: "Free")
      },
      for_game: fn(_) { words },
    ),
  )
}

pub fn sample_copy() -> prose.Copy {
  prose.Copy(
    title: "Play backgammon online with a friend",
    description: "Backgammon for two, free, no accounts.",
    intro: "The race game with the doubling cube.",
    rules: ["Fifteen checkers each.", "Bear them all off."],
    faq: [#("Do we need accounts?", "No.")],
  )
}
