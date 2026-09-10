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
    %{game_id: game_id, p1: p1, t1: t1} = lobby("match3", clock: "blitz")

    row = game_row(game_id)
    assert row.slug == "backgammon"
    assert row.status == "waiting"
    assert row.config["format"] == "match3"
    assert row.config["clock"] == "blitz"
    assert [%{"id" => ^p1, "name" => "Alice", "token" => ^t1}] = row.players
  end

  test "a full game writes playing on start, every action in order, and finished with winners" do
    %{game_id: game_id, p1: p1, t1: t1} = fixture = started(42)

    row = game_row(game_id)
    assert row.status == "playing"
    assert row.seed == 42
    assert [%{"id" => ^p1, "token" => ^t1}, %{"id" => p2, "token" => t2}] = row.players
    assert p2 == fixture.p2 and t2 == fixture.t2

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

  test "a clock forfeit writes an expire entry and finishes the game" do
    # Go: no turn delay in front of the clock, so the forfeit lands at once.
    %{game_id: game_id, p1: p1} =
      lobby("9x9", slug: "go", seed: 11, control: {:fischer, 150, 0})

    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
    {:ok, p2, state} = Game.join_game(game_id, "Bob", nil)
    mover = mover(state.instance, [p1, p2])
    waiting = if mover == p1, do: p2, else: p1

    assert_receive {:game_state_updated, _started, []}
    assert_receive {:game_state_updated, %{instance: instance}, _events}, 1000
    assert Oskol.GameKit.finished?(instance)

    assert [%{kind: "expire", player_id: nil, payload: nil}] = action_rows(game_id)
    row = game_row(game_id)
    assert row.status == "finished"
    assert row.winners == [waiting]
  end

  test "a rematch writes a second game row carrying the seats and tokens over" do
    %{game_id: game_id, p1: p1, p2: p2, t1: t1, t2: t2} = started(42)
    assert {:finished, _} = Oskol.Bots.play(game_id, 7, 5000)

    assert {:ok, nil} = Game.request_rematch(game_id, p1)
    assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)

    row = game_row(rematch_id)
    assert row.status == "playing"
    assert row.slug == "backgammon"
    assert Enum.map(row.players, & &1["id"]) == [p1, p2]
    assert Enum.map(row.players, & &1["token"]) == [t1, t2]
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
