defmodule Oskol.GameFixtures do
  @moduledoc "Helpers to spin up game rooms in tests."

  alias Oskol.Game

  def unique_game_id(prefix \\ "t") do
    prefix <> "-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc "A Tilt room with two seated players who agreed on a format, not yet started."
  def lobby(format \\ "short") do
    game_id = unique_game_id()
    {:ok, _} = Game.start_game(game_id, "tilt")
    {:ok, p1, _} = Game.join_game(game_id, "Alice", nil)
    {:ok, p2, _} = Game.join_game(game_id, "Bob", nil)
    {:ok, _} = Game.select_format(game_id, p1, format)
    {:ok, _} = Game.select_format(game_id, p2, format)
    %{game_id: game_id, p1: p1, p2: p2}
  end

  @doc "A started Tilt game with a fixed seed."
  def started(seed \\ 42, format \\ "short") do
    fixture = lobby(format)
    {:ok, state} = Oskol.Game.GameServer.start_game(fixture.game_id, seed)
    Map.put(fixture, :state, state)
  end

  @doc "Ids of the first `n` cards in the player's hand, from their legal play_hand schema."
  def hand_cards(instance, player_id, n) do
    update = Oskol.GameKit.player_update(instance, player_id)
    play = Enum.find(update["legal"], &(&1["name"] == "play_hand"))
    play["params"] |> hd() |> Map.get("candidates") |> Enum.take(n)
  end

  def play(game_id, player_id, cards) do
    Game.player_action(game_id, player_id, %{
      "name" => "play_hand",
      "params" => %{"cards" => cards}
    })
  end
end
