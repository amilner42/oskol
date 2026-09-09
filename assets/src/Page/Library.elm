module Page.Library exposing (Model, Msg(..), init, title, update, view)

{-| `/` — the library: every registered game as a poster.

Two grids, and only one of them is ever laid out: a phone gets four square
tiles carrying a line-art motif, a desktop screen gets the cabinets with
their animated art. The art reel is the whole point of a cabinet on a big
screen and far too heavy on a phone, so the two swap at `sm`.

-}

import Api
import Api.Catalog as Catalog exposing (Game)
import GameArt
import Html exposing (Html)
import Html.Attributes exposing (class, href, id)
import Route
import Session exposing (Session)
import Ui.Notebook exposing (style)


type alias Model =
    { session : Session
    , games : List Game
    , comingSoon : List Game
    , error : Maybe String
    }


type Msg
    = GotLibrary (Result Api.Error Catalog.Library)


title : String
title =
    "Two-player games from a link"


init : Session -> ( Model, Cmd Msg )
init session =
    ( { session = session, games = [], comingSoon = [], error = Nothing }
    , Catalog.fetchLibrary session GotLibrary
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotLibrary (Ok library) ->
            ( { model | games = library.games, comingSoon = library.comingSoon, error = Nothing }
            , Cmd.none
            )

        GotLibrary (Err err) ->
            ( { model | error = Just (Api.errorMessage err) }, Cmd.none )


view : Model -> Html Msg
view model =
    Html.div []
        [ hero
        , steps
        , case model.error of
            Just message ->
                Html.p
                    [ id "library-error"
                    , class "mb-4 text-sm font-semibold px-4 py-3"
                    , style "border: 2px solid var(--red); color: var(--red); background: #fff3f2"
                    ]
                    [ Html.text message ]

            Nothing ->
                Html.text ""
        , Html.section [ id "game-tiles", class "grid grid-cols-2 gap-4 sm:hidden" ]
            (List.map tileCabinet model.games ++ List.map soonTileCabinet model.comingSoon)
        , Html.section [ id "game-library", class "hidden sm:grid gap-5 sm:gap-8 sm:grid-cols-2" ]
            (List.map cabinet model.games ++ List.map soonCabinet model.comingSoon)
        ]


hero : Html msg
hero =
    Html.section [ class "pt-10 sm:pt-14 pb-10 sm:pb-12 text-center" ]
        [ Html.h1
            [ class "pixel text-lg sm:text-3xl leading-[1.7] sm:leading-[1.6]"
            , style "color: var(--ink)"
            ]
            [ Html.text "PLAY THE CLASSICS."
            , Html.br [] []
            , Html.span [ class "hl px-1" ] [ Html.text "WITH A TWIST." ]
            ]
        , Html.p
            [ class "mt-4 text-base sm:text-lg max-w-md sm:max-w-xl mx-auto"
            , style "color: var(--pencil)"
            ]
            [ Html.text "Free · No sign up · No ads" ]
        ]


steps : Html msg
steps =
    Html.section [ class "mb-8 sm:mb-10 grid grid-cols-3 gap-3 sm:gap-4" ]
        [ step "1" "PICK GAME" "Choose a mode, the settings and an optional clock."
        , step "2" "SHARE LINK" "Your opponent opens it and types a name."
        , step "3" "GAME ON" "The game starts the moment they join."
        ]


step : String -> String -> String -> Html msg
step n stepTitle body =
    Html.div [ class "pix-sm p-3 sm:p-4 flex gap-2.5 sm:gap-3 items-center sm:items-start" ]
        [ Html.span
            [ class "pixel text-xs sm:text-sm shrink-0 w-8 h-8 sm:w-9 sm:h-9 grid place-items-center"
            , style "background: var(--highlighter); color: var(--ink)"
            ]
            [ Html.text n ]
        , Html.div [ class "min-w-0" ]
            [ Html.div
                [ class "pixel text-[8px] sm:text-[10px] leading-relaxed", style "color: var(--ink)" ]
                (String.words stepTitle
                    |> List.map (\word -> Html.span [ class "block" ] [ Html.text word ])
                )
            , Html.div [ class "hidden sm:block text-sm mt-1.5", style "color: var(--pencil)" ]
                [ Html.text body ]
            ]
        ]



-- THE PHONE GRID


{-| One square per game, two across, each carrying a motif instead of the
cabinet's animated art.
-}
tileCabinet : Game -> Html msg
tileCabinet game =
    Html.a
        [ href (Route.href (Route.gameLanding game.slug))
        , id ("game-tile-" ++ game.slug)
        , class "cabinet game-tile pix block"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (tileFace game (Html.span [ class "cursor" ] [ Html.text "▶" ]))


{-| A phone tile for a game with no engine yet: not a link, same face.
-}
soonTileCabinet : Game -> Html msg
soonTileCabinet game =
    Html.article
        [ id ("game-tile-" ++ game.slug)
        , class "cabinet cabinet-soon game-tile pix block"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (tileFace game (Html.span [ class "text-[8px] opacity-80" ] [ Html.text "SOON" ]))


tileFace : Game -> Html msg -> List (Html msg)
tileFace game badge =
    [ Html.div
        [ class "marquee pixel text-[9px] px-2.5 py-2.5 flex items-center justify-between gap-1" ]
        [ Html.span [ class "uppercase truncate" ] [ Html.text game.name ]
        , badge
        ]
    , Html.div [ class "screen grid place-items-center p-3" ]
        [ GameArt.motif game.slug "" ]
    ]



-- THE DESKTOP GRID


cabinet : Game -> Html msg
cabinet game =
    Html.a
        [ href (Route.href (Route.gameLanding game.slug))
        , id ("game-" ++ game.slug)
        , class "cabinet pix block"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (cabinetFace game (Html.span [ class "cursor" ] [ Html.text "▶" ]))


{-| The same anatomy as a playable cabinet, but it is not a link: nothing
here navigates or dead-clicks.
-}
soonCabinet : Game -> Html msg
soonCabinet game =
    Html.article
        [ id ("game-" ++ game.slug)
        , class "cabinet cabinet-soon pix block"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (cabinetFace game (Html.span [ class "text-[9px] opacity-80" ] [ Html.text "SOON" ]))


cabinetFace : Game -> Html msg -> List (Html msg)
cabinetFace game badge =
    [ Html.div
        [ class "marquee pixel text-xs sm:text-sm px-4 py-3 flex items-center justify-between" ]
        [ Html.span [ class "uppercase" ] [ Html.text game.name ]
        , badge
        ]
    , Html.div
        [ class "screen px-3 py-3 sm:px-4 sm:py-4 flex items-center justify-center" ]
        [ GameArt.art { slug = game.slug, class = "h-40 sm:h-56", animate = True } ]
    ]
