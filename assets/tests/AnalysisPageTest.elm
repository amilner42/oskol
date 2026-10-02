module AnalysisPageTest exposing (suite)

{-| The analysis board's editor (`/analysis`, `Page.Analysis`): the
brushes and what a press does with them, a right click and a long press,
the sixteenth checker, the quick starts, the position id following every
change, the doors in (`?xgid=`, `?p=`), the line under the strip, and the
settings that can only be set where they mean something (Crawford, the
cube's owner).
-}

import Api
import Expect
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)
import Games.Backgammon.View as Board
import Games.Backgammon.Xgid as Xgid
import Html.Attributes
import Json.Decode as D
import Page.Analysis as Analysis exposing (Brush(..), Button(..), Msg(..), Target(..))
import PuzzleApiFixtures
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, text)


suite : Test
suite =
    describe "the analysis board"
        [ painting
        , pointers
        , quickStarts
        , theId
        , doors
        , theLine
        , settings
        ]


page : Analysis.Model
page =
    Analysis.init Session.empty { xgid = Nothing, puzzle = Nothing } |> Tuple.first


send : Msg -> Analysis.Model -> Analysis.Model
send msg model =
    Analysis.update msg model |> Tuple.first


sendAll : List Msg -> Analysis.Model -> Analysis.Model
sendAll msgs model =
    List.foldl send model msgs


cleared : Analysis.Model
cleared =
    send PressedClear page


at : Int -> Setup -> Int
at p setup =
    setup.points |> List.drop (p - 1) |> List.head |> Maybe.withDefault 99


painting : Test
painting =
    describe "a press on the board"
        [ test "a tap adds one checker of the brush's colour" <|
            \_ ->
                cleared
                    |> sendAll [ Pressed Primary (Point 6), Pressed Primary (Point 6) ]
                    |> .setup
                    |> at 6
                    |> Expect.equal 2
        , test "the black brush adds Black" <|
            \_ ->
                cleared
                    |> sendAll [ PickedBrush (Paint Black), Pressed Primary (Point 19) ]
                    |> .setup
                    |> at 19
                    |> Expect.equal -1
        , test "a tap on the other colour takes one of those off: a stack is painted over" <|
            \_ ->
                cleared
                    |> sendAll (List.repeat 3 (Pressed Secondary (Point 12)))
                    |> (\m ->
                            List.foldl
                                (\_ ( model, seen ) ->
                                    let
                                        next =
                                            send (Pressed Primary (Point 12)) model
                                    in
                                    ( next, seen ++ [ at 12 next.setup ] )
                                )
                                ( m, [ at 12 m.setup ] )
                                (List.range 1 5)
                       )
                    |> Tuple.second
                    |> Expect.equal [ -3, -2, -1, 0, 1, 2 ]
        , test "a right click (or a long press) is the other colour's brush" <|
            \_ ->
                Expect.all
                    [ \_ -> Analysis.paint (Paint White) Secondary (Point 5) Setup.empty |> Result.map (at 5) |> Expect.equal (Ok -1)
                    , \_ -> Analysis.paint (Paint Black) Secondary (Point 5) Setup.empty |> Result.map (at 5) |> Expect.equal (Ok 1)
                    ]
                    ()
        , test "the x takes one off whatever is there, with either button" <|
            \_ ->
                Expect.all
                    [ \_ -> Analysis.paint Erase Primary (Point 6) Setup.opening |> Result.map (at 6) |> Expect.equal (Ok 4)
                    , \_ -> Analysis.paint Erase Secondary (Point 12) Setup.opening |> Result.map (at 12) |> Expect.equal (Ok -4)
                    , \_ -> Analysis.paint Erase Primary (Point 3) Setup.opening |> Result.map (at 3) |> Expect.equal (Ok 0)
                    ]
                    ()
        , test "the bar's halves take the same taps" <|
            \_ ->
                cleared
                    |> sendAll [ Pressed Primary (Bar White), Pressed Primary (Bar White), Pressed Secondary (Bar Black), Pressed Primary (Bar Black) ]
                    |> .setup
                    |> (\s -> ( s.whiteBar, s.blackBar ))
                    |> Expect.equal ( 2, 0 )
        , test "a sixteenth checker is refused, and that colour's tray flashes" <|
            \_ ->
                page
                    |> send (Pressed Primary (Point 10))
                    |> Expect.all
                        [ .setup >> Expect.equal Setup.opening
                        , .refused >> Expect.equal (Just ( White, 1 ))
                        , Analysis.view >> Query.fromHtml >> Query.has [ class "an-flash-white-1" ]
                        , send (Pressed Secondary (Bar Black)) >> .refused >> Expect.equal (Just ( Black, 2 ))
                        , send (Pressed Secondary (Bar Black)) >> Analysis.view >> Query.fromHtml >> Query.has [ class "an-flash-black-0" ]
                        ]
        , test "the brushes: White to start, the one picked in ink" <|
            \_ ->
                send (PickedBrush Erase) page
                    |> Analysis.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "an-brush-remove" ] >> Query.has [ class "is-on" ]
                        , Query.find [ id "an-brush-white" ] >> Query.hasNot [ class "is-on" ]
                        , \_ -> page.brush |> Expect.equal (Paint White)
                        ]
        ]


pointers : Test
pointers =
    describe "pointers on the board's places"
        [ test "every point and both halves of the bar are a place, by id" <|
            \_ ->
                Analysis.view page
                    |> Query.fromHtml
                    |> Expect.all
                        (List.map (\p -> Query.has [ id ("an-pt-" ++ String.fromInt p) ]) (List.range 1 24)
                            ++ [ Query.has [ id "an-bar-white" ], Query.has [ id "an-bar-black" ] ]
                        )
        , test "a mouse press acts as it lifts on the place it went down on" <|
            \_ ->
                cleared
                    |> sendAll [ Pointer "point:7" (Board.Down False 10 10), Pointer "point:7" Board.Up ]
                    |> .setup
                    |> at 7
                    |> Expect.equal 1
        , test "a press lifted somewhere else does nothing" <|
            \_ ->
                cleared
                    |> sendAll [ Pointer "point:7" (Board.Down False 10 10), Pointer "point:8" Board.Up ]
                    |> .setup
                    |> Expect.equal cleared.setup
        , test "a right click is the other brush, at once" <|
            \_ ->
                cleared
                    |> send (Pointer "point:7" Board.Context)
                    |> .setup
                    |> at 7
                    |> Expect.equal -1
        , test "a long press is the other brush, and lifting it after does nothing" <|
            \_ ->
                let
                    down =
                        send (Pointer "point:7" (Board.Down True 10 10)) cleared

                    seq =
                        down.presses
                in
                down
                    |> sendAll [ LongPressed seq, Pointer "point:7" Board.Up ]
                    |> .setup
                    |> at 7
                    |> Expect.equal -1
        , test "a phone's own right click for the same long press acts once" <|
            \_ ->
                let
                    down =
                        send (Pointer "point:7" (Board.Down True 10 10)) cleared
                in
                down
                    |> sendAll [ Pointer "point:7" Board.Context, LongPressed down.presses, Pointer "point:7" Board.Up ]
                    |> .setup
                    |> at 7
                    |> Expect.equal -1
        , test "a finger that slides is a scroll: nothing is placed" <|
            \_ ->
                let
                    down =
                        send (Pointer "point:7" (Board.Down True 10 10)) cleared
                in
                down
                    |> sendAll [ Pointer "point:7" (Board.Moved 10 40), LongPressed down.presses, Pointer "point:7" Board.Up ]
                    |> .setup
                    |> Expect.equal cleared.setup
        , test "a timer from an earlier press does nothing to this one" <|
            \_ ->
                let
                    first =
                        cleared |> sendAll [ Pointer "point:7" (Board.Down True 10 10), Pointer "point:7" Board.Up ]

                    second =
                        send (Pointer "point:8" (Board.Down True 10 10)) first
                in
                second
                    |> sendAll [ LongPressed first.presses, Pointer "point:8" Board.Up ]
                    |> .setup
                    |> (\s -> ( at 7 s, at 8 s ))
                    |> Expect.equal ( 1, 1 )
        ]


quickStarts : Test
quickStarts =
    describe "OPENING, CLEAR, FLIP"
        [ test "FLIP mirrors the position" <|
            \_ ->
                send PressedFlip page |> .setup |> Expect.equal (Setup.flip Setup.opening)
        , test "OPENING puts the checkers back where a game starts, and the cube in the middle" <|
            \_ ->
                page
                    |> sendAll [ PressedFlip, PressedClear, CycledCube, PressedOpening ]
                    |> .setup
                    |> Expect.all
                        [ .points >> Expect.equal Setup.opening.points
                        , .cubeValue >> Expect.equal 1
                        , .cubeOwner >> Expect.equal Nothing
                        , .toPlay >> Expect.equal Black
                        ]
        , test "CLEAR takes every checker off and keeps the rest" <|
            \_ ->
                page
                    |> sendAll [ PickedRoll ( 3, 1 ), Pressed Primary (Bar White), PressedClear ]
                    |> .setup
                    |> Expect.equal (withRoll Setup.empty)
        ]


withRoll : Setup -> Setup
withRoll setup =
    { setup | ask = Move (Just ( 3, 1 )) }


theId : Test
theId =
    describe "the position id"
        [ test "the field follows every change" <|
            \_ ->
                let
                    field model =
                        Analysis.view model
                            |> Query.fromHtml
                            |> Query.find [ id "an-xgid" ]
                            |> Query.has [ attribute (Html.Attributes.value (Xgid.encode model.setup)) ]

                    steps =
                        [ Pressed Primary (Point 4), PickedRoll ( 6, 5 ), CycledCube, PressedFlip, ToggledGame, SteppedScore White 1 ]
                in
                Expect.all
                    (List.indexedMap (\i _ -> \_ -> field (sendAll (List.take (i + 1) steps) page)) steps
                        ++ [ \_ -> field page ]
                    )
                    ()
        , test "the opening with no roll picked is XG's opening with 00" <|
            \_ ->
                Xgid.encode page.setup
                    |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10"
        , test "IMPORT reads an id onto the board" <|
            \_ ->
                page
                    |> sendAll [ OpenedImport, ImportInput "XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10", ImportSubmitted ]
                    |> Expect.all
                        [ .importOpen >> Expect.equal False
                        , .setup >> Ok >> Expect.equal (Xgid.decode "XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10")
                        ]
        , test "a bad id stays in the dialog and says so" <|
            \_ ->
                page
                    |> sendAll [ OpenedImport, ImportInput "hello", ImportSubmitted ]
                    |> Expect.all
                        [ .importOpen >> Expect.equal True
                        , .setup >> Expect.equal Setup.opening
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-import-error" ] >> Query.has [ text "That is not a position id" ]
                        ]
        , test "the import dialog and its button are where the page says" <|
            \_ ->
                send OpenedImport page
                    |> Analysis.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ id "an-import" ]
                        , Query.find [ id "an-import-go" ] >> Query.has [ text "IMPORT" ]
                        ]
        ]


doors : Test
doors =
    describe "the doors in"
        [ test "/analysis is the opening, White to play, no roll picked" <|
            \_ -> page.setup |> Expect.equal Setup.opening
        , test "?xgid= opens on that position, Black to play and all" <|
            \_ ->
                let
                    raw =
                        "XGID=-b----E-C---eE---c-e----B-:0:0:-1:52:0:0:1:0:10"
                in
                Analysis.init Session.empty { xgid = Just raw, puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ .setup >> Ok >> Expect.equal (Xgid.decode raw)
                        , .setup >> .toPlay >> Expect.equal Black
                        , .setup >> Xgid.encode >> Expect.equal raw
                        ]
        , test "?xgid= that is not one opens the opening and says so" <|
            \_ ->
                Analysis.init Session.empty { xgid = Just "nope", puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ .setup >> Expect.equal Setup.opening
                        , Analysis.line >> Expect.equal (Just "That is not a position id")
                        ]
        , describe "?p= opens a puzzle as its page shows it"
            (List.map
                (\( name, body ) ->
                    test name <|
                        \_ ->
                            case D.decodeString Puzzle.decoder body of
                                Ok puzzle ->
                                    Analysis.init Session.empty { xgid = Nothing, puzzle = Just puzzle.id }
                                        |> Tuple.first
                                        |> Expect.all
                                            [ Analysis.line >> Expect.equal (Just "Opening the puzzle…")
                                            , Analysis.analyzable >> Expect.equal False
                                            , send (GotPuzzle (Ok puzzle))
                                                >> Expect.all
                                                    [ .setup >> Expect.equal (Setup.fromQuestion puzzle.kind puzzle.question)
                                                    , Analysis.line >> Expect.equal Nothing
                                                    , Analysis.analyzable >> Expect.equal True
                                                    ]
                                            ]

                                Err e ->
                                    Expect.fail (D.errorToString e)
                )
                PuzzleApiFixtures.all
            )
        , test "a puzzle that is not there opens the opening and says so, until the first edit" <|
            \_ ->
                Analysis.init Session.empty { xgid = Nothing, puzzle = Just "nope0000" }
                    |> Tuple.first
                    |> send (GotPuzzle (Err (Api.ApiError { code = "not_found", message = "Not found" })))
                    |> Expect.all
                        [ .setup >> Expect.equal Setup.opening
                        , Analysis.line >> Expect.equal (Just Analysis.puzzleGone)
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-check" ] >> Query.has [ text "That puzzle is gone." ]
                        , send (PickedRoll ( 4, 2 )) >> Analysis.line >> Expect.equal Nothing
                        ]
        ]


theLine : Test
theLine =
    describe "the line under the strip, and ANALYZE"
        [ test "the opening asks for a roll, and ANALYZE waits for one" <|
            \_ ->
                Analysis.view page
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "an-check" ] >> Query.has [ text "Pick a roll" ]
                        , Query.find [ id "an-analyze" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        ]
        , test "a roll picked: nothing to say, and ANALYZE is on" <|
            \_ ->
                send (PickedRoll ( 1, 3 )) page
                    |> Expect.all
                        [ .setup >> .ask >> Expect.equal (Move (Just ( 3, 1 )))
                        , Analysis.line >> Expect.equal Nothing
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-analyze" ] >> Query.has [ attribute (Html.Attributes.disabled False) ]
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-analyze" ] >> Event.simulate Event.click >> Event.expect PressedAnalyze
                        ]
        , test "each sentence is the setup's own" <|
            \_ ->
                Expect.all
                    [ \_ -> send PressedClear page |> Analysis.line |> Expect.equal (Just (Setup.noneMessage White))
                    , \_ -> sendAll (PressedClear :: List.repeat 15 (Pressed Primary (Point 6))) page |> Analysis.line |> Expect.equal (Just (Setup.noneMessage Black))
                    , \_ -> sendAll [ CycledCube, CycledOwner, PickedDouble ] page |> Analysis.line |> Expect.equal (Just (Setup.cubeOwnedMessage Black))
                    , \_ -> sendAll [ CycledCube, PickedTake ] page |> Analysis.line |> Expect.equal (Just (Setup.cubeOwnedMessage White))
                    , \_ -> sendAll [ PickedDouble ] page |> Analysis.line |> Expect.equal Nothing
                    ]
                    ()
        , test "the line keeps its place whether or not it says anything" <|
            \_ ->
                send (PickedRoll ( 3, 1 )) page
                    |> Analysis.view
                    |> Query.fromHtml
                    |> Query.has [ id "an-check" ]
        , test "the answer's place is on the page from the start" <|
            \_ -> Analysis.view page |> Query.fromHtml |> Query.has [ id "an-panel" ]
        ]


settings : Test
settings =
    describe "the settings strip"
        [ test "ROLL opens the 21 rolls, and a roll picked closes it" <|
            \_ ->
                send OpenedRolls page
                    |> Expect.all
                        [ Analysis.view >> Query.fromHtml >> Query.find [ id "an-roll-sheet" ] >> Query.findAll [ class "an-roll" ] >> Query.count (Expect.equal 21)
                        , send (PickedRoll ( 6, 6 )) >> .rolling >> Expect.equal False
                        , send (PickedRoll ( 6, 6 )) >> .setup >> .ask >> Expect.equal (Move (Just ( 6, 6 )))
                        ]
        , test "back to ROLL after DOUBLE? remembers the roll" <|
            \_ ->
                page
                    |> sendAll [ PickedRoll ( 5, 2 ), PickedDouble, OpenedRolls, ClosedRolls ]
                    |> .setup
                    |> .ask
                    |> Expect.equal (Move (Just ( 5, 2 )))
        , test "the cube's owner is the middle at 1, and cannot be anything else" <|
            \_ ->
                page
                    |> send CycledOwner
                    |> Expect.all
                        [ .setup >> .cubeOwner >> Expect.equal Nothing
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-cube-owner" ] >> Query.has [ text "CENTER", attribute (Html.Attributes.disabled True) ]
                        ]
        , test "a cube turned off 1 belongs to whoever is acting, and back at 1 it is in the middle again" <|
            \_ ->
                Expect.all
                    [ \_ -> send CycledCube page |> .setup |> (\s -> ( s.cubeValue, s.cubeOwner )) |> Expect.equal ( 2, Just White )
                    , \_ -> sendAll [ PickedTake, CycledCube ] page |> .setup |> .cubeOwner |> Expect.equal (Just Black)
                    , \_ -> sendAll [ CycledCube, CycledOwner ] page |> .setup |> .cubeOwner |> Expect.equal (Just Black)
                    , \_ -> sendAll (List.repeat 6 CycledCube) page |> .setup |> (\s -> ( s.cubeValue, s.cubeOwner )) |> Expect.equal ( 64, Just White )
                    , \_ -> sendAll (List.repeat 7 CycledCube) page |> .setup |> (\s -> ( s.cubeValue, s.cubeOwner )) |> Expect.equal ( 1, Nothing )
                    ]
                    ()
        , test "MATCH TO, its length and the scores, inside their bounds" <|
            \_ ->
                Expect.all
                    [ \_ -> send ToggledGame page |> .setup |> .match |> Expect.equal (Just Analysis.defaultMatch)
                    , \_ -> sendAll [ ToggledGame, ToggledGame ] page |> .setup |> .match |> Expect.equal Nothing
                    , \_ -> sendAll (ToggledGame :: List.repeat 30 (SteppedLength 1)) page |> .setup |> .match |> Maybe.map .length |> Expect.equal (Just 25)
                    , \_ -> sendAll (ToggledGame :: List.repeat 30 (SteppedLength -1)) page |> .setup |> .match |> Maybe.map .length |> Expect.equal (Just 1)
                    , \_ -> sendAll (ToggledGame :: List.repeat 10 (SteppedScore Black 1)) page |> .setup |> .match |> Maybe.map .black |> Expect.equal (Just 6)
                    , \_ -> sendAll ([ ToggledGame ] ++ List.repeat 6 (SteppedScore Black 1) ++ [ SteppedLength -1, SteppedLength -1 ]) page |> .setup |> .match |> Maybe.map .black |> Expect.equal (Just 4)
                    , \_ -> sendAll [ ToggledGame, SteppedScore White 1, ToggledGame, ToggledGame ] page |> .setup |> .match |> Maybe.map .white |> Expect.equal (Just 1)
                    ]
                    ()
        , test "CRAWFORD is off and disabled while nobody is one away" <|
            \_ ->
                page
                    |> sendAll [ ToggledGame, ToggledCrawford ]
                    |> Expect.all
                        [ .setup >> .match >> Maybe.map .crawford >> Expect.equal (Just False)
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-crawford" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        ]
        , test "one away, CRAWFORD can be turned on; off one away again, it goes off" <|
            \_ ->
                let
                    oneAway =
                        sendAll (ToggledGame :: List.repeat 6 (SteppedScore White 1)) page
                in
                Expect.all
                    [ Analysis.view >> Query.fromHtml >> Query.find [ id "an-crawford" ] >> Query.has [ attribute (Html.Attributes.disabled False) ]
                    , send ToggledCrawford >> .setup >> .match >> Maybe.map .crawford >> Expect.equal (Just True)
                    , sendAll [ ToggledCrawford, SteppedScore White -1 ] >> .setup >> .match >> Maybe.map .crawford >> Expect.equal (Just False)
                    , sendAll [ ToggledCrawford, SteppedLength 1 ] >> .setup >> .match >> Maybe.map .crawford >> Expect.equal (Just False)
                    ]
                    oneAway
        , test "unlimited: the match's controls stay in place, disabled" <|
            \_ ->
                Analysis.view page
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "an-game" ] >> Query.has [ text "UNLIMITED" ]
                        , Query.find [ id "an-length-plus" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        , Query.find [ id "an-score-white-plus" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        , Query.find [ id "an-crawford" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        ]
        , test "TO PLAY says who is asked" <|
            \_ ->
                send (PickedTurn Black) page
                    |> Expect.all
                        [ .setup >> .toPlay >> Expect.equal Black
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-turn-black" ] >> Query.has [ class "is-on" ]
                        ]
        ]
