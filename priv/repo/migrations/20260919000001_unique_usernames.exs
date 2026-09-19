defmodule Oskol.Repo.Migrations.UniqueUsernames do
  use Ecto.Migration

  # An account shows up by its username, never its email (the email is the
  # credential, and the home bar is on screen for anyone looking). A
  # username is picked when the account is made -- the name the browser
  # played under as a guest, with a number if it is taken -- and may be
  # changed after. Unique regardless of case: "Arie" and "arie" are one name.
  def up do
    execute("ALTER TABLE users ALTER COLUMN name TYPE citext")
    create(unique_index(:users, [:name]))
  end

  def down do
    drop(unique_index(:users, [:name]))
    execute("ALTER TABLE users ALTER COLUMN name TYPE varchar(255)")
  end
end
