defmodule Oskol.Gleam.Caps.Practice do
  @moduledoc """
  Real IO for src/oskol/caps/practice.gleam, over the `retain` library. Keep
  constructor tags and field order in lockstep:

      PracticeCaps(put_user, put_items, cards, relapse, queue, start,
      start_new, review, amend, defer_until, defer_tomorrow, master,
      suspend, resume, summary)
      Item(key, tags, content_json, position)
      Card(key, tags, content_json, level, due_ms, reps, lapses, status)
      Session(reviews, fresh, new_remaining_today)
      Ask(tags, limit, offset, new_after_reviews, new_limit)
      Graded(level_before, level_after, due_ms, review_id)
      Summary(group, count, new_count, active_count, suspended_count,
      due_count, mean_level)
      Outcome: :pass | :partial | :fail | :again | :known
      Status: :new | :active | :suspended
      PracticeError: :unknown_card | :card_suspended | :card_not_started
      | :out_of_order | :not_amendable | :unknown_timezone | :bad_content
      | {:deck_unavailable, reason}

  Times cross as Unix milliseconds, as they do everywhere else on this
  boundary; a card's `content` crosses as JSON text, because Retain stores it
  opaquely and so does everything above here.

  Tags and summary groups are sorted by key before they cross. A map has no
  order, and an unsorted list would make the same deck serialise differently
  between runs -- the same rule the scenes follow.

  Every call that can be refused returns a `Result` rather than raising. Most
  of those refusals are things a player did -- a card that is not theirs, one
  they paused, one not yet in rotation, an answer out of order, a row that is
  not an attempt. Two are ours: a timezone that is not an IANA name and a
  card whose content is not a JSON object. Neither can happen from the pages
  as they stand, but this is the boundary, so they come back as `:unknown_
  timezone` and `:bad_content` instead of a `MatchError` that would surface
  as an unexplained 500. A handler still answers 500 for those two; the
  difference is that it does so on purpose.
  """

  import Oskol.Gleam.Interop

  require Logger

  # Retain reads "today" in the learner's own timezone. Until the client tells
  # us where a player is, every deck is on one clock, and this is the one the
  # site already runs its days on.
  @default_tz "Etc/UTC"

  def build do
    {:practice_caps, &put_user/3, &put_items/2, &cards/2, &relapse/3, &queue/2, &start/2,
     &start_new/2, &review/3, &amend/4, &defer_until/3, &defer_tomorrow/2, &master/2, &suspend/2,
     &resume/2, &summary/2}
  end

  def default_tz, do: @default_tz

  # An empty timezone means "leave whatever this deck has alone". Filling a
  # deck has no opinion about where its owner is, and passing the default
  # would silently move a player who has told us their zone back onto ours.
  # Retain has nothing to create a deck from without one, so a deck that is
  # not there yet is created on the default and a deck that is there keeps
  # what it has.
  defp put_user(uid, "", new_per_day) do
    unavailable(fn ->
      case Retain.put_user(uid, new_per_day: new_per_day) do
        {:ok, _} -> {:ok, nil}
        {:error, %Ecto.Changeset{action: :insert}} -> put_user(uid, @default_tz, new_per_day)
        {:error, %Ecto.Changeset{}} -> {:error, :unknown_timezone}
      end
    end)
  end

  defp put_user(uid, tz, new_per_day) do
    unavailable(fn ->
      case Retain.put_user(uid, tz: tz, new_per_day: new_per_day) do
        {:ok, _} -> {:ok, nil}
        # The only thing a caller can get wrong here.
        {:error, %Ecto.Changeset{}} -> {:error, :unknown_timezone}
      end
    end)
  end

  defp put_items(uid, items) do
    unavailable(fn ->
      with {:ok, rows} <- item_rows(items),
           {:ok, %{inserted: inserted}} <- Retain.put_items(uid, rows) do
        {:ok, inserted}
      else
        # A card's content is stored opaquely, but it has to be a JSON object to be stored at
        # all; anything else is a bug above this line, not a crash below it.
        :error -> {:error, :bad_content}
        {:error, {:invalid_item, _index, _changeset}} -> {:error, :bad_content}
      end
    end)
  end

  # Which of these keys the deck already holds. One query rather than one
  # per key: this is asked of every sync, and a first sync offers a whole
  # game's mistakes at once. It reads Retain's own table, which is the one
  # place allowed to -- this file is the seam the library is swapped behind.
  defp cards(uid, keys) do
    case Retain.fetch_user(uid) do
      {:ok, user} ->
        import Ecto.Query

        Oskol.Repo.all(from(i in Retain.Item, where: i.user_id == ^user.id and i.key in ^keys))
        |> Enum.map(&card/1)

      {:error, :not_found} ->
        []
    end
  rescue
    e ->
      # A deck that cannot be read offers no relapses; the cards still go
      # in, and the next game says the same thing again.
      Logger.error("deck read failed: #{Exception.message(e)}")
      []
  end

  # The player made this mistake again, in a game. A miss like any other,
  # with a note in the log saying where it came from.
  defp relapse(uid, key, meta_json) do
    unavailable(fn ->
      uid |> Retain.review(key, :again, meta: Jason.decode!(meta_json)) |> graded()
    end)
  end

  defp item_rows(items) do
    Enum.reduce_while(items, {:ok, []}, fn {:item, key, tags, content_json, position},
                                           {:ok, rows} ->
      case Jason.decode(content_json) do
        {:ok, content} when is_map(content) ->
          row = %{key: key, tags: Map.new(tags), content: content, position: unopt(position)}
          {:cont, {:ok, [row | rows]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      :error -> :error
    end
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

    case Retain.queue(uid, opts) do
      {:ok, %{reviews: reviews, new: fresh, new_remaining_today: remaining}} ->
        {:session, Enum.map(reviews, &card/1), Enum.map(fresh, &card/1), remaining}

      # No deck at all: an account that has never made a mistake, or one
      # whose first sync has not run yet. Nothing to practice is a session
      # with nothing in it, not a failure -- and asking must not create a
      # row, or every page view would.
      {:error, :not_found} ->
        {:session, [], [], 0}
    end
  end

  defp start(uid, keys) do
    started(Retain.start(uid, keys))
  end

  defp start_new(uid, count) do
    started(Retain.start(uid, count))
  end

  defp started({:ok, %{started: started}}), do: started
  # KEEP GOING pressed by an account whose deck is not there yet.
  defp started({:error, :not_found}), do: 0

  defp review(uid, key, outcome) do
    uid |> Retain.review(key, outcome(outcome)) |> graded()
  end

  defp amend(uid, key, review_id, outcome) do
    uid |> Retain.amend(key, review_id, outcome(outcome)) |> graded()
  end

  defp defer_until(uid, key, until_ms) do
    uid |> Retain.defer(key, DateTime.from_unix!(until_ms, :millisecond)) |> graded()
  end

  # The start of this deck's own tomorrow: the clock and the timezone are
  # both here, and "due today" is already read the same way.
  defp defer_tomorrow(uid, key) do
    case Retain.fetch_user(uid) do
      {:ok, user} ->
        until = Retain.Clock.start_of_tomorrow(DateTime.utc_now(), user.tz)
        uid |> Retain.defer(key, until) |> graded()

      {:error, :not_found} ->
        {:error, :unknown_card}
    end
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

  # The deck is a database, and a database can be away. A sync that let an
  # exception through would leave rows charged for a try with nothing
  # written down about why -- which is how a mistake is lost silently.
  defp unavailable(fun) do
    fun.()
  rescue
    e ->
      Logger.error("DECK UNAVAILABLE: #{Exception.message(e)}")
      {:error, {:deck_unavailable, Exception.message(e)}}
  end

  defp summary(uid, group_by) do
    # A deck that is not there yet has nothing to total up, exactly as it
    # has nothing to queue. Asking must not create one.
    rows =
      case Retain.summary(uid, group_by: group_by) do
        {:ok, rows} -> rows
        {:error, :not_found} -> []
      end

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
  defp graded({:error, :not_started}), do: {:error, :card_not_started}
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
