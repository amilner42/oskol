defmodule Oskol.CounterServer do
  @moduledoc """
  Simple GenServer to manage a counter that multiple clients can interact with.
  Demonstrates server-side state management for the Elm prototype.
  """
  use GenServer

  # Client API

  def start_link(counter_id) do
    GenServer.start_link(__MODULE__, 0, name: via_tuple(counter_id))
  end

  def increment(counter_id) do
    GenServer.call(via_tuple(counter_id), :increment)
  end

  def decrement(counter_id) do
    GenServer.call(via_tuple(counter_id), :decrement)
  end

  def get_count(counter_id) do
    GenServer.call(via_tuple(counter_id), :get_count)
  end

  # Server Callbacks

  @impl true
  def init(initial_count) do
    {:ok, initial_count}
  end

  @impl true
  def handle_call(:increment, _from, count) do
    new_count = count + 1
    broadcast_update(new_count)
    {:reply, new_count, new_count}
  end

  @impl true
  def handle_call(:decrement, _from, count) do
    new_count = count - 1
    broadcast_update(new_count)
    {:reply, new_count, new_count}
  end

  @impl true
  def handle_call(:get_count, _from, count) do
    {:reply, count, count}
  end

  # Private Helpers

  defp via_tuple(counter_id) do
    {:via, Registry, {Oskol.CounterRegistry, counter_id}}
  end

  defp broadcast_update(new_count) do
    # We'll broadcast via PubSub so all connected clients get updates
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "counter:updates",
      {:counter_updated, new_count}
    )
  end
end
