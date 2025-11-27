# Command Center Reorganization - 4x4 Grid

## Summary

Reorganized the Command Center (formerly "Shop") from a 3x5 grid (15 cards) to a 4x4 grid (16 cards) split into two thematic sections:
- **Arsenal** (top 8 cards): Permanent upgrades (Level Ups + Deck Builders)
- **Tactical Ops** (bottom 8 cards): Temporary battlefield advantages (Action Cards)

## Changes Made

### 1. Card Generation (`lib/oskol/game/shop_state.ex`)

**Before**: 5 Level Ups + 5 Deck Builders + 5 Action Cards = 15 total
**After**: 4 Level Ups + 4 Deck Builders + 8 Action Cards = 16 total

- Updated `generate_random_shop_cards/1` to generate:
  - 4 Level Up cards (down from 5)
  - 4 Deck Builder cards (down from 5)
  - 8 Action Cards (up from 5)
- Cards remain sorted by category for consistency

### 2. Command Center Layout (`lib/oskol_web/components/game_live/shop.ex`)

**Header**: Changed from "Shop" to "Command Center" to fit war theme

**Width**: Increased from `w-[520px]` to `w-[690px]` (~33% wider to accommodate 4 columns)

**Grid Structure**: Changed from single 3-column grid to two 4-column sections:

```elixir
<!-- Arsenal Section (Permanent Upgrades) -->
<div class="mb-6">
  <div class="mb-3 flex items-center gap-2">
    <div class="text-sm font-semibold uppercase tracking-wider text-emerald-500/80">
      Arsenal
    </div>
    <div class="text-xs text-base-content/40">Permanent Upgrades</div>
  </div>
  <div class="grid grid-cols-4 gap-4">
    <!-- First 8 cards (indices 0-7) -->
  </div>
</div>

<!-- Tactical Ops Section (Action Cards) -->
<div>
  <div class="mb-3 flex items-center gap-2">
    <div class="text-sm font-semibold uppercase tracking-wider text-rose-500/80">
      Tactical Ops
    </div>
    <div class="text-xs text-base-content/40">Temporary Battlefield Advantage</div>
  </div>
  <div class="grid grid-cols-4 gap-4">
    <!-- Last 8 cards (indices 8-15) -->
  </div>
</div>
```

### 3. Visual Design

**Section Headers**:
- **Arsenal**: Gray text (`text-base-content/40`) with "Permanent Upgrades" subtitle
- **Tactical Ops**: Gray text (`text-base-content/40`) with "Temporary Battlefield Advantage" subtitle
- Consistent gray color for both sections provides cleaner visual hierarchy

**Card Type Badges & Colors**:
- **Research**: Green badge (`text-emerald-500`), shows "Research" label + hand name (e.g., "Pair", "Flush")
- **Deck Builder**: Violet badge (`text-violet-500`), shows card type (e.g., "Remove Card")
- **Blocker**: Red/rose badge (`text-rose-500`), shows "Blocker" label + blocked hand name
- **Tactical**: Amber/yellow badge (`text-amber-500`), shows "Tactical" label + card name (Scrambler, Plus Bomb, Static Field)

**Card Sizing**: Maintained same per-card dimensions; increased container width to prevent cramping

**Theme**: War-themed naming:
- Arsenal = Your permanent weapon/equipment upgrades
- Tactical Ops = Temporary battlefield tactical advantages

## Testing

The changes compile successfully with Elixir 1.19.2:
```bash
mix compile
# Compiling 36 files (.ex)
# Generated oskol app
```

Server runs successfully:
```bash
mix phx.server
# [info] Running OskolWeb.Endpoint with Bandit 1.8.0 at 127.0.0.1:4000 (http)
# [info] Access OskolWeb.Endpoint at http://localhost:4000
```

## Visual Preview

The new layout provides:
- ✅ Clear visual separation between permanent and temporary cards
- ✅ More action cards (8 vs 5) for greater tactical variety
- ✅ 4x4 grid is visually balanced and fits modern screen aspect ratios better
- ✅ War-themed section names match the game's competitive atmosphere
- ✅ Color-coded sections (emerald for permanent, rose for temporary) for quick recognition

## Files Modified

1. `lib/oskol/game/shop_state.ex` - Card generation logic
2. `lib/oskol_web/components/game_live/shop.ex` - Shop UI layout and sections

## Backward Compatibility

- All existing shop mechanics remain unchanged (turn-based picking, card types, etc.)
- Dev codes (`SHOP_FORCE_SCRAMBLER`, etc.) continue to work
- Shop state structure is unchanged; only card counts differ
