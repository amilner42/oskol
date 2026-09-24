defmodule Oskol.Gleam.Caps.Activity do
  @moduledoc """
  Real IO for src/oskol/caps/activity.gleam. Keep constructor tags and field
  order in lockstep:

      ActivityCaps(days)

  One reading: which of the last `n` local days this account was active on,
  oldest first and ending today. Two sources unioned -- a puzzle answered
  (`Retain`) and a game of theirs that finished (`game_records`) -- because
  the streak the home prints is the whole of what a player does here.

  Which day a moment falls on is the player's own, in the timezone their
  deck was opened with; a player who has never practised has no deck, and
  is read on the site's default. Nothing here counts the days into a
  streak: that rule is Gleam's (`src/oskol/handlers/home.gleam`).
  """

  import Ecto.Query

  alias Oskol.Repo
  alias Oskol.Reviews

  # The same default `Oskol.Gleam.Caps.Practice` opens a deck on. A day has
  # to start somewhere for a player who has never told us where they are.
  @default_tz "Etc/UTC"

  def build do
    {:activity_caps, &days/2}
  end

  defp days(uid, n) when is_integer(n) and n > 0 do
    tz = timezone(uid)
    today = Retain.Clock.local_date(DateTime.utc_now(), tz)
    first = Date.add(today, -(n - 1))
    # Bounded by a day before the window opens, whatever the zone's offset:
    # both reads walk an index range, never the whole history.
    since = DateTime.add(Retain.Clock.start_of_day(first, tz), -1, :day)

    active = MapSet.union(practised(uid, since, tz), played(uid, since, tz))

    for offset <- 0..(n - 1), do: MapSet.member?(active, Date.add(first, offset))
  end

  defp timezone(uid) do
    case Retain.fetch_user(uid) do
      {:ok, user} -> user.tz
      {:error, :not_found} -> @default_tz
    end
  end

  # The days a puzzle was answered. An attempt counts; putting a card off
  # until tomorrow is not practice, and a correction sits on the day of the
  # answer it corrects -- the same two exclusions `Retain.streak/2` makes
  # and `Oskol.Gleam.Caps.Practice.days/2` draws the strip on, so the
  # streak, the strip and Retain's own number can never disagree.
  defp practised(uid, since, tz) do
    case Retain.fetch_user(uid) do
      {:error, :not_found} ->
        MapSet.new()

      {:ok, user} ->
        from(r in Retain.Review,
          join: i in Retain.Item,
          on: i.id == r.item_id,
          where:
            i.user_id == ^user.id and is_nil(r.supersedes_id) and
              r.outcome != ^:defer and r.at >= ^since,
          distinct: true,
          select: fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", r.at, ^tz)
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end

  defp played(uid, since, tz) do
    uid |> Reviews.finished_days(since, tz) |> MapSet.new()
  end
end
