module LibraryTest exposing (suite)

{-| The library is one grid of calm tiles (`#game-library`, two across on a
phone and four from `sm` up), under a head that says two things and nothing
else. Each tile carries both drawings — the motif a phone sees and the reel
a desktop screen sees — and CSS picks; what a test can hold onto is that
both are there, that every game has a tile, and that the playable ones are
links.
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
        [ test "the head is the title and the three words, and no other copy" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.find [ tag "h1" ] >> Query.has [ text "PLAY THE CLASSICS." ]
                        , Query.find [ tag "h1" ] >> Query.has [ text "WITH A TWIST." ]
                        , Query.has [ text "create game" ]
                        , Query.has [ text "share code" ]
                        , Query.has [ text "play a friend" ]
                        , Query.findAll [ class "q-num" ] >> Query.count (Expect.equal 3)
                        , Query.hasNot [ text "Free · No sign up · No ads" ]
                        ]
        , test "one grid: two across at every width" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-library" ]
                    |> Query.has [ class "grid-cols-2" ]
        , test "one tile per game, playable or not, and the playable ones link" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.find [ id "game-library" ]
                            >> Query.findAll [ class "q-card" ]
                            >> Query.count (Expect.equal 3)
                        , Query.find [ id "game-library" ]
                            >> Query.findAll [ tag "a" ]
                            >> Query.count (Expect.equal 2)
                        , Query.find [ id "game-poker" ]
                            >> Query.has [ tag "a", attribute (Attr.href "/poker") ]
                        , Query.find [ id "game-backgammon" ]
                            >> Query.has [ tag "a", attribute (Attr.href "/backgammon") ]
                        ]
        , test "a tile carries the phone's motif and the desktop's reel" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-poker" ]
                    |> Expect.all
                        [ Query.has [ attribute (Attr.attribute "viewBox" "0 0 64 64") ]
                        , Query.has [ class "game-art", class "game-art-anim", class "game-art-reel" ]
                        ]
        , test "a game with no engine yet is dimmed, says Soon and is not a link" <|
            \_ ->
                loaded
                    |> Query.find [ id "game-checkers" ]
                    |> Expect.all
                        [ Query.has [ tag "article", class "q-card-soon", text "Soon" ]
                        , Query.hasNot [ tag "a" ]
                        , Query.hasNot [ class "game-art-anim" ]
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
