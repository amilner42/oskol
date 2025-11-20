# Deck Builder Flow - Reference Document

## Overview
Deck builders are special shop cards that require a two-phase interaction. The entire deck builder process happens during ONE player's turn.

## Complete Flow (Player 1's Turn)

### Phase 1: Commit to Deck Builder
1. **Player 1** clicks a deck builder card (e.g., "+4 Mult")
2. Modal appears showing:
   - Card name (e.g., "Add Multiplier Chip")
   - Description (e.g., "Add +4 mult to a card")
   - **"Confirm Pick" button**
3. **Player 1** clicks "Confirm Pick"
   - Server marks card as picked (adds to `picked_card_indices`)
   - Server generates 8 random cards from Player 1's full deck
   - Server stores in `shop_state.pending_deck_builder`
   - **Turn is STILL Player 1's** (no turn switch yet)

### Phase 2: Select Card to Upgrade
4. Modal updates to show:
   - 8-card grid (both players see the same 8 cards)
   - "Skip" button
   - "Confirm Selection" button (only enabled after selecting a card)
5. **Both players** see the 8 cards (opponent is spectating)
6. **Player 1** can:
   - Click a card to select it (opponent sees the selection highlight)
   - Click "Confirm Selection" to apply the upgrade
   - OR click "Skip" to not apply any upgrade

### Phase 3: Apply Effect & End Turn
7. **If Player 1 confirms:**
   - Server applies enhancement to selected card (e.g., adds +4 mult)
   - Server completes the pick (sets `first_pick_made: true`)
   - Server clears `pending_deck_builder`
   - **Turn ends → Player 2's turn starts immediately**

8. **If Player 1 skips:**
   - Server does NOT apply any effect
   - Server completes the pick (sets `first_pick_made: true`)
   - Server clears `pending_deck_builder`
   - **Turn ends → Player 2's turn starts immediately**

## Key Principles

### Turn Management
- **ONE turn = entire deck builder process** (phases 1-3 all happen in one turn)
- Turn only ends when player confirms selection OR skips
- While in deck builder phase 2, `can_pick?(shop_state, player_id)` must return `true` (still your turn)

### Visibility
- **Both players see everything** (same modal, same 8 cards, same selection)
- Opponent is spectating - they see what you pick but can't interact
- This maintains transparency in the game

### State Management
- `picked_card_indices`: Tracks which shop cards have been picked (prevents re-picking)
- `pending_deck_builder`: Stores active deck builder session (8 cards, which player, which card type)
- `first_pick_made` / `second_pick_made`: Tracks when a pick is FULLY complete (turn ends)

## Implementation Details

### GameState Functions
1. **`confirm_deck_builder_pick(game_state, player_id, card_index)`**
   - Validates it's player's turn
   - Marks card as picked (adds to `picked_card_indices`)
   - Generates 8 cards
   - Stores in `pending_deck_builder`
   - **Does NOT complete pick** (turn doesn't switch)
   - Returns `{:ok, new_state, events}`

2. **`complete_deck_builder_selection(game_state, player_id, selected_card_id)`**
   - Validates pending_deck_builder exists and belongs to player
   - Applies enhancement/add/remove effect to selected card
   - **Completes the pick** via `ShopState.complete_pick` (turn switches)
   - Clears `pending_deck_builder`
   - Checks if both players picked → advance round if needed
   - Returns `{:ok, new_state, events}`

3. **`skip_deck_builder_selection(game_state, player_id)`**
   - Validates pending_deck_builder exists and belongs to player
   - **Does NOT apply any effect**
   - **Completes the pick** via `ShopState.complete_pick` (turn switches)
   - Clears `pending_deck_builder`
   - Checks if both players picked → advance round if needed
   - Returns `{:ok, new_state, events}`

### ShopState Functions
1. **`mark_card_picked(shop_state, card_index)`**
   - Adds card_index to `picked_card_indices`
   - **Does NOT set first_pick_made/second_pick_made**
   - Used for deck builders to prevent re-picking without ending turn

2. **`complete_pick(shop_state, player_id)`**
   - Sets `first_pick_made: true` (if first picker) or `second_pick_made: true` (if second picker)
   - **This is what ends the turn**
   - Returns `{:ok, updated_state}` or `{:error, :not_your_turn}`

3. **`can_pick?(shop_state, player_id)`**
   - Returns `true` if it's the player's turn to pick
   - Checks: `not first_pick_made and player_id == first_picker_id`
   - OR: `first_pick_made and not second_pick_made and player_id == second_picker_id`

## UI States

### Shop Cards Grid (Bottom)
- Deck builder card shows "DECK BUILDER" badge
- If picked: Shows "PICKED" indicator and is disabled
- If not your turn: All cards disabled

### Preview Modal (Center)
**Before Confirm:**
- Shows card description
- Shows "Confirm Pick" button (if `can_pick?` = true)
- No 8-card grid visible

**After Confirm:**
- Shows card description
- Shows 8-card grid
- Shows "Skip" button
- Shows "Confirm Selection" button (enabled only if card selected)
- Card selection is visible to both players

## Events
- `:deck_builder_confirmed` - When player clicks "Confirm Pick"
- `:deck_builder_applied` - When player selects card and confirms
- `:deck_builder_skipped` - When player clicks "Skip"
- `:shop_round_advanced` - When both players complete picks and new round starts
