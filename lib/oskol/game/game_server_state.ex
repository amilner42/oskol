defmodule Oskol.Game.GameServerState do
  @moduledoc """
  Process-level state for one game room: who is connected, what format they
  picked, and the running game instance once it has started. The game itself
  is an opaque Gleam instance; this module never inspects it.
  """

  alias Oskol.GameKit

  @type game_id :: String.t()
  @type player_id :: String.t()
  @type lobby_status :: :waiting_for_players | :ready_to_start

  @type connection :: %{
          name: String.t(),
          pid: pid() | nil,
          connected: boolean(),
          monitor_ref: reference() | nil
        }

  @type t :: %__MODULE__{
          game_id: game_id(),
          slug: String.t(),
          info: map(),
          instance: term() | nil,
          seed: integer() | nil,
          connections: %{player_id() => connection()},
          seat_order: [player_id()],
          lobby_status: lobby_status(),
          last_activity: integer(),
          format_selections: %{player_id() => String.t()},
          rematch_ready: MapSet.t(player_id()),
          rematch_game_id: String.t() | nil
        }

  defstruct game_id: nil,
            slug: nil,
            info: %{},
            instance: nil,
            seed: nil,
            connections: %{},
            seat_order: [],
            lobby_status: :waiting_for_players,
            last_activity: 0,
            format_selections: %{},
            rematch_ready: MapSet.new(),
            rematch_game_id: nil

  @spec new(game_id(), String.t()) :: t()
  def new(game_id, slug) do
    {:ok, info} = GameKit.game_info(slug)

    %__MODULE__{
      game_id: game_id,
      slug: slug,
      info: info,
      last_activity: System.system_time(:second)
    }
  end

  def started?(%__MODULE__{instance: instance}), do: instance != nil

  def max_players(%__MODULE__{info: info}), do: Map.get(info, "max_players", 2)
  def min_players(%__MODULE__{info: info}), do: Map.get(info, "min_players", 2)

  def format_ids(%__MODULE__{info: info}) do
    info |> Map.get("formats", []) |> Enum.map(& &1["id"])
  end

  def full?(%__MODULE__{} = state), do: map_size(state.connections) >= max_players(state)

  @spec name_taken?(t(), String.t()) :: boolean()
  def name_taken?(%__MODULE__{connections: connections}, name) do
    Enum.any?(connections, fn {_id, conn} -> conn.name == name end)
  end

  @spec find_player_id_by_name(t(), String.t()) :: player_id() | nil
  def find_player_id_by_name(%__MODULE__{connections: connections}, name) do
    Enum.find_value(connections, fn {player_id, conn} ->
      if conn.name == name, do: player_id, else: nil
    end)
  end

  @doc "Players in seat order as `{id, name}` pairs."
  def seats(%__MODULE__{} = state) do
    Enum.map(state.seat_order, fn id -> {id, state.connections[id].name} end)
  end

  @doc "Returns `{:ok, format_id}` when every seated player chose the same format."
  @spec check_format_agreement(t()) :: {:ok, String.t()} | :no_agreement
  def check_format_agreement(%__MODULE__{} = state) do
    ids = state.seat_order
    selections = Enum.map(ids, &Map.get(state.format_selections, &1))

    case Enum.uniq(selections) do
      [format] when is_binary(format) and length(ids) >= 1 -> {:ok, format}
      _ -> :no_agreement
    end
  end

  @doc "Recompute lobby status: enough players, all connected, format agreed."
  @spec update_lobby_status(t()) :: t()
  def update_lobby_status(%__MODULE__{instance: nil} = state) do
    connected = Enum.count(state.connections, fn {_id, conn} -> conn.connected end)
    count = map_size(state.connections)

    ready? =
      count >= min_players(state) and count <= max_players(state) and connected == count and
        match?({:ok, _}, check_format_agreement(state))

    %__MODULE__{state | lobby_status: if(ready?, do: :ready_to_start, else: :waiting_for_players)}
  end

  def update_lobby_status(%__MODULE__{} = state), do: state

  def touch(%__MODULE__{} = state) do
    %__MODULE__{state | last_activity: System.system_time(:second)}
  end
end
