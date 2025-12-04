defmodule OskolWeb.CounterChannel do
  use OskolWeb, :channel

  @impl true
  def join("counter:" <> counter_id, _payload, socket) do
    # Start the counter server if it doesn't exist
    case start_counter_server(counter_id) do
      {:ok, _pid} ->
        # Subscribe to counter updates
        Phoenix.PubSub.subscribe(Oskol.PubSub, "counter:updates")

        # Get current count and send it to the client
        count = Oskol.CounterServer.get_count(counter_id)

        socket = assign(socket, :counter_id, counter_id)
        {:ok, %{count: count}, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("increment", _payload, socket) do
    counter_id = socket.assigns.counter_id
    new_count = Oskol.CounterServer.increment(counter_id)
    {:reply, {:ok, %{count: new_count}}, socket}
  end

  @impl true
  def handle_in("decrement", _payload, socket) do
    counter_id = socket.assigns.counter_id
    new_count = Oskol.CounterServer.decrement(counter_id)
    {:reply, {:ok, %{count: new_count}}, socket}
  end

  @impl true
  def handle_info({:counter_updated, new_count}, socket) do
    # Broadcast to all connected clients
    push(socket, "counter_updated", %{count: new_count})
    {:noreply, socket}
  end

  # Private helpers

  defp start_counter_server(counter_id) do
    case Registry.lookup(Oskol.CounterRegistry, counter_id) do
      [] ->
        # Server doesn't exist, start it
        DynamicSupervisor.start_child(
          Oskol.CounterSupervisor,
          {Oskol.CounterServer, counter_id}
        )

      [{pid, _}] ->
        # Server already exists
        {:ok, pid}
    end
  end
end
