module PlayUpdateTest exposing (suite)

{-| The app's update loop fed with real payloads: replaying a fixture through
`applyPayload` must keep the latest payload and legal actions, and the
channel messages must land where they should.
-}

import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Page.Play as Play exposing (ConnectionStatus(..), Model, Msg(..))
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
    Play.init
        { origin = "http://localhost:4400"
        , slug = fixture.game
        , gameId = "fixture"
        , seatToken = Just "tok"
        }
        |> Tuple.first


feed : Fixture -> Model -> Update -> Model
feed fixture model update =
    Play.applyPayload (payload fixture "p1" update) model |> first3


first3 : ( a, b, c ) -> a
first3 ( a, _, _ ) =
    a


suite : Test
suite =
    describe "Page.Play.update with fixture payloads"
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
                    Play.init
                        { origin = "http://localhost:4400"
                        , slug = "backgammon"
                        , gameId = "g"
                        , seatToken = Just "tok"
                        }
                        |> Tuple.first

                withError =
                    Play.update (ServerMessageReceived (ErrorMessage "Not your turn")) model |> first3

                dropped =
                    Play.update (ServerMessageReceived (StatusMessage "disconnected")) withError |> first3

                lobby =
                    Play.update (ServerMessageReceived (LobbyMessage waitingRoom)) dropped |> first3
            in
            Expect.all
                [ \_ -> Expect.equal (Just "Not your turn") withError.error
                , \_ -> Expect.equal Disconnected dropped.connectionStatus
                , \_ -> Expect.equal Connected lobby.connectionStatus
                , \_ -> Expect.equal Nothing lobby.payload
                , \_ -> Expect.equal (Just "p1") lobby.playerId
                , \_ -> Expect.equal (Just waitingRoom) lobby.lobby
                ]
                ()


{-| A room with a seat taken and nobody in the other one.
-}
waitingRoom : Protocol.Lobby
waitingRoom =
    { game = "backgammon"
    , gameId = "g"
    , playerId = Just "p1"
    , connections = [ { id = "p1", name = "Alice", connected = True } ]
    , summary = Just "Single game"
    , status = "waiting_for_players"
    }
