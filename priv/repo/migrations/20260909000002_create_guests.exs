defmodule Oskol.Repo.Migrations.CreateGuests do
  use Ecto.Migration

  def change do
    # Deliberately skeletal: accounts do not exist yet. The table ships
    # empty; it is only here so `guests.user_id` has somewhere to point when
    # a guest claims an account later.
    create table(:users) do
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:guests, primary_key: false) do
      # The opaque crypto-random id minted by OskolWeb.Plugs.GuestId and
      # carried in the long-lived `_oskol_guest` cookie.
      add :id, :string, primary_key: true
      # The last display name this guest played under (last writer wins).
      add :name, :string
      # The future claim path: a guest who signs up keeps their history.
      add :user_id, references(:users, on_delete: :nilify_all)
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end
end
