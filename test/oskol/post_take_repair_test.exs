defmodule Oskol.PostTakeRepairTest do
  @moduledoc """
  The repair for `bg-post-take-cube`, on real rows: a puzzle of a roll after
  a taken double that was asked on the cube from before it goes, with its
  practice card, and its game is owed puzzles again; everything else stays.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game.Persister
  alias Oskol.Puzzles
  alias Oskol.Puzzles.PostTakeRepair
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # Turn 2 was a double, taken; turns 1 and 3 were plain rolls.
  defp report do
    %{
      "turns" => [
        %{"number" => 1, "double" => nil},
        %{"number" => 2, "double" => "take"},
        %{"number" => 3, "double" => nil}
      ]
    }
  end

  defp puzzle(id, cube) do
    %{
      key: "key-" <> id,
      ids: [id],
      kind: "move",
      question: %{
        "version" => 1,
        "kind" => "move",
        "board" => List.duplicate(0, 26),
        "dice" => [6, 4],
        "cube" => cube,
        "score" => nil,
        "crawford" => false,
        "jacoby" => false
      },
      answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
      evaluated_by: %{"levels" => %{}},
      complete: true
    }
  end

  defp source(id, turn, player_id) do
    %{
      key: "key-" <> id,
      game_number: 1,
      turn: turn,
      kind: "move",
      seat: 0,
      player_id: player_id,
      played: "13/9 13/7",
      equity_lost: 0.09,
      grade: "bad",
      skipped_reason: nil
    }
  end

  # A game graded with two mistakes: the roll after the take, asked on the
  # centred 1-cube it was not played on, and an ordinary roll. Each is a
  # card in an account's deck.
  defp graded_game do
    %{game_id: game_id, p1: p1} = started()
    Persister.flush()
    :ok = Oskol.Reviews.save(game_id, 1, "done", 1, %{"turns" => []}, nil, report(), 3)

    {:ok, _} =
      Puzzles.store(
        game_id,
        1,
        [
          puzzle("BADTAKE1", %{"value" => 1, "owner" => "center"}),
          puzzle("PLAINRL1", %{"value" => 1, "owner" => "center"})
        ],
        [source("BADTAKE1", 2, p1), source("PLAINRL1", 1, p1)]
      )

    uid = Oskol.Auth.find_or_create_user("taker@oskol.test").id
    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")

    {:ok, _} =
      Retain.put_items(uid, [
        %{key: "BADTAKE1", tags: %{}, content: %{}},
        %{key: "PLAINRL1", tags: %{}, content: %{}}
      ])

    game_id
  end

  defp puzzle_ids, do: from(p in Puzzles.Puzzle, select: p.id) |> Repo.all() |> Enum.sort()

  defp card_keys,
    do: from(i in Retain.Item, select: i.key) |> Repo.all() |> Enum.sort()

  defp extracted_at(game_id) do
    from(r in Oskol.Reviews.Review,
      where: r.game_id == ^game_id and r.game_number == 1,
      select: r.puzzles_extracted_at
    )
    |> Repo.one()
  end

  test "a dry run names the bad puzzle and writes nothing" do
    game_id = graded_game()

    assert %{found: [found], removed: nil} = PostTakeRepair.run(false)
    assert found.puzzle_id == "BADTAKE1"
    assert found.turn == 2
    assert puzzle_ids() == ["BADTAKE1", "PLAINRL1"]
    assert card_keys() == ["BADTAKE1", "PLAINRL1"]
    assert extracted_at(game_id) != nil
  end

  test "a write removes the bad puzzle and its card, keeps the rest, and reopens the game" do
    game_id = graded_game()

    assert %{removed: %{sources: 1, puzzles: 1, cards: 1, games: 1}} = PostTakeRepair.run(true)
    assert puzzle_ids() == ["PLAINRL1"]
    assert card_keys() == ["PLAINRL1"]
    # Owed again: the sweep extracts it with the cube the roll was played on.
    assert extracted_at(game_id) == nil

    # A second run finds nothing.
    assert %{found: []} = PostTakeRepair.run(true)
  end

  test "a post-take puzzle already asked on the opponent's doubled cube is left alone" do
    %{game_id: game_id, p1: p1} = started()
    Persister.flush()
    :ok = Oskol.Reviews.save(game_id, 1, "done", 1, %{"turns" => []}, nil, report(), 3)

    {:ok, _} =
      Puzzles.store(
        game_id,
        1,
        [puzzle("GOODTAK1", %{"value" => 2, "owner" => "opponent"})],
        [source("GOODTAK1", 2, p1)]
      )

    assert %{found: []} = PostTakeRepair.run(true)
    assert puzzle_ids() == ["GOODTAK1"]
  end
end
