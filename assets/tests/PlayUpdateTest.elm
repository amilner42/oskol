module PlayUpdateTest exposing (suite)

{-| The app's update loop fed with real payloads: replaying a fixture through
`applyPayload` must keep the latest payload and legal actions, and the
channel messages must land where they should.
-}

import Api
import Dict
import Expect
import FixtureLoader exposing (Fixture)
import Games.Backgammon.View as Backgammon
import Page.Play as Play exposing (ConnectionStatus(..), Model, Msg(..), Out(..))
import Protocol exposing (GamePayload, ServerMessage(..), Update)
import Session exposing (Session)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (text)


testSession : Session
testSession =
    { csrf = "tok", guestName = Nothing, prefs = Dict.empty, user = Nothing }


payload : Fixture -> String -> Update -> GamePayload
payload fixture playerId update =
    { game = fixture.game
    , gameId = "fixture"
    , playerId = playerId
    , players = List.map (\( id, name ) -> { id = id, name = name, connected = True, account = False }) fixture.seats
    , rematchReady = []
    , rematchGameId = Nothing
    , update = update
    }


start : Fixture -> Model
start fixture =
    Play.init testSession
        { origin = "http://localhost:4400"
        , slug = fixture.game
        , gameId = "fixture"
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
        (List.map replay FixtureLoader.all
            ++ [ channelMessages, tabTitle, seatNames, prefsRace, ratingsWatch, mistakesOnCards, refusedAtTheDoor, refusedMidGame ]
        )


{-| A browser the room will not have holds no seat there: the URL says
nothing about who anyone is, so the answer comes from the channel, and the
only place that says whether there is a seat to take is the invite link.
-}
refusedAtTheDoor : Test
refusedAtTheDoor =
    test "a room that refuses an empty table sends the browser to the invite" <|
        \_ ->
            Play.init testSession
                { origin = "http://localhost:4400", slug = "backgammon", gameId = "AB12CD" }
                |> Tuple.first
                |> Play.update (ServerMessageReceived (ErrorMessage "unauthorized"))
                |> (\( model, _, out ) -> ( out, model.error ))
                |> Expect.equal ( Play.Navigate "/backgammon?game=AB12CD", Nothing )


{-| Once the table is up it is the player's own game: a refusal then (their
seat opened somewhere else) is a message to read, not a trip anywhere.
-}
refusedMidGame : Test
refusedMidGame =
    test "a refusal at a table already showing is read where it is" <|
        \_ ->
            let
                seated =
                    Play.init testSession
                        { origin = "http://localhost:4400", slug = "backgammon", gameId = "AB12CD" }
                        |> Tuple.first
                        |> Play.update (ServerMessageReceived (LobbyMessage waitingRoom))
                        |> first3
            in
            seated
                |> Play.update (ServerMessageReceived (ErrorMessage "unauthorized"))
                |> (\( model, _, out ) -> ( out, model.error ))
                |> Expect.equal ( Play.NoOut, Just "unauthorized" )


{-| A seat's name is the room's to give: an account that signed in or
renamed itself after the game began is named by its account, while the
scene still carries the name typed at the door. So the table reads the
payload's seat list, and the fixture's own scene name must not show.
-}
seatNames : Test
seatNames =
    test "the table calls a seat what the room calls it, not what the game started with" <|
        \_ ->
            case FixtureLoader.byGame "backgammon" |> List.head of
                Just fixture ->
                    case Dict.get "p1" fixture.initial of
                        Just update ->
                            let
                                renamed =
                                    { fixture | seats = fixture.seats |> List.map (\( id, _ ) -> ( id, "SEAT-" ++ id )) }

                                model =
                                    Play.applyPayload (payload renamed "p1" update) (start fixture) |> first3

                                rendered =
                                    Play.view model |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.has [ text "SEAT-p1" ]
                                , \_ -> rendered |> Query.has [ text "SEAT-p2" ]
                                , \_ -> rendered |> Query.hasNot [ text "Alice" ]
                                , \_ -> rendered |> Query.hasNot [ text "Bob" ]
                                , \_ -> Play.title model |> Expect.equal "SEAT-p2 · Backgammon"
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no p1 update"

                Nothing ->
                    Expect.fail "no backgammon fixture"


{-| The tab names the opponent once the game is on.
-}
tabTitle : Test
tabTitle =
    test "the tab names the opponent once the game is on" <|
        \_ ->
            case FixtureLoader.byGame "backgammon" |> List.head of
                Just fixture ->
                    case Dict.get "p1" fixture.initial of
                        Just update ->
                            Expect.all
                                [ \_ -> Play.title (start fixture) |> Expect.equal "Backgammon"
                                , \_ -> Play.title (feed fixture (start fixture) update) |> Expect.equal "Bob · Backgammon"
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no p1 view in the fixture"

                Nothing ->
                    Expect.fail "no backgammon fixture"


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


{-| A pick made at the table outranks any answer still in flight: the GET
that left before the tap must not move the board back.
-}
prefsRace : Test
prefsRace =
    describe "display preferences"
        [ test "a board picked here survives a stale answer from the server" <|
            \_ ->
                let
                    picked =
                        Play.update
                            (BackgammonMsg (Backgammon.PickTheme "sand"))
                            (startAt "backgammon")
                            |> first3

                    stale =
                        Play.update (GotPrefs (Ok (Dict.fromList [ ( "backgammon_theme", "walnut" ) ]))) picked
                            |> first3
                in
                Expect.equal (Dict.get "backgammon_theme" stale.prefs) (Just "sand")
        , test "a board picked on another browser arrives when nothing was picked here" <|
            \_ ->
                let
                    answered =
                        Play.update (GotPrefs (Ok (Dict.fromList [ ( "backgammon_theme", "neon" ) ]))) (startAt "backgammon")
                            |> first3
                in
                Expect.equal (Dict.get "backgammon_theme" answered.prefs) (Just "neon")
        ]


{-| Waiting for a grade is a small state machine and it has been wrong
twice: it must not stop while the engine still owes the room an answer,
and it must not stop on a game whose review has not been opened yet.
-}
ratingsWatch : Test
ratingsWatch =
    let
        answer graded pending =
            { prs = Dict.empty, careers = Dict.empty, graded = graded, pending = pending, games = Dict.empty }

        got graded pending model =
            Play.update (GotRatings (Ok (answer graded pending))) model |> first3

        waiting =
            -- a page that has asked once and is still owed an answer
            got 0 True (startAt "backgammon")
    in
    describe "watching for a match PR"
        [ test "a page opened in the middle of an analysis starts watching" <|
            \_ ->
                got 2 True (startAt "backgammon")
                    |> .ratingsPolls
                    |> Expect.greaterThan 0
        , test "a page opened long after a match asks once and stops" <|
            \_ ->
                got 3 False (startAt "backgammon")
                    |> .ratingsPolls
                    |> Expect.equal 0
        , test "a grade landing does not stop a watch the engine is still owed" <|
            \_ ->
                got 3 True waiting
                    |> .ratingsPolls
                    |> Expect.greaterThan 0
        , test "nothing pending yet is not nothing coming: the watch keeps going" <|
            \_ ->
                -- the queue has not even opened a row for the game that
                -- just ended here
                got 0 False waiting
                    |> .ratingsPolls
                    |> Expect.greaterThan 0
        , test "the grade lands and nothing else is owed: the watch stops" <|
            \_ ->
                got 1 False waiting
                    |> .ratingsPolls
                    |> Expect.equal 0
        , test "a page that never asked does not start watching on its own" <|
            \_ ->
                got 0 False (startAt "backgammon")
                    |> .ratingsPolls
                    |> Expect.equal 0
        ]


{-| PRACTICE THIS GAME'S N MISTAKES is fed by one ask per graded game,
made for a seat and never for a spectator; the puzzles land a moment after
the grade, so an ask may be told to come back, and it does, bounded.
-}
mistakesOnCards : Test
mistakesOnCards =
    let
        graded numbers =
            { prs = Dict.empty, careers = Dict.empty, graded = List.length numbers, pending = False, games = Dict.fromList (List.map (\n -> ( n, [ ( "p1", 5.0 ) ] )) numbers) }

        entry id =
            { id = id, kind = "move", prompt = "White to play 6-4. What's your play?", due = False }

        answer ids =
            { puzzles = List.map entry ids, counts = Nothing, mistakes = Nothing }

        stillWriting =
            Api.ApiError { code = "puzzles_pending", message = "This game's mistakes are still being written. Try again in a moment." }

        refused =
            Api.ApiError { code = "not_found", message = "No puzzles for that game" }

        firstUpdate fixture =
            Dict.get "p1" fixture.initial

        seatedAt fixture =
            -- the first payload says who this browser is: p1, a seat
            case firstUpdate fixture of
                Just u ->
                    feed fixture (start fixture) u

                Nothing ->
                    start fixture

        watching fixture =
            -- the spectator's payload: nobody the room seats
            case firstUpdate fixture of
                Just u ->
                    Play.applyPayload (payload fixture "watcher" u) (start fixture) |> first3

                Nothing ->
                    start fixture

        got msg model =
            Play.update msg model |> first3

        outOf msg model =
            Play.update msg model |> (\( _, _, out ) -> out)
    in
    describe "the mistakes a result card offers to practice"
        (case FixtureLoader.byGame "backgammon" |> List.head of
            Just fixture ->
                [ test "a graded game is asked about once, for a seat" <|
                    \_ ->
                        seatedAt fixture
                            |> got (GotRatings (Ok (graded [ 1 ])))
                            |> Expect.all
                                [ \m -> Dict.toList m.mistakeAsks |> Expect.equal [ ( 1, 1 ) ]

                                -- the next answer from /ratings does not ask again while one is out
                                , \m -> got (GotRatings (Ok (graded [ 1 ]))) m |> .mistakeAsks |> Dict.toList |> Expect.equal [ ( 1, 1 ) ]
                                ]
                , test "the answer is kept by game, and PRACTICE runs exactly those ids" <|
                    \_ ->
                        seatedAt fixture
                            |> got (GotRatings (Ok (graded [ 1 ])))
                            |> got (GotMistakes 1 (Ok (answer [ "aaaaaaaa", "bbbbbbbb" ])))
                            |> Expect.all
                                [ \m -> Dict.get 1 m.mistakes |> Expect.equal (Just [ "aaaaaaaa", "bbbbbbbb" ])
                                , \m -> Dict.member 1 m.mistakeAsks |> Expect.equal False
                                , \m -> outOf (BackgammonMsg (Backgammon.PracticeGame 1)) m |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ])

                                -- a game not answered for starts nothing
                                , \m -> outOf (BackgammonMsg (Backgammon.PracticeGame 2)) m |> Expect.equal NoOut

                                -- and is not asked about again once answered
                                , \m -> got (GotRatings (Ok (graded [ 1, 2 ]))) m |> .mistakeAsks |> Dict.toList |> Expect.equal [ ( 2, 1 ) ]
                                ]
                , test "a spectator is never asked for: the answer would be a 404" <|
                    \_ ->
                        watching fixture
                            |> got (GotRatings (Ok (graded [ 1 ])))
                            |> .mistakeAsks
                            |> Dict.isEmpty
                            |> Expect.equal True
                , test "a grade that lands before the room has said who this browser is waits for the payload" <|
                    \_ ->
                        start fixture
                            |> got (GotRatings (Ok (graded [ 1 ])))
                            |> Expect.all
                                [ \m -> Dict.isEmpty m.mistakeAsks |> Expect.equal True
                                , \m ->
                                    (case firstUpdate fixture of
                                        Just u ->
                                            feed fixture m u

                                        Nothing ->
                                            m
                                    )
                                        |> .mistakeAsks
                                        |> Dict.toList
                                        |> Expect.equal [ ( 1, 1 ) ]
                                ]
                , test "puzzles still being written: the ask is kept and made again, and gives up after enough" <|
                    \_ ->
                        let
                            told =
                                seatedAt fixture
                                    |> got (GotRatings (Ok (graded [ 1 ])))
                                    |> got (GotMistakes 1 (Err stillWriting))
                        in
                        Expect.all
                            [ \m -> Dict.get 1 m.mistakeAsks |> Expect.equal (Just 1)
                            , \m -> got (AskMistakes 1) m |> .mistakeAsks |> Dict.get 1 |> Expect.equal (Just 2)
                            , \m ->
                                List.foldl (\_ acc -> got (AskMistakes 1) acc) m (List.repeat 30 ())
                                    |> .mistakeAsks
                                    |> Dict.member 1
                                    |> Expect.equal False
                            ]
                            told
                , test "any other refusal ends the asking: no button, and nothing hammered" <|
                    \_ ->
                        seatedAt fixture
                            |> got (GotRatings (Ok (graded [ 1 ])))
                            |> got (GotMistakes 1 (Err refused))
                            |> Expect.all
                                [ \m -> Dict.isEmpty m.mistakeAsks |> Expect.equal True
                                , \m -> Dict.isEmpty m.mistakes |> Expect.equal True
                                ]
                ]

            Nothing ->
                [ test "no backgammon fixture" <| \_ -> Expect.fail "no backgammon fixture" ]
        )


startAt : String -> Model
startAt slug =
    Play.init testSession
        { origin = "http://localhost:4400"
        , slug = slug
        , gameId = "g"
        }
        |> Tuple.first


channelMessages : Test
channelMessages =
    test "errors and connection status are kept, a lobby message only marks the connection live" <|
        \_ ->
            let
                model =
                    Play.init testSession
                        { origin = "http://localhost:4400"
                        , slug = "backgammon"
                        , gameId = "g"
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
    , connections = [ { id = "p1", name = "Alice", connected = True, account = False } ]
    , summary = Just "Single game"
    , status = "waiting_for_players"
    }
