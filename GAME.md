# Oskol - Game Rules & Mechanics

## Overview

Oskol is a **two-player competitive poker roguelike** where players battle through rounds of poker hands, upgrade their abilities in a shop system, and try to be the last player standing.

**Live at:** [oskol.io](https://oskol.io)

## Core Concept

Unlike traditional poker, Oskol combines:
- **Discards** - You can discard cards each round (default: 4 discards)
- **Multiple hands per round** - Play multiple hands per round (default: 3 hands), accumulating score
- **Roguelike progression** - Upgrade your hands, modify your deck, and apply debuffs to your opponent at the shop between each round

## Victory Condition

Each player starts with a configurable number of lives (typically 2-5). The goal is to reduce your opponent to 0 lives
by winning rounds.

## Game Flow

### 1. Lobby Phase
- Two players join a game room and agree on the match settings
  - Skirmish: 2 lives, 1 shop round
  - Battle: 3 lives, 2 shop rounds
  - War: 5 lives, 2 shop rounds
- Once both players are ready, the game begins

### 2. Round Start
- Each player draws **8 cards** from their shuffled deck
- Both players start with the same number of hands and discards for the round
- All temporary debuffs from the previous round are cleared

### 3. Playing Phase

Players take turns making hands until they run out of hands or choose to stop. Each round consists of:

#### Making a Hand
1. **Select 1-5 cards** from your hand
2. **Lock in your hand** when ready
3. Wait for opponent to lock in their hand
4. **Both hands are scored simultaneously**

#### Discarding Cards (Optional)
- Before locking in, you can **discard unwanted cards** and draw replacements
- Limited by "discards per round" setting
- Discarded cards go to your discard pile and you draw from your deck

#### Hand Resolution
When both players lock in:
1. Hands are evaluated (High Card, Pair, Flush, etc.)
2. Scores are calculated using the **scoring formula**
3. Each player's score is added to their **round total**
4. Played cards are discarded
5. Both players draw replacement cards from their deck
6. Players can continue making hands until they've used all their hands for the round

### 4. Round End

After all hands are played:
1. **Total scores are compared** across all hands played that round
2. **The loser loses 1 life** (or no one loses a life if it's a tie)
3. If a player reaches 0 lives, the **game is over**
4. Otherwise, proceed to shop phase

### 5. Shop Phase

After every round (until the game is over), players enter the shop phase:

#### Destroy Phase (Life-Based Advantage)
- If one player has **fewer lives** than the other, they get to **destroy shop cards**
- Number of destroys = life difference (e.g., 3 lives vs 5 lives = 2 destroys)
- The trailing player can remove cards from the shop before anyone picks
- Helps balance the game by giving losing players better shop options

#### Pick Phase
- The **round winner picks first**, then the loser
- Players alternate picking cards from the available shop cards
- The `shop_rounds` configuration (1-3) controls how many pick rounds occur within each shop
  - 1 shop round = each player picks 1 card
  - 2 shop rounds = each player picks 2 cards (alternating)
  - 3 shop rounds = each player picks 3 cards (alternating)
- Some cards (Deck Builders, Napalm Strikes) require additional selection steps
- Once all picks are complete, players auto-ready for the next round

#### Shop Card Categories

**Research Cards** - Upgrade your hand types
- Level up any poker hand (Pair, Flush, Straight, etc.)
- Each level increases both chips and multiplier for that hand type

**Counter Cards** - Deny opponent's hand types
- Block a specific hand type from scoring next round
- If opponent plays a denied hand, they score 0 points

**Logistics Cards** - Modify your deck
- **Fortify**: Add +40 bonus chips to a card
- **Amplify**: Add +1 bonus multiplier to a card
- **Supply Drop**: Add a new card to your deck
- **Discharge**: Remove up to 2 cards from your deck
- **Camo**: Change cards to a specific suit (♥♦♣♠)
- **Promote**: Increase rank of cards by 1 (max is Ace)

**Sabotage Cards** - Debuff your opponent for next round
- **Scrambler**: Opponent's drawn cards have 1-in-5 chance of being face-down
- **Napalm Strikes**: Disable a rank or suit from scoring
- **Static Field**: Disable all card enhancements
- **Supply Chain**: Limit opponent to drawing max 4 cards when discarding

### 6. Next Round
- Both players' decks are reshuffled (combining hand, deck, and discard)
- New hands of 8 cards are drawn
- Hands and discards reset to configured amounts
- Round counter increments
- Repeat from step 3

## Scoring System

### The Formula
```
Total Score = (Base Chips + Card Values + Bonus Chips) × (Base Multiplier + Bonus Multipliers)
```

### Breaking It Down

#### 1. Base Hand Stats
Each hand type has base chips and base multiplier at level 1:

| Hand Type | Base Chips | Base Multiplier |
|-----------|------------|-----------------|
| High Card | 125 | 1 |
| Pair | 140 | 1 |
| Two Pair | 105 | 2 |
| Three of a Kind | 130 | 2 |
| Straight | 70 | 4 |
| Flush | 70 | 4 |
| Full House | 70 | 5 |
| Four of a Kind | 50 | 12 |
| Straight Flush | 95 | 12 |

#### 2. Level Bonuses
When you upgrade a hand in the shop:
- **Levels 1-8**: +10 chips, +1 mult per level
- **Four of a Kind & Straight Flush**: +20 chips, +2 mult per level

For example, a level 3 Pair:
- Base: 140 chips, 1 mult
- Level 3: 140 + (2 × 10) = **160 chips, 3 mult**

#### 3. Card Values
Each card contributes chip value based on its rank:
- **2-10**: Face value (2 = 2 chips, 10 = 10 chips)
- **Jack**: 11 chips
- **Queen**: 12 chips
- **King**: 13 chips
- **Ace**: 14 chips

#### 4. Card Enhancements
Cards can be enhanced via shop cards:
- **Bonus Chips**: Adds extra chips (e.g., +40 from Fortify)
- **Bonus Multiplier**: Adds to the multiplier (e.g., +1 from Amplify)

#### 5. Debuffs
Various effects can reduce scoring:
- **Denied Hands**: If opponent denies your hand type, you score 0
- **Disabled Ranks/Suits**: Cards matching disabled ranks/suits don't contribute
- **Disabled Enhancements**: Bonus chips/mult from enhancements don't apply

### Scoring Example

Playing a **Level 2 Pair** with **7♥ 7♣** (where 7♥ has +40 bonus chips):

1. Base stats: 140 chips, 1 mult
2. Level 2 bonus: +10 chips, +1 mult → **150 chips, 2 mult**
3. Card values: 7 + 7 = 14 chips
4. Card enhancements: +40 bonus chips
5. Total: (150 + 14 + 40) × 2 = **408 points**

## Poker Hand Rankings

Hands are evaluated using standard poker rules:

1. **Straight Flush** - 5 cards in sequence, same suit
2. **Four of a Kind** - 4 cards of same rank
3. **Full House** - 3 of a kind + pair
4. **Flush** - 5 cards of same suit
5. **Straight** - 5 cards in sequence
6. **Three of a Kind** - 3 cards of same rank
7. **Two Pair** - 2 pairs
8. **Pair** - 2 cards of same rank
9. **High Card** - Highest card in hand

### Special Rules
- **Ace-low straight**: A-2-3-4-5 counts as a straight
- **Scoring cards**: Only the cards that make up the hand contribute to score
  - Pair: The 2 matching cards score
  - Flush: All 5 cards score
  - High Card: Only the highest card scores

## Deck Structure

### Starting Deck
Each player starts with a **standard 52-card deck**:
- 13 ranks (2-10, J, Q, K, A)
- 4 suits (♥♦♣♠)
- No jokers

### Deck Modifications
Through shop cards, players can:
- Add new cards (Supply Drop)
- Remove cards (Discharge)
- Change card suits (Camo)
- Increase card ranks (Promote)
- Add enhancements to cards (Fortify, Amplify)

### Card Piles
Each player has three piles:
1. **Deck**: Cards to be drawn
2. **Hand**: Current 8 cards available to play
3. **Discard**: Played and discarded cards

At the start of each round, all piles are combined and reshuffled.

## Strategic Depth

### Core Strategies

**Balanced Approach**
- Upgrade multiple hand types for flexibility
- Adapt to what cards you draw

**Specialization**
- Focus on upgrading 2-3 hand types heavily
- Build your deck to support those hands (e.g., add same-suit cards for Flush)

**Disruption**
- Use Counter cards to deny opponent's strongest hands
- Use Sabotage cards to weaken their scoring

**Deck Building**
- Remove low-value cards (2s, 3s) with Discharge
- Add high-value cards or duplicate useful ranks with Supply Drop
- Use Camo to create more Flush opportunities

### Advanced Tactics

**Life Deficit Strategy**
- When behind on lives, use destroy phase wisely
- Remove opponent's best upgrade options
- Force them into suboptimal picks

**Hand Management**
- Save discards for when you have truly bad hands
- Consider playing mediocre hands early to save discards for later

**Tempo Play**
- Sometimes playing a quick, weaker hand is better than burning discards
- Balance quality vs. quantity of hands played

**Counter-Play**
- Track opponent's upgraded hands
- Deny their strongest hand types in critical rounds
- Use sabotage right before you expect to lose a round (so you pick first in shop)

## Game Phases Summary

| Phase | Description | Duration |
|-------|-------------|----------|
| **Lobby** | Configure settings, wait for both players | Until ready |
| **Round Start** | Draw 8 cards, reset hands/discards | Instant |
| **Playing** | Make hands, discard, accumulate score | Until all hands played |
| **Round End** | Compare scores, loser loses life | Instant |
| **Shop** | Destroy + pick shop cards | Configurable rounds |
| **Game Over** | Winner declared | End of game |

## Win Conditions

You win when:
1. Your opponent reaches **0 lives**
2. Your opponent **disconnects** or **abandons** the game

The game can also **tie** if both players run out of cards with equal lives (rare).

## Tips for New Players

1. **Start with balanced upgrades** - Don't over-invest in one hand type early
2. **High Cards and Pairs are consistent** - They're easy to make but score less
3. **Straights and Flushes need deck building** - Add same-suit or sequential cards
4. **Save discards for critical moments** - Don't waste them on marginal improvements
5. **Watch the life totals** - Being down on lives gives you shop advantages
6. **Deny opponent's best hands** - Track what they're upgrading in shop
7. **Use sabotage strategically** - Save it for rounds where you need an edge

## Common Questions

### Can I play more than 3 hands per round?
No, the maximum hands per round is 3 (configurable in lobby).

### What happens if I run out of cards in my deck?
Your discard pile is shuffled back into your deck automatically.

### Do enhancements persist between rounds?
Yes, all deck modifications (enhancements, suit changes, rank promotions) are permanent.

### Do debuffs last forever?
No, Counter and Sabotage effects only last for the next round, then they clear.

### Can I undo a locked-in hand?
No, once you lock in a hand, it's final. Choose carefully!

### What if both players have the same score?
It's a tie - no one loses a life that round.

### How many shop cards are available?
Typically 4-6 cards are available per shop round, with picks alternating between players.

## Technical Details

- **Real-time multiplayer** using Phoenix Channels (WebSockets)
- **Event sourcing** - all game actions are logged as events
- **Pure functional game logic** in Gleam for correctness and testability
- **Elixir GenServer** manages game state and player actions
- **Phoenix LiveView** for reactive UI updates
- **Elm frontend** for type-safe client-side rendering

---

**Ready to play?** Visit [oskol.io](https://oskol.io) and challenge a friend!
