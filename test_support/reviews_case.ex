defmodule Oskol.ReviewsCase do
  @moduledoc """
  The ground the review-pipeline tests stand on: the queue turned on for the
  duration, an engine that is a `Req.Test` stub and never the network, and a
  room that can be played to a finish.

  It exists so those tests can live in more than one file. `bin/test-par`
  splits the suite by file, and the pipeline is the slowest thing in it: as
  one file it is the floor under every partitioned run, however many
  partitions there are. Split by subject and sharing this, the groups spread
  across partitions instead.

  The sandbox is shared and the case is not async on purpose -- rooms, the
  persister and the queue's tasks each reach the database from their own
  process, and the engine stub and the queue's `enabled` flag are global.
  Partitions give these tests a whole VM each, which is what lets them stay
  honest about that and still run beside one another.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import Oskol.GameFixtures
  import OskolWeb.ConnCase, only: [as_guest: 2]
  import Phoenix.ConnTest

  alias Oskol.Game.Persister
  alias Oskol.Reviews.Queue

  @endpoint OskolWeb.Endpoint

  using do
    quote do
      use OskolWeb.ConnCase, async: false

      import Ecto.Query
      import Oskol.GameFixtures
      import Oskol.ReviewsCase

      alias Oskol.Game.Persister
      alias Oskol.Repo
      alias Oskol.Reviews
      alias Oskol.Reviews.Queue
    end
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Oskol.Repo, shared: true)
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:oskol, Queue)
    Application.put_env(:oskol, Queue, enabled: true)

    on_exit(fn ->
      Queue.await_idle()
      Queue.reset()
      Application.put_env(:oskol, Queue, previous)
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  @doc "Everything the stub has reported so far, thrown away."
  def drain_engine_calls do
    receive do
      {:engine, _} -> drain_engine_calls()
    after
      0 -> :ok
    end
  end

  @doc """
  An engine that grades the opening turn best and every turn after it as a
  mistake worth 0.05 -- so a run really crosses the puzzle-extraction seam --
  and reports every request it gets to `test_pid`.
  """
  def engine(test_pid) do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      request = Jason.decode!(body)
      send(test_pid, {:engine, request})
      Req.Test.json(conn, answer(length(request["turns"])))
    end)
  end

  @doc "The engine's answer for an `n`-turn game, in its wire shape."
  def answer(n) do
    candidate = fn rank, diff ->
      %{
        "rank" => rank,
        "notation" => "13/10 6/5",
        "board" => [],
        "equity" => 0.1,
        "cubeless_equity" => 0.1,
        "equity_diff" => diff,
        "probs" => %{
          "win" => 0.5,
          "gammon_win" => 0.1,
          "backgammon_win" => 0.0,
          "gammon_loss" => 0.1,
          "backgammon_loss" => 0.0
        }
      }
    end

    totals = %{
      "moves" => %{"decisions" => n, "forced" => 0, "error" => 0.1, "grades" => %{"ok" => n}},
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.0,
      "error" => 0.1,
      "pr" => 4.2
    }

    # The opening turn is played perfectly; everything after it gives up
    # 0.05, which is a mistake and so a puzzle.
    move = fn
      0 ->
        %{
          "played" => candidate.(1, 0.0),
          "best" => candidate.(1, 0.0),
          "top" => [candidate.(1, 0.0)],
          "n_legal" => 4,
          "forced" => false,
          "error" => 0.0,
          "grade" => "best"
        }

      _ ->
        %{
          "played" => candidate.(2, -0.05),
          "best" => candidate.(1, 0.0),
          "top" => [candidate.(1, 0.0), candidate.(2, -0.05)],
          # `all_results`: one entry per legal play, which is what lets a
          # puzzle grade any answer instead of shrugging at one outside the
          # top five.
          "results" =>
            for r <- 1..4 do
              %{"board" => [], "equity_diff" => -0.01 * r}
            end,
          "n_legal" => 4,
          "forced" => false,
          "error" => 0.05,
          "grade" => "doubtful"
        }
    end

    %{
      "turns" =>
        for i <- 0..(n - 1) do
          %{
            "index" => i,
            "cube" => nil,
            "move" => move.(i),
            "luck" => %{"luck" => 0.1}
          }
        end,
      "players" => [totals, totals]
    }
  end

  @doc "A room played to a finish by the bots, at `seed`."
  def finished_game(seed) do
    %{game_id: game_id} = started(seed, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, seed, 3000)
    game_id
  end

  @doc """
  The guest holding one of the room's seats: reading a review is open to
  anyone, but only a player's visit queues one.
  """
  def seat_guest(game_id) do
    state = Oskol.Game.get_server_state(game_id)
    [{player, _name} | _] = Oskol.Game.GameServerState.seats(state)
    Oskol.GameFixtures.guest_for(game_id, player)
  end

  @doc "The room casts the queue as the game ends; wait for the job to land."
  def wait_for(fun, tries \\ 200) do
    Queue.await_idle()

    case fun.() do
      result when result in [nil, false, []] and tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end

  @doc """
  Commit exactly one turn without letting the generic random bot choose
  cube, resignation, undo, or any other legal action added by a game UI.
  """
  def play_one_turn(game_id, player_id) do
    state = Oskol.Game.get_server_state(game_id)
    legal = Oskol.GameKit.legal(state.instance, player_id)

    schema =
      Enum.find(legal, &(&1["name"] == "play")) ||
        Enum.find(legal, &(&1["name"] == "move"))

    assert schema
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, player_id, Oskol.Bots.action(schema))

    if schema["name"] == "move", do: play_one_turn(game_id, player_id)
  end

  @doc "One game of a match finished by resignation, and the writes flushed."
  def finish_one_game(game_id, p1, p2) do
    first = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
    play_one_turn(game_id, first)
    first = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
    second = if first == p1, do: p2, else: p1

    assert {:ok, _, _} =
             Oskol.Game.player_action(game_id, first, %{
               "name" => "resign",
               "params" => %{"stakes" => "single"}
             })

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, second, simple("accept_resign"))
    Persister.flush()
  end

  @doc "Every SQL query `fun` causes, in order."
  def read_queries(fun) do
    id = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:oskol, :repo, :query],
        fn _, _, meta, {pid, tag} ->
          send(pid, {tag, meta.query})
        end,
        {parent, id}
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_queries(id, [])
  end

  defp drain_queries(id, queries) do
    receive do
      {^id, query} -> drain_queries(id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  @doc "The reviews index for a room, read as one of its players."
  def reviews(conn, game_id) do
    conn
    |> as_guest(seat_guest(game_id))
    |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
    |> json_response(200)
  end

  @doc "One review of a room, read as one of its players."
  def review(conn, game_id, number) do
    conn
    |> as_guest(seat_guest(game_id))
    |> get("/papi/games/backgammon/rooms/#{game_id}/reviews/#{number}")
    |> json_response(200)
  end
end
