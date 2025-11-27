# PLUS BOMB and STATIC Action Cards Test

Tests the two new action card types:

## PLUS BOMB
- Player picks 1 of 8 random cards
- The selected card's rank AND suit become disabled for opponent's next round
- Cards with that rank OR suit contribute 0 chips and no enhancement bonuses

## STATIC
- Immediate effect (no card selection)
- Disables all opponent's card enhancements next round
- Cards still score base chip values, but bonus_chips/bonus_mult are ignored

## How to Run

```bash
# Start the server
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server &

# Run the test
node playwright/test-plus-bomb-static/test.js

# View screenshots
ls -la playwright/screenshots/test-plus-bomb-static/
```

## Dev Codes Used

- `SHOP_FORCE_PLUS_BOMB` - Forces a Plus Bomb card in the shop
- `SHOP_FORCE_STATIC` - Forces a Static card in the shop
- `1HAND` - Only 1 hand per round (faster testing)

## Key Screenshots

- `11-plus-bomb-preview.png` - Plus Bomb card preview showing description
- `12-plus-bomb-selection-grid.png` - 8-card selection grid for Plus Bomb
- `13-plus-bomb-card-selected.png` - Selected card highlighted
- `16-static-preview.png` - Static card preview showing description
