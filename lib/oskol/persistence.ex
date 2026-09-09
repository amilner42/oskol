defmodule Oskol.Persistence do
  @moduledoc """
  The database picture of a game: one `games` row per room (keyed by the
  public code) and one `game_actions` row per state-mutating step. A game is
  its seed plus its action log, so these two tables are enough to rebuild a
  live room after a deploy or a machine sleep — see `Oskol.Game.Rehydrator`.

  Everything here is plain synchronous Repo work; the room never calls it
  directly. Writes go through `Oskol.Game.Persister` (async, ordered), reads
  through the rehydrator and the pruner.
  """

  import Ecto.Query
  alias Oskol.Repo

  defmodule Game do
    @moduledoc "One room. `players` round-trips seats: ids, names, seat tokens."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "games" do
      field(:slug, :string)
      field(:config, :map, default: %{})
      field(:seed, :integer)
      field(:players, {:array, :map}, default: [])
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
    update_game(game_id, players: players)
  end

  def mark_started(game_id, seed, config, players) do
    update_game(game_id, seed: seed, config: config, players: players, status: "playing")
  end

  def mark_finished(game_id, winners) do
    update_game(game_id, status: "finished", winners: winners)
  end

  def append_action(game_id, index, kind, player_id, payload, at_ms) do
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

    # Keep the game row's updated_at fresh so an active game never looks
    # prunable, and so rehydration recency is visible.
    update_game(game_id, [])
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

  @doc "Whether a game row already claims this code (live room or not)."
  def game_exists?(game_id) do
    Repo.exists?(from(g in Game, where: g.id == ^game_id))
  end

  # ---------- Retention ----------

  @doc """
  Delete unfinished games untouched for `days` days, and their actions
  (the FK cascades). Finished games are kept. Returns the number deleted.
  """
  def prune_unfinished(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      from(g in Game, where: g.status in ["waiting", "playing"] and g.updated_at < ^cutoff)
      |> Repo.delete_all()

    count
  end
end
