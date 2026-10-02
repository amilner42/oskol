# The analysis engine for the analysis board's smoke (part 2): a stand-in
# that answers every request as `Oskol.CompleteEngine` does, on the port the
# dev server's `ANALYSIS_URL` names, in this VM of its own -- the server's
# VM never compiles `test_support/`. No network: every legal play of a roll
# is worked out with the same Gleam the puzzle page's tree comes from, the
# opening 3-1's 8/5 6/5 ranked first, and each answer held 1.5 s so the
# page shows its waiting plate.
#
#   ANALYSIS_STUB_PORT=14484 mix run --no-start -e 'Code.eval_file("playwright/test-analysis/setup.exs")'
#
# Prints one line of JSON once it is listening ({engine: url}) and serves
# until its standard input closes (the smoke that started it ends).

Code.require_file("test_support/complete_engine.ex")
Code.require_file("test_support/engine_server.ex")

{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:jason)

port = String.to_integer(System.get_env("ANALYSIS_STUB_PORT") || "14484")
{:ok, _} = Oskol.EngineServer.start(port, prefer: ["8/5 6/5"], delay_ms: 1500)

IO.puts(Jason.encode!(%{engine: "http://localhost:#{port}"}))

# Serve until the smoke closes our input (or is gone).
IO.read(:stdio, :eof)
