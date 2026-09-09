ExUnit.start()

# Manual sandbox: tests that touch the database (persistence, rehydration,
# pruning) check out a shared owner; the rest run without one and the
# write-behind persister quietly skips its writes.
Ecto.Adapters.SQL.Sandbox.mode(Oskol.Repo, :manual)
