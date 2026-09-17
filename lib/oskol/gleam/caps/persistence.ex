defmodule Oskol.Gleam.Caps.Persistence do
  @moduledoc "Real IO for src/oskol/caps/persistence.gleam. Keep field order in lockstep."

  def build do
    {:persistence_caps, &game_exists?/1, &seated_rooms/1}
  end

  # A database hiccup must not block creating games: the id space plus the
  # registry still make collisions with live rooms impossible.
  defp game_exists?(game_id) do
    Oskol.Persistence.game_exists?(game_id)
  rescue
    _ -> false
  end

  # The rows a guest holds a seat in, as `oskol/rooms/room.ActiveRoom`
  # records. A hiccup is an empty list: the home page still draws.
  defp seated_rooms(guest_id) do
    now = DateTime.utc_now()

    Oskol.Persistence.seated_rooms(guest_id)
    |> Enum.map(fn game ->
      config = game.config || %{}
      state = game.state || %{}

      {:active_room, game.slug, game.id, game.status, config["format"] || "",
       config["clock"] || "none",
       Enum.map(game.players, fn p -> {p["id"], p["name"] || "", p["guest_id"] || ""} end),
       Enum.filter(state["to_act"] || [], &is_binary/1), clocks(state["clocks"]),
       max(DateTime.diff(now, game.updated_at, :second), 0)}
    end)
  rescue
    _ -> []
  end

  # Each seat's clock as the snapshot wrote it; nothing under no clock, or
  # for a row from before the snapshot carried clocks.
  defp clocks(list) when is_list(list) do
    for %{"id" => id, "remaining_ms" => left, "move_ms" => free, "running" => running} <- list,
        is_binary(id) and is_integer(left) and is_integer(free) and is_boolean(running),
        do: {id, left, free, running}
  end

  defp clocks(_), do: []
end
