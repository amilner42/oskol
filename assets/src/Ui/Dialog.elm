module Ui.Dialog exposing (view)

{-| The one dialog the homes open -- JOIN GAME, SIGN IN, CREATE GAME, LIVE
GAMES: a rounded sheet over a dimmed page, the heading in the pixel eyebrow
with a plain ✕ across from it, and whatever the dialog says under that,
left-aligned. One frame, so no two of them can drift apart. A tap on the
dimmed page closes it, and the layer scrolls when the card is taller than
the screen, as on a phone held sideways.
-}

import Html exposing (Html)
import Html.Attributes exposing (attribute, class, id, style, type_)
import Html.Events exposing (onClick)


view :
    { id : String
    , closeId : String
    , label : String
    , heading : String
    , onClose : msg
    , width : String
    }
    -> List (Html msg)
    -> Html msg
view config content =
    Html.div [ id config.id, class "fixed inset-0 z-50 overflow-y-auto flex items-start justify-center px-4 pt-[10vh] sm:pt-[14vh] pb-4" ]
        [ Html.div
            [ class "fixed inset-0"
            , style "background" "rgba(20, 22, 38, 0.55)"
            , onClick config.onClose
            , attribute "aria-hidden" "true"
            ]
            []
        , Html.div
            [ class ("q-card sheet relative w-full " ++ config.width ++ " p-5 sm:p-6")
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" config.label
            ]
            (Html.div [ class "flex items-center justify-between mb-3" ]
                [ Html.h2 [ class "pixel q-eyebrow text-[9px]" ] [ Html.text config.heading ]
                , Html.button
                    [ type_ "button"
                    , id config.closeId
                    , onClick config.onClose
                    , attribute "aria-label" "Close"
                    , class "q-note text-base px-2 py-1 -mr-2 hover:text-[color:var(--red)]"
                    ]
                    [ Html.text "✕" ]
                ]
                :: content
            )
        ]
