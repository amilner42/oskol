defmodule Oskol.RatingsTest do
  @moduledoc """
  `/papi/games/:slug/rooms/:id/ratings` end to end: a real room, the
  engine's answers stored against it, and the match PR the table prints.
  What is worth printing is decided in Gleam and tested on stubs
  (test/oskol/ratings_handler_test.gleam).
  """
  use OskolWeb.ConnCase, async: false

  import Oskol.GameFixtures

  alias Oskol.Game.Persister
  alias Oskol.Repo
  alias Oskol.Reviews

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # The engine's answer, cut down to the one field a match PR reads. The
  # players are positional: seat order.
  defp answer(first, second) do
    %{"turns" => [], "players" => [%{"pr" => first}, %{"pr" => second}]}
  end

  defp ratings(conn, game_id) do
    conn
    |> get("/papi/games/backgammon/rooms/#{game_id}/ratings")
    |> json_response(200)
  end

  defp seat(players, id), do: Enum.find(players, &(&1["player_id"] == id))

  test "unanswered ratings rows keep a null body and answered false" do
    %{game_id: game_id} = started(42, "match5")
    Persister.flush()
    :ok = Reviews.save(game_id, 1, "pending", 1, nil, nil, nil, 1)

    assert [%{response: nil}] = Reviews.rating_summaries(game_id)
    {:analysis_caps, _, _, ratings, _, _, _, _, _, _, _, _, _} = Oskol.Gleam.Caps.Analysis.build()
    assert [{:stored, 1, :pending, 1, :none, false, false, 1}] = ratings.(game_id)
  end

  test "a match averages the games its own engine answers graded", %{conn: conn} do
    %{game_id: game_id, p1: p1, p2: p2} = started(42, "match5")
    Persister.flush()

    # Nothing graded yet: both seats are named, neither wears a number, and
    # nothing is owed, so a watching table is told to stop asking.
    assert %{"ok" => true, "pending" => false, "players" => none} = ratings(conn, game_id)
    assert %{"games" => 0, "pr" => nil} = seat(none, p1)
    assert %{"games" => 0, "pr" => nil} = seat(none, p2)

    # One graded game shows its own PR.
    :ok = Reviews.save(game_id, 1, "done", 1, answer(8.0, 12.0), nil, nil, 1)
    assert %{"players" => one} = ratings(conn, game_id)
    assert %{"games" => 1, "pr" => 8.0} = seat(one, p1)
    assert %{"games" => 1, "pr" => 12.0} = seat(one, p2)

    # A second lands: the plain mean of the two, to one decimal.
    :ok = Reviews.save(game_id, 2, "done", 1, answer(9.0, 13.0), nil, nil, 1)
    assert %{"players" => two} = ratings(conn, game_id)
    assert %{"games" => 2, "pr" => 8.5} = seat(two, p1)
    assert %{"games" => 2, "pr" => 12.5} = seat(two, p2)

    # A game still pending and one the engine gave up on count for nothing.
    :ok = Reviews.save(game_id, 3, "pending", 0, nil, nil, nil, 1)
    :ok = Reviews.save(game_id, 4, "failed", 3, nil, "the engine said no", nil, 1)
    assert %{"pending" => true, "players" => still_two} = ratings(conn, game_id)
    assert %{"games" => 2, "pr" => 8.5} = seat(still_two, p1)

    # The engine answers the one it was working on: nothing owed again.
    :ok = Reviews.save(game_id, 3, "done", 1, answer(7.0, 11.0), nil, nil, 1)
    assert %{"pending" => false, "players" => three} = ratings(conn, game_id)
    assert %{"games" => 3, "pr" => 8.0} = seat(three, p1)
  end

  test "a room that is not there says so, and says nothing else", %{conn: conn} do
    assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
             conn
             |> get("/papi/games/backgammon/rooms/nobody/ratings")
             |> json_response(404)
  end

  test "cold ratings leave the room stopped and transfer no turn analysis", %{conn: conn} do
    %{game_id: game_id} = started(42, "match5")
    Persister.flush()
    response = Map.put(answer(8.0, 12.0), "turns", [%{"large" => String.duplicate("x", 100_000)}])
    :ok = Reviews.save(game_id, 1, "done", 1, response, nil, %{"large" => "report"}, 1)

    {:ok, pid} = Oskol.Game.GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Oskol.Game.GameSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    wait_for_stopped_room(game_id)

    [row] = Reviews.rating_summaries(game_id)
    assert row.response == %{"players" => response["players"]}
    assert %{"players" => [%{"pr" => 8.0}, %{"pr" => 12.0}]} = ratings(conn, game_id)
    assert Oskol.Game.GameSupervisor.find_game(game_id) == :error
  end

  defp wait_for_stopped_room(game_id, tries \\ 100)

  defp wait_for_stopped_room(game_id, 0),
    do: assert(Oskol.Game.GameSupervisor.find_game(game_id) == :error)

  defp wait_for_stopped_room(game_id, tries) do
    if Oskol.Game.GameSupervisor.find_game(game_id) != :error do
      Process.sleep(10)
      wait_for_stopped_room(game_id, tries - 1)
    end
  end

  test "a room still in its lobby answers the same 404", %{conn: conn} do
    %{game_id: game_id} = lobby()

    assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
             conn
             |> get("/papi/games/backgammon/rooms/#{game_id}/ratings")
             |> json_response(404)
  end
end
