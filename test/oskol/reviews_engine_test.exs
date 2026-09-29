defmodule Oskol.Reviews.EngineTest do
  @moduledoc """
  The engine at the edge of the pipeline: a refusal is recorded against the
  game and retried rather than lost, the client never raises into whatever
  called it, and a turn-count backfill leaves a newer failed review alone.
  """
  use Oskol.ReviewsCase

  # Waits out the retry backoffs on purpose: seconds of sleeping, not work.
  @tag :slow
  test "an engine that fails is recorded and the game stays pending", %{conn: conn} do
    Req.Test.stub(Reviews, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"detail" => "turns[3]: bad"})
    end)

    game_id = finished_game(7)

    [row] = wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "failed")) end)
    assert row.attempts == 1
    assert row.error =~ "HTTP 422"
    # A retry is still to come (after the backoff), so the page waits
    assert [%{"status" => "pending"}] = reviews(conn, game_id)["games"]
  end

  test "the engine client never raises" do
    Req.Test.stub(Reviews, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, reason} = Reviews.request("{}")
    assert reason =~ "refused"

    Req.Test.stub(Reviews, &Plug.Conn.send_resp(&1, 200, "{\"turns\":[]}"))
    assert {:ok, "{\"turns\":[]}"} = Reviews.request("{}")
  end

  test "a legacy turn-count backfill preserves a newer failed review" do
    game_id = "turn-count-backfill"
    :ok = Oskol.Persistence.insert_game(game_id, "backgammon", %{})

    :ok = Reviews.save(game_id, 1, "failed", 3, nil, "engine was down", nil, 0)
    :ok = Reviews.backfill_turns(game_id, 1, 42)

    assert [%{game_number: 1, status: "failed", attempts: 3, error: "engine was down", turns: 42}] =
             Reviews.stored(game_id)
  end
end
