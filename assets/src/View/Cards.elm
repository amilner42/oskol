module View.Cards exposing (viewCardImage)

{-| Card rendering components matching LiveView
-}

import Html exposing (Html, div, img, text)
import Html.Attributes exposing (class, classList, src)
import Types exposing (..)


{-| View a card as an image (matches LiveView's card\_display)
-}
viewCardImage :
    { card : Card
    , isFaceDown : Bool
    , showEnhancement : Bool
    , compact : Bool
    , disabled : Bool
    , enhancementDisabled : Bool
    }
    -> Html Msg
viewCardImage config =
    let
        cardUrl =
            if config.isFaceDown then
                "/images/cards/1B.svg"

            else
                cardToSvgUrl config.card

        enhancementText =
            if config.showEnhancement && not config.isFaceDown then
                case config.card.enhancement of
                    Just (BonusChips amount) ->
                        Just ("+" ++ String.fromInt amount ++ "c")

                    Just (BonusMult amount) ->
                        Just ("+" ++ String.fromInt amount ++ "x")

                    Nothing ->
                        Nothing

            else
                Nothing
    in
    div [ class "rounded overflow-hidden relative w-full h-full" ]
        [ img [ src cardUrl, class "w-full h-full" ] []
        , case enhancementText of
            Just text_ ->
                div
                    [ classList
                        [ ( "absolute font-bold rounded shadow-lg", True )
                        , ( "bg-gray-500 text-gray-300 line-through", config.enhancementDisabled )
                        , ( "bg-purple-600 text-white", not config.enhancementDisabled )
                        , ( "top-px right-px text-[8px] px-0.5 py-0", config.compact )
                        , ( "top-0.5 right-0.5 text-xs px-1.5 py-0.5", not config.compact )
                        ]
                    ]
                    [ Html.text text_ ]

            Nothing ->
                text ""
        , if config.disabled && not config.isFaceDown then
            div [ class "absolute inset-0 flex items-center justify-center pointer-events-none" ]
                [ Html.node "svg"
                    [ class "w-3/4 h-3/4 text-pink-600/15"
                    , Html.Attributes.attribute "viewBox" "0 0 100 100"
                    ]
                    [ Html.node "line"
                        [ Html.Attributes.attribute "x1" "20"
                        , Html.Attributes.attribute "y1" "20"
                        , Html.Attributes.attribute "x2" "80"
                        , Html.Attributes.attribute "y2" "80"
                        , Html.Attributes.attribute "stroke" "currentColor"
                        , Html.Attributes.attribute "stroke-width" "12"
                        , Html.Attributes.attribute "stroke-linecap" "round"
                        ]
                        []
                    , Html.node "line"
                        [ Html.Attributes.attribute "x1" "80"
                        , Html.Attributes.attribute "y1" "20"
                        , Html.Attributes.attribute "x2" "20"
                        , Html.Attributes.attribute "y2" "80"
                        , Html.Attributes.attribute "stroke" "currentColor"
                        , Html.Attributes.attribute "stroke-width" "12"
                        , Html.Attributes.attribute "stroke-linecap" "round"
                        ]
                        []
                    ]
                ]

          else
            text ""
        ]


{-| Convert a card to its SVG URL
-}
cardToSvgUrl : Card -> String
cardToSvgUrl card =
    let
        rankStr =
            case card.rank of
                14 ->
                    "A"

                13 ->
                    "K"

                12 ->
                    "Q"

                11 ->
                    "J"

                10 ->
                    "T"

                n ->
                    String.fromInt n

        suitStr =
            case card.suit of
                Hearts ->
                    "H"

                Diamonds ->
                    "D"

                Clubs ->
                    "C"

                Spades ->
                    "S"
    in
    "/images/cards/" ++ rankStr ++ suitStr ++ ".svg"
