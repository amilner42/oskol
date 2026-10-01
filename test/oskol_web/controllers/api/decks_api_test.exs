defmodule OskolWeb.Api.DecksApiTest do
  @moduledoc """
  The universal decks through real requests, on decks built against the
  complete stub engine. What decides -- which decks are offered, what adding
  one writes, who gets a queue -- is tested in Gleam
  (test/oskol/decks_test.gleam). What is here is what only the real tables
  can show: that a deck is its own retain scope, so an answer counted in it
  moves that ladder and never the player's mistakes; that the browser's zone
  reaches it; and that practising one keeps a streak going.
  """
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
    [_, _] = Oskol.Decks.build(true)
    :ok
  end

  defp csrf_checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> csrf_checked()
    |> put_req_header("x-csrf-token", token)
  end

  defp a_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp signed_in(conn, email) do
    guest_id = a_guest_id()
    user = Auth.find_or_create_user(email)
    conn = conn |> as_guest(guest_id) |> get(~p"/")
    :ok = Auth.bind_guest(guest_id, user.id)
    {recycle(conn), user}
  end

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

  defp learner(uid, scope) do
    Repo.one(from(u in Retain.User, where: u.uid == ^uid and u.scope == ^scope))
  end

  test "anybody is offered both decks, and a guest walks one in order", %{conn: conn} do
    body = conn |> get(~p"/papi/decks") |> json_response(200)
    assert %{"ok" => true, "decks" => [openings, replies]} = body
    assert %{"id" => "openings", "name" => "Openings", "size" => 15, "standing" => nil} = openings
    assert %{"id" => "opening_replies", "standing" => nil} = replies

    session = conn |> get(~p"/papi/decks/openings") |> json_response(200)
    assert length(session["puzzles"]) == 15
    assert hd(session["puzzles"])["prompt"] == "White to play 2-1. What's your play?"
    assert session["today"] == nil

    # Adding is an account's.
    assert %{"ok" => false} =
             conn |> with_csrf() |> post(~p"/papi/decks/openings/join", %{}) |> json_response(409)

    assert Repo.aggregate(Retain.User, :count) == 0

    assert conn |> get(~p"/papi/decks/no-such") |> json_response(404)
  end

  test "adding a deck makes a scope of its own, and an answer there moves only it", %{conn: conn} do
    {conn, user} = signed_in(conn, "arie@oskol.test")

    joined =
      conn
      |> with_csrf()
      |> post(~p"/papi/decks/openings/join", %{"tz" => "Europe/Paris"})
      |> json_response(200)

    assert %{"deck" => %{"standing" => %{"joined" => true, "total" => 15}}} = joined
    # Five new a day: the queue offers the first five.
    assert length(joined["puzzles"]) == 5
    assert learner(user.id, "deck:openings").tz == "Europe/Paris"
    # The mistakes learner is not made by adding a deck.
    assert learner(user.id, "default") == nil

    [first | _] = joined["puzzles"]
    payload = conn |> get(~p"/papi/puzzles/#{first["id"]}") |> json_response(200)

    reveal =
      conn
      |> with_csrf()
      |> post(~p"/papi/puzzles/#{first["id"]}/attempts", %{
        "moves" => path_through(payload),
        "key" => "k1",
        "deck" => "openings"
      })
      |> json_response(200)

    assert %{"verdict" => "pass", "schedule" => %{"level_before" => 0, "level_after" => 1}} =
             reveal

    item =
      Repo.one(
        from(i in Retain.Item,
          join: u in Retain.User,
          on: u.id == i.user_id,
          where: u.uid == ^user.id and u.scope == "deck:openings" and i.key == ^first["id"]
        )
      )

    assert item.level == 1
    assert learner(user.id, "default") == nil

    # Answering an opening is showing up: the home's streak counts it.
    home = conn |> get(~p"/papi/me/home") |> json_response(200)
    assert home["form"]["streak"] == 1

    # The browser's zone reaches the deck it has added.
    conn
    |> with_csrf()
    |> post(~p"/papi/practice/tz", %{"tz" => "America/Vancouver"})
    |> json_response(200)

    assert learner(user.id, "deck:openings").tz == "America/Vancouver"
    # And never creates the one it has not.
    assert learner(user.id, "deck:opening_replies") == nil

    listed = conn |> get(~p"/papi/decks") |> json_response(200)
    [openings, replies] = listed["decks"]

    assert %{"joined" => true, "total" => 15, "in_progress" => 1, "due" => 0} =
             openings["standing"]

    assert %{"joined" => false, "total" => 0} = replies["standing"]
  end

  test "the five decks: a set's standing, its page, and KEEP GOING through it", %{conn: conn} do
    # A stranger: the three tiers (none of theirs) and the two sets.
    listed = conn |> get(~p"/papi/practice/decks") |> json_response(200)

    assert Enum.map(listed["decks"], & &1["slug"]) ==
             ["very-bad", "bad", "dubious", "openings", "opening-replies"]

    assert Enum.all?(listed["decks"], &(&1["standing"] == nil))
    assert %{"lead" => nil, "today" => nil, "streak" => 0} = listed

    # KEEP GOING is an account's, and only through a set it has added.
    assert %{"error" => %{"code" => "sign_in"}} =
             conn |> with_csrf() |> post(~p"/papi/decks/openings/more", %{}) |> json_response(409)

    {conn, user} = signed_in(conn, "arie@oskol.test")

    assert %{"error" => %{"code" => "not_joined", "message" => "Add it first."}} =
             conn |> with_csrf() |> post(~p"/papi/decks/openings/more", %{}) |> json_response(409)

    joined =
      conn
      |> with_csrf()
      |> post(~p"/papi/decks/openings/join", %{"tz" => "Etc/UTC"})
      |> json_response(200)

    [first | _] = joined["puzzles"]
    payload = conn |> get(~p"/papi/puzzles/#{first["id"]}") |> json_response(200)

    reveal =
      conn
      |> with_csrf()
      |> post(~p"/papi/puzzles/#{first["id"]}/attempts", %{
        "moves" => path_through(payload),
        "key" => "k1",
        "deck" => "openings"
      })
      |> json_response(200)

    # Level 1 holds for a day, as `config :retain, intervals` says.
    assert %{"schedule" => %{"level_after" => 1, "held_days" => 1}} = reveal

    listed = conn |> get(~p"/papi/practice/decks") |> json_response(200)
    openings = Enum.find(listed["decks"], &(&1["id"] == "openings"))

    # One answered, none due, and the day's budget has four of its five left.
    assert %{
             "kind" => "set",
             "size" => 15,
             "joined" => true,
             "standing" => %{
               "total" => 15,
               "untouched" => 14,
               "in_progress" => 1,
               "patched" => 0,
               "due" => 0,
               "new_left" => 4,
               "done_today" => 1,
               "target_today" => 5,
               "levels" => [14, 1, 0, 0, 0, 0, 0, 0]
             }
           } = openings

    assert %{"lead" => "openings", "today" => %{"done" => 1}, "streak" => 1} = listed
    # Reading added nothing: no mistakes learner, no other set.
    assert learner(user.id, "default") == nil
    assert learner(user.id, "deck:opening_replies") == nil

    page = conn |> get(~p"/papi/practice/decks/openings") |> json_response(200)
    assert length(page["cells"]) == 15
    assert Enum.count(page["cells"], &(&1["status"] == "active")) == 1
    assert Enum.all?(page["cells"], &(&1["band"] == ""))
    assert length(page["days"]) == 30
    assert List.last(page["days"]) == true

    # KEEP GOING: the set's pace again, over what the day has left.
    more = conn |> with_csrf() |> post(~p"/papi/decks/openings/more", %{}) |> json_response(200)
    assert length(more["puzzles"]) == 5
    assert Enum.all?(more["puzzles"], & &1["due"])

    listed = conn |> get(~p"/papi/practice/decks") |> json_response(200)
    openings = Enum.find(listed["decks"], &(&1["id"] == "openings"))

    assert %{"untouched" => 9, "due" => 5, "new_left" => 0, "target_today" => 6} =
             openings["standing"]

    # PRACTICE ANYWAY is ignored while there is a queue.
    anyway = conn |> get("/papi/decks/openings?all=1") |> json_response(200)
    assert Enum.map(anyway["puzzles"], & &1["id"]) == Enum.map(more["puzzles"], & &1["id"])

    assert conn |> get(~p"/papi/practice/decks/no-such") |> json_response(404)
  end

  # A mistake somebody made on this position in a real game.
  defp a_source(puzzle_id, owner_id, grade) do
    game_id = "s-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    Repo.insert!(%Oskol.Persistence.Game{
      id: game_id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: [%{"id" => "p1", "name" => "p1", "user_id" => owner_id}],
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    Repo.insert!(%Oskol.Puzzles.Source{
      puzzle_id: puzzle_id,
      game_id: game_id,
      game_number: 1,
      turn: 1,
      kind: "move",
      seat: 0,
      player_id: "p1",
      played: "13/8 13/11",
      equity_lost: 0.3,
      grade: grade,
      owner_user_id: owner_id
    })
  end

  test "a set's cells band nothing, whoever got its positions wrong in a game", %{conn: conn} do
    {conn, user} = signed_in(conn, "arie@oskol.test")
    other = Auth.find_or_create_user("other@oskol.test")

    joined =
      conn
      |> with_csrf()
      |> post(~p"/papi/decks/openings/join", %{"tz" => "Etc/UTC"})
      |> json_response(200)

    [first | _] = joined["puzzles"]
    # Somebody else's very bad move on this opening, and the player's own.
    a_source(first["id"], other.id, "very_bad")
    a_source(first["id"], user.id, "bad")

    page = conn |> get(~p"/papi/practice/decks/openings") |> json_response(200)
    assert Enum.any?(page["cells"], &(&1["id"] == first["id"]))
    assert Enum.all?(page["cells"], &(&1["band"] == ""))
  end

  test "a deck that names nothing is refused on an answer", %{conn: conn} do
    [first | _] =
      conn |> get(~p"/papi/decks/openings") |> json_response(200) |> Map.get("puzzles")

    payload = conn |> get(~p"/papi/puzzles/#{first["id"]}") |> json_response(200)

    body =
      conn
      |> with_csrf()
      |> post(~p"/papi/puzzles/#{first["id"]}/attempts", %{
        "moves" => path_through(payload),
        "key" => "k1",
        "deck" => "chess-openings"
      })
      |> json_response(422)

    assert %{"ok" => false, "error" => %{"code" => "validation_failed"}} = body
  end
end
