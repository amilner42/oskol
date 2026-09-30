defmodule OskolWeb.StatusTest do
  @moduledoc """
  `GET /status` says whether the analysis engine answered, along the road a
  review takes. It is the only thing in the product that reports on a
  machine we do not control the power to, so what it must never do is read
  green while the engine is unreachable.

  The engine here is a `Req.Test` stub, as everywhere else — no network.
  """
  use OskolWeb.ConnCase, async: false

  setup do
    Req.Test.set_req_test_to_shared()
    # The cache is process-independent, so a stub swapped between tests is
    # not seen until it expires. Clear it instead of sleeping.
    on_exit(fn -> :persistent_term.erase({OskolWeb.StatusController, :last}) end)
    :persistent_term.erase({OskolWeb.StatusController, :last})
    :ok
  end

  defp engine(fun), do: Req.Test.stub(Oskol.Reviews, fun)

  test "an engine that answers reads UP, and 200", %{conn: conn} do
    engine(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

    conn = get(conn, ~p"/status")
    body = response(conn, 200)

    assert body =~ "UP"
    refute body =~ "DOWN"
    assert body =~ "answered in"
  end

  test "an engine that refuses reads DOWN, and 503 so a machine can watch it", %{conn: conn} do
    engine(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    conn = get(conn, ~p"/status")
    body = response(conn, 503)

    assert body =~ "DOWN"
    refute body =~ ">UP<"
  end

  test "an engine that answers badly is down, not up", %{conn: conn} do
    engine(fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    assert get(conn, ~p"/status") |> response(503) =~ "DOWN"
  end

  test "the reason is escaped rather than written into the page", %{conn: conn} do
    engine(fn conn -> Plug.Conn.send_resp(conn, 418, "<script>alert(1)</script>") end)

    body = get(conn, ~p"/status") |> response(503)
    refute body =~ "<script>alert(1)</script>"
  end

  test "a second hit is served from the cache, so the page cannot be used to make requests",
       %{conn: conn} do
    test_pid = self()

    engine(fn conn ->
      send(test_pid, :asked)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert get(conn, ~p"/status") |> response(200) =~ "UP"
    assert_received :asked

    assert get(build_conn(), ~p"/status") |> response(200) =~ "UP"
    refute_received :asked
  end

  test "it is not indexed: the page is for whoever runs the machine", %{conn: conn} do
    engine(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    assert get(conn, ~p"/status") |> response(200) =~ ~s(name="robots" content="noindex")
  end
end
