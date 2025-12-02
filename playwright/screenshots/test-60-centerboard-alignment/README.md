# Fix #60: Centerboard Scoring Alignment

## Issue
The centerboard scoring display on mobile had subtle vertical alignment issues. The cards and scoring formula were not perfectly centered horizontally. Additionally, on desktop, the cards were too large causing overlap with player hands.

## Solution
Added proper Tailwind CSS flexbox alignment classes and reduced desktop card sizes in the `score_breakdown_row` component in `lib/oskol_web/components/game_live/gameplay.ex`:

### Changes Made
**Line 1397** - Main container:
```elixir
# Before:
<div class={if @is_opponent, do: "", else: ""}>

# After:
<div class="flex flex-col items-center">
```

**Line 1404** - Cards display container:
```elixir
# Before:
<div class="flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3">

# After:
<div class="flex gap-1 sm:gap-2 justify-center items-center mb-2 sm:mb-3">
```

**Line 1433** - Individual card wrapper:
```elixir
# Before:
<div class="relative">

# After:
<div class="relative flex items-center">
```

**Line 1436** - Card sizing (reduced for desktop, mobile unchanged):
```elixir
# Before:
class={"w-9 h-[52px] sm:w-16 sm:h-24 #{card_class}"}

# After:
class={"w-9 h-[52px] sm:w-14 sm:h-20 #{card_class}"}
```

### Visual Evidence
The fix ensures perfect horizontal centering of all scoring display elements:

- **Desktop**: See `03-desktop-scoring-ALIGNMENT-FIX.png` - Shows "Lvl 1 PAIR" with smaller cards (w-14 h-20) that fit better and are perfectly centered, significantly reducing overlap with player hands
- **Mobile**: See `07-mobile-scoring-ALIGNMENT-FIX.png` - Shows "Lvl 1 PAIR" and "Lvl 1 HIGH CARD" with cards at original size (w-9 h-52px), perfectly centered

### Technical Details
The fix ensures:
1. Main container uses `flex flex-col` for vertical stacking
2. All children are centered horizontally with `items-center`
3. Cards row maintains proper vertical alignment within the flex container
4. Individual card wrappers use flexbox for consistent alignment
5. Desktop cards are ~17% smaller (64x96px → 56x80px) for better height management
6. Mobile cards remain unchanged for optimal touch interaction
7. Both mobile and desktop views benefit from improved alignment

## Files Modified
- `lib/oskol_web/components/game_live/gameplay.ex` - Added flexbox alignment classes and adjusted card sizes (lines 1397, 1404, 1433, 1436)
