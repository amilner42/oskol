defmodule Oskol.Gleam.CtxBuilder do
  @moduledoc """
  Builds the Gleam `Ctx` capability record (src/oskol/core/ctx.gleam) and the
  `Session` a request or a LiveView mount carries.

  Gleam records are tagged tuples. Each domain's caps are built by its own
  module under `Oskol.Gleam.Caps.*`; that module and its Gleam twin in
  src/oskol/caps/<domain>.gleam must agree on tag and field order. This file
  mirrors ctx.gleam's field order.

  Options are passed to the caps that need a process or an injected
  function:

    * `:player_pid` — the process that takes a seat (a LiveView; `nil` for
      a stateless request, which seats a player with no live connection).
    * `:generate` — a game-code generator, for tests.
    * `:review` — the engine call, for an operator task that times it.

  The capability closures run in the process that builds them: `subscribe`
  subscribes that process.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Gleam.Caps

  def build(opts \\ []) do
    {:ctx, Caps.Analysis.build(opts), Caps.Auth.build(), Caps.Copy.build(), Caps.Guests.build(),
     Caps.Ids.build(opts), Caps.Persistence.build(), Caps.Practice.build(), Caps.Puzzles.build(),
     Caps.Records.build(), Caps.Rooms.build(opts)}
  end

  @doc """
  The session a caller carries: the guest id the GuestId plug put there
  (from a conn or from a LiveView mount's session map), and the account that
  guest is signed in as, if any.
  """
  def session(%Plug.Conn{} = conn) do
    build_session(Plug.Conn.get_session(conn, :guest_id))
  end

  def session(%{} = session) do
    build_session(session["guest_id"])
  end

  @doc "A session with no guest id and no account."
  def anonymous_session, do: {:session, :none, :none}

  # The account signed in on this browser is `guests.user_id`: one indexed
  # read per request, and the reason identity has no second mechanism beside
  # the guest cookie.
  defp build_session(nil), do: {:session, :none, :none}

  defp build_session(guest_id) do
    {:session, opt(guest_id), opt(Oskol.Auth.user_id_of_guest(guest_id))}
  end
end
