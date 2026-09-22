defmodule Oskol.Repo.Migrations.AddRetainV02 do
  @moduledoc """
  The puzzle deck's tables (`retain_users`, `retain_items`, `retain_reviews`).

  The library owns its own schema and versions it; this migration only says
  which version Oskol is on, and is named for it. Upgrading `retain` later
  means a new migration beside this one (`..._add_retain_v03.exs`, from
  `mix retain.gen.migration`), never an edit to this one.
  """
  use Ecto.Migration

  def up, do: Retain.Migration.up(version: 2)
  def down, do: Retain.Migration.down(version: 0)
end
