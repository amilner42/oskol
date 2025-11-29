# Shop Status Bar Test

Tests the round number and lives display in the shop screen (GitHub Issue #36).

## What it tests

1. Two players join and start a game with the 1HAND dev code
2. Plays through one complete round (1 hand due to dev code)
3. Enters the shop screen
4. Verifies:
   - Round number is visible in the shop header
   - Player lives (hearts) are visible for both players
   - Opponent lives (hearts) are visible
   - Layout works on desktop, tablet, and mobile viewports

## Running the test

```bash
# Start the Phoenix server first
mix phx.server &

# Run the test
node playwright/test-shop-status-bar/test.js
```

## Screenshots

Screenshots are saved to `playwright/screenshots/test-shop-status-bar/`:

- `01-shop-desktop-p1.png` - Player 1's shop view (desktop)
- `02-shop-desktop-p2.png` - Player 2's shop view (desktop)
- `03-shop-mobile-p1.png` - Player 1's shop view (mobile, 375x667)
- `04-shop-tablet-p1.png` - Player 1's shop view (tablet, 768x1024)

## Expected result

The shop header should display:
- "Round X" indicator (where X is the current round number)
- Player's name with heart icons showing remaining lives
- Opponent's name with heart icons showing remaining lives
- Responsive layout that stacks on mobile and displays inline on desktop
