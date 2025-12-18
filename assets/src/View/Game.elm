module View.Game exposing (viewGame)

{-| Main game view matching LiveView styling
-}

import Dict exposing (Dict)
import Helpers exposing (buildGameState, isDeckBuilderCard, isDenialCard, isLevelUpCard, isPlusBombCard, isSabotageCard, levelUpHandType, shopCardDescription, shopCardId, shopCardName)
import Heroicons.Outline
import Heroicons.Solid
import Html exposing (Html, button, div, h1, h2, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class, classList, disabled, style)
import Html.Events exposing (onClick, stopPropagationOn)
import Json.Decode as D
import Set exposing (Set)
import Svg.Attributes as SvgAttr
import Types exposing (..)
import View.Cards as Cards
import View.PlayerInfo as PlayerInfo


{-| Main game view
-}
viewGame : Model -> Html Msg
viewGame model =
    case model.gameState of
        NotAsked ->
            viewLoading "Initializing game..."

        Loading ->
            viewLoading "Loading game state..."

        Failure err ->
            viewError err

        Success playerView ->
            viewPlayerView model playerView


{-| View loading state
-}
viewLoading : String -> Html Msg
viewLoading message =
    div [ class "min-h-screen bg-[#161B1F] flex items-center justify-center" ]
        [ div [ class "text-white text-2xl" ] [ text message ]
        ]


{-| View error state
-}
viewError : String -> Html Msg
viewError err =
    div [ class "min-h-screen bg-[#1a1d29] flex items-center justify-center" ]
        [ div [ class "bg-red-900 text-red-200 p-6 rounded-lg max-w-md" ]
            [ h2 [ class "text-xl font-bold mb-4" ] [ text "Error" ]
            , p [] [ text err ]
            ]
        ]


{-| View the player-specific view from Gleam
Pattern matches on the different PlayerView variants and builds fake GameState to call original helpers
-}
viewPlayerView : Model -> PlayerView -> Html Msg
viewPlayerView model playerView =
    case playerView of
        ShopView shopData ->
            -- Handle shop view directly without GameState conversion
            viewShop model shopData

        _ ->
            let
                -- Build fake GameState from PlayerView using adapter
                gameState =
                    buildGameState model playerView
            in
            -- Call the ORIGINAL viewGameState with fake GameState
            viewGameState model gameState


{-| View the active game state with LiveView-style layout (ORIGINAL)
This is the main layout function from the original code
-}
viewGameState : Model -> GameState -> Html Msg
viewGameState model gameState =
    let
        playerId =
            Maybe.withDefault "you" model.playerId

        maybeCurrentPlayer =
            getCurrentPlayer gameState playerId

        maybeOpponent =
            getOpponentPlayer gameState playerId
    in
    case ( maybeCurrentPlayer, maybeOpponent, model.playerId ) of
        ( Just currentPlayer, Just opponent, Just actualPlayerId ) ->
            let
                playerName =
                    getPlayerName gameState actualPlayerId

                opponentName =
                    getPlayerName gameState opponent.playerId
            in
            -- Check game status and phase
            case ( gameState.gameStatus, model.viewingResults ) of
                ( GameOver, False ) ->
                    -- Full-screen match summary (only after animation completes)
                    viewMatchSummary model gameState actualPlayerId playerName currentPlayer opponent opponentName

                _ ->
                    -- Normal game layout
                    div [ class "flex flex-col h-screen-safe bg-[#1a1d29] overflow-hidden" ]
                        [ -- Top - Opponent Cards
                          div [ class "shrink-0 flex flex-col justify-end pt-2 px-0 pb-1 sm:pt-2 sm:px-3 sm:pb-3 bg-[#0C0F14]" ]
                            [ viewOpponentCards opponent model.newCardIds model.cardSort
                            ]
                        , -- Middle - Playing Area
                          div [ class "flex-1 min-h-0 flex flex-col bg-[#161B1F] shadow-[0_0_30px_-5px_rgba(0,0,0,0.5)] relative" ]
                            [ div [ class "flex-1 flex flex-col justify-center" ]
                                [ viewPlayingArea model gameState currentPlayer opponent actualPlayerId
                                ]
                            , viewTopRow gameState currentPlayer opponent opponentName playerName
                            , -- Badges at bottom of centerboard
                              viewCenterboardBadges currentPlayer opponent
                            , -- Console Buttons (absolute, centered vertically within centerboard)
                              viewConsoleButtons model.viewingModal model.playerId
                            ]
                        , -- Bottom - Player Cards
                          div [ class "shrink-0 flex flex-col justify-start pt-1 px-0 pb-0 sm:pt-3 sm:px-3 sm:pb-0 bg-[#0C0F14]" ]
                            [ viewPlayerCards currentPlayer model
                            ]
                        , -- Action Bar
                          viewActionBar currentPlayer model.selectedCards model.cardSort False
                        ]

        _ ->
            viewError "Unable to load player data"



-- ============================================================================
-- ADAPTER LAYER: Convert PlayerView data -> old view helper format
-- ============================================================================
-- These functions build fake PlayerState/GameState records from PlayerView
-- so we can reuse ALL the original view helpers without changing them
-- ============================================================================
-- ORIGINAL VIEW HELPERS (unchanged from before - 3700+ lines)
-- ============================================================================


{-| View opponent's cards at the top
-}
viewOpponentCards : PlayerState -> Set String -> CardSort -> Html Msg
viewOpponentCards opponent newCardIds cardSort =
    let
        sortedCards =
            sortCards cardSort opponent.cardPiles.handPile
    in
    div [ class "flex md:gap-3 lg:gap-4 justify-center px-2" ]
        (List.map
            (\card ->
                let
                    isNew =
                        Set.member card.id newCardIds

                    isFaceDown =
                        List.member card.id opponent.faceDownCardIds

                    isDisabled =
                        List.member (rankValue card.rank) opponent.disabledRanks
                            || List.member card.suit opponent.disabledSuits
                in
                div
                    [ classList
                        [ ( "w-[18%] md:w-auto md:flex-1 md:max-w-[112px] aspect-[5/7] -ml-[6%] md:ml-0 first:ml-0", True )
                        , ( "new-card", isNew )
                        ]
                    ]
                    [ Cards.viewCardImage
                        { card = card
                        , isFaceDown = isFaceDown
                        , showEnhancement = True
                        , compact = True
                        , disabled = isDisabled
                        , enhancementDisabled = opponent.enhancementsDisabled
                        }
                    ]
            )
            sortedCards
        )


{-| View player's cards at the bottom
-}
viewPlayerCards : PlayerState -> Model -> Html Msg
viewPlayerCards player model =
    let
        selectedCardIds =
            case player.lockedInHand of
                Just lockedCards ->
                    List.map .id lockedCards

                Nothing ->
                    Set.toList model.selectedCards

        isLockedIn =
            player.lockedInHand /= Nothing

        atLimit =
            List.length selectedCardIds >= 5

        sortedCards =
            sortCards model.cardSort player.cardPiles.handPile
    in
    div []
        [ div [ class "flex md:gap-3 lg:gap-4 justify-center px-2" ]
            (List.map
                (\card ->
                    let
                        isSelected =
                            List.member card.id selectedCardIds

                        isNew =
                            Set.member card.id model.newCardIds

                        isFaceDown =
                            List.member card.id player.faceDownCardIds

                        isDisabled =
                            List.member (rankValue card.rank) player.disabledRanks
                                || List.member card.suit player.disabledSuits

                        canSelect =
                            not (atLimit && not isSelected) && not isLockedIn
                    in
                    button
                        [ onClick (ToggleCardSelection card.id)
                        , disabled (not canSelect)
                        , classList
                            [ ( "w-[18%] md:w-auto md:flex-1 md:max-w-[112px] -ml-[6%] md:ml-0 first:ml-0 transition-all touch-manipulation", True )
                            , ( "-translate-y-2 md:-translate-y-3 lg:-translate-y-4", isSelected )
                            , ( "cursor-not-allowed brightness-50 contrast-75 saturate-50", not canSelect )
                            ]
                        ]
                        [ div
                            [ classList
                                [ ( "w-full aspect-[5/7]", True )
                                , ( "new-card", isNew )
                                ]
                            ]
                            [ Cards.viewCardImage
                                { card = card
                                , isFaceDown = isFaceDown
                                , showEnhancement = True
                                , compact = True
                                , disabled = isDisabled
                                , enhancementDisabled = player.enhancementsDisabled
                                }
                            ]
                        ]
                )
                sortedCards
            )
        ]


{-| Sort cards based on the current sort option
Matches Elixir's sort\_cards function exactly
-}
sortCards : CardSort -> List Card -> List Card
sortCards sortOption cards =
    case sortOption of
        ByRank ->
            -- Sort by descending rank, then by suit order as secondary
            List.sortWith
                (\a b ->
                    case compare (rankValue b.rank) (rankValue a.rank) of
                        EQ ->
                            compare (suitOrder a.suit) (suitOrder b.suit)

                        other ->
                            other
                )
                cards

        BySuit ->
            -- Sort by suit first, then by descending rank within each suit
            List.sortWith
                (\a b ->
                    case compare (suitOrder a.suit) (suitOrder b.suit) of
                        EQ ->
                            compare (rankValue b.rank) (rankValue a.rank)

                        other ->
                            other
                )
                cards


{-| Suit order for sorting (matches Elixir)
-}
suitOrder : Suit -> Int
suitOrder suit =
    case suit of
        Spades ->
            0

        Hearts ->
            1

        Clubs ->
            2

        Diamonds ->
            3


{-| View the sort button
-}
viewSortButton : CardSort -> Html Msg
viewSortButton currentSort =
    div [ class "hidden sm:flex justify-center mt-2 sm:mt-3" ]
        [ button
            [ onClick ToggleCardSort
            , class "px-3 py-1 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 touch-manipulation"
            ]
            [ span [ class "text-gray-500" ] [ text "Sorting by" ]
            , span [ class "font-semibold text-gray-800" ]
                [ text
                    (case currentSort of
                        ByRank ->
                            "Rank"

                        BySuit ->
                            "Suit"
                    )
                ]
            ]
        ]


{-| View the central playing area
-}
viewPlayingArea : Model -> GameState -> PlayerState -> PlayerState -> String -> Html Msg
viewPlayingArea model gameState currentPlayer opponent playerId =
    let
        opponentName =
            getPlayerName gameState opponent.playerId

        playerName =
            getPlayerName gameState playerId
    in
    case model.viewingModal of
        Just modal ->
            viewModal modal model gameState currentPlayer opponent playerId playerName opponentName

        Nothing ->
            -- Check if viewing animated score results
            if model.viewingResults then
                viewAnimatedScoreResults model gameState playerId playerName opponentName

            else
                div [ class "h-full flex flex-col items-center justify-center p-4 text-white" ]
                    [ -- Phase-specific content
                      case gameState.phase of
                        Playing ->
                            -- Check locked-in status
                            case ( currentPlayer.lockedInHand, opponent.lockedInHand ) of
                                ( Just playerHand, Nothing ) ->
                                    -- Player locked in, waiting for opponent
                                    viewWaitingForOpponent playerHand currentPlayer

                                ( Nothing, Just _ ) ->
                                    -- Opponent locked in, player hasn't
                                    viewOpponentLockedNotice

                                _ ->
                                    -- Neither or both locked in (both = waiting for server to process)
                                    text ""
                    ]


{-| View score differential
-}
viewScoreDifferential : PlayerState -> PlayerState -> String -> String -> Html Msg
viewScoreDifferential player opponent playerName opponentName =
    let
        playerScore =
            player.currentRoundScore

        opponentScore =
            opponent.currentRoundScore

        scoreDiff =
            abs (playerScore - opponentScore)

        roundComplete =
            player.handsRemaining == 0
    in
    if scoreDiff > 0 then
        div [ class "text-sm opacity-70 mt-1" ]
            [ if playerScore > opponentScore then
                span []
                    [ span [ class "text-sky-400" ] [ text playerName ]
                    , text
                        (if roundComplete then
                            " wins by " ++ String.fromInt scoreDiff ++ " " ++ pluralize "point" "points" scoreDiff

                         else
                            " is ahead by " ++ String.fromInt scoreDiff ++ " " ++ pluralize "point" "points" scoreDiff
                        )
                    ]

              else
                span []
                    [ span [ class "text-orange-400" ] [ text opponentName ]
                    , text
                        (if roundComplete then
                            " wins by " ++ String.fromInt scoreDiff ++ " " ++ pluralize "point" "points" scoreDiff

                         else
                            " is ahead by " ++ String.fromInt scoreDiff ++ " " ++ pluralize "point" "points" scoreDiff
                        )
                    ]
            ]

    else
        text ""


pluralize : String -> String -> Int -> String
pluralize singular plural count =
    if count == 1 then
        singular

    else
        plural


{-| View when player has locked in but opponent hasn't
-}
viewWaitingForOpponent : List Card -> PlayerState -> Html Msg
viewWaitingForOpponent lockedHand player =
    let
        sortedHand =
            lockedHand
                |> List.sortWith (\a b -> compare (rankValue b.rank) (rankValue a.rank))
    in
    div [ class "text-center space-y-4 sm:space-y-8 px-2 sm:px-0" ]
        [ -- Opponent placeholder section
          div []
            [ div [ class "text-xs sm:text-sm text-base-content/50 mb-1 sm:mb-2" ]
                [ text "Waiting for opponent..." ]
            , div [ class "flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3" ]
                (List.map
                    (\_ ->
                        div [ class "w-9 h-[52px] sm:w-16 sm:h-24 opacity-0" ] []
                    )
                    sortedHand
                )
            , div [ class "h-5 sm:h-7" ] []
            ]
        , -- Player's locked hand
          div []
            [ div [ class "text-xs sm:text-sm text-base-content/80 mb-1 sm:mb-2" ] [ text "\u{00A0}" ]
            , div [ class "flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3" ]
                (List.map
                    (\card ->
                        let
                            isDisabled =
                                List.member (rankValue card.rank) player.disabledRanks
                                    || List.member card.suit player.disabledSuits

                            isFaceDown =
                                List.member card.id player.faceDownCardIds
                        in
                        div [ class "w-9 h-[52px] sm:w-16 sm:h-24" ]
                            [ Cards.viewCardImage
                                { card = card
                                , isFaceDown = isFaceDown
                                , showEnhancement = True
                                , compact = True
                                , disabled = isDisabled
                                , enhancementDisabled = player.enhancementsDisabled
                                }
                            ]
                    )
                    sortedHand
                )
            , div [ class "h-5 sm:h-7" ] []
            ]
        ]


{-| View when opponent has locked in but player hasn't
-}
viewOpponentLockedNotice : Html Msg
viewOpponentLockedNotice =
    div [ class "text-center text-base-content/50 text-sm" ]
        [ text "Opponent has locked in their hand" ]


{-| View hand results (shown briefly after hands are played)
-}
viewHandResults : Model -> GameState -> Dict String HandResult -> Html Msg
viewHandResults model gameState results =
    div [ class "bg-[#15161f] rounded-lg p-6 max-w-4xl" ]
        [ div [ class "grid grid-cols-2 gap-4" ]
            (results
                |> Dict.toList
                |> List.map
                    (\( playerId, result ) ->
                        div [ class "bg-[#1a1d29] rounded p-4 border border-gray-700" ]
                            [ div [ class "text-white font-bold mb-2" ]
                                [ text (getPlayerName gameState playerId) ]
                            , div [ class "text-gray-300 mb-2" ]
                                [ text (handTypeToString result.handType) ]
                            , div [ class "text-2xl font-bold text-blue-400" ]
                                [ text (String.fromInt result.score ++ " points") ]
                            ]
                    )
            )
        ]


{-| View game over screen - matches LiveView exactly
-}
viewGameOver : GameState -> Html Msg
viewGameOver gameState =
    text ""


{-| View animated score results - shows both players' hands with animated score breakdown
-}
viewAnimatedScoreResults : Model -> GameState -> String -> String -> String -> Html Msg
viewAnimatedScoreResults model gameState playerId playerName opponentName =
    case model.currentAnimationData of
        Just animData ->
            let
                -- Get player states for card rendering info
                maybeCurrentPlayer =
                    getCurrentPlayer gameState playerId

                maybeOpponent =
                    getOpponentPlayer gameState playerId

                -- Opponent shown first (top), player shown second (bottom)
                -- First animates → OpponentPhases → isFirstPlayer=true
                -- Second animates → PlayerPhases → isFirstPlayer=false
                firstAnimState =
                    getPlayerAnimationStateFromBreakdown model.scoreAnimation animData.opponentBreakdown True

                secondAnimState =
                    getPlayerAnimationStateFromBreakdown model.scoreAnimation animData.yourBreakdown False
            in
            div [ class "text-center space-y-8 sm:space-y-16 animate-fadeInScale w-full px-2 sm:px-4" ]
                [ -- Opponent (top)
                  case ( firstAnimState, maybeOpponent ) of
                    ( Just animState, Just opponent ) ->
                        viewScoreBreakdownRowFromAnimation
                            animData.opponentHand
                            animData.opponentHandType
                            animData.opponentScore
                            animData.opponentBreakdown
                            animData.opponentHandLevel
                            opponentName
                            False
                            animState
                            opponent

                    _ ->
                        text ""
                , -- Player (bottom)
                  case ( secondAnimState, maybeCurrentPlayer ) of
                    ( Just animState, Just currentPlayer ) ->
                        viewScoreBreakdownRowFromAnimation
                            animData.yourHand
                            animData.yourHandType
                            animData.yourScore
                            animData.yourBreakdown
                            animData.yourHandLevel
                            playerName
                            True
                            animState
                            currentPlayer

                    _ ->
                        text ""
                ]

        Nothing ->
            text ""


type alias AnimationState =
    { phase : ScoreAnimationPhase
    , cardsScored : Int
    , currentCard : Int
    }


{-| Format hand type string from backend (e.g., "high\_card" -> "High Card")
-}
formatHandTypeString : String -> String
formatHandTypeString handType =
    case handType of
        "high_card" ->
            "High Card"

        "pair" ->
            "Pair"

        "two_pair" ->
            "Two Pair"

        "three_of_a_kind" ->
            "Three of a Kind"

        "straight" ->
            "Straight"

        "flush" ->
            "Flush"

        "full_house" ->
            "Full House"

        "four_of_a_kind" ->
            "Four of a Kind"

        "straight_flush" ->
            "Straight Flush"

        _ ->
            handType


{-| Get skill level for a hand type from the skill tree
-}
getSkillLevelForHandType : SkillTree -> String -> Int
getSkillLevelForHandType skillTree handType =
    case handType of
        "high_card" ->
            skillTree.highCard

        "pair" ->
            skillTree.pair

        "two_pair" ->
            skillTree.twoPair

        "three_of_a_kind" ->
            skillTree.threeOfAKind

        "straight" ->
            skillTree.straight

        "flush" ->
            skillTree.flush

        "full_house" ->
            skillTree.fullHouse

        "four_of_a_kind" ->
            skillTree.fourOfAKind

        "straight_flush" ->
            skillTree.straightFlush

        _ ->
            1


{-| Get animation state from score breakdown (new animation system)
-}
getPlayerAnimationStateFromBreakdown : ScoreAnimationState -> ScoreBreakdown -> Bool -> Maybe AnimationState
getPlayerAnimationStateFromBreakdown globalAnim breakdown isFirstPlayer =
    let
        cardCount =
            List.length breakdown.cardBreakdowns

        opponentPhases =
            [ OpponentBase, OpponentCards, OpponentFinal ]

        playerPhases =
            [ PlayerBase, PlayerCards, PlayerFinal ]

        relevantPhases =
            if isFirstPlayer then
                opponentPhases

            else
                playerPhases
    in
    if globalAnim.phase == AnimationIdle then
        -- Show both hands with base scores from the start
        Just
            { phase = OpponentBase
            , cardsScored = 0
            , currentCard = 0
            }

    else if globalAnim.phase == AnimationComplete then
        Just
            { phase = OpponentFinal
            , cardsScored = cardCount
            , currentCard = cardCount - 1
            }

    else if List.member globalAnim.phase relevantPhases then
        let
            cardsScored =
                case globalAnim.phase of
                    OpponentBase ->
                        0

                    OpponentCards ->
                        globalAnim.cardIndex + 1

                    OpponentFinal ->
                        cardCount

                    PlayerBase ->
                        0

                    PlayerCards ->
                        globalAnim.cardIndex + 1

                    PlayerFinal ->
                        cardCount

                    _ ->
                        0
        in
        Just
            { phase = globalAnim.phase
            , cardsScored = cardsScored
            , currentCard = globalAnim.cardIndex
            }

    else if isFirstPlayer && List.member globalAnim.phase playerPhases then
        -- First player done, show final state
        Just
            { phase = OpponentFinal
            , cardsScored = cardCount
            , currentCard = cardCount - 1
            }

    else
        -- Second player waiting - show with base scores only (0 cards scored)
        Just
            { phase = PlayerBase
            , cardsScored = 0
            , currentCard = 0
            }


{-| View score breakdown from animation data (new animation system)
-}
viewScoreBreakdownRowFromAnimation : List Card -> String -> Int -> ScoreBreakdown -> Int -> String -> Bool -> AnimationState -> PlayerState -> Html Msg
viewScoreBreakdownRowFromAnimation hand handType score breakdown level playerName isCurrentPlayer animState playerState =
    let
        -- Sort cards by rank for display
        sortedHand =
            List.sortBy (\c -> ( -(rankValue c.rank), suitOrder c.suit )) hand

        sortedBreakdowns =
            List.sortBy (\b -> ( -(rankValue b.card.rank), suitOrder b.card.suit )) breakdown.cardBreakdowns

        scoringCardIds =
            Set.fromList (List.map (.card >> .id) sortedBreakdowns)

        -- Calculate running totals
        ( runningChips, runningMult ) =
            if animState.cardsScored == 0 then
                ( breakdown.baseChips, breakdown.baseMultiplier )

            else
                let
                    scoredBreakdowns =
                        List.take animState.cardsScored sortedBreakdowns

                    extraChips =
                        scoredBreakdowns
                            |> List.map (\b -> b.chipValue + b.bonusChips)
                            |> List.sum

                    extraMult =
                        scoredBreakdowns
                            |> List.map .bonusMult
                            |> List.sum
                in
                ( breakdown.baseChips + extraChips
                , breakdown.baseMultiplier + extraMult
                )

        showFinal =
            animState.phase == OpponentFinal || animState.phase == PlayerFinal || animState.phase == AnimationComplete

        runningScore =
            runningChips * runningMult

        handTypeText =
            "Lvl " ++ String.fromInt level ++ " " ++ formatHandTypeString handType
    in
    div []
        [ -- Hand type header
          div [ class "text-xs sm:text-sm text-base-content/80 mb-1 sm:mb-2" ]
            [ text handTypeText ]
        , -- Cards display
          div [ class "flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3" ]
            (List.indexedMap
                (\idx card ->
                    let
                        isScoring =
                            Set.member card.id scoringCardIds

                        scoringIndex =
                            sortedBreakdowns
                                |> List.indexedMap Tuple.pair
                                |> List.filter (\( _, b ) -> b.card.id == card.id)
                                |> List.head
                                |> Maybe.map Tuple.first

                        isCurrentlyScoring =
                            case scoringIndex of
                                Just si ->
                                    si == animState.cardsScored - 1 && (animState.phase == OpponentCards || animState.phase == PlayerCards)

                                Nothing ->
                                    False

                        cardClass =
                            if not isScoring then
                                "card-not-scoring"

                            else if Maybe.withDefault 999 scoringIndex < animState.cardsScored - 1 then
                                "card-scored"

                            else if isCurrentlyScoring then
                                "card-scoring"

                            else if Maybe.withDefault 999 scoringIndex < animState.cardsScored then
                                "card-scored"

                            else
                                ""

                        cardBreakdown =
                            if isCurrentlyScoring then
                                List.drop (animState.cardsScored - 1) sortedBreakdowns |> List.head

                            else
                                Nothing

                        -- Get actual card state from player
                        isDisabled =
                            List.member (rankValue card.rank) playerState.disabledRanks
                                || List.member card.suit playerState.disabledSuits
                    in
                    div [ class "relative" ]
                        [ div [ class ("w-9 h-[52px] sm:w-16 sm:h-24 " ++ cardClass) ]
                            [ Cards.viewCardImage
                                { card = card
                                , isFaceDown = False -- Always face-up during scoring animation
                                , showEnhancement = True
                                , compact = True
                                , disabled = isDisabled
                                , enhancementDisabled = playerState.enhancementsDisabled
                                }
                            ]
                        , case cardBreakdown of
                            Just cb ->
                                div []
                                    [ div [ class "chip-float chip-float-chips text-[10px] sm:text-sm" ]
                                        [ text ("+" ++ String.fromInt (cb.chipValue + cb.bonusChips)) ]
                                    , if cb.bonusMult > 0 then
                                        div [ class "chip-float chip-float-mult text-[10px] sm:text-sm" ]
                                            [ text ("+" ++ String.fromInt cb.bonusMult ++ "x") ]

                                      else
                                        text ""
                                    ]

                            Nothing ->
                                text ""
                        ]
                )
                sortedHand
            )
        , -- Formula display
          div [ class "flex items-center justify-center gap-2 sm:gap-3 text-sm sm:text-lg font-mono" ]
            [ span [ class "text-blue-400 font-bold" ] [ text (String.fromInt runningChips) ]
            , span [ class "text-base-content/60" ] [ text "×" ]
            , span [ class "text-red-400 font-bold" ] [ text (String.fromInt runningMult) ]
            , if showFinal then
                span [ class "text-base-content/60" ] [ text "=" ]

              else
                text ""
            , if showFinal then
                span [ class "text-yellow-400 font-bold text-base sm:text-xl score-reveal" ]
                    [ text (String.fromInt runningScore) ]

              else
                text ""
            ]
        ]


{-| View score breakdown for one player with animated cards and formula
-}
viewScoreBreakdownRow : HandResult -> SkillTree -> String -> Bool -> AnimationState -> Html Msg
viewScoreBreakdownRow result skillTree playerName isCurrentPlayer animState =
    let
        breakdown =
            result.scoreBreakdown

        -- Sort cards by rank for display
        sortedHand =
            List.sortBy (\c -> ( -(rankValue c.rank), suitOrder c.suit )) result.hand

        sortedBreakdowns =
            List.sortBy (\b -> ( -(rankValue b.card.rank), suitOrder b.card.suit )) breakdown.cardBreakdowns

        scoringCardIds =
            Set.fromList (List.map (.card >> .id) sortedBreakdowns)

        -- Calculate running totals
        ( runningChips, runningMult ) =
            if animState.cardsScored == 0 then
                ( breakdown.baseChips, breakdown.baseMultiplier )

            else
                let
                    scoredBreakdowns =
                        List.take animState.cardsScored sortedBreakdowns

                    extraChips =
                        scoredBreakdowns
                            |> List.map (\b -> b.chipValue + b.bonusChips)
                            |> List.sum

                    extraMult =
                        scoredBreakdowns
                            |> List.map .bonusMult
                            |> List.sum
                in
                ( breakdown.baseChips + extraChips
                , breakdown.baseMultiplier + extraMult
                )

        showFinal =
            animState.phase == OpponentFinal || animState.phase == PlayerFinal || animState.phase == AnimationComplete

        runningScore =
            runningChips * runningMult

        level =
            getSkillLevel skillTree result.handType

        handTypeText =
            "Lvl " ++ String.fromInt level ++ " " ++ String.toUpper (handTypeToString result.handType)
    in
    div []
        [ -- Hand type header
          div [ class "text-xs sm:text-sm text-base-content/80 mb-1 sm:mb-2" ]
            [ text handTypeText ]
        , -- Cards display
          div [ class "flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3" ]
            (List.indexedMap
                (\idx card ->
                    let
                        isScoring =
                            Set.member card.id scoringCardIds

                        scoringIndex =
                            sortedBreakdowns
                                |> List.indexedMap Tuple.pair
                                |> List.filter (\( _, b ) -> b.card.id == card.id)
                                |> List.head
                                |> Maybe.map Tuple.first

                        isCurrentlyScoring =
                            case scoringIndex of
                                Just si ->
                                    si == animState.cardsScored - 1 && (animState.phase == OpponentCards || animState.phase == PlayerCards)

                                Nothing ->
                                    False

                        cardClass =
                            if not isScoring then
                                "card-not-scoring"

                            else if Maybe.withDefault 999 scoringIndex < animState.cardsScored - 1 then
                                "card-scored"

                            else if isCurrentlyScoring then
                                "card-scoring"

                            else if Maybe.withDefault 999 scoringIndex < animState.cardsScored then
                                "card-scored"

                            else
                                ""

                        cardBreakdown =
                            if isCurrentlyScoring then
                                List.drop (animState.cardsScored - 1) sortedBreakdowns |> List.head

                            else
                                Nothing
                    in
                    div [ class "relative" ]
                        [ div [ class ("w-9 h-[52px] sm:w-16 sm:h-24 " ++ cardClass) ]
                            [ Cards.viewCardImage
                                { card = card
                                , isFaceDown = isCardFaceDown result card
                                , showEnhancement = True
                                , compact = True
                                , disabled =
                                    List.member (rankValue card.rank) result.disabledRanks
                                        || List.member card.suit result.disabledSuits
                                , enhancementDisabled = result.enhancementsDisabled
                                }
                            ]
                        , case cardBreakdown of
                            Just cb ->
                                div []
                                    [ div [ class "chip-float chip-float-chips text-[10px] sm:text-sm" ]
                                        [ text ("+" ++ String.fromInt (cb.chipValue + cb.bonusChips)) ]
                                    , if cb.bonusMult > 0 then
                                        div [ class "chip-float chip-float-mult text-[10px] sm:text-sm" ]
                                            [ text ("+" ++ String.fromInt cb.bonusMult ++ "x") ]

                                      else
                                        text ""
                                    ]

                            Nothing ->
                                text ""
                        ]
                )
                sortedHand
            )
        , -- Formula display
          div [ class "flex items-center justify-center gap-2 sm:gap-3 text-sm sm:text-lg font-mono" ]
            [ span [ class "text-blue-400 font-bold" ] [ text (String.fromInt runningChips) ]
            , span [ class "text-base-content/60" ] [ text "×" ]
            , span [ class "text-red-400 font-bold" ] [ text (String.fromInt runningMult) ]
            , if showFinal then
                span [ class "text-base-content/60" ] [ text "=" ]

              else
                text ""
            , if showFinal then
                span [ class "text-yellow-400 font-bold text-base sm:text-xl score-reveal" ]
                    [ text (String.fromInt runningScore) ]

              else
                text ""
            ]
        ]


isCardFaceDown : HandResult -> Card -> Bool
isCardFaceDown result card =
    False


{-| Get skill level for a hand type from the skill tree
-}
getSkillLevel : SkillTree -> HandType -> Int
getSkillLevel skillTree handType =
    case handType of
        HighCard ->
            skillTree.highCard

        Pair ->
            skillTree.pair

        TwoPair ->
            skillTree.twoPair

        ThreeOfAKind ->
            skillTree.threeOfAKind

        Straight ->
            skillTree.straight

        Flush ->
            skillTree.flush

        FullHouse ->
            skillTree.fullHouse

        FourOfAKind ->
            skillTree.fourOfAKind

        StraightFlush ->
            skillTree.straightFlush


{-| View match summary screen - full page with interactive rematch
-}
viewMatchSummary : Model -> GameState -> String -> String -> PlayerState -> PlayerState -> String -> Html Msg
viewMatchSummary model gameState playerId playerName playerState opponentState opponentName =
    let
        isWinner =
            gameState.winnerId == Just playerId

        playerReady =
            playerState.readyForNextRound

        opponentReady =
            opponentState.readyForNextRound

        bothReady =
            playerReady && opponentReady
    in
    div [ class "min-h-screen flex items-center justify-center bg-gradient-to-br from-base-300 via-base-200 to-base-100" ]
        [ div [ class "w-full max-w-2xl px-6" ]
            [ -- Header with emoji and title
              div [ class "text-center mb-8" ]
                [ div [ class "text-6xl mb-4" ]
                    [ text
                        (if isWinner then
                            "🏆"

                         else
                            "💀"
                        )
                    ]
                , h1 [ class "text-4xl font-bold text-base-content mb-2" ]
                    [ text
                        (if isWinner then
                            "Victory!"

                         else
                            "Defeat"
                        )
                    ]
                , p [ class "text-base-content/60" ]
                    [ text ("Match complete after " ++ String.fromInt gameState.roundNumber ++ " rounds") ]
                ]
            , -- Match result summary
              div [ class "text-center mb-8 text-lg text-base-content/80" ]
                [ let
                    winnerName =
                        if isWinner then
                            playerName

                        else
                            opponentName

                    loserName =
                        if isWinner then
                            opponentName

                        else
                            playerName

                    winnerLives =
                        if isWinner then
                            playerState.lives

                        else
                            opponentState.lives

                    -- Determine message based on lives remaining
                    ( verb, livesMessage ) =
                        if winnerLives == gameState.initialLives then
                            ( "absolutely stomped", "without losing a life" )

                        else if winnerLives == 1 then
                            ( "barely defeated", "with just one life remaining" )

                        else
                            ( "crushed", "with " ++ String.fromInt winnerLives ++ " lives remaining" )

                    -- Winner color: text-player if isWinner, text-opponent if opponent won
                    winnerColor =
                        if isWinner then
                            "text-player"

                        else
                            "text-opponent"

                    -- Loser color: text-opponent if isWinner, text-player if opponent won
                    loserColor =
                        if isWinner then
                            "text-opponent"

                        else
                            "text-player"
                  in
                  Html.span []
                    [ Html.span [ class ("font-bold " ++ winnerColor) ] [ text winnerName ]
                    , text (" " ++ verb ++ " ")
                    , Html.span [ class ("font-bold " ++ loserColor) ] [ text loserName ]
                    , text (" " ++ livesMessage)
                    ]
                ]
            , -- Rematch section
              viewRematchButton playerReady opponentReady playerName opponentName
            ]
        ]


{-| Interactive rematch button with glow states
-}
viewRematchButton : Bool -> Bool -> String -> String -> Html Msg
viewRematchButton playerReady opponentReady playerName opponentName =
    let
        -- Determine button styling based on ready states
        buttonState =
            case ( playerReady, opponentReady ) of
                ( True, True ) ->
                    -- Both ready - solid blue, show starting match
                    { bgClasses = "bg-blue-500 text-white"
                    , borderClasses = "border-blue-400"
                    , textContent = "Starting match..."
                    , clickable = False
                    , showFill = False
                    }

                ( True, False ) ->
                    -- Player ready - show fill animation
                    { bgClasses = "bg-white text-gray-900 relative overflow-hidden"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = False
                    , showFill = True
                    }

                ( False, True ) ->
                    -- Opponent ready - show fill animation
                    { bgClasses = "bg-white text-gray-900 relative overflow-hidden"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = True
                    , showFill = True
                    }

                ( False, False ) ->
                    -- Neither ready - white button with gray text
                    { bgClasses = "bg-white hover:bg-gray-50 text-gray-700 shadow-md hover:shadow-lg"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = True
                    , showFill = False
                    }

        onClick_ =
            if buttonState.clickable then
                onClick RequestRematch

            else
                onClick NoOp
    in
    div [ class "flex flex-col gap-2" ]
        [ button
            [ class ("w-full px-8 py-4 rounded-xl font-bold text-lg transition-all " ++ buttonState.bgClasses)
            , onClick_
            , disabled (not buttonState.clickable)
            ]
            [ -- Progress fill animation overlay
              if buttonState.showFill then
                div [ class "absolute inset-0 pointer-events-none rounded-xl overflow-hidden" ]
                    [ div
                        [ class "absolute inset-y-0 left-0 h-full bg-blue-500"
                        , Html.Attributes.style "animation" "progress-fill 0.5s ease-out forwards"
                        ]
                        []
                    ]

              else
                text ""
            , -- Button text with color animation when filling
              if buttonState.showFill then
                Html.span
                    [ class "relative z-10"
                    , Html.Attributes.style "animation" "text-to-white 0.5s ease-out forwards"
                    ]
                    [ text buttonState.textContent ]

              else
                Html.span [ class "relative z-10" ] [ text buttonState.textContent ]
            ]
        , -- Status text below button
          case ( playerReady, opponentReady ) of
            ( True, True ) ->
                div [ class "text-center text-sm text-base-content/60" ]
                    [ text "Both players ready!" ]

            ( True, False ) ->
                div [ class "text-center text-sm text-base-content/60" ]
                    [ text "You requested a rematch" ]

            ( False, True ) ->
                div [ class "text-center text-sm text-base-content/60" ]
                    [ text (opponentName ++ " requested a rematch") ]

            ( False, False ) ->
                text ""
        ]


{-| Player result card for match summary
-}
viewPlayerResultCard : String -> Int -> Int -> Bool -> String -> Html Msg
viewPlayerResultCard playerName lives initialLives isWinner colorClass =
    let
        livesRemaining =
            max 0 lives

        lostLives =
            initialLives - livesRemaining
    in
    div
        [ classList
            [ ( "rounded-xl p-6 border-2 bg-base-100 shadow-lg", True )
            , ( "border-success ring-2 ring-success/20", isWinner )
            , ( "border-base-300", not isWinner )
            ]
        ]
        [ h2 [ class ("text-xl font-bold mb-4 text-center " ++ colorClass) ]
            [ text playerName ]
        , if isWinner then
            div [ class "text-2xl font-bold text-success text-center mb-4" ]
                [ text "Winner" ]

          else
            div [ class "text-2xl font-bold text-error/60 text-center mb-4" ]
                [ text "Eliminated" ]
        , -- Hearts display
          div [ class "flex justify-center items-center gap-1.5 mb-3" ]
            (List.concat
                [ -- Filled hearts
                  if livesRemaining > 0 then
                    List.repeat livesRemaining
                        (Heroicons.Solid.heart [ SvgAttr.class "w-8 h-8 text-error" ])

                  else
                    []
                , -- Empty hearts
                  if lostLives > 0 then
                    List.repeat lostLives
                        (Heroicons.Outline.heart [ SvgAttr.class "w-8 h-8 text-base-content/20" ])

                  else
                    []
                ]
            )
        , -- Lives text
          div [ class "text-center text-base-content/50 text-xs" ]
            [ text (String.fromInt livesRemaining ++ "/" ++ String.fromInt initialLives ++ " lives") ]
        ]



{- ========== GAME VIEW HELPER FUNCTIONS ========== -}


{-| View console buttons (fixed at mid-left)
-}
viewConsoleButtons : Maybe Modal -> Maybe String -> Html Msg
viewConsoleButtons viewingModal playerId =
    let
        isDeckOpen =
            case viewingModal of
                Just (PlayerDeck _) ->
                    True

                _ ->
                    False

        isLevelsOpen =
            viewingModal == Just PlayerLevels

        isLogOpen =
            viewingModal == Just GameLog

        anyModalOpen =
            viewingModal /= Nothing
    in
    div
        [ classList
            [ ( "absolute left-px top-1/2 -translate-y-1/2 z-40", True )
            , ( "hidden", anyModalOpen )
            , ( "sm:block", True )
            ]
        ]
        [ div [ class "flex flex-col gap-2 sm:gap-3" ]
            [ button
                [ class "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
                , Html.Attributes.title "View Deck"
                , onClick
                    (if isDeckOpen then
                        CloseModal

                     else
                        case playerId of
                            Just pid ->
                                OpenModal (PlayerDeck pid)

                            Nothing ->
                                NoOp
                    )
                ]
                [ if isDeckOpen then
                    Heroicons.Solid.square3Stack3d [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-blue-600" ]

                  else
                    Heroicons.Outline.square3Stack3d [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-blue-600" ]
                ]
            , button
                [ class "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
                , Html.Attributes.title "View Levels"
                , onClick
                    (if isLevelsOpen then
                        CloseModal

                     else
                        OpenModal PlayerLevels
                    )
                ]
                [ if isLevelsOpen then
                    Heroicons.Solid.chartBar [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-green-600" ]

                  else
                    Heroicons.Outline.chartBar [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-green-600" ]
                ]
            , button
                [ class "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
                , Html.Attributes.title "View Log"
                , onClick
                    (if isLogOpen then
                        CloseModal

                     else
                        OpenModal GameLog
                    )
                ]
                [ if isLogOpen then
                    Heroicons.Solid.newspaper [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-amber-600" ]

                  else
                    Heroicons.Outline.newspaper [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-amber-600" ]
                ]
            ]
        ]


{-| View action bar at the bottom
-}
viewActionBar : PlayerState -> Set String -> CardSort -> Bool -> Html Msg
viewActionBar player selectedCards cardSort actionInProgress =
    let
        selectedCardsList =
            Set.toList selectedCards

        selectedCount =
            List.length selectedCardsList

        isLockedIn =
            player.lockedInHand /= Nothing

        canLockIn =
            selectedCount > 0 && not isLockedIn && not actionInProgress

        canDiscard =
            selectedCount > 0 && player.discardsRemaining > 0 && not isLockedIn && not actionInProgress
    in
    div [ class "flex items-center justify-center shrink-0 bg-[#0C0F14] px-2 py-2 md:py-3 lg:py-4" ]
        [ div [ class "flex items-center gap-2 w-full md:max-w-[980px] lg:max-w-[1008px]" ]
            [ button
                [ onClick (DiscardCards selectedCardsList)
                , disabled (not canDiscard)
                , classList
                    [ ( "flex-1 py-3 rounded-lg transition-colors text-xs md:text-sm font-semibold touch-manipulation shadow-lg ring-1 ring-white/10", True )
                    , ( "bg-red-600 hover:bg-red-700 text-white", canDiscard )
                    , ( "opacity-50 cursor-not-allowed bg-red-600/30 text-red-200", not canDiscard )
                    ]
                ]
                [ text "Discard" ]
            , button
                [ onClick ToggleCardSort
                , class "flex-1 py-3 rounded-lg text-xs md:text-sm bg-white/90 hover:bg-white transition-all flex items-center justify-center gap-1 touch-manipulation shadow-lg"
                ]
                [ span [ class "text-gray-500" ] [ text "Sort:" ]
                , span [ class "font-semibold text-gray-800" ]
                    [ text
                        (case cardSort of
                            ByRank ->
                                "Rank"

                            BySuit ->
                                "Suit"
                        )
                    ]
                ]
            , button
                [ onClick LockInHand
                , disabled (not canLockIn)
                , classList
                    [ ( "flex-1 py-3 rounded-lg transition-colors text-xs md:text-sm font-semibold touch-manipulation shadow-lg ring-1 ring-white/10", True )
                    , ( "bg-sky-600 hover:bg-sky-700 text-white", canLockIn )
                    , ( "opacity-50 cursor-not-allowed bg-sky-600/30 text-sky-200", not canLockIn )
                    ]
                ]
                [ text "Play" ]
            ]
        ]


{-| View top row with opponent info, hand progress, and player info
-}
viewTopRow : GameState -> PlayerState -> PlayerState -> String -> String -> Html Msg
viewTopRow gameState player opponent opponentName playerName =
    let
        initialLives =
            gameState.initialLives

        discardsPerRound =
            gameState.discardsPerRound

        playerScore =
            player.currentRoundScore

        opponentScore =
            opponent.currentRoundScore

        scoreDiff =
            abs (playerScore - opponentScore)

        playerWinning =
            playerScore > opponentScore && scoreDiff > 0

        opponentWinning =
            opponentScore > playerScore && scoreDiff > 0
    in
    div [ class "absolute top-2 sm:top-4 left-2 right-2 sm:left-4 sm:right-4 flex items-start justify-between z-10" ]
        [ div [ class "flex items-start gap-2" ]
            [ viewPlayerInfo player
                playerName
                initialLives
                discardsPerRound
                (if playerWinning then
                    scoreDiff

                 else
                    0
                )
            ]
        , viewTopCenterBar gameState player opponent
        , div [ class "flex items-start gap-2" ]
            [ viewOpponentInfo opponent
                opponentName
                initialLives
                discardsPerRound
                (if opponentWinning then
                    scoreDiff

                 else
                    0
                )
            ]
        ]


{-| View top center bar showing hand progress dots and score differential
-}
viewTopCenterBar : GameState -> PlayerState -> PlayerState -> Html Msg
viewTopCenterBar gameState player opponent =
    let
        totalHands =
            gameState.handsPerRound

        handsPlayed =
            totalHands - player.handsRemaining

        currentHand =
            handsPlayed + 1

        playerScore =
            player.currentRoundScore

        opponentScore =
            opponent.currentRoundScore

        scoreDiff =
            abs (playerScore - opponentScore)

        playerWinning =
            playerScore > opponentScore

        opponentWinning =
            opponentScore > playerScore
    in
    div [ class "flex items-center gap-1.5" ]
        (List.range 1 totalHands
            |> List.map
                (\handNum ->
                    let
                        isPast =
                            handNum < currentHand

                        isCurrent =
                            handNum == currentHand && player.handsRemaining > 0

                        isFuture =
                            handNum > currentHand
                    in
                    div
                        [ classList
                            [ ( "w-2 h-2 rounded-full transition-all", True )
                            , ( "bg-base-content", isPast )
                            , ( "bg-base-content animate-pulse ring-2 ring-base-content/50", isCurrent )
                            , ( "bg-base-content/30", isFuture )
                            ]
                        ]
                        []
                )
        )


{-| View opponent info overlay (top-right corner) - Mobile and Desktop
-}
viewOpponentInfo : PlayerState -> String -> Int -> Int -> Int -> Html Msg
viewOpponentInfo opponent opponentName initialLives discardsPerRound scoreDiff =
    div [ class "flex flex-col items-end gap-0.5 text-base-content" ]
        [ div [ class "flex flex-col-reverse sm:flex-row items-end sm:items-center gap-0.5 sm:gap-1" ]
            [ div [ class "flex items-center gap-0.5" ]
                (List.range 1 discardsPerRound
                    |> List.map
                        (\i ->
                            if i > discardsPerRound - opponent.discardsRemaining then
                                Heroicons.Solid.trash [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                            else
                                Heroicons.Outline.trash [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                        )
                )
            , span [ class "hidden sm:inline text-gray-500" ] [ text "·" ]
            , div [ class "flex items-center gap-0.5" ]
                (List.range 1 initialLives
                    |> List.map
                        (\i ->
                            if i > initialLives - opponent.lives then
                                Heroicons.Solid.heart [ SvgAttr.class "w-4 h-4 text-red-400" ]

                            else
                                Heroicons.Outline.heart [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                        )
                )
            ]
        , div [ class "flex items-center gap-3" ]
            [ if scoreDiff > 0 then
                span [ class "flex items-center gap-0 text-xs font-semibold text-opponent" ]
                    [ Heroicons.Solid.plus [ SvgAttr.class "w-3 h-3" ]
                    , text (String.fromInt scoreDiff)
                    ]

              else
                text ""
            , span [ class "text-sm text-opponent truncate max-w-[25ch]" ] [ text opponentName ]
            ]
        ]


{-| View player info overlay (top-left corner) - Mobile and Desktop
-}
viewPlayerInfo : PlayerState -> String -> Int -> Int -> Int -> Html Msg
viewPlayerInfo player playerName initialLives discardsPerRound scoreDiff =
    div [ class "flex flex-col items-start gap-0.5 text-base-content" ]
        [ div [ class "flex flex-col sm:flex-row items-start sm:items-center gap-0.5 sm:gap-1" ]
            [ div [ class "flex items-center gap-0.5" ]
                (List.range 1 initialLives
                    |> List.reverse
                    |> List.map
                        (\i ->
                            if i > initialLives - player.lives then
                                Heroicons.Solid.heart [ SvgAttr.class "w-4 h-4 text-red-400" ]

                            else
                                Heroicons.Outline.heart [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                        )
                )
            , span [ class "hidden sm:inline text-gray-500" ] [ text "·" ]
            , div [ class "flex items-center gap-0.5" ]
                (List.range 1 discardsPerRound
                    |> List.reverse
                    |> List.map
                        (\i ->
                            if i > discardsPerRound - player.discardsRemaining then
                                Heroicons.Solid.trash [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                            else
                                Heroicons.Outline.trash [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                        )
                )
            ]
        , div [ class "flex items-center gap-3" ]
            [ span [ class "text-sm text-player truncate max-w-[25ch]" ] [ text playerName ]
            , if scoreDiff > 0 then
                span [ class "flex items-center gap-0 text-xs font-semibold text-player" ]
                    [ Heroicons.Solid.plus [ SvgAttr.class "w-3 h-3" ]
                    , text (String.fromInt scoreDiff)
                    ]

              else
                text ""
            ]
        ]


{-| View modal based on which modal is currently viewing
-}
viewModal : Modal -> Model -> GameState -> PlayerState -> PlayerState -> String -> String -> String -> Html Msg
viewModal modal model gameState currentPlayer opponent playerId playerName opponentName =
    case modal of
        GameLog ->
            viewGameLogModal

        PlayerDeck deckPlayerId ->
            viewDeckModal deckPlayerId currentPlayer opponent playerId playerName opponentName

        PlayerLevels ->
            viewLevelsModal currentPlayer opponent playerName opponentName

        ShopModal ->
            text ""


{-| View game log modal
-}
viewGameLogModal : Html Msg
viewGameLogModal =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center justify-center mb-4 w-full" ]
            [ div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.newspaper [ SvgAttr.class "w-8 h-8 text-amber-600" ]
                , h2 [ class "text-2xl font-bold text-amber-600" ] [ text "History" ]
                ]
            , button
                [ onClick CloseModal
                , class "sm:hidden px-3 py-2 bg-base-300/50 hover:bg-base-300/70 rounded-lg transition-colors flex items-center gap-2 relative z-50"
                , Html.Attributes.type_ "button"
                , Html.Attributes.title "Close"
                ]
                [ span [ class "text-sm font-medium text-white" ] [ text "Close" ]
                , Heroicons.Solid.xCircle [ SvgAttr.class "w-5 h-5 text-base-content/60" ]
                ]
            ]
        , div [ class "w-full max-w-4xl" ]
            [ div [ class "text-gray-300 text-center" ]
                [ text "Game event log coming soon..." ]
            ]
        ]


{-| View deck modal
-}
viewDeckModal : String -> PlayerState -> PlayerState -> String -> String -> String -> Html Msg
viewDeckModal deckPlayerId currentPlayer opponent playerId playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center justify-center mb-4 w-full" ]
            [ div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.square3Stack3d [ SvgAttr.class "w-8 h-8 text-blue-600" ]
                , h2 [ class "text-2xl font-bold text-blue-600" ] [ text "Deck" ]
                ]
            , button
                [ onClick CloseModal
                , class "sm:hidden px-3 py-2 bg-base-300/50 hover:bg-base-300/70 rounded-lg transition-colors flex items-center gap-2 relative z-50"
                , Html.Attributes.type_ "button"
                , Html.Attributes.title "Close"
                ]
                [ span [ class "text-sm font-medium text-white" ] [ text "Close" ]
                , Heroicons.Solid.xCircle [ SvgAttr.class "w-5 h-5 text-base-content/60" ]
                ]
            ]
        , div [ class "w-full max-w-4xl" ]
            [ viewDeckCards currentPlayer ]
        ]


{-| View deck cards
-}
viewDeckCards : PlayerState -> Html Msg
viewDeckCards player =
    let
        allCards =
            player.cardPiles.drawPile ++ player.cardPiles.handPile

        cardsRemaining =
            List.length allCards

        inHandIds =
            Set.fromList (List.map .id player.cardPiles.handPile)

        faceDownIds =
            Set.fromList player.faceDownCardIds

        suits =
            [ Spades, Hearts, Clubs, Diamonds ]

        ranks =
            [ 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2 ]

        getSuitCards suit =
            List.filter (\card -> card.suit == suit) allCards

        groupCardsByRank cards =
            List.foldl
                (\card acc ->
                    Dict.update (rankValue card.rank)
                        (\maybeList ->
                            case maybeList of
                                Just list ->
                                    Just (list ++ [ card ])

                                Nothing ->
                                    Just [ card ]
                        )
                        acc
                )
                Dict.empty
                cards

        getMaxDuplicates cardsByRank =
            if Dict.isEmpty cardsByRank then
                1

            else
                cardsByRank
                    |> Dict.values
                    |> List.map List.length
                    |> List.maximum
                    |> Maybe.withDefault 1
    in
    div [ class "flex justify-center" ]
        [ div [ class "inline-block" ]
            [ div [ class "text-xs text-base-content/70 mb-2 sm:mb-3" ]
                [ text (String.fromInt cardsRemaining ++ " cards left") ]
            , div [ class "space-y-2 sm:space-y-3 min-w-0" ]
                (List.map
                    (\suit ->
                        let
                            suitCards =
                                getSuitCards suit

                            cardsByRank =
                                groupCardsByRank suitCards

                            maxDupes =
                                getMaxDuplicates cardsByRank
                        in
                        div [ class "flex items-start gap-1 sm:gap-2" ]
                            [ div [ class "w-3 sm:w-4 text-center pt-1 text-[10px] sm:text-xs text-base-content/50 flex-shrink-0" ]
                                [ text (String.fromInt (List.length suitCards)) ]
                            , div [ class "flex-1 space-y-0.5 sm:space-y-1 overflow-x-auto" ]
                                (List.range 0 (maxDupes - 1)
                                    |> List.map
                                        (\rowIdx ->
                                            div [ class "flex gap-0.5 sm:gap-1" ]
                                                (List.map
                                                    (\rank ->
                                                        let
                                                            cardsAtRank =
                                                                Dict.get rank cardsByRank
                                                                    |> Maybe.withDefault []

                                                            maybeCard =
                                                                List.drop rowIdx cardsAtRank
                                                                    |> List.head
                                                        in
                                                        case maybeCard of
                                                            Just card ->
                                                                let
                                                                    isInHand =
                                                                        Set.member card.id inHandIds

                                                                    isFaceDown =
                                                                        Set.member card.id faceDownIds

                                                                    opacityClass =
                                                                        if isInHand && not isFaceDown then
                                                                            "opacity-100"

                                                                        else
                                                                            "opacity-40"

                                                                    isDisabled =
                                                                        List.member (rankValue card.rank) player.disabledRanks
                                                                            || List.member card.suit player.disabledSuits
                                                                in
                                                                div [ class ("w-6 h-9 sm:w-12 sm:h-[72px] flex-shrink-0 " ++ opacityClass) ]
                                                                    [ Cards.viewCardImage
                                                                        { card = card
                                                                        , isFaceDown = False
                                                                        , showEnhancement = True
                                                                        , compact = True
                                                                        , disabled = isDisabled
                                                                        , enhancementDisabled = player.enhancementsDisabled
                                                                        }
                                                                    ]

                                                            Nothing ->
                                                                div [ class "w-6 h-9 sm:w-12 sm:h-[72px] bg-base-300/20 rounded flex-shrink-0" ]
                                                                    []
                                                    )
                                                    ranks
                                                )
                                        )
                                )
                            ]
                    )
                    suits
                )
            ]
        ]


{-| View levels modal
-}
viewLevelsModal : PlayerState -> PlayerState -> String -> String -> Html Msg
viewLevelsModal currentPlayer opponent playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center justify-center mb-6 w-full" ]
            [ div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.chartBar [ SvgAttr.class "w-8 h-8 text-green-600" ]
                , h2 [ class "text-2xl font-bold text-green-600" ] [ text "Levels" ]
                ]
            , button
                [ onClick CloseModal
                , class "sm:hidden px-3 py-2 bg-base-300/50 hover:bg-base-300/70 rounded-lg transition-colors flex items-center gap-2 relative z-50"
                , Html.Attributes.type_ "button"
                , Html.Attributes.title "Close"
                ]
                [ span [ class "text-sm font-medium text-white" ] [ text "Close" ]
                , Heroicons.Solid.xCircle [ SvgAttr.class "w-5 h-5 text-base-content/60" ]
                ]
            ]
        , div [ class "w-full max-w-2xl" ]
            [ viewLevelsList currentPlayer ]
        ]


{-| View levels list for current player
-}
viewLevelsList : PlayerState -> Html Msg
viewLevelsList player =
    let
        handTypes =
            [ HighCard, Pair, TwoPair, ThreeOfAKind, Straight, Flush, FullHouse, FourOfAKind, StraightFlush ]

        getLevel handType skillTree =
            case handType of
                HighCard ->
                    skillTree.highCard

                Pair ->
                    skillTree.pair

                TwoPair ->
                    skillTree.twoPair

                ThreeOfAKind ->
                    skillTree.threeOfAKind

                Straight ->
                    skillTree.straight

                Flush ->
                    skillTree.flush

                FullHouse ->
                    skillTree.fullHouse

                FourOfAKind ->
                    skillTree.fourOfAKind

                StraightFlush ->
                    skillTree.straightFlush

        statsAtLevel handType level =
            let
                config =
                    case handType of
                        HighCard ->
                            { baseChips = 125, baseMult = 1, upgradeChips = 10, upgradeMult = 1 }

                        Pair ->
                            { baseChips = 140, baseMult = 1, upgradeChips = 10, upgradeMult = 1 }

                        TwoPair ->
                            { baseChips = 105, baseMult = 2, upgradeChips = 10, upgradeMult = 1 }

                        ThreeOfAKind ->
                            { baseChips = 130, baseMult = 2, upgradeChips = 10, upgradeMult = 1 }

                        Straight ->
                            { baseChips = 70, baseMult = 4, upgradeChips = 10, upgradeMult = 1 }

                        Flush ->
                            { baseChips = 70, baseMult = 4, upgradeChips = 10, upgradeMult = 1 }

                        FullHouse ->
                            { baseChips = 70, baseMult = 5, upgradeChips = 10, upgradeMult = 1 }

                        FourOfAKind ->
                            { baseChips = 50, baseMult = 12, upgradeChips = 20, upgradeMult = 2 }

                        StraightFlush ->
                            { baseChips = 95, baseMult = 12, upgradeChips = 20, upgradeMult = 2 }

                bonusMultiplier =
                    max 0 (level - 1)
            in
            { chips = config.baseChips + bonusMultiplier * config.upgradeChips
            , multiplier = config.baseMult + bonusMultiplier * config.upgradeMult
            }

        isCountered handType =
            List.member handType player.activeDebuffs
    in
    div [ class "w-full" ]
        [ div [ class "space-y-1" ]
            (List.map
                (\handType ->
                    let
                        level =
                            getLevel handType player.skillTree

                        stats =
                            statsAtLevel handType level

                        countered =
                            isCountered handType

                        opacityClass =
                            if countered then
                                "opacity-60"

                            else
                                ""

                        strikeClass =
                            if countered then
                                "line-through"

                            else
                                ""

                        statsColorClass =
                            if countered then
                                "text-base-content/40 line-through"

                            else
                                "text-base-content/70"

                        -- Background color gradient based on level (plateaus at 5+)
                        levelBgClass =
                            case min level 5 of
                                1 ->
                                    "bg-base-300/20"

                                2 ->
                                    "bg-emerald-900/20"

                                3 ->
                                    "bg-cyan-900/20"

                                4 ->
                                    "bg-purple-900/25"

                                _ ->
                                    -- Level 5+
                                    "bg-amber-900/25"
                    in
                    div [ class ("flex items-center justify-between py-1 px-2 rounded " ++ levelBgClass ++ " " ++ opacityClass) ]
                        [ div [ class "flex items-center gap-2" ]
                            [ span [ class "text-xs text-base-content/50 w-6" ]
                                [ text ("Lv" ++ String.fromInt level) ]
                            , span [ class ("text-sm " ++ strikeClass) ]
                                [ text (handTypeToString handType) ]
                            , if countered then
                                span [ class "text-xs text-error font-medium" ]
                                    [ text "(Countered)" ]

                              else
                                text ""
                            ]
                        , span [ class ("text-xs " ++ statsColorClass) ]
                            [ text (String.fromInt stats.chips ++ " × " ++ String.fromInt stats.multiplier) ]
                        ]
                )
                handTypes
            )
        ]


{-| Badge representing a debuff or status effect on a player
-}
type alias Badge =
    { name : String
    , tooltip : String
    }


{-| Get list of active sabotage badges for a player
-}
getSabotageBadges : PlayerState -> List Badge
getSabotageBadges player =
    let
        scrambledBadge =
            if player.scrambled then
                Just { name = "Scrambled", tooltip = "1-in-5 drawn cards are face-down" }

            else
                Nothing

        staticFieldBadge =
            if player.enhancementsDisabled then
                Just { name = "Static Field", tooltip = "Card enhancements disabled" }

            else
                Nothing

        plusBombBadge =
            if player.disabledRanks /= [] || player.disabledSuits /= [] then
                let
                    disabledText =
                        formatDisabledCards player.disabledRanks player.disabledSuits
                in
                Just { name = "Napalm Strikes", tooltip = disabledText ++ " won't score" }

            else
                Nothing

        supplyChainBadge =
            if player.supplyChainLimited then
                Just { name = "Supply Chain", tooltip = "Draws limited to 4 cards per discard" }

            else
                Nothing
    in
    [ scrambledBadge, staticFieldBadge, plusBombBadge, supplyChainBadge ]
        |> List.filterMap identity


{-| Format disabled cards for tooltip
-}
formatDisabledCards : List Int -> List Suit -> String
formatDisabledCards disabledRanks disabledSuits =
    let
        rankStrs =
            List.map formatRank disabledRanks

        suitStrs =
            List.map formatSuit disabledSuits

        allStrs =
            rankStrs ++ suitStrs
    in
    String.join ", " allStrs


{-| Format rank for display
-}
formatRank : Int -> String
formatRank rank =
    case rank of
        2 ->
            "2s"

        3 ->
            "3s"

        4 ->
            "4s"

        5 ->
            "5s"

        6 ->
            "6s"

        7 ->
            "7s"

        8 ->
            "8s"

        9 ->
            "9s"

        10 ->
            "10s"

        11 ->
            "Jacks"

        12 ->
            "Queens"

        13 ->
            "Kings"

        14 ->
            "Aces"

        _ ->
            String.fromInt rank


{-| Format suit for display
-}
formatSuit : Suit -> String
formatSuit suit =
    case suit of
        Hearts ->
            "Hearts"

        Diamonds ->
            "Diamonds"

        Clubs ->
            "Clubs"

        Spades ->
            "Spades"


{-| Render a single badge
-}
viewBadge : String -> Badge -> Html Msg
viewBadge colorClass badge =
    div
        [ class ("group relative flex items-center gap-1 px-2 py-1 rounded text-xs font-semibold " ++ colorClass)
        , Html.Attributes.title badge.tooltip
        ]
        [ span [] [ text badge.name ] ]


{-| View badges positioned at bottom of centerboard
-}
viewCenterboardBadges : PlayerState -> PlayerState -> Html Msg
viewCenterboardBadges player opponent =
    let
        _ =
            Debug.log "Player scrambled" player.scrambled

        _ =
            Debug.log "Player enhancementsDisabled" player.enhancementsDisabled

        _ =
            Debug.log "Player supplyChainLimited" player.supplyChainLimited

        _ =
            Debug.log "Opponent scrambled" opponent.scrambled

        _ =
            Debug.log "Opponent enhancementsDisabled" opponent.enhancementsDisabled

        _ =
            Debug.log "Opponent supplyChainLimited" opponent.supplyChainLimited

        opponentDebuffBadges =
            if opponent.activeDebuffs /= [] then
                let
                    debuffNames =
                        opponent.activeDebuffs
                            |> List.map handTypeToString
                            |> String.join ", "
                in
                [ { name = "Blocked: " ++ debuffNames, tooltip = "These hand types cannot be played" } ]

            else
                []

        opponentSabotageBadges =
            getSabotageBadges opponent

        playerDebuffBadges =
            if player.activeDebuffs /= [] then
                let
                    debuffNames =
                        player.activeDebuffs
                            |> List.map handTypeToString
                            |> String.join ", "
                in
                [ { name = "Blocked: " ++ debuffNames, tooltip = "These hand types cannot be played" } ]

            else
                []

        playerSabotageBadges =
            getSabotageBadges player

        allOpponentBadges =
            opponentDebuffBadges ++ opponentSabotageBadges

        allPlayerBadges =
            playerDebuffBadges ++ playerSabotageBadges

        hasAnyBadges =
            allOpponentBadges /= [] || allPlayerBadges /= []
    in
    if hasAnyBadges then
        div []
            [ div [ class "sm:hidden absolute bottom-1 left-2 right-2 flex flex-wrap gap-1 z-10" ]
                (List.map (viewBadge "bg-player text-sky-900") allPlayerBadges
                    ++ List.map (viewBadge "bg-opponent text-orange-900") allOpponentBadges
                )
            , div [ class "hidden sm:flex absolute bottom-4 left-4 right-4 items-end justify-between z-10 pointer-events-none" ]
                [ if allPlayerBadges /= [] then
                    div [ class "pointer-events-auto flex flex-wrap gap-1" ]
                        (List.map (viewBadge "bg-player text-sky-900") allPlayerBadges)

                  else
                    text ""
                , if allOpponentBadges /= [] then
                    div [ class "pointer-events-auto flex flex-wrap gap-1" ]
                        (List.map (viewBadge "bg-opponent text-orange-900") allOpponentBadges)

                  else
                    text ""
                ]
            ]

    else
        text ""



{- ========== SHOP VIEW FUNCTIONS ========== -}


{-| View shop interface - full page view
-}
viewShop : Model -> ShopData -> Html Msg
viewShop model shopData =
    div [ class "h-screen-safe bg-base-200 lg:bg-gradient-to-br lg:from-base-200 lg:via-base-100 lg:to-base-200 overflow-auto" ]
        [ div [ class "min-h-full flex flex-col lg:flex-row lg:h-screen-safe" ]
            [ -- Section 1: Header with lives (left column on desktop)
              div [ class "order-1 lg:order-none lg:w-[440px] xl:w-[540px] lg:flex-shrink-0 lg:border-r border-base-300/50 bg-base-200 lg:bg-base-100/50 lg:flex lg:flex-col lg:h-screen-safe" ]
                [ viewShopHeader shopData
                , -- Cards Grid (hidden on mobile, shown on desktop)
                  div [ class "hidden lg:block flex-1 p-6 overflow-y-auto" ]
                    [ viewShopCardsGrid shopData model.shopUIState ]
                ]
            , -- Section 2: Timeline + Preview Panel (order-2 on mobile)
              div [ class "order-2 lg:order-none lg:flex-1 lg:flex lg:flex-col lg:h-screen lg:overflow-hidden" ]
                [ div [ class "flex-shrink-0" ]
                    [ viewPickTimeline shopData ]
                , -- Preview Panel (hidden on mobile, shown on desktop)
                  case model.shopUIState of
                    Just uiState ->
                        div [ class "hidden lg:flex flex-1 flex-col overflow-hidden" ]
                            [ viewPreviewPanelByState uiState model.shopCountdown shopData.yourSkillTree ]

                    Nothing ->
                        text ""
                ]
            , -- Section 3: Mobile cards view (order-3)
              div [ class "order-3 lg:hidden px-3 py-3 border-t border-base-300/50 bg-base-200" ]
                [ viewMobileShopCards shopData model.shopUIState ]
            , -- Mobile preview modal
              case model.shopUIState of
                Just uiState ->
                    viewMobilePreviewModal uiState model.shopCountdown shopData.yourSkillTree

                Nothing ->
                    text ""
            ]
        ]


{-| Shop header with lives display
-}
viewShopHeader : ShopData -> Html Msg
viewShopHeader shopData =
    div [ class "p-6 border-b border-base-300/50 flex-shrink-0" ]
        [ div [ class "flex items-center justify-between mb-4" ]
            [ div [ class "text-2xl font-light text-base-content" ]
                [ text "Command Center" ]
            , div [ class "flex items-center gap-2" ]
                [ div [ class "text-xs uppercase tracking-wider text-base-content/40" ]
                    [ text "Round" ]
                , div [ class "text-lg font-semibold text-base-content" ]
                    [ text (String.fromInt shopData.currentRound) ]
                ]
            ]
        , -- Lives status
          div [ class "flex items-center gap-4" ]
            [ -- Player lives
              div [ class "flex items-center gap-2" ]
                [ span [ class "text-xs text-player font-medium" ]
                    [ text shopData.yourName ]
                , div [ class "flex items-center gap-0.5" ]
                    (List.range 1 shopData.initialLives
                        |> List.map
                            (\i ->
                                if i <= shopData.yourLives then
                                    span [ class "text-error" ] [ text "♥" ]

                                else
                                    span [ class "text-base-content/20" ] [ text "♥" ]
                            )
                    )
                ]
            , -- VS divider
              span [ class "text-xs text-base-content/30" ] [ text "vs" ]
            , -- Opponent lives
              div [ class "flex items-center gap-2" ]
                [ span [ class "text-xs text-opponent font-medium" ]
                    [ text shopData.opponentName ]
                , div [ class "flex items-center gap-0.5" ]
                    (List.range 1 shopData.initialLives
                        |> List.map
                            (\i ->
                                if i <= shopData.opponentLives then
                                    span [ class "text-error" ] [ text "♥" ]

                                else
                                    span [ class "text-base-content/20" ] [ text "♥" ]
                            )
                    )
                ]
            ]
        ]


{-| Shop cards grid - desktop view
-}
viewShopCardsGrid : ShopData -> Maybe ShopUIState -> Html Msg
viewShopCardsGrid shopData maybeUIState =
    let
        pickedCardIdsSet =
            Set.fromList shopData.shopState.pickedCardIds

        destroyedCardIdsSet =
            Set.fromList shopData.shopState.destroyedCardIds

        -- Determine if player can pick based on UI state
        canPick =
            case maybeUIState of
                Just (BrowsingCards _) ->
                    True

                Just (PreviewingCard _) ->
                    True

                Just (DestroyPhase data) ->
                    data.isMyTurn

                _ ->
                    False

        -- Get the currently previewing card ID
        previewingCardId =
            case maybeUIState of
                Just (PreviewingCard data) ->
                    Just data.cardId

                _ ->
                    Nothing
    in
    div []
        [ -- Arsenal Section (Permanent Upgrades)
          div [ class "mb-6" ]
            [ div [ class "mb-3 flex items-center gap-2" ]
                [ div [ class "text-sm font-semibold uppercase tracking-wider text-base-content/40" ]
                    [ text "Arsenal" ]
                , div [ class "text-xs text-base-content/40" ]
                    [ text "Permanent Upgrades" ]
                ]
            , div [ class "grid grid-cols-4 gap-3" ]
                (shopData.availableCards
                    |> List.take 8
                    |> List.map
                        (\shopCard ->
                            viewShopCard shopCard shopData pickedCardIdsSet destroyedCardIdsSet canPick previewingCardId
                        )
                )
            ]
        , -- Tactical Ops Section (Action Cards)
          div []
            [ div [ class "mb-3 flex items-center gap-2" ]
                [ div [ class "text-sm font-semibold uppercase tracking-wider text-base-content/40" ]
                    [ text "Tactical Ops" ]
                , div [ class "text-xs text-base-content/40" ]
                    [ text "Temporary Battlefield Advantage" ]
                ]
            , div [ class "grid grid-cols-4 gap-3" ]
                (shopData.availableCards
                    |> List.drop 8
                    |> List.map
                        (\shopCard ->
                            viewShopCard shopCard shopData pickedCardIdsSet destroyedCardIdsSet canPick previewingCardId
                        )
                )
            ]
        ]


{-| Helper to determine who picked a card and return (name, isPlayer)
-}
getCardPicker : String -> ShopData -> Maybe ( String, Bool )
getCardPicker cardId shopData =
    let
        -- Find the index of this card in the picked cards list
        maybePickIndex =
            shopData.shopState.pickedCardIds
                |> List.indexedMap (\idx id -> ( idx, id ))
                |> List.filter (\( _, id ) -> id == cardId)
                |> List.head
                |> Maybe.map Tuple.first
    in
    case maybePickIndex of
        Nothing ->
            Nothing

        Just pickIndex ->
            let
                -- Convert to 1-based pick number
                pickNum =
                    pickIndex + 1

                -- Odd picks = first picker, even picks = second picker
                pickerId =
                    if modBy 2 pickNum == 1 then
                        shopData.shopState.firstPickerId

                    else
                        shopData.shopState.secondPickerId

                pickerName =
                    if pickerId == shopData.yourPlayerId then
                        shopData.yourName

                    else
                        shopData.opponentName

                isPlayer =
                    pickerId == shopData.yourPlayerId
            in
            Just ( pickerName, isPlayer )


{-| Individual shop card
-}
viewShopCard : ShopCard -> ShopData -> Set String -> Set String -> Bool -> Maybe String -> Html Msg
viewShopCard shopCard shopData pickedIds destroyedIds canPick previewingCardId =
    let
        cardId =
            shopCardId shopCard

        isPicked =
            Set.member cardId pickedIds

        isDestroyed =
            Set.member cardId destroyedIds

        isSelected =
            previewingCardId == Just cardId

        isDisabled =
            isPicked || isDestroyed || not canPick

        accentColor =
            case shopCard.kind of
                Types.Research _ ->
                    "emerald"

                Types.Counter _ ->
                    "rose"

                Types.Sabotage _ ->
                    "amber"

                Types.Logistics _ ->
                    "violet"

        typeLabel =
            case shopCard.kind of
                Types.Research _ ->
                    "RESEARCH"

                Types.Counter _ ->
                    "COUNTER"

                Types.Sabotage _ ->
                    "SABOTAGE"

                Types.Logistics _ ->
                    "LOGISTICS"

        borderClass =
            if isSelected then
                case accentColor of
                    "emerald" ->
                        "border-emerald-500 shadow-lg shadow-emerald-500/20 scale-[1.02]"

                    "rose" ->
                        "border-rose-500 shadow-lg shadow-rose-500/20 scale-[1.02]"

                    "violet" ->
                        "border-violet-500 shadow-lg shadow-violet-500/20 scale-[1.02]"

                    "amber" ->
                        "border-amber-500 shadow-lg shadow-amber-500/20 scale-[1.02]"

                    _ ->
                        "border-base-300/50"

            else if isPicked || isDestroyed then
                "border-base-300/30 opacity-50"

            else if not canPick then
                "border-base-300/30 opacity-50 cursor-not-allowed"

            else
                -- Use full class names for Tailwind to detect
                case accentColor of
                    "emerald" ->
                        "border-base-300/50 hover:border-emerald-400 hover:shadow-md cursor-pointer"

                    "rose" ->
                        "border-base-300/50 hover:border-rose-400 hover:shadow-md cursor-pointer"

                    "violet" ->
                        "border-base-300/50 hover:border-violet-400 hover:shadow-md cursor-pointer"

                    "amber" ->
                        "border-base-300/50 hover:border-amber-400 hover:shadow-md cursor-pointer"

                    _ ->
                        "border-base-300/50 cursor-pointer"

        labelColor =
            case accentColor of
                "emerald" ->
                    "text-emerald-500"

                "rose" ->
                    "text-rose-500"

                "amber" ->
                    "text-amber-500"

                "violet" ->
                    "text-violet-500"

                _ ->
                    "text-base-content/40"
    in
    button
        [ class ("w-full aspect-[2/3] rounded-xl p-2 flex flex-col transition-all relative overflow-hidden bg-base-100 border-2 " ++ borderClass)
        , onClick
            (if isDisabled then
                NoOp

             else
                -- Always preview the card, the action button in preview will make the actual pick
                PreviewShopCard cardId
            )
        , Html.Attributes.disabled isDisabled
        ]
        [ -- Type badge
          div [ class ("text-[10px] font-bold uppercase tracking-wider mb-2 " ++ labelColor) ]
            [ text typeLabel ]
        , -- Card name
          div [ class "flex-1 flex items-center justify-center" ]
            [ div [ class "font-semibold text-sm text-center leading-tight text-base-content" ]
                [ text (shopCardName shopCard) ]
            ]
        , -- Picked/Destroyed overlay
          if isPicked then
            case getCardPicker cardId shopData of
                Just ( pickerName, isPlayer ) ->
                    let
                        textColorClass =
                            if isPlayer then
                                "text-blue-400"

                            else
                                "text-orange-400"
                    in
                    div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                        [ span [ class ("text-xs font-medium " ++ textColorClass) ]
                            [ text pickerName ]
                        ]

                Nothing ->
                    div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                        [ span [ class "text-xs text-base-content/40 font-medium" ]
                            [ text "Picked" ]
                        ]

          else if isDestroyed then
            div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                [ span [ class "text-xs text-rose-400 font-medium" ]
                    [ text "Destroyed" ]
                ]

          else
            text ""
        ]


{-| Mobile shop cards - horizontal scrolling sections
-}
viewMobileShopCards : ShopData -> Maybe ShopUIState -> Html Msg
viewMobileShopCards shopData maybeUIState =
    let
        pickedCardIdsSet =
            Set.fromList shopData.shopState.pickedCardIds

        destroyedCardIdsSet =
            Set.fromList shopData.shopState.destroyedCardIds

        -- Determine if player can pick based on UI state
        canPick =
            case maybeUIState of
                Just (BrowsingCards _) ->
                    True

                Just (PreviewingCard _) ->
                    True

                Just (DestroyPhase data) ->
                    data.isMyTurn

                _ ->
                    False

        -- Extract the currently previewing card ID
        previewingCardId =
            case maybeUIState of
                Just (PreviewingCard data) ->
                    Just data.cardId

                _ ->
                    Nothing
    in
    div []
        [ -- Arsenal Section
          div [ class "mb-4" ]
            [ div [ class "mb-2 flex items-center gap-2" ]
                [ div [ class "text-xs font-semibold uppercase tracking-wider text-base-content/40" ]
                    [ text "Arsenal" ]
                , div [ class "text-[10px] text-base-content/40" ]
                    [ text "Permanent Upgrades" ]
                ]
            , div [ class "flex gap-2 overflow-x-auto pb-2" ]
                (shopData.availableCards
                    |> List.take 8
                    |> List.map
                        (\shopCard ->
                            viewMobileShopCard shopCard shopData pickedCardIdsSet destroyedCardIdsSet canPick previewingCardId
                        )
                )
            ]
        , -- Tactical Ops Section
          div []
            [ div [ class "mb-2 flex items-center gap-2" ]
                [ div [ class "text-xs font-semibold uppercase tracking-wider text-base-content/40" ]
                    [ text "Tactical Ops" ]
                , div [ class "text-[10px] text-base-content/40" ]
                    [ text "Temporary Battlefield Advantage" ]
                ]
            , div [ class "flex gap-2 overflow-x-auto pb-2" ]
                (shopData.availableCards
                    |> List.drop 8
                    |> List.map
                        (\shopCard ->
                            viewMobileShopCard shopCard shopData pickedCardIdsSet destroyedCardIdsSet canPick previewingCardId
                        )
                )
            ]
        ]


{-| Mobile shop card (smaller)
-}
viewMobileShopCard : ShopCard -> ShopData -> Set String -> Set String -> Bool -> Maybe String -> Html Msg
viewMobileShopCard shopCard shopData pickedIds destroyedIds canPick previewingCardId =
    let
        cardId =
            shopCardId shopCard

        isPicked =
            Set.member cardId pickedIds

        isDestroyed =
            Set.member cardId destroyedIds

        isSelected =
            previewingCardId == Just cardId

        isDisabled =
            isPicked || isDestroyed || not canPick

        accentColor =
            case shopCard.kind of
                Types.Research _ ->
                    "emerald"

                Types.Counter _ ->
                    "rose"

                Types.Sabotage _ ->
                    "amber"

                Types.Logistics _ ->
                    "violet"

        typeLabel =
            case shopCard.kind of
                Types.Research _ ->
                    "RESEARCH"

                Types.Counter _ ->
                    "COUNTER"

                Types.Sabotage _ ->
                    "SABOTAGE"

                Types.Logistics _ ->
                    "LOGISTICS"

        borderClass =
            if isSelected then
                case accentColor of
                    "emerald" ->
                        "border-emerald-500 shadow-lg shadow-emerald-500/20 scale-[1.02]"

                    "rose" ->
                        "border-rose-500 shadow-lg shadow-rose-500/20 scale-[1.02]"

                    "violet" ->
                        "border-violet-500 shadow-lg shadow-violet-500/20 scale-[1.02]"

                    "amber" ->
                        "border-amber-500 shadow-lg shadow-amber-500/20 scale-[1.02]"

                    _ ->
                        "border-base-300/50"

            else if isPicked || isDestroyed then
                "border-base-300/30 opacity-50"

            else if not canPick then
                "border-base-300/30 opacity-50 cursor-not-allowed"

            else
                "border-base-300/50"

        labelColor =
            case accentColor of
                "emerald" ->
                    "text-emerald-500"

                "rose" ->
                    "text-rose-500"

                "amber" ->
                    "text-amber-500"

                "violet" ->
                    "text-violet-500"

                _ ->
                    "text-base-content/40"
    in
    button
        [ class ("w-[100px] aspect-[2/3] rounded-xl p-2 flex flex-col transition-all relative overflow-hidden flex-shrink-0 bg-base-100 border-2 " ++ borderClass)
        , onClick
            (if isDisabled then
                NoOp

             else
                -- Always preview the card, the action button in preview will make the actual pick
                PreviewShopCard cardId
            )
        , Html.Attributes.disabled isDisabled
        ]
        [ -- Type badge
          div [ class ("text-[8px] lg:text-[10px] font-bold uppercase tracking-wider mb-1 " ++ labelColor) ]
            [ text typeLabel ]
        , -- Card name
          div [ class "flex-1 flex items-center justify-center" ]
            [ div [ class "font-semibold text-xs text-center leading-tight text-base-content" ]
                [ text (shopCardName shopCard) ]
            ]
        , -- Picked/Destroyed overlay
          if isPicked then
            case getCardPicker cardId shopData of
                Just ( pickerName, isPlayer ) ->
                    let
                        textColorClass =
                            if isPlayer then
                                "text-blue-400"

                            else
                                "text-orange-400"
                    in
                    div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                        [ span [ class ("text-xs font-medium " ++ textColorClass) ]
                            [ text pickerName ]
                        ]

                Nothing ->
                    div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                        [ span [ class "text-xs text-base-content/40 font-medium" ]
                            [ text "Picked" ]
                        ]

          else if isDestroyed then
            div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                [ span [ class "text-xs text-rose-400 font-medium" ]
                    [ text "Destroyed" ]
                ]

          else
            text ""
        ]


{-| Pick timeline showing order of picks
-}
viewPickTimeline : ShopData -> Html Msg
viewPickTimeline shopData =
    let
        firstPickerName =
            if shopData.shopState.firstPickerId == shopData.yourPlayerId then
                shopData.yourName

            else
                shopData.opponentName

        secondPickerName =
            if shopData.shopState.secondPickerId == shopData.yourPlayerId then
                shopData.yourName

            else
                shopData.opponentName

        -- Destroyer name (if there is one)
        destroyerName =
            case shopData.shopState.destroyerId of
                Just destroyerId ->
                    if destroyerId == shopData.yourPlayerId then
                        Just shopData.yourName

                    else
                        Just shopData.opponentName

                Nothing ->
                    Nothing

        totalDestroys =
            shopData.shopState.destroysAllowed

        totalPicks =
            shopData.totalRounds * 2

        destroyedCount =
            List.length shopData.shopState.destroyedCardIds

        pickedCount =
            List.length shopData.shopState.pickedCardIds

        reversedDestroyedIds =
            List.reverse shopData.shopState.destroyedCardIds

        reversedPickedIds =
            List.reverse shopData.shopState.pickedCardIds

        -- Create destroy slots
        destroySlots =
            List.range 1 totalDestroys
                |> List.map
                    (\destroyNum ->
                        let
                            maybeCardId =
                                reversedDestroyedIds
                                    |> List.drop (destroyNum - 1)
                                    |> List.head

                            maybeCard =
                                maybeCardId
                                    |> Maybe.andThen (\cardId -> shopData.availableCards |> List.filter (\c -> c.id == cardId) |> List.head)

                            isCurrent =
                                not shopData.shopState.destroyPhaseComplete
                                    && destroyNum
                                    == (destroyedCount + 1)
                                    && destroyedCount
                                    < totalDestroys

                            -- Check if this is the player's action
                            isPlayerAction =
                                case shopData.shopState.destroyerId of
                                    Just destroyerId ->
                                        destroyerId == shopData.yourPlayerId

                                    Nothing ->
                                        False
                        in
                        { slotNum = destroyNum
                        , slotType = "DESTROY"
                        , pickerName = Maybe.withDefault "" destroyerName
                        , maybeCard = maybeCard
                        , isCurrent = isCurrent
                        , isPlayerAction = isPlayerAction
                        }
                    )

        -- Create pick slots
        pickSlots =
            List.range 1 totalPicks
                |> List.map
                    (\pickNum ->
                        let
                            -- Determine who is picking
                            pickerId =
                                if modBy 2 pickNum == 1 then
                                    shopData.shopState.firstPickerId

                                else
                                    shopData.shopState.secondPickerId

                            pickerName =
                                if modBy 2 pickNum == 1 then
                                    firstPickerName

                                else
                                    secondPickerName

                            maybeCardId =
                                reversedPickedIds
                                    |> List.drop (pickNum - 1)
                                    |> List.head

                            maybeCard =
                                maybeCardId
                                    |> Maybe.andThen (\cardId -> shopData.availableCards |> List.filter (\c -> c.id == cardId) |> List.head)

                            isCurrent =
                                shopData.shopState.destroyPhaseComplete
                                    && pickNum
                                    == (pickedCount + 1)
                                    && pickedCount
                                    < totalPicks

                            -- Check if this is the player's pick
                            isPlayerAction =
                                pickerId == shopData.yourPlayerId
                        in
                        { slotNum = pickNum
                        , slotType = "PICK"
                        , pickerName = pickerName
                        , maybeCard = maybeCard
                        , isCurrent = isCurrent
                        , isPlayerAction = isPlayerAction
                        }
                    )

        -- Combine destroy + pick slots
        allSlots =
            destroySlots ++ pickSlots
    in
    div [ class "p-3 lg:p-6 border-b border-base-300/50" ]
        [ div [ class "flex flex-wrap gap-2 lg:gap-3" ]
            (allSlots
                |> List.map
                    (\slot ->
                        viewTimelineSlot slot.slotNum slot.slotType slot.pickerName slot.maybeCard slot.isCurrent slot.isPlayerAction
                    )
            )
        ]


{-| Individual timeline slot
-}
viewTimelineSlot : Int -> String -> String -> Maybe ShopCard -> Bool -> Bool -> Html Msg
viewTimelineSlot slotNum slotType pickerName maybeCard isCurrent isPlayerAction =
    let
        ordinal =
            case slotNum of
                1 ->
                    "1ST"

                2 ->
                    "2ND"

                3 ->
                    "3RD"

                n ->
                    String.fromInt n ++ "TH"

        label =
            if slotType == "DESTROY" then
                "DESTROY"

            else
                ordinal ++ " " ++ slotType

        ( containerClass, labelColor ) =
            if maybeCard /= Nothing then
                if slotType == "DESTROY" then
                    -- Glassy red effect for completed destroy phase
                    ( "bg-gradient-to-br from-rose-500/20 to-rose-600/30 backdrop-blur-sm border-rose-400/40", "text-rose-400/80" )

                else
                -- Glassy effect in player color (blue or orange) for completed pick
                if
                    isPlayerAction
                then
                    ( "bg-gradient-to-br from-blue-500/20 to-blue-600/30 backdrop-blur-sm border-blue-400/40", "text-blue-400/80" )

                else
                    ( "bg-gradient-to-br from-orange-500/20 to-orange-600/30 backdrop-blur-sm border-orange-400/40", "text-orange-400/80" )

            else if isCurrent then
                -- Use player color for the glow (blue for player, orange for opponent)
                if isPlayerAction then
                    ( "bg-base-200/50 border-dashed animate-pulse border-blue-400", "text-base-content/40" )

                else
                    ( "bg-base-200/50 border-dashed animate-pulse border-orange-400", "text-base-content/40" )

            else
                ( "bg-base-200/30 border-base-300/30", "text-base-content/40" )
    in
    div [ class ("flex-1 min-w-[110px] lg:min-w-[180px] flex-shrink-0 rounded-lg p-2 lg:p-3 border transition-all " ++ containerClass) ]
        [ div [ class ("text-[9px] lg:text-[10px] uppercase tracking-wider mb-0.5 lg:mb-1 " ++ labelColor) ]
            [ text label ]
        , case maybeCard of
            Just card ->
                div [ class "min-w-0" ]
                    [ div [ class "text-xs lg:text-sm font-medium text-base-content truncate" ]
                        [ text (shopCardName card) ]
                    , div [ class "text-[9px] lg:text-[10px] text-base-content/40" ]
                        [ text pickerName ]
                    ]

            Nothing ->
                div [ class "text-xs lg:text-sm text-base-content/30" ]
                    [ text pickerName ]
        ]


{-| Preview panel - exhaustive pattern match on UI state
-}
viewPreviewPanelByState : ShopUIState -> Maybe Int -> SkillTree -> Html Msg
viewPreviewPanelByState uiState shopCountdown skillTree =
    case uiState of
        DestroyPhase data ->
            if data.isMyTurn then
                viewDestroyInstructions data.destroysRemaining

            else
                viewWaitingMessage "Opponent is destroying cards..."

        WaitingForOpponent data ->
            case data.reason of
                OpponentDestroying ->
                    viewWaitingMessage "Opponent is destroying cards..."

                OpponentPicking ->
                    viewWaitingMessage "Opponent is picking..."

        BrowsingCards _ ->
            viewEmptyBrowsingPreview

        PreviewingCard data ->
            viewShopCardPreview data skillTree

        SelectingDeckBuilderCards data ->
            viewDeckBuilderSelectionPreview data

        SelectingPlusBombCard data ->
            viewPlusBombSelectionPreview data

        ShopComplete _ ->
            viewShopCompletePreview shopCountdown


{-| Mobile preview modal
-}
viewMobilePreviewModal : ShopUIState -> Maybe Int -> SkillTree -> Html Msg
viewMobilePreviewModal uiState shopCountdown skillTree =
    let
        hasContent =
            case uiState of
                PreviewingCard _ ->
                    True

                SelectingDeckBuilderCards _ ->
                    True

                SelectingPlusBombCard _ ->
                    True

                _ ->
                    False
    in
    if hasContent then
        div [ class "lg:hidden fixed inset-0 z-50 bg-black/50" ]
            [ div [ class "absolute inset-x-0 bottom-0 flex items-end" ]
                [ div [ class "relative w-full max-h-[85vh] bg-base-100 rounded-t-2xl shadow-2xl overflow-hidden animate-slide-up" ]
                    [ -- Content (scrollable)
                      div [ class "overflow-y-auto max-h-[85vh]" ]
                        [ viewPreviewPanelByState uiState shopCountdown skillTree ]
                    ]
                ]
            ]

    else
        text ""


{-| Destroy phase instructions
-}
viewDestroyInstructions : Int -> Html Msg
viewDestroyInstructions destroysRemaining =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ p [ class "text-base-content/60 text-lg font-light mb-2" ]
                [ text "Destroy cards from the shop" ]
            , p [ class "text-base-content/40 text-sm" ]
                [ text
                    (if destroysRemaining == 1 then
                        "1 destroy remaining"

                     else
                        String.fromInt destroysRemaining ++ " destroys remaining"
                    )
                ]
            ]
        ]


{-| Waiting message
-}
viewWaitingMessage : String -> Html Msg
viewWaitingMessage message =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ p [ class "text-base-content/40 text-lg font-light" ]
                [ text message ]
            ]
        ]


{-| Empty preview when browsing
-}
viewEmptyBrowsingPreview : Html Msg
viewEmptyBrowsingPreview =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ p [ class "text-base-content/40 text-lg font-light" ]
                [ text "Select a card to preview" ]
            ]
        ]


{-| Shop complete preview
-}
viewShopCompletePreview : Maybe Int -> Html Msg
viewShopCompletePreview shopCountdown =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ p [ class "text-base-content/60 text-lg font-light mb-2" ]
                [ text "All Picks Complete" ]
            , p [ class "text-base-content/40 text-sm" ]
                [ case shopCountdown of
                    Just seconds ->
                        text ("Starting in " ++ String.fromInt seconds ++ "...")

                    Nothing ->
                        text "Starting..."
                ]
            ]
        ]


{-| Shop card preview (regular card)
-}
viewShopCardPreview : PreviewCardData -> SkillTree -> Html Msg
viewShopCardPreview data skillTree =
    let
        accentColor =
            case data.card.kind of
                Types.Research _ ->
                    "emerald"

                Types.Counter _ ->
                    "rose"

                Types.Sabotage _ ->
                    "amber"

                Types.Logistics _ ->
                    "violet"

        typeLabel =
            case data.card.kind of
                Types.Research _ ->
                    "Research"

                Types.Counter _ ->
                    "Counter"

                Types.Sabotage _ ->
                    "Sabotage"

                Types.Logistics _ ->
                    "Logistics"

        labelColorClass =
            case accentColor of
                "emerald" ->
                    "text-emerald-500/60"

                "rose" ->
                    "text-rose-500/60"

                "amber" ->
                    "text-amber-500/60"

                "violet" ->
                    "text-violet-500/60"

                _ ->
                    "text-base-content/40"

        buttonBgClass =
            case accentColor of
                "emerald" ->
                    "bg-emerald-500 hover:bg-emerald-600"

                "rose" ->
                    "bg-rose-500 hover:bg-rose-600"

                "amber" ->
                    "bg-amber-500 hover:bg-amber-600"

                "violet" ->
                    "bg-violet-500 hover:bg-violet-600"

                _ ->
                    "bg-base-300 hover:bg-base-400"
    in
    div [ class "flex-1 flex flex-col p-4 sm:p-8 overflow-hidden" ]
        [ -- Header (always centered)
          div [ class "mb-8 flex-shrink-0 text-center" ]
            [ div [ class ("text-xs uppercase tracking-widest mb-1 " ++ labelColorClass) ]
                [ text typeLabel ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text (shopCardName data.card) ]
            ]
        , -- Description and upgrade details
          div [ class "overflow-y-auto" ]
            [ if isLevelUpCard data.card then
                -- For LevelUp cards, skip description and show upgrade details
                viewUpgradeDetails data.card skillTree

              else
                -- For other cards, show description
                div [ class "mb-8" ]
                    [ p [ class "text-base-content/60 text-lg leading-relaxed text-center" ]
                        [ text (shopCardDescription data.card) ]
                    ]
            ]
        , -- Action Buttons (always inline with Cancel on mobile, except destroy mode)
          div [ class "pt-8 flex justify-center gap-3 flex-shrink-0" ]
            [ -- Cancel button (mobile only, not in destroy mode)
              if not data.isDestroyMode then
                button
                    [ onClick ClearCardPreview
                    , class "lg:hidden px-6 py-3 rounded-full font-medium transition-all text-base-content bg-base-300/50 hover:bg-base-300"
                    ]
                    [ text "Cancel" ]

              else
                text ""
            , -- Primary action button
              if data.isDestroyMode then
                button
                    [ onClick (DestroyShopCard data.cardId)
                    , class "px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl bg-rose-500 hover:bg-rose-600"
                    ]
                    [ text "Destroy" ]

              else if isDeckBuilderCard data.card then
                button
                    [ onClick (ConfirmDeckBuilder data.cardId)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else if isPlusBombCard data.card then
                button
                    [ onClick (ConfirmPlusBomb data.cardId)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else if isLevelUpCard data.card then
                button
                    [ onClick (MakeShopPick data.cardId)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else
                button
                    [ onClick (MakeShopPick data.cardId)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]
            ]
        ]


{-| Display upgrade details showing current level → new level
-}
viewUpgradeDetails : ShopCard -> SkillTree -> Html Msg
viewUpgradeDetails card skillTree =
    -- Only show for LevelUp cards
    case card.kind of
        Research (LevelUpCard handType) ->
            let
                -- Get current level from skill tree (default to 1)
                currentLevel =
                    case handType of
                        HighCard ->
                            skillTree.highCard

                        Pair ->
                            skillTree.pair

                        TwoPair ->
                            skillTree.twoPair

                        ThreeOfAKind ->
                            skillTree.threeOfAKind

                        Straight ->
                            skillTree.straight

                        Flush ->
                            skillTree.flush

                        FullHouse ->
                            skillTree.fullHouse

                        FourOfAKind ->
                            skillTree.fourOfAKind

                        StraightFlush ->
                            skillTree.straightFlush

                newLevel =
                    currentLevel + 1

                -- Base hand scores
                ( baseChips, baseMult ) =
                    case handType of
                        HighCard ->
                            ( 125, 1 )

                        Pair ->
                            ( 140, 1 )

                        TwoPair ->
                            ( 105, 2 )

                        ThreeOfAKind ->
                            ( 130, 2 )

                        Straight ->
                            ( 70, 4 )

                        Flush ->
                            ( 70, 4 )

                        FullHouse ->
                            ( 70, 5 )

                        FourOfAKind ->
                            ( 50, 12 )

                        StraightFlush ->
                            ( 95, 12 )

                -- Upgrade bonuses per level
                ( upgradeChips, upgradeMult ) =
                    case handType of
                        HighCard ->
                            ( 10, 1 )

                        Pair ->
                            ( 10, 1 )

                        TwoPair ->
                            ( 10, 1 )

                        ThreeOfAKind ->
                            ( 10, 1 )

                        Straight ->
                            ( 10, 1 )

                        Flush ->
                            ( 10, 1 )

                        FullHouse ->
                            ( 10, 1 )

                        FourOfAKind ->
                            ( 20, 2 )

                        StraightFlush ->
                            ( 20, 2 )

                -- Calculate current and new chips/mult
                currentChips =
                    baseChips + (currentLevel - 1) * upgradeChips

                currentMult =
                    baseMult + (currentLevel - 1) * upgradeMult

                newChips =
                    baseChips + (newLevel - 1) * upgradeChips

                newMult =
                    baseMult + (newLevel - 1) * upgradeMult
            in
            div [ class "flex items-center justify-center gap-6" ]
                [ -- Current Level
                  div [ class "text-center" ]
                    [ div [ class "text-xs uppercase tracking-wider text-base-content/40 mb-2" ]
                        [ text ("Level " ++ String.fromInt currentLevel) ]
                    , div [ class "flex items-center gap-3" ]
                        [ div [ class "text-center" ]
                            [ div [ class "text-sm text-base-content/40" ] [ text "Chips" ]
                            , div [ class "text-lg font-semibold text-base-content" ] [ text (String.fromInt currentChips) ]
                            ]
                        , div [ class "text-base-content/20" ] [ text "×" ]
                        , div [ class "text-center" ]
                            [ div [ class "text-sm text-base-content/40" ] [ text "Mult" ]
                            , div [ class "text-lg font-semibold text-base-content" ] [ text (String.fromInt currentMult) ]
                            ]
                        ]
                    ]
                , -- Arrow
                  div [ class "text-base-content/40 text-2xl" ]
                    [ text "→" ]
                , -- New Level
                  div [ class "text-center" ]
                    [ div [ class "text-xs uppercase tracking-wider text-emerald-600 mb-2" ]
                        [ text ("Level " ++ String.fromInt newLevel) ]
                    , div [ class "flex items-center gap-3" ]
                        [ div [ class "text-center" ]
                            [ div [ class "text-sm text-emerald-600/60" ] [ text "Chips" ]
                            , div [ class "text-lg font-semibold text-emerald-600" ] [ text (String.fromInt newChips) ]
                            ]
                        , div [ class "text-emerald-600/40" ] [ text "×" ]
                        , div [ class "text-center" ]
                            [ div [ class "text-sm text-emerald-600/60" ] [ text "Mult" ]
                            , div [ class "text-lg font-semibold text-emerald-600" ] [ text (String.fromInt newMult) ]
                            ]
                        ]
                    ]
                ]

        _ ->
            text ""


{-| Deck builder selection preview
-}
viewDeckBuilderSelectionPreview : DeckBuilderSelectionData -> Html Msg
viewDeckBuilderSelectionPreview data =
    let
        buttonBgClass =
            "bg-violet-500 hover:bg-violet-600"
    in
    div [ class "flex-1 flex flex-col p-4 sm:p-8 overflow-hidden" ]
        [ -- Header (centered)
          div [ class "mb-8 flex-shrink-0 text-center" ]
            [ div [ class "text-xs uppercase tracking-widest mb-1 text-violet-500/60" ]
                [ text "Logistics" ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text (shopCardName data.deckBuilderCard) ]
            ]
        , -- Card selection
          div [ class "overflow-y-auto" ]
            [ div [ class "mb-4 text-center" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text (shopCardDescription data.deckBuilderCard) ]
                ]
            , div [ class "flex flex-wrap gap-3 mb-6 justify-center" ]
                (data.availableCards
                    |> List.map
                        (\card ->
                            let
                                isSelected =
                                    List.member card.id data.selectedCardIds
                            in
                            viewDeckBuilderCardMinimal card isSelected
                        )
                )
            ]
        , -- Action Buttons (always show confirm, disabled when empty)
          div [ class "pt-8 flex justify-center gap-3 flex-shrink-0" ]
            [ let
                hasSelection =
                    not (List.isEmpty data.selectedCardIds)
              in
              button
                [ onClick
                    (if hasSelection then
                        ConfirmSelection

                     else
                        NoOp
                    )
                , class
                    ("px-8 py-3 rounded-full font-medium transition-all "
                        ++ (if hasSelection then
                                "text-white shadow-lg hover:shadow-xl " ++ buttonBgClass

                            else
                                "text-base-content/30 bg-base-300/30 cursor-not-allowed"
                           )
                    )
                ]
                [ text "Confirm" ]
            ]
        ]


{-| Minimal card for deck builder selection
-}
viewDeckBuilderCardMinimal : Card -> Bool -> Html Msg
viewDeckBuilderCardMinimal card isSelected =
    button
        [ class
            ("w-[75px] lg:w-[140px] transition-all cursor-pointer rounded-lg overflow-hidden "
                ++ (if isSelected then
                        "ring-2 ring-violet-500 ring-offset-2 ring-offset-base-100 scale-105 shadow-lg"

                    else
                        "hover:shadow-md hover:scale-102 border border-base-300/50"
                   )
            )
        , onClick (ToggleDeckCardSelection card.id)
        ]
        [ Cards.viewCardImage
            { card = card
            , isFaceDown = False
            , showEnhancement = True
            , compact = False
            , disabled = False
            , enhancementDisabled = False
            }
        ]


{-| Plus bomb selection preview
-}
viewPlusBombSelectionPreview : PlusBombSelectionData -> Html Msg
viewPlusBombSelectionPreview data =
    let
        buttonBgClass =
            "bg-amber-500 hover:bg-amber-600"

        -- Find the shop card for this Plus Bomb
        maybeShopCard =
            data.availableShopCards
                |> List.filter (\c -> shopCardId c == data.cardId)
                |> List.head

        cardDescription =
            case maybeShopCard of
                Just card ->
                    shopCardDescription card

                Nothing ->
                    "Select a card to disable all opponent cards of that rank or suit next round"
    in
    div [ class "flex-1 flex flex-col p-4 sm:p-8 overflow-hidden" ]
        [ -- Header (centered)
          div [ class "mb-8 flex-shrink-0 text-center" ]
            [ div [ class "text-xs uppercase tracking-widest mb-1 text-amber-500/60" ]
                [ text "Sabotage" ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text "Napalm Strikes" ]
            ]
        , -- Card selection
          div [ class "overflow-y-auto" ]
            [ div [ class "mb-4 text-center" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text cardDescription ]
                ]
            , div [ class "flex flex-wrap gap-3 mb-6 justify-center" ]
                (data.availableCards
                    |> List.map
                        (\card ->
                            let
                                isSelected =
                                    data.selectedCardId == Just card.id
                            in
                            viewPlusBombCardMinimal card isSelected
                        )
                )
            ]
        , -- Action Buttons
          div [ class "pt-8 flex justify-center gap-3 flex-shrink-0" ]
            [ let
                hasSelection =
                    data.selectedCardId /= Nothing
              in
              button
                [ onClick
                    (if hasSelection then
                        ConfirmSelection

                     else
                        NoOp
                    )
                , class
                    ("px-8 py-3 rounded-full font-medium transition-all "
                        ++ (if hasSelection then
                                "text-white shadow-lg hover:shadow-xl " ++ buttonBgClass

                            else
                                "text-base-content/30 bg-base-300/30 cursor-not-allowed"
                           )
                    )
                ]
                [ text "Confirm" ]
            ]
        ]


{-| Minimal card for plus bomb selection
-}
viewPlusBombCardMinimal : Card -> Bool -> Html Msg
viewPlusBombCardMinimal card isSelected =
    button
        [ class
            ("w-[75px] lg:w-[140px] transition-all cursor-pointer rounded-lg overflow-hidden "
                ++ (if isSelected then
                        "ring-2 ring-rose-500 ring-offset-2 ring-offset-base-100 scale-105 shadow-lg"

                    else
                        "hover:shadow-md hover:scale-102 border border-base-300/50"
                   )
            )
        , onClick (SelectPlusBombCard card.id)
        ]
        [ Cards.viewCardImage
            { card = card
            , isFaceDown = False
            , showEnhancement = True
            , compact = False
            , disabled = False
            , enhancementDisabled = False
            }
        ]
