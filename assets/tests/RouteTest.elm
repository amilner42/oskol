module RouteTest exposing (suite)

{-| The client's routes are the server's routes. Every URL the app can be
served at, and every URL it hands to `pushUrl`, has to round-trip through
this module or a visitor ends up on the wrong page.

No route carries a credential any more: who a visitor is rides on their
guest cookie. Links minted before seat tokens were dropped carry a `?t=`,
and the tests below pin what that is worth now, which is nothing at all.

-}

import Expect
import Route exposing (Route(..))
import Test exposing (Test, describe, test)
import Url


suite : Test
suite =
    describe "Route"
        [ describe "fromUrl"
            [ test "the library" <|
                \_ -> Expect.equal (Just Library) (parse "/")
            , test "a game's start page" <|
                \_ -> Expect.equal (Just (GameLanding "backgammon" Nothing)) (parse "/backgammon")
            , test "an invite link carries the room code" <|
                \_ ->
                    Expect.equal
                        (Just (GameLanding "backgammon" (Just "AB12CD")))
                        (parse "/backgammon?game=AB12CD")
            , test "a running game" <|
                \_ ->
                    Expect.equal
                        (Just (Play "backgammon" "AB12CD"))
                        (parse "/backgammon/AB12CD")
            , test "an old link's seat token is read by nobody" <|
                \_ ->
                    Expect.equal
                        (Just (Play "backgammon" "AB12CD"))
                        (parse "/backgammon/AB12CD?t=an-old-token")
            , test "and neither is one on an invite" <|
                \_ ->
                    Expect.equal
                        (Just (GameLanding "backgammon" (Just "AB12CD")))
                        (parse "/backgammon?game=AB12CD&t=an-old-token")
            , test "a replay, opening one game" <|
                \_ ->
                    Expect.equal
                        (Just (Replay "backgammon" "AB12CD" (Just 2) Nothing))
                        (parse "/backgammon/AB12CD/replay?game=2")
            , test "a replay, opening one game on one line" <|
                \_ ->
                    Expect.equal
                        (Just (Replay "backgammon" "AB12CD" (Just 2) (Just 17)))
                        (parse "/backgammon/AB12CD/replay?game=2&step=17")
            , test "a replay with no game named opens wherever the page decides" <|
                \_ ->
                    Expect.equal
                        (Just (Replay "backgammon" "AB12CD" Nothing Nothing))
                        (parse "/backgammon/AB12CD/replay")
            , test "an old replay link still opens its game" <|
                \_ ->
                    Expect.equal
                        (Just (Replay "backgammon" "AB12CD" (Just 2) Nothing))
                        (parse "/backgammon/AB12CD/replay?t=an-old-token&game=2")
            , test "a game that is not a number is no game" <|
                \_ ->
                    Expect.equal
                        (Just (Replay "backgammon" "AB12CD" Nothing Nothing))
                        (parse "/backgammon/AB12CD/replay?game=two")
            , test "a puzzle, by its id" <|
                \_ -> Expect.equal (Just (Puzzle "AB12CD34")) (parse "/puzzles/AB12CD34")
            , test "a puzzle is not a room of a game called puzzles" <|
                \_ -> Expect.notEqual (Just (Play "puzzles" "AB12CD34")) (parse "/puzzles/AB12CD34")
            , test "practising is its own page, not a game's start page" <|
                \_ -> Expect.equal (Just Puzzles) (parse "/puzzles")
            , test "the sitemap belongs to the server" <|
                \_ -> Expect.equal Nothing (parse "/sitemap.xml")
            , test "so does the dev dashboard" <|
                \_ -> Expect.equal Nothing (parse "/dev/dashboard")
            , test "anything deeper than a game is nothing of ours" <|
                \_ -> Expect.equal Nothing (parse "/backgammon/AB12CD/extra")
            ]
        , describe "href"
            [ test "the library" <|
                \_ -> Expect.equal "/" (Route.href Route.library)
            , test "backgammon's start page is the home page" <|
                \_ -> Expect.equal "/" (Route.href (Route.gameLanding "backgammon"))
            , test "and the home page parses back as the home, not a second address" <|
                \_ -> Expect.equal (Just Library) (parse (Route.href (Route.gameLanding "backgammon")))
            , test "an invite link: the room, and nothing identifying" <|
                \_ -> Expect.equal "/backgammon?game=AB12CD" (Route.href (Route.invite "backgammon" "AB12CD"))
            , test "the practice home" <|
                \_ -> Expect.equal "/puzzles" (Route.href Route.puzzles)
            , test "a puzzle's link" <|
                \_ -> Expect.equal "/puzzles/AB12CD34" (Route.href (Route.puzzle "AB12CD34"))
            , test "a seat's link is the room's link: there is nothing else to it" <|
                \_ ->
                    Route.href (Route.play "backgammon" "AB12CD")
                        |> Expect.equal "/backgammon/AB12CD"
            , test "a replay's link: the room, then the game" <|
                \_ ->
                    Route.href (Route.replay "backgammon" "AB12CD" (Just 3))
                        |> Expect.equal "/backgammon/AB12CD/replay?game=3"
            , test "nothing the client builds carries a token" <|
                \_ ->
                    [ Route.href (Route.invite "backgammon" "AB12CD")
                    , Route.href (Route.play "backgammon" "AB12CD")
                    , Route.href (Route.replay "backgammon" "AB12CD" (Just 3))
                    ]
                        |> List.filter (String.contains "t=")
                        |> Expect.equal []
            ]
        , describe "round trip"
            (List.map roundTrip
                [ Library
                , GameLanding "backgammon" (Just "AB12CD")
                , Play "backgammon" "AB12CD"
                , Puzzles
                , Puzzle "AB12CD34"
                , Replay "backgammon" "AB12CD" (Just 2) Nothing
                , Replay "backgammon" "AB12CD" (Just 2) (Just 17)
                , Replay "backgammon" "AB12CD" Nothing Nothing
                ]
            )
        ]


roundTrip : Route -> Test
roundTrip route =
    test ("href then fromUrl is the same route: " ++ Route.href route) <|
        \_ -> Expect.equal (Just route) (parse (Route.href route))


parse : String -> Maybe Route
parse path =
    Url.fromString ("http://localhost:4400" ++ path)
        |> Maybe.andThen Route.fromUrl
