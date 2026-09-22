defmodule Oskol.Puzzles do
  @moduledoc """
  The rows a puzzle lives in, and nothing that decides anything.

  What counts as a puzzle, what its question and answer are and what makes
  two of them the same all live in `src/oskol/puzzles.gleam` and
  `src/oskol/puzzles/extract.gleam`. This is the IO behind
  `src/oskol/caps/puzzles.gleam` (built in `Oskol.Gleam.Caps.Puzzles`).

  `store/4` is the whole write path and it is one transaction: the puzzles,
  the sources that point at them and the marker that says this game has
  been extracted land together or not at all. It is idempotent -- a puzzle
  is written only where its key is new, a source only where its (game, game
  number, turn, kind) is new -- so a rerun writes nothing and a crash
  half-way leaves nothing to reconcile by hand.

  A puzzle's id is read off its key's own digest, which makes a rerun ask
  for exactly the same row. Two *different* questions could still want one
  id, so Gleam offers several and this takes the first that nobody else's
  key holds.

  The attempt is charged before the transaction, deliberately: a write that
  keeps failing must not have the minute sweep replaying one room for ever.
  Every giving-up path -- a failed transaction, and `failed/3` for a
  decision Gleam could not even reach -- charges and logs, and the one that
  spends the last attempt marks the row (`puzzles_extracted_at`, with
  `puzzles_error` saying why) so the sweep lets it go.
  """

  import Ecto.Query
  require Logger

  alias Oskol.Persistence.Game
  alias Oskol.Repo
  alias Oskol.Reviews.Review

  @max_attempts 3

  defmodule Puzzle do
    @moduledoc "One question, asked of anyone, with the engine's answer."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "puzzles" do
      field(:key, :string)
      field(:kind, :string)
      field(:question, :map)
      field(:answer, :map)
      field(:evaluated_by, :map)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Source do
    @moduledoc "Where a puzzle came from: one decision of one game."
    use Ecto.Schema

    schema "puzzle_sources" do
      field(:puzzle_id, :string)
      field(:game_id, :string)
      field(:game_number, :integer)
      field(:turn, :integer)
      field(:kind, :string)
      field(:seat, :integer)
      field(:player_id, :string)
      field(:played, :string)
      field(:equity_lost, :float)
      field(:grade, :string)
      field(:skipped_reason, :string)
      field(:deck_synced_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Attempt do
    @moduledoc "One answer somebody gave. Written by the API ticket."
    use Ecto.Schema

    schema "puzzle_attempts" do
      field(:puzzle_id, :string)
      field(:user_id, Ecto.UUID)
      field(:idempotency_key, :string)
      field(:answer, :map)
      field(:verdict, :string)
      field(:outcome, :string)
      field(:scheduled, :boolean, default: false)
      field(:at, :utc_datetime_usec)
      # The deck review this attempt wrote, which an override supersedes.
      field(:review_id, :integer)
      # What the answer reported: a retry has to say the same thing again,
      # and by then the card has moved.
      field(:schedule, :map)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Share do
    @moduledoc "A link that tells a friend whose mistake it was."
    use Ecto.Schema

    @primary_key {:token, :string, autogenerate: false}
    schema "puzzle_shares" do
      field(:puzzle_id, :string)
      field(:source_id, :id)
      field(:shared_by, :string)
      field(:shared_name, :string)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  defmodule Image do
    @moduledoc "The board, drawn once, for a link preview."
    use Ecto.Schema

    @primary_key {:puzzle_id, :string, autogenerate: false}
    schema "puzzle_images" do
      field(:png, :binary)
      field(:rendered_at, :utc_datetime_usec)
      field(:attempts, :integer, default: 0)

      timestamps(type: :utc_datetime_usec)
    end
  end

  # ---------- Reading one back ----------

  @doc "One puzzle by id, or nil. The whole row: Gleam reads both bodies."
  def get(id) when is_binary(id) do
    Repo.get(Puzzle, id)
  end

  @doc """
  The sources of a puzzle in rooms that list this guest id or this account
  id among their seats, newest game first, with the room's slug and seats.

  The query only *narrows*, to the rooms a caller could plausibly be seated
  in; who really holds a seat is the one holder rule in Gleam, asked on the
  seats that come back with each row. The same `players` containment the
  home page's list of games uses, so the same partial index serves it.
  """
  def mine(puzzle_id, guest_id, user_id) do
    case seat_match(guest_id, user_id) do
      nil ->
        []

      held ->
        from(s in Source,
          join: g in Game,
          on: g.id == s.game_id,
          where: s.puzzle_id == ^puzzle_id,
          where: ^held,
          order_by: [desc: g.updated_at, desc: s.game_number, desc: s.turn],
          limit: 20,
          select: {s, g.slug, g.players}
        )
        |> Repo.all()
        |> with_names()
    end
  end

  @doc """
  One game of one room's decisions, in turn order, each with its puzzle's
  question so a list can ask every one in its own words without a read
  apiece. Decisions no puzzle was written for come too; the caller drops
  them.
  """
  def game_sources(game_id, game_number) do
    from(s in Source,
      left_join: p in Puzzle,
      on: p.id == s.puzzle_id,
      where: s.game_id == ^game_id and s.game_number == ^game_number,
      order_by: [asc: s.turn, asc: s.id],
      select: {s, p.question}
    )
    |> Repo.all()
  end

  # The `players` jsonb holds the account name only by reference, exactly as
  # the record does, so the names are resolved here and never copied.
  defp with_names(rows) do
    resolved =
      Oskol.Persistence.display_names(Enum.map(rows, fn {_s, _slug, players} -> players end))

    rows
    |> Enum.zip(resolved)
    |> Enum.map(fn {{source, slug, _}, players} -> {source, slug, players} end)
  end

  # "a seat this guest took, or a seat this account owns". The same
  # expression `Oskol.Persistence` indexes.
  defp seat_match(guest_id, user_id) do
    guest = holds("guest_id", guest_id)
    user = holds("user_id", user_id)

    cond do
      guest && user -> dynamic([_s, g], ^guest or ^user)
      guest -> guest
      user -> user
      true -> nil
    end
  end

  defp holds(key, value) when is_binary(value) and byte_size(value) > 0 do
    entry = [%{key => value}]
    dynamic([_s, g], fragment("oskol_players_jsonb(?) @> ?::jsonb", g.players, ^entry))
  end

  defp holds(_key, _value), do: nil

  # ---------- Attempts ----------

  @doc """
  Write this answer down unless its key is already there, and hand back the
  row that stands together with whether this call is what wrote it.

  That flag is the whole point. An idempotency key is one answer: a retried
  POST, a second tab, a phone that sent it twice all reach this and find the
  row already here, and only a row this call wrote is allowed to move
  anybody's ladder.
  """
  def put_attempt(puzzle_id, user_id, key, answer, verdict) do
    now = DateTime.utc_now()

    row = %{
      puzzle_id: puzzle_id,
      user_id: user_id,
      idempotency_key: key,
      answer: answer,
      verdict: verdict,
      scheduled: false,
      at: now,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Attempt, [row],
           on_conflict: :nothing,
           conflict_target: [:puzzle_id, :user_id, :idempotency_key]
         ) do
      {1, _} -> {:fresh, attempt(puzzle_id, key)}
      {0, _} -> {:kept, attempt(puzzle_id, key)}
    end
  end

  @doc "An attempt by the key its own client minted. Whose it is, is Gleam's to check."
  def attempt(puzzle_id, key) do
    Repo.one(
      from(a in Attempt,
        where: a.puzzle_id == ^puzzle_id and a.idempotency_key == ^key,
        limit: 1
      )
    )
  end

  @doc "What happened after the deck was asked."
  def settle_attempt(id, scheduled, review_id, outcome, schedule) do
    from(a in Attempt, where: a.id == ^id)
    |> Repo.update_all(
      set:
        [scheduled: scheduled, schedule: schedule, updated_at: DateTime.utc_now()] ++
          if(review_id, do: [review_id: review_id], else: []) ++
          if(outcome, do: [outcome: outcome], else: [])
    )

    :ok
  end

  # ---------- What is still owed ----------

  @doc """
  The game numbers of this room whose engine answer is stored and whose
  puzzles are not, with attempts to spare. Three columns of the review
  rows; neither body is read.
  """
  def unextracted(game_id) do
    owed_query()
    |> where([r], r.game_id == ^game_id)
    |> select([r], r.game_number)
    |> order_by([r], r.game_number)
    |> Repo.all()
  end

  @doc "Rooms with a graded game whose puzzles have never been written."
  def rooms_owed_puzzles do
    owed_query()
    |> select([r], r.game_id)
    |> distinct(true)
    |> Repo.all()
  end

  defp owed_query do
    from(r in Review,
      where:
        r.status == "done" and not is_nil(r.response) and is_nil(r.puzzles_extracted_at) and
          r.puzzles_attempts < @max_attempts
    )
  end

  # ---------- The write ----------

  @doc """
  Write one game's puzzles, its sources and its extraction marker, all in
  one transaction.

  `puzzles` are `%{key:, ids:, kind:, question:, answer:, evaluated_by:}`
  and `sources` `%{key:, game_number:, turn:, kind:, seat:, player_id:,
  played:, equity_lost:, grade:, skipped_reason:}`, both already decided in
  Gleam. A source names its puzzle by key; this resolves the key to the id
  the row actually ended up with, so two extractions racing on the same
  position agree.

  `:ok`, or `{:error, reason}` -- extraction never fails a review.
  """
  def store(game_id, game_number, puzzles, sources) do
    attempts = charge_attempt(game_id, game_number)

    Repo.transaction(fn ->
      ids = resolve_ids(puzzles, 0)

      sources
      |> Enum.map(&source_row(&1, game_id, ids))
      |> then(fn rows ->
        Repo.insert_all(Source, rows,
          on_conflict: :nothing,
          conflict_target: [:game_id, :game_number, :turn, :kind]
        )
      end)

      mark_extracted(game_id, game_number)
    end)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        gave_up(game_id, game_number, inspect(reason), attempts)
        {:error, inspect(reason)}
    end
  rescue
    e ->
      gave_up(game_id, game_number, Exception.message(e), attempts_of(game_id, game_number))
      {:error, Exception.message(e)}
  end

  @doc """
  This game was owed puzzles and could not have them -- the stored answer
  no longer lines up with the game's turns, say. Charge the try, log it,
  and once the budget is spent mark the row so the sweep lets it go.
  """
  def failed(game_id, game_number, reason) do
    attempts = charge_attempt(game_id, game_number)
    gave_up(game_id, game_number, reason, attempts)
    :ok
  end

  # A puzzle whose key is already stored keeps the id it has; a new one
  # takes the first of Gleam's candidates that no other key holds. Looping
  # rather than picking once, because the winner of a race is whichever
  # write got there first, not whichever we hoped for.
  defp resolve_ids([], _attempt), do: %{}

  defp resolve_ids(puzzles, attempt) do
    keys = Enum.map(puzzles, & &1.key)
    found = Repo.all(from(p in Puzzle, where: p.key in ^keys, select: {p.key, p.id})) |> Map.new()

    case Enum.reject(puzzles, &Map.has_key?(found, &1.key)) do
      [] ->
        found

      missing ->
        {writable, exhausted} =
          missing
          |> Enum.map(&{&1, puzzle_row(&1, attempt)})
          |> Enum.split_with(fn {_puzzle, row} -> row.id != nil end)

        # Every candidate id this puzzle had is held by some other key.
        # Vanishingly unlikely, and never a reason to lose the rest of the
        # game: this one puzzle is skipped and its sources say so.
        for {puzzle, _row} <- exhausted do
          Logger.error("puzzle id candidates exhausted for key #{puzzle.key}")
        end

        case writable do
          [] ->
            found

          rows ->
            # No conflict target: the key index and the id index both apply,
            # and losing either race means this row is already someone
            # else's problem, so read back rather than guess.
            Repo.insert_all(Puzzle, Enum.map(rows, &elem(&1, 1)), on_conflict: :nothing)
            Map.merge(found, resolve_ids(Enum.map(rows, &elem(&1, 0)), attempt + 1))
        end
    end
  end

  defp puzzle_row(puzzle, attempt) do
    now = DateTime.utc_now()

    %{
      id: Enum.at(puzzle.ids, attempt),
      key: puzzle.key,
      kind: puzzle.kind,
      question: puzzle.question,
      answer: puzzle.answer,
      evaluated_by: puzzle.evaluated_by,
      inserted_at: now,
      updated_at: now
    }
  end

  # The reason a source carries when its puzzle could not be given an id.
  # A storage fact, not a product rule, so it is named here and not in Gleam.
  @id_exhausted "id_exhausted"

  defp source_row(source, game_id, ids) do
    now = DateTime.utc_now()
    puzzle_id = source.key && Map.get(ids, source.key)

    skipped =
      cond do
        source.skipped_reason != nil -> source.skipped_reason
        source.key != nil and puzzle_id == nil -> @id_exhausted
        true -> nil
      end

    %{
      puzzle_id: puzzle_id,
      game_id: game_id,
      game_number: source.game_number,
      turn: source.turn,
      kind: source.kind,
      seat: source.seat,
      player_id: source.player_id,
      played: source.played,
      equity_lost: source.equity_lost,
      grade: source.grade,
      skipped_reason: skipped,
      inserted_at: now,
      updated_at: now
    }
  end

  defp mark_extracted(game_id, game_number) do
    from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
    |> Repo.update_all(set: [puzzles_extracted_at: DateTime.utc_now(), puzzles_error: nil])
  end

  # Charged outside the transaction on purpose: a rollback must not refund
  # it, or a write that always fails would have the sweep replaying this
  # room every minute for ever. Returns the count after this try.
  defp charge_attempt(game_id, game_number) do
    {_, counts} =
      from(r in Review,
        where: r.game_id == ^game_id and r.game_number == ^game_number,
        select: r.puzzles_attempts
      )
      |> Repo.update_all(inc: [puzzles_attempts: 1])

    List.first(counts || []) || @max_attempts
  end

  defp attempts_of(game_id, game_number) do
    from(r in Review,
      where: r.game_id == ^game_id and r.game_number == ^game_number,
      select: r.puzzles_attempts
    )
    |> Repo.one() || @max_attempts
  end

  # Log every time, and on the last attempt settle the row so the minute
  # sweep stops coming back for a game it can never extract. The marker
  # says "the sweep is done with this"; `puzzles_error` says why, and is
  # what an operator looks for.
  defp gave_up(game_id, game_number, reason, attempts) do
    Logger.error(
      "puzzle extraction failed for #{game_id} game #{game_number} " <>
        "(attempt #{attempts}/#{@max_attempts}): #{reason}"
    )

    if attempts >= @max_attempts do
      Logger.error("puzzle extraction given up for #{game_id} game #{game_number}: #{reason}")

      from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
      |> Repo.update_all(
        set: [
          puzzles_extracted_at: DateTime.utc_now(),
          puzzles_error: String.slice(reason, 0, 500)
        ]
      )
    end

    :ok
  end
end
