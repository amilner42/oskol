defmodule Oskol.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Accounts by email and nothing else (the `accounts-email-codes` ticket).

  `users` has shipped empty since the very first migration and `guests.user_id`
  has always been null, so the placeholder is replaced outright rather than
  grown: a uuid key (an account id is the one identity that may one day be
  looked at from outside a row) and the email that is the whole credential.

  Nothing is backfilled. Every seat starts unowned; the first sign-in on a
  browser stamps the seats that browser's guest holds.
  """

  def up do
    # Email is case-insensitive as people type it, not as they remember
    # typing it. The handler lowercases too, so this is belt and braces.
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    # Empty table, always-null column: the reference goes, the table goes,
    # and both come back with the shape accounts need.
    alter table(:guests) do
      remove(:user_id)
    end

    drop(table(:users))

    create table(:users, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:email, :citext, null: false)
      # Set later, from the home board. Null until then: the email is the name.
      add(:name, :string)
      add(:last_login_at, :utc_datetime_usec)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:users, [:email]))

    alter table(:guests) do
      # Who is signed in on this browser right now. Logging out nilifies it;
      # the seats it stamped stay the account's.
      add(:user_id, references(:users, type: :uuid, on_delete: :nilify_all))
    end

    # Read once per request (CtxBuilder) and once per socket connect.
    create(index(:guests, [:user_id]))

    # One sign-in in flight: a link and a six-digit code, both hashed, both
    # good for fifteen minutes, both single use.
    create table(:login_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:email, :citext, null: false)
      add(:token_hash, :binary, null: false)
      add(:code_hash, :binary, null: false)
      # The browser that asked. Kept for the rate counter's sake and for
      # nothing else: the browser that *opens* the link is the one signed in.
      add(:guest_id, :string)
      # Where the player was when they asked, so the landing page can send
      # them back. A local path or nothing; never a URL.
      add(:next, :string)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:login_tokens, [:email]))
    create(unique_index(:login_tokens, [:token_hash]))
  end

  def down do
    drop(table(:login_tokens))

    drop(index(:guests, [:user_id]))

    alter table(:guests) do
      remove(:user_id)
    end

    drop(table(:users))

    create table(:users) do
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    alter table(:guests) do
      add(:user_id, references(:users, on_delete: :nilify_all))
    end
  end
end
