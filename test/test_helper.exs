# The suite runs without its slowest tests by default, because a suite you
# wait four minutes for is a suite you stop running. What is tagged `slow`
# is the work that spends real seconds on purpose -- random playouts of
# whole matches through the room, and clocks that have to run out in real
# time -- and it is where the fewest changes land. CI always runs it
# (`mix test --include slow`), and so does `bin/check --all`.
#
# `bin/test-par` divides the machine between its partitions: each one runs a
# share of ExUnit's usual concurrency, so all of them together still use the
# schedulers one plain run would, and the connection pool sized alongside it
# in config/test.exs is wide enough for the cases this BEAM runs at once.
partitions = String.to_integer(System.get_env("MIX_TEST_PARTITIONS") || "1")

ExUnit.start(
  exclude: [:slow],
  max_cases: max(div(System.schedulers_online() * 2, partitions), 2)
)

# Manual sandbox: tests that touch the database (persistence, rehydration)
# check out a shared owner; the rest run without one and the
# write-behind persister quietly skips its writes.
Ecto.Adapters.SQL.Sandbox.mode(Oskol.Repo, :manual)
