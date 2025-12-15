# Oskol - Poker Roguelike for Two Players

## Project Overview
Oskol is a real-time multiplayer poker roguelike game where two players compete in rounds of poker hands. Players can upgrade their poker hand levels through a shop system, adding roguelike progression to traditional poker gameplay.

**Live at:** oskol.io
**Tech Stack:** Elixir, Phoenix, Phoenix LiveView, Tailwind CSS

## Architecture

### Core Components

1. **Game Server** (`lib/oskol/game/game_server.ex`)
   - GenServer managing game state
   - Handles player actions asynchronously
   - Broadcasts state updates via PubSub

2. **Game State** (`lib/oskol/game/game_state.ex`)
   - Pure functional game logic
   - Manages rounds, hands, scoring
   - Emits events for all state changes

3. **Event Log** (`lib/oskol/game/event_log.ex`)
   - Event sourcing system
   - Immutable history of all game events
   - Used for game history, card highlighting, auditing

4. **LiveView** (`lib/oskol_web/live/game_live.ex`)
   - Real-time UI updates
   - Tracks UI state (modals, selections, highlights)
   - Subscribes to PubSub for state updates

### Key Design Patterns

**Event Sourcing**
- All game actions emit events (`:cards_drawn`, `:hand_locked_in`, `:cards_discarded`, etc.)
- Event log is source of truth for "what happened"
- UI features (highlighting, history) consume events
- Enables time-travel debugging and replay

**Async Actions**
- Player actions are async: `player_lock_in_hand_async`, `player_discard_cards_async`
- GenServer validates and applies changes
- PubSub broadcasts to all connected clients
- LiveView updates on `handle_info({:game_state_updated, new_state})`

**Card Highlighting (Event-Based)**
```elixir
# Tracks which events user has acknowledged
acknowledged_event_sequence: 0
last_seen_event_sequence: 0

# Only highlight cards from unacknowledged :cards_drawn events
# Excludes :round_start, only highlights after :after_discard/:after_hand_played
# Clears on user action (lock-in/discard)
```

## File Structure

### Game Logic
- `lib/oskol/game/game_state.ex` - Core game rules
- `lib/oskol/game/player_state.ex` - Player state structure
- `lib/oskol/game/game_server.ex` - Game server (GenServer)
- `lib/oskol/game/event_log.ex` - Event sourcing

### Poker Logic
- `lib/oskol/poker/hand.ex` - Hand evaluation
- `lib/oskol/poker/score.ex` - Scoring with skill tree bonuses
- `lib/oskol/poker/skill_tree.ex` - Player progression
- `lib/oskol/poker.ex` - Facade module

### UI Components
- `lib/oskol_web/live/game_live.ex` - Main LiveView controller
- `lib/oskol_web/components/game_live/gameplay.ex` - Game UI, modals
- `lib/oskol_web/components/game_live/summaries.ex` - Round/match summaries
- `lib/oskol_web/components/game_live/history.ex` - Game history modal
- `lib/oskol_web/components/game_live/lobby.ex` - Pre-game lobby
- `lib/oskol_web/components/game_live/shop.ex` - Shop system

## Game Flow

1. **Lobby** → Players join, configure lives & shop rounds → Start game
2. **Round Start** → Each player draws 8 cards
3. **Playing Hands** → Players select & lock in 1-5 cards (up to 3 hands per round)
   - Can discard cards before locking in
   - New cards highlighted after draw
4. **Hand Comparison** → Scores calculated with skill tree bonuses
5. **Round End** → Loser loses 1 life (or tie = no loss)
6. **Shop** (if configured) → Players buy hand upgrades
7. **Next Round** → Repeat until one player reaches 0 lives
8. **Match End** → Winner declared

## Key Features

### Modals (All use blur backdrop + shadow-xl)
- **Game Log** - Event history with color-coded events
- **Player Decks** - View own/opponent's full deck (discard = low opacity)
- **Player Levels** - Compare skill tree levels side-by-side

### Card Highlighting
- Yellow border on newly drawn cards
- Only after discard/play (NOT on round start)
- Clears when player takes action
- Permanent highlight (no fade) for visibility

### Shop System
- Purchase hand type upgrades
- Level up = increased chips & multiplier
- Configurable rounds (0-5)
- Ready-up system when no shop

### Scoring
```elixir
# Base scores from base_hand_scores
# Level bonuses: base + (level - 1) × upgrade_bonus
# Final score: (chips + card_values) × multiplier
```

## Important Conventions

### Event Flow
```
User Action → LiveView Event → Async Game Action →
GenServer Validation → State Update → Event Emission →
PubSub Broadcast → LiveView handle_info → UI Update
```

### UI State vs Game State
- **UI State** (LiveView assigns): viewing_*, selected_*, new_card_ids
- **Game State** (GenServer): players, phase, round_number, shop_state
- Keep UI concerns in LiveView, not in game logic

### Styling
- Tailwind CSS utility classes
- Consistent colors: blue (player), red (opponent), gray (neutral)
- Modern/sleek aesthetic (no green/yellow backgrounds)
- White/gray/black color scheme

## Recent Changes

### Card Highlighting Fix
- Added `acknowledged_event_sequence` to track user acknowledgment
- Filter out `:round_start` events from highlighting
- Clear highlights on lock-in/discard
- Event-based approach (no state diffing)

### UI Improvements
- Removed "undo hand" functionality (too confusing)
- Added score differential display ("You are up by X points")
- Modernized round summary screens
- Added Player Levels modal
- Changed modals to blur backdrop instead of black overlay

### Shop Integration
- Conditional "Continue to Shop" vs "Continue to Next Round"
- Ready-up system for no-shop rounds
- Shop state properly cleared when 0 shop rounds

## Development Commands

```bash
mix deps.get          # Install dependencies
mix ecto.setup        # Setup database (if needed)
mix phx.server        # Start server (localhost:4000)
mix test              # Run tests
mix compile           # Compile Elixir/Gleam code
mix assets.build      # Compile Elm and build assets
```

## Development Workflow for Claude

**IMPORTANT: Never run background tasks or servers**
- ❌ DO NOT use `run_in_background: true` on mix phx.server or any long-running commands
- ❌ DO NOT start the Phoenix server in the background
- ✅ DO use `mix compile` to verify Elixir/Gleam code compiles
- ✅ DO use `mix assets.build` or `cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null` to verify Elm compiles
- ✅ DO use `timeout 90` on potentially long-running commands to prevent hanging

**Testing code changes:**
1. Make your code changes
2. Run `mix compile` to check Elixir/Gleam compilation
3. Run `cd assets && timeout 90 ../node_modules/.bin/elm make src/Main.elm --output=/dev/null` to check Elm compilation
4. Report compilation results to the user
5. Let the user test manually in their browser

## Common Patterns

### Adding a Modal
1. Add `viewing_modal_name: false` to LiveView assigns
2. Add `handle_event("toggle_modal_name", ...)` handler
3. Create `modal_name_modal(assigns)` component in gameplay.ex
4. Render in game_live.ex template
5. Use `backdrop-blur-sm bg-white/10` for overlay
6. Use `shadow-xl` on modal content

### Adding a Player Action
1. Add async function in game_server.ex
2. Add action handler in game_server_state.ex
3. Add game logic in game_state.ex
4. Emit events for state changes
5. Add LiveView event handler
6. Update UI to call event

## Known Patterns to Avoid

❌ Don't use bash commands for file operations (use Read/Write/Edit tools)
❌ Don't add emojis unless explicitly requested
❌ Don't create files unnecessarily (prefer editing existing)
❌ Don't use undo functionality (removed as confusing)
❌ Don't accumulate state in LiveView (use event log)
❌ Don't put UI logic in game state (separation of concerns)
❌ Don't run background tasks or servers (use compile commands instead - see Development Workflow)

## Testing Notes

- Game state tests in `test/oskol/game/`
- Poker logic tests in `test/oskol/poker/`
- Event log tests verify event sourcing correctness
- LiveView tests for UI interactions

## Future Considerations

- Distributed game servers (currently single-node GenServer)
- Persistent storage (currently in-memory only)
- Spectator mode
- Replay functionality from event log
- More shop items/upgrades
- Sound effects and animations
