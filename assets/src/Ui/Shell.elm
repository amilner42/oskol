module Ui.Shell exposing (Config, bare, bird, joinButton, joinCodeInputId, view)

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
import Svg
import Svg.Attributes as SvgAttr
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


{-| A page that is its own chrome (the home board): the content edge to
edge, and the code prompt when it is open.
-}
bare : Config msg -> List (Html msg) -> Html msg
bare config content =
    Html.div [ class "paper quiet min-h-screen-safe" ]
        (content
            ++ (if config.joinOpen then
                    [ joinModal config ]

                else
                    []
               )
        )


{-| JOIN GAME, for a page that draws its own top bar.
-}
joinButton : Config msg -> Html msg
joinButton config =
    Html.button
        [ class "btn-arcade plain pixel text-[9px] sm:text-[11px] px-3 py-3 sm:px-5 text-center leading-relaxed"
        , id "join-game-board"
        , onClick config.onOpenJoin
        ]
        [ Html.text "JOIN GAME" ]


topbar : Config msg -> Html msg
topbar config =
    Html.header
        [ class "w-full max-w-5xl mx-auto px-4 sm:px-6 pt-4 sm:pt-5 pb-2 flex items-center justify-between gap-3" ]
        [ Html.a
            [ href (Route.href Route.library)
            , class "inline-flex items-center"
            , attribute "aria-label" "Oskol home"
            ]
            -- Plain pixel type, no plate: the wordmark is the one loud thing
            -- the page still says, and a box around it makes it a button.
            [ bird
            , Html.span
                -- the pixel face sits low in its line box; leading-none and a
                -- one-pixel lift put its optical centre on the bird's
                [ class "pixel text-[15px] sm:text-[18px] block leading-none relative top-[1px]"
                , style "color: var(--ink)"
                ]
                [ Html.text "OSKOL" ]
            ]
        , Html.div [ class "flex items-center gap-3" ]
            [ Html.span [ class "hidden sm:block q-note text-sm leading-none" ] [ Html.text "Have a code?" ]
            , Html.button
                [ type_ "button"
                , id "open-join"
                , onClick config.onOpenJoin
                , class "q-btn yellow text-sm whitespace-nowrap px-4 py-2.5"
                ]
                [ Html.text "JOIN GAME" ]
            ]
        ]


{-| The six-character code prompt behind JOIN GAME. Codes are letters and
digits now, so the field takes both and shows them upper-case; the sixth
character auto-submits (see `Main.update`, which also folds the lookalikes
the alphabet leaves out).
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
                [ Html.text "Type the 6-character code from your friend." ]
            , Html.form [ onSubmit config.onJoinSubmit, class "space-y-3" ]
                ([ Html.input
                    [ type_ "text"
                    , id joinCodeInputId
                    , Html.Attributes.name "code"
                    , value config.joinCode
                    , attribute "inputmode" "text"
                    , attribute "pattern" "[0-9A-Za-z]*"
                    , Html.Attributes.maxlength 6
                    , attribute "autocapitalize" "characters"
                    , attribute "autocomplete" "one-time-code"
                    , Html.Attributes.placeholder "A1B2C3"
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


{-| The oskol itself: a small bird in profile, one line, before the
wordmark at the type's height. The drawing is Lucide's "bird" icon
(lucide.dev, MIT), a monoline built for this size.
-}
bird : Html msg
bird =
    Svg.svg
        [ SvgAttr.viewBox "0 0 24 24"
        , SvgAttr.class "block h-[1.9em] w-auto mr-2 shrink-0"
        , SvgAttr.fill "none"
        , SvgAttr.stroke "currentColor"
        , SvgAttr.strokeWidth "2"
        , SvgAttr.strokeLinecap "round"
        , SvgAttr.strokeLinejoin "round"
        , attribute "aria-hidden" "true"
        , attribute "style" "color: var(--ink)"
        ]
        [ Svg.path [ SvgAttr.d "M16 7h.01" ] []
        , Svg.path [ SvgAttr.d "M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20" ] []
        , Svg.path [ SvgAttr.d "m20 7 2 .5-2 .5" ] []
        , Svg.path [ SvgAttr.d "M10 18v3" ] []
        , Svg.path [ SvgAttr.d "M14 17.75V21" ] []
        , Svg.path [ SvgAttr.d "M7 18a6 6 0 0 0 3.84-10.61" ] []
        ]
