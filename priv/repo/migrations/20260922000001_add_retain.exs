defmodule Oskol.Repo.Migrations.AddRetain do
  @moduledoc """
  The puzzle deck's tables (`retain_users`, `retain_items`, `retain_reviews`).

  The library owns its own schema and versions it; this migration only says
  which version Oskol is on. Upgrading `retain` later means a new migration
  here at the next version, not an edit to this one.
  """
  use Ecto.Migration

  def up, do: Retain.Migration.up(version: 2)
  def down, do: Retain.Migration.down(version: 0)
end
