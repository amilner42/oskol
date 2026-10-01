module Ui.Loading exposing (minMs, view)

{-| What `/` is while it cannot yet say which of its two pages it is: the
paper, the homes' bar with only the bird in it (both homes' bar starts
the same way, so nothing moves when either arrives), and one thin bar
filling across the middle.

The server paints the same thing before the app has booted
(`spa_html/spa.html.heex`), so the first paint is this and not a flash of
the guest home. The fill is one CSS animation from the moment the page
started loading; Elm draws its own bar with that animation already
`elapsedMs` in (a negative delay), so taking the page over from the
server's markup does not send the bar back to the start.

-}

import Html exposing (Html)
import Html.Attributes exposing (attribute, class, id, style)
import Ui.Shell as Shell


{-| The least time the bar is up, counted from when the page began to
load: long enough to read as a loading screen rather than a flicker (half
a second still read as one).
-}
minMs : Float
minMs =
    1000


view : Float -> Html msg
view elapsedMs =
    Html.div [ id "boot-page" ]
        [ Html.div [ class "lh lh-top" ] [ Html.header [ class "lh-bar" ] [ Shell.barMark ] ]
        , Html.div [ id "boot", class "boot", attribute "role" "progressbar", attribute "aria-label" "Loading" ]
            [ Html.div [ class "boot-track" ]
                [ Html.div
                    [ class "boot-fill"
                    , style "animation-delay" ("-" ++ String.fromInt (round elapsedMs) ++ "ms")
                    ]
                    []
                ]
            ]
        ]
