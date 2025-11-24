# Test: Full Game Flow with Suit-Changing Cards

End-to-end test that verifies the complete game flow including the suit-changing card feature.

## What This Tests

- ✅ 2-player lobby (Primary and Opponent)
- ✅ Starting a game
- ✅ Playing through a complete round (4 hands)
- ✅ Both players skipping hand/round summaries
- ✅ Shop navigation with dynamic turn order
- ✅ Suit-changing cards (Primary attempts when available)
- ✅ Card selection UI (multi-select up to 3 cards)
- ✅ Shop card purchases (simple confirm)
- ✅ Ready-up system (both players marking ready)
- ✅ Advancing to next round
- ✅ View Cards modal showing modified deck

## Running the Test

```bash
# From project root
node playwright/test-suit-action-card/test.js
```

## Output

Screenshots are saved to: `playwright/screenshots/test-suit-action-card/`

- `01-lobby-initial.png` - Initial lobby screen
- `02-player1-joined.png` - After Primary joins
- `03-both-joined-p1.png` - Both players in lobby (Primary view)
- `04-both-joined-p2.png` - Both players in lobby (Opponent view)
- `05-game-started-p1.png` - Game started with cards dealt
- `06-game-started-p2.png` - Game started (Opponent view)
- `07-round-complete-p1.png` - After all 4 hands played
- `08-round-complete-p2.png` - Round summary
- `09-shop-p1.png` - Shop screen showing all cards
- `10-shop-p2.png` - Shop screen (Opponent view)
- `11-suit-card-preview.png` - **Suit-changing card selected** (if available)
- `12-suit-card-selection.png` - **Card selection modal (up to 3 cards)**
- `13-cards-selected.png` - **3 cards selected with borders**
- `14-after-suit-change.png` - After confirming suit change
- `15-next-round-started.png` - Both players ready, next round started
- `16-next-round-started-p2.png` - Next round (Opponent view)
- `17-view-cards-modal.png` - **View Cards modal showing modified deck**
- `ERROR.png` - Saved if test fails

## Customization

Edit `test.js` to modify:
- **Game ID** (line 29): Change test ID prefix
- **Player names** (lines 42, 53): Currently "Primary" and "Opponent"
- **Wait times** (sleep durations): Adjust for slower/faster machines
- **Number of hands** (line 75): Currently plays 4 hands

## Notes

- **Turn order is dynamic**: Winner of the previous round picks first in the shop
- **Shop cards are randomly generated**: Suit-changing cards may not always appear
- **Primary attempts suit-changing**: On Primary's first shop pick, the test looks for suit-changing cards
- **Fallback to any shop card**: If no suit-changing card is available, Primary picks any available shop card
- **All other picks are simple shop cards**: Could be level ups or action cards, simple confirm-only picks
- The test will log a warning if no suit-changing card is found
- Run multiple times to see different card combinations
- Server must be running on `http://localhost:4000`

## Troubleshooting

If the test fails:
1. Check `playwright/screenshots/test-suit-action-card/ERROR.png` to see where it stopped
2. Look at the console logs - they show timestamps for each step
3. Increase `sleep()` durations if steps are timing out
4. Verify the server is running: `mix phx.server`
