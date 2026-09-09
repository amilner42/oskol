defmodule Oskol.Guests do
  @moduledoc """
  Silent guest identity: every visitor gets an opaque id (minted by
  `OskolWeb.Plugs.GuestId`, carried in a long-lived cookie) and a `guests`
  row the site uses only to conveniently remember them — today that is the
  display name they last played under, prefilled into the create and join
  forms. No signup, nothing visible.

  `users` is a deliberate skeleton (it ships empty): `guests.user_id` is the
  future claim path for a guest who eventually creates an account.

  Guest bookkeeping must never break a page: every write here rescues and
  degrades to "the site just doesn't remember you", the same posture as
  `Oskol.Game.Persister`. The sandbox `OwnershipError` only happens in tests
  that did not check out a connection.
  """

  require Logger

  alias Oskol.Repo

  defmodule User do
    @moduledoc "Placeholder for future accounts. Ships empty."
    use Ecto.Schema

    schema "users" do
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  defmodule Guest do
    @moduledoc "One visitor: opaque id, last display name, last visit."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "guests" do
      field(:name, :string)
      field(:last_seen_at, :utc_datetime_usec)
      belongs_to(:user, Oskol.Guests.User)

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
