defmodule Oskol.Game.EventLog do
  @moduledoc """
  Manages the event log for a game.

  The EventLog stores all events that occur during a game in chronological order.
  Events are stored in reverse order internally for O(1) append performance,
  and reversed when queried.

  ## Usage

      log = EventLog.new()
      log = EventLog.append(log, game_id, :player_joined, player_id, %{name: "Alice"})
      log = EventLog.append(log, game_id, :game_started, nil, %{...})

      all_events = EventLog.get_all(log)
      recent = EventLog.get_since(log, 5)
  """

  alias Oskol.Game.Event

  defstruct events: [], next_sequence: 1

  @type t :: %__MODULE__{
          events: [Event.t()],
          next_sequence: integer()
        }

  @doc """
  Creates a new empty event log.
  """
  def new do
    %__MODULE__{}
  end

  @doc """
  Appends a new event to the log.

  The event is automatically assigned the next sequence number.
  Returns the updated log.

  ## Examples

      iex> log = EventLog.new()
      iex> log = EventLog.append(log, "game-1", :player_joined, "p1", %{name: "Alice"})
      iex> EventLog.count(log)
      1
  """
  def append(log, game_id, type, player_id \\ nil, data \\ %{}) do
    event = Event.new(game_id, log.next_sequence, type, player_id, data)

    %{
      log
      | events: [event | log.events],
        next_sequence: log.next_sequence + 1
    }
  end

  @doc """
  Appends multiple events to the log.

  Events should be provided as a list of tuples: `{type, player_id, data}`.
  All events will be assigned sequential sequence numbers.

  ## Examples

      iex> log = EventLog.new()
      iex> events = [
      ...>   {:player_joined, "p1", %{name: "Alice"}},
      ...>   {:player_joined, "p2", %{name: "Bob"}}
      ...> ]
      iex> log = EventLog.append_many(log, "game-1", events)
      iex> EventLog.count(log)
      2
  """
  def append_many(log, game_id, events_data) when is_list(events_data) do
    Enum.reduce(events_data, log, fn {type, player_id, data}, acc_log ->
      append(acc_log, game_id, type, player_id, data)
    end)
  end

  @doc """
  Returns all events in chronological order (oldest to newest).
  """
  def get_all(log) do
    Enum.reverse(log.events)
  end

  @doc """
  Returns all events with sequence number >= the given sequence.

  Useful for getting events that occurred after a certain point.

  ## Examples

      iex> # Get all events since sequence 10
      iex> recent_events = EventLog.get_since(log, 10)
  """
  def get_since(log, sequence) do
    log.events
    |> Enum.filter(fn event -> event.sequence >= sequence end)
    |> Enum.reverse()
  end

  @doc """
  Returns all events of a specific type.

  ## Examples

      iex> draws = EventLog.get_by_type(log, :cards_drawn)
  """
  def get_by_type(log, type) do
    log.events
    |> Enum.filter(fn event -> event.type == type end)
    |> Enum.reverse()
  end

  @doc """
  Returns all events initiated by a specific player.

  Does not include system events (where player_id is nil).

  ## Examples

      iex> player_actions = EventLog.get_by_player(log, "player-1")
  """
  def get_by_player(log, player_id) do
    log.events
    |> Enum.filter(fn event -> event.player_id == player_id end)
    |> Enum.reverse()
  end

  @doc """
  Returns the most recent N events in chronological order.

  ## Examples

      iex> last_10 = EventLog.get_latest(log, 10)
  """
  def get_latest(log, count \\ 10) do
    log.events
    |> Enum.take(count)
    |> Enum.reverse()
  end

  @doc """
  Returns the total number of events in the log.
  """
  def count(log) do
    length(log.events)
  end

  @doc """
  Returns the last event in the log, or nil if empty.
  """
  def get_last(log) do
    List.first(log.events)
  end

  @doc """
  Returns events in a time range.

  ## Examples

      iex> start_time = ~U[2024-01-01 00:00:00Z]
      iex> end_time = ~U[2024-01-01 23:59:59Z]
      iex> events = EventLog.get_by_time_range(log, start_time, end_time)
  """
  def get_by_time_range(log, start_time, end_time) do
    log.events
    |> Enum.filter(fn event ->
      DateTime.compare(event.timestamp, start_time) in [:gt, :eq] and
        DateTime.compare(event.timestamp, end_time) in [:lt, :eq]
    end)
    |> Enum.reverse()
  end
end
