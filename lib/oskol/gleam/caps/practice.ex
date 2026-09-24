defmodule Oskol.Gleam.Caps.Practice do
  @moduledoc """
  Real IO for src/oskol/caps/practice.gleam, over the `retain` library. Keep
  constructor tags and field order in lockstep:

      PracticeCaps(put_user, put_items, cards, relapse, queue, start,
      start_new, review, amend, defer_until, defer_tomorrow, master,
      suspend, resume, summary, ladder, days, day, severity)
      Day(answered, new_remaining)
      Severity(grade, total, in_progress, patched)
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

  import Ecto.Query
  import Oskol.Gleam.Interop

  require Logger

  # Retain reads "today" in the learner's own timezone. Until the client tells
  # us where a player is, every deck is on one clock, and this is the one the
  # site already runs its days on.
  @default_tz "Etc/UTC"

  def build do
    {:practice_caps, &put_user/3, &put_items/2, &cards/2, &relapse/3, &queue/2, &start/2,
     &start_new/2, &review/3, &amend/4, &defer_until/3, &defer_tomorrow/2, &master/2, &suspend/2,
     &resume/2, &summary/2, &ladder/1, &days/2, &day/1, &severity/2}
  end

  # ---------- The two pictures the home draws ----------
  #
  # Retain answers "how is this deck doing" as one row of totals and as a
  # series of readings over time; neither is "how many cards sit on each
  # rung" or "which days did this person practise". Both are one grouped
  # count over rows Retain owns, so they are read here rather than folded
  # out of something that was not meant to answer them. `Retain.Item` and
  # `Retain.Review` are the library's public schemas and we own the library
  # (amilner42/retain); when it grows these two readings, these go.

  # Cards per level, lowest first: every card in the deck, whatever its
  # status, so the bars add up to the deck size printed beside them.
  defp ladder(uid) do
    levels = length(Retain.Config.intervals())

    counts =
      case Retain.fetch_user(uid) do
        {:error, :not_found} ->
          %{}

        {:ok, user} ->
          from(i in Retain.Item,
            where: i.user_id == ^user.id,
            group_by: i.level,
            select: {i.level, count(i.id)}
          )
          |> Oskol.Repo.all()
          |> Map.new()
      end

    for level <- 0..(levels - 1), do: Map.get(counts, level, 0)
  end

  # Which of the last `n` local days this deck was practised on, oldest
  # first and ending today. An attempt counts; putting a card off until
  # tomorrow is not practice, and a correction sits on the day of the
  # answer it corrects -- the same two exclusions `Retain.streak/2` makes,
  # so the strip and a streak can never disagree.
  defp days(uid, n) when is_integer(n) and n > 0 do
    case Retain.fetch_user(uid) do
      {:error, :not_found} ->
        List.duplicate(false, n)

      {:ok, user} ->
        today = Retain.Clock.local_date(DateTime.utc_now(), user.tz)
        first = Date.add(today, -(n - 1))
        # Bounded by a day before the window opens, whatever the zone's
        # offset: the strip reads an index range, not every row this deck
        # has ever written.
        since = DateTime.add(Retain.Clock.start_of_day(first, user.tz), -1, :day)

        practised =
          from(r in Retain.Review,
            join: i in Retain.Item,
            on: i.id == r.item_id,
            where:
              i.user_id == ^user.id and is_nil(r.supersedes_id) and
                r.outcome != ^:defer and r.at >= ^since,
            distinct: true,
            select: fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", r.at, ^user.tz)
          )
          |> Oskol.Repo.all()
          |> MapSet.new()

        for offset <- 0..(n - 1), do: MapSet.member?(practised, Date.add(first, offset))
    end
  end

  # Where this deck's day stands: what it has answered, and how much of
  # today's new-card budget is left.
  #
  # `answered` makes the same two exclusions `days/2` makes -- a card put
  # off is not practice, and a correction sits on the day of the answer it
  # corrects, which is already counted -- so the ring is the strip's last
  # square counted rather than lit, and neither can say the other is
  # wrong. Both readings are bounded by the start of the player's own day.
  #
  # `new_remaining` is retain's own budget arithmetic (`new_per_day` minus
  # whatever was started today, by any path), done here because the
  # library only hands it back from a queue, and a page that merely draws
  # a ring must not run one.
  defp day(uid) do
    case Retain.fetch_user(uid) do
      # No deck: nothing answered and nothing to answer. What the budget
      # would be is the caller's rule, not this layer's, and an account
      # with no deck has no mistakes waiting either way.
      {:error, :not_found} ->
        {:day, 0, 0}

      {:ok, user} ->
        today = Retain.Clock.local_date(DateTime.utc_now(), user.tz)
        since = Retain.Clock.start_of_day(today, user.tz)
        until = Retain.Clock.start_of_day(Date.add(today, 1), user.tz)

        answered =
          from(r in Retain.Review,
            join: i in Retain.Item,
            on: i.id == r.item_id,
            where:
              i.user_id == ^user.id and is_nil(r.supersedes_id) and
                r.outcome != ^:defer and r.at >= ^since,
            select: count(r.id)
          )
          |> Oskol.Repo.one()
          |> Kernel.||(0)

        started =
          from(i in Retain.Item,
            where: i.user_id == ^user.id and i.started_at >= ^since and i.started_at < ^until,
            select: count(i.id)
          )
          |> Oskol.Repo.one()
          |> Kernel.||(0)

        {:day, answered, max(user.new_per_day - started, 0)}
    end
  end

  # The deck counted by how bad the mistake was: how many of each band the
  # player has patched, and how many they are working on.
  #
  # A card is one puzzle, and a puzzle can have been reached in several
  # games: the worst of those rows is the band the card counts in, which
  # is what the ranking in the fragment is for. The band names are the
  # grades `puzzle_sources` already stores, and `src/oskol/practice/deck`
  # holds the same three: they must agree.
  #
  # In progress is Retain's own "started, and not there yet": an item is
  # `:new` until `started_at` is set (Retain.Item.status/1), so the three
  # states are untouched, started-and-below-the-rung, and at-or-above it.
  # They do not overlap, and they add up to the band's total.
  #
  # `patched_level` is the caller's rule and is never decided here.
  defp severity(uid, patched_level) when is_integer(patched_level) do
    case Retain.fetch_user(uid) do
      {:error, :not_found} ->
        []

      {:ok, user} ->
        worst =
          from(i in Retain.Item,
            join: s in Oskol.Puzzles.Source,
            on: s.puzzle_id == i.key,
            where: i.user_id == ^user.id,
            group_by: [i.id, i.level, i.started_at],
            select: %{
              level: i.level,
              started: fragment("case when ? is null then 0 else 1 end", i.started_at),
              rank:
                max(
                  fragment(
                    "case ? when 'very_bad' then 3 when 'bad' then 2 when 'doubtful' then 1 else 0 end",
                    s.grade
                  )
                )
            }
          )

        from(w in subquery(worst),
          group_by: w.rank,
          select: {
            w.rank,
            count(w.rank),
            sum(
              fragment(
                "case when ? = 1 and ? < ? then 1 else 0 end",
                w.started,
                w.level,
                ^patched_level
              )
            ),
            sum(fragment("case when ? >= ? then 1 else 0 end", w.level, ^patched_level))
          }
        )
        |> Oskol.Repo.all()
        |> Enum.flat_map(fn {rank, total, in_progress, patched} ->
          case band(rank) do
            nil -> []
            name -> [{:severity, name, total, in_progress || 0, patched || 0}]
          end
        end)
    end
  end

  defp band(3), do: "very_bad"
  defp band(2), do: "bad"
  defp band(1), do: "doubtful"
  defp band(_), do: nil

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
        # Retain's default is every card due by the learner's next midnight.
        # A practice page can only offer cards due *now*: the puzzle handler
        # quite correctly will not record an early answer. Keep this cutoff
        # aligned with the handler's `due_ms <= now_ms` decision.
        before: DateTime.utc_now(),
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
    # The headline has to count the same cards `queue/2` can return. A
    # "due today" count beside an immediate-only queue invites a player to
    # expect cards that cannot yet be reviewed.
    rows =
      case Retain.summary(uid, group_by: group_by, before: DateTime.utc_now()) do
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
