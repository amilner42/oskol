defmodule Oskol.Dev.RoomImport do
  @moduledoc """
  A real room, brought home. `priv/dev/rooms/<code>.json` is a room's four
  tables as production held them (the game row, its action log, its
  reviews with the engine's answers, its records), exported once with a
  one-liner over `bin/oskol rpc`; `import!/1` puts the rows into the local
  database under the same code, replacing what was there. The seeder runs
  it, so `mix oskol.seed` leaves a match somebody actually played, graded
  and all, beside the parked positions it builds itself.

  Seats are held by nobody here (the guest ids are production's), so the
  invite link hands them out like any seeded room's.
  """

  import Ecto.Query

  alias Oskol.Persistence
  alias Oskol.Repo
  alias Oskol.Reviews

  @dir Path.join(:code.priv_dir(:oskol), "dev/rooms")

  @doc "Every room file there is, by code."
  def codes do
    case File.ls(@dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "Load one room's rows, replacing any row of that code already here."
  def import!(code) do
    %{"game" => game, "actions" => actions, "reviews" => reviews, "records" => records} =
      @dir |> Path.join(code <> ".json") |> File.read!() |> Jason.decode!()

    Repo.transaction(fn ->
      Repo.delete_all(from(g in Persistence.Game, where: g.id == ^code))
      Repo.insert!(struct(Persistence.Game, atomize(game, Persistence.Game)))

      Enum.each(
        actions,
        &Repo.insert!(struct(Persistence.GameAction, atomize(&1, Persistence.GameAction)))
      )

      Enum.each(reviews, &Repo.insert!(struct(Reviews.Review, atomize(&1, Reviews.Review))))
      Enum.each(records, &Repo.insert!(struct(Reviews.Record, atomize(&1, Reviews.Record))))
    end)

    :ok
  end

  # The JSON's string keys onto the schema's fields, timestamps parsed; keys
  # the schema does not have (a column since dropped) are left behind.
  defp atomize(row, schema) do
    fields = schema.__schema__(:fields)

    for {key, value} <- row, field = safe_atom(key), field in fields, into: %{} do
      {field, cast(schema.__schema__(:type, field), value)}
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp cast(:utc_datetime_usec, value) when is_binary(value) do
    {:ok, dt, _} = DateTime.from_iso8601(value)
    dt
  end

  defp cast(_, value), do: value
end
