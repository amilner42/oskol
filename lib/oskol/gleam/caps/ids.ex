defmodule Oskol.Gleam.Caps.Ids do
  @moduledoc """
  Real IO for src/oskol/caps/ids.gleam. Keep field order in lockstep.

  The generator is injectable so tests can force code collisions
  (`Oskol.Game.create_game/2`).
  """

  def build(opts \\ []) do
    {:ids_caps, Keyword.get(opts, :generate, &Oskol.Game.generate_game_id/0)}
  end
end
