module View.PlayerInfo exposing (viewPlayerInfo, viewPlayerStats)

{-| Player information display components
-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class)
import Types exposing (..)


{-| View player stats bar (lives, score, etc.)
-}
viewPlayerStats :
    { player : PlayerState
    , playerName : String
    , isCurrentPlayer : Bool
    }
    -> Html Msg
viewPlayerStats config =
    let
        bgColor =
            if config.isCurrentPlayer then
                "bg-blue-900"

            else
                "bg-gray-800"

        borderColor =
            if config.isCurrentPlayer then
                "border-blue-500"

            else
                "border-gray-600"
    in
    div [ class ("rounded-lg p-4 mb-4 border-2 " ++ bgColor ++ " " ++ borderColor) ]
        [ div [ class "flex items-center justify-between" ]
            [ div [ class "flex items-center gap-4" ]
                [ div [ class "text-xl font-bold text-white" ]
                    [ text config.playerName ]
                , viewLives config.player.lives
                ]
            , div [ class "flex items-center gap-6" ]
                [ viewStat "Score" (String.fromInt config.player.currentRoundScore)
                , viewStat "Hands" (String.fromInt config.player.handsRemaining)
                , viewStat "Discards" (String.fromInt config.player.discardsRemaining)
                ]
            ]
        ]


{-| View lives as heart symbols
-}
viewLives : Int -> Html Msg
viewLives lives =
    div [ class "flex gap-1" ]
        (List.repeat lives
            (span [ class "text-red-500 text-2xl" ] [ text "♥" ])
        )


{-| View a single stat
-}
viewStat : String -> String -> Html Msg
viewStat label value =
    div [ class "text-center" ]
        [ div [ class "text-gray-400 text-sm" ] [ text label ]
        , div [ class "text-white text-lg font-bold" ] [ text value ]
        ]


{-| View comprehensive player info (for modals, etc.)
-}
viewPlayerInfo :
    { player : PlayerState
    , playerName : String
    , gameState : GameState
    }
    -> Html Msg
viewPlayerInfo config =
    div [ class "space-y-4" ]
        [ div [ class "text-2xl font-bold text-white mb-4" ]
            [ text config.playerName ]
        , div [ class "grid grid-cols-2 gap-4" ]
            [ viewInfoCard "Lives" (String.fromInt config.player.lives)
            , viewInfoCard "Current Score" (String.fromInt config.player.currentRoundScore)
            , viewInfoCard "Hands Remaining" (String.fromInt config.player.handsRemaining)
            , viewInfoCard "Discards Remaining" (String.fromInt config.player.discardsRemaining)
            , viewInfoCard "Cards in Hand" (String.fromInt (List.length config.player.cardPiles.handPile))
            , viewInfoCard "Cards in Draw Pile" (String.fromInt (List.length config.player.cardPiles.drawPile))
            , viewInfoCard "Cards in Discard" (String.fromInt (List.length config.player.cardPiles.discardPile))
            ]
        , if not (List.isEmpty config.player.activeDebuffs) then
            div [ class "mt-4" ]
                [ div [ class "text-red-500 font-bold mb-2" ] [ text "Active Debuffs:" ]
                , div [ class "flex flex-wrap gap-2" ]
                    (List.map viewDebuffBadge config.player.activeDebuffs)
                ]

          else
            text ""
        , if config.player.scrambled then
            div [ class "mt-2 p-2 bg-yellow-900 border border-yellow-600 rounded text-yellow-200" ]
                [ text "⚠️ Scrambled: Some new cards will be face-down" ]

          else
            text ""
        ]


{-| View an info card
-}
viewInfoCard : String -> String -> Html Msg
viewInfoCard label value =
    div [ class "bg-gray-800 rounded p-3" ]
        [ div [ class "text-gray-400 text-sm mb-1" ] [ text label ]
        , div [ class "text-white text-xl font-bold" ] [ text value ]
        ]


{-| View a debuff badge
-}
viewDebuffBadge : HandType -> Html Msg
viewDebuffBadge handType =
    span [ class "bg-red-900 text-red-200 px-2 py-1 rounded text-sm" ]
        [ text (handTypeToString handType ++ " Denied") ]
