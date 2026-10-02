defmodule Oskol.OwnDecks do
  @moduledoc """
  The rows behind a player's own sets, and nothing that decides anything.

  Who may do what to a set, what a name may be and how many sets an
  account may keep are `src/oskol/handlers/own_decks.gleam`'s. This is the
  IO behind the own-set caps of `src/oskol/caps/decks.gleam` (built in
  `Oskol.Gleam.Caps.Decks`).

  A set is a `decks` row (its owner, its name, its pace) and its positions
  are `deck_puzzles` rows under its id, exactly as a universal set's are,
  so `Oskol.Puzzles.deck_members/1` and `deck_size/1` read them unchanged.
  """

  import Ecto.Query

  alias Oskol.Repo

  defmodule Deck do
    @moduledoc "A set an account made: its name and its pace."
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :string, autogenerate: false}
    schema "decks" do
      field(:user_id, :binary_id)
      field(:name, :string)
      field(:new_per_day, :integer, default: 5)
      # Set by a delete. The row, its membership and its ladder stay.
      field(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    @doc false
    def changeset(deck, attrs) do
      deck
      |> cast(attrs, [:id, :user_id, :name, :new_per_day])
      |> validate_required([:id, :user_id, :name, :new_per_day])
      |> unique_constraint(:id, name: :decks_pkey)
      |> unique_constraint(:name, name: :decks_user_id_lower_name_index)
    end
  end

  @doc "An account's live sets, oldest first."
  def own(user_id) when is_binary(user_id) do
    from(d in Deck,
      where: d.user_id == ^user_id and is_nil(d.deleted_at),
      order_by: [asc: d.inserted_at, asc: d.id]
    )
    |> Repo.all()
  end

  @doc """
  Make a set. `{:ok, deck}`, or `{:error, :name_taken}` when the owner has a
  live set of that name in any case, or `{:error, :id_taken}` when the id is
  somebody's already (the caller mints another).
  """
  def create(user_id, id, name, new_per_day) do
    %Deck{}
    |> Deck.changeset(%{id: id, user_id: user_id, name: name, new_per_day: new_per_day})
    |> Repo.insert()
    |> refused()
  end

  @doc "Rename a live set: `{:ok, deck}` or `{:error, :name_taken}`."
  def rename(id, name) do
    case Repo.one(from(d in Deck, where: d.id == ^id and is_nil(d.deleted_at))) do
      nil ->
        raise ArgumentError, "no live set #{inspect(id)}"

      deck ->
        deck
        |> Ecto.Changeset.change(name: name)
        |> Ecto.Changeset.unique_constraint(:name, name: :decks_user_id_lower_name_index)
        |> Repo.update()
        |> refused()
    end
  end

  @doc "Delete a set: it leaves `own/1`. Its rows and its ladder stay."
  def delete(id) do
    from(d in Deck, where: d.id == ^id and is_nil(d.deleted_at))
    |> Repo.update_all(set: [deleted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Put a puzzle into a set, one past its highest position, unless it is
  there already. `{added?, position}`: where it stands either way.
  """
  def add_member(deck, puzzle_id) when is_binary(deck) and is_binary(puzzle_id) do
    %{rows: rows} =
      Repo.query!(
        """
        INSERT INTO deck_puzzles (deck, puzzle_id, position, inserted_at, updated_at)
        SELECT $1::varchar, $2::varchar, COALESCE(MAX(position), 0) + 1, now(), now()
        FROM deck_puzzles WHERE deck = $1::varchar
        ON CONFLICT (deck, puzzle_id) DO NOTHING
        RETURNING position
        """,
        [deck, puzzle_id]
      )

    case rows do
      [[position]] ->
        {true, position}

      [] ->
        position =
          from(m in "deck_puzzles",
            where: m.deck == ^deck and m.puzzle_id == ^puzzle_id,
            select: m.position
          )
          |> Repo.one!()

        {false, position}
    end
  end

  @doc "Take a puzzle out of a set: true if a row went."
  def remove_member(deck, puzzle_id) when is_binary(deck) and is_binary(puzzle_id) do
    {count, _} =
      from(m in "deck_puzzles", where: m.deck == ^deck and m.puzzle_id == ^puzzle_id)
      |> Repo.delete_all()

    count > 0
  end

  defp refused({:ok, deck}), do: {:ok, deck}

  defp refused({:error, %Ecto.Changeset{errors: errors}}) do
    if Keyword.has_key?(errors, :id), do: {:error, :id_taken}, else: {:error, :name_taken}
  end
end
