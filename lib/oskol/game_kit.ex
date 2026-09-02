defmodule Oskol.GameKit do
  @moduledoc """
  The only bridge between Elixir and the Gleam games.

  Everything crosses as opaque instances and JSON. Elixir never sees a card,
  a piece, or any other game-specific type, so adding a game never touches
  this module.
  """

  @type instance :: term()
  @type player_id :: String.t()

  @doc "Info for every registered game, in library order."
  @spec games() :: [map()]
  def games do
    :gamekit@host.games_json() |> Jason.decode!()
  end

  @spec game_info(String.t()) :: {:ok, map()} | :error
  def game_info(slug) do
    case :gamekit@host.game_info_json(slug) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, _} -> :error
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(slug), do: :gamekit@host.game_exists(slug)

  @spec format_ids(String.t()) :: [String.t()]
  def format_ids(slug), do: :gamekit@host.format_ids(slug)

  @doc "Start a game. `seats` is a list of `{player_id, name}` in seat order."
  @spec start(String.t(), String.t(), [{player_id, String.t()}], integer()) ::
          {:ok, instance} | {:error, String.t()}
  def start(slug, format_id, seats, seed) do
    :gamekit@host.start(slug, format_id, seats, seed)
  end

  @doc "Apply a client action (a decoded JSON map) for a player."
  @spec apply(instance, player_id, map()) :: {:ok, instance, [term()]} | {:error, String.t()}
  def apply(instance, player_id, action) when is_map(action) do
    case :gamekit@host.apply(instance, player_id, action) do
      {:ok, {next, events}} -> {:ok, next, events}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Scene, legal actions, outcome and events for one player, as a map."
  @spec player_update(instance, player_id, [term()]) :: map()
  def player_update(instance, player_id, events \\ []) do
    :gamekit@host.player_update_json(instance, player_id, events) |> Jason.decode!()
  end

  @spec spectator_update(instance, [term()]) :: map()
  def spectator_update(instance, events \\ []) do
    :gamekit@host.spectator_update_json(instance, events) |> Jason.decode!()
  end

  @spec finished?(instance) :: boolean()
  def finished?(instance), do: :gamekit@host.finished(instance)

  @spec outcome(instance) :: :ongoing | {:finished, [player_id]}
  def outcome(instance), do: :gamekit@host.outcome(instance)

  @spec slug(instance) :: String.t()
  def slug(instance), do: :gamekit@host.slug(instance)

  @doc "Plain-text rendering of the game for logs, agents and tests."
  @spec text(instance, player_id) :: String.t()
  def text(instance, player_id), do: :gamekit@host.text(instance, player_id)
end
