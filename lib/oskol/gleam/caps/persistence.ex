defmodule Oskol.Gleam.Caps.Persistence do
  @moduledoc "Real IO for src/oskol/caps/persistence.gleam. Keep field order in lockstep."

  import Oskol.Gleam.Interop

  def build do
    {:persistence_caps, &game_exists?/1, &seated_rooms/2, &abandon/3}
  end

  # A database hiccup must not block creating games: the id space plus the
  # registry still make collisions with live rooms impossible.
  defp game_exists?(game_id) do
    Oskol.Persistence.game_exists?(game_id)
  rescue
    _ -> false
  end

  # The rows this caller holds a seat in — by the guest that took it or the
  # account that owns it — as `oskol/rooms/room.ActiveRoom` records. A
  # hiccup is an empty list: the home page still draws.
  defp seated_rooms(guest_id, user_id) do
    now = DateTime.utc_now()

    rooms = Oskol.Persistence.seated_rooms(unopt(guest_id), unopt(user_id))
    named = Oskol.Persistence.display_names(Enum.map(rooms, & &1.players))

    Enum.zip(rooms, named)
    |> Enum.map(fn {game, players} ->
      config = game.config || %{}
      state = game.state || %{}

      {:active_room, game.slug, game.id, game.status, config["format"] || "",
       config["clock"] || "none",
       Enum.map(players, fn p ->
         {p["id"], p["name"] || "", p["guest_id"] || "", p["user_id"] || ""}
       end), Enum.filter(state["to_act"] || [], &is_binary/1), clocks(state["clocks"]),
       clock_age_s(state["at"], game.updated_at, now),
       max(DateTime.diff(now, game.updated_at, :second), 0)}
    end)
  rescue
    _ -> []
  end

  # Refuse from the persisted seats before any lookup can replay a cold room.
  # This is only a cost guard: the row-locking transaction asks the same
  # holder rule again and remains authoritative if ownership changes between
  # this read and the write. An authorized request still wakes a cold room so
  # no concurrent rehydration can install stale active memory after the row
  # changes.
  defp abandon(game_id, guest_id, user_id) do
    guest_id = unopt(guest_id)
    user_id = unopt(user_id)

    if Oskol.Persistence.may_abandon_game?(game_id, guest_id, user_id) do
      case Oskol.Game.lookup_game(game_id) do
        {:ok, _pid} -> Oskol.Game.GameServer.abandon(game_id, guest_id, user_id) == :ok
        :not_found -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  # How long ago the snapshot read its clocks: its own stamp, or, for a row
  # from before it carried one, the row's.
  # A stamp in the future (a clock skew between nodes) charges nothing.
  defp clock_age_s(at_ms, _updated_at, _now) when is_integer(at_ms),
    do: max(div(System.os_time(:millisecond) - at_ms, 1000), 0)

  defp clock_age_s(_, updated_at, now), do: max(DateTime.diff(now, updated_at, :second), 0)

  # Each seat's clock as the snapshot wrote it; nothing under no clock, or
  # for a row from before the snapshot carried clocks.
  defp clocks(list) when is_list(list) do
    for %{"id" => id, "remaining_ms" => left, "move_ms" => free, "running" => running} <- list,
        is_binary(id) and is_integer(left) and is_integer(free) and is_boolean(running),
        do: {id, left, free, running}
  end

  defp clocks(_), do: []
end
