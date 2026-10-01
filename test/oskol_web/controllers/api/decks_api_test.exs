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
