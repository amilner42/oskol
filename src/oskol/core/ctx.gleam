//// The capability context — every IO operation a handler may perform,
//// grouped by domain and injected by Elixir (closures over the room
//// registry, the repo and PubSub). Handlers receive a Ctx and are
//// otherwise pure; tests build a Ctx of stubs (see test/oskol/fakes.gleam).
////
//// Conventions:
////   * Each domain's caps live in src/oskol/caps/<domain>.gleam and are
////     built for real in lib/oskol/gleam/caps/<domain>.ex — those two files
////     must agree on constructor tag + field order, and are owned together.
////   * Caps are fine-grained, take and return the domain types in
////     src/oskol/*, and never Elixir structs or Dynamic. A room process is
////     the one exception and travels as the opaque `rooms/room.Room`.
////   * Caps that cannot fail in a way a handler should branch on return
////     plain values; genuine failures raise on the Elixir side and surface
////     as 500s, exactly as before the port.
////   * This record and its field order are shared surface: Elixir's
////     CtxBuilder mirrors it.

import oskol/caps/copy.{type CopyCaps}
import oskol/caps/guests.{type GuestsCaps}
import oskol/caps/ids.{type IdsCaps}
import oskol/caps/persistence.{type PersistenceCaps}
import oskol/caps/rooms.{type RoomsCaps}

pub type Ctx {
  Ctx(
    copy: CopyCaps,
    guests: GuestsCaps,
    ids: IdsCaps,
    persistence: PersistenceCaps,
    rooms: RoomsCaps,
  )
}
