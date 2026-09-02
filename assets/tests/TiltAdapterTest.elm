module TiltAdapterTest exposing (suite)

{-| The Tilt adapter turns generic scenes into the PlayerView the bespoke UI
renders. Every fixture payload must adapt, and what it produces must agree
with the scene it came from.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Games.Tilt.Adapter as Adapter
import Protocol exposing (Event(..))
import Test exposing (Test, describe, test)
import Types exposing (PlayerView(..))


suite : Test
suite =
    describe "Tilt adapter" (List.map perFixture (FixtureLoader.byGame "tilt"))


perFixture : Fixture -> Test
perFixture fixture =
    let
        views =
            (fixture.initial :: List.map .updates fixture.steps)
                |> List.filterMap (Dict.get "p1")
    in
    describe fixture.name
        [ test "every p1 update adapts to a view" <|
            \_ ->
                views
                    |> List.all (\u -> Adapter.toPlayerView "p1" [] u.scene /= Nothing)
                    |> Expect.equal True
        , test "the view kind follows the scene phase" <|
            \_ ->
                views
                    |> List.all
                        (\u ->
                            case ( u.scene.phase, Adapter.toPlayerView "p1" [] u.scene ) of
                                ( "playing", Just (PlayingView _) ) ->
                                    True

                                ( "shop", Just (ShopView _) ) ->
                                    True

                                ( "game_over", Just (GameOverView _) ) ->
                                    True

                                _ ->
                                    False
                        )
                    |> Expect.equal True
        , test "hands and counters match the scene" <|
            \_ ->
                views
                    |> List.filterMap
                        (\u ->
                            case Adapter.toPlayerView "p1" [] u.scene of
                                Just (PlayingView p) ->
                                    Just ( u, p )

                                _ ->
                                    Nothing
                        )
                    |> List.all
                        (\( u, p ) ->
                            let
                                me =
                                    Protocol.findPlayer "p1" u.scene
                            in
                            List.length p.yourHand == List.length (Protocol.zoneTokens "hand:p1" u.scene)
                                && List.length p.opponentHand == List.length (Protocol.zoneTokens "hand:p2" u.scene)
                                && List.length p.yourDrawPile == List.length (Protocol.zoneTokens "deck:p1" u.scene)
                                && Just p.yourLives == Maybe.map (Protocol.counter "lives") me
                                && Just p.yourHandsRemaining == Maybe.map (Protocol.counter "hands_remaining") me
                                && (p.yourLockedInHand /= Nothing) == (Maybe.map (Protocol.hasFlag "locked_in") me |> Maybe.withDefault False)
                        )
                    |> Expect.equal True
        , test "the shop view sees all sixteen cards and both skill trees" <|
            \_ ->
                views
                    |> List.filterMap
                        (\u ->
                            case Adapter.toPlayerView "p1" [] u.scene of
                                Just (ShopView s) ->
                                    Just s

                                _ ->
                                    Nothing
                        )
                    |> List.all (\s -> List.length s.availableCards == 16 && s.yourSkillTree.highCard >= 1 && s.opponentSkillTree.pair >= 1)
                    |> Expect.equal True
        , test "a hands_resolved event yields an animation with both breakdowns" <|
            \_ ->
                fixture.steps
                    |> List.filterMap (\step -> Dict.get "p1" step.updates)
                    |> List.filter (\u -> List.any isResolved u.events)
                    |> List.all
                        (\u ->
                            case Adapter.animationFromEvents "p1" u.events of
                                Just a ->
                                    a.yourHand /= [] && a.opponentHand /= [] && a.yourScore >= 0

                                Nothing ->
                                    False
                        )
                    |> Expect.equal True
        , test "rematch readiness is reflected in the game-over view" <|
            \_ ->
                views
                    |> List.filter (\u -> u.scene.phase == "game_over")
                    |> List.all
                        (\u ->
                            case Adapter.toPlayerView "p1" [ "p2" ] u.scene of
                                Just (GameOverView g) ->
                                    g.opponentReady && not g.yourReady

                                _ ->
                                    False
                        )
                    |> Expect.equal True
        ]


isResolved : Event -> Bool
isResolved event =
    case event of
        Custom "hands_resolved" _ ->
            True

        _ ->
            False
