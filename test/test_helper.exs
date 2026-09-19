# The suite runs without its slowest tests by default, because a suite you
# wait four minutes for is a suite you stop running. What is tagged `slow`
# is the work that spends real seconds on purpose -- random playouts of
# whole matches through the room, and clocks that have to run out in real
# time -- and it is where the fewest changes land. CI always runs it
# (`mix test --include slow`), and so does `bin/check --all`.
ExUnit.start(exclude: [:slow])

# Manual sandbox: tests that touch the database (persistence, rehydration)
# check out a shared owner; the rest run without one and the
# write-behind persister quietly skips its writes.
Ecto.Adapters.SQL.Sandbox.mode(Oskol.Repo, :manual)
