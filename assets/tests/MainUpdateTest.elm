module MainUpdateTest exposing (suite)

{-| The app's update loop fed with real payloads: replaying a fixture through
`applyPayload` must keep the latest payload and legal actions, and the
channel messages must land where they should.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Main exposing (ConnectionStatus(..), Model, Msg(..))
import Protocol exposing (GamePayload, ServerMessage(..), Update)
import Test exposing (Test, describe, test)


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
        (List.map replay FixtureLoader.all ++ [ channelMessages ])


replay : Fixture -> Test
replay fixture =
    test (fixture.name ++ " replays and always shows the latest payload") <|
        \_ ->
            let
                updates =
                    (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

                final =
                    List.foldl (\u m -> feed fixture m u) (start fixture) updates

                last =
                    List.reverse updates |> List.head
            in
            Expect.all
                [ \m -> Expect.equal (Maybe.map .legal last) (Just m.legal)
                , \m -> Expect.equal (Maybe.map .scene last) (Maybe.map (\p -> p.update.scene) m.payload)
                , \m -> Expect.equal (Just "p1") m.playerId
                , \m -> Expect.equal Connected m.connectionStatus
                ]
                final


channelMessages : Test
channelMessages =
    test "errors and connection status are kept, a lobby message only marks the connection live" <|
        \_ ->
            let
                model =
                    Main.init { gameId = "g", gameSlug = "backgammon", playerId = Just "p1" } |> Tuple.first

                withError =
                    Main.update (ServerMessageReceived (ErrorMessage "Not your turn")) model |> Tuple.first

                dropped =
                    Main.update (ServerMessageReceived (StatusMessage "disconnected")) withError |> Tuple.first

                lobby =
                    Main.update (ServerMessageReceived LobbyMessage) dropped |> Tuple.first
            in
            Expect.all
                [ \_ -> Expect.equal (Just "Not your turn") withError.error
                , \_ -> Expect.equal Disconnected dropped.connectionStatus
                , \_ -> Expect.equal Connected lobby.connectionStatus
                , \_ -> Expect.equal Nothing lobby.payload
                ]
                ()
