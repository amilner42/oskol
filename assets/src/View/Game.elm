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
            -- Check if we should show shop instead of normal game view
            case ( gameState.phase, gameState.shopState ) of
                ( RoundEnd, Just shopState ) ->
                    -- Full-page shop view
                    viewShop model gameState shopState

                _ ->
                    -- Normal game layout
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
    div [ class "h-screen bg-gradient-to-br from-base-200 via-base-100 to-base-200" ]
        [ div [ class "min-h-full flex flex-col lg:flex-row lg:h-screen" ]
            [ -- Left column: Header + Cards Grid
              div [ class "lg:w-[440px] xl:w-[540px] lg:flex-shrink-0 lg:border-r border-base-300/50 bg-base-100/50 lg:flex lg:flex-col lg:h-screen" ]
                [ -- Header
                  div [ class "p-6 border-b border-base-300/50 flex-shrink-0" ]
                    [ div [ class "flex items-center justify-between mb-4" ]
                        [ div [ class "text-2xl font-light text-base-content" ]
                            [ text "Command Center" ]
                        , viewTurnIndicatorByState uiState
                        ]
                    , -- Game status bar (round and lives)
                      case ( maybePlayerState, maybeOpponentState ) of
                        ( Just playerState, Just opponentState ) ->
                            div [ class "flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-6" ]
                                [ -- Round indicator
                                  div [ class "flex items-center gap-2" ]
                                    [ div [ class "text-xs uppercase tracking-wider text-base-content/40" ]
                                        [ text "Round" ]
                                    , div [ class "text-lg font-semibold text-base-content" ]
                                        [ text (String.fromInt gameState.roundNumber) ]
                                    ]
                                , -- Lives status
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
                                ]

                        _ ->
                            text ""
                    ]
                , -- Cards Grid (scrollable)
                  div [ class "flex-1 p-6 overflow-y-auto" ]
                    [ viewShopCardsGrid availableCards canPick pickedIndicesSet destroyedIndicesSet previewingCardIndex
                    ]
                ]
            , -- Right column: Pick Timeline + Preview Panel
              div [ class "lg:flex-1 lg:flex lg:flex-col lg:h-screen lg:overflow-hidden" ]
                [ -- Pick status bar (timeline)
                  div [ class "flex-shrink-0" ]
                    [ viewPickTimeline shopState playerId playerName opponentName ]
                , -- Preview panel
                  div [ class "flex-1 flex flex-col overflow-hidden" ]
                    [ viewPreviewPanelByState uiState ]
                ]
            ]
        ]


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
viewShopCardsGrid : List ShopCard -> Bool -> Set Int -> Set Int -> Maybe Int -> Html Msg
viewShopCardsGrid availableCards canPick pickedIndices destroyedIndices previewingCardIndex =
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
                            viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex
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
                            viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex
                        )
                )
            ]
        ]


{-| Minimal shop card - just badge and name (no description)
-}
viewShopCardMinimal : ShopCard -> Int -> Bool -> Set Int -> Set Int -> Maybe Int -> Html Msg
viewShopCardMinimal shopCard index canPick pickedIndices destroyedIndices previewingCardIndex =
    let
        isPicked =
            Set.member index pickedIndices

        isDestroyed =
            Set.member index destroyedIndices

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
        [ class ("w-full aspect-[2/3] rounded-xl p-4 flex flex-col transition-all relative overflow-hidden flex-shrink-0 bg-base-100 border-2 " ++ borderClass ++ " " ++ opacityClass ++ " " ++ cursorClass)
        , onClick
            (if isDisabled then
                NoOp

             else
                PreviewShopCard index
            )
        , Html.Attributes.disabled isDisabled
        ]
        [ -- Type badge at top
          div [ class ("text-[10px] font-bold uppercase tracking-wider mb-2 " ++ labelColor) ]
            [ text typeLabel ]
        , -- Card name centered
          div [ class "flex-1 flex items-center justify-center" ]
            [ div [ class "font-semibold text-sm text-center leading-tight text-base-content" ]
                [ text shopCard.name ]
            ]
        , -- Picked/Destroyed overlay
          if isPicked then
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


{-| Pick timeline showing all picks made
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

        totalPicks =
            shopState.totalRounds * 2

        currentPickNumber =
            List.length shopState.pickedCardIndices + 1

        reversedIndices =
            List.reverse shopState.pickedCardIndices

        pickSlots =
            List.range 1 totalPicks
                |> List.map
                    (\pickNum ->
                        let
                            pickerName =
                                if modBy 2 pickNum == 1 then
                                    firstPickerName

                                else
                                    secondPickerName

                            maybeCardIndex =
                                reversedIndices
                                    |> List.drop (pickNum - 1)
                                    |> List.head

                            maybeCard =
                                maybeCardIndex
                                    |> Maybe.andThen (\idx -> shopState.availableCards |> List.drop idx |> List.head)

                            isCurrent =
                                pickNum == currentPickNumber && currentPickNumber <= totalPicks
                        in
                        { pickNum = pickNum
                        , pickerName = pickerName
                        , maybeCard = maybeCard
                        , isCurrent = isCurrent
                        }
                    )
    in
    div [ class "p-6 border-b border-base-300/50" ]
        [ div [ class "flex flex-wrap gap-3" ]
            (pickSlots
                |> List.map
                    (\slot ->
                        viewTimelineSlot slot.pickNum slot.pickerName slot.maybeCard slot.isCurrent
                    )
            )
        ]


{-| Single timeline slot
-}
viewTimelineSlot : Int -> String -> Maybe ShopCard -> Bool -> Html Msg
viewTimelineSlot pickNum pickerName maybeCard isCurrent =
    let
        label =
            case pickNum of
                1 ->
                    "1st"

                2 ->
                    "2nd"

                3 ->
                    "3rd"

                n ->
                    String.fromInt n ++ "th"

        containerClass =
            if maybeCard /= Nothing then
                "bg-base-100 border-base-300/50"

            else if isCurrent then
                "bg-base-200/50 border-dashed animate-pulse border-emerald-400"

            else
                "bg-base-200/30 border-base-300/30"
    in
    div [ class ("flex-1 min-w-[180px] flex-shrink-0 rounded-lg p-3 border transition-all " ++ containerClass) ]
        [ div [ class "text-[10px] uppercase tracking-wider text-base-content/40 mb-1" ]
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
                div [ class "flex items-center gap-2" ]
                    [ div [ class ("w-2 h-2 rounded-full flex-shrink-0 " ++ dotColor) ] []
                    , div [ class "min-w-0" ]
                        [ div [ class "text-sm font-medium text-base-content truncate" ]
                            [ text card.name ]
                        , div [ class "text-[10px] text-base-content/40" ]
                            [ text pickerName ]
                        ]
                    ]

            Nothing ->
                div [ class "text-sm text-base-content/30" ]
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
    div [ class "flex-1 flex flex-col p-8 overflow-hidden" ]
        [ -- Header
          div [ class "mb-8 flex-shrink-0" ]
            [ div [ class ("text-xs uppercase tracking-widest mb-1 " ++ labelColorClass) ]
                [ text typeLabel ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text data.card.name ]
            ]
        , -- Description
          div [ class "flex-1 overflow-y-auto" ]
            [ div [ class "mb-8" ]
                [ p [ class "text-base-content/60 text-lg leading-relaxed" ]
                    [ text data.card.description ]
                ]
            ]
        , -- Action Button
          div [ class "pt-8 flex-shrink-0" ]
            [ if data.card.cardType == DeckBuilder then
                button
                    [ onClick (ConfirmDeckBuilder data.cardIndex)
                    , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Choose Cards" ]

              else if data.card.cardType == Sabotage && data.card.subtype == "plus_bomb" then
                button
                    [ onClick (ConfirmPlusBomb data.cardIndex)
                    , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Choose Card" ]

              else
                button
                    [ onClick (MakeShopPick data.cardIndex)
                    , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                    ]
                    [ text "Confirm Selection" ]
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
    div [ class "flex-1 flex flex-col p-8 overflow-hidden" ]
        [ -- Header
          div [ class "mb-8 flex-shrink-0" ]
            [ div [ class "text-xs uppercase tracking-widest mb-1 text-violet-500/60" ]
                [ text "Logistics" ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text data.deckBuilderCard.name ]
            ]
        , -- Card selection
          div [ class "flex-1 overflow-y-auto" ]
            [ div [ class "mb-4" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text ("Select up to " ++ String.fromInt data.maxSelection ++ " cards to enhance") ]
                ]
            , div [ class "flex flex-wrap gap-3 mb-6" ]
                (data.availableCards
                    |> List.map
                        (\card ->
                            let
                                isSelected =
                                    Set.member card.id data.selectedCardIds
                            in
                            viewDeckBuilderCardMinimal card isSelected
                        )
                )
            ]
        , -- Action Buttons
          div [ class "pt-8 flex-shrink-0" ]
            [ div [ class "flex gap-3" ]
                [ button
                    [ onClick CancelSelection
                    , class "flex-1 py-4 rounded-full font-medium text-base-content/60 bg-base-300/50 hover:bg-base-300 transition-all"
                    ]
                    [ text "Skip" ]
                , if not (Set.isEmpty data.selectedCardIds) then
                    button
                        [ onClick ConfirmSelection
                        , class ("flex-1 py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                        ]
                        [ text "Confirm" ]

                  else
                    text ""
                ]
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
    div [ class "flex-1 flex flex-col p-8 overflow-hidden" ]
        [ -- Header
          div [ class "mb-8 flex-shrink-0" ]
            [ div [ class "text-xs uppercase tracking-widest mb-1 text-amber-500/60" ]
                [ text "Sabotage" ]
            , h2 [ class "text-4xl font-light text-base-content" ]
                [ text "Plus Bomb" ]
            ]
        , -- Card selection
          div [ class "flex-1 overflow-y-auto" ]
            [ div [ class "mb-4" ]
                [ p [ class "text-sm text-base-content/50" ]
                    [ text "Select a card - that rank AND suit won't score for opponent" ]
                ]
            , div [ class "flex flex-wrap gap-3 mb-6" ]
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
        , -- Action Button
          div [ class "pt-8 flex-shrink-0" ]
            [ case data.selectedCardId of
                Just _ ->
                    button
                        [ onClick ConfirmSelection
                        , class ("w-full py-4 rounded-full font-medium text-lg transition-all text-white shadow-lg hover:shadow-xl " ++ buttonBgClass)
                        ]
                        [ text "Confirm Selection" ]

                Nothing ->
                    text ""
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
            ("w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden "
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
            ("w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden "
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
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-4" ]
            [ Heroicons.Solid.newspaper [ SvgAttr.class "w-8 h-8 text-amber-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Game History" ]
            ]
        , div [ class "w-full max-w-4xl" ]
            [ div [ class "text-gray-300 text-center" ]
                [ text "Game event log coming soon..." ]
            ]
        ]


{-| View deck modal -}
viewDeckModal : String -> PlayerState -> PlayerState -> String -> String -> String -> Html Msg
viewDeckModal deckPlayerId currentPlayer opponent playerId playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-4" ]
            [ Heroicons.Solid.square3Stack3d [ SvgAttr.class "w-8 h-8 text-blue-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Deck" ]
            ]
        , div [ class "w-full max-w-4xl" ]
            [ viewDeckCards currentPlayer
            ]
        ]


{-| View deck cards -}
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


{-| View levels modal -}
viewLevelsModal : PlayerState -> PlayerState -> String -> String -> Html Msg
viewLevelsModal currentPlayer opponent playerName opponentName =
    div [ class "h-full flex flex-col items-center justify-start px-4 py-4 pt-12 text-white overflow-y-auto" ]
        [ div [ class "flex items-center gap-3 mb-6" ]
            [ Heroicons.Solid.chartBar [ SvgAttr.class "w-8 h-8 text-green-600" ]
            , h2 [ class "text-2xl font-bold" ] [ text "Levels" ]
            ]
        , div [ class "w-full max-w-2xl" ]
            [ viewLevelsList currentPlayer
            ]
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
