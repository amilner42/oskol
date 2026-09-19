defmodule Oskol.Guests do
  @moduledoc """
  Silent guest identity: every visitor gets an opaque id (minted by
  `OskolWeb.Plugs.GuestId`, carried in a long-lived cookie) and a `guests`
  row the site uses only to conveniently remember them — today that is the
  display name they last played under, prefilled into the create and join
  forms. No signup, nothing visible.

  `guests.user_id` is where this browser becomes an account: `Oskol.Auth`
  owns `users` and writes that column on sign-in, and clears it on logout.

  Guest bookkeeping must never break a page: every write here rescues and
  degrades to "the site just doesn't remember you", the same posture as
  `Oskol.Game.Persister`. The sandbox `OwnershipError` only happens in tests
  that did not check out a connection.
  """

  require Logger

  import Ecto.Query

  alias Oskol.Repo

  defmodule Guest do
    @moduledoc "One visitor: opaque id, last display name, last visit."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "guests" do
      field(:name, :string)
      # Display preferences this browser picked for itself (a board theme,
      # say). Opaque here: which keys are real and which values they take is
      # decided in Gleam (src/oskol/guests/prefs.gleam).
      field(:prefs, :map, default: %{})
      field(:last_seen_at, :utc_datetime_usec)
      # The account signed in on this browser, if any (Oskol.Auth).
      belongs_to(:user, Oskol.Auth.User, type: :binary_id)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  @doc """
  Upsert the guest's row, touching `last_seen_at`, and return their saved
  display name (or nil). Called on every LiveView mount, so it is one cheap
  statement.
  """
  def touch(guest_id) when is_binary(guest_id) do
    now = DateTime.utc_now()

    {:ok, guest} =
      Repo.insert(%Guest{id: guest_id, last_seen_at: now},
        on_conflict: [set: [last_seen_at: now]],
        conflict_target: :id,
        returning: [:name]
      )

    guest.name
  rescue
    e -> swallow(e, :touch)
  end

  def touch(_), do: nil

  @doc "Remember the name this guest played under. Last writer wins."
  def save_name(guest_id, name) when is_binary(guest_id) and is_binary(name) do
    now = DateTime.utc_now()

    {:ok, _} =
      Repo.insert(%Guest{id: guest_id, name: name, last_seen_at: now},
        on_conflict: [set: [name: name, last_seen_at: now]],
        conflict_target: :id
      )

    :ok
  rescue
    e -> swallow(e, :save_name)
  end

  def save_name(_, _), do: :ok

  @doc """
  This guest's display preferences, as a list of `{key, value}` string
  pairs — the shape the Gleam side speaks. A guest with no row, a missing
  column value or a non-string entry simply has no preference.
  """
  def prefs(guest_id) when is_binary(guest_id) do
    Repo.one(from(g in Guest, where: g.id == ^guest_id, select: g.prefs))
    |> case do
      %{} = prefs ->
        for {key, value} <- prefs, is_binary(key) and is_binary(value), do: {key, value}

      _ ->
        []
    end
  rescue
    e ->
      swallow(e, :prefs)
      []
  end

  def prefs(_), do: []

  @doc """
  Remember one preference for this guest, merging it into whatever else
  they have. Last writer wins, per key.
  """
  def save_pref(guest_id, key, value)
      when is_binary(guest_id) and is_binary(key) and is_binary(value) do
    now = DateTime.utc_now()
    patch = %{key => value}

    {:ok, _} =
      Repo.insert(%Guest{id: guest_id, prefs: patch, last_seen_at: now},
        on_conflict:
          from(g in Guest,
            update: [
              set: [
                prefs: fragment("coalesce(?, '{}'::jsonb) || ?", g.prefs, type(^patch, :map)),
                last_seen_at: ^now
              ]
            ]
          ),
        conflict_target: :id
      )

    :ok
  rescue
    e ->
      swallow(e, :save_pref)
      :ok
  end

  def save_pref(_, _, _), do: :ok

  defp swallow(%DBConnection.OwnershipError{} = e, op) do
    # Only the test sandbox raises this. Not a production condition.
    Logger.debug("guest persistence skipped (#{op}): #{Exception.message(e)}")
    nil
  end

  defp swallow(e, op) do
    Logger.error("GUEST PERSISTENCE FAILED (#{op}): #{Exception.message(e)}")
    nil
  end
end
