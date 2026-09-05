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
  One seat. `token` is the seat credential: a secret, unguessable string
  minted when the seat is taken. It is what a channel join or a reconnect
  authenticates with, and it never leaves the server except to the player
  who holds that seat. The display name grants nothing.
  """
  @type connection :: %{
          name: String.t(),
          token: String.t(),
          pid: pid() | nil,
          connected: boolean(),
          monitor_ref: reference() | nil
        }

  @typedoc """
  What the creator picked: a format, its setting choices, a clock preset,
  and (for tests and tooling) an explicit seed or raw clock control.
  """
  @type setup :: %{
          format: String.t(),
          selections: %{String.t() => String.t()},
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
            setup: %{format: nil, selections: %{}, clock: "none", seed: nil, control: nil},
            clock_timer: nil,
            rematch_ready: MapSet.new(),
            rematch_game_id: nil

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

  @doc "The game's first format with every setting at its default and the default clock."
  @spec default_setup(map()) :: setup()
  def default_setup(info) do
    %{
      format: info["formats"] |> List.first() |> Map.get("id"),
      selections: %{},
      clock: Map.get(info, "default_clock", "none"),
      seed: nil,
      control: nil
    }
  end

  @doc """
  Merge a creator's choices into the setup, checking them against the game's
  formats, settings and clocks. Keys may be atoms or strings.
  """
  @spec validate_setup(t(), map()) ::
          {:ok, setup()}
          | {:error, :unknown_format | :unknown_clock | :unknown_setting | :unknown_choice}
  def validate_setup(%__MODULE__{info: info, setup: current}, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_key(k), v} end)
    merged = Map.merge(current, Map.take(attrs, [:format, :selections, :clock, :seed, :control]))

    with {:ok, format} <- fetch_format(info, merged.format),
         :ok <- check_clock(info, merged.clock),
         {:ok, selections} <- check_selections(format, merged.selections || %{}) do
      {:ok, %{merged | selections: selections}}
    end
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key("format"), do: :format
  defp to_key("selections"), do: :selections
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

  defp check_clock(info, id) do
    offered = Map.get(info, "clocks", GameKit.clock_ids())

    if id in offered and id in GameKit.clock_ids(),
      do: :ok,
      else: {:error, :unknown_clock}
  end

  defp check_selections(format, selections) do
    settings = format["settings"] || []

    Enum.reduce_while(selections, {:ok, %{}}, fn {setting_id, choice_id}, {:ok, acc} ->
      setting_id = to_string(setting_id)
      choice_id = to_string(choice_id)

      case Enum.find(settings, &(&1["id"] == setting_id)) do
        nil ->
          {:halt, {:error, :unknown_setting}}

        setting ->
          if Enum.any?(setting["choices"], &(&1["id"] == choice_id)),
            do: {:cont, {:ok, Map.put(acc, setting_id, choice_id)}},
            else: {:halt, {:error, :unknown_choice}}
      end
    end)
  end

  @doc "The format map the room is set up with."
  def format(%__MODULE__{info: info, setup: setup}) do
    Enum.find(info["formats"], &(&1["id"] == setup.format))
  end

  @doc "One line describing the setup: format, chosen settings, clock."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{setup: setup} = state) do
    format = format(state) || %{"name" => setup.format, "settings" => []}

    choices =
      for setting <- format["settings"] || [],
          chosen = Map.get(setup.selections, setting["id"], setting["default"]),
          choice = Enum.find(setting["choices"], &(&1["id"] == chosen)),
          do: choice["name"]

    clock =
      case Enum.find(GameKit.clock_presets(), &(&1["id"] == setup.clock)) do
        %{"id" => "none"} -> []
        %{"name" => name} -> ["#{name} clock"]
        nil -> []
      end

    Enum.join([format["name"] | choices] ++ clock, " · ")
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
  Mint a seat token: 24 crypto-random bytes, URL-safe, unpadded (32 chars).
  """
  @spec new_token() :: String.t()
  def new_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  The seat a token opens, or `nil`. Compared in constant time so a caller
  cannot learn a token one character at a time.
  """
  @spec find_player_id_by_token(t(), String.t() | nil) :: player_id() | nil
  def find_player_id_by_token(%__MODULE__{}, token)
      when not is_binary(token) or byte_size(token) == 0,
      do: nil

  def find_player_id_by_token(%__MODULE__{connections: connections}, token) do
    Enum.find_value(connections, fn {player_id, conn} ->
      if secure_compare(conn.token, token), do: player_id, else: nil
    end)
  end

  @doc "The token for a seat, or `nil` if there is no such seat."
  @spec token_for(t(), player_id()) :: String.t() | nil
  def token_for(%__MODULE__{connections: connections}, player_id) do
    case connections[player_id] do
      nil -> nil
      conn -> conn.token
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
