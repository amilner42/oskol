module View.Cards exposing (viewCardImage)

{-| Card rendering components matching LiveView
-}

import Html exposing (Html, div, img, text)
import Html.Attributes exposing (class, classList, src)
import Svg
import Svg.Attributes
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
            div [ class "absolute inset-0 z-10 pointer-events-none" ]
                [ div [ class "absolute inset-0 flex items-center justify-center" ]
                    [ Svg.svg
                        [ Svg.Attributes.class "w-3/4 h-3/4 text-pink-600/15"
                        , Svg.Attributes.viewBox "0 0 100 100"
                        ]
                        [ Svg.line
                            [ Svg.Attributes.x1 "20"
                            , Svg.Attributes.y1 "20"
                            , Svg.Attributes.x2 "80"
                            , Svg.Attributes.y2 "80"
                            , Svg.Attributes.stroke "currentColor"
                            , Svg.Attributes.strokeWidth "12"
                            , Svg.Attributes.strokeLinecap "round"
                            ]
                            []
                        , Svg.line
                            [ Svg.Attributes.x1 "80"
                            , Svg.Attributes.y1 "20"
                            , Svg.Attributes.x2 "20"
                            , Svg.Attributes.y2 "80"
                            , Svg.Attributes.stroke "currentColor"
                            , Svg.Attributes.strokeWidth "12"
                            , Svg.Attributes.strokeLinecap "round"
                            ]
                            []
                        ]
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
                Ace ->
                    "A"

                King ->
                    "K"

                Queen ->
                    "Q"

                Jack ->
                    "J"

                Ten ->
                    "T"

                Nine ->
                    "9"

                Eight ->
                    "8"

                Seven ->
                    "7"

                Six ->
                    "6"

                Five ->
                    "5"

                Four ->
                    "4"

                Three ->
                    "3"

                Two ->
                    "2"

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
