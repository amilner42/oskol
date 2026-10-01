defmodule Oskol.Decks do
  @moduledoc """
  The universal decks' operator side: building them from the engine. Every
  decision -- which positions, what is asked, what is trusted -- is Gleam's
  (`src/oskol/handlers/decks_build.gleam`); this only hands it a context.
  """

  alias Oskol.Gleam.CtxBuilder

  @doc """
  Ask the engine about every position a universal deck is missing, and write
  the answers (`write?`), or count what that would ask (dry run, no engine).
  Returns the Gleam reports, one per deck.
  """
  def build(write?) when is_boolean(write?) do
    :oskol@handlers@decks_build.run(CtxBuilder.build(), write?)
  end

  @doc "The reports as lines for a terminal."
  def describe(reports), do: :oskol@handlers@decks_build.describe(reports)
end
