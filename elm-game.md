# Oskol Elm Migration Plan

## Overview
Migrate the core game experience to Elm while keeping the landing page and lobby in LiveView for SEO and fast initial load.

## Architecture Split

### LiveView (Keep)
- **Landing Page** (`/`) - Marketing, SEO-friendly
- **Lobby** (`/:id` when `game_state.phase == :lobby`) - Player join, name entry, game config
- **Transition** - When game starts, redirect to `/elm/game/:id`

### Elm (New)
- **Full Game** (`/elm/game/:id`) - All gameplay, shop, summaries, history
- **Phases**: Playing hands, round summaries, shop, match end

## Why This Split?

**LiveView for Lobby:**
- Fast server-side rendering
- Simple forms (player name, lives, shop rounds)
- SEO for shared game links
- No lag concerns (not interactive gameplay)

**Elm for Game:**
- Zero-lag card selection/interactions
- Complex client state (selected cards, modals, highlights)
- Type-safe game logic
- Server is still source of truth (GenServer)

---

## Elm Application Architecture

### Core Types

```elm
-- Game State (mirrors Elixir GameState)
type alias GameState =
    { phase : GamePhase
    , players : Players
    , roundNumber : Int
    , eventLog : List GameEvent
    , shopState : Maybe ShopState
    }

type GamePhase
    = PlayingHands
    | RoundSummary RoundResult
    | Shopping
    | MatchEnd Winner

type alias Players =
    { player1 : PlayerState
    , player2 : PlayerState
    }

type alias PlayerState =
    { name : String
    , lives : Int
    , currentHand : List Card
    , discardedCards : List Card
    , lockedInHands : List (List Card)
    , skillTree : SkillTree
    , score : Int
    }

-- UI State (client-only)
type alias Model =
    { gameId : String
    , gameState : RemoteData String GameState
    , viewingModal : Maybe Modal
    , selectedCards : Set Int  -- Card indices
    , newCardIds : Set Int     -- For highlighting
    , acknowledgedEventSeq : Int
    }

type RemoteData error data
    = NotAsked
    | Loading
    | Success data
    | Failure error

type Modal
    = GameLog
    | PlayerDeck Player
    | PlayerLevels
    | ShopPick
```

### Communication Pattern

```
User Action (click card)
  ↓
Elm Update (instant UI feedback - add to selectedCards)
  ↓
Send to Channel (when ready: lock_in_hand, discard_cards)
  ↓
GameServer validates & updates state
  ↓
Broadcast via PubSub
  ↓
Elm receives game_state_updated
  ↓
Update gameState, clear selectedCards, update highlights
```

---

## Implementation Plan

### Phase 1: Setup & Basic Rendering (Week 1)

**Goal**: Render game state from server, no interactions yet

#### Step 1.1: Types & Decoders (2-3 hours)
- [ ] Create `Types.elm` - All game types
- [ ] Create `Decoders.elm` - JSON decoders for GameState
- [ ] Create `Encoders.elm` - JSON encoders for actions
- [ ] Test with mock data

**Files**:
```
assets/src/
  Main.elm              -- Entry point
  Types.elm             -- All type definitions
  Decoders.elm          -- JSON decoders
  Encoders.elm          -- JSON encoders
  View/
    Game.elm            -- Main game view
    Cards.elm           -- Card rendering
    PlayerInfo.elm      -- Player stats
    Modals.elm          -- All modals
```

#### Step 1.2: Channel Integration (2 hours)
- [ ] Update `app.js` to connect to `game:${gameId}` channel
- [ ] Join channel on mount, send initial state to Elm
- [ ] Subscribe to `game_state_updated` messages
- [ ] Handle reconnection logic

#### Step 1.3: Basic Game View (3-4 hours)
- [ ] Render both players' hands (cards as simple divs)
- [ ] Show lives, score, round number
- [ ] Display phase (playing/summary/shop/end)
- [ ] Copy Tailwind classes from LiveView (no animations)

**Key CSS Classes to Reuse**:
```elm
-- Card: "bg-white rounded-lg shadow-md p-4 border-2"
-- Player section: "bg-gray-800 rounded-lg p-6"
-- Button: "bg-blue-500 hover:bg-blue-600 text-white font-bold py-2 px-4 rounded"
```

### Phase 2: Core Interactions (Week 1-2)

#### Step 2.1: Card Selection (2-3 hours)
- [ ] Click card → add to `selectedCards`
- [ ] Visual feedback (border highlight)
- [ ] Deselect on click again
- [ ] Limit to 5 cards selected

#### Step 2.2: Lock In Hand (2 hours)
- [ ] Button enabled when 1-5 cards selected
- [ ] Send `lock_in_hand` with card indices
- [ ] Optimistic update OR wait for server
- [ ] Clear selection on success

#### Step 2.3: Discard Cards (2 hours)
- [ ] Select cards to discard
- [ ] Send `discard_cards` action
- [ ] Wait for server response with new cards
- [ ] Highlight new cards (yellow border)

#### Step 2.4: Card Highlighting (1-2 hours)
- [ ] Track `acknowledgedEventSeq`
- [ ] Filter `:cards_drawn` events after `:after_discard` / `:after_hand_played`
- [ ] Yellow border for `newCardIds`
- [ ] Clear on lock-in/discard

### Phase 3: Modals & Secondary Views (Week 2)

#### Step 3.1: Modals (3-4 hours)
- [ ] Game Log modal (event history with colors)
- [ ] Player Deck modal (all cards, discard opacity)
- [ ] Player Levels modal (skill tree comparison)
- [ ] Blur backdrop + ESC to close

#### Step 3.2: Round Summary (2 hours)
- [ ] Show both hands played
- [ ] Winner/loser/tie display
- [ ] Score differential
- [ ] "Continue" button → server advances phase

#### Step 3.3: Shop (3-4 hours)
- [ ] Display 3 shop picks (hand upgrades)
- [ ] Show current level + upgrade bonus
- [ ] Click to purchase
- [ ] "Ready" button when done
- [ ] Both players ready → advance

#### Step 3.4: Match End (1 hour)
- [ ] Winner display
- [ ] Final stats
- [ ] "Play Again" button

### Phase 4: Polish & Edge Cases (Week 2-3)

#### Step 4.1: Error Handling
- [ ] RemoteData.Failure for channel errors
- [ ] Reconnection UI (spinner/toast)
- [ ] Validation errors (can't lock in, etc.)
- [ ] Timeout handling

#### Step 4.2: Game History
- [ ] Previous rounds display
- [ ] Hands played history
- [ ] Score progression

#### Step 4.3: Testing
- [ ] Two-player flow (open 2 tabs)
- [ ] Mid-game reconnect
- [ ] Network failure scenarios
- [ ] All game phases (lobby → playing → shop → end)

---

## File Structure

```
lib/oskol_web/
  router.ex                          -- Add /elm/game/:id route
  controllers/
    page_controller.ex               -- elm_game action
  controllers/page_html/
    elm_game.html.heex               -- Elm mount point

assets/
  src/
    Main.elm                         -- Entry point, ports, init
    Types.elm                        -- All type aliases
    Decoders.elm                     -- JSON → Elm
    Encoders.elm                     -- Elm → JSON
    Update.elm                       -- Update logic
    Subscriptions.elm                -- Channel subscriptions
    View/
      Game.elm                       -- Main game layout
      PlayingHands.elm               -- Card selection UI
      RoundSummary.elm               -- Round result screen
      Shop.elm                       -- Shop interface
      MatchEnd.elm                   -- Winner screen
      Cards.elm                      -- Card rendering
      PlayerInfo.elm                 -- Player stats bar
      Modals.elm                     -- All modal views
    Utils/
      RemoteData.elm                 -- RemoteData type helpers
      CardHelpers.elm                -- Card utilities
  js/
    app.js                           -- Channel setup for Elm game
```

---

## Key Decisions & Patterns

### 1. RemoteData for All Server State

```elm
type alias Model =
    { gameState : RemoteData String GameState  -- Always wrapped
    , pendingAction : RemoteData String ()     -- Track in-flight requests
    }

-- View handles all states
view : Model -> Html Msg
view model =
    case model.gameState of
        NotAsked -> text "Initializing..."
        Loading -> spinner
        Failure err -> errorView err
        Success gameState -> gameView gameState
```

### 2. Optimistic Updates vs Wait-for-Server

**Optimistic** (instant feedback):
- Card selection (local only)
- Modal open/close

**Wait-for-Server** (source of truth):
- Lock in hand
- Discard cards
- Shop purchase

**Hybrid** (optimistic + rollback):
- Could do optimistic lock-in, rollback on error
- Start simple: wait for server

### 3. Event Log for Highlights

```elm
-- Only highlight cards from recent :cards_drawn events
getNewCardIds : GameState -> Int -> Set Int
getNewCardIds gameState acknowledgedSeq =
    gameState.eventLog
        |> List.filter (isCardsDrawnAfterAction acknowledgedSeq)
        |> List.concatMap getCardIdsFromEvent
        |> Set.fromList
```

### 4. No Animations (v1)

Skip for now:
- Card flip animations
- Score count-up
- Lock-in glow effect
- Fade transitions

Use:
- Instant state changes
- CSS transitions (hover, etc.)
- Focus on correctness first

---

## Migration Strategy

### Parallel Development

1. **Keep LiveView working** - Don't break existing game
2. **Build Elm alongside** - `/elm/game/:id` as new route
3. **Test both** - Compare behavior side-by-side
4. **Feature flag** - ENV var to switch between versions
5. **Gradual rollout** - Start with new games only

### Testing Checklist

- [ ] Two players can join and play a full game
- [ ] Card selection feels instant (< 10ms)
- [ ] Server state syncs correctly across tabs
- [ ] Highlights appear after discard/play
- [ ] Shop purchases work
- [ ] Match ends correctly
- [ ] Reconnect mid-game works
- [ ] No console errors
- [ ] All modals open/close properly

---

## Expected Wins

✅ **Zero-lag interactions** - Card selection, modal toggles instant
✅ **Type safety** - Impossible states impossible
✅ **Better testing** - Pure functions, no mocking needed
✅ **Clearer state management** - RemoteData makes loading/error explicit
✅ **Easier debugging** - Elm debugger, time-travel

## Expected Challenges

⚠️ **No hot reload** - Full page refresh loses client state (but server persists!)
⚠️ **Learning curve** - JSON decoders can be tedious
⚠️ **Larger bundle** - Elm app ~40-60KB compiled
⚠️ **Two codebases** - Lobby (LiveView) + Game (Elm)

---

## Timeline Estimate

**Aggressive** (full-time): 1-2 weeks
**Realistic** (part-time): 3-4 weeks
**Conservative** (learning Elm): 4-6 weeks

### Minimum Viable Elm Game (1 week)

- Types, decoders, channel integration
- Basic game view (cards, players, phase)
- Lock in hand, discard cards
- Round summary, match end
- No shop, no modals, no highlights

### Full Feature Parity (2-3 weeks)

- All modals (log, deck, levels)
- Shop system
- Card highlights
- Game history
- Error handling
- Polish

---

## Next Steps

1. **Prototype** - Start with Types.elm, mock game state
2. **Render** - Get a static game view working
3. **Connect** - Wire up channel, receive real state
4. **Interact** - Add card selection
5. **Iterate** - One feature at a time

Ready to build? Start with `Types.elm` and the game state decoder!
