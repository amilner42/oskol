module MainUpdateTest exposing (suite)

{-| The app's update loop fed with real payloads: replaying a fixture through
`applyPayload` must never lose the game state, and the score reveal must
start and hold the board until dismissed.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Main
import Protocol exposing (Event(..), GamePayload, Update)
import Test exposing (Test, describe, test)
import Types exposing (..)


payload : Fixture -> String -> Update -> GamePayload
payload fixture playerId update =
    { game = fixture.game
    , gameId = "fixture"
    , playerId = playerId
    , players = List.map (\( id, name ) -> { id = id, name = name, connected = True }) fixture.seats
    , rematchReady = []
    , rematchGameId = Nothing
    , update = update
    }


start : Fixture -> Model
start fixture =
    Main.init { gameId = "fixture", gameSlug = fixture.game, playerId = Just "p1" } |> Tuple.first


feed : Fixture -> Model -> Update -> Model
feed fixture model update =
    Main.applyPayload (payload fixture "p1" update) model |> Tuple.first


suite : Test
suite =
    describe "Main.update with fixture payloads"
        (List.map replay FixtureLoader.all ++ [ tiltReveal ])


replay : Fixture -> Test
replay fixture =
    test (fixture.name ++ " replays without losing state") <|
        \_ ->
            let
                updates =
                    (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

                final =
                    List.foldl (\u m -> feed fixture m u) (start fixture) updates

                ok m =
                    case ( fixture.game, m.gameState ) of
                        ( "tilt", Success _ ) ->
                            True

                        ( "tilt", _ ) ->
                            False

                        _ ->
                            m.payload /= Nothing
            in
            Expect.all
                [ \m -> Expect.equal True (ok m)
                , \m -> Expect.equal (List.length updates > 0) True
                , \m -> Expect.equal (Just "p1") m.playerId
                ]
                final


tiltReveal : Test
tiltReveal =
    test "a hands_resolved payload starts the reveal and holds the playing view until dismissed" <|
        \_ ->
            case FixtureLoader.byGame "tilt" of
                fixture :: _ ->
                    let
                        updates =
                            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

                        isResolved u =
                            List.any
                                (\e ->
                                    case e of
                                        Custom "hands_resolved" _ ->
                                            True

                                        _ ->
                                            False
                                )
                                u.events

                        beforeAndAt =
                            updates |> List.indexedMap Tuple.pair |> List.filter (\( _, u ) -> isResolved u) |> List.head
                    in
                    case beforeAndAt of
                        Just ( index, resolved ) ->
                            let
                                model =
                                    List.foldl (\u m -> feed fixture m u) (start fixture) (List.take index updates)

                                afterReveal =
                                    feed fixture model resolved

                                dismissed =
                                    Main.update DismissResults afterReveal |> Tuple.first
                            in
                            Expect.all
                                [ \_ -> Expect.equal True afterReveal.viewingResults
                                , \_ -> Expect.notEqual Nothing afterReveal.currentAnimationData
                                , \_ ->
                                    case afterReveal.gameState of
                                        Success (PlayingView p) ->
                                            Expect.notEqual Nothing p.pendingAnimation

                                        _ ->
                                            Expect.fail "reveal should show the playing view"
                                , \_ -> Expect.equal False dismissed.viewingResults
                                ]
                                ()

                        Nothing ->
                            Expect.fail "fixture has no hands_resolved step"

                [] ->
                    Expect.fail "no tilt fixture"
