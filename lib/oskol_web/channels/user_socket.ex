defmodule OskolWeb.UserSocket do
  use Phoenix.Socket

  # Channels
  channel "game:*", OskolWeb.GameChannel

  @doc """
  `client` names the browser tab behind this socket (the client mints it and
  keeps it for the life of the tab). It authenticates nothing — seats are
  opened by their token and by nothing else — and it is only ever compared
  with itself, to tell one of this tab's own reconnects from another tab
  taking the seat over (`src/oskol/rooms/seat.gleam`). A socket that does
  not offer one falls back to being its own client.
  """
  @impl true
  def connect(params, socket, _connect_info) do
    {:ok, assign(socket, :client, client_id(params["client"]))}
  end

  defp client_id(id) when is_binary(id) and byte_size(id) in 1..100, do: id
  defp client_id(_), do: nil

  @impl true
  def id(_socket), do: nil
end
