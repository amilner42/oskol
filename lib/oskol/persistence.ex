defmodule Oskol.Persistence do
  @moduledoc """
  The database picture of a game: one `games` row per room (keyed by the
  public code) and one `game_actions` row per state-mutating step. A game is
  its seed plus its action log, so these two tables are enough to rebuild a
  live room after a deploy or a machine sleep — see `Oskol.Game.Rehydrator`.

  Everything here is plain synchronous Repo work; the room never calls it
  directly. Writes go through `Oskol.Game.Persister` (async, ordered), reads
  through the rehydrator.
  """

  import Ecto.Query
  alias Oskol.Gleam.Interop
  alias Oskol.Repo

  defmodule Game do
    @moduledoc "One room. `players` round-trips seats: ids, names, and the guest holding each."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "games" do
      field(:slug, :string)
      field(:config, :map, default: %{})
      field(:seed, :integer)
      # The log snapshot used to store per-game records, and its completed-
      # game marker. Only the latter invalidates records: an ordinary move
      # can lengthen the log without finishing another game.
      field(:records_through, :integer)
      field(:records_generation, :integer)
      # This room has a game that ended and may still owe an analysis. Set
      # when the game ends, cleared when the queue finds nothing owed.
      field(:analysis_owed, :boolean, default: false)
      field(:analysis_owed_at, :utc_datetime_usec)
      field(:players, {:array, :map}, default: [])
      # Where the game stands, as of its last step: `gamekit/host.summary_json`
      # (to_act, on_clock, outcome, phase, players' public counters). Written
      # with every step so active games can be listed and watched from here
      # without waking a room. Null for a row from before it existed, until
      # its room next wakes.
      field(:state, :map)
      field(:status, :string, default: "waiting")
      field(:winners, {:array, :string}, default: [])

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule GameAction do
    @moduledoc """
    One applied step: exactly what the engine saw. `kind` is `"action"`
    (a payload applied for a player — including auto actions the engine takes
    inside `apply` for an expired clock) or `"expire"` (the room resolved a
    clock that ran out). `at_ms` is milliseconds since the instance started;
    replaying the log at these offsets reproduces the clocks too.
    """
    use Ecto.Schema

    @primary_key false
    schema "game_actions" do
      field(:game_id, :string, primary_key: true)
      field(:index, :integer, primary_key: true)
      field(:kind, :string)
      field(:player_id, :string)
      field(:payload, :map)
      field(:at_ms, :integer)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  # ---------- Writes (called from Oskol.Game.Persister) ----------

  def insert_game(game_id, slug, config) do
    %Game{id: game_id, slug: slug, config: config, status: "waiting"}
    |> Repo.insert(on_conflict: :nothing)

    :ok
  end

  def update_config(game_id, config) do
    update_game(game_id, config: config)
  end

  def update_players(game_id, players) do
    update_game(game_id, players: keep_owners(game_id, players))
  end

  def mark_started(game_id, seed, config, players, state) do
    update_game(game_id,
      seed: seed,
      config: config,
      players: keep_owners(game_id, players),
      status: "playing",
      state: state
    )
  end

  # A room writes its seat list from memory. If a sign-in stamped a seat on
  # disk that the room has not heard of yet, the room's list says unowned
  # and the row says owned; the row wins (`seat.keep_owners`, in Gleam):
  # an owner never comes off a seat. One read, and only on the rare writes
  # that carry the whole seat list (a join, a claim, a start).
  defp keep_owners(game_id, players) when is_list(players) do
    case players(game_id) do
      [] ->
        players

      stored ->
        :oskol@rooms@seat.keep_owners(to_seats(players), to_seats(stored))
        |> apply_seats(players)
    end
  end

  defp keep_owners(_game_id, players), do: players

  @doc """
  The snapshot a room writes when it comes back from the log, so an old row
  heals on its first wake. Not activity: `updated_at` stays where the last
  step left it, so a wake does not jump a room up the list.
  """
  def mirror_state(game_id, state) do
    from(g in Game, where: g.id == ^game_id) |> Repo.update_all(set: [state: state])
    :ok
  end

  def mark_finished(game_id, winners) do
    update_game(game_id, status: "finished", winners: winners)
  end

  def append_action(game_id, index, kind, player_id, payload, at_ms, state) do
    Repo.insert!(
      %GameAction{
        game_id: game_id,
        index: index,
        kind: kind,
        player_id: player_id,
        payload: payload,
        at_ms: at_ms
      },
      on_conflict: :nothing
    )

    # Keep the game row's updated_at fresh so rehydration recency is visible;
    # and write down where the game now stands, in the same statement.
    update_game(game_id, state: state)
  end

  defp update_game(game_id, sets) do
    sets = Keyword.put(sets, :updated_at, DateTime.utc_now())
    from(g in Game, where: g.id == ^game_id) |> Repo.update_all(set: sets)
    :ok
  end

  # ---------- Reads ----------

  @doc "The game row and its ordered action log, or :not_found."
  def fetch(game_id) do
    case Repo.get(Game, game_id) do
      nil ->
        :not_found

      game ->
        actions =
          from(a in GameAction, where: a.game_id == ^game_id, order_by: a.index)
          |> Repo.all()

        {:ok, game, actions}
    end
  end

  @doc """
  The unfinished rooms this caller holds a seat in, most recently touched
  first: what a returning browser can pick back up. A waiting room counts
  (its lobby is where it resumes to); a finished game is the replay's, not
  this list's. Rows only: no room is woken by asking.

  A seat matches on the guest that took it *or* on the account that owns
  it, so an account's games follow it to any browser it signs in on. Which
  of the matched seats is really the caller's is the holder rule, in Gleam
  (`src/oskol/rooms/seat.gleam`); this is the coarse read behind it.
  """
  def seated_rooms(guest_id, user_id \\ nil) do
    case seated_rooms_query(guest_id, user_id) do
      nil ->
        []

      query ->
        Repo.all(query)
    end
  end

  @doc false
  # Kept as a query builder so the regression test can EXPLAIN the exact
  # query we send to PostgreSQL, including its parameters.
  def seated_rooms_query(guest_id, user_id \\ nil) do
    # Postgrex encodes a jsonb parameter itself: hand it the term, not text.
    case seat_match(guest_id, user_id) do
      nil ->
        nil

      held ->
        from(g in Game,
          # These literals deliberately match the partial-index predicate.
          # A bound status array could force a generic prepared plan to scan
          # instead, even though every caller wants only resumable rooms.
          where: fragment("? IN ('waiting', 'playing')", g.status),
          where: ^held,
          order_by: [desc: g.updated_at]
        )
    end
  end

  # "a seat this guest took, or a seat this account owns", as whichever of
  # the two the caller actually has.
  defp seat_match(guest_id, user_id) do
    guest = holds("guest_id", guest_id)
    user = holds("user_id", user_id)

    cond do
      guest && user -> dynamic([g], ^guest or ^user)
      guest -> guest
      user -> user
      true -> nil
    end
  end

  defp holds(key, value) when is_binary(value) and byte_size(value) > 0 do
    entry = [%{key => value}]
    # Keep this expression byte-for-byte equivalent to the partial GIN index
    # in 20260920000001_index_seated_rooms. `to_jsonb(players)` itself is
    # stable in PostgreSQL and therefore cannot be indexed directly.
    dynamic([g], fragment("oskol_players_jsonb(?) @> ?::jsonb", g.players, ^entry))
  end

  defp holds(_key, _value), do: nil

  @doc "A room's seats as the row holds them, without waking it or reading its log."
  def players(game_id) when is_binary(game_id) do
    from(g in Game, where: g.id == ^game_id, select: g.players)
    |> Repo.one()
    |> Kernel.||([])
  end

  @doc """
  Hand every seat this guest holds to an account, and move the guest's
  seats to its fresh id. One statement per room, all statuses (a finished
  game is part of what an account keeps), inside one transaction with the
  guest row's own move.

  A seat is stamped only when it is this guest's, that guest is a real one
  (a row from before guests, or a seat tooling took, has none and can never
  be stamped), and no account owns it yet. At a table where this account
  already owns a seat, the other seat is not stamped (one person, one seat
  per table, however many devices) but its `guest_id` still moves to the
  new one, so the browser keeps playing it as a guest seat. A stamped seat
  keeps nothing of the old guest either: its `guest_id` is the new one,
  and ownership is the account.

  Returns `{seats_stamped, game_ids}`; the ids are the rooms that changed,
  so a live one can be told (`Oskol.Game.GameServer.stamp/4`).
  """
  def stamp_seats(old_guest_id, new_guest_id, user_id)
      when is_binary(old_guest_id) and byte_size(old_guest_id) > 0 and
             is_binary(new_guest_id) and byte_size(new_guest_id) > 0 and
             is_binary(user_id) and byte_size(user_id) > 0 do
    mine = [%{"guest_id" => old_guest_id}]

    rows =
      from(g in Game,
        where: fragment("to_jsonb(?) @> ?::jsonb", g.players, ^mine),
        select: {g.id, g.players}
      )
      |> Repo.all()

    Enum.reduce(rows, {0, []}, fn {game_id, players}, {count, ids} ->
      # The rule is Gleam's (`seat.stamp`), the same one a live room's
      # memory follows.
      {seats, stamped} =
        :oskol@rooms@seat.stamp(to_seats(players), old_guest_id, new_guest_id, user_id)

      moved = apply_seats(seats, players)

      if moved == players do
        {count, ids}
      else
        from(g in Game, where: g.id == ^game_id)
        |> Repo.update_all(set: [players: moved])

        {count + stamped, [game_id | ids]}
      end
    end)
  end

  def stamp_seats(_, _, _), do: {0, []}

  # A row's seat list as the Gleam seat rules read it: `Seat(player_id,
  # guest_id, user_id)`, an empty or missing id being no id at all.
  defp to_seats(players) do
    for player <- players, is_map(player), is_binary(player["id"]) do
      {:seat, player["id"], Interop.opt(blank_to_nil(player["guest_id"])),
       Interop.opt(blank_to_nil(player["user_id"]))}
    end
  end

  # Those seats written back onto the row's entries, by player id; every
  # other key of an entry (the name) is left as it was.
  defp apply_seats(seats, players) do
    by_id = Map.new(seats, fn {:seat, id, guest, user} -> {id, {guest, user}} end)

    Enum.map(players, fn
      %{"id" => id} = player when is_map_key(by_id, id) ->
        {guest, user} = by_id[id]

        player
        |> put_id("guest_id", Interop.unopt(guest))
        |> put_id("user_id", Interop.unopt(user))

      player ->
        player
    end)
  end

  defp put_id(player, _key, nil), do: player
  defp put_id(player, key, id), do: Map.put(player, key, id)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  The names these seat entries play under: the account's name where an
  account owns the seat, else the name typed at the door. One query for
  however many rows, and nothing is copied onto a seat -- a rename is one
  row, and every game shows it at once.
  """
  def display_names(players_lists) do
    ids =
      for players <- players_lists,
          player <- players,
          is_map(player),
          id = player["user_id"],
          is_binary(id) and id != "",
          uniq: true,
          do: id

    names = Oskol.Auth.usernames(ids)

    for players <- players_lists do
      for player <- players, is_map(player) do
        Map.put(player, "name", names[player["user_id"]] || player["name"] || "")
      end
    end
  end

  @doc """
  These seat entries with a `username` key on the ones an account owns: the
  name that seat plays under, looked up once. Nothing is written; the key
  is for a room coming up, which does no IO of its own.
  """
  def with_usernames(players) when is_list(players) do
    names =
      Oskol.Auth.usernames(
        for player <- players,
            is_map(player),
            id = player["user_id"],
            is_binary(id) and id != "",
            uniq: true,
            do: id
      )

    Enum.map(players, fn player ->
      case is_map(player) && names[player["user_id"]] do
        name when is_binary(name) -> Map.put(player, "username", name)
        _ -> player
      end
    end)
  end

  def with_usernames(players), do: players

  @doc "Whether a game row already claims this code (live room or not)."
  def game_exists?(game_id) do
    Repo.exists?(from(g in Game, where: g.id == ^game_id))
  end
end
