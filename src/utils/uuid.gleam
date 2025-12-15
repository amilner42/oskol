/// UUID generation using Elixir FFI
///
/// This module provides UUID v4 generation for card and shop card IDs.
/// UUIDs ensure stable identity across game state updates.

/// Generate a UUID v4 string
/// Calls Elixir's Utils.Uuid module which uses crypto to generate a UUID
@external(erlang, "Elixir.Utils.Uuid", "generate_v4")
pub fn generate() -> String
