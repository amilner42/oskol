defmodule Oskol.Gleam.Caps.Analysis do
  @moduledoc """
  Real IO for src/oskol/caps/analysis.gleam. Keep constructor tags and field
  order in lockstep:

      AnalysisCaps(log, stored, save, enqueue, review)
      GameLog(slug, format, selections, clock, seed, seats, entries)
      LogEntry(kind, player_id, payload_json, at_ms)
      Stored(game_number, status, attempts, response_json)
      Status: :pending | :done | :failed
  """

  import Oskol.Gleam.Interop

  alias Oskol.Reviews

  def build do
    {:analysis_caps, &log/1, &stored/1, &save/6, &enqueue/1, &review/1}
  end

  defp log(game_id) do
    case Reviews.log(game_id) do
      nil ->
        :none

      %{game: game, actions: actions} ->
        config = game.config || %{}

        {:some,
         {:game_log, game.slug, config["format"] || "",
          Enum.map(config["selections"] || %{}, fn {k, v} -> {k, v} end),
          config["clock"] || "none", game.seed,
          Enum.map(game.players, fn p -> {p["id"], p["name"]} end),
          Enum.map(actions, fn a ->
            {:log_entry, a.kind, opt(a.player_id), Jason.encode!(a.payload), a.at_ms}
          end)}}
    end
  end

  defp stored(game_id) do
    Enum.map(Reviews.stored(game_id), fn r ->
      {:stored, r.game_number, status(r.status), r.attempts, opt(r.response, &Jason.encode!/1)}
    end)
  end

  defp status("pending"), do: :pending
  defp status("done"), do: :done
  defp status("failed"), do: :failed

  defp save(game_id, number, status, attempts, response, error) do
    response = if json = unopt(response), do: Jason.decode!(json)
    :ok = Reviews.save(game_id, number, Atom.to_string(status), attempts, response, unopt(error))
    nil
  end

  defp enqueue(game_id) do
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
