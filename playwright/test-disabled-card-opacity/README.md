# Disabled Card Opacity Test

## Issue Reference
Fixes #42: Disabled cards make seeing the card a bit too hard

## What This Test Verifies
This test verifies that the red X overlay on disabled cards has been reduced in opacity from 90% to 50%, making the underlying card more visible while still clearly indicating it is disabled.

## Test Steps
1. Two players join and start a game with dev codes: `SHOP_FORCE_PLUS_BOMB,1HAND`
2. Play one quick round (1HAND dev code reduces hands per round to 1)
3. Enter shop phase and pick the PLUS BOMB card
4. Select a card/rank to disable on the opponent
5. Start next round and screenshot the disabled cards showing the new lower opacity X

## Key Change
- **Before**: `text-red-600/90` (90% opacity)
- **After**: `text-red-600/50` (50% opacity)

This makes the card beneath the X much more visible while still clearly indicating the card is disabled.

## Running the Test
```bash
# Start the Phoenix server
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server &

# Run the test
node playwright/test-disabled-card-opacity/test.js
```

## Screenshots
After running, check `playwright/screenshots/test-disabled-card-opacity/` for:
- `02-disabled-cards-p1.png` - Shows disabled cards with reduced opacity X
- `03-disabled-cards-p2.png` - Shows disabled cards from other player view
- `04-console-deck-view.png` - Console deck view with disabled cards
