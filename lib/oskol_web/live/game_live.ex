defmodule OskolWeb.GameLive do
  use OskolWeb, :live_view

  def mount(%{"id" => game_id}, _session, socket) do
    {:ok, assign(socket, game_id: game_id)}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-100">
      <div class="text-center px-4">
        <h1 class="text-4xl font-bold mb-8">
          Game Room: <span class="text-primary"><%= @game_id %></span>
        </h1>
        <p class="text-lg text-base-content/70">
          Game logic will be implemented here!
        </p>
        <div class="mt-8">
          <a href={~p"/"} class="btn btn-outline">
            Back to Home
          </a>
        </div>
      </div>
    </div>
    """
  end
end
