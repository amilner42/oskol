defmodule Oskol.Gleam.Interop do
  @moduledoc """
  The few conversions the Elixir/Gleam boundary needs.

      Gleam                     Erlang/Elixir
      Ok(x) / Error(e)          {:ok, x} / {:error, e}
      Some(x) / None            {:some, x} / :none
      record Foo(a, b)          {:foo, a, b}
      no-field constructor Bar  :bar
      String                    UTF-8 binary

  Gleam records are tagged tuples, so a capability twin in
  `Oskol.Gleam.Caps.*` must keep its fields in the same order as the Gleam
  record it builds.
  """

  @doc "nil-or-value to a Gleam Option."
  def opt(nil), do: :none
  def opt(value), do: {:some, value}

  @doc "nil-or-value to a Gleam Option, through a getter."
  def opt(nil, _fun), do: :none
  def opt(value, fun), do: {:some, fun.(value)}

  @doc "A Gleam Option back to nil-or-value."
  def unopt(:none), do: nil
  def unopt({:some, value}), do: value
end
