module Ui.Shell exposing (Config, joinCodeInputId, view)

{-| The chrome every landing page sits in: the OSKOL wordmark, the JOIN GAME
prompt behind it, and the footer.

Quiet notebook: the paper and its grid stay, and the pixel font is kept for
the wordmark and the eyebrows alone. Everything else here — the button, the
prompt, the footer — is the page's sans on 1.5px rules and 3px shadows.

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
    Html.div [ class "paper quiet min-h-screen-safe flex flex-col" ]
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
                    [ class "q-note text-xs sm:text-sm text-center pb-6 px-4" ]
                    [ Html.text "Free · No accounts · By the book, until you flip a twist" ]
               ]
        )


topbar : Config msg -> Html msg
topbar config =
    Html.header
        [ class "w-full max-w-5xl mx-auto px-4 sm:px-6 pt-4 sm:pt-5 pb-2 flex items-center justify-between gap-3" ]
        [ Html.a
            [ href (Route.href Route.library)
            , class "inline-block"
            , attribute "aria-label" "Oskol home"
            ]
            -- Plain pixel type, no plate: the wordmark is the one loud thing
            -- the page still says, and a box around it makes it a button.
            [ Html.span
                [ class "pixel text-[12px] sm:text-[13px] inline-block"
                , style "color: var(--ink)"
                ]
                [ Html.text "OSKOL" ]
            ]
        , Html.div [ class "flex items-center gap-3" ]
            [ Html.span [ class "hidden sm:inline q-note text-sm" ] [ Html.text "Have a code?" ]
            , Html.button
                [ type_ "button"
                , id "open-join"
                , onClick config.onOpenJoin
                , class "q-btn yellow text-sm whitespace-nowrap px-4 py-2.5"
                ]
                [ Html.text "JOIN GAME" ]
            ]
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
            , style "background: rgba(35, 36, 58, 0.45)"
            , onClick config.onCloseJoin
            , attribute "aria-hidden" "true"
            ]
            []
        , Html.div
            [ class "q-card relative w-full max-w-sm p-5 sm:p-6"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" "Join a game by code"
            ]
            [ Html.div [ class "flex items-center justify-between mb-3" ]
                [ Html.h2 [ class "pixel q-eyebrow text-[9px]" ] [ Html.text "JOIN GAME" ]
                , Html.button
                    [ type_ "button"
                    , id "close-join"
                    , onClick config.onCloseJoin
                    , attribute "aria-label" "Close"
                    , class "q-note text-base px-2 py-1 hover:text-[color:var(--red)]"
                    ]
                    [ Html.text "✕" ]
                ]
            , Html.p [ class "q-note text-sm mb-3" ]
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
                    , class "q-field w-full px-4 py-3 text-center text-2xl font-mono tracking-[0.4em]"
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
                                    , class "text-sm font-semibold leading-relaxed"
                                    , style "color: var(--red)"
                                    ]
                                    [ Html.text message ]
                                ]

                            Nothing ->
                                []
                       )
                    ++ [ Notebook.submitCta { id = "join-submit", label = "Join game" } ]
                )
            ]
        ]
