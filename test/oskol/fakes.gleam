//// A context of stubs. Every capability panics, so a handler test that
//// reaches IO it did not arrange for fails loudly, and each test overrides
//// only the caps its branch is supposed to use.

import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/order
import gleam/result
import gleam/string
import oskol/caps/analysis as analysis_caps
import oskol/caps/auth as auth_caps
import oskol/caps/copy as copy_caps
import oskol/caps/guests as guests_caps
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/practice as practice_caps
import oskol/caps/puzzles as puzzles_caps
import oskol/caps/records as records_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/session.{type Session, Session}
import oskol/landing/copy as prose
import oskol/rooms/room.{type Room, Room}

pub fn ctx() -> Ctx {
  Ctx(
    analysis: analysis_caps.stub(),
    auth: auth_caps.stub(),
    copy: copy_caps.stub(),
    guests: guests_caps.stub(),
    ids: ids_caps.stub(),
    persistence: persistence_caps.stub(),
    practice: practice_caps.stub(),
    puzzles: puzzles_caps.stub(),
    records: records_caps.stub(),
    rooms: rooms_caps.stub(),
  )
}

/// A stand-in for a live room process.
pub fn room() -> Room {
  Room(process: dynamic.string("a room"))
}

/// Room caps that answer a lookup and a table read. Everything a room can
/// be asked to *do* still panics.
pub fn with_room(
  ctx: Ctx,
  found: Option(Room),
  table: Option(room.Table),
) -> Ctx {
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      find: fn(_) { found },
      resume: fn(_) { option.None },
      table: fn(_) { table },
    ),
  )
}

pub fn with_slug(ctx: Ctx, slug: Option(String)) -> Ctx {
  Ctx(..ctx, rooms: rooms_caps.RoomsCaps(..ctx.rooms, slug_of: fn(_) { slug }))
}

/// Persistence caps that answer one room's row, or none.
pub fn with_row(ctx: Ctx, row: option.Option(room.ActiveRoom)) -> Ctx {
  Ctx(
    ..ctx,
    persistence: persistence_caps.PersistenceCaps(
      ..ctx.persistence,
      room: fn(_) { row },
    ),
  )
}

/// Persistence caps that answer which rooms a guest holds a seat in.
pub fn with_active_rooms(ctx: Ctx, rooms: List(room.ActiveRoom)) -> Ctx {
  Ctx(
    ..ctx,
    persistence: persistence_caps.PersistenceCaps(
      ..ctx.persistence,
      seated_rooms: fn(_, _) { rooms },
    ),
  )
}

pub fn guest(id: String) -> Session {
  Session(guest_id: Some(id), user_id: option.None)
}

/// A browser signed in: its guest cookie, and the account on it.
pub fn signed_in(id: String, user_id: String) -> Session {
  Session(guest_id: Some(id), user_id: Some(user_id))
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
      prefs: fn(_) { [] },
      save_pref: fn(_, _, _) { Nil },
    ),
  )
}

/// Guest caps for the preference endpoints: `kept` is what the row holds,
/// and a write is only allowed to be the pair the test expects — anything
/// else panics, so a handler that mangles a key or a value fails loudly
/// instead of writing quietly.
pub fn with_prefs(
  ctx: Ctx,
  kept: List(#(String, String)),
  expected: #(String, String),
) -> Ctx {
  Ctx(
    ..ctx,
    guests: guests_caps.GuestsCaps(
      mint: fn() { minted_id },
      touch: fn(_) { option.None },
      save_name: fn(_, _) { Nil },
      prefs: fn(_) { kept },
      save_pref: fn(_, key, value) {
        case #(key, value) == expected {
          True -> Nil
          False ->
            panic as "guests.save_pref got a pair the test did not expect"
        }
      },
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
    description: "Backgammon for two, free, no account needed.",
    intro: "The race game with the doubling cube.",
    rules: ["Fifteen checkers each.", "Bear them all off."],
    faq: [#("Do we need accounts?", "No.")],
  )
}

/// Records caps over one room: what started it (None when nothing was ever
/// written down for it) and the record rows it has. A save is dropped.
pub fn with_records(
  ctx: Ctx,
  setup: Option(records_caps.Setup),
  rows: List(records_caps.StoredRecord),
) -> Ctx {
  Ctx(
    ..ctx,
    records: records_caps.RecordsCaps(
      setup: fn(_) { setup },
      stored: fn(_) { rows },
      numbers: fn(_) { list.map(rows, fn(row) { row.game_number }) },
      save: fn(_, _, _, _) { Nil },
      entries_of: fn(_, number) {
        list.find(rows, fn(row) { row.game_number == number })
        |> result.map(fn(row) { row.entries_json })
        |> option.from_result
      },
    ),
  )
}

/// A browser signed into an account: the same guest, plus the user its row
/// points at.
pub fn signed_in_guest(id: String, user_id: String) -> Session {
  Session(guest_id: Some(id), user_id: Some(user_id))
}

/// Analysis caps that answer one account's graded games, newest first.
///
/// The stub pages for real -- it honours the limit and steps over
/// everything at or before the cursor, as the query does -- and it panics
/// when asked about any other account, so a handler that reached for
/// somebody else's games, or ignored the page it was given, fails loudly
/// instead of being handed what the test happened to expect.
pub fn with_graded(
  ctx: Ctx,
  uid: String,
  rows: List(analysis_caps.GradedGame),
) -> Ctx {
  Ctx(
    ..ctx,
    analysis: analysis_caps.AnalysisCaps(
      ..ctx.analysis,
      graded_for: fn(asked, limit, before) {
        case asked == uid {
          False -> panic as "analysis.graded_for asked for another account"
          True ->
            rows
            |> list.filter(fn(row) {
              case before {
                option.None -> True
                Some(cursor) -> after_cursor(row, cursor)
              }
            })
            |> list.take(limit)
        }
      },
    ),
  )
}

/// Ordered as the query orders it: the answer's moment, then the game
/// number, then the room, each newest-first. A row is "after" the cursor
/// when it is further down that list.
fn after_cursor(
  row: analysis_caps.GradedGame,
  cursor: analysis_caps.Cursor,
) -> Bool {
  case int.compare(row.ended_at_ms, cursor.ended_at_ms) {
    order.Lt -> True
    order.Gt -> False
    order.Eq ->
      case int.compare(row.game_number, cursor.game_number) {
        order.Lt -> True
        order.Gt -> False
        order.Eq -> string.compare(row.game_id, cursor.game_id) == order.Lt
      }
  }
}

/// Practice caps for a page that only reads a deck: what is due, how big
/// it is, the ladder and the days practised. Everything a session does to
/// a deck still panics.
pub fn with_deck(
  ctx: Ctx,
  due: Int,
  size: Int,
  ladder: List(Int),
  days: List(Bool),
) -> Ctx {
  Ctx(
    ..ctx,
    practice: practice_caps.PracticeCaps(
      ..ctx.practice,
      summary: fn(_, _) {
        case size {
          0 -> []
          _ -> [
            practice_caps.Summary(
              group: [],
              count: size,
              new_count: 0,
              active_count: size,
              suspended_count: 0,
              due_count: due,
              mean_level: 0.0,
            ),
          ]
        }
      },
      ladder: fn(_) { ladder },
      days: fn(_, n) {
        case list.length(days) == n {
          True -> days
          False -> panic as "practice.days asked for a window it was not given"
        }
      },
    ),
  )
}
