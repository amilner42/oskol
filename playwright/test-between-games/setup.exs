# A room of unlimited play against Sage, between its first and second games,
# left in the database for the browser to pick up.
#
# Sage answers a resignation by the board (`backgammon/bot.answer_resign`),
# and at the opening the board says a backgammon, so it declines a single --
# which is all unlimited play's centred cube lets anyone offer. Nor can a
# smoke play a game against it to the end: no smoke has an engine. So the
# first game is ended here, with both seats played by this script (the
# resignation and its acceptance), and only then is the second seat made
# Sage's, in the row the web server rebuilds the room from. Opened, the room
# is between games with Sage ready, as it is the moment a real game ends.
#
#   mix run -e 'Code.eval_file("playwright/test-between-games/setup.exs")'
#
# Prints one line of JSON: the rooms, each with its id and the guest
# holding the person's seat.

# The last line of this script's output is its result, read by the smoke
# that ran it.
Logger.configure(level: :warning)

import Ecto.Query
alias Oskol.Game

# One room per screen the smoke checks: NEXT moves a room on.
count = String.to_integer(System.get_env("BETWEEN_ROOMS") || "6")

rooms =
  for _ <- 1..count do
    game_id = "betw-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    {:ok, _} = Game.start_game(game_id, "backgammon")
    {:ok, _} = Game.configure(game_id, %{format: "unlimited", clock: "none"})
    me = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    stand_in = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    {:ok, p1, _} = Game.join_game(game_id, "Guest", nil, me)
    {:ok, p2, _} = Game.join_game(game_id, "Sage", nil, stand_in)

    {:ok, _, _} =
      Game.player_action(game_id, p1, %{"name" => "resign", "params" => %{"stakes" => "single"}})

    {:ok, _, _} = Game.player_action(game_id, p2, %{"name" => "accept_resign", "params" => %{}})

    # Everything written, and the room gone from this node, before the seat
    # changes hands: nothing here may write the players back over it.
    :ok = Oskol.Game.Persister.flush()
    [{room, _}] = Registry.lookup(Oskol.GameRegistry, game_id)
    ref = Process.monitor(room)
    Process.exit(room, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    players =
      Oskol.Repo.one!(
        from(g in Oskol.Persistence.Game, where: g.id == ^game_id, select: g.players)
      )
      |> Enum.map(fn
        %{"id" => ^p2} = seat -> Map.merge(seat, %{"bot" => true, "guest_id" => nil})
        seat -> seat
      end)

    {1, _} =
      Oskol.Repo.update_all(from(g in Oskol.Persistence.Game, where: g.id == ^game_id),
        set: [players: players]
      )

    %{game_id: game_id, guest: me, sage: p2}
  end

IO.puts(Jason.encode!(%{rooms: rooms}))
