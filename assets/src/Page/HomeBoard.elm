module Page.HomeBoard exposing (pips, view)

{-| The home page is a backgammon table: the real board in its opening
position, drawn with the table's own classes, with the Oskol mark inlaid in
the left half's felt and the ways into the site in the right half's band,
where a roll button and the dice sit in a game. It is a picture with
buttons on it: nothing here is a game, and nothing is sent anywhere.
-}

import Games.Backgammon.View
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (attribute, class, id, style)
import Ui.Shell


{-| `actions` go in the right half's band beside the dice, then `join` and
then `more` (the second row: practising, and what is on its way); `note`
is the right end of the player's own bar at the foot, where a game shows
the pip count (the games waiting for them, when there are any).
-}
view : { actions : List (Html msg), join : Html msg, more : List (Html msg), you : Html msg, theme : String, picker : Html msg, note : Html msg } -> Html msg
view config =
    div [ class ("bg-page home-board " ++ Games.Backgammon.View.themeClass config.theme) ]
        [ div [ class "bg-main" ]
            [ div [ class "bg-stack" ]
                [ topBar config.picker
                , board
                    [ div [ id "home-menu", class "home-menu grid grid-cols-2 gap-2.5 sm:gap-3" ] (config.actions ++ [ config.join ] ++ config.more) ]
                , bar "white" config.you True config.note
                ]
            ]
        ]


{-| The opponent's bar is the site's: the mark.
-}
topBar : Html msg -> Html msg
topBar picker =
    div [ class "player-bar home-top flex items-center gap-2 px-3 py-2 sm:px-4" ]
        [ div [ class "home-mark" ] [ Ui.Shell.mark ]
        , div [ class "flex-1" ] []
        , picker
        ]


bar : String -> Html msg -> Bool -> Html msg -> Html msg
bar color name isMe note =
    div
        [ class
            ("player-bar flex items-center gap-1.5 sm:gap-2 px-2 py-1.5 sm:px-3 sm:py-2"
                ++ (if isMe then
                        " is-me active"

                    else
                        ""
                   )
            )
        ]
        [ div [ class ("swatch shrink-0 " ++ color) ] []
        , name
        , div [ class "flex-1" ] []
        , note
        ]


{-| What the bar says when there is nothing waiting: the pip count a game
would show.
-}
pips : Html msg
pips =
    span [ class "bar-pips pixel text-[7px] sm:text-[8px] whitespace-nowrap" ] [ text "167 PIPS" ]


board : List (Html msg) -> Html msg
board actions =
    div [ class "bg-board relative select-none" ]
        [ div [ class "bg-grid grid grid-cols-[minmax(0,6fr)_auto_minmax(0,6fr)]" ]
            [ div [ class "home-left contents" ] [ half [ 13, 14, 15, 16, 17, 18 ] [ inlay ] [ 12, 11, 10, 9, 8, 7 ] ]
            , div [ class "home-left contents" ] [ barColumn ]
            , half [ 19, 20, 21, 22, 23, 24 ]
                (div [ class "home-inlay-phone w-full flex justify-center" ] [ inlay ] :: actions)
                [ 6, 5, 4, 3, 2, 1 ]
            ]
        ]


{-| The maker's mark, set into the felt: the bird and the wordmark,
pressed rather than printed.
-}
inlay : Html msg
inlay =
    div [ class "home-inlay flex items-center", attribute "aria-label" "Oskol" ]
        [ Ui.Shell.bird ]


half : List Int -> List (Html msg) -> List Int -> Html msg
half top band bottom =
    div [ class "bg-half min-w-0 flex flex-col" ]
        [ div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (point True) top)
        , div [ class "bg-band min-w-0 flex flex-wrap items-center justify-center gap-2 sm:gap-3 py-1" ] band
        , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (point False) bottom)
        ]


point : Bool -> Int -> Int -> Html msg
point isTop index p =
    let
        ( color, n ) =
            opening p

        colour =
            if modBy 2 (index + (if isTop then 0 else 1)) == 0 then
                "var(--bg-point-a)"

            else
                "var(--bg-point-b)"
    in
    div
        [ class
            ("bg-point flex flex-col items-center gap-px px-px "
                ++ (if isTop then
                        "top"

                    else
                        "bottom flex-col-reverse"
                   )
            )
        , attribute "style" ("--point: " ++ colour)
        ]
        (List.repeat n (div [ class ("checker relative shrink-0 " ++ color) ] []))


{-| The opening position as the viewer (White, moving 24 to 1) sees it.
-}
opening : Int -> ( String, Int )
opening p =
    case p of
        24 ->
            ( "white", 2 )

        13 ->
            ( "white", 5 )

        8 ->
            ( "white", 3 )

        6 ->
            ( "white", 5 )

        1 ->
            ( "black", 2 )

        12 ->
            ( "black", 5 )

        17 ->
            ( "black", 3 )

        19 ->
            ( "black", 5 )

        _ ->
            ( "white", 0 )


barColumn : Html msg
barColumn =
    div [ class "bg-bar grid justify-items-center" ]
        [ div [ class "bg-bar-row" ] []
        , div [ class "bg-bar-row centre flex items-center justify-center w-full" ]
            [ div [ class "cube pixel text-[10px]" ] [ text "64" ] ]
        , div [ class "bg-bar-row" ] []
        ]
