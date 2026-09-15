module Page.Library exposing (Model, Msg(..), init, subscriptions, title, update, view)

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
import Html.Attributes exposing (attribute, class, href, id)
import Route
import Session exposing (Session)
import Time
import Ui.Notebook exposing (style)


type alias Model =
    { session : Session
    , games : List Game
    , comingSoon : List Game
    , error : Maybe String
    , spotlight : Int -- which game's card is animating: one at a time, in turn
    }


type Msg
    = GotLibrary (Result Api.Error Catalog.Library)
    | Spotlight Time.Posix


title : String
title =
    "Two-player games from a link"


init : Session -> ( Model, Cmd Msg )
init session =
    ( { session = session, games = [], comingSoon = [], error = Nothing, spotlight = 0 }
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

        Spotlight _ ->
            ( { model | spotlight = modBy (max 1 (List.length model.games)) (model.spotlight + 1) }
            , Cmd.none
            )


{-| One card animates at a time. The spotlight stays on a card for one full
run of its reel, then moves to the next game.
-}
subscriptions : Model -> Sub Msg
subscriptions model =
    case List.drop model.spotlight model.games |> List.head of
        Just game ->
            Time.every (toFloat (GameArt.reelMs game.slug)) Spotlight

        Nothing ->
            Sub.none


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
            [ id "game-library", class "grid grid-cols-2 gap-4 sm:gap-8" ]
            (List.indexedMap (\i game -> tile (i == model.spotlight) game) model.games
                ++ List.map soonTile model.comingSoon
            )
        ]


{-| The whole of the head, centred: the pixel title the site has always
had, and the three steps as one line of plain text under it. No subtitle,
no boxes: nothing else belongs up here.
-}
hero : Html msg
hero =
    Html.section [ class "pt-10 sm:pt-14 pb-8 sm:pb-12 text-center" ]
        [ Html.h1
            [ class "pixel text-lg sm:text-3xl leading-[1.7] sm:leading-[1.6]"
            , style "color: var(--ink)"
            ]
            [ Html.text "PLAY THE CLASSICS."
            , Html.br [] []
            , Html.span [ class "hl px-1" ] [ Html.text "WITH A TWIST." ]
            ]
        , Html.p [ class "q-steps q-note mt-5 sm:mt-6 text-base sm:text-xl flex flex-wrap items-center justify-center gap-x-6 sm:gap-x-10 gap-y-2" ]
            [ stepWord "1" "create game"
            , stepWord "2" "share code"
            , stepWord "3" "play a friend"
            ]
        ]


{-| One step of the three: a hand-drawn circled number and its words.
-}
stepWord : String -> String -> Html msg
stepWord n words =
    Html.span [ class "inline-flex items-center gap-2 sm:gap-2.5 whitespace-nowrap" ]
        [ Html.span [ class "q-num", attribute "aria-hidden" "true" ] [ Html.text n ]
        , Html.text words
        ]


tile : Bool -> Game -> Html msg
tile lit game =
    Html.a
        [ href (Route.href (Route.gameLanding game.slug))
        , id ("game-" ++ game.slug)
        , class "q-card block overflow-hidden"
        , style ("--accent: " ++ GameArt.accent game.slug)
        ]
        (tileFace game lit Nothing)


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
        (tileFace game False (Just "Soon"))


tileFace : Game -> Bool -> Maybe String -> List (Html msg)
tileFace game lit badge =
    [ Html.div
        [ class "q-art flex items-center justify-center p-4 sm:p-8" ]
        [ GameArt.motif game.slug "sm:hidden w-full h-[88px]"
        , GameArt.art
            { slug = game.slug
            , class = "hidden sm:block h-44 lg:h-56"
            , animate = lit
            }
        ]
    , Html.div [ class "px-3 py-2.5 sm:px-5 sm:py-4" ]
        [ Html.div [ class "flex items-baseline justify-between gap-2" ]
            [ Html.span [ class "font-semibold text-[15px] sm:text-lg truncate tracking-tight" ]
                [ Html.text game.name ]
            , case badge of
                Just label ->
                    Html.span [ class "q-note text-xs shrink-0" ] [ Html.text label ]

                Nothing ->
                    Html.text ""
            ]

        ]
    ]
