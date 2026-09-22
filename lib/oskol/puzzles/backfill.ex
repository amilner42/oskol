defmodule Oskol.Puzzles.Backfill do
  @moduledoc """
  Ask the engine again about every game graded before it sent every legal
  result, one game at a time, and settle what depends on the answer: the
  row, the page, the puzzles (complete now, and the post-take plays judged
  on the right cube), and the decks that own them.

  Every decision is `src/oskol/handlers/backfill.gleam`: which stored
  answers are old, what the fresh answer must hold before it is trusted,
  and what a re-ask writes and in what order. This walks the rooms oldest
  first, calls it a game at a time, times the engine, prints a line per
  game and adds the counts up. `mix oskol.puzzles.backfill` and
  `Oskol.Release.puzzles_backfill/1` are the two doors onto it.

  Dry run unless told to write: a dry run replays each room and reads its
  stored answers (that is how an old one is told from a new one), asks
  the engine nothing, charges nothing and writes nothing of its own. The
  replay is the one a read of the replay page makes, and settles what
  that read would (a record row never written, an answer never rendered)
  and no more. A run is
  bounded by the number of old games and by three engine calls per game;
  a game the engine does not answer is charged and skipped, and the run
  goes on. Rerun once everything has been asked and it finds nothing to
  do and writes nothing.

  The review queue must be off for the run (both doors turn it off before
  the application starts), so its minute sweep cannot extract a game this
  is in the middle of re-asking.
  """

  require Logger

  alias Oskol.Gleam.CtxBuilder

  @doc """
  Options: `write: true` to act (default false), `room: id` for one room,
  `limit: n` to stop after that many games, `reset: true` to let the games
  whose tries are spent be asked again first, `say: fun` for the lines
  (default `IO.puts/1`). Returns the totals.
  """
  def run(opts \\ []) do
    write? = Keyword.get(opts, :write, false)
    room = Keyword.get(opts, :room)
    limit = Keyword.get(opts, :limit)
    say = Keyword.get(opts, :say, &IO.puts/1)
    ctx = CtxBuilder.build(review: &timed_review/1)

    if Keyword.get(opts, :reset, false) and not write? do
      say.("--reset acts only with --write; nothing reopened")
    end

    totals =
      Oskol.Reviews.rooms_reviewed(room)
      |> Enum.reduce_while(fresh(), fn game_id, totals ->
        totals =
          if write? && Keyword.get(opts, :reset, false),
            do: reset(ctx, game_id, totals, say),
            else: totals

        if reached?(totals, limit) do
          {:halt, totals}
        else
          {:cont, room(ctx, game_id, totals, write?, limit, say)}
        end
      end)

    totals = if write?, do: sync_decks(totals, say), else: totals
    say.(summary(totals, write?))
    totals
  end

  defp fresh do
    %{
      rooms: 0,
      unreplayable: 0,
      unreadable: 0,
      games: 0,
      spent: 0,
      reasked: 0,
      engine_ms: 0,
      engine_wall_ms: 0,
      puzzles: 0,
      upgraded: 0,
      sources: 0,
      unextracted: 0,
      quarantined: %{},
      failed: 0,
      reset: 0,
      decks: %{accounts: 0, added: 0, failed: 0}
    }
  end

  defp reached?(_totals, nil), do: false
  defp reached?(totals, limit), do: totals.games >= limit

  defp reset(ctx, game_id, totals, say) do
    case :oskol@handlers@backfill.reset(ctx, game_id) do
      {:ok, 0} ->
        totals

      {:ok, n} ->
        say.("#{game_id}: #{n} game(s) reopened for another try")
        %{totals | reset: totals.reset + n}

      {:error, _} ->
        totals
    end
  end

  defp room(ctx, game_id, totals, write?, limit, say) do
    totals = %{totals | rooms: totals.rooms + 1}

    case :oskol@handlers@backfill.candidates(ctx, game_id) do
      {:error, reason} ->
        say.("#{game_id}: #{reason}")
        %{totals | unreplayable: totals.unreplayable + 1}

      {:ok, {:found, room, candidates, unreadable}} ->
        for number <- unreadable do
          say.("#{game_id} game #{number}: stored answer does not read; left alone")
        end

        totals = %{totals | unreadable: totals.unreadable + length(unreadable)}

        Enum.reduce_while(candidates, totals, fn candidate, totals ->
          if reached?(totals, limit),
            do: {:halt, totals},
            else: {:cont, game(ctx, game_id, room, candidate, totals, write?, say)}
        end)
    end
  end

  defp game(
         ctx,
         game_id,
         room,
         {:candidate, number, turns, attempts, levels} = c,
         totals,
         write?,
         say
       ) do
    label = "#{game_id} game #{number} (#{turns} turns, #{levels(levels)})"

    cond do
      :oskol@handlers@backfill.spent(c) ->
        say.("#{label}: #{attempts} tries spent, skipped (--reset to ask again)")
        %{totals | spent: totals.spent + 1}

      not write? ->
        say.("#{label}: old answer, would re-ask")
        %{totals | games: totals.games + 1}

      true ->
        {wall_us, outcome} =
          :timer.tc(fn -> :oskol@handlers@backfill.reask(ctx, game_id, room, c) end)

        wall_ms = div(wall_us, 1000)
        engine_ms = take_engine_ms()

        totals = %{
          totals
          | games: totals.games + 1,
            engine_wall_ms: totals.engine_wall_ms + engine_ms
        }

        settle(outcome, label, wall_ms, engine_ms, totals, say)
    end
  end

  defp settle({:reasked, engine_said, written}, label, wall_ms, engine_ms, totals, say) do
    said = unopt_int(engine_said)
    totals = %{totals | reasked: totals.reasked + 1, engine_ms: totals.engine_ms + said}

    case written do
      {:ok, {:written, puzzles, upgraded, sources}} ->
        say.(
          "#{label}: re-asked in #{seconds(engine_ms)} s (engine says #{seconds(said)} s, " <>
            "#{seconds(wall_ms)} s all told); #{puzzles} puzzles written, " <>
            "#{upgraded} answers upgraded, #{sources} sources written"
        )

        %{
          totals
          | puzzles: totals.puzzles + puzzles,
            upgraded: totals.upgraded + upgraded,
            sources: totals.sources + sources
        }

      {:error, reason} ->
        say.(
          "#{label}: re-asked in #{seconds(engine_ms)} s, but its puzzles were not written: #{reason}"
        )

        %{totals | unextracted: totals.unextracted + 1}
    end
  end

  defp settle({:quarantined, reason, turn}, label, _wall_ms, engine_ms, totals, say) do
    where = if turn == :none, do: "", else: " (turn #{unopt_int(turn)})"
    say.("#{label}: QUARANTINED after #{seconds(engine_ms)} s: #{reason}#{where}; nothing stored")
    %{totals | quarantined: Map.update(totals.quarantined, reason, 1, &(&1 + 1))}
  end

  defp settle({:engine_failed, reason}, label, _wall_ms, engine_ms, totals, say) do
    say.("#{label}: engine failed after #{seconds(engine_ms)} s: #{reason}; charged, skipped")
    %{totals | failed: totals.failed + 1}
  end

  defp settle(:not_in_replay, label, _wall_ms, _engine_ms, totals, say) do
    say.("#{label}: not in the room's replay; left alone")
    %{totals | unreplayable: totals.unreplayable + 1}
  end

  # Every account owed cards, until none is: each pass charges the rows it
  # reads, so a deck that cannot be filled runs out rather than loops, and
  # the passes are capped besides.
  @sweep_passes 100

  defp sync_decks(totals, say) do
    decks =
      Stream.repeatedly(fn -> Oskol.Practice.sweep() end)
      |> Stream.take(@sweep_passes)
      |> Enum.reduce_while(totals.decks, fn pass, acc ->
        acc = %{
          accounts: acc.accounts + pass.accounts,
          added: acc.added + pass.added,
          failed: acc.failed + pass.failed
        }

        if pass.accounts + pass.failed == 0, do: {:halt, acc}, else: {:cont, acc}
      end)

    say.("decks: #{decks.accounts} synced, #{decks.added} new cards, #{decks.failed} refused")
    %{totals | decks: decks}
  end

  @doc "The totals in one line."
  def summary(t, write?) do
    quarantined =
      case t.quarantined do
        map when map_size(map) == 0 ->
          "0"

        map ->
          Enum.map_join(map, ", ", fn {reason, n} -> "#{n} #{reason}" end) <>
            " (#{Enum.sum(Map.values(map))})"
      end

    "#{t.rooms} rooms, #{t.games} old games" <>
      if(write?,
        do:
          ": #{t.reasked} re-asked in #{seconds(t.engine_wall_ms)} engine s " <>
            "(engine's own count #{seconds(t.engine_ms)} s), #{t.puzzles} puzzles written, " <>
            "#{t.upgraded} answers upgraded, #{t.sources} sources written, " <>
            "#{t.unextracted} not extracted, quarantined #{quarantined}, " <>
            "#{t.failed} engine failures, #{t.spent} skipped as spent, #{t.reset} reset, " <>
            "#{t.unreadable} unreadable, #{t.unreplayable} unreplayable; " <>
            "decks #{t.decks.accounts} synced, #{t.decks.added} new cards, #{t.decks.failed} refused",
        else:
          " would be re-asked, #{t.spent} skipped as spent, #{t.unreadable} unreadable, " <>
            "#{t.unreplayable} unreplayable; dry run (pass --write)"
      )
  end

  # ---------- Timing the engine ----------

  # The engine cap, timed: the milliseconds each call took are left for the
  # caller that made it. One call per re-asked game, so what `take_engine_ms`
  # collects is that game's.
  defp timed_review(body) do
    {us, result} = :timer.tc(fn -> Oskol.Reviews.request(body) end)
    Process.put(__MODULE__, Process.get(__MODULE__, 0) + div(us, 1000))
    result
  end

  defp take_engine_ms do
    Process.delete(__MODULE__) || 0
  end

  defp levels({:some, {:levels, moves, cube}}), do: "#{moves}/#{cube}"
  defp levels(:none), do: "engine default"

  defp unopt_int({:some, n}), do: n
  defp unopt_int(:none), do: 0

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)
end
