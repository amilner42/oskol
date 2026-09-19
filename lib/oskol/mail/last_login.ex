defmodule Oskol.Mail.LastLogin do
  @moduledoc """
  The last sign-in this node put in the mail, kept in memory for the
  development endpoint `GET /dev/last-login` — which is how a browser test
  reads a link without a mailbox.

  It holds one mail, and it holds it nowhere but here: the agent is only
  started in dev and test, and the endpoint that reads it is a dev-only
  route. In production nothing starts it and `put/1` is a no-op, so a live
  token is never held anywhere but its own hashed row.
  """
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "Remember this sign-in, if anyone is keeping them."
  def put(mail) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> mail end)
    :ok
  end

  @doc "The last sign-in, or nil."
  def get do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1)
  end
end
