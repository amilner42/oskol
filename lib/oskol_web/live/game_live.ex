defmodule OskolWeb.GameLive do
  use OskolWeb, :live_view

  alias Oskol.{GameSupervisor, GameServer}

  def mount(%{"id" => game_id}, _session, socket) do
    # Find or start the game
    {:ok, _pid} = GameSupervisor.find_or_start_game(game_id)

    # Get current game state
    game_state = GameServer.get_state(game_id)

    # Subscribe to game updates
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

    socket =
      socket
      |> assign(:game_id, game_id)
      |> assign(:game_state, game_state)
      |> assign(:current_player, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  def handle_event("join_new_player", %{"player_name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, :error, "Name cannot be empty")}
    else
      case GameServer.join_game(socket.assigns.game_id, name, self()) do
        {:ok, new_state} ->
          socket =
            socket
            |> assign(:game_state, new_state)
            |> assign(:current_player, name)
            |> assign(:error, nil)

          {:noreply, socket}

        {:error, :game_full} ->
          {:noreply, assign(socket, :error, "Game is full")}

        {:error, :name_taken} ->
          {:noreply, assign(socket, :error, "Name is already taken")}
      end
    end
  end

  def handle_event("rejoin_player", %{"player_name" => name}, socket) do
    case GameServer.rejoin_game(socket.assigns.game_id, name, self()) do
      {:ok, new_state} ->
        socket =
          socket
          |> assign(:game_state, new_state)
          |> assign(:current_player, name)
          |> assign(:error, nil)

        {:noreply, socket}

      {:error, :player_not_found} ->
        {:noreply, assign(socket, :error, "Player not found")}
    end
  end

  def handle_info({:game_state_updated, new_state}, socket) do
    {:noreply, assign(socket, :game_state, new_state)}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 p-8">
      <div class="max-w-4xl mx-auto">
        <div class="mb-8">
          <h1 class="text-3xl font-bold mb-2">
            Game Room: <span class="text-primary"><%= @game_id %></span>
          </h1>
          <div class="badge badge-lg">
            <%= status_text(@game_state.status) %>
          </div>
        </div>

        <%= if @current_player do %>
          <div class="card bg-base-200 shadow-xl mb-8">
            <div class="card-body">
              <h2 class="card-title">You are: <%= @current_player %></h2>

              <div class="mt-4">
                <h3 class="text-lg font-semibold mb-2">Players:</h3>
                <ul class="space-y-2">
                  <%= for player <- @game_state.players do %>
                    <li class="flex items-center gap-2">
                      <div class={[
                        "badge",
                        if(player.connected, do: "badge-success", else: "badge-error")
                      ]}>
                        <%= if player.connected, do: "Online", else: "Offline" %>
                      </div>
                      <span class={[
                        "font-medium",
                        if(player.name == @current_player, do: "text-primary")
                      ]}>
                        <%= player.name %>
                      </span>
                      <%= if player.name == @current_player do %>
                        <span class="text-sm text-base-content/50">(you)</span>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>

              <%= if @game_state.status == :waiting do %>
                <div class="alert alert-info mt-4">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    class="stroke-current shrink-0 w-6 h-6"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    >
                    </path>
                  </svg>
                  <span>Waiting for another player to join...</span>
                </div>
              <% end %>

              <%= if @game_state.status == :ready do %>
                <div class="alert alert-success mt-4">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>Both players are connected! Game can start.</span>
                </div>
              <% end %>

              <%= if @game_state.status == :paused do %>
                <div class="alert alert-warning mt-4">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                    />
                  </svg>
                  <span>Game paused - waiting for player to reconnect.</span>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="card bg-base-200 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Join the Game</h2>

              <%= if @error do %>
                <div class="alert alert-error mb-4">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span><%= @error %></span>
                </div>
              <% end %>

              <%= if length(@game_state.players) > 0 do %>
                <div class="mb-6">
                  <h3 class="text-lg font-semibold mb-3">Current Players:</h3>
                  <div class="space-y-2">
                    <%= for player <- @game_state.players do %>
                      <div class="flex items-center justify-between p-3 bg-base-300 rounded-lg">
                        <div class="flex items-center gap-3">
                          <div class={[
                            "badge",
                            if(player.connected, do: "badge-success", else: "badge-error")
                          ]}>
                            <%= if player.connected, do: "Online", else: "Offline" %>
                          </div>
                          <span class="font-medium"><%= player.name %></span>
                        </div>
                        <%= if not player.connected do %>
                          <button
                            class="btn btn-sm btn-primary"
                            phx-click="rejoin_player"
                            phx-value-player_name={player.name}
                          >
                            Rejoin as <%= player.name %>
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if length(@game_state.players) < 2 do %>
                <div>
                  <h3 class="text-lg font-semibold mb-3">Join as New Player:</h3>
                  <form phx-submit="join_new_player" class="flex gap-2">
                    <input
                      type="text"
                      name="player_name"
                      placeholder="Enter your name"
                      class="input input-bordered flex-1"
                      autocomplete="off"
                      autofocus
                    />
                    <button type="submit" class="btn btn-primary">Join Game</button>
                  </form>
                </div>
              <% else %>
                <div class="alert alert-warning">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                    />
                  </svg>
                  <span>
                    Game is full. You can rejoin as a disconnected player if available.
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="mt-8">
          <a href={~p"/"} class="btn btn-outline">← Back to Home</a>
        </div>
      </div>
    </div>
    """
  end

  defp status_text(:waiting), do: "Waiting for players"
  defp status_text(:ready), do: "Ready to play"
  defp status_text(:paused), do: "Paused"
end
