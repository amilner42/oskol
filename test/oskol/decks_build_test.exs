defmodule Oskol.DecksBuildTest do
  @moduledoc """
  Building the universal decks against the real tables, with an engine that
  answers every legal play (`Oskol.CompleteEngine`). What decides -- which
  positions, what is trusted -- is Gleam's; what is under test here is the
  whole run: the engine asked only for what is missing, the answers written
  as puzzles in their decks in order, and nothing asked twice.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Req.Test.set_req_test_to_shared()
    :ok
  end

  defp report(reports, deck) do
    Enum.find(reports, fn {:report, d, _, _, _, _, _, _} -> d == deck end)
  end

  defp nobody_asked do
    Req.Test.stub(Oskol.Reviews, fn _conn -> flunk("the engine was asked") end)
  end

  defp members(deck) do
    Repo.all(
      from(m in "deck_puzzles",
        join: p in "puzzles",
        on: p.id == m.puzzle_id,
        where: m.deck == ^deck,
        order_by: m.position,
        select: %{
          position: m.position,
          question: p.question,
          answer: p.answer,
          complete: p.complete
        }
      )
    )
  end

  test "a dry run counts what it would ask and asks nobody" do
    nobody_asked()
    reports = Oskol.Decks.build(false)

    assert {:report, "openings", 15, 0, 0, 0, 0, ["dry run: 15 to ask"]} =
             report(reports, "openings")

    # No opening is stored, so every reply waits on its opening.
    assert {:report, "opening_replies", 315, 0, 0, 0, 315, []} =
             report(reports, "opening_replies")

    assert members("openings") == []
  end

  @tag timeout: 120_000
  test "a write builds both decks, complete and in order, and a second run asks nobody" do
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
    reports = Oskol.Decks.build(true)

    assert {:report, "openings", 15, 0, 15, 15, 0, []} = report(reports, "openings")
    {:report, "opening_replies", 315, 0, 315, added, 0, []} = report(reports, "opening_replies")

    openings = members("openings")
    best = fn o -> Enum.find(o.answer["candidates"], &(&1["rank"] == 1))["board"] end

    # A reply is its position, so two openings whose best plays leave the
    # same board (4-1 and 3-2 can both play 24/19) share one set of replies.
    # The stub engine's arbitrary "best" does that; the real one's does not.
    distinct = openings |> Enum.map(best) |> Enum.uniq() |> length()
    assert added == 21 * distinct
    assert length(openings) == 15
    assert Enum.map(openings, & &1.position) == Enum.to_list(1..15)
    assert Enum.all?(openings, & &1.complete)
    # The first is 2-1 from the starting position, money play with Jacoby.
    first = hd(openings).question
    assert first["dice"] == [2, 1]
    assert first["score"] == nil
    assert first["jacoby"] == true
    assert first["cube"] == %{"value" => 1, "owner" => "center"}
    assert first["board"] == :backgammon@analysis.encode(:backgammon@board.initial(), :white)

    replies = members("opening_replies")
    assert length(replies) == added
    assert Enum.all?(replies, & &1.complete)
    # Grouped by opening: the replies to 2-1 come first, all 21 rolls, and
    # they are played from the board 2-1's best play left, turned round.
    [reply | _] = replies
    assert reply.position == 101
    assert reply.question["board"] == :oskol@puzzles.flip(best.(hd(openings)))
    assert Enum.count(replies, &(div(&1.position, 100) == 1)) in [0, 21]

    # Only the top five are candidates: the play named in the request was
    # any legal one, and a reveal has no place for it.
    assert Enum.all?(openings, fn o -> Enum.all?(o.answer["candidates"], &(&1["rank"] <= 5)) end)

    nobody_asked()
    again = Oskol.Decks.build(true)
    assert {:report, "openings", 15, 15, 0, 0, 0, []} = report(again, "openings")

    assert {:report, "opening_replies", 315, ^added, 0, 0, 0, []} =
             report(again, "opening_replies")
  end

  test "an answer that is not complete is not written, and says why" do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      # The real answer with the list of every legal play cut short.
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      answer = Oskol.CompleteEngine.answer(Jason.decode!(body))

      truncated =
        update_in(answer["turns"], fn turns ->
          Enum.map(turns, fn t ->
            put_in(t, ["move", "results"], Enum.take(t["move"]["results"], 3))
          end)
        end)

      Req.Test.json(conn, truncated)
    end)

    reports = Oskol.Decks.build(true)
    {:report, "openings", 15, 0, 15, 0, 0, failures} = report(reports, "openings")
    assert length(failures) == 15
    assert hd(failures) =~ "every legal play"
    assert members("openings") == []
    # Nothing to reply to.
    assert {:report, "opening_replies", 315, 0, 0, 0, 315, []} =
             report(reports, "opening_replies")
  end
end
