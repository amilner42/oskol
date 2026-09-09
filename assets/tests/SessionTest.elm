module SessionTest exposing (suite)

{-| What the page hands the app on boot. Guest identity is a cookie the
client never sees; the only part of it that reaches Elm is the name to
prefill, and a missing or blank one has to read as "no name" rather than as
a name that happens to be empty.
-}

import Expect
import Json.Decode as D
import Session
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Session"
        [ test "the CSRF token and the remembered name come through" <|
            \_ ->
                decode """{"csrf":"tok","guestName":"Alice"}"""
                    |> Expect.equal (Ok { csrf = "tok", guestName = Just "Alice" })
        , test "a visitor the site has never seen has no name" <|
            \_ ->
                decode """{"csrf":"tok","guestName":null}"""
                    |> Result.map .guestName
                    |> Expect.equal (Ok Nothing)
        , test "neither has one whose meta tag was not rendered at all" <|
            \_ ->
                decode """{"csrf":"tok"}"""
                    |> Result.map .guestName
                    |> Expect.equal (Ok Nothing)
        , test "a blank name is no name" <|
            \_ ->
                decode """{"csrf":"tok","guestName":"   "}"""
                    |> Result.map .guestName
                    |> Expect.equal (Ok Nothing)
        , test "flags that are not an object at all still boot the app" <|
            \_ ->
                decode "null"
                    |> Result.withDefault { csrf = "", guestName = Nothing }
                    |> Expect.equal { csrf = "", guestName = Nothing }
        , test "taking a seat updates the name the next form will show" <|
            \_ ->
                Session.withGuestName "Bob" { csrf = "tok", guestName = Just "Alice" }
                    |> Expect.equal { csrf = "tok", guestName = Just "Bob" }
        ]


decode : String -> Result D.Error Session.Session
decode =
    D.decodeString Session.decoder
