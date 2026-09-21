defmodule Oskol.SentryUpgradeTest do
  use ExUnit.Case, async: true

  test "Sentry 12 starts its Finch transport and keeps Oskol's integrations" do
    assert Sentry.Config.client() == Sentry.FinchClient
    assert Process.whereis(Sentry.FinchClient) |> is_pid()

    assert Code.ensure_loaded?(Sentry.LoggerHandler)
    assert Code.ensure_loaded?(Sentry.PlugCapture)
    assert Code.ensure_loaded?(Sentry.PlugContext)
    assert Code.ensure_loaded?(Sentry.LiveViewHook)
  end
end
