defmodule Oskol.Game.DevCodes do
  @moduledoc """
  Centralized module for dev code definitions and validation.
  Add new dev codes here to automatically make them available everywhere.
  """

  @dev_codes %{
    # Shop force codes
    "SHOP_FORCE_SCRAMBLER" => "Force Scrambler card to appear in shop",
    "SHOP_FORCE_PLUS_BOMB" => "Force Plus Bomb card to appear in shop",
    "SHOP_FORCE_STATIC" => "Force Static Field card to appear in shop",
    "SHOP_FORCE_SUPPLY_CHAIN" => "Force Supply Chain card to appear in shop",
    # Game modifier codes
    "1HAND" => "Only 1 hand per round instead of 4",
    "ALL_ENHANCED" => "All cards start with random enhancements"
  }

  @doc """
  Returns all valid dev code strings.
  """
  @spec all() :: [String.t()]
  def all do
    Map.keys(@dev_codes)
  end

  @doc """
  Returns true if the given code is valid.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(code) do
    code in all()
  end

  @doc """
  Returns the description for a dev code, or nil if invalid.
  """
  @spec description(String.t()) :: String.t() | nil
  def description(code) do
    Map.get(@dev_codes, code)
  end

  @doc """
  Validates a list of dev codes, returning {valid_codes, invalid_codes}.
  """
  @spec validate([String.t()]) :: {[String.t()], [String.t()]}
  def validate(codes) do
    Enum.split_with(codes, &valid?/1)
  end
end
