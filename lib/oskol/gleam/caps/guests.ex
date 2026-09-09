defmodule Oskol.Gleam.Caps.Guests do
  @moduledoc """
  Real IO for src/oskol/caps/guests.gleam. Keep field order in lockstep.

  `Oskol.Guests` already rescues every write and degrades to "the site just
  doesn't remember you", so none of these raise.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Guests

  def build do
    {:guests_caps, &mint/0, fn guest_id -> opt(Guests.touch(guest_id)) end,
     fn guest_id, name ->
       Guests.save_name(guest_id, name)
       nil
     end}
  end

  # 16 crypto-random bytes, URL-safe base64, unpadded: exactly 22 chars.
  defp mint, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
