module Ui.Scrub exposing (Arrows, plate, row)

{-| The row of plates under a board: the four arrows that step through a
game on the outsides, and between them whatever the page puts there (the
table's match list and resign flag; the replay's match list and flip).
One drawing, so the arrows are the same size and weight on every page.

An arrow with nothing to do is greyed; `plate` draws a middle button the
same way, and `stale` blinks the way back to a game that moved on.

-}

import Html exposing (Html, button, div, span)
import Html.Attributes exposing (attribute, class, classList, disabled, id, title)
import Html.Events exposing (onClick)


{-| The four arrows: each `Nothing` when there is nowhere to go, and the
ids the page (and its smokes) know them by.
-}
type alias Arrows msg =
    { first : ( String, Maybe msg )
    , back : ( String, Maybe msg )
    , forward : ( String, Maybe msg )
    , last : ( String, Maybe msg )
    }


row : { id : String, stale : Bool } -> Arrows msg -> List (Html msg) -> Html msg
row config arrows middle =
    div [ classList [ ( "bg-scrub inline-flex items-center gap-3 sm:gap-4", True ), ( "stale", config.stale ) ], id config.id ]
        ([ arrow arrows.first "First" "hero-chevron-double-left"
         , arrow arrows.back "Back" "hero-chevron-left"
         ]
            ++ middle
            ++ [ arrow arrows.forward "Forward" "hero-chevron-right"
               , arrow arrows.last "Last" "hero-chevron-double-right"
               ]
        )


arrow : ( String, Maybe msg ) -> String -> String -> Html msg
arrow ( id_, msg ) label iconName =
    plate { id = id_, label = label, icon = iconName, onPress = msg }


{-| One plate of the row: an icon on a white square, greyed when it can do
nothing. `icon` is a Heroicon class (`hero-…`).
-}
plate : { id : String, label : String, icon : String, onPress : Maybe msg } -> Html msg
plate config =
    button
        ([ class "bg-scrub-btn"
         , id config.id
         , title config.label
         , attribute "aria-label" config.label
         , disabled (config.onPress == Nothing)
         ]
            ++ (case config.onPress of
                    Just m ->
                        [ onClick m ]

                    Nothing ->
                        []
               )
        )
        [ span [ class (config.icon ++ " w-4 h-4"), attribute "aria-hidden" "true" ] [] ]
