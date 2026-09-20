defmodule Oskol.Auth.SourceKeyTest do
  use ExUnit.Case, async: true

  alias Oskol.Auth.SourceKey

  test "a boot-secret source key is stable per source and distinct across sources" do
    first = SourceKey.key("203.0.113.10")

    assert first == SourceKey.key("203.0.113.10")
    refute first == SourceKey.key("203.0.113.11")
    refute first =~ "203.0.113.10"
  end
end
