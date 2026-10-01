module Ui.Shell exposing (Config, bare, barMark, bird, mark, joinButton, joinCodeInputId, view)

{-| The chrome a page sits in: the shell's bar on top (passed in), the JOIN
GAME prompt behind its ☰, and the footer.

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
import Ui.Dialog as Dialog
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


view : Config msg -> List (Html msg) -> List (Html msg) -> Html msg
view config bar content =
    Html.div [ class "paper quiet min-h-screen-safe flex flex-col" ]
        (bar
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
                    [ Html.text "Free · No account needed · Play a friend from a link, then learn from the game" ]
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


{-| The six-character code prompt behind JOIN GAME. Codes are letters and
digits now, so the field takes both and shows them upper-case; the sixth
character auto-submits (see `Main.update`, which also folds the lookalikes
the alphabet leaves out).
-}
joinModal : Config msg -> Html msg
joinModal config =
    Dialog.view
        { id = "join-modal"
        , closeId = "close-join"
        , label = "Join a game by code"
        , heading = "JOIN GAME"
        , onClose = config.onCloseJoin
        , width = "max-w-sm"
        }
        [ Html.p [ class "q-note text-sm mb-3" ]
            [ Html.text "Type the 6-character code from your friend." ]
        , Html.form [ onSubmit config.onJoinSubmit, class "flex flex-col gap-2.5" ]
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
                -- Full width, as SIGN IN's is: the one thing to press.
                ++ [ Html.button [ type_ "submit", id "join-submit", class "q-btn w-full px-6 py-3 text-[15px]" ]
                        [ Html.text "JOIN GAME" ]
                   ]
            )
        ]


{-| The mark: the bird and the word, the same size and the same distance
apart on every page, a link home. Its colour is the page's (`.oskol-mark`
in app.css; the home board paints it white).
-}
mark : Html msg
mark =
    Html.a [ href "/", class "oskol-mark inline-flex items-center gap-1.5 shrink-0", attribute "aria-label" "Oskol home" ]
        [ bird, Html.span [ class "pixel text-[13px] sm:text-[16px] relative top-[2px]" ] [ Html.text "OSKOL" ] ]


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


{-| The bar's left end: the bird, alone (the wordmark is the page's
title), home. The same on both homes' bar and on the loading screen
before either, so it never moves when one becomes the other.
-}
barMark : Html msg
barMark =
    Html.a [ href "/", class "lh-mark", attribute "aria-label" "Oskol home" ]
        [ Svg.svg
            [ SvgAttr.viewBox "0 0 24 24"
            , SvgAttr.width "24"
            , SvgAttr.height "24"
            , SvgAttr.fill "none"
            , SvgAttr.stroke "currentColor"
            , SvgAttr.strokeWidth "2"
            , SvgAttr.strokeLinecap "round"
            , SvgAttr.strokeLinejoin "round"
            , attribute "aria-hidden" "true"
            ]
            [ Svg.path [ SvgAttr.d "M16 7h.01" ] []
            , Svg.path [ SvgAttr.d "M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20" ] []
            , Svg.path [ SvgAttr.d "m20 7 2 .5-2 .5" ] []
            , Svg.path [ SvgAttr.d "M10 18v3" ] []
            , Svg.path [ SvgAttr.d "M14 17.75V21" ] []
            , Svg.path [ SvgAttr.d "M7 18a6 6 0 0 0 3.84-10.61" ] []
            ]
        ]
