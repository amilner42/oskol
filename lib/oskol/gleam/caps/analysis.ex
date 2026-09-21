defmodule Oskol.Gleam.Caps.Analysis do
  @moduledoc """
  Real IO for src/oskol/caps/analysis.gleam. Keep constructor tags and field
  order in lockstep:

      AnalysisCaps(log, stored, summaries, report, save, backfill_turns,
      enqueue, review)
      GameLog(slug, format, clock, seed, seats, entries)
      LogEntry(kind, player_id, payload_json, at_ms)
      Stored(game_number, status, attempts, response_json, answered, rendered, turns)
      Save(status, attempts, response_json, error, report_json, turns)
      Status: :pending | :done | :failed

  `response` and `report` are hundreds of kilobytes each. `summaries`
  selects neither and `report/2` selects one of them for one game, so the
  only query that carries a body is the one whose answer is the body.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Reviews

  def build do
    {:analysis_caps, &log/1, &stored/1, &summaries/1, &report/2, &save/3, &backfill_turns/3,
     &enqueue/1, &review/1}
  end

  defp log(game_id) do
    case Reviews.log(game_id) do
      nil ->
        :none

      %{game: game, actions: actions} ->
        config = game.config || %{}

        {:some,
         {
           :game_log,
           game.slug,
           config["format"] || "",
           config["clock"] || "none",
           game.seed,
           # The names the seats play under, so a review names an account's
           # seat as the table and the replay do.
           Enum.map(hd(Oskol.Persistence.display_names([game.players])), fn p ->
             {p["id"], p["name"]}
           end),
           Enum.map(actions, fn a ->
             {:log_entry, a.kind, opt(a.player_id), Jason.encode!(a.payload), a.at_ms}
           end)
         }}
    end
  end

  defp stored(game_id) do
    Enum.map(Reviews.stored(game_id), fn r ->
      {:stored, r.game_number, status(r.status), r.attempts, opt(r.response, &Jason.encode!/1),
       r.response != nil, r.rendered, r.turns || 0}
    end)
  end

  defp summaries(game_id) do
    Enum.map(Reviews.summaries(game_id), fn r ->
      {:stored, r.game_number, status(r.status), r.attempts, :none, r.answered, r.rendered,
       r.turns || 0}
    end)
  end

  defp report(game_id, number) do
    opt(Reviews.report(game_id, number), &Jason.encode!/1)
  end

  defp status("pending"), do: :pending
  defp status("done"), do: :done
  defp status("failed"), do: :failed

  defp save(game_id, number, {:save, status, attempts, response, error, report, turns}) do
    :ok =
      Reviews.save(
        game_id,
        number,
        Atom.to_string(status),
        attempts,
        decode(response),
        unopt(error),
        decode(report),
        turns
      )

    nil
  end

  # A legacy row needs just its count filled in. Do not turn this into a
  # `save`: a queue worker can have updated status/error after the caller
  # read its snapshot, and that newer state must survive this backfill.
  defp backfill_turns(game_id, number, turns) do
    :ok = Reviews.backfill_turns(game_id, number, turns)
    nil
  end

  defp decode(option) do
    if json = unopt(option), do: Jason.decode!(json)
  end

  # A note before the ask, always. The queue lives in memory, so anything
  # that asks it for work -- today a player's retry of a failed analysis --
  # must leave something behind that a restart cannot forget. Writing it
  # here rather than at each call site means a new caller cannot omit it.
  defp enqueue(game_id) do
    Reviews.mark_analysis_owed(game_id)
    Oskol.Reviews.Queue.enqueue(game_id)
    nil
  end

  defp review(body) do
    case Reviews.request(body) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
