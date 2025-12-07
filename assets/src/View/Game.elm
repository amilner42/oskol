module View.Game exposing (viewGame)

{-| Main game view matching LiveView styling
-}

import Dict exposing (Dict)
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

        Success gameState ->
            viewGameState model gameState


{-| View loading state
-}
viewLoading : String -> Html Msg
viewLoading message =
    div [ class "min-h-screen bg-[#1a1d29] flex items-center justify-center" ]
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


{-| View the active game state with LiveView-style layout
-}
viewGameState : Model -> GameState -> Html Msg
viewGameState model gameState =
    let
        maybeCurrentPlayer =
            getCurrentPlayer model

        maybeOpponent =
            getOpponentPlayer model
    in
    case ( maybeCurrentPlayer, maybeOpponent, model.playerId ) of
        ( Just currentPlayer, Just opponent, Just playerId ) ->
            let
                playerName =
                    getPlayerName gameState playerId

                opponentName =
                    getPlayerName gameState opponent.playerId
            in
            -- Check game status and phase
            case gameState.gameStatus of
                GameOver ->
                    -- Full-screen match summary
                    viewMatchSummary model gameState playerId playerName currentPlayer opponent opponentName

                Active ->
                    case ( gameState.phase, gameState.shopState, model.viewingResults ) of
                        ( RoundEnd, Just shopState, False ) ->
                            -- Full-page shop view (only if not viewing score animation)
                            viewShop model gameState shopState

                        _ ->
                            -- Normal game layout
                            div [ class "flex flex-col h-screen bg-[#1a1d29] overflow-hidden" ]
                                [ -- Top - Opponent Cards
                                  div [ class "shrink-0 flex flex-col justify-end pt-2 px-0 pb-1 sm:pt-2 sm:px-3 sm:pb-3 bg-[#0C0F14]" ]
                                    [ viewOpponentCards opponent model.newCardIds model.cardSort
                                    ]
                                , -- Middle - Playing Area
                                  div [ class "flex-1 min-h-0 flex flex-col bg-[#161B1F] shadow-[0_0_30px_-5px_rgba(0,0,0,0.5)] relative" ]
                                    [ div [ class "flex-1 flex flex-col justify-center" ]
                                        [ viewPlayingArea model gameState currentPlayer opponent playerId
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


{-| View opponent's cards at the top
-}
viewOpponentCards : PlayerState -> Set String -> CardSort -> Html Msg
viewOpponentCards opponent newCardIds cardSort =
    let
        sortedCards =
            sortCards cardSort opponent.cardPiles.handPile
    in
    div [ class "flex gap-1 sm:gap-3 md:gap-4 justify-center px-2 sm:px-0" ]
        (List.map
            (\card ->
                let
                    isNew =
                        Set.member card.id newCardIds

                    isFaceDown =
                        List.member card.id opponent.faceDownCardIds

                    isDisabled =
                        List.member card.rank opponent.disabledRanks
                            || List.member card.suit opponent.disabledSuits
                in
                div
                    [ classList
                        [ ( "flex-1 min-w-0 max-w-[112px] aspect-[5/7]", True )
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
        [ div [ class "flex gap-1 sm:gap-3 md:gap-4 justify-center px-2 sm:px-0" ]
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
                            List.member card.rank player.disabledRanks
                                || List.member card.suit player.disabledSuits

                        canSelect =
                            not (atLimit && not isSelected) && not isLockedIn
                    in
                    button
                        [ onClick (ToggleCardSelection card.id)
                        , disabled (not canSelect)
                        , classList
                            [ ( "flex-1 min-w-0 max-w-[112px] transition-all touch-manipulation", True )
                            , ( "-translate-y-2 sm:-translate-y-3 md:-translate-y-4", isSelected )
                            , ( "opacity-50 cursor-not-allowed", not canSelect )
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
        , viewSortButton model.cardSort
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
                    case compare b.rank a.rank of
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
                            compare b.rank a.rank

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

                        RoundEnd ->
                            viewRoundEnd model gameState currentPlayer
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
                |> List.sortWith (\a b -> compare b.rank a.rank)
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
                                List.member card.rank player.disabledRanks
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


{-| View round end state (when not in shop)
-}
viewRoundEnd : Model -> GameState -> PlayerState -> Html Msg
viewRoundEnd model gameState currentPlayer =
    case gameState.gameStatus of
        GameOver ->
            viewGameOver gameState

        Active ->
            -- Shop is shown at top level, so here we only show ready button
            viewReadyForNextRound currentPlayer


{-| View game over screen - matches LiveView exactly
-}
viewGameOver : GameState -> Html Msg
viewGameOver gameState =
    text ""


{-| View animated score results - shows both players' hands with animated score breakdown
-}
viewAnimatedScoreResults : Model -> GameState -> String -> String -> String -> Html Msg
viewAnimatedScoreResults model gameState playerId playerName opponentName =
    case gameState.lastHandResults of
        Just handResults ->
            let
                -- Get opponent ID
                opponentId =
                    Dict.keys gameState.players
                        |> List.filter (\id -> id /= playerId)
                        |> List.head
                        |> Maybe.withDefault ""

                -- Sort by player name alphabetically to determine animation order
                playerNames =
                    [ ( playerId, playerName ), ( opponentId, opponentName ) ]
                        |> List.sortBy Tuple.second

                ( firstPlayerId, firstPlayerName ) =
                    List.head playerNames |> Maybe.withDefault ( "", "" )

                ( secondPlayerId, secondPlayerName ) =
                    List.drop 1 playerNames |> List.head |> Maybe.withDefault ( "", "" )

                firstResult =
                    Dict.get firstPlayerId handResults

                secondResult =
                    Dict.get secondPlayerId handResults

                firstPlayer =
                    Dict.get firstPlayerId gameState.players

                secondPlayer =
                    Dict.get secondPlayerId gameState.players

                -- Determine animation state for each player
                firstAnimState =
                    getPlayerAnimationState model.scoreAnimation firstResult True

                secondAnimState =
                    getPlayerAnimationState model.scoreAnimation secondResult False
            in
            div [ class "text-center space-y-8 sm:space-y-16 animate-fadeInScale w-full px-2 sm:px-4" ]
                [ -- First player (alphabetically - opponent in phases)
                  case ( firstResult, firstPlayer, firstAnimState ) of
                    ( Just result, Just player, Just animState ) ->
                        viewScoreBreakdownRow
                            result
                            player.skillTree
                            firstPlayerName
                            (firstPlayerId == playerId)
                            animState

                    _ ->
                        text ""
                , -- Second player (alphabetically - player in phases)
                  case ( secondResult, secondPlayer, secondAnimState ) of
                    ( Just result, Just player, Just animState ) ->
                        viewScoreBreakdownRow
                            result
                            player.skillTree
                            secondPlayerName
                            (secondPlayerId == playerId)
                            animState

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


{-| Get animation state for a specific player based on global animation phase
-}
getPlayerAnimationState : ScoreAnimationState -> Maybe HandResult -> Bool -> Maybe AnimationState
getPlayerAnimationState globalAnim maybeResult isFirstPlayer =
    case maybeResult of
        Just result ->
            let
                cardCount =
                    List.length result.scoreBreakdown.cardBreakdowns

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

        Nothing ->
            Nothing


{-| View score breakdown for one player with animated cards and formula
-}
viewScoreBreakdownRow : HandResult -> SkillTree -> String -> Bool -> AnimationState -> Html Msg
viewScoreBreakdownRow result skillTree playerName isCurrentPlayer animState =
    let
        breakdown =
            result.scoreBreakdown

        -- Sort cards by rank for display
        sortedHand =
            List.sortBy (\c -> ( -c.rank, suitOrder c.suit )) result.hand

        sortedBreakdowns =
            List.sortBy (\b -> ( -b.card.rank, suitOrder b.card.suit )) breakdown.cardBreakdowns

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
                                , disabled = False
                                , enhancementDisabled = False
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
            model.rematchRequested

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
            , -- Player cards grid
              div [ class "grid grid-cols-2 gap-6 mb-8" ]
                [ viewPlayerResultCard playerName playerState.lives gameState.initialLives isWinner "text-player"
                , viewPlayerResultCard opponentName opponentState.lives gameState.initialLives (not isWinner) "text-opponent"
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
                    -- Both ready - show starting match
                    { bgClasses = "bg-gradient-to-r from-emerald-500 to-emerald-600 animate-pulse text-white"
                    , borderClasses = "border-emerald-400 shadow-[0_0_30px_rgba(16,185,129,0.5)]"
                    , textContent = "Starting match..."
                    , clickable = False
                    }

                ( True, False ) ->
                    -- Player ready - blue scanning animation
                    { bgClasses = "bg-white text-gray-900 relative overflow-hidden"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = False
                    }

                ( False, True ) ->
                    -- Opponent ready - orange scanning animation
                    { bgClasses = "bg-white text-gray-900 relative overflow-hidden"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = True
                    }

                ( False, False ) ->
                    -- Neither ready - white button with dark text
                    { bgClasses = "bg-white hover:bg-gray-50 text-gray-900 shadow-md hover:shadow-lg"
                    , borderClasses = "border-gray-200"
                    , textContent = "Rematch"
                    , clickable = True
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
            [ -- Barcode scanning animation overlay (multiple thin lines)
              if playerReady && not opponentReady then
                -- Player ready - blue progress fill
                div [ class "absolute inset-0 pointer-events-none rounded-xl overflow-hidden" ]
                    [ div
                        [ class "absolute inset-y-0 left-0 h-full bg-blue-500"
                        , Html.Attributes.style "animation" "progress-fill 1.5s ease-out forwards"
                        ]
                        []
                    ]

              else if opponentReady && not playerReady then
                -- Opponent ready - orange progress fill
                div [ class "absolute inset-0 pointer-events-none rounded-xl overflow-hidden" ]
                    [ div
                        [ class "absolute inset-y-0 left-0 h-full bg-orange-500"
                        , Html.Attributes.style "animation" "progress-fill 1.5s ease-out forwards"
                        ]
                        []
                    ]

              else
                text ""
            , -- Button text
              Html.span [ class "relative z-10" ] [ text buttonState.textContent ]
            ]
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


{-| View shop interface - full page view
-}
viewShop : Model -> GameState -> ShopState -> Html Msg
viewShop model gameState shopState =
    case ( model.playerId, model.shopUIState ) of
        ( Just playerId, Just uiState ) ->
            viewShopWithUIState model gameState shopState playerId uiState

        _ ->
            div [ class "flex items-center justify-center h-screen" ]
                [ text "Loading..." ]


{-| View shop with UI state pattern matching
-}
viewShopWithUIState : Model -> GameState -> ShopState -> String -> ShopUIState -> Html Msg
viewShopWithUIState model gameState shopState playerId uiState =
    let
        -- Get player states for lives display
        maybePlayerState =
            Dict.get playerId gameState.players

        maybeOpponentState =
            Dict.toList gameState.players
                |> List.filter (\( pid, _ ) -> pid /= playerId)
                |> List.head
                |> Maybe.map Tuple.second

        playerName =
            Dict.get playerId gameState.playerNames
                |> Maybe.withDefault "You"

        opponentName =
            Dict.toList gameState.playerNames
                |> List.filter (\( pid, _ ) -> pid /= playerId)
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault "Opponent"

        -- Extract common data from UI state
        ( availableCards, pickedIndices, destroyedIndices ) =
            case uiState of
                DestroyPhase data ->
                    ( data.availableCards, [], data.destroyedIndices )

                WaitingForOpponent data ->
                    ( data.availableCards, data.pickedIndices, data.destroyedIndices )

                BrowsingCards data ->
                    ( data.availableCards, data.pickedIndices, data.destroyedIndices )

                PreviewingCard data ->
                    ( data.availableCards, data.pickedIndices, data.destroyedIndices )

                SelectingDeckBuilderCards data ->
                    ( data.availableShopCards, data.pickedIndices, data.destroyedIndices )

                SelectingPlusBombCard data ->
                    ( data.availableShopCards, data.pickedIndices, data.destroyedIndices )

                ShopComplete data ->
                    ( data.availableCards, data.pickedIndices, data.destroyedIndices )

        pickedIndicesSet =
            Set.fromList pickedIndices

        destroyedIndicesSet =
            Set.fromList destroyedIndices

        -- Determine if player can pick (for card grid styling)
        canPick =
            case uiState of
                BrowsingCards _ ->
                    True

                PreviewingCard _ ->
                    True

                DestroyPhase data ->
                    data.isMyTurn

                _ ->
                    False

        -- Get previewing card index for grid highlighting (backwards compat)
        previewingCardIndex =
            case uiState of
                PreviewingCard data ->
                    Just data.cardIndex

                SelectingDeckBuilderCards data ->
                    Just data.cardIndex

                SelectingPlusBombCard data ->
                    Just data.cardIndex

                _ ->
                    Nothing
    in
    div [ class "h-screen bg-gradient-to-br from-base-200 via-base-100 to-base-200 overflow-auto" ]
        [ div [ class "min-h-full flex flex-col lg:flex-row lg:h-screen" ]
            [ -- Section 1: Header (order-1 on mobile, part of left column on desktop)
              div [ class "order-1 lg:order-none lg:w-[440px] xl:w-[540px] lg:flex-shrink-0 lg:border-r border-base-300/50 bg-base-100/50 lg:flex lg:flex-col lg:h-screen" ]
                [ -- Header
                  div [ class "p-6 border-b border-base-300/50 flex-shrink-0" ]
                    [ div [ class "flex items-center justify-between mb-4" ]
                        [ div [ class "text-2xl font-light text-base-content" ]
                            [ text "Command Center" ]
                        , div [ class "flex items-center gap-2" ]
                            [ div [ class "text-xs uppercase tracking-wider text-base-content/40" ]
                                [ text "Round" ]
                            , div [ class "text-lg font-semibold text-base-content" ]
                                [ text (String.fromInt gameState.roundNumber) ]
                            ]
                        ]
                    , -- Lives status
                      case ( maybePlayerState, maybeOpponentState ) of
                        ( Just playerState, Just opponentState ) ->
                            div [ class "flex items-center gap-4" ]
                                [ -- Player lives
                                  div [ class "flex items-center gap-2" ]
                                    [ span [ class "text-xs text-player font-medium" ]
                                        [ text playerName ]
                                    , div [ class "flex items-center gap-0.5" ]
                                        (List.range 1 gameState.initialLives
                                            |> List.map
                                                (\i ->
                                                    if i <= playerState.lives then
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
                                        [ text opponentName ]
                                    , div [ class "flex items-center gap-0.5" ]
                                        (List.range 1 gameState.initialLives
                                            |> List.map
                                                (\i ->
                                                    if i <= opponentState.lives then
                                                        span [ class "text-error" ] [ text "♥" ]

                                                    else
                                                        span [ class "text-base-content/20" ] [ text "♥" ]
                                                )
                                        )
                                    ]
                                ]

                        _ ->
                            text ""
                    ]
                , -- Cards Grid (hidden on mobile, shown on desktop)
                  div [ class "hidden lg:block flex-1 p-6 overflow-y-auto" ]
                    [ viewShopCardsGrid availableCards canPick pickedIndicesSet destroyedIndicesSet previewingCardIndex uiState shopState playerId playerName opponentName
                    ]
                ]
            , -- Section 2: Timeline (order-2 on mobile)
              div [ class "order-2 lg:order-none lg:flex-1 lg:flex lg:flex-col lg:h-screen lg:overflow-hidden" ]
                [ div [ class "flex-shrink-0" ]
                    [ viewPickTimeline shopState playerId playerName opponentName ]
                , -- Preview Panel (hidden on mobile, shown on desktop)
                  div [ class "hidden lg:flex flex-1 flex-col overflow-hidden" ]
                    [ viewPreviewPanelByState uiState ]
                ]
            , -- Section 3: Cards (order-3 on mobile only, 2 rows with horizontal scroll)
              div [ class "order-3 lg:hidden px-3 py-3 border-t border-base-300/50 bg-base-100/50" ]
                [ -- Arsenal Section (Permanent Upgrades)
                  div [ class "mb-4" ]
                    [ div [ class "mb-2 flex items-center gap-2" ]
                        [ div [ class "text-xs font-semibold uppercase tracking-wider text-base-content/40" ]
                            [ text "Arsenal" ]
                        , div [ class "text-[10px] text-base-content/40" ]
                            [ text "Permanent Upgrades" ]
                        ]
                    , div [ class "flex gap-2 overflow-x-auto pb-2" ]
                        (availableCards
                            |> List.take 8
                            |> List.indexedMap
                                (\index shopCard ->
                                    viewShopCardMinimal shopCard index canPick pickedIndicesSet destroyedIndicesSet previewingCardIndex uiState shopState playerId playerName opponentName
                                )
                        )
                    ]
                , -- Tactical Ops Section (Action Cards)
                  div []
                    [ div [ class "mb-2 flex items-center gap-2" ]
                        [ div [ class "text-xs font-semibold uppercase tracking-wider text-base-content/40" ]
                            [ text "Tactical Ops" ]
                        , div [ class "text-[10px] text-base-content/40" ]
                            [ text "Temporary Battlefield Advantage" ]
                        ]
                    , div [ class "flex gap-2 overflow-x-auto pb-2" ]
                        (availableCards
                            |> List.drop 8
                            |> List.indexedMap
                                (\relIndex shopCard ->
                                    let
                                        index =
                                            relIndex + 8
                                    in
                                    viewShopCardMinimal shopCard index canPick pickedIndicesSet destroyedIndicesSet previewingCardIndex uiState shopState playerId playerName opponentName
                                )
                        )
                    ]
                ]
            , -- Section 4: Preview (order-4 on mobile only) - now a bottom sheet modal
              viewMobilePreviewModal uiState
            ]
        ]


{-| Mobile preview modal - slides up from bottom when there's content to show
-}
viewMobilePreviewModal : ShopUIState -> Html Msg
viewMobilePreviewModal uiState =
    let
        -- Check if there's something to preview
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
        -- Modal overlay + bottom sheet
        div [ class "lg:hidden fixed inset-0 z-50 flex items-end" ]
            [ -- Backdrop
              div
                [ class "absolute inset-0 bg-black/50 backdrop-blur-sm"
                , onClick ClearCardPreview
                ]
                []
            , -- Bottom sheet
              div [ class "relative w-full max-h-[85vh] bg-base-100 rounded-t-2xl shadow-2xl overflow-hidden animate-slide-up" ]
                [ -- Content (scrollable)
                  div [ class "overflow-y-auto max-h-[85vh]" ]
                    [ viewPreviewPanelByState uiState ]
                ]
            ]

    else
        text ""


{-| View turn indicator for shop (state-based)
-}
viewTurnIndicatorByState : ShopUIState -> Html Msg
viewTurnIndicatorByState uiState =
    let
        isYourTurn =
            case uiState of
                BrowsingCards _ ->
                    True

                PreviewingCard _ ->
                    True

                DestroyPhase data ->
                    data.isMyTurn

                _ ->
                    False
    in
    div
        [ class
            (if isYourTurn then
                "px-3 py-1.5 rounded-full text-xs font-medium bg-emerald-500/10 text-emerald-600"

             else
                "px-3 py-1.5 rounded-full text-xs font-medium bg-base-300/50 text-base-content/40"
            )
        ]
        [ text
            (if isYourTurn then
                "Your pick"

             else
                "Waiting"
            )
        ]


{-| Shop cards grid with Arsenal and Tactical Ops sections
-}
viewShopCardsGrid : List ShopCard -> Bool -> Set Int -> Set Int -> Maybe Int -> ShopUIState -> ShopState -> String -> String -> String -> Html Msg
viewShopCardsGrid availableCards canPick pickedIndices destroyedIndices previewingCardIndex uiState shopState playerId playerName opponentName =
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
                (availableCards
                    |> List.take 8
                    |> List.indexedMap
                        (\index shopCard ->
                            viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex uiState shopState playerId playerName opponentName
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
                (availableCards
                    |> List.drop 8
                    |> List.indexedMap
                        (\relIndex shopCard ->
                            let
                                index =
                                    relIndex + 8
                            in
                            viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex uiState shopState playerId playerName opponentName
                        )
                )
            ]
        ]


{-| Minimal shop card - just badge and name (no description)
-}
viewShopCardMinimal : ShopCard -> Int -> Bool -> Set Int -> Set Int -> Maybe Int -> ShopUIState -> ShopState -> String -> String -> String -> Html Msg
viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex uiState shopState playerId playerName opponentName =
    let
        isPicked =
            Set.member index pickedIndices

        isDestroyed =
            Set.member index destroyedIndices

        -- Determine who picked this card
        pickerNameForCard =
            if isPicked then
                -- Find position of this card in picked indices
                let
                    reversedPicked =
                        shopState.pickedCardIndices |> List.reverse

                    maybePosition =
                        reversedPicked
                            |> List.indexedMap (\i cardIdx -> if cardIdx == index then Just i else Nothing)
                            |> List.filterMap identity
                            |> List.head
                in
                case maybePosition of
                    Just position ->
                        -- Determine who picked at this position (1-indexed)
                        let
                            pickNum = position + 1
                        in
                        if modBy 2 pickNum == 1 then
                            -- First picker
                            if shopState.firstPickerId == playerId then
                                playerName
                            else
                                opponentName
                        else
                            -- Second picker
                            if shopState.secondPickerId == playerId then
                                playerName
                            else
                                opponentName

                    Nothing ->
                        "Picked"
            else
                "Picked"

        isSelected =
            previewingCardIndex == Just index

        isDisabled =
            isPicked || isDestroyed || not canPick

        accentColor =
            case shopCard.cardType of
                LevelUp ->
                    "emerald"

                Denial ->
                    "rose"

                Sabotage ->
                    "amber"

                DeckBuilder ->
                    "violet"

        typeLabel =
            case shopCard.cardType of
                LevelUp ->
                    "RESEARCH"

                Denial ->
                    "COUNTER"

                Sabotage ->
                    "SABOTAGE"

                DeckBuilder ->
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
                "border-base-300/30"

            else if not isDisabled then
                "border-base-300/50 hover:border-" ++ accentColor ++ "-400 hover:shadow-md"

            else
                "border-base-300/30"

        opacityClass =
            if isPicked || isDestroyed then
                "opacity-50"

            else
                "opacity-100"

        cursorClass =
            if isDisabled then
                "cursor-not-allowed"

            else
                "cursor-pointer"

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
        [ class ("w-[100px] lg:w-full aspect-[2/3] rounded-xl p-2 lg:p-4 flex flex-col transition-all relative overflow-hidden flex-shrink-0 bg-base-100 border-2 " ++ borderClass ++ " " ++ opacityClass ++ " " ++ cursorClass)
        , onClick
            (if isDisabled then
                NoOp

             else
                -- Always preview the card, the action button in preview will differ
                PreviewShopCard index
            )
        , Html.Attributes.disabled isDisabled
        ]
        [ -- Type badge at top
          div [ class ("text-[8px] lg:text-[10px] font-bold uppercase tracking-wider mb-1 lg:mb-2 " ++ labelColor) ]
            [ text typeLabel ]
        , -- Card name centered
          div [ class "flex-1 flex items-center justify-center" ]
            [ div [ class "font-semibold text-xs lg:text-sm text-center leading-tight text-base-content" ]
                [ text shopCard.name ]
            ]
        , -- Picked/Destroyed overlay
          if isPicked then
            div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                [ span [ class "text-xs text-base-content/40 font-medium" ]
                    [ text pickerNameForCard ]
                ]

          else if isDestroyed then
            div [ class "absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl" ]
                [ span [ class "text-xs text-rose-400 font-medium" ]
                    [ text "Destroyed" ]
                ]

          else
            text ""
        ]


{-| Pick timeline showing all picks and destroys
-}
viewPickTimeline : ShopState -> String -> String -> String -> Html Msg
viewPickTimeline shopState playerId playerName opponentName =
    let
        firstPickerName =
            if shopState.firstPickerId == playerId then
                playerName

            else
                opponentName

        secondPickerName =
            if shopState.secondPickerId == playerId then
                playerName

            else
                opponentName

        -- Destroyer name (if there is one)
        destroyerName =
            case shopState.destroyerId of
                Just destroyerId ->
                    if destroyerId == playerId then
                        Just playerName
                    else
                        Just opponentName
                Nothing ->
                    Nothing

        totalDestroys =
            shopState.destroysAllowed

        totalPicks =
            shopState.totalRounds * 2

        destroyedCount =
            List.length shopState.destroyedCardIndices

        pickedCount =
            List.length shopState.pickedCardIndices

        reversedDestroyedIndices =
            List.reverse shopState.destroyedCardIndices

        reversedPickedIndices =
            List.reverse shopState.pickedCardIndices

        -- Create destroy slots
        destroySlots =
            List.range 1 totalDestroys
                |> List.map
                    (\destroyNum ->
                        let
                            maybeCardIndex =
                                reversedDestroyedIndices
                                    |> List.drop (destroyNum - 1)
                                    |> List.head

                            maybeCard =
                                maybeCardIndex
                                    |> Maybe.andThen (\idx -> shopState.availableCards |> List.drop idx |> List.head)

                            isCurrent =
                                not shopState.destroyPhaseComplete
                                && destroyNum == (destroyedCount + 1)
                                && destroyedCount < totalDestroys

                            -- Check if this is the player's action
                            isPlayerAction =
                                case shopState.destroyerId of
                                    Just destroyerId ->
                                        destroyerId == playerId
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
                                    shopState.firstPickerId
                                else
                                    shopState.secondPickerId

                            pickerName =
                                if modBy 2 pickNum == 1 then
                                    firstPickerName

                                else
                                    secondPickerName

                            maybeCardIndex =
                                reversedPickedIndices
                                    |> List.drop (pickNum - 1)
                                    |> List.head

                            maybeCard =
                                maybeCardIndex
                                    |> Maybe.andThen (\idx -> shopState.availableCards |> List.drop idx |> List.head)

                            isCurrent =
                                shopState.destroyPhaseComplete
                                && pickNum == (pickedCount + 1)
                                && pickedCount < totalPicks

                            -- Check if this is the player's pick
                            isPlayerAction =
                                pickerId == playerId
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


{-| Single timeline slot
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
            ordinal ++ " " ++ slotType

        ( containerClass, labelColor ) =
            if maybeCard /= Nothing then
                if slotType == "DESTROY" then
                    ( "bg-base-100 border-rose-400/30", "text-rose-500/60" )
                else
                    ( "bg-base-100 border-base-300/50", "text-base-content/40" )

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
                let
                    dotColor =
                        case card.cardType of
                            LevelUp ->
                                "bg-emerald-500"

                            Denial ->
                                "bg-rose-500"

                            Sabotage ->
                                "bg-amber-500"

                            DeckBuilder ->
                                "bg-violet-500"
                in
                div [ class "flex items-center gap-1.5 lg:gap-2" ]
                    [ div [ class ("w-1.5 h-1.5 lg:w-2 lg:h-2 rounded-full flex-shrink-0 " ++ dotColor) ] []
                    , div [ class "min-w-0" ]
                        [ div [ class "text-xs lg:text-sm font-medium text-base-content truncate" ]
                            [ text card.name ]
                        , div [ class "text-[9px] lg:text-[10px] text-base-content/40" ]
                            [ text pickerName ]
                        ]
                    ]

            Nothing ->
                div [ class "text-xs lg:text-sm text-base-content/30" ]
                    [ text pickerName ]
        ]


{-| Preview panel - exhaustive pattern match on UI state
-}
viewPreviewPanelByState : ShopUIState -> Html Msg
viewPreviewPanelByState uiState =
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
            viewShopCardPreview data

        SelectingDeckBuilderCards data ->
            viewDeckBuilderSelectionPreview data

        SelectingPlusBombCard data ->
            viewPlusBombSelectionPreview data

        ShopComplete _ ->
            viewShopCompletePreview


{-| Destroy phase instructions
-}
viewDestroyInstructions : Int -> Html Msg
viewDestroyInstructions destroysRemaining =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ div [ class "w-20 h-20 rounded-full bg-rose-500/10 mx-auto mb-4 flex items-center justify-center" ]
                [ span [ class "text-4xl font-light text-rose-500" ]
                    [ text (String.fromInt destroysRemaining) ]
                ]
            , p [ class "text-base-content/60 text-lg font-light mb-2" ]
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
            [ div [ class "w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center" ]
                [ span [ class "text-4xl animate-pulse" ] [ text "⏳" ] ]
            , p [ class "text-base-content/40 text-lg font-light" ]
                [ text message ]
            ]
        ]


{-| Empty preview when browsing
-}
viewEmptyBrowsingPreview : Html Msg
viewEmptyBrowsingPreview =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ div [ class "w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center" ]
                [ span [ class "text-4xl" ] [ text "👆" ] ]
            , p [ class "text-base-content/40 text-lg font-light" ]
                [ text "Select a card to preview" ]
            ]
        ]


{-| Shop complete preview
-}
viewShopCompletePreview : Html Msg
viewShopCompletePreview =
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ div [ class "w-20 h-20 rounded-full bg-emerald-500/10 mx-auto mb-4 flex items-center justify-center" ]
                [ span [ class "text-4xl font-light text-emerald-500" ]
                    [ text "✓" ]
                ]
            , p [ class "text-base-content/60 text-lg font-light mb-2" ]
                [ text "All picks complete!" ]
            , p [ class "text-base-content/40 text-sm" ]
                [ text "Next round starting soon..." ]
            ]
        ]


{-| Display upgrade details showing current level → new level
-}
viewUpgradeDetails : ShopCard -> SkillTree -> Html Msg
viewUpgradeDetails card skillTree =
    -- Only show for LevelUp cards with a hand type subtype
    if card.cardType == LevelUp then
        let
            handType =
                card.subtype

            -- Get current level from skill tree (default to 1)
            currentLevel =
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

            newLevel =
                currentLevel + 1

            -- Base hand scores (from Elixir @base_hand_scores)
            ( baseChips, baseMult ) =
                case handType of
                    "high_card" ->
                        ( 125, 1 )

                    "pair" ->
                        ( 140, 1 )

                    "two_pair" ->
                        ( 105, 2 )

                    "three_of_a_kind" ->
                        ( 130, 2 )

                    "straight" ->
                        ( 70, 4 )

                    "flush" ->
                        ( 70, 4 )

                    "full_house" ->
                        ( 70, 5 )

                    "four_of_a_kind" ->
                        ( 50, 12 )

                    "straight_flush" ->
                        ( 95, 12 )

                    _ ->
                        ( 0, 0 )

            -- Upgrade bonuses per level (from Elixir @upgrade_bonuses)
            ( upgradeChips, upgradeMult ) =
                case handType of
                    "high_card" ->
                        ( 10, 1 )

                    "pair" ->
                        ( 10, 1 )

                    "two_pair" ->
                        ( 10, 1 )

                    "three_of_a_kind" ->
                        ( 10, 1 )

                    "straight" ->
                        ( 10, 1 )

                    "flush" ->
                        ( 10, 1 )

                    "full_house" ->
                        ( 10, 1 )

                    "four_of_a_kind" ->
                        ( 20, 2 )

                    "straight_flush" ->
                        ( 20, 2 )

                    _ ->
                        ( 0, 0 )

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

    else
        text ""


{-| Shop card preview (regular card)
-}
viewShopCardPreview : PreviewCardData -> Html Msg
viewShopCardPreview data =
    let
        accentColor =
            case data.card.cardType of
                LevelUp ->
                    "emerald"

                Denial ->
                    "rose"

                Sabotage ->
                    "amber"

                DeckBuilder ->
                    "violet"

        typeLabel =
            case data.card.cardType of
                LevelUp ->
                    "Research"

                Denial ->
                    "Counter"

                Sabotage ->
                    "Sabotage"

                DeckBuilder ->
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
                [ text data.card.name ]
            ]
        , -- Description and upgrade details
          div [ class "overflow-y-auto" ]
            [ case data.card.cardType of
                LevelUp ->
                    -- For LevelUp cards, skip description and show upgrade details
                    viewUpgradeDetails data.card data.skillTree

                _ ->
                    -- For other cards, show description
                    div [ class "mb-8" ]
                        [ p [ class "text-base-content/60 text-lg leading-relaxed text-center" ]
                            [ text data.card.description ]
                        ]
            ]
        , -- Action Buttons (always inline with Cancel on mobile)
          div [ class "pt-8 flex justify-center gap-3 flex-shrink-0" ]
            [ -- Cancel button (mobile only)
              button
                [ onClick ClearCardPreview
                , class "lg:hidden px-6 py-3 rounded-full font-medium transition-all text-base-content bg-base-300/50 hover:bg-base-300"
                ]
                [ text "Cancel" ]
            , -- Primary action button
              if data.isDestroyMode then
                button
                    [ onClick (DestroyShopCard data.cardIndex)
                    , class "px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl bg-rose-500 hover:bg-rose-600"
                    ]
                    [ text "Destroy" ]

              else if data.card.cardType == DeckBuilder then
                button
                    [ onClick (ConfirmDeckBuilder data.cardIndex)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else if data.card.cardType == Sabotage && data.card.subtype == "plus_bomb" then
                button
                    [ onClick (ConfirmPlusBomb data.cardIndex)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else if data.card.cardType == LevelUp then
                button
                    [ onClick (MakeShopPick data.cardIndex)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]

              else
                button
                    [ onClick (MakeShopPick data.cardIndex)
                    , class ("px-8 py-3 rounded-full font-medium transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm" ]
            ]
        ]


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
                [ text data.deckBuilderCard.name ]
            ]
        , -- Card selection
          div [ class "overflow-y-auto" ]
            [ div [ class "mb-4 text-center" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text ("Select up to " ++ String.fromInt data.maxSelection ++ " cards to enhance") ]
                ]
            , div [ class "grid grid-cols-4 gap-2 sm:flex sm:flex-wrap sm:justify-center sm:gap-3 mb-6" ]
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
                hasSelection = not (List.isEmpty data.selectedCardIds)
              in
              button
                [ onClick (if hasSelection then ConfirmSelection else NoOp)
                , class ("px-8 py-3 rounded-full font-medium transition-all " ++
                    if hasSelection then
                        "text-white shadow-lg hover:shadow-xl " ++ buttonBgClass
                    else
                        "text-base-content/30 bg-base-300/30 cursor-not-allowed"
                  )
                ]
                [ text "Confirm" ]
            ]
        ]


{-| Plus bomb selection preview
-}
viewPlusBombSelectionPreview : PlusBombSelectionData -> Html Msg
viewPlusBombSelectionPreview data =
    let
        buttonBgClass =
            "bg-amber-500 hover:bg-amber-600"
    in
    div [ class "flex-1 flex flex-col p-4 sm:p-8 overflow-hidden" ]
        [ -- Header (centered)
          div [ class "mb-8 flex-shrink-0 text-center" ]
            [ div [ class "text-xs uppercase tracking-widest mb-1 text-amber-500/60" ]
                [ text "Sabotage" ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text "Plus Bomb" ]
            ]
        , -- Card selection
          div [ class "flex-1 overflow-y-auto" ]
            [ div [ class "mb-4 text-center" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text "Select a card - that rank AND suit won't score for opponent" ]
                ]
            , div [ class "grid grid-cols-4 gap-2 sm:flex sm:flex-wrap sm:justify-center sm:gap-3 mb-6" ]
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
        , -- Action Buttons (always show confirm, disabled when empty)
          div [ class "pt-8 flex justify-center gap-3 flex-shrink-0" ]
            [ let
                hasSelection = data.selectedCardId /= Nothing
              in
              button
                [ onClick (if hasSelection then ConfirmSelection else NoOp)
                , class ("px-8 py-3 rounded-full font-medium transition-all " ++
                    if hasSelection then
                        "text-white shadow-lg hover:shadow-xl " ++ buttonBgClass
                    else
                        "text-base-content/30 bg-base-300/30 cursor-not-allowed"
                  )
                ]
                [ text "Confirm" ]
            ]
        ]


{-| OLD - Card detail view in preview panel (TO BE REMOVED)
-}
viewCardDetail : ShopCard -> Int -> Bool -> ShopState -> String -> List String -> Maybe String -> Html Msg
viewCardDetail shopCard cardIndex canPick shopState playerId deckBuilderSelection plusBombSelection =
    let
        accentColor =
            case shopCard.cardType of
                LevelUp ->
                    "emerald"

                Denial ->
                    "rose"

                Sabotage ->
                    "amber"

                DeckBuilder ->
                    "violet"

        typeLabel =
            case shopCard.cardType of
                LevelUp ->
                    "Research"

                Denial ->
                    "Counter"

                Sabotage ->
                    "Sabotage"

                DeckBuilder ->
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

        -- Check if we're in deck builder selection mode for this card
        hasDeckBuilderSelection =
            case shopState.pendingDeckBuilder of
                Just pending ->
                    pending.shopCardIndex == cardIndex && pending.playerId == playerId

                Nothing ->
                    False

        -- Check if we're in plus bomb selection mode for this card
        hasPlusBombSelection =
            case shopState.pendingPlusBomb of
                Just pending ->
                    pending.shopCardIndex == cardIndex && pending.playerId == playerId

                Nothing ->
                    False
    in
    div [ class "flex-1 flex flex-col p-8 overflow-hidden" ]
        [ -- Header
          div [ class "mb-8 flex-shrink-0" ]
            [ div [ class ("text-xs uppercase tracking-widest mb-1 " ++ labelColorClass) ]
                [ text typeLabel ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text shopCard.name ]
            ]
        , -- Description or card selection
          if hasDeckBuilderSelection then
            case shopState.pendingDeckBuilder of
                Just pending ->
                    div [ class "flex-1 overflow-y-auto" ]
                        [ -- Selection instruction
                          div [ class "mb-4" ]
                            [ p [ class "text-sm text-base-content/50" ]
                                [ text "Select cards to enhance" ]
                            ]
                        , -- 8-card selection grid
                          div [ class "flex flex-wrap gap-3 mb-6" ]
                            (pending.availableCards
                                |> List.map
                                    (\card ->
                                        let
                                            isSelected =
                                                List.member card.id deckBuilderSelection
                                        in
                                        viewDeckBuilderCardMinimal card isSelected
                                    )
                            )
                        ]

                Nothing ->
                    text ""

          else if hasPlusBombSelection then
            case shopState.pendingPlusBomb of
                Just pending ->
                    div [ class "flex-1 overflow-y-auto" ]
                        [ -- Selection instruction
                          div [ class "mb-4" ]
                            [ p [ class "text-sm text-base-content/50" ]
                                [ text "Select a card - that rank AND suit won't score for opponent" ]
                            ]
                        , -- 8-card selection grid
                          div [ class "flex flex-wrap gap-3 mb-6" ]
                            (pending.availableCards
                                |> List.map
                                    (\card ->
                                        let
                                            isSelected =
                                                plusBombSelection == Just card.id
                                        in
                                        viewPlusBombCardMinimal card isSelected
                                    )
                            )
                        ]

                Nothing ->
                    text ""

          else
            -- Normal card description
            div [ class "flex-1 overflow-y-auto" ]
                [ div [ class "mb-8" ]
                    [ p [ class "text-base-content/60 text-lg leading-relaxed" ]
                        [ text shopCard.description ]
                    ]
                ]
        , -- Action Button: fixed at bottom
          if canPick then
            div [ class "pt-8 flex-shrink-0" ]
                [ if hasDeckBuilderSelection then
                    -- Deck builder: show Skip and Confirm buttons
                    div [ class "flex gap-3" ]
                        [ button
                            [ onClick SkipDeckBuilderSelection
                            , class "flex-1 py-4 rounded-full font-medium text-base-content/60 bg-base-300/50 hover:bg-base-300 transition-all"
                            ]
                            [ text "Skip" ]
                        , if not (List.isEmpty deckBuilderSelection) then
                            button
                                [ onClick (CompleteDeckBuilderSelection deckBuilderSelection)
                                , class ("flex-1 py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                                ]
                                [ text "Confirm" ]

                          else
                            text ""
                        ]

                  else if hasPlusBombSelection then
                    -- Plus bomb: show confirm button
                    case plusBombSelection of
                        Just cardId ->
                            button
                                [ onClick (CompletePlusBombSelection cardId)
                                , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                                ]
                                [ text "Confirm Selection" ]

                        Nothing ->
                            text ""

                  else if shopCard.cardType == DeckBuilder then
                    -- Deck builder: show "Choose Cards" button
                    button
                        [ onClick (PreviewDeckBuilder cardIndex)
                        , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                        ]
                        [ text "Choose Cards" ]

                  else if shopCard.cardType == Sabotage && shopCard.subtype == "plus_bomb" then
                    -- Plus bomb: show "Choose Card" button
                    button
                        [ onClick (PreviewPlusBomb cardIndex)
                        , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                        ]
                        [ text "Choose Card" ]

                  else
                    -- Regular card: show "Confirm Selection" button
                    button
                        [ onClick (MakeShopPick cardIndex)
                        , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                        ]
                        [ text "Confirm Selection" ]
                ]

          else
            text ""
        ]


{-| Minimal card display for deck builder selection
-}
viewDeckBuilderCardMinimal : Card -> Bool -> Html Msg
viewDeckBuilderCardMinimal card isSelected =
    button
        [ class
            ("w-full sm:w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden "
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


{-| Minimal card display for plus bomb selection
-}
viewPlusBombCardMinimal : Card -> Bool -> Html Msg
viewPlusBombCardMinimal card isSelected =
    button
        [ class
            ("w-full sm:w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden "
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


{-| Empty preview state
-}
viewEmptyPreview : ShopState -> Bool -> Html Msg
viewEmptyPreview shopState canPick =
    let
        isShopComplete =
            shopState.currentRound == shopState.totalRounds && shopState.firstPickMade && shopState.secondPickMade
    in
    div [ class "flex-1 flex items-center justify-center" ]
        [ div [ class "text-center" ]
            [ if isShopComplete then
                -- Shop complete - show countdown
                div []
                    [ div [ class "w-20 h-20 rounded-full bg-emerald-500/10 mx-auto mb-4 flex items-center justify-center" ]
                        [ span [ class "text-4xl font-light text-emerald-500" ]
                            [ text "5" ]
                        ]
                    , p [ class "text-base-content/60 text-lg font-light mb-2" ]
                        [ text "All picks complete!" ]
                    , p [ class "text-base-content/40 text-sm" ]
                        [ text "Next round starting in..." ]
                    ]

              else if canPick then
                div []
                    [ div [ class "w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center" ]
                        [ span [ class "text-4xl" ] [ text "👆" ] ]
                    , p [ class "text-base-content/40 text-lg font-light" ]
                        [ text "Select a card to preview" ]
                    ]

              else
                div []
                    [ div [ class "w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center" ]
                        [ span [ class "text-4xl animate-pulse" ] [ text "⏳" ] ]
                    , p [ class "text-base-content/40 text-lg font-light" ]
                        [ text "Waiting for opponent..." ]
                    ]
            ]
        ]


{-| View ready for next round button
-}
viewReadyForNextRound : PlayerState -> Html Msg
viewReadyForNextRound currentPlayer =
    div [ class "bg-[#15161f] rounded-lg p-6 text-center border border-gray-700" ]
        [ if currentPlayer.readyForNextRound then
            p [ class "text-green-400 text-xl" ]
                [ text "Waiting for opponent..." ]

          else
            button
                [ onClick ReadyForNextRound
                , class "bg-sky-600 hover:bg-sky-700 text-white font-bold py-3 px-6 rounded-lg text-xl transition-colors"
                ]
                [ text "Ready for Next Round" ]
        ]


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
    -- Hide console buttons on mobile when modal is open, always show on desktop
    div
        [ classList
            [ ( "absolute left-px top-1/2 -translate-y-1/2 z-40", True )
            , ( "hidden", anyModalOpen )
            , ( "sm:block", True )
            ]
        ]
        [ div [ class "flex flex-col gap-2 sm:gap-3" ]
            [ -- Deck Button
              button
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
            , -- Levels Button
              button
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
            , -- Log Button
              button
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
    div [ class "h-12 sm:h-20 flex items-center shrink-0 bg-[#0C0F14]" ]
        [ -- Desktop layout
          div [ class "hidden sm:flex items-center gap-4 ml-auto px-8" ]
            [ button
                [ onClick (DiscardCards selectedCardsList)
                , disabled (not canDiscard)
                , classList
                    [ ( "px-4 py-2 rounded-lg transition-colors shadow-lg ring-1 ring-white/10 text-base touch-manipulation", True )
                    , ( "bg-red-600 hover:bg-red-700 text-white", canDiscard )
                    , ( "opacity-50 cursor-not-allowed bg-gray-600 text-gray-400", not canDiscard )
                    ]
                ]
                [ if actionInProgress then
                    text "Discarding..."

                  else
                    text "Discard"
                ]
            , button
                [ onClick LockInHand
                , disabled (not canLockIn)
                , classList
                    [ ( "px-4 py-2 rounded-lg transition-colors shadow-lg ring-1 ring-white/10 text-base font-semibold touch-manipulation", True )
                    , ( "bg-sky-600 hover:bg-sky-700 text-white", canLockIn )
                    , ( "opacity-50 cursor-not-allowed bg-gray-600 text-gray-400", not canLockIn )
                    ]
                ]
                [ if actionInProgress then
                    text "Playing..."

                  else
                    text "Play"
                ]
            ]
        , -- Mobile layout
          div [ class "sm:hidden flex items-center justify-between gap-1.5 w-full px-2" ]
            [ button
                [ onClick (DiscardCards selectedCardsList)
                , disabled (not canDiscard)
                , classList
                    [ ( "w-16 py-1.5 rounded transition-colors shadow ring-1 ring-white/10 text-xs touch-manipulation", True )
                    , ( "bg-red-600 hover:bg-red-700 text-white", canDiscard )
                    , ( "opacity-50 cursor-not-allowed bg-gray-600 text-gray-400", not canDiscard )
                    ]
                ]
                [ text "Discard" ]
            , -- Sort button
              button
                [ onClick ToggleCardSort
                , class "px-3 py-1.5 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 touch-manipulation"
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
                    [ ( "w-16 py-1.5 rounded transition-colors shadow ring-1 ring-white/10 text-xs font-semibold touch-manipulation", True )
                    , ( "bg-sky-600 hover:bg-sky-700 text-white", canLockIn )
                    , ( "opacity-50 cursor-not-allowed bg-gray-600 text-gray-400", not canLockIn )
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
        [ -- Left: Player info (you)
          div [ class "flex items-start gap-2" ]
            [ viewPlayerInfo player playerName initialLives discardsPerRound playerWinning
            ]
        , -- Center: Hand progress with score
          viewTopCenterBar gameState player opponent
        , -- Right: Opponent info
          div [ class "flex items-start gap-2" ]
            [ viewOpponentInfo opponent opponentName initialLives discardsPerRound opponentWinning
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
            if player.handsRemaining > 0 then
                handsPlayed + 1

            else
                totalHands

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
    div [ class "flex flex-col items-center text-xs gap-1.5" ]
        [ -- Progress dots (top row)
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
        , -- Score differential (bottom row)
          if playerWinning && scoreDiff > 0 then
              span [ class "text-xs font-semibold text-player" ]
                  [ text ("+" ++ String.fromInt scoreDiff) ]

          else if opponentWinning && scoreDiff > 0 then
              span [ class "text-xs font-semibold text-opponent" ]
                  [ text ("+" ++ String.fromInt scoreDiff) ]

          else
              text ""
        ]


{-| View opponent info overlay (top-right corner) - Mobile and Desktop
-}
viewOpponentInfo : PlayerState -> String -> Int -> Int -> Bool -> Html Msg
viewOpponentInfo opponent opponentName initialLives discardsPerRound isWinning =
    div [ class "flex flex-col items-end gap-0.5 text-base-content" ]
        [ -- Icons row (trash and hearts - swapped order, horizontal on desktop, vertical on mobile)
          div [ class "flex flex-col-reverse sm:flex-row items-end sm:items-center gap-0.5 sm:gap-1" ]
            [ -- Trash (removed from LEFT/center - leftmost trash disappears first)
              div [ class "flex items-center gap-0.5" ]
                (List.range 1 discardsPerRound
                    |> List.map
                        (\i ->
                            if i > discardsPerRound - opponent.discardsRemaining then
                                Heroicons.Solid.trash [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                            else
                                Heroicons.Outline.trash [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                        )
                )
            , -- Dot separator (desktop only)
              span [ class "hidden sm:inline text-gray-500" ] [ text "·" ]
            , -- Hearts (removed from LEFT/center - leftmost heart disappears first)
              div [ class "flex items-center gap-0.5" ]
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
        , -- Name row with star if winning
          div [ class "flex items-center gap-1" ]
            [ span [ class "text-sm text-opponent truncate max-w-[25ch]" ] [ text opponentName ]
            , if isWinning then
                Heroicons.Solid.star [ SvgAttr.class "w-3 h-3 text-opponent" ]

              else
                text ""
            ]
        ]


{-| View player info overlay (top-left corner) - Mobile and Desktop
-}
viewPlayerInfo : PlayerState -> String -> Int -> Int -> Bool -> Html Msg
viewPlayerInfo player playerName initialLives discardsPerRound isWinning =
    div [ class "flex flex-col items-start gap-0.5 text-base-content" ]
        [ -- Icons row (hearts and trash - horizontal on desktop, vertical on mobile)
          div [ class "flex flex-col sm:flex-row items-start sm:items-center gap-0.5 sm:gap-1" ]
            [ -- Hearts (removed from RIGHT/center - rightmost heart disappears first)
              div [ class "flex items-center gap-0.5" ]
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
            , -- Dot separator (desktop only)
              span [ class "hidden sm:inline text-gray-500" ] [ text "·" ]
            , -- Trash (removed from RIGHT/center - rightmost trash disappears first)
              div [ class "flex items-center gap-0.5" ]
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
        , -- Name row with star if winning
          div [ class "flex items-center gap-1" ]
            [ span [ class "text-sm text-player truncate max-w-[25ch]" ] [ text playerName ]
            , if isWinning then
                Heroicons.Solid.star [ SvgAttr.class "w-3 h-3 text-player" ]

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
            -- Shop modal will be implemented later
            text ""


{-| View game log modal
-}
viewGameLogModal : Html Msg
viewGameLogModal =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ -- Title row - desktop shows icon+title, mobile shows only X (centered, no text)
          div [ class "flex items-center justify-center mb-4 w-full" ]
            [ -- Desktop: Icon + Title
              div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.newspaper [ SvgAttr.class "w-8 h-8 text-amber-600" ]
                , h2 [ class "text-2xl font-bold text-amber-600" ] [ text "History" ]
                ]
            , -- Mobile: Close button with X icon
              button
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
        [ -- Title row - desktop shows icon+title, mobile shows only X (centered, no text)
          div [ class "flex items-center justify-center mb-4 w-full" ]
            [ -- Desktop: Icon + Title
              div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.square3Stack3d [ SvgAttr.class "w-8 h-8 text-blue-600" ]
                , h2 [ class "text-2xl font-bold text-blue-600" ] [ text "Deck" ]
                ]
            , -- Mobile: Close button with X icon
              button
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
            [ viewDeckCards currentPlayer
            ]
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

        -- Group cards by suit, then by rank within suit
        getSuitCards suit =
            List.filter (\card -> card.suit == suit) allCards

        groupCardsByRank cards =
            List.foldl
                (\card acc ->
                    Dict.update card.rank
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
                            [ -- Suit count
                              div [ class "w-3 sm:w-4 text-center pt-1 text-[10px] sm:text-xs text-base-content/50 flex-shrink-0" ]
                                [ text (String.fromInt (List.length suitCards)) ]
                            , -- 13-column grid with multiple rows for duplicates
                              div [ class "flex-1 space-y-0.5 sm:space-y-1 overflow-x-auto" ]
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

                                                                    -- Face-down cards treated like draw pile
                                                                    opacityClass =
                                                                        if isInHand && not isFaceDown then
                                                                            "opacity-100"

                                                                        else
                                                                            "opacity-40"

                                                                    isDisabled =
                                                                        List.member card.rank player.disabledRanks
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
        [ -- Title row - desktop shows icon+title, mobile shows only X (centered, no text)
          div [ class "flex items-center justify-center mb-6 w-full" ]
            [ -- Desktop: Icon + Title
              div [ class "hidden sm:flex items-center gap-3" ]
                [ Heroicons.Solid.chartBar [ SvgAttr.class "w-8 h-8 text-green-600" ]
                , h2 [ class "text-2xl font-bold text-green-600" ] [ text "Levels" ]
                ]
            , -- Mobile: Close button with X icon
              button
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
            [ viewLevelsList currentPlayer
            ]
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
                    in
                    div [ class ("flex items-center justify-between py-1 px-2 rounded hover:bg-base-200 " ++ opacityClass) ]
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
Mirrors the get_sabotage_badges function from gameplay.ex:421
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
                Just { name = "Plus Bomb", tooltip = disabledText ++ " won't score" }

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
        [ span [] [ text badge.name ]
        ]


{-| Render badges for a player (both debuffs and sabotage effects)
Returns a list of badge elements to be rendered
Mobile: stacks vertically (1 per line)
Desktop: wraps horizontally (multiple per line)
-}
viewPlayerBadges : PlayerState -> String -> Html Msg
viewPlayerBadges player colorClass =
    let
        debuffBadges =
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

        sabotageBadges =
            getSabotageBadges player

        allBadges =
            debuffBadges ++ sabotageBadges
    in
    if allBadges /= [] then
        div [ class "flex flex-col sm:flex-row sm:flex-wrap gap-1" ]
            (List.map (viewBadge colorClass) allBadges)

    else
        text ""


{-| View badges positioned at bottom of centerboard
Mobile: All badges together in one row (player badges first, then opponent)
Desktop: Player badges on bottom-left, opponent badges on bottom-right
-}
viewCenterboardBadges : PlayerState -> PlayerState -> Html Msg
viewCenterboardBadges player opponent =
    let
        -- Get individual badge lists
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
            [ -- Mobile: All badges together, player first then opponent
              div [ class "sm:hidden absolute bottom-1 left-2 right-2 flex flex-wrap gap-1 z-10" ]
                (List.map (viewBadge "bg-player text-sky-900") allPlayerBadges
                    ++ List.map (viewBadge "bg-opponent text-orange-900") allOpponentBadges
                )
            , -- Desktop: Split left and right with more spacing
              div [ class "hidden sm:flex absolute bottom-4 left-4 right-4 items-end justify-between z-10 pointer-events-none" ]
                [ -- Bottom-left: Player badges (you)
                  if allPlayerBadges /= [] then
                    div [ class "pointer-events-auto flex flex-wrap gap-1" ]
                        (List.map (viewBadge "bg-player text-sky-900") allPlayerBadges)

                  else
                    text ""
                , -- Bottom-right: Opponent badges
                  if allOpponentBadges /= [] then
                    div [ class "pointer-events-auto flex flex-wrap gap-1" ]
                        (List.map (viewBadge "bg-opponent text-orange-900") allOpponentBadges)

                  else
                    text ""
                ]
            ]

    else
        text ""


