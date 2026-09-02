defmodule OskolWeb.ChannelCase do
  @moduledoc "Test case for channel tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import OskolWeb.ChannelCase

      @endpoint OskolWeb.Endpoint
    end
  end

  setup _tags do
    :ok
  end
end
