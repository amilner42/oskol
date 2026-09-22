defmodule OskolWeb.Api.PuzzleApiTest do
  @moduledoc """
  The wiring behind the puzzle pages: the routes, the envelope, the status
  codes, the rows, and the fact that a puzzle is open to anyone with the
  link while a deck is nobody's but its account's.

  What a puzzle *says* and whether an answer is right are decided in Gleam
  and tested there (test/oskol/puzzles_handler_test.gleam,
  puzzles_grade_test.gleam, puzzles_tree_test.gleam). This locks what only
  the server can be wrong about.

  The last test here is the frozen wire contract itself: the four hand-
  written fixtures the Elm board was built against (`puzzles-wire`), each
  of them rebuilt by this server's own move generator and compared. If the
  two ever disagree, one of them has moved.
  """
  # Puzzle and attempt rows are written from the request process: shared
  # sandbox, not async.
  use OskolWeb.ConnCase, async: false

  alias Oskol.Puzzles
  alias Oskol.Puzzles.TreeCache
  alias Oskol.Repo

  @cookie "_oskol_guest"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    TreeCache.clear()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
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

  # One of the fixtures the Gleam side renders, written into the rows as an
  # extraction would have written it.
  defp seed_puzzle(name) do
    {_, body} = Enum.find(:oskol@puzzles@fixture.samples(), fn {n, _} -> n == name end)
    payload = Jason.decode!(body)

    # The question the page is shown is the question as stored, except for a
    # take, which is turned around for display only. Round-tripping the
    # stored bodies through the fixture module keeps this honest.
    {question, answer} = stored_bodies(name)

    id = payload["id"]

    Repo.insert_all(
      Puzzles.Puzzle,
      [
        %{
          id: id,
          key: "key-" <> id,
          kind: payload["kind"],
          question: question,
          answer: answer,
          evaluated_by: %{},
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing
    )

    {id, payload}
  end

  # The stored bodies behind a fixture, which the fixture module builds and
  # the handler reads back.
  defp stored_bodies(name) do
    {:stored, _id, _kind, question, answer} = :oskol@puzzles@fixture.stored_sample(name)
    {Jason.decode!(question), Jason.decode!(answer)}
  end

  # A whole turn, walked through the payload's own tree to a position where
  # nothing more can be played: what the page would send as an attempt.
  defp path_through(payload) do
    tree = payload["tree"]
    walk(tree["nodes"], tree["root"], [])
  end

  defp walk(nodes, id, so_far) do
    case nodes[id]["children"] do
      [] ->
        Enum.reverse(so_far)

      [child | _] ->
        walk(nodes, child["node"], [
          %{"from" => child["from"], "to" => child["to"], "die" => child["die"]} | so_far
        ])
    end
  end

  defp root_children(payload) do
    tree = payload["tree"]
    tree["nodes"][tree["root"]]["children"]
  end

  describe "GET /papi/puzzles/:id" do
    test "answers the question, the tree and the prompt, and never the answer", %{conn: conn} do
      {id, _} = seed_puzzle("move")

      body = conn |> get(~p"/papi/puzzles/#{id}") |> json_response(200)

      assert %{"ok" => true, "id" => ^id, "kind" => "move", "prompt" => prompt} = body
      assert prompt == "White to play 6-4. What's your play?"
      assert %{"question" => %{"board" => %{"white" => white}}} = body
      assert length(white["points"]) == 24
      assert %{"tree" => %{"root" => root, "nodes" => nodes}} = body
      assert Map.has_key?(nodes, root)
      refute String.contains?(Jason.encode!(body), "equity")
    end

    test "a cube puzzle has no tree", %{conn: conn} do
      {id, _} = seed_puzzle("double")
      body = conn |> get(~p"/papi/puzzles/#{id}") |> json_response(200)

      assert %{
               "ok" => true,
               "kind" => "double",
               "prompt" => "White to play. Double?",
               "tree" => nil
             } = body
    end

    test "an id nobody holds is a 404 in the usual envelope", %{conn: conn} do
      body = conn |> get(~p"/papi/puzzles/nosuchpz") |> json_response(404)
      assert %{"ok" => false, "error" => %{"code" => "not_found"}} = body
    end

    test "the tree is worked out once and kept", %{conn: conn} do
      {id, _} = seed_puzzle("doubles")
      assert TreeCache.get(id) == nil
      first = conn |> get(~p"/papi/puzzles/#{id}") |> json_response(200)
      assert is_binary(TreeCache.get(id))
      again = conn |> recycle() |> get(~p"/papi/puzzles/#{id}") |> json_response(200)
      assert first == again
    end
  end

  describe "GET /papi/puzzles/:id/tree" do
    test "a node id that was never offered is a 404", %{conn: conn} do
      {id, _} = seed_puzzle("move")
      body = conn |> get(~p"/papi/puzzles/#{id}/tree?node=made-up") |> json_response(404)
      assert %{"ok" => false} = body
    end

    test "a node this puzzle minted is one it answers for", %{conn: conn} do
      {id, payload} = seed_puzzle("move")
      [child | _] = root_children(payload)

      body = conn |> get(~p"/papi/puzzles/#{id}/tree?node=#{child["node"]}") |> json_response(200)

      assert %{"ok" => true, "node" => node, "tree" => %{"children" => _}} = body
      assert node == child["node"]
    end
  end

  describe "POST /papi/puzzles/:id/attempts" do
    test "a guest is graded and nothing is written", %{conn: conn} do
      {id, payload} = seed_puzzle("move")
      [first | _] = root_children(payload)

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/attempts", %{
          "moves" => path_through(payload),
          "key" => "k1"
        })
        |> json_response(200)

      assert %{"ok" => true, "verdict" => verdict, "schedule" => nil} = body
      assert verdict in ["pass", "hold", "fail", "unknown"]
      assert %{"best" => %{"rank" => 1}} = body
      assert Repo.aggregate(Puzzles.Attempt, :count) == 0
      assert is_map(first)
    end

    test "a path the tree does not offer is a 422", %{conn: conn} do
      {id, _} = seed_puzzle("move")

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/attempts", %{
          "moves" => [%{"from" => "13", "to" => "1", "die" => 6}],
          "key" => "k1"
        })
        |> json_response(422)

      assert %{"ok" => false, "error" => %{"code" => "validation_failed"}} = body
    end

    test "a band outside the five is a 422", %{conn: conn} do
      {id, _} = seed_puzzle("double")

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/attempts", %{"band" => 7, "key" => "k1"})
        |> json_response(422)

      assert %{"ok" => false} = body
    end

    test "a cube answer comes back with the engine's band and its equities", %{conn: conn} do
      {id, _} = seed_puzzle("double")

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/attempts", %{"band" => 2, "key" => "k1"})
        |> json_response(200)

      assert %{"ok" => true, "cube" => cube} = body
      assert cube["band"] in -2..2
      assert is_number(cube["no_double"])
      assert is_number(cube["double_take"])
      assert is_number(cube["double_pass"])
    end
  end

  describe "POST /papi/puzzles/:id/attempts/:key/outcome" do
    test "a guest has no attempt of their own to change", %{conn: conn} do
      {id, _} = seed_puzzle("move")

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/puzzles/#{id}/attempts/k1/outcome", %{"outcome" => "sooner"})
        |> json_response(403)

      assert %{"ok" => false, "error" => %{"code" => "forbidden"}} = body
    end
  end

  describe "GET /papi/puzzles/:id/mine" do
    test "a visitor who was not in the game gets nothing", %{conn: conn} do
      {id, _} = seed_puzzle("move")

      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> get(~p"/papi/puzzles/#{id}/mine")
        |> json_response(404)

      assert %{"ok" => false, "error" => %{"code" => "not_found"}} = body
    end
  end

  describe "GET /papi/games/:slug/rooms/:id/puzzles" do
    test "a room nobody is seated at is a 404", %{conn: conn} do
      body =
        conn
        |> put_req_cookie(@cookie, new_guest_id())
        |> get(~p"/papi/games/backgammon/rooms/000001/puzzles?game=1")
        |> json_response(404)

      assert %{"ok" => false} = body
    end
  end

  describe "the rows" do
    test "an idempotency key is one answer", %{conn: _conn} do
      {id, _} = seed_puzzle("move")
      user = insert_user()

      assert {:fresh, first} = Puzzles.put_attempt(id, user, "k1", %{"band" => 1}, "pass")
      assert {:kept, again} = Puzzles.put_attempt(id, user, "k1", %{"band" => -2}, "fail")
      assert again.id == first.id
      # The row that stands is the first one, verdict and all.
      assert again.verdict == "pass"
      assert Repo.aggregate(Puzzles.Attempt, :count) == 1
    end

    test "a key means something only inside its own account", %{conn: _conn} do
      # The unique index is (puzzle_id, user_id, idempotency_key), and a key
      # is a uuid a browser made up: two of them can pick the same string.
      # Reading one by key alone would hand one person's attempt -- and the
      # override that moves their ladder -- to whoever sent the same bytes.
      {id, _} = seed_puzzle("move")
      mine = insert_user()
      theirs = insert_user()

      {:fresh, first} = Puzzles.put_attempt(id, mine, "shared", %{}, "pass")
      {:fresh, second} = Puzzles.put_attempt(id, theirs, "shared", %{}, "fail")

      # Two attempts, not one, and each account reads its own.
      assert first.id != second.id
      assert Puzzles.attempt(id, mine, "shared").id == first.id
      assert Puzzles.attempt(id, theirs, "shared").id == second.id
      assert Puzzles.attempt(id, insert_user(), "shared") == nil

      # And settling one leaves the other exactly as it was.
      :ok = Puzzles.settle_attempt(second.id, true, 99, "sooner", %{"level_after" => 0})
      assert Puzzles.attempt(id, mine, "shared").review_id == nil
      assert Puzzles.attempt(id, mine, "shared").outcome == nil
    end

    test "a deck action does not blank what an answer reported", %{conn: _conn} do
      {id, _} = seed_puzzle("move")
      user = insert_user()
      {:fresh, row} = Puzzles.put_attempt(id, user, "k1", %{}, "pass")
      :ok = Puzzles.settle_attempt(row.id, true, 7, nil, %{"level_after" => 3})

      # Pressing NEVER records the outcome and suspends the card; the
      # schedule the answer reported has to survive it, because a retry of
      # that answer is contractually the same reply.
      :ok = Puzzles.settle_attempt(row.id, true, nil, "never", nil)
      kept = Puzzles.attempt(id, user, "k1")
      assert kept.outcome == "never"
      assert kept.schedule == %{"level_after" => 3}
      assert kept.review_id == 7
    end

    test "settling an attempt records what the deck did", %{conn: _conn} do
      {id, _} = seed_puzzle("move")
      user = insert_user()
      {:fresh, row} = Puzzles.put_attempt(id, user, "k1", %{}, "pass")

      :ok = Puzzles.settle_attempt(row.id, true, 77, nil, %{"level_after" => 3})

      settled = Puzzles.attempt(id, user, "k1")
      assert settled.scheduled
      assert settled.review_id == 77
      assert settled.schedule == %{"level_after" => 3}
      # An outcome that was not given does not erase the one that was.
      :ok = Puzzles.settle_attempt(row.id, true, nil, "sooner", %{"level_after" => 0})
      assert Puzzles.attempt(id, user, "k1").review_id == 77
      assert Puzzles.attempt(id, user, "k1").outcome == "sooner"
    end

    test "the memory line's day is the game's end, not the day the source was written",
         %{conn: conn} do
      {id, _} = seed_puzzle("move")
      guest = new_guest_id()
      game_id = "mine-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      ended = ~U[2026-03-04 20:00:00.000000Z]

      Repo.insert!(%Oskol.Persistence.Game{
        id: game_id,
        slug: "backgammon",
        config: %{"format" => "single"},
        seed: 3,
        players: [
          %{"id" => "p1", "name" => "Alice", "guest_id" => guest},
          %{"id" => "p2", "name" => "Charlie", "guest_id" => new_guest_id()}
        ],
        status: "finished",
        winners: ["p2"],
        inserted_at: ended,
        updated_at: ended
      })

      # The review row is opened the moment the game ends; the source is
      # written whenever extraction (or a backfill) gets to it.
      Repo.insert!(%Oskol.Reviews.Review{
        game_id: game_id,
        game_number: 1,
        status: "done",
        attempts: 1,
        inserted_at: ended,
        updated_at: ended
      })

      Repo.insert!(%Puzzles.Source{
        puzzle_id: id,
        game_id: game_id,
        game_number: 1,
        turn: 4,
        kind: "move",
        seat: 0,
        player_id: "p1",
        played: "24/23 13/11",
        equity_lost: 0.11,
        grade: "bad"
      })

      body =
        conn
        |> put_req_cookie(@cookie, guest)
        |> get(~p"/papi/puzzles/#{id}/mine")
        |> json_response(200)

      assert body["date"] == "2026-03-04"
      assert body["who"] == "you"
      # The other seat, by name; the reader's own name is never sent.
      assert body["opponent"] == "Charlie"
    end

    test "a puzzle nobody's room points at has no memory line for anyone", %{conn: _conn} do
      {id, _} = seed_puzzle("move")
      assert Puzzles.mine(id, new_guest_id(), "") == []
      # No credentials at all narrows to nothing without asking the rows.
      assert Puzzles.mine(id, "", "") == []
    end
  end

  describe "the frozen wire contract" do
    test "this server's tree is the tree the Elm board was built against" do
      fixtures = elm_fixtures()
      # Four positions: a hit, an entry from the bar, bearing off, doubles.
      assert length(fixtures) == 4

      for {name, body} <- fixtures do
        payload = Jason.decode!(body)
        assert %{"question" => question, "tree" => %{"nodes" => nodes} = tree} = payload

        rebuilt = rebuild_tree(question)

        assert canonical(tree["root"], nodes) == canonical(rebuilt["root"], rebuilt["nodes"]),
               "the tree for the #{name} fixture has moved"
      end
    end
  end

  # The four hand-written fixtures the Elm board reads, straight out of the
  # file it reads them from.
  defp elm_fixtures do
    source = File.read!("assets/tests/PuzzleFixtures.elm")

    Regex.scan(~r/^(\w+) =\n    """(.*?)"""$/ms, source)
    |> Enum.map(fn [_, name, body] -> {name, body} end)
  end

  # The same question, put through this server's own move generator.
  defp rebuild_tree(question) do
    engine = engine_board(question)
    [high, low] = question["dice"]
    {:ok, board} = :oskol@puzzles@tree.from_engine(engine)
    dice = :oskol@puzzles@tree.dice_of({high, low})
    {:ok, tree} = :oskol@puzzles@tree.build(board, dice, 100_000)
    Jason.decode!(:gleam@json.to_string(:oskol@puzzles@tree.to_json(tree)))
  end

  # The wire's board back into the engine's 26 ints: index 0 is the
  # opponent's bar, 1..24 the points (the mover's positive), 25 the mover's.
  defp engine_board(%{"board" => %{"white" => white, "black" => black}}) do
    points =
      Enum.zip(white["points"], black["points"])
      |> Enum.map(fn {w, b} -> w - b end)

    [black["bar"]] ++ points ++ [white["bar"]]
  end

  # A tree as a set of facts with the node ids forgotten: two trees that
  # agree here offer the same taps from the same positions, which is the
  # whole of the contract.
  defp canonical(root, nodes) do
    nodes
    |> Enum.map(fn {id, node} ->
      {node_key(node), node["terminal"],
       node["children"]
       |> Enum.map(fn c -> {c["die"], c["from"], c["to"], node_key(nodes[c["node"]])} end)
       |> Enum.sort(), id == root}
    end)
    |> Enum.sort()
  end

  defp node_key(nil), do: :missing

  defp node_key(node) do
    {node["board"], Enum.sort(node["dice_left"])}
  end

  defp insert_user do
    Oskol.Auth.find_or_create_user("p#{System.unique_integer([:positive])}@oskol.test").id
  end
end
