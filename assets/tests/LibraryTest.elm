module LibraryTest exposing (suite)

{-| The library renders both grids on every visit and lets CSS choose: the
phone's four square tiles (`#game-tiles`, `sm:hidden`) and the desktop
cabinets (`#game-library`, `hidden sm:grid`). Which one a visitor sees is a
media query, so what a test can hold onto is that both are there, complete,
and pointing at the right pages.
-}

import Api
import Api.Catalog as Catalog
import Expect
import Html.Attributes as Attr
import Page.Library as Library
import Session exposing (Session)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)


suite : Test
suite =
    describe "Page.Library"
        [ test "the phone grid is two across and hidden from sm up" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-tiles" ]
                    |> Query.has [ class "grid-cols-2", class "sm:hidden" ]
        , test "the desktop grid is hidden below sm" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-library" ]
                    |> Query.has [ class "hidden", class "sm:grid" ]
        , test "one tile and one cabinet per game, playable or not" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.find [ id "game-tiles" ]
                            >> Query.findAll [ class "game-tile" ]
                            >> Query.count (Expect.equal 3)
                        , Query.find [ id "game-tiles" ]
                            >> Query.findAll [ tag "a" ]
                            >> Query.count (Expect.equal 2)
                        , Query.find [ id "game-library" ]
                            >> Query.findAll [ class "cabinet" ]
                            >> Query.count (Expect.equal 3)
                        , Query.find [ id "game-library" ]
                            >> Query.findAll [ tag "a" ]
                            >> Query.count (Expect.equal 2)
                        ]
        , test "both link to the game's start page" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.find [ id "game-tile-poker" ]
                            >> Query.has [ tag "a", attribute (Attr.href "/poker") ]
                        , Query.find [ id "game-poker" ]
                            >> Query.has [ tag "a", attribute (Attr.href "/poker") ]
                        ]
        , test "the phone tile carries the motif: one small drawing, no reel" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-tile-poker" ]
                    |> Expect.all
                        [ Query.has [ attribute (Attr.attribute "viewBox" "0 0 64 64") ]
                        , Query.hasNot [ class "game-art-anim" ]
                        ]
        , test "the desktop cabinet carries the reel, and it animates" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-poker" ]
                    |> Query.has [ class "game-art", class "game-art-anim", class "game-art-reel" ]
        , test "a game with no engine yet is not a link and says SOON" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-checkers" ]
                    |> Expect.all
                        [ Query.has [ tag "article", class "cabinet-soon", text "SOON" ]
                        , Query.hasNot [ tag "a" ]
                        ]
        , test "the headline and the three steps are always there" <|
            \_ ->
                loaded
                    |> Query.has
                        [ text "PLAY THE CLASSICS."
                        , text "WITH A TWIST."
                        , text "PICK"
                        , text "SHARE"
                        , text "ON"
                        ]
        , test "a catalogue that will not load says so instead of an empty page" <|
            \_ ->
                Library.init (session ())
                    |> Tuple.first
                    |> send (Library.GotLibrary (Err Api.NetworkError))
                    |> render
                    |> Query.find [ id "library-error" ]
                    |> Query.has [ text "Lost the connection. Try again." ]
        ]



-- HARNESS


loaded : Query.Single Library.Msg
loaded =
    Library.init (session ())
        |> Tuple.first
        |> send (Library.GotLibrary (Api.parseBody Catalog.libraryDecoder libraryJson))
        |> render


session : () -> Session
session () =
    { csrf = "token", guestName = Nothing }


send : Library.Msg -> Library.Model -> Library.Model
send msg model =
    Library.update msg model |> Tuple.first


render : Library.Model -> Query.Single Library.Msg
render =
    Library.view >> Query.fromHtml


libraryJson : String
libraryJson =
    """
    {"ok":true,
     "games":[
       {"slug":"poker","name":"Poker","description":"Hold'em for two."},
       {"slug":"backgammon","name":"Backgammon","description":"The race game."}],
     "coming_soon":[{"slug":"checkers","name":"Checkers","description":"Soon."}]}
    """
