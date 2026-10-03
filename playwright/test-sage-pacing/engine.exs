# The engine for Sage's pacing smoke: the analysis smoke's stand-in
# (`Oskol.EngineServer`), answering at once. An engine that answers in no time
# is the case pacing is for -- whatever holds Sage's checkers back is the
# server's pacing, not the think.
#
#   ANALYSIS_STUB_PORT=14501 mix run --no-start -e 'Code.eval_file("playwright/test-sage-pacing/engine.exs")'
#
# Prints one line of JSON once it is listening ({engine: url}) and serves
# until its standard input closes (the smoke that started it ends).

Code.require_file("test_support/complete_engine.ex")
Code.require_file("test_support/engine_server.ex")

{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:jason)

port = String.to_integer(System.get_env("ANALYSIS_STUB_PORT") || "14400")
{:ok, _} = Oskol.EngineServer.start(port, delay_ms: 0)

IO.puts(Jason.encode!(%{engine: "http://localhost:#{port}"}))

IO.read(:stdio, :eof)
