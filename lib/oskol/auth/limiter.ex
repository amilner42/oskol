defmodule Oskol.Auth.Limiter do
  @moduledoc """
  The counters behind the sign-in rate limits: one ETS table of
  `{key, window_start, count}`, incremented through the `count` and
  `allow_mail` capabilities.

  The Gleam handler chooses which buckets a send reserves; application
  configuration supplies their limits and windows through the auth capability.
  Counters use fixed windows that reset when they run out.

  **Per node and uptime.** A restart clears ETS, and a second node would get
  its own allowance. This is a best-effort spend guard, not a durable billing
  cap. Nothing here is a security control on its own: a token is still hashed,
  single use, fifteen minutes and five tries.
  """

  use GenServer
  require Logger

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Bump `key` and answer how many it holds inside the current window, this one
  included. A window that has run out starts again at one.
  """
  def count(key, window_s) when is_binary(key) and is_integer(window_s) and window_s > 0 do
    GenServer.call(__MODULE__, {:count, key, window_s})
  rescue
    # A counter is never worth a 500. Failing open costs at most some mail.
    _ -> 1
  end

  @doc """
  Atomically reserve one message from every `{key, limit, window}` bucket.
  Nothing is incremented unless all buckets have room, which prevents a
  refused guest from consuming the node-global budget or another address's.
  """
  def allow_mail(buckets) when is_list(buckets) do
    GenServer.call(__MODULE__, {:allow_mail, buckets})
  rescue
    # As with count/2, an unavailable in-memory limiter must not turn login
    # into a 500. The process normally lives for the whole application.
    _ -> true
  end

  @doc "Forget every count. Tests only."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:count, key, window_s}, _from, state) do
    now = System.system_time(:second)

    count =
      case :ets.lookup(@table, key) do
        [{^key, started, _}] when now - started < window_s ->
          :ets.update_counter(@table, key, {3, 1})

        _ ->
          :ets.insert(@table, {key, now, 1})
          1
      end

    {:reply, count, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:allow_mail, buckets}, _from, state) do
    now = System.system_time(:second)
    buckets = Enum.map(buckets, &bucket(&1, now))

    if Enum.all?(buckets, fn {_key, _started, limit, _window_s, count} -> count < limit end) do
      Enum.each(buckets, fn {key, started, _limit, _window_s, count} ->
        :ets.insert(@table, {key, started, count + 1})
      end)

      {:reply, true, state}
    else
      log_limited(buckets)

      {:reply, false, state}
    end
  end

  # Keys nobody has touched for a day are dead weight: an abuser's address
  # is not worth remembering, and the table must not grow forever.
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - 86_400
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.hours(1))

  defp bucket({:limit_bucket, key, limit, window_s}, now)
       when is_binary(key) and is_integer(limit) and limit > 0 and is_integer(window_s) and
              window_s > 0 do
    {started, count} =
      case :ets.lookup(@table, key) do
        [{^key, started, count}] when now - started < window_s -> {started, count}
        _ -> {now, 0}
      end

    {key, started, limit, window_s, count}
  end

  # Values after these prefixes are guest ids, addresses, or opaque source
  # hashes. Logs name only the exhausted policy bucket.
  defp bucket_name({"start:global", _started, _limit, _window_s, _count}), do: "global"
  defp bucket_name({"start:guest:" <> _, _started, _limit, _window_s, _count}), do: "guest"
  defp bucket_name({"start:address:" <> _, _started, _limit, _window_s, _count}), do: "address"
  defp bucket_name({"start:source:" <> _, _started, _limit, _window_s, _count}), do: "source"
  defp bucket_name({_key, _started, _limit, _window_s, _count}), do: "unknown"

  # A refusal must be observable without becoming an attacker-controlled log
  # stream. Each policy kind writes at most one anonymous warning per its
  # actual fixed window, including one that straddles a Unix-time boundary.
  defp log_limited(buckets) do
    buckets
    |> Enum.filter(fn {_key, _started, limit, _window_s, count} -> count >= limit end)
    |> Enum.group_by(&bucket_name/1)
    |> Enum.each(fn {name, exhausted} ->
      {_key, started, _limit, window_s, _count} =
        Enum.min_by(exhausted, fn {_key, started, _limit, _window_s, _count} -> started end)

      marker = {:limit_log, name, started, window_s}

      if :ets.insert_new(@table, {marker, started, 1}) do
        Logger.warning("auth mail limited: #{name}")
      end
    end)
  end

  # The table belongs to whoever gets there first: the supervised process on
  # boot, or the first caller in a test that runs without the tree.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
