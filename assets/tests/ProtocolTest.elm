module ProtocolTest exposing (suite)

{-| Contract tests: everything the Gleam side emits must decode, and the
decoded values must be internally consistent.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Fixtures
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Event(..), Outcome(..), ParamKind(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "wire protocol"
        [ describe "every fixture decodes" (List.map decodes Fixtures.all)
        , describe "decoded fixtures are consistent" (List.map consistent FixtureLoader.all)
        , describe "helpers"
            [ test "formatClock renders minutes, seconds, and tenths under ten seconds" <|
                \_ ->
                    Expect.equal
                        [ "3:00", "0:59", "9.9", "0.0", "10:05" ]
                        (List.map Protocol.formatClock [ 180000, 59999, 9999, 0, 605000 ])
            , test "remainingNow only ticks a running clock" <|
                \_ ->
                    let
                        running =
                            { id = "a", remainingMs = 5000, moveMs = 0, running = True }

                        stopped =
                            { running | running = False }
                    in
                    Expect.equal
                        [ 3000, 5000, 0 ]
                        [ Protocol.remainingNow running 1000 3000
                        , Protocol.remainingNow stopped 1000 3000
                        , Protocol.remainingNow running 1000 99000
                        ]
            , test "encodeAction wraps name and params in the envelope the channel expects" <|
                \_ ->
                    Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ]
                        |> E.encode 0
                        |> Expect.equal "{\"type\":\"action\",\"name\":\"move\",\"params\":{\"from\":\"13\",\"to\":\"8\"}}"
            ]
        ]


decodes : ( String, String ) -> Test
decodes ( name, json ) =
    test name <|
        \_ ->
            case FixtureLoader.decode ( name, json ) of
                Ok _ ->
                    Expect.pass

                Err err ->
                    Expect.fail (D.errorToString err)


consistent : Fixture -> Test
consistent fixture =
    describe fixture.name
        [ test "the scene names the fixture's game and both seats" <|
            \_ ->
                fixture.initial
                    |> Dict.get "p1"
                    |> Maybe.map
                        (\u ->
                            Expect.all
                                [ \s -> Expect.equal fixture.game s.game
                                , \s -> Expect.equal (List.map Tuple.first fixture.seats) (List.map .id s.players)
                                , \s -> Expect.equal (Just "p1") s.viewer
                                ]
                                u.scene
                        )
                    |> Maybe.withDefault (Expect.fail "no p1 view")
        , test "spectator views carry no legal actions and no viewer id" <|
            \_ ->
                fixture.steps
                    |> List.filterMap (\step -> Dict.get "spectator" step.updates)
                    |> List.all (\u -> u.legal == [] && u.scene.viewer == Nothing)
                    |> Expect.equal True
        , test "while ongoing, somebody always has a legal action" <|
            \_ ->
                fixture.steps
                    |> List.all
                        (\step ->
                            case Dict.get "p1" step.updates |> Maybe.map (.outcome) of
                                Just (Finished _) ->
                                    True

                                _ ->
                                    [ "p1", "p2" ]
                                        |> List.any (\id -> Dict.get id step.updates |> Maybe.map (.legal >> List.isEmpty >> not) |> Maybe.withDefault False)
                        )
                    |> Expect.equal True
        , test "every step carries at least one event" <|
            \_ ->
                fixture.steps
                    |> List.all (\step -> Dict.get "p1" step.updates |> Maybe.map (.events >> List.isEmpty >> not) |> Maybe.withDefault False)
                    |> Expect.equal True
        , test "select params only offer candidates that exist in their zone" <|
            \_ ->
                (fixture.initial :: List.map .updates fixture.steps)
                    |> List.concatMap Dict.values
                    |> List.all
                        (\u ->
                            u.legal
                                |> List.concatMap .params
                                |> List.all
                                    (\param ->
                                        case param.kind of
                                            Select sel ->
                                                let
                                                    ids =
                                                        Protocol.zoneTokens sel.zone u.scene |> List.map .id
                                                in
                                                List.all (\c -> List.member c ids) sel.candidates && sel.min <= sel.max

                                            _ ->
                                                True
                                    )
                        )
                    |> Expect.equal True
        , test "token ids are unique within each zone" <|
            -- Tilt deals each player their own deck, so "KS" legitimately sits
            -- in deck:p1 and hand:p2 at once: the contract is per zone, which
            -- is what token_moved events (from zone, to zone) need.
            \_ ->
                (fixture.initial :: List.map .updates fixture.steps)
                    |> List.concatMap Dict.values
                    |> List.all
                        (\u ->
                            u.scene.zones
                                |> List.all
                                    (\zone ->
                                        let
                                            ids =
                                                List.map .id zone.tokens
                                        in
                                        List.length ids == List.length (unique ids)
                                    )
                        )
                    |> Expect.equal True
        , test "token_moved events never name a token the viewer cannot see" <|
            \_ ->
                fixture.steps
                    |> List.concatMap (\step -> Dict.values step.updates)
                    |> List.all
                        (\u ->
                            u.events
                                |> List.all
                                    (\e ->
                                        case e of
                                            TokenMoved id _ _ ->
                                                id == "" || List.any (\z -> List.any (\t -> t.id == id) z.tokens) u.scene.zones

                                            _ ->
                                                True
                                    )
                        )
                    |> Expect.equal True
        , test "token_moved events name zones that exist in the scene after the step" <|
            \_ ->
                fixture.steps
                    |> List.all
                        (\step ->
                            case Dict.get "p1" step.updates of
                                Just u ->
                                    let
                                        zoneIds =
                                            List.map .id u.scene.zones
                                    in
                                    u.events
                                        |> List.all
                                            (\e ->
                                                case e of
                                                    TokenMoved _ from to ->
                                                        [ from, to ] |> List.filterMap identity |> List.all (\z -> List.member z zoneIds)

                                                    _ ->
                                                        True
                                            )

                                Nothing ->
                                    False
                        )
                    |> Expect.equal True
        ]


unique : List comparable -> List comparable
unique =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []
