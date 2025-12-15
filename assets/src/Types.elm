module Types exposing (..)

{-| Core type definitions for the Oskol Elm game client.
This mirrors the Elixir GameState structure from the server.
-}

import Dict exposing (Dict)
import Set exposing (Set)



-- REMOTE DATA PATTERN


{-| RemoteData pattern for handling async data from server
-}
type RemoteData error data
    = NotAsked
    | Loading
    | Success data
    | Failure error



-- PLAYER VIEW (from Gleam)
-- Clean ADT matching what Gleam sends


{-| Player-specific view of the game
This is what gets sent from the server - clean, minimal, typed
-}
type PlayerView
    = PlayingView PlayingData
    | ShopView ShopData
    | GameOverView GameOverData


{-| Playing state during a round
-}
type alias PlayingData =
    { yourHand : List Card
    , yourDrawPile : List Card
    , yourLives : Int
    , yourHandsRemaining : Int
    , yourDiscardsRemaining : Int
    , yourCurrentScore : Int
    , yourLockedInHand : Maybe (List Card)
    , yourFaceDownCardIds : List String
    , yourDisabledRanks : List Int
    , yourDisabledSuits : List Suit
    , yourEnhancementsDisabled : Bool
    , yourActiveDebuffs : List HandType
    , yourScrambled : Bool
    , yourSupplyChainLimited : Bool
    , yourSkillTree : SkillTree
    , opponentName : String
    , opponentHand : List Card
    , opponentLives : Int
    , opponentHandsRemaining : Int
    , opponentDiscardsRemaining : Int
    , opponentCurrentScore : Int
    , opponentLockedInHand : Maybe (List Card)
    , opponentFaceDownCardIds : List String
    , opponentDisabledRanks : List Int
    , opponentDisabledSuits : List Suit
    , opponentEnhancementsDisabled : Bool
    , opponentActiveDebuffs : List HandType
    , opponentScrambled : Bool
    , opponentSupplyChainLimited : Bool
    , roundNumber : Int
    , handsPerRound : Int
    , discardsPerRound : Int
    , initialLives : Int
    , pendingAnimation : Maybe HandResultAnimation
    }


{-| Shop view data - shown to both players during shop phase
-}
type alias ShopData =
    { shopState : ShopState
    , availableCards : List ShopCard
    , yourPlayerId : String
    , yourName : String
    , yourLives : Int
    , yourSkillTree : SkillTree
    , opponentPlayerId : String
    , opponentName : String
    , opponentLives : Int
    , opponentSkillTree : SkillTree
    , currentRound : Int
    , totalRounds : Int
    , initialLives : Int
    }


{-| Game over state
-}
type alias GameOverData =
    { yourName : String
    , opponentName : String
    , winnerName : String
    , youWon : Bool
    , yourFinalLives : Int
    , opponentFinalLives : Int
    , yourReady : Bool
    , opponentReady : Bool
    }


{-| Individual player state
-}
type alias PlayerState =
    { playerId : String
    , lives : Int
    , cardPiles : CardPiles
    , skillTree : SkillTree
    , handsRemaining : Int
    , discardsRemaining : Int
    , currentRoundScore : Int
    , lockedInHand : Maybe (List Card)
    , readyForNextRound : Bool
    , status : PlayerStatus
    , activeDebuffs : List HandType
    , scrambled : Bool
    , faceDownCardIds : List String
    , disabledRanks : List Int
    , disabledSuits : List Suit
    , enhancementsDisabled : Bool
    , supplyChainLimited : Bool
    }


type PlayerStatus
    = PlayerActive
    | PlayerEliminated


{-| Card piles for a player's deck
-}
type alias CardPiles =
    { handPile : List Card
    , drawPile : List Card
    , discardPile : List Card
    }


{-| Result of a played hand
-}
type alias HandResult =
    { hand : List Card
    , handType : HandType
    , score : Int
    , scoreBreakdown : ScoreBreakdown
    , disabledRanks : List Int
    , disabledSuits : List Suit
    , enhancementsDisabled : Bool
    }


{-| Score calculation breakdown
-}
type alias ScoreBreakdown =
    { baseChips : Int
    , baseMultiplier : Int
    , totalChips : Int
    , totalMultiplier : Int
    , cardBreakdowns : List CardBreakdown
    }


{-| Per-card breakdown in scoring
-}
type alias CardBreakdown =
    { card : Card
    , chipValue : Int
    , bonusChips : Int
    , bonusMult : Int
    , disabled : Bool
    }


{-| Hand result animation data
-}
type alias HandResultAnimation =
    { yourHand : List Card
    , yourHandType : String
    , yourScore : Int
    , yourBreakdown : ScoreBreakdown
    , opponentHand : List Card
    , opponentHandType : String
    , opponentScore : Int
    , opponentBreakdown : ScoreBreakdown
    }



-- CARD TYPES


{-| Card rank - fully typed, matches Gleam!
-}
type Rank
    = Two
    | Three
    | Four
    | Five
    | Six
    | Seven
    | Eight
    | Nine
    | Ten
    | Jack
    | Queen
    | King
    | Ace


{-| A playing card with rank, suit, ID, and optional enhancement
-}
type alias Card =
    { id : String
    , rank : Rank
    , suit : Suit
    , enhancement : Maybe Enhancement
    }


type Suit
    = Hearts
    | Diamonds
    | Clubs
    | Spades


type Enhancement
    = BonusChips Int
    | BonusMult Int


type HandType
    = HighCard
    | Pair
    | TwoPair
    | ThreeOfAKind
    | Straight
    | Flush
    | FullHouse
    | FourOfAKind
    | StraightFlush



-- SKILL TREE


{-| Skill tree with levels for each hand type
-}
type alias SkillTree =
    { highCard : Int
    , pair : Int
    , twoPair : Int
    , threeOfAKind : Int
    , straight : Int
    , flush : Int
    , fullHouse : Int
    , fourOfAKind : Int
    , straightFlush : Int
    }



-- SHOP TYPES


{-| Shop state for upgrade rounds
-}
type alias ShopState =
    { totalRounds : Int
    , currentRound : Int
    , firstPickerId : String
    , secondPickerId : String
    , firstPickMade : Bool
    , secondPickMade : Bool
    , availableCards : List ShopCard
    , pickedCardIds : List String
    , pendingDeckBuilder : Maybe PendingDeckBuilder
    , pendingPlusBomb : Maybe PendingPlusBomb
    , destroyPhaseComplete : Bool
    , destroyerId : Maybe String
    , destroysAllowed : Int
    , destroyedCardIds : List String
    }


type ResearchCard
    = LevelUpCard HandType


type CounterCard
    = DenialCard HandType


type LogisticsCard
    = FortifyCard Int Int -- amount, max_cards
    | AmplifyCard Int Int -- amount, max_cards
    | SupplyDropCard Int -- max_cards
    | DischargeCard Int -- max_cards
    | CamoCard Suit Int -- suit, max_cards
    | PromoteCard Int -- max_cards


type SabotageCard
    = ScramblerCard
    | PlusBombCard Int -- max_cards
    | StaticFieldCard
    | SupplyChainCard


type CardKind
    = Research ResearchCard
    | Counter CounterCard
    | Logistics LogisticsCard
    | Sabotage SabotageCard


type alias ShopCard =
    { id : String
    , kind : CardKind
    }


type alias PendingDeckBuilder =
    { playerId : String
    , shopCardId : String
    , deckBuilderCard : ShopCard
    , availableCards : List Card
    }


type alias PendingPlusBomb =
    { playerId : String
    , shopCardId : String
    , availableCards : List Card
    }



-- SHOP UI STATE (CLIENT-ONLY)


{-| Complete UI state for the shop system.
Represents all possible states the player can be in during the shop phase.
This is CLIENT-SIDE ONLY - derived from server ShopState on every update.
-}
type ShopUIState
    = DestroyPhase DestroyPhaseData
    | WaitingForOpponent WaitingData
    | BrowsingCards BrowsingData
    | PreviewingCard PreviewCardData
    | SelectingDeckBuilderCards DeckBuilderSelectionData
    | SelectingPlusBombCard PlusBombSelectionData
    | ShopComplete CompletionData


{-| Data for destroy phase
-}
type alias DestroyPhaseData =
    { isMyTurn : Bool
    , destroysRemaining : Int
    , availableCards : List ShopCard
    , destroyedCardIds : List String
    }


{-| Data for waiting on opponent
-}
type alias WaitingData =
    { reason : WaitingReason
    , availableCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    }


type WaitingReason
    = OpponentDestroying
    | OpponentPicking


{-| Data for browsing available cards (my turn, no preview)
-}
type alias BrowsingData =
    { availableCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    }


{-| Data for previewing a regular card (LevelUp, Denial, basic Sabotage)
-}
type alias PreviewCardData =
    { cardId : String
    , card : ShopCard
    , availableCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    , isDestroyMode : Bool -- True if previewing during destroy phase
    , skillTree : SkillTree -- Player's skill tree for showing upgrade details
    }


{-| Data for selecting deck builder cards
-}
type alias DeckBuilderSelectionData =
    { cardId : String
    , deckBuilderCard : ShopCard
    , availableCards : List Card
    , selectedCardIds : List String -- Changed from Set to List to preserve selection order
    , maxSelection : Int
    , availableShopCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    }


{-| Data for selecting plus bomb card
-}
type alias PlusBombSelectionData =
    { cardId : String
    , availableCards : List Card
    , selectedCardId : Maybe String
    , availableShopCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    }


{-| Data for shop completion state
-}
type alias CompletionData =
    { availableCards : List ShopCard
    , pickedCardIds : List String
    , destroyedCardIds : List String
    }



-- SCORE ANIMATION STATE (CLIENT-ONLY)


{-| Score animation phase - matches LiveView animation phases
-}
type ScoreAnimationPhase
    = AnimationIdle
    | OpponentBase
    | OpponentCards
    | OpponentFinal
    | PlayerBase
    | PlayerCards
    | PlayerFinal
    | AnimationComplete


{-| Score animation state
-}
type alias ScoreAnimationState =
    { phase : ScoreAnimationPhase
    , cardIndex : Int
    , nextStepTime : Maybe Int -- Timestamp when next animation step should occur
    }



-- LEGACY GAME STATE (for original view helpers)
-- This is reconstructed from PlayerView for backward compatibility


{-| Full game state - LEGACY type for original view helpers
We reconstruct this from PlayerView data using adapters
-}
type alias GameState =
    { roundNumber : Int
    , playerNames : Dict String String
    , players : Dict String PlayerState
    , phase : GamePhase
    , gameStatus : GameStatus
    , lastHandResults : Maybe (Dict String HandResult)
    , roundHandHistory : List (Dict String HandResult)
    , winnerId : Maybe String
    , lastRoundWinnerId : Maybe String
    , shopState : Maybe ShopState
    , shopRounds : Int
    , initialLives : Int
    , handsPerRound : Int
    , discardsPerRound : Int
    }


type GamePhase
    = Playing


type GameStatus
    = Active
    | GameOver



-- UI STATE (CLIENT-ONLY)


{-| Main application model
-}
type alias Model =
    { gameId : String
    , playerId : Maybe String
    , gameState : RemoteData String PlayerView
    , viewingModal : Maybe Modal
    , selectedCards : Set String
    , newCardIds : Set String
    , acknowledgedEventSeq : Int
    , connectionStatus : ConnectionStatus
    , cardSort : CardSort
    , previewingCardIndex : Maybe Int -- TODO: Remove after migration
    , deckBuilderSelection : List String -- TODO: Remove after migration
    , plusBombSelection : Maybe String -- TODO: Remove after migration
    , shopUIState : Maybe ShopUIState -- NEW: Unified shop state
    , scoreAnimation : ScoreAnimationState -- Score animation state
    , viewingResults : Bool -- Whether we're viewing hand results
    , shopCountdown : Maybe Int -- Countdown timer for shop completion (seconds remaining)
    , currentAnimationData : Maybe HandResultAnimation -- Current animation data from server
    }


type Modal
    = GameLog
    | PlayerDeck String
    | PlayerLevels
    | ShopModal


type ConnectionStatus
    = Disconnected
    | Connecting
    | Connected


type CardSort
    = ByRank
    | BySuit



-- MESSAGES


type Msg
    = -- Channel messages
      ReceivedGameState PlayerView
    | GameStateUpdated PlayerView
    | RematchGameReady String
    | ChannelError String
    | ConnectionStatusChanged ConnectionStatus
      -- User actions
    | ToggleCardSelection String
    | ToggleCardSort
    | LockInHand
    | DiscardCards (List String)
      -- Score animation
    | AdvanceScoreAnimation Int -- Takes current time in milliseconds
    | DismissResults
      -- Shop actions
    | MakeShopPick String
    | PreviewShopCard String
    | ClearCardPreview
    | ConfirmDeckBuilder String
    | ConfirmPlusBomb String
    | ToggleDeckCardSelection String -- NEW: Toggle deck builder card selection
    | SelectPlusBombCard String
    | ConfirmSelection -- NEW: Unified confirm for selections
    | CancelSelection -- NEW: Cancel/skip selection
      -- OLD (to be removed after migration):
    | PreviewDeckBuilder String -- TODO: Remove
    | SelectDeckCard String -- TODO: Remove (replaced by ToggleDeckCardSelection)
    | CompleteDeckBuilderSelection (List String) -- TODO: Remove (replaced by ConfirmSelection)
    | SkipDeckBuilderSelection -- TODO: Remove (replaced by CancelSelection)
    | PreviewPlusBomb String -- TODO: Remove
    | CompletePlusBombSelection String -- TODO: Remove (replaced by ConfirmSelection)
      -- Destroy phase
    | DestroyShopCard String
    | CompleteDestroyPhase
      -- Shop countdown
    | ShopCountdownTick
      -- Rematch
    | RequestRematch
      -- Modal actions
    | OpenModal Modal
    | CloseModal
      -- No-op
    | NoOp



-- HELPER FUNCTIONS


{-| Get a player's current hand from their card piles
-}
getPlayerHand : PlayerState -> List Card
getPlayerHand player =
    player.cardPiles.handPile


{-| Get a player's full deck (all cards combined)
-}
getPlayerDeck : PlayerState -> List Card
getPlayerDeck player =
    player.cardPiles.handPile
        ++ player.cardPiles.drawPile
        ++ player.cardPiles.discardPile


{-| Check if a card is selected
-}
isCardSelected : Set String -> Card -> Bool
isCardSelected selectedCards card =
    Set.member card.id selectedCards


{-| Check if a card is newly drawn (should be highlighted)
-}
isNewCard : Set String -> Card -> Bool
isNewCard newCardIds card =
    Set.member card.id newCardIds


{-| Check if a card is face down
-}
isCardFaceDown : PlayerState -> Card -> Bool
isCardFaceDown player card =
    List.member card.id player.faceDownCardIds


{-| Get the current player (you) from GameState
Updated to take GameState and playerId directly
-}
getCurrentPlayer : GameState -> String -> Maybe PlayerState
getCurrentPlayer gameState playerId =
    Dict.get playerId gameState.players


{-| Get the opponent player from GameState
Updated to take GameState and playerId directly
-}
getOpponentPlayer : GameState -> String -> Maybe PlayerState
getOpponentPlayer gameState playerId =
    gameState.players
        |> Dict.toList
        |> List.filter (\( id, _ ) -> id /= playerId)
        |> List.head
        |> Maybe.map Tuple.second


{-| Get player name by ID from GameState
-}
getPlayerName : GameState -> String -> String
getPlayerName gameState playerId =
    Dict.get playerId gameState.playerNames
        |> Maybe.withDefault "Player"


{-| Check if it's the player's turn in the shop
-}
isPlayerTurnInShop : Maybe ShopState -> String -> Bool
isPlayerTurnInShop maybeShopState playerId =
    case maybeShopState of
        Just shopState ->
            if not shopState.destroyPhaseComplete then
                -- During destroy phase, only destroyer can act
                shopState.destroyerId == Just playerId

            else if not shopState.firstPickMade then
                -- First picker's turn
                shopState.firstPickerId == playerId

            else if not shopState.secondPickMade then
                -- Second picker's turn
                shopState.secondPickerId == playerId

            else
                -- Both players have picked
                False

        Nothing ->
            False


{-| Check if shop is complete (all rounds done and both players picked)
-}
isShopComplete : Maybe ShopState -> Bool
isShopComplete maybeShopState =
    case maybeShopState of
        Just shopState ->
            shopState.currentRound
                == shopState.totalRounds
                && shopState.firstPickMade
                && shopState.secondPickMade

        Nothing ->
            True


{-| Get the card rank display string
-}
rankToString : Rank -> String
rankToString rank =
    case rank of
        Two ->
            "2"

        Three ->
            "3"

        Four ->
            "4"

        Five ->
            "5"

        Six ->
            "6"

        Seven ->
            "7"

        Eight ->
            "8"

        Nine ->
            "9"

        Ten ->
            "10"

        Jack ->
            "J"

        Queen ->
            "Q"

        King ->
            "K"

        Ace ->
            "A"


{-| Get the numeric value of a rank (for comparison/sorting)
-}
rankValue : Rank -> Int
rankValue rank =
    case rank of
        Two ->
            2

        Three ->
            3

        Four ->
            4

        Five ->
            5

        Six ->
            6

        Seven ->
            7

        Eight ->
            8

        Nine ->
            9

        Ten ->
            10

        Jack ->
            11

        Queen ->
            12

        King ->
            13

        Ace ->
            14


{-| Get the hand type display string
-}
handTypeToString : HandType -> String
handTypeToString handType =
    case handType of
        HighCard ->
            "High Card"

        Pair ->
            "Pair"

        TwoPair ->
            "Two Pair"

        ThreeOfAKind ->
            "Three of a Kind"

        Straight ->
            "Straight"

        Flush ->
            "Flush"

        FullHouse ->
            "Full House"

        FourOfAKind ->
            "Four of a Kind"

        StraightFlush ->
            "Straight Flush"
