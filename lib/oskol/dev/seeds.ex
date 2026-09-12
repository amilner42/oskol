defmodule Oskol.Dev.Seeds do
  @moduledoc """
  Local rooms at fixed codes, each parked in a position worth testing, with
  P1 always the one to act. `mix oskol.seed` writes them; open the printed
  links.

  A game is its seed plus its action log, so a position cannot be written
  down directly: each scenario is *found* by random legal play against the
  engine (fast, no room, no clock) until its predicate holds for P1, and
  that exact play is then replayed through a real room, which persists it.
  The web server rehydrates the room from the log on the first visit.

  Reseeding replaces the rows. A room that is already live in a running
  server keeps its old log until that process stops, so after reseeding a
  code you have open, restart the server (or run `Oskol.Dev.Seeds.run/0`
  from its IEx, which stops the live rooms first).
  """

  import Ecto.Query

  alias Oskol.Game
  alias Oskol.Game.{GameServerState, GameSupervisor, Persister}
  alias Oskol.GameKit
  alias Oskol.Persistence
  alias Oskol.Repo

  @slug "backgammon"
  @seats [{"p1", "P1"}, {"p2", "P2"}]
  @max_steps 3000
  @max_seeds 3000

  @doc "Every seeded room: its code, what it is, and the format it is played in."
  def scenarios do
    [
      %{code: "000001", format: "single", what: "a fresh game, P1 has the opening roll", find: &fresh?/2},
      %{code: "000002", format: "single", what: "P1 has a checker on the bar, dice rolled", find: &on_bar?/2},
      %{code: "000003", format: "single", what: "P1 is bearing off, dice rolled", find: &bearing_off?/2},
      %{code: "000004", format: "single", what: "P1 danced: no legal move, turn to pass", find: &danced?/2},
      %{code: "000005", format: "match5", what: "match to 5: P1 may roll or double", find: &roll_or_double?/2},
      %{code: "000006", format: "match5", what: "match to 5: P1 must answer a double", find: &answer_double?/2},
      %{code: "000007", format: "match5", what: "match to 5: P1 owns the cube, dice rolled", find: &owns_cube?/2}
    ]
  end

  @doc "Write every scenario; returns the rows printed, one per room."
  def run do
    codes = Enum.map(scenarios(), & &1.code)
    Enum.each(codes, &stop_live/1)
    Persister.flush()
    Repo.delete_all(from(g in Persistence.Game, where: g.id in ^codes))

    rows = Enum.map(scenarios(), &seed/1)
    Persister.flush()
    rows
  end

  # ---------- one scenario ----------

  defp seed(%{code: code, format: format, what: what, find: find}) do
    {seed, actions} = search(format, find)

    {:ok, _} = Game.start_game(code, @slug)
    {:ok, _} = Game.configure(code, %{format: format, clock: "none", seed: seed})
    {:ok, p1, _} = Game.join_game(code, "P1", nil)
    {:ok, p2, _} = Game.join_game(code, "P2", nil)
    seat_of = %{"p1" => p1, "p2" => p2}

    Enum.each(actions, fn {player_id, action} ->
      {:ok, _, _} = Game.player_action(code, seat_of[player_id], action)
    end)

    state = Game.get_server_state(code)
    true = find.(GameKit.player_update(state.instance, p1), p1)

    %{
      code: code,
      what: what,
      seed: seed,
      steps: length(actions),
      links: %{
        "P1" => link(code, GameServerState.token_for(state, p1)),
        "P2" => link(code, GameServerState.token_for(state, p2))
      }
    }
  end

  defp link(code, token), do: "#{OskolWeb.Endpoint.url()}/#{@slug}/#{code}?t=#{token}"

  # A live room at this code (this VM only) would shadow the reseeded log.
  defp stop_live(code) do
    case GameSupervisor.find_game(code) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(GameSupervisor, pid)
      :error -> :ok
    end
  end

  # ---------- the search ----------

  # Random legal play from each seed in turn, never resigning, until P1's
  # update satisfies `find`; the seed and the actions that got there.
  defp search(format, find) do
    Enum.find_value(1..@max_seeds, fn seed ->
      case play(format, seed, find) do
        {:found, actions} -> {seed, actions}
        :none -> nil
      end
    end) || raise "no position found in #{@max_seeds} seeds"
  end

  defp play(format, seed, find) do
    {:ok, instance} = GameKit.start(@slug, format, @seats, seed, :no_clock, 0)
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

    Enum.reduce_while(1..@max_steps, {instance, []}, fn _, {instance, taken} ->
      cond do
        find.(GameKit.player_update(instance, "p1"), "p1") ->
          {:halt, {:found, Enum.reverse(taken)}}

        GameKit.finished?(instance) ->
          {:halt, :none}

        true ->
          choices =
            for player_id <- ["p1", "p2"],
                schema <- GameKit.player_update(instance, player_id)["legal"],
                schema["name"] != "resign",
                do: {player_id, schema}

          case choices do
            [] ->
              {:halt, :none}

            _ ->
              {player_id, schema} = Enum.random(choices)
              action = action_for(schema)
              {:ok, next, _} = GameKit.apply(instance, player_id, action, 0)
              {:cont, {next, [{player_id, action} | taken]}}
          end
      end
    end)
    |> case do
      {:found, actions} -> {:found, actions}
      _ -> :none
    end
  end

  defp action_for(schema) do
    %{"name" => schema["name"], "params" => Map.new(schema["params"], &{&1["name"], value(&1)})}
  end

  defp value(%{"type" => "choice", "options" => options}), do: Enum.random(options)["id"]
  defp value(%{"type" => "number", "min" => min, "max" => max}), do: Enum.random(min..max)
  defp value(%{"type" => "select", "candidates" => c, "min" => min}), do: Enum.take_random(c, min)

  # ---------- the positions, read off P1's update (`me` is P1's seat id) ----------

  defp fresh?(u, me), do: data(u)["to_act"] == me and has?(u, "move")

  defp on_bar?(u, _me), do: moves_where(u, "from", "bar")

  defp bearing_off?(u, _me), do: moves_where(u, "to", "off")

  defp danced?(u, me), do: data(u)["no_moves"] == true and data(u)["to_move"] == me

  defp roll_or_double?(u, _me), do: has?(u, "roll") and has?(u, "double")

  defp answer_double?(u, _me), do: has?(u, "take")

  defp owns_cube?(u, me), do: data(u)["cube"]["owner"] == me and has?(u, "move")

  defp data(u), do: u["scene"]["data"]

  defp has?(u, name), do: Enum.any?(u["legal"], &(&1["name"] == name))

  # A `move` schema whose `param` choice is exactly `id`.
  defp moves_where(u, param, id) do
    Enum.any?(u["legal"], fn schema ->
      schema["name"] == "move" and
        Enum.any?(schema["params"], fn p ->
          p["name"] == param and Enum.any?(p["options"], &(&1["id"] == id))
        end)
    end)
  end
end
