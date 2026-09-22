defmodule Oskol.Repo.Migrations.ShareOncePerSharer do
  use Ecto.Migration

  @moduledoc """
  One story link per (decision, sharer). `Oskol.Puzzles.mint_share/5`
  inserts `on_conflict: :nothing` against this index and reads back the
  token that stands, so two requests minting together get one link and
  no read-then-act gap can make two.
  """

  def change do
    create(unique_index(:puzzle_shares, [:source_id, :shared_by]))
  end
end
