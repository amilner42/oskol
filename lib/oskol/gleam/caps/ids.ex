defmodule Oskol.Gleam.Caps.Ids do
  @moduledoc """
  Real IO for src/oskol/caps/ids.gleam. Keep field order in lockstep.

  The generator is injectable so tests can force code collisions
  (`Oskol.Game.create_game/2`).
  """

  def build(opts \\ []) do
    {:ids_caps, Keyword.get(opts, :generate, &Oskol.Game.generate_game_id/0), &share_token/0}
  end

  @doc """
  A share token: twelve crypto-random characters of the code alphabet
  (`oskol/handlers/shares.token_length`), drawn as two game codes so the
  shape stays Gleam's. Each draw is 64 random bits reduced modulo 32^6,
  which divides 2^64, so no character is favoured.
  """
  def share_token do
    Oskol.Game.generate_game_id() <> Oskol.Game.generate_game_id()
  end
end
