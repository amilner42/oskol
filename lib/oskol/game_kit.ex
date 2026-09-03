defmodule Oskol.GameKit do
  @moduledoc """
  The only bridge between Elixir and the Gleam games.

  Everything crosses as opaque instances, JSON, and integers. Elixir never
  sees a card, a piece, or any other game-specific type, so adding a game
  never touches this module. Time is a monotonic millisecond count that
  Elixir supplies; the games never read a clock themselves.
  """

  @type instance :: term()
  @type player_id :: String.t()
  @type control :: term()

  @doc "Monotonic time in milliseconds, the `now` every clock call expects."
  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  # ---------- Catalogue ----------

  @doc "Info for every registered game, in library order."
  @spec games() :: [map()]
  def games, do: :gamekit@host.games_json() |> Jason.decode!()

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

  # ---------- Clocks ----------

  @doc "Time-control presets offered in the lobby; the first is the default."
  @spec clock_presets() :: [map()]
  def clock_presets, do: :gamekit@host.clock_presets_json() |> Jason.decode!()

  @spec clock_ids() :: [String.t()]
  def clock_ids, do: :gamekit@host.clock_ids()

  @doc "Resolve a preset id to an opaque control term (unknown ids mean no clock)."
  @spec clock_control(String.t()) :: control
  def clock_control(preset_id), do: :gamekit@host.clock_control(preset_id)

  @doc "Milliseconds until a running clock could expire, or :none."
  @spec next_deadline(instance, integer()) :: {:ok, non_neg_integer()} | :none
  def next_deadline(instance, now \\ now()) do
    case :gamekit@host.next_deadline(instance, now) do
      {:ok, ms} -> {:ok, ms}
      {:error, nil} -> :none
    end
  end

  @doc "Forfeit a player whose clock ran out, if any."
  @spec expire(instance, integer()) :: {:ok, instance, [term()]} | :none
  def expire(instance, now \\ now()) do
    case :gamekit@host.expire(instance, now) do
      {:ok, {next, events}} -> {:ok, next, events}
      {:error, nil} -> :none
    end
  end

  # ---------- Lifecycle ----------

  @doc """
  Start a game. `seats` is a list of `{player_id, name}` in seat order;
  `selections` the creator's `{setting_id, choice_id}` pairs for the format.
  """
  @spec start(
          String.t(),
          String.t(),
          [{player_id, String.t()}],
          integer(),
          control,
          integer(),
          [{String.t(), String.t()}]
        ) ::
          {:ok, instance} | {:error, String.t()}
  def start(slug, format_id, seats, seed, control \\ :no_clock, now \\ now(), selections \\ []) do
    :gamekit@host.start(slug, format_id, selections, seats, seed, control, now)
  end

  @doc "Apply a client action (a decoded JSON map) for a player."
  @spec apply(instance, player_id, map(), integer()) ::
          {:ok, instance, [term()]} | {:error, String.t()}
  def apply(instance, player_id, action, now \\ now()) when is_map(action) do
    case :gamekit@host.apply(instance, player_id, action, now) do
      {:ok, {next, events}} -> {:ok, next, events}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Scene, legal actions, outcome, clocks and events for one player, as a map."
  @spec player_update(instance, player_id, [term()], integer()) :: map()
  def player_update(instance, player_id, events \\ [], now \\ now()) do
    :gamekit@host.player_update_json(instance, player_id, events, now) |> Jason.decode!()
  end

  @spec spectator_update(instance, [term()], integer()) :: map()
  def spectator_update(instance, events \\ [], now \\ now()) do
    :gamekit@host.spectator_update_json(instance, events, now) |> Jason.decode!()
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
