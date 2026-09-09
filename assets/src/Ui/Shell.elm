module Ui.Shell exposing (Config, joinCodeInputId, view)

{-| The chrome every landing page sits in: the OSKOL plate, the JOIN GAME
prompt behind it, and the footer. A direct port of `LandingLive.render/1`,
`topbar/1` and `join_modal/1` — same elements, same ids, same classes.
-}

import Html exposing (Html)
import Html.Attributes exposing (attribute, class, href, id, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Route
import Ui.Notebook as Notebook exposing (style)


type alias Config msg =
    { joinOpen : Bool
    , joinCode : String
    , joinError : Maybe String
    , onOpenJoin : msg
    , onCloseJoin : msg
    , onJoinCodeInput : String -> msg
    , onJoinSubmit : msg
    }


joinCodeInputId : String
joinCodeInputId =
    "join-code-input"


view : Config msg -> List (Html msg) -> Html msg
view config content =
    Html.div [ class "paper min-h-screen-safe flex flex-col" ]
        ([ topbar config ]
            ++ (if config.joinOpen then
                    [ joinModal config ]

                else
                    []
               )
            ++ [ Html.main_
                    [ class "flex-1 w-full max-w-5xl mx-auto px-4 sm:px-6 pb-10 sm:pb-16" ]
                    content
               , Html.footer
                    [ class "pixel text-[8px] sm:text-[10px] leading-loose text-center pb-6 px-4"
                    , style "color: var(--pencil)"
                    ]
                    [ Html.text "FREE · NO ACCOUNTS · BY THE BOOK — UNTIL YOU FLIP A TWIST" ]
               ]
        )


topbar : Config msg -> Html msg
topbar config =
    Html.header
        [ class "w-full max-w-5xl mx-auto px-4 sm:px-6 pt-4 sm:pt-5 pb-2 flex items-center justify-between gap-3" ]
        [ Html.a
            [ href (Route.href Route.library)
            , class "pixel inline-block"
            , attribute "aria-label" "Oskol home"
            ]
            [ Html.span
                [ class "pixel text-xs sm:text-sm tracking-[0.35em] px-3.5 py-2.5 inline-block"
                , style "background: #fff; color: var(--ink); border: 3px solid var(--ink); box-shadow: 4px 4px 0 0 var(--ink)"
                ]
                [ Html.text "OSKOL" ]
            ]
        , Html.button
            [ type_ "button"
            , id "open-join"
            , onClick config.onOpenJoin
            , class "btn-arcade yellow pixel text-[9px] sm:text-[10px] whitespace-nowrap px-3.5 py-2.5"
            ]
            [ Html.text "JOIN GAME" ]
        ]


{-| The 6-digit code prompt behind JOIN GAME. `inputmode` and `pattern` get
phones the number pad; a sixth digit auto-submits (see `Main.update`).
-}
joinModal : Config msg -> Html msg
joinModal config =
    Html.div
        [ id "join-modal"
        , class "fixed inset-0 z-50 flex items-start justify-center px-4 pt-[16vh]"
        ]
        [ Html.div
            [ class "absolute inset-0"
            , style "background: rgba(26, 26, 46, 0.5)"
            , onClick config.onCloseJoin
            , attribute "aria-hidden" "true"
            ]
            []
        , Html.div
            [ class "pix relative w-full max-w-sm p-5 sm:p-6"
            , style "background: var(--paper)"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" "Join a game by code"
            ]
            [ Html.div [ class "flex items-center justify-between mb-4" ]
                [ Html.h2 [ class "pixel text-[10px] sm:text-xs", style "color: var(--ink)" ]
                    [ Html.text "JOIN GAME" ]
                , Html.button
                    [ type_ "button"
                    , id "close-join"
                    , onClick config.onCloseJoin
                    , attribute "aria-label" "Close"
                    , class "pixel text-[10px] px-2 py-1 hover:text-[color:var(--red)]"
                    , style "color: var(--pencil)"
                    ]
                    [ Html.text "✕" ]
                ]
            , Html.p [ class "text-sm mb-3", style "color: var(--pencil)" ]
                [ Html.text "Type the 6-digit code from your friend." ]
            , Html.form [ onSubmit config.onJoinSubmit, class "space-y-3" ]
                ([ Html.input
                    [ type_ "text"
                    , id joinCodeInputId
                    , Html.Attributes.name "code"
                    , value config.joinCode
                    , attribute "inputmode" "numeric"
                    , attribute "pattern" "[0-9]*"
                    , Html.Attributes.maxlength 6
                    , attribute "autocomplete" "one-time-code"
                    , Html.Attributes.placeholder "000000"
                    , class "name-field w-full px-4 py-3 text-center text-2xl font-mono tracking-[0.4em]"
                    , style "color: var(--ink)"
                    , attribute "autocorrect" "off"
                    , attribute "spellcheck" "false"
                    , onInput config.onJoinCodeInput
                    ]
                    []
                 ]
                    ++ (case config.joinError of
                            Just message ->
                                [ Html.p
                                    [ id "join-error"
                                    , class "pixel text-[9px] leading-relaxed"
                                    , style "color: var(--red)"
                                    ]
                                    [ Html.text message ]
                                ]

                            Nothing ->
                                []
                       )
                    ++ [ Notebook.submitCta { id = "join-submit", color = "green", label = "JOIN ▶" } ]
                )
            ]
        ]
