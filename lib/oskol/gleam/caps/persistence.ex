defmodule Oskol.Gleam.Caps.Persistence do
  @moduledoc "Real IO for src/oskol/caps/persistence.gleam. Keep field order in lockstep."

  def build do
    {:persistence_caps, &game_exists?/1}
  end

  # A database hiccup must not block creating games: the id space plus the
  # registry still make collisions with live rooms impossible.
  defp game_exists?(game_id) do
    Oskol.Persistence.game_exists?(game_id)
  rescue
    _ -> false
  end
end
