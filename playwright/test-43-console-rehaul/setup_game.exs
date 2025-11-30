# Script to programmatically set up a game for testing
game_id = "playwright-test-game"

# Start the game server
{:ok, _pid} = Oskol.Game.find_or_start_game(game_id)

# Add two players
{:ok, p1_id, _state} = Oskol.Game.join_game(game_id, "TestPlayer1", self())
{:ok, p2_id, _state} = Oskol.Game.join_game(game_id, "TestPlayer2", self())

# Set format for both players (3 lives, 0 shop rounds)
Oskol.Game.set_format_async(game_id, p1_id, %{lives: 3, shop_rounds: 0})
Oskol.Game.set_format_async(game_id, p2_id, %{lives: 3, shop_rounds: 0})

# Wait a bit for the async actions
Process.sleep(100)

# Start the game
Oskol.Game.start_game_async(game_id, p1_id)

# Wait for game to start
Process.sleep(500)

IO.puts("Game #{game_id} is ready for testing!")
IO.puts("Navigate to: http://localhost:4001/game/#{game_id}?name=TestPlayer1")
