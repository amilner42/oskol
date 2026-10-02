defmodule Oskol.StaleOwnerTest do
  @moduledoc """
  `puzzle_sources.owner_user_id` against the seats, on the real rows
  (`puzzles-stale-owner`).

  The deck finds a mistake by that column, so every write that hands a seat
  to an account has to leave its room's sources agreeing. Room 821900 on
  prod is what happens when one does not: a signed-in browser claimed an
  away seat in a room whose mistakes were already written, the room wrote
  its seat list with the account on it, and nothing told the sources -- so
  the account's deck never got the 93 mistakes on that seat.

  Each way a seat gains an owner is here once, and so is the operator's
  repair for the rooms that were already left behind.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.Persister
  alias Oskol.Persistence
  alias Oskol.Practice
  alias Oskol.Puzzles
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp account(email), do: Oskol.Auth.find_or_create_user(email).id

  # One graded game in this room, one mistake on each named seat, written
  # the way the review job writes them.
  defp mistakes(game_id, player_ids) do
    :ok = Oskol.Reviews.save(game_id, 1, "done", 1, %{"turns" => []}, nil, %{"turns" => []}, 3)

    puzzles =
      for player_id <- player_ids do
        %{
          key: "k-#{game_id}-#{player_id}",
          ids: ids_for(game_id, player_id),
          kind: "move",
          question: %{
            "version" => 1,
            "kind" => "move",
            "board" => List.duplicate(0, 26),
            "dice" => [6, 4],
            "cube" => %{"value" => 1, "owner" => "center"},
            "score" => nil,
            "crawford" => false,
            "jacoby" => false
          },
          answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
          evaluated_by: %{"levels" => %{}},
          complete: true
        }
      end

    sources =
      for {player_id, turn} <- Enum.with_index(player_ids, 1) do
        %{
          key: "k-#{game_id}-#{player_id}",
          game_number: 1,
          turn: turn,
          kind: "move",
          seat: turn - 1,
          player_id: player_id,
          played: "13/8 13/11",
          equity_lost: 0.061,
          grade: "bad",
          skipped_reason: nil
        }
      end

    {:ok, _} = Puzzles.store(game_id, 1, puzzles, sources)
    :ok
  end

  defp ids_for(game_id, player_id) do
    base =
      :crypto.hash(:sha256, game_id <> player_id)
      |> Base.encode32(padding: false)
      |> binary_part(0, 7)

    for n <- 1..4, do: base <> Integer.to_string(n)
  end

  defp owners(game_id) do
    from(s in Puzzles.Source,
      where: s.game_id == ^game_id,
      select: {s.player_id, s.owner_user_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cards(user_id) do
    case Retain.queue(user_id, limit: 50) do
      {:ok, %{new: new}} -> Enum.map(new, & &1.key)
      _ -> []
    end
  end

  # A room with mistakes already written and one seat's owner left behind:
  # the shape room 821900 is in on prod, made by writing the account onto
  # the seat the way a row from before the fix got it, with no refresh.
  defp a_stale_room(user_id) do
    %{game_id: game_id, p1: p1, p2: p2} = started()
    Persister.flush()
    :ok = mistakes(game_id, [p1, p2])

    players =
      for player <- Persistence.players(game_id) do
        if player["id"] == p1, do: Map.put(player, "user_id", user_id), else: player
      end

    from(g in Persistence.Game, where: g.id == ^game_id)
    |> Repo.update_all(set: [players: players])

    %{game_id: game_id, p1: p1, p2: p2}
  end

  describe "every way a seat gains an owner reaches its mistakes" do
    test "a signed-in browser claiming an away seat in a room with mistakes" do
      user = account("austin@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = started()
      Persister.flush()
      :ok = mistakes(game_id, [p1, p2])
      assert owners(game_id) == %{p1 => nil, p2 => nil}

      # Another device, signed in, takes the seat back from the invite link:
      # the seat is the account's now, and so are its mistakes.
      {:ok, ^p1, _} = Game.claim_seat(game_id, p1, self(), unique_guest_id(), user)
      Persister.flush()

      assert owners(game_id) == %{p1 => user, p2 => nil}
      assert {:ok, 1} = Practice.sync(user)
      assert length(cards(user)) == 1
    end

    test "a seat taken while signed in, whose mistakes come later" do
      user = account("joiner@oskol.test")
      %{game_id: game_id, p1: p1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, unique_guest_id(), user)
      Persister.flush()

      # The review job writes the sources with the seat's owner on them.
      :ok = mistakes(game_id, [p1, p2])
      assert owners(game_id) == %{p1 => nil, p2 => user}
    end

    test "any seat-list write a room makes agrees its sources with the row" do
      user = account("writer@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = a_stale_room(user)
      assert owners(game_id) == %{p1 => nil, p2 => nil}

      # A join, a claim and a start all write the whole list this way.
      :ok = Persistence.update_players(game_id, Persistence.players(game_id))

      assert owners(game_id) == %{p1 => user, p2 => nil}
    end

    test "the sign-in stamp, after the mistakes were written" do
      user = account("stamped@oskol.test")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, p2: p2, g1: g1} = started()
      Persister.flush()
      :ok = mistakes(game_id, [p1, p2])

      assert {:ok, 1} = Oskol.Gleam.Caps.Auth.stamp_seats(g1, fresh, user)
      Persister.flush()

      assert owners(game_id) == %{p1 => user, p2 => nil}
    end

    test "a rehydrate keeps the owner, and the sources with it" do
      user = account("rehydrated@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = started()
      {:ok, ^p1, _} = Game.claim_seat(game_id, p1, self(), unique_guest_id(), user)
      Persister.flush()
      :ok = mistakes(game_id, [p1, p2])

      # A deploy: the process goes, and the next lookup rebuilds it from the
      # row and the log.
      {:ok, pid} = Oskol.Game.GameSupervisor.find_game(game_id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(Oskol.Game.GameSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      Process.sleep(50)
      assert {:ok, _pid} = Game.lookup_game(game_id)
      assert Game.get_server_state(game_id).connections[p1].user_id == user
      Persister.flush()

      assert owners(game_id) == %{p1 => user, p2 => nil}
    end
  end

  describe "the repair (mix oskol.puzzles.refresh_owners)" do
    test "a dry run reports the room and the account and writes nothing" do
      user = account("austin@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = a_stale_room(user)

      output =
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Oskol.Puzzles.RefreshOwners.run([]) end)

      assert output =~ "room #{game_id}: 1 mistakes would be owned by #{user}"
      assert output =~ "account #{user}: 1 mistakes in 1 rooms, deck to sync"
      assert output =~ "1 rooms, 1 accounts, dry run"
      assert owners(game_id) == %{p1 => nil, p2 => nil}
      assert cards(user) == []
    end

    test "--write fixes the room, fills the deck, and a second run finds nothing" do
      user = account("austin@oskol.test")
      other = account("arie@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = a_stale_room(user)
      # A room that was never stale is not touched or reported.
      %{game_id: fine} = a_stale_room(other)
      :ok = Puzzles.refresh_owners([fine])

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Oskol.Puzzles.RefreshOwners.run(["--write"])
        end)

      assert output =~ "room #{game_id}: 1 mistakes now owned by #{user}"
      assert output =~ "account #{user}: 1 mistakes in 1 rooms, 1 new cards"
      refute output =~ fine
      assert owners(game_id) == %{p1 => user, p2 => nil}

      [source] =
        Repo.all(from(s in Puzzles.Source, where: s.game_id == ^game_id and s.player_id == ^p1))

      assert cards(user) == [source.puzzle_id]
      assert source.deck_synced_at != nil

      assert %{rooms: [], accounts: []} = Practice.refresh_owners(true)
    end

    test "the release twin is the same repair" do
      user = account("austin@oskol.test")
      %{game_id: game_id, p1: p1} = a_stale_room(user)

      ExUnit.CaptureIO.capture_io(fn ->
        assert %{rooms: [%{game_id: ^game_id}]} = Oskol.Release.refresh_owners(dry_run: true)
      end)

      assert owners(game_id)[p1] == nil

      ExUnit.CaptureIO.capture_io(fn ->
        assert %{accounts: [%{user_id: ^user, added: 1}]} =
                 Oskol.Release.refresh_owners(dry_run: false)
      end)

      assert owners(game_id)[p1] == user
    end
  end
end
