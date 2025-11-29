# Test: Countered Hand Indication (Issue #40)

## What This Tests

Verifies that when a hand type is countered (via Counter/denial card from shop), it shows visual indicators in the Research tab:

1. **Strikethrough text** on the hand name and stats
2. **"(Countered)" label** in red next to the hand name
3. **Reduced opacity** (60%) on the row

## How It Works

1. Two players join a game
2. Both play through one complete round (4 hands)
3. In the shop, the test tries to find and pick a Counter card
4. After shop rounds complete and next round starts
5. Opens the Research tab to show countered hand indication

## Running the Test

```bash
# Start the Phoenix server
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server &

# Run the test
node playwright/test-countered-hand-indication/test.js

# View screenshots
ls -la playwright/screenshots/test-countered-hand-indication/
```

## Screenshots

- `01-shop-initial.png` - Shop screen at start
- `02-counter-card-preview.png` - Counter card preview (if found)
- `03-next-round-started.png` - Game state after shop
- `04-research-tab-primary.png` - Research tab for Primary player
- `05-research-tab-opponent.png` - Research tab for Opponent

## Notes

- Counter cards are not guaranteed to appear in shop (random selection)
- If no Counter card is available, test shows normal Research tab state
- The strikethrough indication only shows when a player has an active counter debuff
