defmodule Oskol.Puzzles.PicturesTest do
  @moduledoc """
  A puzzle's picture: drawn off a request, stored once, bounded when it
  cannot be.

  What the picture shows is Gleam's and tested there
  (test/oskol/puzzle_picture_test.gleam). Under test here is the IO around
  it: the SVG reaches the binary and the PNG comes back into the row; a
  failure is charged and, after three, written down and left alone; a
  missing binary charges nobody; the review job's batch and the sweep's
  batch draw exactly the puzzles still owed. The binary is a stub
  (test_support/fake_rsvg_convert) except in the one test that runs the
  real one when the machine has it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Oskol.Persistence
  alias Oskol.Puzzles
  alias Oskol.Puzzles.Pictures
  alias Oskol.Repo

  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>
  @failing "/usr/bin/false"
  @no_png Path.expand("../../test_support/blank_rsvg_convert", __DIR__)
  @slow Path.expand("../../test_support/slow_rsvg_convert", __DIR__)

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  # ---------- Rows ----------

  defp an_id,
    do: :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)

  # A real question: the opening position, White to play 3-1.
  defp a_question do
    %{
      "version" => 1,
      "kind" => "move",
      "board" => [
        0,
        -2,
        0,
        0,
        0,
        0,
        5,
        0,
        3,
        0,
        0,
        0,
        -5,
        5,
        0,
        0,
        0,
        -3,
        0,
        -5,
        0,
        0,
        0,
        0,
        2,
        0
      ],
      "dice" => [3, 1],
      "cube" => %{"value" => 1, "owner" => "center"},
      "score" => nil,
      "crawford" => false,
      "jacoby" => false
    }
  end

  defp a_puzzle(opts \\ []) do
    id = an_id()
    now = DateTime.utc_now()

    Repo.insert!(%Puzzles.Puzzle{
      id: id,
      key: "k-" <> id,
      kind: "move",
      question: Keyword.get(opts, :question, a_question()),
      answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
      inserted_at: Keyword.get(opts, :at, now),
      updated_at: now
    })

    id
  end

  defp a_room do
    id = "pic-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    Repo.insert!(%Persistence.Game{
      id: id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: [],
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    id
  end

  defp a_source(game_id, game_number, puzzle_id, turn) do
    now = DateTime.utc_now()

    Repo.insert_all(Puzzles.Source, [
      %{
        puzzle_id: puzzle_id,
        game_id: game_id,
        game_number: game_number,
        turn: turn,
        kind: "move",
        seat: 0,
        player_id: "p1",
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp image(id), do: Repo.get(Puzzles.Image, id)

  # ---------- One render ----------

  describe "render/2" do
    test "draws the picture into the row, once" do
      id = a_puzzle()
      assert Pictures.png(id) == :none

      assert Pictures.render(id) == :ok

      assert {:ok, png} = Pictures.png(id)
      # The stub answers with the PNG signature and how much SVG it read:
      # the drawing reached the binary on stdin, whole.
      assert <<@png_signature, "fake ", rest::binary>> = png
      {bytes, " bytes"} = Integer.parse(rest)
      {:ok, svg} = Pictures.svg(a_question())
      assert bytes == byte_size(svg)

      row = image(id)
      assert row.attempts == 1
      assert row.rendered_at != nil
      assert row.error == nil
    end

    test "a puzzle that does not exist is refused and nothing is written" do
      assert {:error, "no such puzzle"} = Pictures.render("nothere")
      assert image("nothere") == nil
    end

    test "a binary that fails charges the try, logs it, and gives up after three" do
      id = a_puzzle()

      log =
        capture_log(fn ->
          assert {:error, "rsvg-convert exited 1"} = Pictures.render(id, rsvg: @failing)
        end)

      assert log =~ "puzzle picture #{id} failed (attempt 1/3)"
      refute log =~ "given up"
      assert image(id).attempts == 1
      assert image(id).error == nil
      assert image(id).png == nil

      capture_log(fn -> Pictures.render(id, rsvg: @failing) end)

      log = capture_log(fn -> Pictures.render(id, rsvg: @failing) end)
      assert log =~ "puzzle picture #{id} given up: rsvg-convert exited 1"
      assert image(id).attempts == 3
      assert image(id).error == "rsvg-convert exited 1"

      # Out of tries: the sweep leaves it alone, and the operator's lever
      # reopens it.
      refute id in Repo.all(owed_ids())
      assert Pictures.reset_attempts() >= 1
      assert id in Repo.all(owed_ids())
      assert image(id).attempts == 0
      assert image(id).error == nil
    end

    test "a binary that exits 0 without a PNG is a failure, not a picture" do
      id = a_puzzle()

      capture_log(fn ->
        assert {:error, "rsvg-convert exited 0 without a PNG"} =
                 Pictures.render(id, rsvg: @no_png)
      end)

      assert image(id).png == nil
      assert image(id).attempts == 1
    end

    test "a binary that never answers is killed at the timeout and charged" do
      id = a_puzzle()

      capture_log(fn ->
        assert {:error, "rsvg-convert took longer than 100 ms"} =
                 Pictures.render(id, rsvg: @slow, timeout: 100)
      end)

      assert image(id).attempts == 1
    end

    test "a missing binary is the machine's fault: logged, charged to nobody, still owed" do
      id = a_puzzle()

      log =
        capture_log(fn ->
          assert {:error, "/nowhere/rsvg-convert is not installed"} =
                   Pictures.render(id, rsvg: "/nowhere/rsvg-convert")
        end)

      assert log =~ "not drawn: /nowhere/rsvg-convert is not installed"
      assert image(id) == nil
      assert id in Repo.all(owed_ids())
    end

    test "a stored question that does not read as one is charged like any failure" do
      id = a_puzzle(question: %{"kind" => "move", "board" => [0, 1, 2]})

      log =
        capture_log(fn ->
          assert {:error, "A stored puzzle question did not read as one"} = Pictures.render(id)
        end)

      assert log =~ "failed (attempt 1/3)"
      assert image(id).attempts == 1
    end

    test "a stored board that is not 26 ints is refused, not drawn empty" do
      id = a_puzzle(question: Map.put(a_question(), "board", [0, 1, 2]))

      capture_log(fn ->
        assert {:error, "a stored board has 3 entries, not 26"} = Pictures.render(id)
      end)

      assert image(id).attempts == 1
    end

    @tag :rsvg
    test "the real binary draws a 1200 x 630 PNG" do
      case System.find_executable("rsvg-convert") do
        nil ->
          # Not on this machine (CI has none): the stub covers the seam.
          :ok

        exe ->
          id = a_puzzle()
          assert Pictures.render(id, rsvg: exe) == :ok
          assert {:ok, png} = Pictures.png(id)
          # The IHDR chunk follows the signature: length, "IHDR", width, height.
          assert <<@png_signature, _len::32, "IHDR", 1200::32, 630::32, _::binary>> = png
      end
    end
  end

  # ---------- The batches ----------

  describe "render_game/2" do
    test "draws that game's puzzles without a picture and no others" do
      game_id = a_room()
      mine = a_puzzle()
      drawn = a_puzzle()
      other_game = a_puzzle()
      a_source(game_id, 1, mine, 3)
      a_source(game_id, 1, drawn, 5)
      # Two sources of one game on one puzzle (a double and its take, say)
      # are one picture.
      a_source(game_id, 1, mine, 7)
      a_source(game_id, 2, other_game, 2)
      assert Pictures.render(drawn) == :ok
      before = image(drawn).updated_at

      assert Pictures.render_game(game_id, 1) == 1

      assert {:ok, _} = Pictures.png(mine)
      assert image(mine).attempts == 1
      assert image(drawn).updated_at == before
      assert Pictures.png(other_game) == :none
    end
  end

  describe "render_owed/1" do
    test "draws the newest owed puzzles up to the limit, and nothing already drawn or given up" do
      now = DateTime.utc_now()
      oldest = a_puzzle(at: DateTime.add(now, -30, :second))
      middle = a_puzzle(at: DateTime.add(now, -20, :second))
      newest = a_puzzle(at: DateTime.add(now, -10, :second))
      spent = a_puzzle(at: now)

      for _ <- 1..3, do: capture_log(fn -> Pictures.render(spent, rsvg: @failing) end)
      assert Pictures.any_owed?()

      # Other tests' puzzles may be owed too (the tables are global), so
      # the batch is read back by what it did to these rows.
      assert Pictures.render_owed(2) == 2
      assert {:ok, _} = Pictures.png(newest)
      assert {:ok, _} = Pictures.png(middle)
      assert Pictures.png(oldest) == :none
      assert Pictures.png(spent) == :none

      assert Pictures.render_owed(100) >= 1
      assert {:ok, _} = Pictures.png(oldest)
      assert Pictures.png(spent) == :none
      assert image(spent).attempts == 3
    end
  end

  defp owed_ids do
    from(p in Puzzles.Puzzle,
      left_join: i in Puzzles.Image,
      on: i.puzzle_id == p.id,
      where: is_nil(i.png),
      where: is_nil(i.attempts) or i.attempts < 3,
      select: p.id
    )
  end
end

defmodule Oskol.Puzzles.PicturesSweepTest do
  @moduledoc """
  The queue's minute sweep draws what the review job did not: one
  `:pictures` job, one batch, in the same line as the reviews and the decks.
  """
  use ExUnit.Case, async: false

  alias Oskol.Puzzles
  alias Oskol.Puzzles.Pictures
  alias Oskol.Repo
  alias Oskol.Reviews.Queue

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    previous = Application.get_env(:oskol, Queue)
    Application.put_env(:oskol, Queue, enabled: true)
    Queue.reset()

    on_exit(fn ->
      Queue.await_idle()
      Queue.reset()
      Application.put_env(:oskol, Queue, previous)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "the sweep queues one pictures job for whatever is owed, and none when nothing is" do
    id = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    now = DateTime.utc_now()

    Repo.insert!(%Puzzles.Puzzle{
      id: id,
      key: "k-" <> id,
      kind: "double",
      question: %{
        "kind" => "double",
        "board" => [
          0,
          -2,
          0,
          0,
          0,
          0,
          5,
          0,
          3,
          0,
          0,
          0,
          -5,
          5,
          0,
          0,
          0,
          -3,
          0,
          -5,
          0,
          0,
          0,
          0,
          2,
          0
        ],
        "dice" => nil,
        "cube" => %{"value" => 1, "owner" => "center"},
        "score" => %{"mover_away" => 3, "opponent_away" => 5},
        "crawford" => false,
        "jacoby" => false
      },
      answer: %{"kind" => "cube"},
      inserted_at: now,
      updated_at: now
    })

    assert Pictures.any_owed?()
    assert Queue.sweep_owed() == 1
    Queue.await_idle()

    assert {:ok, <<0x89, "PNG", _::binary>>} = Pictures.png(id)
    refute Pictures.any_owed?()
    assert Queue.sweep_owed() == 0
  end
end
