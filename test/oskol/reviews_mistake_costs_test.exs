defmodule Oskol.ReviewsMistakeCostsTest do
  @moduledoc """
  `Oskol.Reviews.mistake_costs/1` -- the rows "what your mistakes cost you"
  subtracts -- against real tables: whose rows it returns, which it leaves
  out, that it reaches the seats through the players index, and what a
  whole cost read (it and `graded_for/2`) costs on a heavy account.

  The maths and the holder rule over these rows are tested in Gleam
  (test/oskol/cost_test.gleam).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Persistence
  alias Oskol.Puzzles
  alias Oskol.Repo
  alias Oskol.Reviews

  # The ticket's ceiling for a list read that carries the cost.
  @budget_ms 150

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp a_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp a_room(id, players) do
    Repo.insert!(%Persistence.Game{
      id: id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: players,
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    id
  end

  defp seat(id, opts \\ []) do
    %{"id" => id, "name" => id, "guest_id" => Keyword.get(opts, :guest, a_guest_id())}
    |> then(fn s ->
      case Keyword.get(opts, :user) do
        nil -> s
        user -> Map.put(s, "user_id", user)
      end
    end)
  end

  defp a_puzzle(id) do
    Repo.insert_all(
      Puzzles.Puzzle,
      [
        %{
          id: id,
          key: "key-" <> id,
          kind: "move",
          question: %{},
          answer: %{},
          evaluated_by: %{},
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing
    )

    id
  end

  defp a_source(game_id, turn, player_id, opts \\ []) do
    puzzle_id =
      case Keyword.fetch(opts, :puzzle) do
        {:ok, nil} -> nil
        {:ok, id} -> a_puzzle(id)
        :error -> a_puzzle("p-#{game_id}-#{turn}")
      end

    Repo.insert!(%Puzzles.Source{
      puzzle_id: puzzle_id,
      game_id: game_id,
      game_number: Keyword.get(opts, :game_number, 1),
      turn: turn,
      kind: "move",
      seat: if(player_id == "p1", do: 0, else: 1),
      player_id: player_id,
      played: "13/8 13/11",
      equity_lost: Keyword.get(opts, :lost, 0.061),
      grade: Keyword.get(opts, :grade, "bad"),
      skipped_reason: Keyword.get(opts, :skipped),
      owner_user_id: Keyword.get(opts, :owner)
    })
  end

  test "the account's seat's mistakes, with the seat, and nothing else" do
    me = Auth.find_or_create_user("costs1@oskol.test")
    other = Auth.find_or_create_user("costs2@oskol.test")
    guest = a_guest_id()

    game =
      a_room("mc0001", [seat("p1", user: me.id, guest: guest), seat("p2", user: other.id)])

    a_source(game, 1, "p1", grade: "very_bad", lost: 0.25, owner: me.id)
    a_source(game, 2, "p2", owner: other.id)
    # Skipped: a source with a reason and no puzzle, never a cost.
    a_source(game, 3, "p1", puzzle: nil, skipped: "post_take_cube", owner: me.id)
    a_source(game, 4, "p1", game_number: 2, grade: "doubtful", lost: 0.03, owner: me.id)

    # A game this account has no seat in.
    a_room("mc0002", [seat("p1"), seat("p2", user: other.id)])
    a_source("mc0002", 1, "p1")

    assert [first, second] = Reviews.mistake_costs(me.id)

    assert %{
             puzzle_id: "p-mc0001-1",
             band: "very_bad",
             game_id: "mc0001",
             game_number: 1,
             equity_lost: 0.25,
             player_id: "p1",
             guest_id: ^guest,
             user_id: user_id,
             bot: false
           } = first

    assert user_id == me.id
    assert %{game_number: 2, band: "doubtful"} = second

    # And across the boundary, as Gleam reads it: a MistakeCost with a seat
    # the holder rule can be asked of.
    {:analysis_caps, _log, _stored, _ratings, _summaries, _report, _save, _backfill_turns,
     _enqueue, _review, _report_turn, _charge, _replace, _grades, _forget_grades, _graded_for,
     _graded_rooms_for, mistake_costs, _ask_budget, _asking, _submit, _allow_ask, _release_ask} =
      Oskol.Gleam.Caps.Analysis.build()

    assert [
             {:mistake_cost, "p-mc0001-1", "very_bad", "mc0001", 1,
              {:seat, "p1", {:some, ^guest}, {:some, _}, false}, 0.25},
             _
           ] = mistake_costs.(me.id)

    assert [] = Reviews.mistake_costs(Ecto.UUID.generate())
  end

  test "a seat that came to the account later is found, however its owner column reads" do
    me = Auth.find_or_create_user("costs3@oskol.test")
    guest = a_guest_id()

    # Played as a guest: the mistakes are written with nobody owning them.
    game = a_room("mc0003", [seat("p1", guest: guest), seat("p2")])
    a_source(game, 1, "p1")
    a_source(game, 2, "p1")
    assert [] = Reviews.mistake_costs(me.id)

    # The sign-in stamps the seat...
    {1, _} =
      Repo.update_all(
        from(g in Persistence.Game, where: g.id == ^game),
        set: [players: [seat("p1", guest: guest, user: me.id), seat("p2")]]
      )

    # ...and before `refresh_owners` has caught the sources up, the seat is
    # already what finds them: a stale index key cannot leave a game's error
    # in the rating while dropping its mistakes.
    assert [_, _] = Reviews.mistake_costs(me.id)

    :ok = Puzzles.refresh_owners([game])
    assert [%{user_id: user_id}, _] = Reviews.mistake_costs(me.id)
    assert user_id == me.id
  end

  test "the seats are reached through the players index" do
    me = Auth.find_or_create_user("costs4@oskol.test")

    for i <- 1..20 do
      id = a_room("mce#{i}", [seat("p1", user: me.id), seat("p2")])
      a_source(id, 1, "p1")
    end

    # Everybody else's mistakes: the set a plan must never start from.
    for i <- 1..100 do
      id = a_room("mco#{i}", [seat("p1", user: Ecto.UUID.generate()), seat("p2")])
      for t <- 1..3, do: a_source(id, t, "p1")
    end

    Repo.query!("ANALYZE games")
    Repo.query!("ANALYZE puzzle_sources")

    {sql, params} = Reviews.mistake_costs_sql(me.id)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL enable_seqscan = off")
      Repo.query!("SET LOCAL enable_indexscan = off")
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      plan = rows |> List.flatten() |> Enum.join("\n")
      assert plan =~ "games_players_gin", plan
    end)
  end

  describe "what it costs" do
    @tag :slow
    test "three hundred graded games and their mistakes read inside the budget" do
      me = Auth.find_or_create_user("costs5@oskol.test")
      turns = bulky_turns()

      for g <- 1..300 do
        id = "mcb" <> String.pad_leading(Integer.to_string(g), 4, "0")
        a_room(id, [seat("p1", user: me.id), seat("p2")])

        :ok =
          Reviews.save(
            id,
            1,
            "done",
            1,
            %{"players" => [totals(0.4, 40), totals(0.6, 40)], "turns" => turns},
            nil,
            nil,
            30
          )

        # Five mistakes a game, about what prod's heaviest account makes.
        for t <- 1..5,
            do: a_source(id, t, "p1", grade: Enum.at(~w(very_bad bad doubtful), rem(t, 3)))
      end

      Repo.query!("ANALYZE")

      ctx = Oskol.Gleam.CtxBuilder.build()
      session = {:session, {:some, "a-guest"}, {:some, me.id}}
      read = fn -> :oskol@practice@cost.read(ctx, session) end

      {:some, {:window, rated, costs}} = read.()
      assert length(rated) == 300
      assert length(costs) == 1500

      {ms, times} = median_ms(read)
      {query_ms, _} = median_ms(fn -> Reviews.mistake_costs(me.id) end)

      IO.puts(
        "\n  cost read, 300 graded games and 1500 mistakes: median #{Float.round(ms, 1)} ms " <>
          "(#{Enum.map_join(times, ", ", &Float.round(&1, 1))}); mistake_costs alone " <>
          "#{Float.round(query_ms, 1)} ms"
      )

      assert ms < @budget_ms
    end
  end

  defp totals(error, decisions) do
    %{
      "moves" => %{"decisions" => decisions, "forced" => 0, "error" => error, "grades" => %{}},
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.0,
      "error" => error,
      "pr" => error / decisions * 500
    }
  end

  defp median_ms(work) do
    work.()

    times =
      for _ <- 1..5 do
        {us, _} = :timer.tc(work)
        us / 1000
      end

    {Enum.at(Enum.sort(times), 2), times}
  end

  # An engine answer the size production stores, so reaching past it into
  # the totals costs what it really costs.
  defp bulky_turns do
    candidates =
      for rank <- 1..20 do
        %{
          "rank" => rank,
          "move" => "24/23 13/11",
          "equity" => 0.123_456,
          "equity_diff" => -0.01 * rank,
          "board" => Enum.to_list(1..26),
          "probs" => %{
            "win" => 0.5,
            "gammon_win" => 0.1,
            "backgammon_win" => 0.01,
            "gammon_loss" => 0.1,
            "backgammon_loss" => 0.01
          }
        }
      end

    for number <- 1..60 do
      %{
        "number" => number,
        "player" => rem(number, 2),
        "dice" => [3, 1],
        "board" => Enum.to_list(1..26),
        "candidates" => candidates
      }
    end
  end
end
