defmodule OskolWeb.InviteHeadTest do
  @moduledoc """
  What an invite link says before anyone taps it: the head `/backgammon?game=`
  unfurls with. The words are decided in Gleam (test/oskol/landing_handler_test.gleam);
  this locks the wiring: the row is read (the room may be asleep), the
  large card carries the board, the canonical never moves, and any room but
  a waiting one gets the game page's own head.
  """
  # Game rows are written from the persister's process: shared sandbox, not async.
  use OskolWeb.ConnCase, async: false

  alias Oskol.Game.GameSupervisor
  alias Oskol.Game.Persister
  alias Oskol.GameFixtures
  alias Oskol.Repo
  alias OskolWeb.GameCopy

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("timed out waiting")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  defp generic_head(html) do
    copy = GameCopy.for_game(Oskol.GameKit.game_info("backgammon") |> elem(1))
    assert html =~ ~s(<meta property="og:title" content="#{esc(copy.title)}")
    assert html =~ ~s(<meta property="og:description" content="#{esc(copy.description)}")
    assert html =~ ~s(<meta name="twitter:card" content="summary">)
    refute html =~ "og:image"
    refute html =~ "invite-board"
  end

  describe "GET /backgammon?game=<id>" do
    test "a room waiting for its second player unfurls as the invitation, with the board", %{
      conn: conn
    } do
      %{game_id: id} = GameFixtures.lobby("match7", clock: "bg5")
      Persister.flush()

      html = conn |> get(~p"/backgammon?game=#{id}") |> html_response(200)
      title = "Alice wants to play a match to 7 on a 5 min clock"

      assert html =~ ~s(<meta property="og:title" content="#{title}">)
      assert html =~ ~s(<meta name="twitter:title" content="#{title}">)
      assert html =~ ~s(<title data-suffix=" · Oskol">#{title} · Oskol</title>)
      assert html =~ ~s(<meta property="og:description" content="Take the other seat and roll.)
      assert html =~ ~s(<meta property="og:image" content="#{url(~p"/images/invite-board.png")}">)
      assert html =~ ~s(<meta property="og:image:width" content="1200">)
      assert html =~ ~s(<meta property="og:image:height" content="630">)
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image">)
      # the invite never competes with the game page
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/backgammon">)
      assert html =~ ~s(<meta property="og:url" content="http://localhost:4002/backgammon">)
    end

    test "the head is read from the row: the room may be asleep, and a crawler does not wake it",
         %{conn: conn} do
      %{game_id: id} = GameFixtures.lobby("single")
      Persister.flush()
      {:ok, pid} = GameSupervisor.find_game(id)
      :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
      # the registry lets the name go a moment after the process
      wait_until(fn -> GameSupervisor.find_game(id) == :error end)

      html = conn |> get(~p"/backgammon?game=#{id}") |> html_response(200)

      assert html =~
               ~s(<meta property="og:title" content="Alice wants to play a game of backgammon">)

      assert GameSupervisor.find_game(id) == :error
    end

    test "a room that has started, or is over, keeps the game's own head and no picture", %{
      conn: conn
    } do
      %{game_id: id} = GameFixtures.started()
      Persister.flush()

      conn |> get(~p"/backgammon?game=#{id}") |> html_response(200) |> generic_head()
    end

    test "a room nobody made keeps the game's own head", %{conn: conn} do
      conn |> get(~p"/backgammon?game=nosuchroom") |> html_response(200) |> generic_head()
    end

    test "the bare game page is untouched", %{conn: conn} do
      conn |> get(~p"/backgammon") |> html_response(200) |> generic_head()
    end

    test "the picture is served, at the card's size", %{conn: conn} do
      resp = get(conn, ~p"/images/invite-board.png")
      assert resp.status == 200
      assert <<0x89, "PNG", _::binary>> = resp.resp_body
      assert byte_size(resp.resp_body) > 10_000
    end
  end
end
