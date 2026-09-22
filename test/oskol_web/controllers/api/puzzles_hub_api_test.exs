defmodule OskolWeb.Api.PuzzlesHubApiTest do
  @moduledoc """
  The wiring behind TRY ONE: the route, the envelope, the 404 while the pool
  is empty, and that the pool is complete answers only. Which puzzle stands
  clear is Gleam's rule (test/oskol/puzzles_hub_test.gleam); this locks what
  only the server can be wrong about, and that the `sample` capability's
  tuple agrees with its Gleam record.
  """
  use OskolWeb.ConnCase, async: false

  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    # The table is global: nothing another test left behind is this one's.
    Repo.delete_all(Oskol.Puzzles.Puzzle)
    :ok
  end

  # A stored puzzle from the fixtures, whose best move stands clear (the
  # `move` sample's runner-up gives up 0.11), complete or not.
  defp a_puzzle(name, complete) do
    {:stored, _id, kind, question, answer} = :oskol@puzzles@fixture.stored_sample(name)
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    Repo.insert!(%Oskol.Puzzles.Puzzle{
      id: id,
      key: "hub-" <> id,
      kind: kind,
      question: Jason.decode!(question),
      answer: Jason.decode!(answer),
      evaluated_by: %{},
      complete: complete
    })

    id
  end

  describe "GET /papi/puzzles/random" do
    test "an empty pool is an honest 404, not an error", %{conn: conn} do
      body = conn |> get(~p"/papi/puzzles/random") |> json_response(404)
      assert %{"ok" => false, "error" => %{"code" => "not_found", "message" => message}} = body
      assert message =~ "no puzzles yet"
    end

    test "answers a stored puzzle by id, kind and question, and never the answer", %{
      conn: conn
    } do
      id = a_puzzle("move", true)
      body = conn |> get(~p"/papi/puzzles/random") |> json_response(200)
      assert %{"ok" => true, "id" => ^id, "kind" => "move", "prompt" => prompt} = body
      assert prompt == "White to play 6-4. What's your play?"
      refute Map.has_key?(body, "answer")
      refute inspect(body) =~ "equity"
    end

    test "the pool is complete answers only", %{conn: conn} do
      _ = a_puzzle("move", false)
      assert conn |> get(~p"/papi/puzzles/random") |> json_response(404)
    end

    test "'random' is not read as a puzzle id", %{conn: conn} do
      # Declared before /puzzles/:id: this is the hub's answer, not the
      # page's 404 for a puzzle called "random".
      body = conn |> get(~p"/papi/puzzles/random") |> json_response(404)
      assert body["error"]["message"] =~ "no puzzles yet"
    end
  end

  test "the sample capability crosses as its Gleam record says" do
    id = a_puzzle("double", true)

    {:puzzles_caps, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, sample} =
      Oskol.Gleam.Caps.Puzzles.build()

    assert [{:stored, ^id, "double", question, answer}] = sample.(5)
    assert is_binary(question) and is_binary(answer)
  end
end
