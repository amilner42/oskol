defmodule OskolWeb.LandingLive do
  use OskolWeb, :live_view

  alias OskolWeb.Components.Shared.Brand

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       step: :game_name,
       game_name: "",
       player_name: "",
       error: nil
     )}
  end

  @impl true
  def handle_event("submit_game_name", %{"game_name" => game_name}, socket) do
    game_name = String.trim(game_name)

    if game_name == "" do
      {:noreply, assign(socket, error: "Please enter a game name")}
    else
      {:noreply, assign(socket, step: :player_name, game_name: game_name, error: nil)}
    end
  end

  @impl true
  def handle_event("submit_player_name", %{"player_name" => player_name}, socket) do
    player_name = String.trim(player_name)

    if player_name == "" do
      {:noreply, assign(socket, error: "Please enter your name")}
    else
      {:noreply,
       push_navigate(socket,
         to: "/g/#{URI.encode_www_form(socket.assigns.game_name)}?name=#{URI.encode_www_form(player_name)}"
       )}
    end
  end

  @impl true
  def handle_event("go_back", _params, socket) do
    {:noreply, assign(socket, step: :game_name, error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Brand.brand_page battle_density={:full}>
      <div class="text-center px-6 max-w-xl w-full mx-auto">
        <div class="mb-10">
          <Brand.logo_large />
        </div>

        <%= if @error do %>
          <div class="mb-4 text-red-500 text-sm font-medium">
            {@error}
          </div>
        <% end %>

        <div class="space-y-3">
          <%= if @step == :game_name do %>
            <.game_name_form />
          <% else %>
            <.player_name_form game_name={@game_name} />
          <% end %>
        </div>

        <p class="text-base-content/40 text-xs mt-6">
          Share the game name with a friend
        </p>
      </div>
    </Brand.brand_page>
    """
  end

  defp game_name_form(assigns) do
    ~H"""
    <form phx-submit="submit_game_name" class="space-y-3">
      <div class="h-6 mb-2"></div>

      <Brand.brand_input
        name="game_name"
        placeholder="Enter game name"
        autofocus={true}
        phx-mounted={JS.focus()}
      />

      <Brand.brand_button type="submit" color={:red}>
        Play Now
      </Brand.brand_button>
    </form>
    """
  end

  defp player_name_form(assigns) do
    ~H"""
    <form phx-submit="submit_player_name" class="space-y-3">
      <div class="h-6 mb-2"></div>

      <Brand.brand_input
        name="player_name"
        placeholder="Your name"
        autofocus={true}
        phx-mounted={JS.focus()}
      />

      <Brand.brand_button type="submit" color={:red}>
        Join {@game_name}
      </Brand.brand_button>
    </form>
    """
  end
end
