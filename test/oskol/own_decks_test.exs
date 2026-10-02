defmodule Oskol.OwnDecksTest do
  @moduledoc """
  A player's own sets against the real tables and through real requests.
  What decides -- whose a set is, what a name may be, what saving writes --
  is tested in Gleam (test/oskol/own_decks_test.gleam). What is here is what
  only the tables can show: a set's positions are `deck_puzzles` rows its
  members read back, saving one puts it on the owner's ladder in the set's
  own retain scope, the name's uniqueness is the index's, a delete hides
  the row, taking a position out suspends its card, and the envelopes.
  """
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.OwnDecks
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
    # Positions to save: the openings, built against the complete stub.
    [_, _] = Oskol.Decks.build(true)

    puzzles =
      from(m in "deck_puzzles",
        where: m.deck == "openings",
        order_by: m.position,
        limit: 2,
        select: m.puzzle_id
      )
      |> Repo.all()

    %{puzzles: puzzles}
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

  defp create(conn, name) do
    conn |> with_csrf() |> post(~p"/papi/decks/mine", %{"name" => name})
  end

  test "a set is made, filled, read back and practiced in a scope of its own", %{
    conn: conn,
    puzzles: [p1, p2]
  } do
    {conn, user} = signed_in(conn, "own@oskol.test")

    assert %{"ok" => true, "deck" => deck} = conn |> create("  Back games ") |> json_response(200)
    assert %{"name" => "Back games", "size" => 0, "new_per_day" => 5, "standing" => _} = deck
    id = deck["id"]
    assert String.match?(id, ~r/^[0-9A-HJKMNP-TV-Z]{8}$/)

    added =
      conn
      |> with_csrf()
      |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p1})
      |> json_response(200)

    assert %{"ok" => true, "added" => true, "deck" => %{"size" => 1}} = added

    again =
      conn
      |> with_csrf()
      |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p1})
      |> json_response(200)

    assert %{"added" => false, "deck" => %{"size" => 1}} = again

    assert %{"added" => true} =
             conn
             |> with_csrf()
             |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p2})
             |> json_response(200)

    # Its positions are deck_puzzles rows, in the order they were saved.
    assert [%{puzzle_id: ^p1, position: 1}, %{puzzle_id: ^p2, position: 2}] =
             Oskol.Puzzles.deck_members(id)

    # Each is on the owner's ladder in the set's own scope, due as new today.
    assert {:ok, item} = Retain.fetch_item(user.id, p1, scope: "deck:" <> id)
    assert item.tags == %{"deck" => id, "kind" => "move"}
    assert item.position == 1
    assert {:error, :not_found} = Retain.fetch_item(user.id, p1)

    # The list, the members and the hub all have it.
    assert %{"decks" => [%{"id" => ^id, "size" => 2}]} =
             conn |> get(~p"/papi/decks/mine") |> json_response(200)

    assert %{"members" => [%{"id" => ^p1, "level" => 0}, %{"id" => ^p2, "position" => 2}]} =
             conn |> get(~p"/papi/decks/#{id}/puzzles") |> json_response(200)

    hub = conn |> get(~p"/papi/practice/decks") |> json_response(200)

    assert %{"kind" => "own", "joined" => true, "size" => 2} =
             Enum.find(hub["decks"], &(&1["id"] == id))

    # The session is the set's queue: both new positions, the set's pace.
    session = conn |> get(~p"/papi/decks/#{id}") |> json_response(200)
    assert Enum.map(session["puzzles"], & &1["id"]) == [p1, p2]

    # Taking one out suspends its card: the ladder is kept.
    assert %{"deck" => %{"size" => 1}} =
             conn
             |> with_csrf()
             |> delete(~p"/papi/decks/#{id}/puzzles/#{p1}")
             |> json_response(200)

    assert {:ok, %{suspended: true}} = Retain.fetch_item(user.id, p1, scope: "deck:" <> id)

    # What was taken out counts for nothing: one in the set, one in its
    # standing, one in its grid.
    hub = conn |> get(~p"/papi/practice/decks") |> json_response(200)

    assert %{"size" => 1, "standing" => %{"total" => 1}} =
             Enum.find(hub["decks"], &(&1["id"] == id))

    page = conn |> get(~p"/papi/practice/decks/#{id}") |> json_response(200)
    assert [%{"id" => ^p2}] = page["cells"]

    assert %{"decks" => [%{"standing" => %{"total" => 1}}]} =
             conn |> get(~p"/papi/decks/mine") |> json_response(200)

    # Saving it again brings it back at the level it had, at the set's end.
    conn
    |> with_csrf()
    |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p1})
    |> json_response(200)

    assert {:ok, %{suspended: false, position: 3}} =
             Retain.fetch_item(user.id, p1, scope: "deck:" <> id)

    assert [%{puzzle_id: ^p2, position: 2}, %{puzzle_id: ^p1, position: 3}] =
             Oskol.Puzzles.deck_members(id)
  end

  test "taking a position out of a set nothing was ever saved into is no error", %{
    conn: conn,
    puzzles: [p1, _]
  } do
    {conn, _user} = signed_in(conn, "own@oskol.test")
    %{"deck" => %{"id" => id}} = conn |> create("Empty") |> json_response(200)

    assert %{"ok" => true, "deck" => %{"size" => 0}} =
             conn
             |> with_csrf()
             |> delete(~p"/papi/decks/#{id}/puzzles/#{p1}")
             |> json_response(200)
  end

  test "two saves at once take two positions", %{conn: conn, puzzles: [p1, p2]} do
    {_conn, user} = signed_in(conn, "own@oskol.test")
    {:ok, deck} = OwnDecks.create(user.id, "RACE0001", "Race", 5)

    [p1, p2]
    |> Task.async_stream(&OwnDecks.add_member(deck.id, &1), timeout: :infinity)
    |> Enum.to_list()

    assert [1, 2] = deck.id |> Oskol.Puzzles.deck_members() |> Enum.map(& &1.position)
  end

  test "saving a position somebody analyzed leaves it out of strangers' practice", %{
    conn: conn,
    puzzles: [p1, _]
  } do
    {conn, _user} = signed_in(conn, "own@oskol.test")

    from(p in Oskol.Puzzles.Puzzle, where: p.id == ^p1)
    |> Repo.update_all(set: [origin: "analysis"])

    %{"deck" => %{"id" => id}} = conn |> create("Mine") |> json_response(200)

    conn
    |> with_csrf()
    |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p1})
    |> json_response(200)

    assert Repo.one(from(p in Oskol.Puzzles.Puzzle, where: p.id == ^p1, select: p.origin)) ==
             "analysis"

    refute p1 in Enum.map(Oskol.Puzzles.sample(1000), & &1.id)
  end

  test "names: trimmed, unique per owner in any case, free again once deleted", %{conn: conn} do
    {conn, user} = signed_in(conn, "own@oskol.test")
    {other_conn, _} = signed_in(build_conn(), "other@oskol.test")

    %{"deck" => %{"id" => id}} = conn |> create("Primes") |> json_response(200)

    assert %{"ok" => false, "error" => %{"code" => "name_taken"}} =
             conn |> create("PRIMES") |> json_response(422)

    # Somebody else may have one called that.
    assert %{"ok" => true} = other_conn |> create("primes") |> json_response(200)

    # The index is the last word, under the handler's own check.
    assert {:error, :name_taken} = OwnDecks.create(user.id, "ZZZZZZZZ", "pRiMeS", 5)

    assert %{"ok" => false, "error" => %{"code" => "name_missing"}} =
             conn |> create("   ") |> json_response(422)

    # Renamed in place.
    assert %{"deck" => %{"name" => "Prime walls"}} =
             conn
             |> with_csrf()
             |> patch(~p"/papi/decks/#{id}", %{"name" => "Prime walls"})
             |> json_response(200)

    # Deleted: out of own/1, and every door is a 404; the name is free.
    assert %{"ok" => true} =
             conn |> with_csrf() |> delete(~p"/papi/decks/#{id}") |> json_response(200)

    assert OwnDecks.own(user.id) == []
    assert conn |> get(~p"/papi/decks/#{id}") |> json_response(404)
    assert conn |> get(~p"/papi/practice/decks/#{id}") |> json_response(404)
    assert %{"ok" => true} = conn |> create("Prime walls") |> json_response(200)
  end

  test "fifty sets is the most", %{conn: conn} do
    {conn, user} = signed_in(conn, "own@oskol.test")

    for n <- 1..50 do
      {:ok, _} =
        OwnDecks.create(user.id, "S" <> String.pad_leading("#{n}", 7, "0"), "Set #{n}", 5)
    end

    assert %{"error" => %{"code" => "too_many_sets", "message" => "That is a lot of sets"}} =
             conn |> create("One more") |> json_response(422)
  end

  test "a set is its owner's: a stranger and a guest are told it is not there", %{
    conn: conn,
    puzzles: [p1, _]
  } do
    {owner_conn, _} = signed_in(conn, "own@oskol.test")
    %{"deck" => %{"id" => id}} = owner_conn |> create("Mine") |> json_response(200)
    {stranger, _} = signed_in(build_conn(), "stranger@oskol.test")

    for c <- [stranger, build_conn()] do
      assert %{"ok" => false} = c |> get(~p"/papi/decks/#{id}") |> json_response(404)
      assert c |> get(~p"/papi/decks/#{id}/puzzles") |> json_response(404)
      assert c |> get(~p"/papi/practice/decks/#{id}") |> json_response(404)

      assert c
             |> with_csrf()
             |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => p1})
             |> json_response(404)

      assert c |> with_csrf() |> delete(~p"/papi/decks/#{id}") |> json_response(404)
    end

    # A guest has no sets, and is asked to sign in to make one.
    assert %{"ok" => true, "decks" => []} =
             build_conn() |> get(~p"/papi/decks/mine") |> json_response(200)

    assert %{"error" => %{"code" => "sign_in"}} =
             build_conn() |> as_guest(a_guest_id()) |> create("Mine") |> json_response(409)

    # The page itself is a 404 for anybody else, and noindex for its owner.
    assert_error_sent 404, fn -> get(stranger, ~p"/practice/#{id}") end
    page = owner_conn |> get(~p"/practice/#{id}") |> html_response(200)
    assert page =~ "noindex"
    assert page =~ "Mine · Practice"

    # A puzzle that is not there is not saved.
    assert %{"error" => %{"code" => "not_found"}} =
             owner_conn
             |> with_csrf()
             |> post(~p"/papi/decks/#{id}/puzzles", %{"puzzle_id" => "nope"})
             |> json_response(404)
  end
end
