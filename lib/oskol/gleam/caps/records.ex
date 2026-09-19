defmodule Oskol.Gleam.Caps.Records do
  @moduledoc """
  Real IO for src/oskol/caps/records.gleam. Keep constructor tags and field
  order in lockstep:

      RecordsCaps(setup, stored, save)
      Setup(slug, format, clock, seed, seats, finished, log_length,
            records_through)
      StoredRecord(game_number, entries_json)

  Record entries cross as JSON text: they are written verbatim from what
  the game produced and read back verbatim onto the wire, so nothing here
  looks inside them.
  """

  alias Oskol.Reviews

  def build do
    {:records_caps, &setup/1, &stored/1, &save/2}
  end

  defp setup(game_id) do
    case Reviews.setup(game_id) do
      nil ->
        :none

      game ->
        config = game.config || %{}

        {:some,
         {:setup, game.slug, config["format"] || "", config["clock"] || "none", game.seed,
          Enum.map(game.players, fn p ->
            {p["id"], p["name"], p["guest_id"] || "", p["user_id"] || ""}
          end), game.status == "finished", Reviews.log_length(game_id), game.records_through || 0}}
    end
  end

  defp stored(game_id) do
    Enum.map(Reviews.records(game_id), fn r ->
      {:stored_record, r.game_number, Jason.encode!(r.entries)}
    end)
  end

  defp save(game_id, rows) do
    :ok =
      Reviews.save_records(
        game_id,
        Enum.map(rows, fn {number, entries_json} -> {number, Jason.decode!(entries_json)} end)
      )

    nil
  end
end
