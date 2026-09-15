defmodule Oskol.Game.ReadyUpPatch do
  @moduledoc """
  One-off repair of backgammon action logs written before the between-games
  READY existed.

  Until then, when a game of a match (or of unlimited play) ended, the next
  game began in the same step: its opening roll was made at once and the
  log went straight on into its moves. The engine now pauses there until
  both players send `ready`, so an old log replayed today is refused at the
  first action after a game's end, and a room that cannot replay cannot
  rehydrate. There is one set of rules, so the old logs are made to say what
  the new rules need: wherever the replay reaches the pause and the next
  logged entry is not a `ready` (the pause refuses it), a `ready` for each
  seat that has not sent one is inserted before it.

  The board changes nothing a player saw: `ready` spends no randomness, so
  the second one makes the very opening roll the game's end used to make.
  The inserted entries carry the `at_ms` of the step that ended the game,
  so the next game starts at the same moment as it did. The clocks come
  back as they were but for one case the old engine did differently: a
  player who ended a game and then moved first in the next was never taken
  off the clock, where the pause now stops their clock (a Fischer increment)
  and the next game starts it afresh (the turn delay, or a new per-move
  allowance). In a timed room that player gains that little, once per such
  game; nobody loses time. If it would undo a recorded timeout, the room no
  longer ends where it did, and it is reported and left unpatched
  (`:no_longer_finishes`). A dry run names each room's clock, so a timed
  room stands out.

  A log that ends on the pause is left alone: a room created under the new
  rules is waiting there legitimately, and an old room that stopped there
  comes back paused, with the same opening roll waiting behind READY. A log
  already patched has a `ready` after every pause, so a second run inserts
  nothing.

  It runs once by itself, at boot, from the migration
  `PatchReadyUpLogs` (before any room can rehydrate); `mix
  oskol.patch_ready_up` and `Oskol.Release.patch_ready_up/1` run it by hand,
  as a dry run unless told to write.
  """

  import Ecto.Query
  require Logger

  alias Oskol.GameKit
  alias Oskol.Persistence
  alias Oskol.Repo

  @slug "backgammon"
  @ready %{"name" => "ready", "params" => %{}}

  @type insert :: %{
          before_index: non_neg_integer() | nil,
          at_ms: integer(),
          player_id: String.t()
        }
  @type report :: %{
          game_id: String.t(),
          format: String.t(),
          clock: String.t() | nil,
          status: String.t(),
          steps: non_neg_integer(),
          inserts: [insert()],
          result: :unchanged | :would_patch | :patched | {:skipped, String.t()} | {:error, term()}
        }

  @doc """
  Patch every backgammon room played in a format with more than one game.
  `write: true` rewrites the logs that need it, each in its own transaction
  and only when the patched log replays cleanly to the end; otherwise it is
  a dry run. Returns one report per room looked at.
  """
  @spec run(keyword()) :: [report()]
  def run(opts \\ []) do
    write? = Keyword.get(opts, :write, false)

    from(g in Persistence.Game,
      where: g.slug == @slug and g.status in ["playing", "finished"] and not is_nil(g.seed),
      order_by: g.id
    )
    |> Repo.all()
    |> Enum.reject(&(&1.config["format"] == "single"))
    |> Enum.map(&patch_game(&1, write?))
  end

  @doc "One line per room, for a person reading a dry run."
  @spec describe(report()) :: String.t()
  def describe(report) do
    inserts =
      report.inserts
      |> Enum.chunk_by(& &1.before_index)
      |> Enum.map(fn [first | _] = group ->
        "before ##{first.before_index} at #{first.at_ms}ms: #{Enum.map_join(group, ", ", & &1.player_id)}"
      end)

    "#{report.game_id} #{report.format} clock #{report.clock} #{report.status} " <>
      "#{report.steps} steps: " <>
      "#{inspect(report.result)}" <>
      if(inserts == [],
        do: "",
        else: " (#{length(inserts)} boundaries: #{Enum.join(inserts, "; ")})"
      )
  end

  # ---------- one room ----------

  defp patch_game(game, write?) do
    actions =
      from(a in Persistence.GameAction, where: a.game_id == ^game.id, order_by: a.index)
      |> Repo.all()

    base = %{
      game_id: game.id,
      format: game.config["format"],
      clock: game.config["clock"] || "none",
      status: game.status,
      steps: length(actions),
      inserts: []
    }

    # `plan` has already replayed the patched log, entry by entry, through
    # the calls the rehydrator makes: what it ends on is what a room gets.
    with {:ok, final, log, inserts} <- plan(game, actions),
         report = %{base | inserts: inserts},
         :ok <- still_finished(game, final) do
      cond do
        inserts == [] -> Map.put(report, :result, :unchanged)
        not write? -> Map.put(report, :result, :would_patch)
        live?(game.id) -> Map.put(report, :result, {:skipped, "a live room holds it"})
        true -> Map.put(report, :result, write(game.id, log))
      end
    else
      {:error, reason} -> Map.put(base, :result, {:error, reason})
    end
  rescue
    e ->
      %{
        game_id: game.id,
        format: nil,
        clock: nil,
        status: nil,
        steps: 0,
        inserts: [],
        result: {:error, Exception.message(e)}
      }
  end

  # Walk the log through the engine. An entry the pause refuses (any
  # action but a `ready`) gets the readies the pause is waiting for put in
  # before it. Asking the engine what is legal is the expensive part, so it
  # is asked only when an action is refused, and before a clock expiry
  # (which the pause would not refuse, only swallow).
  defp plan(game, actions) do
    with {:ok, instance} <- start(game) do
      seat_ids = Enum.map(game.players, & &1["id"])

      Enum.reduce_while(actions, {:ok, instance, 0, [], []}, fn entry,
                                                                {:ok, inst, prev_at, log, inserts} ->
        {inst, log, inserts} =
          if entry.kind == "expire",
            do: ready_if_paused(inst, seat_ids, prev_at, entry.index, log, inserts),
            else: {inst, log, inserts}

        result =
          case step(inst, entry) do
            {:ok, next} ->
              {:ok, next, log, inserts}

            {:error, reason} ->
              case ready_if_paused(inst, seat_ids, prev_at, entry.index, log, inserts) do
                {_, _, ^inserts} ->
                  {:error, reason}

                {readied, log, inserts} ->
                  with {:ok, next} <- step(readied, entry), do: {:ok, next, log, inserts}
              end
          end

        case result do
          {:ok, next, log, inserts} -> {:cont, {:ok, next, entry.at_ms, [entry | log], inserts}}
          {:error, reason} -> {:halt, {:error, {:replay_failed, entry.index, reason}}}
        end
      end)
      |> case do
        {:ok, inst, _at, log, inserts} -> {:ok, inst, Enum.reverse(log), Enum.reverse(inserts)}
        {:error, _} = error -> error
      end
    end
  end

  defp ready_if_paused(inst, seat_ids, at_ms, before_index, log, inserts) do
    case waiting_on(inst, seat_ids) do
      [] -> {inst, log, inserts}
      waiting -> ready_all(inst, waiting, at_ms, before_index, log, inserts)
    end
  end

  defp ready_all(inst, waiting, at_ms, before_index, log, inserts) do
    Enum.reduce(waiting, {inst, log, inserts}, fn player_id, {inst, log, inserts} ->
      entry = %{kind: "action", player_id: player_id, payload: @ready, at_ms: at_ms, index: nil}
      {:ok, next} = step(inst, entry)
      insert = %{before_index: before_index, at_ms: at_ms, player_id: player_id}
      {next, [entry | log], [insert | inserts]}
    end)
  end

  # A room that had finished must still end finished.
  defp still_finished(game, instance) do
    if game.status == "finished" and not GameKit.finished?(instance),
      do: {:error, :no_longer_finishes},
      else: :ok
  end

  defp start(game) do
    config = game.config
    seats = Enum.map(game.players, &{&1["id"], &1["name"]})

    GameKit.start(
      @slug,
      config["format"],
      seats,
      game.seed,
      GameKit.clock_control(config["clock"] || "none"),
      0,
      Map.to_list(config["selections"] || %{})
    )
  end

  defp step(inst, %{kind: "action"} = entry) do
    case GameKit.apply(inst, entry.player_id, entry.payload, entry.at_ms) do
      {:ok, next, _} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp step(inst, %{kind: "expire"} = entry) do
    case GameKit.expire(inst, entry.at_ms) do
      {:ok, next, _} -> {:ok, next}
      :none -> {:ok, inst}
    end
  end

  # The seats the pause is waiting on, in seat order (none outside it).
  defp waiting_on(inst, seat_ids) do
    Enum.filter(seat_ids, &("ready" in GameKit.legal_names(inst, &1)))
  end

  # A room running in this VM keeps its own action count: renumbering its
  # log under it would lose its next write. (A bare `eval` VM runs no rooms.)
  defp live?(game_id) do
    Process.whereis(Oskol.GameRegistry) != nil and
      Registry.lookup(Oskol.GameRegistry, game_id) != []
  end

  defp write(game_id, log) do
    now = DateTime.utc_now()

    rows =
      log
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        %{
          game_id: game_id,
          index: index,
          kind: entry.kind,
          player_id: entry.player_id,
          payload: entry.payload,
          at_ms: entry.at_ms,
          inserted_at: Map.get(entry, :inserted_at) || now
        }
      end)

    Repo.transaction(fn ->
      from(a in Persistence.GameAction, where: a.game_id == ^game_id) |> Repo.delete_all()
      rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Persistence.GameAction, &1))
    end)
    |> case do
      {:ok, _} ->
        Logger.info("ready-up patch: #{game_id} rewritten, #{length(rows)} steps")
        :patched

      {:error, reason} ->
        {:error, reason}
    end
  end
end
