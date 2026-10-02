defmodule OskolWeb.Api.PositionsApiTest do
  @moduledoc """
  SHARE POSITION from the replay, `POST /papi/games/:slug/rooms/:id/positions`,
  over the seeded match at 821900 as `mix oskol.seed` plants it
  (`Oskol.Dev.RoomImport`): the route, the statuses, the row and its replay
  link, the picture, and what the row does not get -- a source, a story,
  a place in TRY ONE.

  Which step asks which question, and every refusal's reason, is Gleam's
  and tested there (test/oskol/positions_test.gleam). The engine is never
  asked: nothing here stubs it, so a share that tried would fail.
  """
  use OskolWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Oskol.Puzzles
  alias Oskol.Puzzles.Pictures
  alias Oskol.Repo
  alias Oskol.Reviews.Review

  @cookie "_oskol_guest"
  @room "821900"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok = Oskol.Dev.RoomImport.import!(@room)
    :ok
  end

  defp new_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp csrf_checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> csrf_checked()
    |> put_req_header("x-csrf-token", token)
  end

  # A stranger: a browser that holds no seat in the room.
  defp share(conn, body, slug \\ "backgammon") do
    conn
    |> put_req_cookie(@cookie, new_guest_id())
    |> with_csrf()
    |> post(~p"/papi/games/#{slug}/rooms/#{@room}/positions", body)
  end

  # The seeded answers predate `all_results`: give game 1's checker plays
  # every legal play, as today's engine sends them.
  defp complete_game_one do
    review = Repo.one!(from(r in Review, where: r.game_id == @room and r.game_number == 1))

    turns =
      Enum.map(review.response["turns"], fn
        %{"move" => %{"n_legal" => n, "best" => %{"board" => board}} = move} = turn ->
          results = for i <- 0..(n - 1), do: %{"board" => board, "equity_diff" => -0.01 * i}
          %{turn | "move" => Map.put(move, "results", results)}

        turn ->
          turn
      end)

    review
    |> Ecto.Changeset.change(response: %{review.response | "turns" => turns})
    |> Repo.update!()
  end

  # Game 1's second line: the second roll of the match, a checker play
  # with plenty of ways to play it.
  @step 2

  describe "POST /papi/games/:slug/rooms/:id/positions" do
    test "a graded step is a puzzle row, linked back, pictured, in nobody's practice", %{
      conn: conn
    } do
      complete_game_one()
      sources = Repo.aggregate(Puzzles.Source, :count)

      body = conn |> share(%{"game" => 1, "step" => @step}) |> json_response(200)
      assert %{"ok" => true, "id" => id, "url" => url} = body
      assert url == "/puzzles/#{id}"

      row = Repo.get!(Puzzles.Puzzle, id)
      assert row.origin == "replay"
      assert row.kind == "move"
      assert row.complete

      assert row.replay == %{
               "slug" => "backgammon",
               "id" => @room,
               "game" => 1,
               "step" => @step
             }

      # Drawn now, so the link unfurls with the board the moment it is sent.
      assert {:ok, _png} = Pictures.png(id)
      # No source: it is nobody's mistake, so it enters nobody's deck.
      assert Repo.aggregate(Puzzles.Source, :count) == sources

      # The same step is the same key is the same row.
      again = conn |> share(%{"game" => 1, "step" => @step}) |> json_response(200)
      assert again["id"] == id
      assert Repo.aggregate(from(p in Puzzles.Puzzle, where: p.origin == "replay"), :count) == 1

      # The page says where it came from; nobody can tell a story on it.
      page = conn |> get(~p"/papi/puzzles/#{id}") |> json_response(200)
      assert page["replay"] == %{"path" => "/backgammon/#{@room}/replay?game=1&step=#{@step}"}

      story =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/shares", %{})

      assert json_response(story, 403)["ok"] == false
    end

    test "an old answer short of every play is a 409 and writes nothing", %{conn: conn} do
      before = Repo.aggregate(Puzzles.Puzzle, :count)
      body = conn |> share(%{"game" => 1, "step" => @step}) |> json_response(409)
      assert body["error"]["code"] == "incomplete"

      assert body["error"]["message"] ==
               "This position's answer is incomplete; open it in the analysis board instead."

      assert Repo.aggregate(Puzzles.Puzzle, :count) == before
    end

    test "the statuses", %{conn: conn} do
      complete_game_one()
      # The opening position: nobody has rolled.
      assert json_response(share(conn, %{"game" => 1, "step" => 0}), 409)["error"]["code"] ==
               "no_decision"

      # The game still on the board: twelve are written down.
      not_graded = json_response(share(conn, %{"game" => 13, "step" => 1}), 409)
      assert not_graded["error"]["code"] == "not_graded"

      assert not_graded["error"]["message"] ==
               "This position will be shareable once the game is graded."

      # A review that is not done yet.
      Repo.update_all(from(r in Review, where: r.game_id == @room and r.game_number == 3),
        set: [status: "pending"]
      )

      assert json_response(share(conn, %{"game" => 3, "step" => 1}), 409)["error"]["code"] ==
               "not_graded"

      # Names nothing.
      assert json_response(share(conn, %{"game" => 99, "step" => 1}), 404)
      assert json_response(share(conn, %{"game" => 1, "step" => 9999}), 404)
      assert json_response(share(conn, %{"game" => 1, "step" => 1}, "chess"), 404)
      # Says nothing.
      assert json_response(share(conn, %{"game" => 1}), 422)
    end
  end

  describe "Puzzles.store_one/3 and the replay link" do
    defp a_new_puzzle(key) do
      {:stored, _id, kind, question, answer} = :oskol@puzzles@fixture.stored_sample("move")
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

      %{
        key: key,
        ids: ["rp" <> suffix, "rq" <> suffix],
        kind: kind,
        question: Jason.decode!(question),
        answer: Jason.decode!(answer),
        evaluated_by: %{},
        complete: true
      }
    end

    defp link(step), do: %{"slug" => "backgammon", "id" => @room, "game" => 1, "step" => step}

    test "is written once, and a row that has one keeps it" do
      p = a_new_puzzle("replay-once")
      assert {:ok, id} = Puzzles.store_one(p, "replay", link(3))
      assert {:ok, ^id} = Puzzles.store_one(p, "replay", link(7))
      assert Repo.get!(Puzzles.Puzzle, id).replay == link(3)
      assert Puzzles.replay_of(id) == link(3)
    end

    test "a stored row with none gets it and keeps its origin; a set's row never does" do
      game = a_new_puzzle("replay-game")
      assert {:ok, id} = Puzzles.store_one(game, "game")
      assert Repo.get!(Puzzles.Puzzle, id).replay == nil
      assert {:ok, ^id} = Puzzles.store_one(game, "replay", link(5))
      row = Repo.get!(Puzzles.Puzzle, id)
      assert row.origin == "game"
      assert row.replay == link(5)

      set = a_new_puzzle("replay-set")
      assert {:ok, set_id} = Puzzles.store_one(set, "set")
      assert {:ok, ^set_id} = Puzzles.store_one(set, "replay", link(1))
      assert Repo.get!(Puzzles.Puzzle, set_id).replay == nil
    end

    test "TRY ONE never draws a shared step, nor a row a share linked" do
      assert {:ok, shared} = Puzzles.store_one(a_new_puzzle("replay-try-1"), "replay", link(2))
      game = a_new_puzzle("replay-try-2")
      assert {:ok, linked} = Puzzles.store_one(game, "game")
      assert {:ok, ^linked} = Puzzles.store_one(game, "replay", link(4))
      assert {:ok, plain} = Puzzles.store_one(a_new_puzzle("replay-try-3"), "game")

      drawn = Puzzles.sample(1000) |> Enum.map(& &1.id)
      refute shared in drawn
      refute linked in drawn
      assert plain in drawn
    end
  end
end
