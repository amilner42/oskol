# Shop Cards TODO List

## Overview

**Status as of 2025-12-14:**
- ✅ 9 cards working
- ❌ 3 cards broken/not implemented
- ⚠️ 4 cards need verification

---

## PRIORITY 1: Fix Broken Cards

### [ ] TODO 1: Fix PlusBomb (Sabotage)

**Current Issue:** The card selection flow works, but the selected card is IGNORED and no effect is applied to the opponent.

**What PlusBomb Should Do:**
When you select a card (e.g., Ace of Spades), all of the opponent's cards matching that rank AND suit are disabled from scoring in the next round.

**The Bug:**
- File: `src/game/engine.gleam`
- Line 94: `_opponent_card_id` parameter is ignored (underscore prefix)
- Lines 566-587: `handle_complete_plus_bomb_selection()` doesn't apply any effect

**Implementation Steps:**

1. Update line 94 to pass the parameter:
```gleam
CompletePlusBombSelection(player_id, opponent_card_id) ->
  handle_complete_plus_bomb_selection(state, player_id, opponent_card_id)
```

2. Update `handle_complete_plus_bomb_selection()` signature (line 566):
```gleam
fn handle_complete_plus_bomb_selection(
  state: GameState,
  player_id: PlayerId,
  selected_card_id: String,
) -> EngineResult {
```

3. Inside the function, after getting `Ok(updated_shop)`, extract the pending plus bomb info and apply the effect:
```gleam
Ok(updated_shop) -> {
  // Get the pending plus bomb info to find the selected card
  let state_with_debuff = case shop.pending_plus_bomb {
    Some(pending) -> {
      // Find the selected card from available_cards
      case list.find(pending.available_cards, fn(c) { c.id == selected_card_id }) {
        Ok(selected_card) -> {
          // Get opponent ID
          let all_player_ids = dict.keys(state.players)
          case list.find(all_player_ids, fn(id) { id != player_id }) {
            Ok(opponent_id) -> {
              // Get opponent player
              case dict.get(state.players, opponent_id) {
                Ok(opponent) -> {
                  // Add rank and suit to opponent's disabled lists
                  let updated_opponent = player.Player(
                    ..opponent,
                    disabled_ranks: [selected_card.rank, ..opponent.disabled_ranks],
                    disabled_suits: [selected_card.suit, ..opponent.disabled_suits]
                  )
                  let updated_players = dict.insert(state.players, opponent_id, updated_opponent)
                  state.GameState(..state, players: updated_players)
                }
                Error(_) -> state
              }
            }
            Error(_) -> state
          }
        }
        Error(_) -> state
      }
    }
    None -> state
  }

  let new_state = state.GameState(..state_with_debuff, shop_state: Some(updated_shop))
  let final_state = check_shop_completion_and_auto_ready(new_state)
  EngineResult(state: final_state, events: [])
}
```

**Files to Modify:**
- `src/game/engine.gleam` (lines 94, 566-587)

**Testing:**
1. Start a game with shop enabled
2. Buy PlusBomb card
3. Select a card from your hand (e.g., Ace of Spades)
4. Confirm selection
5. In next round, verify opponent's Aces and Spades don't score
6. After that round, verify debuff is cleared (cards score normally again)

---

### [ ] TODO 2: Implement Camo (Logistics/DeckBuilder)

**Current Issue:** Line 509 in `engine.gleam` shows `// TODO: Implement Camo and Promote` - returns unmodified player.

**What Camo Should Do:**
Change selected cards' suits to a specified target suit (Hearts/Diamonds/Clubs/Spades). The suit change persists permanently across rounds.

**Implementation Steps:**

1. Add new function to `src/game/player.gleam`:
```gleam
/// Change the suit of specific cards by their IDs
pub fn change_cards_suit(
  player: Player,
  card_ids: List(String),
  new_suit: Suit,
) -> Player {
  let change_suit = fn(c: Card) -> Card {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, suit: new_suit)
      False -> c
    }
  }

  // Apply to all cards in all piles
  let new_hand = list.map(player.card_piles.hand, change_suit)
  let new_deck = list.map(player.card_piles.deck, change_suit)
  let new_discard = list.map(player.card_piles.discard, change_suit)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)
  Player(..player, card_piles: new_piles)
}
```

2. Update `src/game/engine.gleam` line 509:
```gleam
shop_card.Camo(target_suit, _) ->
  player.change_cards_suit(current_player, selected_card_ids, target_suit)
```

**Files to Modify:**
- `src/game/player.gleam` (add new function)
- `src/game/engine.gleam` (line 509)

**Testing:**
1. Start a game with shop enabled
2. Buy Camo card (specify target suit, e.g., Hearts)
3. Select cards of different suits from the shown options
4. Confirm selection
5. Verify selected cards now have the target suit
6. Play a round, discard, shuffle - verify suit change persists

---

### [ ] TODO 3: Implement Promote (Logistics/DeckBuilder)

**Current Issue:** Line 509 in `engine.gleam` shows `// TODO: Implement Camo and Promote` - returns unmodified player.

**What Promote Should Do:**
Increase the rank of selected cards by 1 (Two→Three, Three→Four, ..., King→Ace, Ace stays Ace). The rank change persists permanently across rounds.

**Implementation Steps:**

1. Add helper function to `src/poker/card.gleam`:
```gleam
/// Get the next rank (for Promote card). Ace stays Ace (max rank).
pub fn next_rank(rank: Rank) -> Rank {
  case rank {
    Two -> Three
    Three -> Four
    Four -> Five
    Five -> Six
    Six -> Seven
    Seven -> Eight
    Eight -> Nine
    Nine -> Ten
    Ten -> Jack
    Jack -> Queen
    Queen -> King
    King -> Ace
    Ace -> Ace  // Max rank, can't promote further
  }
}
```

2. Add new function to `src/game/player.gleam`:
```gleam
/// Increase the rank of specific cards by their IDs
pub fn promote_cards(
  player: Player,
  card_ids: List(String),
) -> Player {
  let promote = fn(c: Card) -> Card {
    case list.contains(card_ids, c.id) {
      True -> card.Card(..c, rank: card.next_rank(c.rank))
      False -> c
    }
  }

  // Apply to all cards in all piles
  let new_hand = list.map(player.card_piles.hand, promote)
  let new_deck = list.map(player.card_piles.deck, promote)
  let new_discard = list.map(player.card_piles.discard, promote)

  let new_piles = CardPiles(hand: new_hand, deck: new_deck, discard: new_discard)
  Player(..player, card_piles: new_piles)
}
```

3. Update `src/game/engine.gleam` line 509:
```gleam
shop_card.Promote(_) ->
  player.promote_cards(current_player, selected_card_ids)
```

**Files to Modify:**
- `src/poker/card.gleam` (add `next_rank` function)
- `src/game/player.gleam` (add `promote_cards` function)
- `src/game/engine.gleam` (line 509)

**Testing:**
1. Start a game with shop enabled
2. Buy Promote card
3. Select cards (e.g., Two, King, Ace)
4. Confirm selection
5. Verify cards are now Three, Ace, Ace respectively
6. Play a round, discard, shuffle - verify rank changes persist

---

## PRIORITY 2: Verify Debuff Usage

These cards SET debuff flags correctly, but we need to verify gameplay logic actually CHECKS these flags.

### [ ] TODO 4: Verify Scrambler Effect

**What It Should Do:**
When opponent draws cards, 1-in-5 cards should be face-down (opponent can't see rank/suit).

**Current Status:**
- ✅ Flag is set: `scrambled: True` on opponent (engine.gleam lines 301-302)
- ❓ Need to verify: Card drawing logic checks this flag

**Verification Steps:**
1. Search codebase for where cards are drawn
2. Check if `scrambled` flag is used to randomly set cards as face-down
3. Look for `face_down_card_ids` population logic
4. If missing, implement the 1-in-5 randomization when `scrambled == True`

**Testing:**
1. Buy Scrambler against opponent
2. Wait for opponent to discard cards (triggers draw)
3. Check if ~20% of opponent's drawn cards show as face-down
4. After 1 round, verify effect clears

---

### [ ] TODO 5: Verify Static Field Effect

**What It Should Do:**
Opponent's card enhancements (BonusChips, BonusMult) should be ignored when scoring hands.

**Current Status:**
- ✅ Flag is set: `enhancements_disabled: True` on opponent (engine.gleam lines 303-304)
- ❓ Need to verify: Scoring logic checks this flag

**Verification Steps:**
1. Find hand scoring logic (likely in `src/poker/score.gleam` or similar)
2. Check if `enhancements_disabled` flag is checked when calculating score
3. If missing, add logic to skip card enhancement bonuses when flag is True

**Testing:**
1. Opponent buys Fortify/Amplify and enhances cards
2. Buy Static Field against opponent
3. Next round, when opponent plays enhanced cards, verify bonuses don't apply
4. After 1 round, verify effect clears (enhancements work again)

---

### [ ] TODO 6: Verify Supply Chain Effect

**What It Should Do:**
When opponent discards cards, they can only draw up to 4 cards (instead of replacing all discarded cards).

**Current Status:**
- ✅ Flag is set: `supply_chain_limited: True` on opponent (engine.gleam lines 305-306)
- ❓ Need to verify: Discard/draw logic checks this flag

**Verification Steps:**
1. Find discard handling logic (likely in engine.gleam or player.gleam)
2. Check if `supply_chain_limited` flag limits draw to min(4, cards_discarded)
3. If missing, add logic to cap draws at 4 when flag is True

**Testing:**
1. Buy Supply Chain against opponent
2. Next round, observe when opponent discards 5+ cards
3. Verify they only draw 4 cards back (hand size shrinks)
4. After 1 round, verify effect clears

---

### [ ] TODO 7: Verify Denial Effect

**What It Should Do:**
If opponent plays a hand type that's in their `active_debuffs` list, that hand should score 0 points.

**Current Status:**
- ✅ Flag is set: Hand type added to `active_debuffs` list (engine.gleam line 345)
- ❓ Need to verify: Scoring logic checks this list

**Verification Steps:**
1. Find hand scoring logic
2. Check if `active_debuffs` is checked before calculating score
3. If the played hand type is in the list, score should be 0
4. If missing, add this check

**Testing:**
1. Buy Denial: Flush
2. Next round, observe opponent playing a Flush
3. Verify their score is 0 (not calculated normally)
4. Verify opponent playing other hand types (Pair, Straight, etc.) still score normally
5. After 1 round, verify effect clears

---

## Currently Working Cards (No Action Needed)

### ✅ Research Cards
- **LevelUp** - Upgrades hand type levels in skill tree

### ✅ Counter Cards
- **Denial** - Adds hand type to opponent's `active_debuffs` (needs verification - see TODO 7)

### ✅ Logistics/DeckBuilder Cards
- **Fortify** - Adds bonus chips to selected cards
- **Amplify** - Adds bonus multiplier to selected cards
- **SupplyDrop** - Creates new cards and adds to deck
- **Discharge** - Removes selected cards from deck

### ✅ Sabotage Cards (need verification)
- **Scrambler** - Sets `scrambled: True` (needs verification - see TODO 4)
- **StaticField** - Sets `enhancements_disabled: True` (needs verification - see TODO 5)
- **SupplyChain** - Sets `supply_chain_limited: True` (needs verification - see TODO 6)

---

## Implementation Order Recommendation

1. **PlusBomb** (TODO 1) - Easiest fix, infrastructure exists, just needs to apply effect
2. **Camo** (TODO 2) - Simple card mutation logic
3. **Promote** (TODO 3) - Similar to Camo, simple card mutation
4. **Scrambler** (TODO 4) - Need to find draw logic and add randomization
5. **Static Field** (TODO 5) - Need to find scoring logic and add check
6. **Supply Chain** (TODO 6) - Need to find discard logic and add limit
7. **Denial** (TODO 7) - Need to find scoring logic and add zero-score check

---

## Testing Checklist

After implementing all fixes, run through this complete test:

- [ ] LevelUp: Buy Pair level, verify Pair hand scores higher
- [ ] Denial: Buy Denial:Flush, verify opponent's Flush scores 0 next round
- [ ] Fortify: Buy Fortify, select cards, verify +chips persists
- [ ] Amplify: Buy Amplify, select cards, verify +mult persists
- [ ] SupplyDrop: Buy SupplyDrop, select card, verify deck grows by 1
- [ ] Discharge: Buy Discharge, select cards, verify deck shrinks by 2
- [ ] Camo: Buy Camo:Hearts, select cards, verify all become Hearts
- [ ] Promote: Buy Promote, select Two/King/Ace, verify they become Three/Ace/Ace
- [ ] Scrambler: Buy Scrambler, verify opponent's draws have face-down cards
- [ ] StaticField: Buy StaticField (after opponent has enhancements), verify bonuses ignored
- [ ] SupplyChain: Buy SupplyChain, verify opponent draws max 4 on discard
- [ ] PlusBomb: Buy PlusBomb, select Ace♠, verify opponent's Aces and Spades disabled

All debuffs should clear after 1 round!
