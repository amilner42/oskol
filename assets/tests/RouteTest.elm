module RouteTest exposing (suite)

{-| The client's routes are the server's routes. Every URL the app can be
served at, and every URL it hands to `pushUrl`, has to round-trip through
this module or a visitor ends up on the wrong page.
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
                \_ -> Expect.equal (Just (GameLanding "backgammon" Nothing Nothing)) (parse "/backgammon")
            , test "an invite link carries the room code" <|
                \_ ->
                    Expect.equal
                        (Just (GameLanding "backgammon" (Just "123456") Nothing))
                        (parse "/backgammon?game=123456")
            , test "an invite link with a seat token carries both" <|
                \_ ->
                    Expect.equal
                        (Just (GameLanding "backgammon" (Just "123456") (Just "secret")))
                        (parse "/backgammon?game=123456&t=secret")
            , test "a running game" <|
                \_ ->
                    Expect.equal
                        (Just (Play "backgammon" "123456" (Just "secret")))
                        (parse "/backgammon/123456?t=secret")
            , test "a running game with no token: the server decides what that is worth" <|
                \_ ->
                    Expect.equal (Just (Play "backgammon" "123456" Nothing)) (parse "/backgammon/123456")
            , test "a seat token is percent-decoded" <|
                \_ ->
                    parse "/backgammon/123456?t=a%2Fb%2Bc"
                        |> Expect.equal (Just (Play "backgammon" "123456" (Just "a/b+c")))
            , test "the sitemap belongs to the server" <|
                \_ -> Expect.equal Nothing (parse "/sitemap.xml")
            , test "so does the dev dashboard" <|
                \_ -> Expect.equal Nothing (parse "/dev/dashboard")
            , test "anything deeper than a game is nothing of ours" <|
                \_ -> Expect.equal Nothing (parse "/backgammon/123456/extra")
            ]
        , describe "href"
            [ test "the library" <|
                \_ -> Expect.equal "/" (Route.href Route.library)
            , test "a game's start page" <|
                \_ -> Expect.equal "/backgammon" (Route.href (Route.gameLanding "backgammon"))
            , test "an invite link: the room, and nothing identifying" <|
                \_ -> Expect.equal "/backgammon?game=123456" (Route.href (Route.invite "backgammon" "123456"))
            , test "a seat's own link" <|
                \_ ->
                    Route.href (Route.play "backgammon" "123456" (Just "secret"))
                        |> Expect.equal "/backgammon/123456?t=secret"
            , test "a seat token is percent-encoded on the way out" <|
                \_ ->
                    Route.href (Route.play "backgammon" "123456" (Just "a/b+c"))
                        |> Expect.equal "/backgammon/123456?t=a%2Fb%2Bc"
            ]
        , describe "round trip"
            (List.map roundTrip
                [ Library
                , GameLanding "backgammon" Nothing Nothing
                , GameLanding "backgammon" (Just "123456") Nothing
                , GameLanding "backgammon" (Just "123456") (Just "a/b+c")
                , Play "backgammon" "123456" (Just "secret")
                , Play "backgammon" "123456" Nothing
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
