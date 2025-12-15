defmodule Utils.Uuid do
  @moduledoc """
  Elixir FFI implementation for UUID generation.
  Called by Gleam via @external(erlang, "Elixir.Utils.Uuid", "generate_v4").
  """

  import Bitwise

  @doc """
  Generate a UUID v4 string.
  Uses Elixir's :crypto module to generate random bytes.
  """
  def generate_v4 do
    # Generate 16 random bytes
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Format as UUID v4: xxxxxxxx-xxxx-4xxx-xxxx-xxxxxxxxxxxx
    # Version 4: Set version bits (4xxx)
    # Variant: Set variant bits (8xxx, 9xxx, axxx, or bxxx)
    uuid =
      :io_lib.format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c &&& 0x0FFF, (d &&& 0x3FFF) ||| 0x8000, e]
      )

    # Convert to binary string
    :erlang.list_to_binary(uuid)
  end
end
