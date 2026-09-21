defmodule Oskol.Gleam.Caps.Records do
  @moduledoc """
  Real IO for src/oskol/caps/records.gleam. Keep constructor tags and field
  order in lockstep:

      RecordsCaps(setup, stored, numbers, save)
      Setup(slug, format, clock, seed, seats, finished, records_stale)
      StoredRecord(game_number, entries_json)

  Record entries cross as JSON text: they are written verbatim from what
  the game produced and read back verbatim onto the wire, so nothing here
  looks inside them.
  """

  alias Oskol.Reviews

  def build do
    {:records_caps, &setup/1, &stored/1, &Reviews.record_numbers/1, &save/4}
  end

  defp setup(game_id) do
    case Reviews.setup(game_id) do
      nil ->
        :none

      game ->
        config = game.config || %{}
        generation = Reviews.record_generation(game)

        stale =
          case game.records_generation do
            nil -> game.status == "finished" or generation > 0 or not is_nil(game.records_through)
            settled -> settled < generation
          end

        {:some,
         {:setup, game.slug, config["format"] || "", config["clock"] || "none", game.seed,
          Enum.map(hd(Oskol.Persistence.display_names([game.players])), fn p ->
            {p["id"], p["name"], p["guest_id"] || "", p["user_id"] || ""}
          end), game.status == "finished", stale}}
    end
  end

  defp stored(game_id) do
    Enum.map(Reviews.records(game_id), fn r ->
      {:stored_record, r.game_number, Jason.encode!(r.entries)}
    end)
  end

  defp save(game_id, rows, through, generation) do
    :ok =
      Reviews.save_records(
        game_id,
        Enum.map(rows, fn {number, entries_json} -> {number, Jason.decode!(entries_json)} end),
        through,
        generation
      )

    nil
  end
end
