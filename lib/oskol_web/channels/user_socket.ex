defmodule OskolWeb.UserSocket do
  use Phoenix.Socket

  # Channels
  channel "game:*", OskolWeb.GameChannel

  @doc """
  Two things come off the socket, and only one of them is a credential.

  `guest_id` is the credential: the opaque id of the visitor's guest cookie,
  read out of the session that the websocket's own upgrade request carried
  (`connect_info: [session: ...]` in the endpoint). A page script cannot
  read that cookie — it is HttpOnly — so the client never sends it and
  cannot be tricked into leaking it. Phoenix hands the session over only
  when the socket's `_csrf_token` param matches it, which is what stops
  another origin from opening a socket as the visitor and sitting down at
  their table.

  `client` names the browser tab behind this socket (the client mints it and
  keeps it for the life of the tab). It authenticates nothing, and it is
  only ever compared with itself, to tell one of this tab's own reconnects
  from another tab taking the seat over (`src/oskol/rooms/seat.gleam`). A
  socket that does not offer one falls back to being its own client.
  """
  @impl true
  def connect(params, socket, connect_info) do
    {:ok,
     socket
     |> assign(:client, client_id(params["client"]))
     |> assign(:guest_id, guest_id(connect_info))}
  end

  defp client_id(id) when is_binary(id) and byte_size(id) in 1..100, do: id
  defp client_id(_), do: nil

  # No session (no cookie, a stale CSRF token, a connection from somewhere
  # that has neither) is simply a visitor who holds no seat anywhere.
  defp guest_id(%{session: %{"guest_id" => id}}) when is_binary(id), do: id
  defp guest_id(_), do: nil

  @impl true
  def id(_socket), do: nil
end
