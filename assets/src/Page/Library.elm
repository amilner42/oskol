module Page.Library exposing (Model, Msg(..), init, title, update, view)

{-| `/` — the library: every registered game as a calm tile.

One headline, one line under it, and then the games: a grid of paper tiles,
two across on a phone and four across from `sm` up. A tile carries the
game's art — the line-art motif on a phone, the animated reel on a desktop
screen, where it is worth the frames — over the game's name.

A game with no engine yet gets the same tile, dimmed, and is not a link.

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
        , case model.error of
            Just message ->
                Html.p
                    [ id "library-error"
                    , class "mb-4 text-sm font-semibold px-4 py-3"
                    , style "border: 1.5px solid var(--red); color: var(--red); background: #fff3f2"
                    ]
                    [ Html.text message ]

            Nothing ->
                Html.text ""
        , Html.section
            [ id "game-library", class "grid grid-cols-2 sm:grid-cols-4 gap-4 sm:gap-5" ]
            (List.map tile model.games ++ List.map soonTile model.comingSoon)
        ]


{-| The whole of the head: the title, and the three words under it. Nothing
else belongs up here.
-}
hero : Html msg
hero =
    Html.section [ class "pt-8 sm:pt-16 pb-8 sm:pb-12" ]
        [ Html.h1 [ class "q-title text-[34px] sm:text-6xl" ]
            [ Html.text "Play the classics" ]
        , Html.p [ class "q-note mt-3 sm:mt-4 text-base sm:text-xl" ]
            [ Html.text "create game → share code → play" ]
        ]


tile : Game -> Html msg
tile game =
    Html.a
        [ href (Route.href (Route.gameLanding game.slug))
        , id ("game-" ++ game.slug)
        , class "q-card block overflow-hidden"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (tileFace game Nothing)


{-| A game with no engine yet: the same tile, dimmed, and not a link — so
nothing here navigates or dead-clicks.
-}
soonTile : Game -> Html msg
soonTile game =
    Html.article
        [ id ("game-" ++ game.slug)
        , class "q-card q-card-soon block overflow-hidden"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (tileFace game (Just "Soon"))


tileFace : Game -> Maybe String -> List (Html msg)
tileFace game badge =
    [ Html.div
        [ class "q-art flex items-center justify-center p-3 sm:p-4" ]
        [ GameArt.motif game.slug "sm:hidden w-full h-[88px]"
        , GameArt.art
            { slug = game.slug
            , class = "hidden sm:block h-32 lg:h-36"
            , animate = badge == Nothing
            }
        ]
    , Html.div [ class "px-3 py-2.5 sm:px-4 sm:py-3.5" ]
        [ Html.div [ class "flex items-baseline justify-between gap-2" ]
            [ Html.span [ class "font-semibold text-[15px] sm:text-base truncate" ]
                [ Html.text game.name ]
            , case badge of
                Just label ->
                    Html.span [ class "q-note text-xs shrink-0" ] [ Html.text label ]

                Nothing ->
                    Html.text ""
            ]

        -- The line is worth its room on a desktop screen and not on a phone,
        -- where the name and the drawing already say it.
        , Html.p [ class "hidden sm:block q-note text-[13px] leading-snug mt-1" ]
            [ Html.text game.description ]
        ]
    ]
