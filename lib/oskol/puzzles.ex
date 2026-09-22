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

  A stored answer is never rewritten, with one audited exception: a
  puzzle whose answer is not `complete` (Gleam's word, stored beside it)
  takes a complete answer to the same question, and `answer_upgraded_at`
  says so. That is what lets the backfill reconcile puzzles written from
  answers older than `all_results`; a complete answer is never touched.

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
  # The reason `oskol/puzzles/extract` writes on a checker play it skipped
  # for the engine's old cube bug (`post_take_reason`): a Gleam constant is
  # inlined, so it is written twice, like the attempt budget.
  @post_take "post_take_cube"

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
      # The answer grades any attempt exactly (`oskol/puzzles.complete`).
      # The one thing that lets `answer` be written twice.
      field(:complete, :boolean, default: false)
      field(:answer_upgraded_at, :utc_datetime_usec)

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
      # The account whose seat made this mistake, derived from the game's
      # players. An index key, never an authority: who holds a seat is
      # decided in Gleam, of the seat itself.
      field(:owner_user_id, Ecto.UUID)
      field(:deck_attempts, :integer, default: 0)
      field(:deck_error, :string)

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
      # Render attempts spent, bounded like an analysis's, and why the last
      # one failed once they are.
      field(:attempts, :integer, default: 0)
      field(:error, :string)

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
        # The day is the game's end -- the review row is opened the moment
        # the game ends -- as the deck's ordering has it, and never the day
        # the source was extracted, which a backfill would make today.
        from(s in Source,
          join: g in Game,
          on: g.id == s.game_id,
          left_join: r in Review,
          on: r.game_id == s.game_id and r.game_number == s.game_number,
          where: s.puzzle_id == ^puzzle_id,
          where: ^held,
          order_by: [desc: g.updated_at, desc: s.game_number, desc: s.turn],
          limit: 20,
          select: {s, g.slug, g.players, coalesce(r.inserted_at, s.inserted_at)}
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
      Oskol.Persistence.display_names(Enum.map(rows, fn {_s, _slug, players, _} -> players end))

    rows
    |> Enum.zip(resolved)
    |> Enum.map(fn {{source, slug, _, ended_at}, players} ->
      {source, slug, players, ended_at}
    end)
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

  # ---------- Shares ----------

  @doc """
  Mint a story link for one decision, or hand back the one this sharer
  already has for it.

  One row per (source, sharer), and the unique index is what says so: the
  insert is `on_conflict: :nothing`, and the read after it returns whichever
  token stands -- the one just offered, or the one an earlier request won
  with. Two tabs pressing the button together get the same link, and no
  read-then-act gap can mint two.

  Who may mint one is Gleam's decision (`oskol/handlers/shares`); this writes
  what it was told. The name is frozen here, on purpose: the person who
  consented to be named must not change underneath the link.
  """
  def mint_share(puzzle_id, source_id, shared_by, shared_name, token) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Share,
      [
        %{
          token: token,
          puzzle_id: puzzle_id,
          source_id: source_id,
          shared_by: shared_by,
          shared_name: shared_name,
          inserted_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:source_id, :shared_by]
    )

    Repo.one!(
      from(s in Share,
        where: s.source_id == ^source_id and s.shared_by == ^shared_by,
        select: s.token,
        limit: 1
      )
    )
  end

  @doc """
  A story link by its token, with the decision it tells, or nil. The day
  is the game's end, as the memory line's is.
  """
  def share(token) when is_binary(token) and token != "" do
    Repo.one(
      from(sh in Share,
        join: s in Source,
        on: s.id == sh.source_id,
        left_join: r in Review,
        on: r.game_id == s.game_id and r.game_number == s.game_number,
        where: sh.token == ^token,
        select: {sh, s, coalesce(r.inserted_at, s.inserted_at)}
      )
    )
  end

  def share(_token), do: nil

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
      {1, _} -> {:fresh, attempt(puzzle_id, user_id, key)}
      {0, _} -> {:kept, attempt(puzzle_id, user_id, key)}
    end
  end

  @doc """
  One account's attempt under the key its own client minted.

  Scoped to the account, and the unique index says why: a key is only
  unique within one (`puzzle_id, user_id, idempotency_key`). It is a uuid
  the browser made up, so two of them can collide, and reading by key alone
  would hand one person's attempt -- and their override -- to whoever sent
  the same string.
  """
  def attempt(puzzle_id, user_id, key) do
    Repo.one(
      from(a in Attempt,
        where:
          a.puzzle_id == ^puzzle_id and a.user_id == ^user_id and
            a.idempotency_key == ^key,
        limit: 1
      )
    )
  end

  @doc """
  Run `decide` with nobody else deciding what an answer does to the same
  account's same card.

  Whether an answer counts is read-then-act -- is this attempt row new, and
  is the card due -- so two requests that both read before either wrote
  would both find a due card and both move the ladder. A transaction-scoped
  advisory lock keyed on the account and the puzzle makes that one at a
  time; it is released when the transaction ends, so it is safe behind
  pgbouncer's transaction pooling, which a session lock would not be.

  A refusal is still an answer -- the player did answer, and the attempt
  row should stand -- so nothing here rolls back on the value `decide`
  returns. Only a raise does.
  """
  def serialize(user_id, puzzle_id, decide) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [
          user_id <> ":" <> puzzle_id
        ])

        decide.()
      end)

    result
  end

  @doc """
  What happened after the deck was asked.

  A nil `schedule` leaves the one already on the row alone. Pressing NEVER
  is a deck action, not an answer: it suspends the card, and the schedule
  the answer reported has to survive it, because a retry of that answer is
  contractually the same reply.
  """
  def settle_attempt(id, scheduled, review_id, outcome, schedule) do
    from(a in Attempt, where: a.id == ^id)
    |> Repo.update_all(
      set:
        [scheduled: scheduled, updated_at: DateTime.utc_now()] ++
          if(schedule, do: [schedule: schedule], else: []) ++
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

  `puzzles` are `%{key:, ids:, kind:, question:, answer:, evaluated_by:,
  complete:}` and `sources` `%{key:, game_number:, turn:, kind:, seat:,
  player_id:, played:, equity_lost:, grade:, skipped_reason:}`, both
  already decided in Gleam. A source names its puzzle by key; this resolves
  the key to the id the row actually ended up with, so two extractions
  racing on the same position agree.

  `{:ok, %{puzzles:, upgraded:, sources:}}` with the rows this write
  actually made (a rerun is all zeros; `upgraded` is stored puzzles whose
  incomplete answer this game's complete one replaced), or `{:error,
  reason}` -- extraction never fails a review.
  """
  def store(game_id, game_number, puzzles, sources) do
    attempts = charge_attempt(game_id, game_number)

    Repo.transaction(fn ->
      {ids, written} = resolve_ids(puzzles, 0, 0)
      upgraded = upgrade_answers(puzzles)

      {inserted, _} =
        sources
        |> Enum.map(&source_row(&1, game_id, ids))
        |> then(fn rows ->
          Repo.insert_all(Source, rows,
            on_conflict: :nothing,
            conflict_target: [:game_id, :game_number, :turn, :kind]
          )
        end)

      # The sources exist now, so the account that owns each seat can be
      # written onto them -- in this transaction, because the sweep's index
      # is keyed on it and a row without it would never be found.
      refresh_owners([game_id])

      mark_extracted(game_id, game_number)
      %{puzzles: written, upgraded: upgraded, sources: inserted}
    end)
    |> case do
      {:ok, counts} ->
        {:ok, counts}

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
  This game's answer has been replaced and its puzzles are owed again.

  One transaction: the extraction marker, its error and its attempts are
  cleared, and the sources written for turns skipped as `post_take_cube`
  are dropped, so the fresh answer -- which grades those on the right cube
  -- can write them as puzzles. Every other source, and every puzzle,
  stays: `store/4` is idempotent over them. Called inside the transaction
  that stores the fresh answer (`Oskol.Reviews.replace/8`), so the game is
  never owed puzzles while its old answer is what is stored.
  """
  def reopen(game_id, game_number) do
    {:ok, _} =
      Repo.transaction(fn ->
        from(s in Source,
          where:
            s.game_id == ^game_id and s.game_number == ^game_number and
              s.skipped_reason == @post_take
        )
        |> Repo.delete_all()

        from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
        |> Repo.update_all(
          set: [puzzles_extracted_at: nil, puzzles_error: nil, puzzles_attempts: 0]
        )
      end)

    :ok
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
  # write got there first, not whichever we hoped for. Returns the ids by
  # key and how many rows this write made.
  defp resolve_ids([], _attempt, written), do: {%{}, written}

  defp resolve_ids(puzzles, attempt, written) do
    keys = Enum.map(puzzles, & &1.key)
    found = Repo.all(from(p in Puzzle, where: p.key in ^keys, select: {p.key, p.id})) |> Map.new()

    case Enum.reject(puzzles, &Map.has_key?(found, &1.key)) do
      [] ->
        {found, written}

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
            {found, written}

          rows ->
            # No conflict target: the key index and the id index both apply,
            # and losing either race means this row is already someone
            # else's problem, so read back rather than guess.
            {inserted, _} =
              Repo.insert_all(Puzzle, Enum.map(rows, &elem(&1, 1)), on_conflict: :nothing)

            {more, written} =
              resolve_ids(Enum.map(rows, &elem(&1, 0)), attempt + 1, written + inserted)

            {Map.merge(found, more), written}
        end
    end
  end

  # The one write that touches a stored answer: a complete answer to a
  # question whose stored answer is not complete. Decided on the `complete`
  # column, Gleam's word on each answer, so nothing here reads inside one;
  # a complete row is never matched, so a rerun writes nothing. Returns
  # how many rows it upgraded.
  defp upgrade_answers(puzzles) do
    puzzles
    |> Enum.filter(& &1.complete)
    |> Enum.reduce(0, fn puzzle, count ->
      {upgraded, _} =
        from(p in Puzzle, where: p.key == ^puzzle.key and p.complete == false)
        |> Repo.update_all(
          set: [
            answer: puzzle.answer,
            evaluated_by: puzzle.evaluated_by,
            complete: true,
            answer_upgraded_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          ]
        )

      count + upgraded
    end)
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
      complete: puzzle.complete,
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

  # ---------- What the deck is owed ----------

  @doc """
  The mistakes on seats this account owns that no deck holds yet, newest
  game first, narrowed to `game_ids` when any are given.

  The query is coarse on purpose: it finds the rows whose seat *names* this
  account, and each row comes back with its seat so that
  `src/oskol/rooms/seat.gleam` -- and not this file -- decides whose
  mistake it is. Nothing here compares a credential.

  Reading charges a try against every row it returns, exactly as an engine
  call is charged before it is made: a sync that keeps crashing must not
  have the sweep coming back for the same rows every minute for ever. A row
  that reaches a deck is marked and leaves this query, so the charge only
  outlives a failure.
  """
  def owned_sources(user_id, game_ids) when is_binary(user_id) do
    ids =
      owed_deck()
      |> where([s], s.owner_user_id == ^user_id)
      |> scope_games(game_ids)
      |> select([s], s.id)
      |> Repo.all()

    charge_sync(ids)
    sources_by_id(ids)
  end

  @doc "The deck holds these source rows now."
  def mark_synced([]), do: :ok

  def mark_synced(ids) when is_list(ids) do
    from(s in Source, where: s.id in ^ids)
    |> Repo.update_all(set: [deck_synced_at: DateTime.utc_now(), deck_error: nil])

    :ok
  end

  @doc """
  These rows could not be put in a deck. Logged every time, and recorded on
  the rows once their tries are spent, so the sweep lets them go and an
  operator can see why it did.
  """
  def sync_failed([], _reason), do: :ok

  def sync_failed(ids, reason) when is_list(ids) do
    Logger.error("deck sync failed for #{length(ids)} puzzle sources: #{reason}")

    from(s in Source, where: s.id in ^ids, where: s.deck_attempts >= @max_attempts)
    |> Repo.update_all(set: [deck_error: String.slice(to_string(reason), 0, 500)])

    :ok
  end

  @doc """
  The accounts with mistakes no deck holds yet, and the games those
  mistakes are in: at most `limit` of them, the most recent first.

  A read, and only a read. It is the sweep's work list, the dry run of
  `mix oskol.puzzles.sync`, and how a game that has just been graded finds
  out whose mistakes it wrote.
  """
  def deck_pending(game_ids, limit) when is_list(game_ids) and is_integer(limit) do
    owed_deck()
    |> scope_games(game_ids)
    |> group_by([s], s.owner_user_id)
    |> select([s], %{
      user_id: type(s.owner_user_id, :string),
      game_ids: fragment("array_agg(DISTINCT ?)", s.game_id),
      sources: count(s.id),
      recent: max(s.inserted_at)
    })
    |> order_by([s], desc: max(s.inserted_at))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Let the rows that gave up be tried again: an operator has fixed whatever
  `deck_error` was complaining about. Returns how many were reopened.
  """
  def reset_deck_attempts do
    {count, _} =
      from(s in Source, where: not is_nil(s.deck_error), where: is_nil(s.deck_synced_at))
      |> Repo.update_all(set: [deck_attempts: 0, deck_error: nil])

    count
  end

  @doc """
  Point these games' sources at the accounts that own their seats.

  Run inside the write that can change the answer: when the sources are
  first written, and when a sign-in stamps a game's seats. One statement,
  and it only ever writes where the answer moved, so running it twice
  writes nothing the second time.
  """
  def refresh_owners([]), do: :ok

  def refresh_owners(game_ids) when is_list(game_ids) do
    Repo.query!(
      """
      UPDATE puzzle_sources s
      SET owner_user_id = (p ->> 'user_id')::uuid, updated_at = now()
      FROM games g, LATERAL jsonb_array_elements(oskol_players_jsonb(g.players)) p
      WHERE g.id = s.game_id
        AND s.game_id = ANY($1)
        AND p ->> 'id' = s.player_id
        AND p ->> 'user_id' IS NOT NULL
        AND s.owner_user_id IS DISTINCT FROM (p ->> 'user_id')::uuid
      """,
      [game_ids]
    )

    :ok
  end

  @doc """
  The mistakes on seats this guest's cookie holds and no account owns,
  newest game first.

  A guest has no deck, so this is their whole practice session. The
  containment test is the one the seated-rooms index answers; the seat
  rides back with each row and the holder rule says which of them are
  really this browser's.
  """
  def guest_sources(guest_id, limit \\ 500)

  def guest_sources(guest_id, limit) when is_binary(guest_id) and guest_id != "" do
    held = [%{"guest_id" => guest_id}]

    from(g in Oskol.Persistence.Game,
      join: s in Source,
      on: s.game_id == g.id and not is_nil(s.puzzle_id),
      inner_lateral_join:
        p in fragment("jsonb_array_elements(oskol_players_jsonb(?))", g.players),
      on: fragment("? ->> 'id'", p) == s.player_id,
      left_join: r in Review,
      on: r.game_id == s.game_id and r.game_number == s.game_number,
      where: fragment("oskol_players_jsonb(?) @> ?::jsonb", g.players, ^held),
      where: fragment("? ->> 'guest_id'", p) == ^guest_id,
      where: is_nil(fragment("? ->> 'user_id'", p)),
      order_by: [desc: coalesce(r.inserted_at, s.inserted_at), asc: s.turn],
      limit: ^limit,
      select: %{
        id: s.id,
        puzzle_id: s.puzzle_id,
        game_id: s.game_id,
        game_number: s.game_number,
        kind: s.kind,
        turn: s.turn,
        ended_at: coalesce(r.inserted_at, s.inserted_at),
        player_id: s.player_id,
        guest_id: fragment("? ->> 'guest_id'", p),
        user_id: fragment("? ->> 'user_id'", p)
      }
    )
    |> Repo.all()
    |> with_questions()
  end

  def guest_sources(_guest_id, _limit), do: []

  # Mistakes an account owns that its deck does not hold and that still have
  # tries left: the whole of what the sweep is for, and exactly the partial
  # index `puzzle_sources_owed_deck` holds. No join, because a guest's
  # mistakes are never synced and this set would otherwise grow with every
  # guest who ever plays.
  defp owed_deck do
    from(s in Source,
      where: not is_nil(s.owner_user_id),
      where: not is_nil(s.puzzle_id),
      where: is_nil(s.deck_synced_at),
      where: s.deck_attempts < @max_attempts
    )
  end

  defp scope_games(query, []), do: query
  defp scope_games(query, game_ids), do: where(query, [s], s.game_id in ^game_ids)

  # Charged outside any transaction and before the write, for the same
  # reason the extraction charges there: a rollback must not refund it.
  defp charge_sync([]), do: :ok

  defp charge_sync(ids) do
    from(s in Source, where: s.id in ^ids)
    |> Repo.update_all(inc: [deck_attempts: 1])

    :ok
  end

  defp sources_by_id([]), do: []

  defp sources_by_id(ids) do
    from(s in Source,
      join: g in Oskol.Persistence.Game,
      on: g.id == s.game_id,
      inner_lateral_join:
        p in fragment("jsonb_array_elements(oskol_players_jsonb(?))", g.players),
      on: fragment("? ->> 'id'", p) == s.player_id,
      left_join: r in Review,
      on: r.game_id == s.game_id and r.game_number == s.game_number,
      where: s.id in ^ids,
      order_by: [desc: coalesce(r.inserted_at, s.inserted_at), asc: s.turn],
      select: %{
        id: s.id,
        puzzle_id: s.puzzle_id,
        game_id: s.game_id,
        game_number: s.game_number,
        kind: s.kind,
        turn: s.turn,
        ended_at: coalesce(r.inserted_at, s.inserted_at),
        player_id: s.player_id,
        guest_id: fragment("? ->> 'guest_id'", p),
        user_id: fragment("? ->> 'user_id'", p)
      }
    )
    |> Repo.all()
    |> with_questions()
  end

  # The questions these sources ask, in one query rather than one each. The
  # puzzle row is what a card carries and what a prompt is written from.
  defp with_questions([]), do: []

  defp with_questions(rows) do
    questions =
      from(p in Puzzle,
        where: p.id in ^Enum.map(rows, & &1.puzzle_id),
        select: {p.id, p.question}
      )
      |> Repo.all()
      |> Map.new()

    for row <- rows, question = Map.get(questions, row.puzzle_id), question != nil do
      Map.put(row, :question, question)
    end
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
