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



-- GAME TYPES


{-| Complete game state from server
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
    | RoundEnd


type GameStatus
    = Active
    | GameOver


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
    , totalScore : Int
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



-- CARD TYPES


{-| A playing card with rank, suit, ID, and optional enhancement
-}
type alias Card =
    { id : String
    , rank : Int
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
    , pickedCardIndices : List Int
    , pendingDeckBuilder : Maybe PendingDeckBuilder
    , pendingPlusBomb : Maybe PendingPlusBomb
    , destroyPhaseComplete : Bool
    , destroyerId : Maybe String
    , destroysAllowed : Int
    , destroyedCardIndices : List Int
    }


type alias ShopCard =
    { cardType : ShopCardType
    , subtype : String
    , name : String
    , description : String
    , cost : Int
    , metadata : Maybe ShopCardMetadata
    }


type ShopCardType
    = LevelUp
    | Denial
    | Sabotage
    | DeckBuilder


type alias ShopCardMetadata =
    { amount : Maybe Int
    , suit : Maybe Suit
    }


type alias PendingDeckBuilder =
    { playerId : String
    , shopCardIndex : Int
    , deckBuilderCard : ShopCard
    , availableCards : List Card
    }


type alias PendingPlusBomb =
    { playerId : String
    , shopCardIndex : Int
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
    , destroyedIndices : List Int
    }


{-| Data for waiting on opponent
-}
type alias WaitingData =
    { reason : WaitingReason
    , availableCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }


type WaitingReason
    = OpponentDestroying
    | OpponentPicking


{-| Data for browsing available cards (my turn, no preview)
-}
type alias BrowsingData =
    { availableCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }


{-| Data for previewing a regular card (LevelUp, Denial, basic Sabotage)
-}
type alias PreviewCardData =
    { cardIndex : Int
    , card : ShopCard
    , availableCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }


{-| Data for selecting deck builder cards
-}
type alias DeckBuilderSelectionData =
    { cardIndex : Int
    , deckBuilderCard : ShopCard
    , availableCards : List Card
    , selectedCardIds : Set String
    , maxSelection : Int
    , availableShopCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }


{-| Data for selecting plus bomb card
-}
type alias PlusBombSelectionData =
    { cardIndex : Int
    , availableCards : List Card
    , selectedCardId : Maybe String
    , availableShopCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }


{-| Data for shop completion state
-}
type alias CompletionData =
    { availableCards : List ShopCard
    , pickedIndices : List Int
    , destroyedIndices : List Int
    }



-- UI STATE (CLIENT-ONLY)


{-| Main application model
-}
type alias Model =
    { gameId : String
    , playerId : Maybe String
    , gameState : RemoteData String GameState
    , viewingModal : Maybe Modal
    , selectedCards : Set String
    , newCardIds : Set String
    , acknowledgedEventSeq : Int
    , connectionStatus : ConnectionStatus
    , cardSort : CardSort
    , previewingCardIndex : Maybe Int  -- TODO: Remove after migration
    , deckBuilderSelection : List String  -- TODO: Remove after migration
    , plusBombSelection : Maybe String  -- TODO: Remove after migration
    , shopUIState : Maybe ShopUIState  -- NEW: Unified shop state
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
      ReceivedGameState GameState
    | GameStateUpdated GameState
    | ChannelError String
    | ConnectionStatusChanged ConnectionStatus
      -- User actions
    | ToggleCardSelection String
    | ToggleCardSort
    | LockInHand
    | DiscardCards (List String)
      -- Shop actions
    | MakeShopPick Int
    | PreviewShopCard Int
    | ClearCardPreview
    | ConfirmDeckBuilder Int
    | ConfirmPlusBomb Int
    | ToggleDeckCardSelection String  -- NEW: Toggle deck builder card selection
    | SelectPlusBombCard String
    | ConfirmSelection  -- NEW: Unified confirm for selections
    | CancelSelection  -- NEW: Cancel/skip selection
      -- OLD (to be removed after migration):
    | PreviewDeckBuilder Int  -- TODO: Remove
    | SelectDeckCard String  -- TODO: Remove (replaced by ToggleDeckCardSelection)
    | CompleteDeckBuilderSelection (List String)  -- TODO: Remove (replaced by ConfirmSelection)
    | SkipDeckBuilderSelection  -- TODO: Remove (replaced by CancelSelection)
    | PreviewPlusBomb Int  -- TODO: Remove
    | CompletePlusBombSelection String  -- TODO: Remove (replaced by ConfirmSelection)
      -- Destroy phase
    | DestroyShopCard Int
    | CompleteDestroyPhase
    | ReadyForNextRound
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


{-| Get the current player (you)
-}
getCurrentPlayer : Model -> Maybe PlayerState
getCurrentPlayer model =
    case ( model.gameState, model.playerId ) of
        ( Success gameState, Just playerId ) ->
            Dict.get playerId gameState.players

        _ ->
            Nothing


{-| Get the opponent player
-}
getOpponentPlayer : Model -> Maybe PlayerState
getOpponentPlayer model =
    case ( model.gameState, model.playerId ) of
        ( Success gameState, Just playerId ) ->
            gameState.players
                |> Dict.toList
                |> List.filter (\( id, _ ) -> id /= playerId)
                |> List.head
                |> Maybe.map Tuple.second

        _ ->
            Nothing


{-| Get player name by ID
-}
getPlayerName : GameState -> String -> String
getPlayerName gameState playerId =
    Dict.get playerId gameState.playerNames
        |> Maybe.withDefault "Unknown"


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
            shopState.currentRound == shopState.totalRounds
                && shopState.firstPickMade
                && shopState.secondPickMade

        Nothing ->
            True


{-| Get the card rank display string
-}
rankToString : Int -> String
rankToString rank =
    case rank of
        11 ->
            "J"

        12 ->
            "Q"

        13 ->
            "K"

        14 ->
            "A"

        _ ->
            String.fromInt rank


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
