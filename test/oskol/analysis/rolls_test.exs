defmodule Oskol.Analysis.RollsTest do
  @moduledoc """
  Per-roll grids through real requests, with the engine a `Req.Test` stub.

  What decides -- which board, on which cube, from which side, what each
  refusal says, and the sign -- is tested in Gleam
  (test/oskol/analysis/rolls_test.gleam). What is here is what only the real
  path can show: one engine call per new board and none for a board already
  stored, two boards in one batch, the row written once, the circuit, and the
  budget counted in the real limiter.
  """
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Analysis.Asker
  alias Oskol.Analysis.Rolls
  alias Oskol.Limiter
  alias Oskol.Repo

  @opening [-2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Req.Test.set_req_test_to_shared()
    budget = Application.get_env(:oskol, :analysis_budget)

    Application.put_env(
      :oskol,
      :analysis_budget,
      Keyword.merge(budget, rolls_minute: 100, rolls_global_minute: 100)
    )

    :ok = Asker.reset()
    :ok = Limiter.reset()

    on_exit(fn ->
      Application.put_env(:oskol, :analysis_budget, budget)
      :ok = Asker.reset()
      :ok = Limiter.reset()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    %{conn: as_guest(build_conn(), guest_id)}
  end

  # ---------- Positions ----------

  defp opening(roll \\ [3, 1]) do
    %{
      "points" => @opening,
      "white_bar" => 0,
      "black_bar" => 0,
      "to_play" => "white",
      "ask" => "move",
      "dice" => roll,
      "cube" => %{"value" => 1, "owner" => "center"},
      "match" => nil
    }
  end

  # The opening with White's 3-1 played: 8/5 6/5, and a board with a blot on 5
  # for the second one, so the two differ.
  defp after_best do
    %{
      "points" => played(@opening, [{8, -1}, {6, -1}, {5, 2}]),
      "white_bar" => 0,
      "black_bar" => 0
    }
  end

  defp after_other do
    %{
      "points" => played(@opening, [{13, -1}, {24, -1}, {10, 1}, {23, 1}]),
      "white_bar" => 0,
      "black_bar" => 0
    }
  end

  defp played(points, changes) do
    Enum.reduce(changes, points, fn {point, by}, acc ->
      List.update_at(acc, point - 1, &(&1 + by))
    end)
  end

  defp ask(conn, body), do: post(conn, ~p"/papi/analysis/rolls", body)

  # An engine that counts the calls it was asked and what it was asked for.
  defp counting_engine do
    test = self()

    Req.Test.stub(Oskol.Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
      send(test, {:engine, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, answered(conn.request_path, Jason.decode!(body)))
    end)
  end

  defp answered("/backgammon/rolls", body), do: Oskol.CompleteEngine.grid(body)

  defp answered("/backgammon/batch", body) do
    %{
      "results" =>
        Enum.map(body["items"], fn item -> Oskol.CompleteEngine.grid(item["request"]) end)
    }
  end

  defp grids_stored, do: Repo.aggregate(from(g in Rolls.Grid), :count)

  # ---------- One board ----------

  test "a position's grid is asked for once and then answered from the row", %{conn: conn} do
    counting_engine()

    assert %{"ok" => true, "rolls" => grid} =
             conn |> ask(%{"setup" => opening()}) |> json_response(200)

    assert_receive {:engine, "/backgammon/rolls", asked}
    # 3-ply, never the depths whose per-roll rows are the bare net or corrupt.
    assert asked["level"] == "3ply"
    assert length(asked["board"]) == 26
    assert asked["cube_value"] == 1
    assert asked["cube_owner"] == "centered"
    assert asked["jacoby"] == true

    assert %{"level" => "3ply", "cells" => cells} = grid
    assert length(cells) == 21
    assert Enum.sum(Enum.map(cells, & &1["weight"])) == 36
    assert Enum.all?(cells, &match?(%{"dice" => [_, _], "value" => _, "best" => _}, &1))
    # A cell is the roll's own equity, so the cells average to the headline.
    mean =
      Enum.reduce(cells, 0.0, fn cell, sum -> sum + cell["weight"] * cell["value"] end) / 36.0

    assert_in_delta mean, grid["equity"], 0.0000001
    assert grids_stored() == 1

    # The same board again: the row answers it, nothing is asked, nothing more
    # is written -- and the roll that was set makes no difference to the grid.
    assert same = conn |> ask(%{"setup" => opening([6, 5])}) |> json_response(200)
    refute_received {:engine, _, _}
    assert same["rolls"] == grid
    assert grids_stored() == 1
  end

  test "a roll that cannot be played still has a grid", %{conn: conn} do
    counting_engine()
    blocked = opening([6, 6]) |> Map.put("points", blocked_points()) |> Map.put("white_bar", 1)

    # Asking the engine about the position itself is refused before any engine
    # time: that roll plays nothing.
    assert %{"ok" => false, "error" => %{"code" => "dances"}} =
             conn |> post(~p"/papi/analysis", blocked) |> json_response(409)

    # The grid is not: it is about all 21 rolls and not about the one that
    # happens to be set.
    assert %{"ok" => true, "rolls" => %{"cells" => cells}} =
             conn |> ask(%{"setup" => blocked}) |> json_response(200)

    assert length(cells) == 21
    assert_receive {:engine, "/backgammon/rolls", _}
  end

  # White on the bar with every entry point held by Black: 6-6 plays nothing.
  defp blocked_points do
    for point <- 1..24 do
      cond do
        point in 19..24 -> -2
        point == 1 -> 2
        true -> 0
      end
    end
  end

  # ---------- Two boards ----------

  test "two candidate boards are one batch, each from the other side", %{conn: conn} do
    counting_engine()

    body = %{"setup" => opening(), "after" => [after_best(), after_other()]}
    assert answer = conn |> ask(body) |> json_response(200)
    assert_receive {:engine, "/backgammon/batch", asked}

    assert [first, second] = asked["items"]
    assert first["kind"] == "rolls"
    assert second["kind"] == "rolls"
    # Each board is read from the opponent's side: the player on roll in a
    # post-move position is the other one, so what was White's is negative.
    for item <- asked["items"] do
      assert item["request"]["level"] == "3ply"
      assert length(item["request"]["board"]) == 26
    end

    assert %{"grids" => [baseline, compared], "diff" => diff} = answer
    assert length(baseline["cells"]) == 21
    assert length(compared["cells"]) == 21
    assert length(diff["cells"]) == 21
    # The difference grid averages to what it says it does.
    mean =
      Enum.reduce(diff["cells"], 0.0, fn cell, sum -> sum + cell["weight"] * cell["value"] end) /
        36.0

    assert_in_delta mean, diff["equity"], 0.0000001
    assert grids_stored() == 2

    # Both boards stored: the same comparison again costs no engine time.
    assert conn |> ask(body) |> json_response(200) == answer
    refute_received {:engine, _, _}
    assert grids_stored() == 2
  end

  test "a third board is refused before anything is asked", %{conn: conn} do
    counting_engine()
    body = %{"setup" => opening(), "after" => [after_best(), after_other(), after_best()]}
    assert %{"ok" => false, "error" => error} = conn |> ask(body) |> json_response(422)
    assert error["code"] == "validation_failed"
    refute_received {:engine, _, _}
  end

  test "a cube question has no plays to compare", %{conn: conn} do
    counting_engine()
    cube = opening() |> Map.put("ask", "double") |> Map.put("dice", nil)
    body = %{"setup" => cube, "after" => [after_best()]}
    assert %{"ok" => false} = conn |> ask(body) |> json_response(422)
    refute_received {:engine, _, _}
    # Its own grid, though, it has: the pre-roll board.
    assert %{"ok" => true} = conn |> ask(%{"setup" => cube}) |> json_response(200)
    assert_receive {:engine, "/backgammon/rolls", _}
  end

  test "a take's grid is on the cube the take left", %{conn: conn} do
    counting_engine()

    take =
      opening()
      |> Map.put("ask", "take")
      |> Map.put("dice", nil)
      |> Map.put("cube", %{"value" => 2, "owner" => "black"})

    assert %{"ok" => true} = conn |> ask(%{"setup" => take}) |> json_response(200)
    assert_receive {:engine, "/backgammon/rolls", asked}
    # The doubler is on roll and the taker owns twice the cube, which from the
    # doubler's side is the opponent's.
    assert asked["cube_value"] == 4
    assert asked["cube_owner"] == "opponent"
  end

  # ---------- The refusals ----------

  test "a position that cannot be asked gets the setup's own sentence", %{conn: conn} do
    counting_engine()
    empty = Map.put(opening(), "points", List.duplicate(0, 24))

    assert %{"ok" => false, "error" => error} =
             conn |> ask(%{"setup" => empty}) |> json_response(422)

    assert error["message"] =~ "checkers on the board"
    refute_received {:engine, _, _}
    assert grids_stored() == 0
  end

  test "an engine that is not answering is a 503, and the circuit then answers for it",
       %{conn: conn} do
    test = self()

    Req.Test.stub(Oskol.Reviews, fn conn ->
      send(test, :engine)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert %{"ok" => false, "error" => error} =
             conn |> ask(%{"setup" => opening()}) |> json_response(503)

    assert error["code"] == "engine_down"
    assert error["retry_after_s"] > 0
    assert_receive :engine
    assert grids_stored() == 0

    # The circuit is open now, so the next press is a 503 without a call: a
    # sleeping desktop is asked once and not once per keen player.
    assert %{"ok" => false} = conn |> ask(%{"setup" => opening([6, 5])}) |> json_response(503)
    refute_received :engine
  end

  test "an engine that refuses the board is a 422 and nothing is stored", %{conn: conn} do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      Plug.Conn.send_resp(conn, 422, ~s({"detail":"board"}))
    end)

    assert %{"ok" => false, "error" => error} =
             conn |> ask(%{"setup" => opening()}) |> json_response(422)

    assert error["message"] =~ "could not read this position"
    assert grids_stored() == 0
  end

  test "an answer that is not a grid is not stored", %{conn: conn} do
    Req.Test.stub(Oskol.Reviews, fn conn -> Req.Test.json(conn, %{"level" => "3ply"}) end)
    assert %{"ok" => false} = conn |> ask(%{"setup" => opening()}) |> json_response(503)
    assert grids_stored() == 0
  end

  # ---------- The budget ----------

  test "a caller past their minute is a 429, and a stored board still answers", %{conn: conn} do
    counting_engine()
    budget = Application.get_env(:oskol, :analysis_budget)
    Application.put_env(:oskol, :analysis_budget, Keyword.put(budget, :rolls_minute, 1))

    assert %{"ok" => true} = conn |> ask(%{"setup" => opening()}) |> json_response(200)
    assert_receive {:engine, _, _}

    # A different board, and the minute is spent.
    assert %{"ok" => false, "error" => error} =
             conn
             |> ask(%{"setup" => %{opening() | "points" => after_best()["points"]}})
             |> json_response(429)

    assert error["code"] == "rate_limited"
    refute_received {:engine, _, _}

    # The first board is stored, so it costs nothing and is answered even now.
    assert %{"ok" => true} = conn |> ask(%{"setup" => opening()}) |> json_response(200)
    refute_received {:engine, _, _}
  end
end
