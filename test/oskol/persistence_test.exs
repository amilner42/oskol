defmodule Oskol.PersistenceTest do
  # The room writes behind from its own process (via Oskol.Game.Persister),
  # so these tests own a shared sandbox connection and must not run async.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.Persister
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      # Drain the write queue before the owner goes: a write mid-flight
      # against a dying connection would only add noise.
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp game_row(game_id) do
    Persister.flush()
    Repo.get(Persistence.Game, game_id)
  end

  defp action_rows(game_id) do
    Persister.flush()

    from(a in Persistence.GameAction, where: a.game_id == ^game_id, order_by: a.index)
    |> Repo.all()
  end

  test "a lobby writes a waiting row with the setup and the seated player" do
    %{game_id: game_id, p1: p1, g1: g1} = lobby("match3", clock: "bg3")

    row = game_row(game_id)
    assert row.slug == "backgammon"
    assert row.status == "waiting"
    assert row.config["format"] == "match3"
    assert row.config["clock"] == "bg3"
    assert [%{"id" => ^p1, "name" => "Alice", "guest_id" => ^g1}] = row.players
    refute Map.has_key?(hd(row.players), "token")
  end

  test "a full game writes playing on start, every action in order, and finished with winners" do
    %{game_id: game_id, p1: p1, g1: g1} = fixture = started(42)

    row = game_row(game_id)
    assert row.status == "playing"
    assert row.seed == 42
    assert [%{"id" => ^p1, "guest_id" => ^g1}, %{"id" => p2, "guest_id" => g2}] = row.players
    assert p2 == fixture.p2 and g2 == fixture.g2

    assert {:finished, steps} = Oskol.Bots.play(game_id, 7, 5000)

    actions = action_rows(game_id)
    assert length(actions) == steps
    assert Enum.map(actions, & &1.index) == Enum.to_list(0..(steps - 1))
    assert Enum.all?(actions, &(&1.kind == "action" and is_map(&1.payload)))
    assert Enum.all?(actions, &(&1.player_id in [p1, p2]))
    # Offsets never run backwards: the log replays on this timeline.
    assert Enum.map(actions, & &1.at_ms) == Enum.sort(Enum.map(actions, & &1.at_ms))

    row = game_row(game_id)
    assert row.status == "finished"
    assert length(row.winners) == 1 and hd(row.winners) in [p1, p2]
  end

  @tag :slow
  test "a clock forfeit writes an expire entry and finishes the game" do
    # 150 ms of bank behind backgammon's 12 s turn delay: the forfeit lands
    # just over 12 s after the opening roll.
    %{game_id: game_id, p1: p1} =
      lobby("single", seed: 11, control: {:fischer, 150, 0})

    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
    {:ok, p2, state} = Game.join_game(game_id, "Bob", nil)
    mover = mover(state.instance, [p1, p2])
    waiting = if mover == p1, do: p2, else: p1

    assert_receive {:game_state_updated, _started, []}
    assert_receive {:game_state_updated, %{instance: instance}, _events}, 14_000
    assert Oskol.GameKit.finished?(instance)

    assert [%{kind: "expire", player_id: nil, payload: nil}] = action_rows(game_id)
    row = game_row(game_id)
    assert row.status == "finished"
    assert row.winners == [waiting]
  end

  test "a rematch writes a second game row carrying the seats and their guests over" do
    %{game_id: game_id, p1: p1, p2: p2, g1: g1, g2: g2} = started(42)
    assert {:finished, _} = Oskol.Bots.play(game_id, 7, 5000)

    assert {:ok, nil} = Game.request_rematch(game_id, p1)
    assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)

    row = game_row(rematch_id)
    assert row.status == "playing"
    assert row.slug == "backgammon"
    assert Enum.map(row.players, & &1["id"]) == [p1, p2]
    assert Enum.map(row.players, & &1["guest_id"]) == [g1, g2]
    # A fresh game, not a continuation of the old log.
    assert game_row(game_id).status == "finished"
  end

  test "create_game never hands out a code a persisted game still holds" do
    taken = unique_game_id("taken")
    free = unique_game_id("free")
    Repo.insert!(%Persistence.Game{id: taken, slug: "backgammon", status: "finished"})

    {:ok, agent} = Agent.start_link(fn -> [taken, free] end)
    generate = fn -> Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end) end

    assert {:ok, ^free} = Game.create_game("backgammon", generate)
  end
end

defmodule Oskol.Persistence.SeatedRoomsTest do
  # Which rooms a guest holds a seat in, from the rows alone.
  use ExUnit.Case, async: false

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.Persister
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "lists the unfinished rooms a guest holds a seat in, newest first, and nobody else's" do
    # Alice's lobby, then a game she started with Bob.
    %{game_id: lobby_id, g1: alice} = lobby("single")
    %{game_id: playing_id, p2: bob_seat, g2: bob} = started(42)
    # Alice takes the second seat of a third room too, after the others.
    %{game_id: third_id} = lobby("match3")
    {:ok, _, _} = Game.join_game(third_id, "Ann", nil, alice)
    Persister.flush()

    ids = Persistence.seated_rooms(alice) |> Enum.map(& &1.id)
    assert third_id in ids and lobby_id in ids
    refute playing_id in ids
    # Newest activity first: the third room was touched last.
    assert List.first(ids) == third_id

    assert Persistence.seated_rooms(bob) |> Enum.map(& &1.id) == [playing_id]
    assert Persistence.seated_rooms("nobody-at-all") == []
    assert Persistence.seated_rooms(nil) == []
    assert Persistence.seated_rooms("") == []

    # A finished game is not something to resume.
    Persistence.mark_finished(playing_id, [bob_seat])
    assert Persistence.seated_rooms(bob) == []
  end
end

defmodule Oskol.Persistence.SeatedRoomsIndexTest do
  # This is deliberately a database test rather than a query-string test:
  # it protects the expression-index contract between the migration and the
  # Ecto fragment. A small table naturally gets a sequential scan, so make a
  # representative unfinished-room set and ask the normal planner for both
  # holder shapes.
  use ExUnit.Case, async: false

  alias Oskol.Persistence
  alias Oskol.Repo

  @guest "index-target-guest"
  @user "index-target-user"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "the unfinished-room index serves guest and account containment" do
    now = DateTime.utc_now()

    rows =
      for n <- 1..10_000 do
        holder =
          case n do
            9_997 -> %{"guest_id" => @guest}
            9_998 -> %{"user_id" => @user}
            _ -> %{"guest_id" => "guest-#{n}"}
          end

        %{
          id: "seat-index-#{n}",
          slug: "backgammon",
          config: %{},
          players: [Map.put(holder, "id", "p1")],
          status: if(rem(n, 4) == 0, do: "finished", else: "playing"),
          winners: [],
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn batch ->
      {count, nil} = Repo.insert_all(Persistence.Game, batch)
      assert count == length(batch)
    end)

    Repo.query!("ANALYZE games")

    assert ["seat-index-9997"] = Persistence.seated_rooms(@guest) |> Enum.map(& &1.id)

    assert ["seat-index-9998"] =
             Persistence.seated_rooms("another-browser", @user) |> Enum.map(& &1.id)

    assert index_plan(@guest) =~ "games_unfinished_players_gin"
    assert index_plan("another-browser", @user) =~ "games_unfinished_players_gin"
  end

  defp index_plan(guest_id, user_id \\ nil) do
    query = Persistence.seated_rooms_query(guest_id, user_id)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

    Repo.query!(
      "EXPLAIN (COSTS OFF) " <> sql,
      params
    )
    |> Map.fetch!(:rows)
    |> Enum.map_join("\n", fn [line] -> line end)
  end
end
