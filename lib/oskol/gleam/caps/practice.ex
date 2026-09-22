defmodule Oskol.Gleam.Caps.Practice do
  @moduledoc """
  Real IO for src/oskol/caps/practice.gleam, over the `retain` library. Keep
  constructor tags and field order in lockstep:

      PracticeCaps(put_user, put_items, queue, start, review, amend,
      defer_until, master, suspend, resume, summary)
      Item(key, tags, content_json, position)
      Card(key, tags, content_json, level, due_ms, reps, lapses, status)
      Session(reviews, fresh, new_remaining_today)
      Ask(tags, limit, offset, new_after_reviews, new_limit)
      Graded(level_before, level_after, due_ms, review_id)
      Summary(group, count, new_count, active_count, suspended_count,
      due_count, mean_level)
      Outcome: :pass | :partial | :fail | :again | :known
      Status: :new | :active | :suspended
      PracticeError: :unknown_card | :card_suspended | :out_of_order
      | :not_amendable

  Times cross as Unix milliseconds, as they do everywhere else on this
  boundary; a card's `content` crosses as JSON text, because Retain stores it
  opaquely and so does everything above here.

  Tags and summary groups are sorted by key before they cross. A map has no
  order, and an unsorted list would make the same deck serialise differently
  between runs -- the same rule the scenes follow.

  Only the three writes a player can be refused return a `Result`: answering a
  card that is not theirs, is paused, or is out of order, and correcting a row
  that is not an attempt. Everything else raises and surfaces as a 500, which
  is what a missing deck is -- `put_user` opens every session.
  """

  import Oskol.Gleam.Interop

  # Retain reads "today" in the learner's own timezone. Until the client tells
  # us where a player is, every deck is on one clock, and this is the one the
  # site already runs its days on.
  @default_tz "Etc/UTC"

  def build do
    {:practice_caps, &put_user/3, &put_items/2, &queue/2, &start/2, &review/3, &amend/4,
     &defer_until/3, &master/2, &suspend/2, &resume/2, &summary/2}
  end

  def default_tz, do: @default_tz

  defp put_user(uid, tz, new_per_day) do
    tz = if tz == "", do: @default_tz, else: tz
    {:ok, _} = Retain.put_user(uid, tz: tz, new_per_day: new_per_day)
    nil
  end

  defp put_items(uid, items) do
    rows =
      Enum.map(items, fn {:item, key, tags, content_json, position} ->
        %{
          key: key,
          tags: Map.new(tags),
          content: Jason.decode!(content_json),
          position: unopt(position)
        }
      end)

    {:ok, %{inserted: inserted}} = Retain.put_items(uid, rows)
    inserted
  end

  defp queue(uid, {:ask, tags, limit, offset, new_after_reviews, new_limit}) do
    opts =
      [
        tags: Map.new(tags),
        limit: limit,
        offset: offset,
        new: if(new_after_reviews, do: :after_reviews, else: :always)
      ]
      |> put_opt(:new_limit, unopt(new_limit))

    {:ok, %{reviews: reviews, new: fresh, new_remaining_today: remaining}} =
      Retain.queue(uid, opts)

    {:session, Enum.map(reviews, &card/1), Enum.map(fresh, &card/1), remaining}
  end

  defp start(uid, keys) do
    {:ok, %{started: started}} = Retain.start(uid, keys)
    started
  end

  defp review(uid, key, outcome) do
    uid |> Retain.review(key, outcome(outcome)) |> graded()
  end

  defp amend(uid, key, review_id, outcome) do
    uid |> Retain.amend(key, review_id, outcome(outcome)) |> graded()
  end

  defp defer_until(uid, key, until_ms) do
    uid |> Retain.defer(key, DateTime.from_unix!(until_ms, :millisecond)) |> graded()
  end

  defp master(uid, keys) do
    {:ok, %{mastered: mastered}} = Retain.master(uid, keys)
    mastered
  end

  defp suspend(uid, keys) do
    {:ok, %{suspended: suspended}} = Retain.suspend(uid, keys)
    suspended
  end

  defp resume(uid, keys) do
    {:ok, %{resumed: resumed}} = Retain.resume(uid, keys)
    resumed
  end

  defp summary(uid, group_by) do
    {:ok, rows} = Retain.summary(uid, group_by: group_by)

    Enum.map(rows, fn row ->
      {:summary, pairs(row.group), row.count, row.new_count, row.active_count,
       row.suspended_count, row.due_count, row.mean_level / 1}
    end)
  end

  ## Conversions

  defp card(item) do
    {:card, item.key, pairs(item.tags), Jason.encode!(item.content), item.level,
     DateTime.to_unix(item.due, :millisecond), item.reps, item.lapses, Retain.Item.status(item)}
  end

  defp graded({:ok, %{} = result}) do
    {:ok,
     {:graded, result.level_before, result.level_after,
      DateTime.to_unix(result.due, :millisecond), result.review_id}}
  end

  defp graded({:error, :not_found}), do: {:error, :unknown_card}
  defp graded({:error, :suspended}), do: {:error, :card_suspended}
  defp graded({:error, :out_of_order}), do: {:error, :out_of_order}
  defp graded({:error, :not_amendable}), do: {:error, :not_amendable}

  # The Gleam Outcome type is closed, so this cannot be reached from a
  # handler; if it ever is, it is a bug and should read like one.
  defp outcome(outcome) when outcome in [:pass, :partial, :fail, :again, :known], do: outcome

  # A map has no order; the wire needs one.
  defp pairs(tags), do: tags |> Enum.map(fn {k, v} -> {k, v || ""} end) |> Enum.sort()

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
