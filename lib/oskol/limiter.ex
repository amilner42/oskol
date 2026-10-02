defmodule Oskol.Limiter do
  @moduledoc """
  The counters behind every rate limit: one ETS table of
  `{key, window_start, count, window_s}`. Sign-in mail reserves through the
  auth capability's `allow_mail` (`start:*` buckets), the analysis board
  through the analysis capability's `allow_ask` (`analysis:*` buckets).

  A Gleam handler chooses which buckets a request reserves; application
  configuration supplies their limits and windows through its capability.
  Counters use fixed windows that reset when they run out.

  **Per node and uptime.** A restart clears ETS, and a second node would get
  its own allowance. This is a best-effort spend guard, not a durable billing
  cap. Nothing here is a security control on its own: a sign-in token is
  still hashed, single use, fifteen minutes and five tries.
  """

  use GenServer
  require Logger

  @table __MODULE__
  @call_timeout 250

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically reserve one use from every `{:limit_bucket, key, limit,
  window_s}` bucket. Nothing is incremented unless all buckets have room,
  which prevents a refused guest from consuming the node-global budget or
  another address's.

  `{:ok, nil}`, or `{:error, {:refused, key, retry_after_s}}` naming the
  full bucket that frees up last and how long until it does: the shape of
  Gleam's `Result(Nil, caps/analysis.Refused)`.
  """
  def allow(buckets) when is_list(buckets) do
    GenServer.call(__MODULE__, {:allow, buckets}, @call_timeout)
  rescue
    _ -> unavailable(buckets)
  catch
    :exit, _ -> unavailable(buckets)
  end

  # An unavailable limiter must not turn a request into a 500. Sign-in fails
  # open: being unable to sign in is worse than a few extra mails. Engine
  # asks fail closed: the engine is shared with every game's review, and a
  # limiter that is not answering is not one that is counting.
  @unavailable_retry_s 30

  defp unavailable(buckets) do
    if Enum.any?(buckets, &analysis_bucket?/1),
      do: {:error, {:refused, "analysis:limiter", @unavailable_retry_s}},
      else: {:ok, nil}
  end

  defp analysis_bucket?({:limit_bucket, "analysis:" <> _, _, _}), do: true
  defp analysis_bucket?(_), do: false

  @doc """
  Hand back one use to every bucket, as `allow/1` took it: a reservation for
  something that then never happened (an ask the asker could not take). A
  bucket whose window has moved on, or that has nothing in it, is left
  alone. Best effort, never raises.
  """
  def release(buckets) when is_list(buckets) do
    GenServer.call(__MODULE__, {:release, buckets}, @call_timeout)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Sign-in mail's reservation, as the auth capability takes it: a boolean."
  def allow_mail(buckets) when is_list(buckets) do
    match?({:ok, _}, allow(buckets))
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
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:allow, buckets}, _from, state) do
    now = System.system_time(:second)
    buckets = Enum.map(buckets, &bucket(&1, now))

    if Enum.all?(buckets, fn {_key, _started, limit, _window_s, count} -> count < limit end) do
      Enum.each(buckets, fn {key, started, _limit, window_s, count} ->
        :ets.insert(@table, {key, started, count + 1, window_s})
      end)

      {:reply, {:ok, nil}, state}
    else
      log_limited(buckets)

      {key, started, _limit, window_s, _count} =
        buckets
        |> Enum.filter(fn {_key, _started, limit, _window_s, count} -> count >= limit end)
        |> Enum.max_by(fn {_key, started, _limit, window_s, _count} -> started + window_s end)

      {:reply, {:error, {:refused, key, max(started + window_s - now, 1)}}, state}
    end
  end

  def handle_call({:release, buckets}, _from, state) do
    now = System.system_time(:second)

    Enum.each(buckets, fn {:limit_bucket, key, _limit, window_s} ->
      case :ets.lookup(@table, key) do
        [{^key, started, count, stored_window_s}] when count > 0 and now - started < window_s ->
          :ets.insert(@table, {key, started, count - 1, stored_window_s})

        _ ->
          :ok
      end
    end)

    {:reply, :ok, state}
  end

  # Each entry owns its actual configured window. Do not erase a valid bucket
  # merely because it is older than a fixed housekeeping interval.
  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    :ets.foldl(
      fn
        {key, started, _count, window_s}, :ok when now - started >= window_s ->
          :ets.delete(@table, key)
          :ok

        {key, started, _count}, :ok when now - started >= 86_400 ->
          # An upgrade may leave a pre-window entry in a live ETS table.
          :ets.delete(@table, key)
          :ok

        _, :ok ->
          :ok
      end,
      :ok,
      @table
    )

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.hours(1))

  defp bucket({:limit_bucket, key, limit, window_s}, now)
       when is_binary(key) and is_integer(limit) and limit > 0 and is_integer(window_s) and
              window_s > 0 do
    {started, count} =
      case :ets.lookup(@table, key) do
        [{^key, started, count, _stored_window_s}] when now - started < window_s ->
          {started, count}

        [{^key, started, count}] when now - started < window_s ->
          {started, count}

        _ ->
          {now, 0}
      end

    {key, started, limit, window_s, count}
  end

  # Values after these prefixes are guest ids, account ids, addresses, or
  # opaque source hashes. Logs name only the exhausted policy bucket, under
  # the limit it belongs to: "auth mail limited: source", "analysis limited:
  # user".
  defp policy("start:global"), do: {"auth mail", "global"}
  defp policy("start:guest:" <> _), do: {"auth mail", "guest"}
  defp policy("start:address:" <> _), do: {"auth mail", "address"}
  defp policy("start:source:" <> _), do: {"auth mail", "source"}
  defp policy("analysis:global:" <> _), do: {"analysis", "global"}
  defp policy("analysis:guest:" <> _), do: {"analysis", "guest"}
  defp policy("analysis:user:" <> _), do: {"analysis", "user"}
  defp policy(_key), do: {"auth mail", "unknown"}

  # A refusal must be observable without becoming an attacker-controlled log
  # stream. Each policy kind writes at most one anonymous warning per its
  # actual fixed window, including one that straddles a Unix-time boundary.
  defp log_limited(buckets) do
    buckets
    |> Enum.filter(fn {_key, _started, limit, _window_s, count} -> count >= limit end)
    |> Enum.group_by(fn {key, _started, _limit, _window_s, _count} -> policy(key) end)
    |> Enum.each(fn {{limit, name}, exhausted} ->
      {_key, started, _limit, window_s, _count} =
        Enum.min_by(exhausted, fn {_key, started, _limit, _window_s, _count} -> started end)

      # Sign-in's markers keep the shape they had, so a node upgraded with
      # a live table does not log a window twice.
      marker =
        if limit == "auth mail",
          do: {:limit_log, name, started, window_s},
          else: {:limit_log, limit, name, started, window_s}

      if :ets.insert_new(@table, {marker, started, 1, window_s}) do
        Logger.warning("#{limit} limited: #{name}")
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
