defmodule Oskol.Game.GameServerState do
  @moduledoc """
  Process-level state for one game room: who is connected, how the creator
  set the game up, and the running game instance once it has started. The
  game itself is an opaque Gleam instance; this module never inspects it.
  """

  alias Oskol.GameKit

  @type game_id :: String.t()
  @type player_id :: String.t()
  @type lobby_status :: :waiting_for_players | :ready_to_start

  @typedoc """
  One seat. `guest_id` is who holds it: the opaque id in the visitor's
  guest cookie, recorded when the seat was taken or claimed. It is what a
  channel join or a reconnect authenticates with, and nothing in a URL
  grants it. A seat whose holder is away can be claimed by anyone with the
  room code, and then it is that guest's. The display name grants nothing.
  """
  @type connection :: %{
          name: String.t(),
          guest_id: String.t() | nil,
          pid: pid() | nil,
          # The client behind `pid`: the socket's transport, which survives
          # the channel rejoining. It is what tells a reconnect from a
          # takeover (`src/oskol/rooms/seat.gleam`).
          client: pid() | nil,
          connected: boolean(),
          monitor_ref: reference() | nil
        }

  @typedoc """
  What the creator picked: a format, a clock preset, and (for tests and
  tooling) an explicit seed or raw clock control.
  """
  @type setup :: %{
          format: String.t(),
          clock: String.t(),
          seed: integer() | nil,
          control: term() | nil
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
          setup: setup(),
          clock_timer: reference() | nil,
          rematch_ready: MapSet.t(player_id()),
          rematch_game_id: String.t() | nil,
          action_count: non_neg_integer(),
          clock_base: integer() | nil
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
            setup: %{format: nil, clock: "none", seed: nil, control: nil},
            clock_timer: nil,
            rematch_ready: MapSet.new(),
            rematch_game_id: nil,
            # How many log entries (actions + expiries) the instance has
            # applied, and the `now` the instance started at: together they
            # let the write-behind log record each entry's index and offset.
            action_count: 0,
            clock_base: nil

  @spec new(game_id(), String.t()) :: t()
  def new(game_id, slug) do
    {:ok, info} = GameKit.game_info(slug)

    %__MODULE__{
      game_id: game_id,
      slug: slug,
      info: info,
      setup: default_setup(info),
      last_activity: System.system_time(:second)
    }
  end

  @doc "The game's first format and the default clock."
  @spec default_setup(map()) :: setup()
  def default_setup(info) do
    %{
      format: info["formats"] |> List.first() |> Map.get("id"),
      clock: Map.get(info, "default_clock", "none"),
      seed: nil,
      control: nil
    }
  end

  @doc """
  Merge a creator's choices into the setup, checking them against the game's
  formats and clocks. Keys may be atoms or strings. Keys the setup has no
  slot for -- `selections`, which every stored config row still carries --
  are ignored, so an old row rebuilds.

  A creator may only pick a clock the game offers today. A room that already
  has its clock -- one rebuilt from its row, or a rematch carrying its setup
  over -- passes `retired_clocks: true`, which also accepts a preset the game
  no longer offers but that is still defined, so a room made before a clock
  was retired still replays and rematches.
  """
  @spec validate_setup(t(), map(), keyword()) ::
          {:ok, setup()} | {:error, :unknown_format | :unknown_clock}
  def validate_setup(%__MODULE__{info: info, setup: current}, attrs, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_key(k), v} end)
    merged = Map.merge(current, Map.take(attrs, [:format, :clock, :seed, :control]))

    with {:ok, _format} <- fetch_format(info, merged.format),
         :ok <- check_clock(info, merged.clock, Keyword.get(opts, :retired_clocks, false)) do
      {:ok, merged}
    end
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key("format"), do: :format
  defp to_key("clock"), do: :clock
  defp to_key("seed"), do: :seed
  defp to_key("control"), do: :control
  defp to_key(other), do: other

  defp fetch_format(info, id) do
    case Enum.find(info["formats"] || [], &(&1["id"] == id)) do
      nil -> {:error, :unknown_format}
      format -> {:ok, format}
    end
  end

  defp check_clock(info, id, retired_ok) do
    offered =
      if retired_ok, do: GameKit.clock_ids(), else: Map.get(info, "clocks", GameKit.clock_ids())

    if id in offered and id in GameKit.clock_ids(),
      do: :ok,
      else: {:error, :unknown_clock}
  end

  @doc "The format map the room is set up with."
  def format(%__MODULE__{info: info, setup: setup}) do
    Enum.find(info["formats"], &(&1["id"] == setup.format))
  end

  @doc "One line describing the setup: format and clock."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{setup: setup} = state) do
    format = format(state) || %{"name" => setup.format}

    clock =
      case Enum.find(GameKit.clock_presets(), &(&1["id"] == setup.clock)) do
        %{"id" => "none"} -> []
        %{"name" => name} -> ["#{name} clock"]
        nil -> []
      end

    Enum.join([format["name"]] ++ clock, " · ")
  end

  def started?(%__MODULE__{instance: instance}), do: instance != nil

  def max_players(%__MODULE__{info: info}), do: Map.get(info, "max_players", 2)
  def min_players(%__MODULE__{info: info}), do: Map.get(info, "min_players", 2)

  def full?(%__MODULE__{} = state), do: map_size(state.connections) >= max_players(state)

  @spec name_taken?(t(), String.t()) :: boolean()
  def name_taken?(%__MODULE__{connections: connections}, name) do
    Enum.any?(connections, fn {_id, conn} -> conn.name == name end)
  end

  @doc """
  The seat a guest holds here, or `nil`. Compared in constant time: the
  guest id is the credential now, so it is never leaked one character at a
  time by how long a comparison took.
  """
  @spec find_player_id_by_guest(t(), String.t() | nil) :: player_id() | nil
  def find_player_id_by_guest(%__MODULE__{}, guest_id)
      when not is_binary(guest_id) or byte_size(guest_id) == 0,
      do: nil

  def find_player_id_by_guest(%__MODULE__{} = state, guest_id) do
    # In seat order, so the answer never depends on map ordering.
    Enum.find(state.seat_order, fn player_id ->
      conn = state.connections[player_id]
      conn != nil and secure_compare(conn.guest_id, guest_id)
    end)
  end

  @doc "The guest holding a seat, or `nil` if there is no such seat."
  @spec guest_for(t(), player_id()) :: String.t() | nil
  def guest_for(%__MODULE__{connections: connections}, player_id) do
    case connections[player_id] do
      nil -> nil
      conn -> conn.guest_id
    end
  end

  @doc "Seats whose player is currently away, as `{id, name}` in seat order."
  @spec disconnected_seats(t()) :: [{player_id(), String.t()}]
  def disconnected_seats(%__MODULE__{} = state) do
    for id <- state.seat_order,
        conn = state.connections[id],
        conn != nil and not conn.connected,
        do: {id, conn.name}
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_, _), do: false

  @doc "Players in seat order as `{id, name}` pairs."
  def seats(%__MODULE__{} = state) do
    Enum.map(state.seat_order, fn id -> {id, state.connections[id].name} end)
  end

  @doc "Recompute lobby status: enough players and all of them connected."
  @spec update_lobby_status(t()) :: t()
  def update_lobby_status(%__MODULE__{instance: nil} = state) do
    connected = Enum.count(state.connections, fn {_id, conn} -> conn.connected end)
    count = map_size(state.connections)

    ready? =
      count >= min_players(state) and count <= max_players(state) and connected == count

    %__MODULE__{state | lobby_status: if(ready?, do: :ready_to_start, else: :waiting_for_players)}
  end

  def update_lobby_status(%__MODULE__{} = state), do: state

  @doc "True when nothing a player did has touched the room for `ms`."
  def idle?(%__MODULE__{} = state, ms) do
    System.system_time(:second) - state.last_activity >= div(ms, 1000)
  end

  def touch(%__MODULE__{} = state) do
    %__MODULE__{state | last_activity: System.system_time(:second)}
  end
end
