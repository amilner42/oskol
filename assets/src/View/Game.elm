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
            -- Full-screen flexbox layout matching LiveView
            div [ class "flex flex-col h-screen bg-[#1a1d29] overflow-hidden" ]
                [ -- Top - Opponent Cards
                  div [ class "shrink-0 flex flex-col justify-end pt-2 px-0 pb-1 sm:pt-2 sm:px-3 sm:pb-3 bg-[#0C0F14]" ]
                    [ viewOpponentCards opponent model.newCardIds model.cardSort
                    ]
                , -- Middle - Playing Area
                  div [ class "flex-1 min-h-0 flex flex-col justify-center bg-[#161B1F] shadow-[0_0_30px_-5px_rgba(0,0,0,0.5)] relative" ]
                    [ viewPlayingArea model gameState currentPlayer opponent playerId
                    , viewOpponentInfo opponent opponentName gameState.initialLives gameState.discardsPerRound
                    , viewPlayerInfo currentPlayer playerName gameState.initialLives gameState.discardsPerRound
                    ]
                , -- Bottom - Player Cards
                  div [ class "shrink-0 flex flex-col justify-start pt-1 px-0 pb-0 sm:pt-3 sm:px-3 sm:pb-0 bg-[#0C0F14]" ]
                    [ viewPlayerCards currentPlayer model
                    ]
                , -- Action Bar
                  viewActionBar currentPlayer model.selectedCards False
                , -- Console Buttons (fixed at mid-left)
                  viewConsoleButtons model.viewingModal model.playerId
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
                        , disabled = False
                        , enhancementDisabled = False
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
                                , disabled = False
                                , enhancementDisabled = False
                                }
                            ]
                        ]
                )
                sortedCards
            )
        , viewSortButton model.cardSort
        ]


{-| Sort cards based on the current sort option
Matches Elixir's sort_cards function exactly
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
            div [ class "h-full flex flex-col items-center justify-center p-4 text-white" ]
                [ -- Round info
                  div [ class "text-center mb-4" ]
                    [ div [ class "text-4xl font-bold mb-2" ]
                        [ text ("Round " ++ String.fromInt gameState.roundNumber) ]
                    , div [ class "text-lg opacity-70" ]
                        [ text
                            (if currentPlayer.handsRemaining == 0 then
                                "Round complete"

                             else if currentPlayer.handsRemaining == 1 then
                                "Final hand"

                             else
                                String.fromInt currentPlayer.handsRemaining ++ " hands remaining"
                            )
                        ]
                    , viewScoreDifferential currentPlayer opponent playerName opponentName
                    ]
                , -- Phase-specific content
                  case gameState.phase of
                    Playing ->
                        case gameState.lastHandResults of
                            Just results ->
                                viewHandResults model gameState results

                            Nothing ->
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


{-| View hand results (shown briefly after hands are played)
-}
viewHandResults : Model -> GameState -> Dict String HandResult -> Html Msg
viewHandResults model gameState results =
    div [ class "bg-[#15161f] rounded-lg p-6 max-w-4xl" ]
        [ h2 [ class "text-xl font-bold text-white mb-4" ] [ text "Hand Results" ]
        , div [ class "grid grid-cols-2 gap-4" ]
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


{-| View round end state
-}
viewRoundEnd : Model -> GameState -> PlayerState -> Html Msg
viewRoundEnd model gameState currentPlayer =
    case gameState.gameStatus of
        GameOver ->
            viewGameOver gameState

        Active ->
            case gameState.shopState of
                Just shopState ->
                    viewShop model gameState shopState

                Nothing ->
                    viewReadyForNextRound currentPlayer


{-| View game over screen
-}
viewGameOver : GameState -> Html Msg
viewGameOver gameState =
    case gameState.winnerId of
        Just winnerId ->
            div [ class "bg-[#15161f] rounded-lg p-8 text-center border border-gray-700" ]
                [ h2 [ class "text-3xl font-bold text-white mb-4" ]
                    [ text "Game Over!" ]
                , p [ class "text-2xl text-blue-400 mb-6" ]
                    [ text (getPlayerName gameState winnerId ++ " wins!") ]
                ]

        Nothing ->
            div [ class "bg-[#15161f] rounded-lg p-8 text-center border border-gray-700" ]
                [ h2 [ class "text-3xl font-bold text-white" ]
                    [ text "Game Over" ]
                ]


{-| View shop interface (placeholder)
-}
viewShop : Model -> GameState -> ShopState -> Html Msg
viewShop model gameState shopState =
    div [ class "bg-[#15161f] rounded-lg p-6 border border-gray-700" ]
        [ h2 [ class "text-xl font-bold text-white mb-4" ]
            [ text ("Shop - Round " ++ String.fromInt shopState.currentRound) ]
        , p [ class "text-gray-400" ]
            [ text "Shop interface coming soon..." ]
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
    in
    div [ class "fixed left-px top-1/2 -translate-y-1/2 z-40" ]
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
                    Heroicons.Solid.squares2x2 [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-blue-600" ]

                  else
                    Heroicons.Outline.squares2x2 [ SvgAttr.class "w-6 h-6 sm:w-7 sm:h-7 text-blue-600" ]
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
viewActionBar : PlayerState -> Set String -> Bool -> Html Msg
viewActionBar player selectedCards actionInProgress =
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


{-| View opponent info overlay (top-right corner) -}
viewOpponentInfo : PlayerState -> String -> Int -> Int -> Html Msg
viewOpponentInfo opponent opponentName initialLives discardsPerRound =
    div [ class "hidden sm:flex absolute top-4 right-4 flex-col items-end gap-0.5 text-gray-300" ]
        [ div [ class "flex items-center gap-1" ]
            [ span [ class "text-sm text-red-400 truncate max-w-[25ch]" ] [ text opponentName ]
            ]
        , div [ class "flex items-center gap-0.5" ]
            (List.range 1 initialLives
                |> List.map
                    (\i ->
                        if i > initialLives - opponent.lives then
                            Heroicons.Solid.heart [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                        else
                            Heroicons.Outline.heart [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                    )
            )
        , div [ class "flex items-center gap-0.5" ]
            (List.range 1 discardsPerRound
                |> List.map
                    (\i ->
                        if i > discardsPerRound - opponent.discardsRemaining then
                            Heroicons.Solid.trash [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                        else
                            Heroicons.Outline.trash [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                    )
            )
        ]


{-| View player info overlay (bottom-right corner) -}
viewPlayerInfo : PlayerState -> String -> Int -> Int -> Html Msg
viewPlayerInfo player playerName initialLives discardsPerRound =
    div [ class "hidden sm:flex absolute bottom-4 right-4 flex-col items-end gap-0.5 text-gray-300" ]
        [ div [ class "flex items-center gap-0.5" ]
            (List.range 1 discardsPerRound
                |> List.map
                    (\i ->
                        if i > discardsPerRound - player.discardsRemaining then
                            Heroicons.Solid.trash [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                        else
                            Heroicons.Outline.trash [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                    )
            )
        , div [ class "flex items-center gap-0.5" ]
            (List.range 1 initialLives
                |> List.map
                    (\i ->
                        if i > initialLives - player.lives then
                            Heroicons.Solid.heart [ SvgAttr.class "w-4 h-4 text-gray-400" ]

                        else
                            Heroicons.Outline.heart [ SvgAttr.class "w-4 h-4 text-gray-600" ]
                    )
            )
        , div [ class "flex items-center gap-1" ]
            [ span [ class "text-sm text-blue-400 truncate max-w-[25ch]" ] [ text playerName ]
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


{-| View game log modal -}
viewGameLogModal : Html Msg
viewGameLogModal =
    div [ class "h-full flex flex-col items-center justify-start p-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-4" ]
            [ Heroicons.Solid.newspaper [ SvgAttr.class "w-8 h-8 text-amber-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Game History" ]
            ]
        , div [ class "text-gray-300 text-center" ]
            [ text "Game event log coming soon..." ]
        ]


{-| View deck modal -}
viewDeckModal : String -> PlayerState -> PlayerState -> String -> String -> String -> Html Msg
viewDeckModal deckPlayerId currentPlayer opponent playerId playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start p-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-4" ]
            [ Heroicons.Solid.squares2x2 [ SvgAttr.class "w-8 h-8 text-blue-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Deck" ]
            ]
        , viewDeckCards currentPlayer
        ]


{-| View deck cards -}
viewDeckCards : PlayerState -> Html Msg
viewDeckCards player =
    let
        allCards =
            player.cardPiles.drawPile ++ player.cardPiles.handPile

        totalCards =
            List.length (getPlayerDeck player)

        cardsRemaining =
            List.length allCards

        -- Group cards by (suit order, rank) - using suitOrder to make it comparable
        cardsByPosition =
            allCards
                |> List.foldl
                    (\card acc ->
                        let
                            key =
                                ( suitOrder card.suit, card.rank )

                            existing =
                                Dict.get key acc |> Maybe.withDefault []
                        in
                        Dict.insert key (existing ++ [ card ]) acc
                    )
                    Dict.empty

        inHandIds =
            Set.fromList (List.map .id player.cardPiles.handPile)

        suits =
            [ Spades, Hearts, Clubs, Diamonds ]

        ranks =
            [ 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2 ]

        suitSymbol suit =
            case suit of
                Spades ->
                    "♠"

                Hearts ->
                    "♥"

                Clubs ->
                    "♣"

                Diamonds ->
                    "♦"

        suitColor suit =
            case suit of
                Hearts ->
                    "text-red-500"

                Diamonds ->
                    "text-red-500"

                _ ->
                    "text-white"

        countSuitRemaining suit =
            List.length (List.filter (\c -> c.suit == suit) allCards)
    in
    div []
        [ div [ class "mb-3 text-sm text-gray-400" ]
            [ text (String.fromInt cardsRemaining ++ " cards left") ]
        , div [ class "overflow-x-auto" ]
            [ table [ class "border-collapse" ]
                [ tbody []
                    (List.map
                        (\suit ->
                            let
                                suitCount =
                                    countSuitRemaining suit
                            in
                            tr []
                                (td [ class "px-2 py-1 text-left text-base font-semibold" ]
                                    [ span [ class "text-xs text-gray-400 mr-1" ]
                                        [ text (String.fromInt suitCount) ]
                                    , span [ class (suitColor suit) ]
                                        [ text (suitSymbol suit) ]
                                    ]
                                    :: List.map
                                        (\rank ->
                                            let
                                                cardsAtPosition =
                                                    Dict.get ( suitOrder suit, rank ) cardsByPosition
                                                        |> Maybe.withDefault []

                                                stackHeight =
                                                    if List.length cardsAtPosition > 0 then
                                                        96 + (List.length cardsAtPosition - 1) * 20

                                                    else
                                                        96
                                            in
                                            td [ class "p-1" ]
                                                [ if List.length cardsAtPosition > 0 then
                                                    div
                                                        [ class "relative"
                                                        , style "height" (String.fromInt stackHeight ++ "px")
                                                        , style "width" "64px"
                                                        ]
                                                        (List.indexedMap
                                                            (\index card ->
                                                                let
                                                                    isInHand =
                                                                        Set.member card.id inHandIds

                                                                    opacityClass =
                                                                        if isInHand then
                                                                            "opacity-100"

                                                                        else
                                                                            "opacity-30"

                                                                    topOffset =
                                                                        index * 20
                                                                in
                                                                div
                                                                    [ class ("absolute " ++ opacityClass)
                                                                    , style "top" (String.fromInt topOffset ++ "px")
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
                                                            )
                                                            cardsAtPosition
                                                        )

                                                  else
                                                    div
                                                        [ class "w-16 h-24" ]
                                                        []
                                                ]
                                        )
                                        ranks
                                )
                        )
                        suits
                    )
                ]
            ]
        ]


{-| View levels modal -}
viewLevelsModal : PlayerState -> PlayerState -> String -> String -> Html Msg
viewLevelsModal currentPlayer opponent playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start p-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-6" ]
            [ Heroicons.Solid.chartBar [ SvgAttr.class "w-8 h-8 text-green-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Levels" ]
            ]
        , viewLevelsList currentPlayer
        ]


{-| View levels list for current player -}
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
    in
    div [ class "max-w-3xl mx-auto" ]
        [ table [ class "w-full" ]
            [ tbody []
                (List.map
                    (\handType ->
                        let
                            level =
                                getLevel handType player.skillTree

                            stats =
                                statsAtLevel handType level
                        in
                        tr [ class "border-b border-gray-700" ]
                            [ td [ class "py-3 px-4 font-semibold text-white" ]
                                [ span [ class "text-gray-400 font-normal" ]
                                    [ text ("Lv" ++ String.fromInt level) ]
                                , span [ class "ml-2" ]
                                    [ text (handTypeToString handType) ]
                                ]
                            , td [ class "py-3 px-4 text-sm text-right text-gray-300" ]
                                [ text (String.fromInt stats.chips ++ " x " ++ String.fromInt stats.multiplier) ]
                            ]
                    )
                    handTypes
                )
            ]
        ]
