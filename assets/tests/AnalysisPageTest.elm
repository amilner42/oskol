module AnalysisPageTest exposing (suite)

{-| The analysis board's editor (`/analysis`, `Page.Analysis`): the
brushes and what a press does with them, a right click and a long press,
the sixteenth checker, the quick starts, the position id following every
change, the doors in (`?xgid=`, `?p=`), the line under the strip, and the
settings that can only be set where they mean something (Crawford, the
cube's owner).
-}

import AnalysisFixtures
import Api
import Api.Analysis as AnalysisApi
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
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)
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
        , answering
        , placing
        ]


none : Analysis.Off
none =
    { white = 0, black = 0 }


page : Analysis.Model
page =
    Analysis.init Session.empty "http://oskol.test" { xgid = Nothing, puzzle = Nothing } |> Tuple.first


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
                    [ \_ -> Analysis.paint (Paint White) Secondary (Point 5) ( Setup.empty, none ) |> Result.map (Tuple.first >> at 5) |> Expect.equal (Ok -1)
                    , \_ -> Analysis.paint (Paint Black) Secondary (Point 5) ( Setup.empty, none ) |> Result.map (Tuple.first >> at 5) |> Expect.equal (Ok 1)
                    ]
                    ()
        , test "the x takes one off whatever is there, with either button" <|
            \_ ->
                Expect.all
                    [ \_ -> Analysis.paint Erase Primary (Point 6) ( Setup.opening, none ) |> Result.map (Tuple.first >> at 6) |> Expect.equal (Ok 4)
                    , \_ -> Analysis.paint Erase Secondary (Point 12) ( Setup.opening, none ) |> Result.map (Tuple.first >> at 12) |> Expect.equal (Ok -4)
                    , \_ -> Analysis.paint Erase Primary (Point 3) ( Setup.opening, none ) |> Result.map (Tuple.first >> at 3) |> Expect.equal (Ok 0)
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
        , test "a phone's late right click for a press it dropped (a scroll) does not paint" <|
            \_ ->
                cleared
                    |> sendAll [ Pointer "point:7" (Board.Down True 10 10), Pointer "point:7" Board.Cancelled, Pointer "point:7" Board.Context ]
                    |> .setup
                    |> Expect.equal cleared.setup
        , test "nor for one that slid away" <|
            \_ ->
                cleared
                    |> sendAll [ Pointer "point:7" (Board.Down True 10 10), Pointer "point:7" (Board.Moved 10 60), Pointer "point:7" Board.Context ]
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
                Analysis.init Session.empty "http://oskol.test" { xgid = Just raw, puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ .setup >> Ok >> Expect.equal (Xgid.decode raw)
                        , .setup >> .toPlay >> Expect.equal Black
                        , .setup >> Xgid.encode >> Expect.equal raw
                        ]
        , test "an id with Crawford and nobody one away comes in without it, by every door" <|
            \_ ->
                let
                    raw =
                        "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:2:2:1:7:10"

                    crawford =
                        .setup >> .match >> Maybe.map .crawford
                in
                Expect.all
                    [ \_ -> Analysis.init Session.empty "http://oskol.test" { xgid = Just raw, puzzle = Nothing } |> Tuple.first |> crawford |> Expect.equal (Just False)
                    , \_ -> page |> sendAll [ OpenedImport, ImportInput raw, ImportSubmitted ] |> crawford |> Expect.equal (Just False)
                    , \_ -> page |> sendAll [ OpenedImport, ImportInput raw, ImportSubmitted ] |> Analysis.line |> Expect.equal Nothing
                    , \_ -> page |> sendAll [ OpenedImport, ImportInput raw, ImportSubmitted, ToggledGame, ToggledGame ] |> crawford |> Expect.equal (Just False)
                    ]
                    ()
        , test "an id with an owner on a cube at 1 comes in centered" <|
            \_ ->
                Analysis.init Session.empty "http://oskol.test" { xgid = Just "XGID=-b----E-C---eE---c-e----B-:0:1:1:31:0:0:1:0:10", puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ .setup >> .cubeOwner >> Expect.equal Nothing
                        , Analysis.line >> Expect.equal Nothing
                        ]
        , test "?xgid= that is not one opens the opening and says so" <|
            \_ ->
                Analysis.init Session.empty "http://oskol.test" { xgid = Just "nope", puzzle = Nothing }
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
                                    Analysis.init Session.empty "http://oskol.test" { xgid = Nothing, puzzle = Just puzzle.id }
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
                Analysis.init Session.empty "http://oskol.test" { xgid = Nothing, puzzle = Just "nope0000" }
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
                    [ \_ -> send PressedClear page |> Analysis.line |> Expect.equal (Just "Place 15 more White and 15 more Black checkers")
                    , \_ -> sendAll (PressedClear :: List.repeat 15 (Pressed Primary (Point 6))) page |> Analysis.line |> Expect.equal (Just "Place 15 more Black checkers")
                    , \_ -> sendAll [ PickedRoll ( 3, 1 ), PickedBrush Erase, Pressed Primary (Point 6) ] page |> Analysis.line |> Expect.equal (Just "Place 1 more White checker")
                    , \_ -> sendAll [ PickedBrush Erase, Pressed Primary (Point 6) ] page |> Analysis.line |> Expect.equal (Just "Place 1 more White checker")
                    , \_ -> sendAll [ PickedBrush Erase, Pressed Primary (Point 6), PickedBrush (Paint White), Pressed Primary (Tray White) ] page |> Analysis.line |> Expect.equal (Just "Pick a roll")
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
                    , sendAll [ ToggledCrawford ] >> Analysis.view >> Query.fromHtml >> Query.find [ id "an-crawford" ] >> Query.has [ attribute (Html.Attributes.disabled False) ]
                    , sendAll [ ToggledCrawford, ToggledCrawford ] >> .setup >> .match >> Maybe.map .crawford >> Expect.equal (Just False)
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



-- THE ANSWER


{-| A server's answer, from `AnalysisFixtures` (the server's own bytes).
-}
answerNamed : String -> AnalysisApi.Status
answerNamed name =
    case
        AnalysisFixtures.all
            |> List.filter (\( n, _ ) -> n == name)
            |> List.head
            |> Maybe.map (\( _, body ) -> Api.parseBody AnalysisApi.statusDecoder body)
    of
        Just (Ok status) ->
            status

        _ ->
            AnalysisApi.Failed ("no fixture " ++ name)


done : String -> Result AnalysisApi.Refusal AnalysisApi.Status
done name =
    Ok (answerNamed name)


refusal : String -> String -> Maybe Int -> Result AnalysisApi.Refusal AnalysisApi.Status
refusal code message wait =
    Err { error = Api.ApiError { code = code, message = message }, retryAfter = wait }


{-| The opening with 6-4 to play, ANALYZE pressed: the first ask is out.
-}
asked : Analysis.Model
asked =
    sendAll [ PickedRoll ( 6, 4 ), PressedAnalyze ] page


{-| The answer, after a wait: pending, a tick, then done from the poll.
-}
answered : String -> Analysis.Model
answered name =
    asked
        |> sendAll
            [ GotAsk 1 (Ok (AnalysisApi.Pending "k1"))
            , Ticked 1
            , GotStatus 1 (done name)
            ]


panel : Analysis.Model -> Query.Single Msg
panel model =
    Analysis.view model |> Query.fromHtml |> Query.find [ id "an-panel" ]


answering : Test
answering =
    describe "ANALYZE and the answer"
        [ test "every answer the server renders decodes" <|
            \_ ->
                AnalysisFixtures.all
                    |> List.map (\( name, body ) -> ( name, Api.parseBody AnalysisApi.statusDecoder body |> Result.map (\_ -> ()) ))
                    |> List.filter (\( _, r ) -> r /= Ok ())
                    |> List.map Tuple.first
                    |> Expect.equal []
        , test "a refusal's wait is read off its envelope" <|
            \_ ->
                AnalysisApi.refusalOf """{"ok":false,"error":{"code":"engine_down","message":"The engine is asleep. Try again in a minute.","retry_after_s":42}}""" Api.NetworkError
                    |> .retryAfter
                    |> Expect.equal (Just 42)
        , test "the press: ANALYZE's slot is a plate counting seconds, and the poll waits for a key" <|
            \_ ->
                asked
                    |> Expect.all
                        [ Analysis.view >> Query.fromHtml >> Query.find [ id "an-asking" ] >> Query.has [ text "ASKING THE ENGINE… 0 s" ]
                        , Analysis.view >> Query.fromHtml >> Query.hasNot [ id "an-analyze" ]
                        , sendAll [ GotAsk 1 (Ok (AnalysisApi.Pending "k1")), Ticked 1, Ticked 1 ]
                            >> Analysis.view
                            >> Query.fromHtml
                            >> Query.find [ id "an-asking" ]
                            >> Query.has [ text "ASKING THE ENGINE… 2 s" ]
                        ]
        , test "pending, then done: the best play in words over the table" <|
            \_ ->
                answered "move"
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-candidates" ] >> Query.findAll [ class "rp-cand" ] >> Query.count (Expect.equal 3)
                        , Query.find [ id "an-candidates" ] >> Query.find [ attribute (Html.Attributes.attribute "data-rank" "1") ] >> Query.has [ text "play 1" ]
                        , Query.has [ text "The best play is play 1: 55.0% wins, 12.0% gammons, 10.0% gammons against." ]
                        , Query.find [ id "an-depth" ] >> Query.has [ text "4-ply · asked just now" ]
                        , Query.find [ id "an-open-puzzle" ] >> Query.has [ attribute (Html.Attributes.href "/puzzles/fixmove1"), attribute (Html.Attributes.target "_blank") ]
                        , Query.has [ id "an-share" ]
                        ]
        , test "a position analyzed before is answered at once, and says so" <|
            \_ ->
                asked
                    |> send (GotAsk 1 (done "move"))
                    |> Expect.all
                        [ panel >> Query.find [ id "an-depth" ] >> Query.has [ text "4-ply · already analyzed" ]
                        , Analysis.view >> Query.fromHtml >> Query.has [ id "an-analyze" ]
                        ]
        , test "the depth line without a depth" <|
            \_ ->
                asked
                    |> send (GotAsk 1 (done "move_no_levels"))
                    |> panel
                    |> Query.find [ id "an-depth" ]
                    |> Query.has [ text "Already analyzed" ]
        , test "a double: the sentence, the three equities with the pick, the chances" <|
            \_ ->
                sendAll [ PickedDouble, PressedAnalyze, GotAsk 1 (done "double") ] page
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-answer" ] >> Query.has [ attribute (Html.Attributes.attribute "data-kind" "double") ]
                        , Query.findAll [ class "rp-cube-eq" ] >> Query.count (Expect.equal 3)
                        , Query.findAll [ class "rp-cube-eq", class "is-pick" ] >> Query.count (Expect.equal 1)
                        , Query.has [ class "rp-cube-top" ]
                        , Query.hasNot [ id "an-candidates" ]
                        , Query.find [ id "an-depth" ] >> Query.has [ text "4-ply · already analyzed" ]
                        ]
        , test "a take: the taker's sentence" <|
            \_ ->
                sendAll [ PickedTake, PressedAnalyze, GotAsk 1 (done "take") ] page
                    |> panel
                    |> Query.has [ class "rp-cube-eqs" ]
        , test "a candidate goes on the board, and the dice take it back" <|
            \_ ->
                let
                    model =
                        answered "move"

                    showing =
                        send (Show (Just 2)) model
                in
                Expect.all
                    [ \_ -> Analysis.shownSetup showing |> .points |> Expect.notEqual model.setup.points
                    , \_ -> Analysis.view showing |> Query.fromHtml |> Query.find [ id "an-proposed" ] |> Query.has [ text "ENGINE'S #2" ]
                    , \_ -> Analysis.view showing |> Query.fromHtml |> Query.find [ id "an-dice-toggle" ] |> Event.simulate Event.click |> Event.expect (Show Nothing)
                    , \_ -> send (Show Nothing) showing |> Analysis.shownSetup |> Expect.equal model.setup
                    , \_ -> panel showing |> Query.find [ id "an-candidates" ] |> Query.find [ class "is-on" ] |> Query.has [ attribute (Html.Attributes.attribute "data-rank" "2") ]
                    , \_ -> panel model |> Query.find [ id "an-candidates" ] |> Query.find [ attribute (Html.Attributes.attribute "data-rank" "3") ] |> Event.simulate Event.click |> Event.expect (Show (Just 3))
                    , \_ -> Analysis.view model |> Query.fromHtml |> Query.hasNot [ id "an-dice-toggle" ]
                    ]
                    ()
        , test "a tap on the board while a candidate is shown takes it back and paints nothing" <|
            \_ ->
                answered "move"
                    |> sendAll [ Show (Just 2), Pressed Primary (Point 3) ]
                    |> Expect.all
                        [ .showing >> Expect.equal Nothing
                        , .setup >> at 3 >> Expect.equal 0
                        , .ask >> isAnswered >> Expect.equal True
                        ]
        , test "for Black to play, a candidate's board is turned back round" <|
            \_ ->
                let
                    black =
                        sendAll [ PickedRoll ( 6, 4 ), PickedTurn Black, PressedAnalyze, GotAsk 1 (done "move"), Show (Just 1) ] page

                    white =
                        send (Show (Just 1)) (answered "move")
                in
                Analysis.shownSetup black
                    |> .points
                    |> Expect.equal (Analysis.shownSetup white |> .points |> List.reverse |> List.map negate)
        , test "an edit after an answer clears it, and the panel keeps its place" <|
            \_ ->
                answered "move"
                    |> sendAll [ Show (Just 2), Show Nothing, PressedClear ]
                    |> Expect.all
                        [ .ask >> isAnswered >> Expect.equal False
                        , .showing >> Expect.equal Nothing
                        , panel >> Query.hasNot [ id "an-answer" ]
                        , panel >> Query.has [ class "an-panel-hint" ]
                        ]
        , test "a control that changes nothing leaves the answer up" <|
            \_ ->
                answered "move"
                    |> send (PickedTurn White)
                    |> .ask
                    |> isAnswered
                    |> Expect.equal True
        , test "an answer for an earlier press is dropped" <|
            \_ ->
                asked
                    |> sendAll [ PressedClear, PressedOpening, PickedRoll ( 6, 4 ), PressedAnalyze, GotAsk 1 (done "move") ]
                    |> .ask
                    |> isAnswered
                    |> Expect.equal False
        , test "a roll that plays nothing: the server's sentence, no TRY AGAIN" <|
            \_ ->
                asked
                    |> send (GotAsk 1 (refusal "dances" "6-4 cannot be played from here" Nothing))
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-refused-text" ] >> Query.has [ text "6-4 cannot be played from here" ]
                        , Query.hasNot [ id "an-retry" ]
                        ]
        , test "the engine asleep: its sentence, and TRY AGAIN once the wait has passed" <|
            \_ ->
                let
                    asleep =
                        send (GotAsk 1 (refusal "engine_down" "The engine is asleep. Try again in a minute." (Just 3))) asked

                    waited =
                        sendAll [ Ticked 1, Ticked 1, Ticked 1 ] asleep
                in
                Expect.all
                    [ \_ -> panel asleep |> Query.find [ id "an-refused-text" ] |> Query.has [ text "The engine is asleep. Try again in a minute." ]
                    , \_ -> panel asleep |> Query.find [ id "an-retry" ] |> Query.has [ text "TRY AGAIN · 3 s", attribute (Html.Attributes.disabled True) ]
                    , \_ -> panel waited |> Query.find [ id "an-retry" ] |> Query.has [ text "TRY AGAIN", attribute (Html.Attributes.disabled False) ]
                    , \_ -> panel waited |> Query.find [ id "an-retry" ] |> Event.simulate Event.click |> Event.expect PressedRetry
                    , \_ -> send PressedRetry waited |> .ask |> isAsking |> Expect.equal True
                    , \_ -> send PressedRetry asleep |> .ask |> isAsking |> Expect.equal False
                    ]
                    ()
        , test "over a budget: the server's sentence and its wait" <|
            \_ ->
                asked
                    |> send (GotAsk 1 (refusal "rate_limited" "Guests can analyze 10 positions an hour. Sign in for more, or try again in 14 minutes." (Just 840)))
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-refused-text" ] >> Query.has [ text "Guests can analyze 10 positions an hour. Sign in for more, or try again in 14 minutes." ]
                        , Query.find [ id "an-retry" ] >> Query.has [ text "TRY AGAIN · 14 min" ]
                        ]
        , test "a failed ask: the asker's sentence, and TRY AGAIN at once" <|
            \_ ->
                asked
                    |> sendAll [ GotAsk 1 (Ok (AnalysisApi.Pending "k1")), Ticked 1, GotStatus 1 (Ok (AnalysisApi.Failed "The engine could not read this position. Check the board and try another.")) ]
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-refused-text" ] >> Query.has [ text "The engine could not read this position. Check the board and try another." ]
                        , Query.find [ id "an-retry" ] >> Query.has [ attribute (Html.Attributes.disabled False) ]
                        ]
        , test "a key the server forgot is asked again" <|
            \_ ->
                asked
                    |> sendAll [ GotAsk 1 (Ok (AnalysisApi.Pending "k1")), Ticked 1, GotStatus 1 (refusal "not_found" "That puzzle is gone." Nothing) ]
                    |> .ask
                    |> isAsking
                    |> Expect.equal True
        , test "a poll lost on the way is asked again at the next tick" <|
            \_ ->
                asked
                    |> sendAll [ GotAsk 1 (Ok (AnalysisApi.Pending "k1")), Ticked 1, GotStatus 1 (Err { error = Api.NetworkError, retryAfter = Nothing }) ]
                    |> .ask
                    |> isAsking
                    |> Expect.equal True
        , test "after the poll limit the page stops asking and says so" <|
            \_ ->
                asked
                    |> send (GotAsk 1 (Ok (AnalysisApi.Pending "k1")))
                    |> sendAll (List.repeat Analysis.pollLimit (Ticked 1))
                    |> panel
                    |> Expect.all
                        [ Query.find [ id "an-refused-text" ] >> Query.has [ text Analysis.tooLongMessage ]
                        , Query.find [ id "an-retry" ] >> Query.has [ attribute (Html.Attributes.disabled False) ]
                        ]
        , test "SHARE's answer is the fixed line under the answer" <|
            \_ ->
                answered "move"
                    |> send (ShareReported "copied")
                    |> panel
                    |> Query.find [ id "an-share-note" ]
                    |> Query.has [ text "Link copied" ]
        , test "nothing on the page asks anyone to sign in" <|
            \_ ->
                answered "move"
                    |> Analysis.view
                    |> Query.fromHtml
                    |> Query.hasNot [ text "Sign in" ]
        ]


isAnswered : Analysis.Asking -> Bool
isAnswered ask =
    case ask of
        Analysis.Answered _ ->
            True

        _ ->
            False


isAsking : Analysis.Asking -> Bool
isAsking ask =
    case ask of
        Analysis.Asking _ ->
            True

        _ ->
            False


placing : Test
placing =
    describe "every checker placed, borne off, or not placed yet"
        [ test "a checker taken off the board is not placed, not borne off" <|
            \_ ->
                sendAll [ PickedRoll ( 3, 1 ), PickedBrush Erase, Pressed Primary (Point 6) ] page
                    |> Expect.all
                        [ .off >> Expect.equal none
                        , \m -> Analysis.toPlace White ( m.setup, m.off ) |> Expect.equal 1
                        , Analysis.analyzable >> Expect.equal False
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-left-white" ] >> Query.has [ text "1" ]
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-off-white" ] >> Query.has [ text "0 off" ]
                        ]
        , test "a tap on a tray bears one of those not placed off" <|
            \_ ->
                sendAll [ PickedRoll ( 3, 1 ), PickedBrush Erase, Pressed Primary (Point 6), PickedBrush (Paint Black), Pressed Primary (Tray White) ] page
                    |> Expect.all
                        [ .off >> Expect.equal { white = 1, black = 0 }
                        , Analysis.line >> Expect.equal Nothing
                        , Analysis.analyzable >> Expect.equal True
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-off-white" ] >> Query.has [ text "1 off" ]
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-left-white" ] >> Query.has [ class "is-none" ]
                        ]
        , test "the other button, or the x, takes one back from the tray to be placed" <|
            \_ ->
                let
                    borne =
                        sendAll [ PickedBrush Erase, Pressed Primary (Point 6), PickedBrush (Paint White), Pressed Primary (Tray White) ] page
                in
                Expect.all
                    [ send (Pressed Secondary (Tray White)) >> .off >> Expect.equal none
                    , sendAll [ PickedBrush Erase, Pressed Primary (Tray White) ] >> .off >> Expect.equal none
                    , send (Pressed Secondary (Tray White)) >> Analysis.line >> Expect.equal (Just "Place 1 more White checker")
                    ]
                    borne
        , test "a tray refuses what it cannot do, and flashes" <|
            \_ ->
                Expect.all
                    [ \_ -> send (Pressed Primary (Tray White)) page |> Expect.all [ .off >> Expect.equal none, .refused >> Expect.equal (Just ( White, 1 )) ]
                    , \_ -> send (Pressed Secondary (Tray Black)) page |> .refused |> Expect.equal (Just ( Black, 1 ))
                    ]
                    ()
        , test "with none left to place, a checker on the board comes back from the tray" <|
            \_ ->
                Analysis.init Session.empty "http://oskol.test" { xgid = Just "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10", puzzle = Nothing }
                    |> Tuple.first
                    |> sendAll [ PickedBrush Erase, Pressed Primary (Point 6), PickedBrush (Paint White), Pressed Primary (Tray White), Pressed Primary (Point 4) ]
                    |> Expect.all
                        [ .off >> Expect.equal none
                        , .setup >> at 4 >> Expect.equal 1
                        , Analysis.line >> Expect.equal Nothing
                        ]
        , test "CLEAR: every checker not placed, nothing borne off" <|
            \_ ->
                sendAll [ PickedBrush Erase, Pressed Primary (Point 6), Pressed Primary (Tray White), PressedClear ] page
                    |> Expect.all
                        [ .off >> Expect.equal none
                        , \m -> ( Analysis.toPlace White ( m.setup, m.off ), Analysis.toPlace Black ( m.setup, m.off ) ) |> Expect.equal ( 15, 15 )
                        ]
        , test "a door in has nothing not placed: what is not on the board is borne off" <|
            \_ ->
                Analysis.init Session.empty "http://oskol.test" { xgid = Just "XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10", puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ \m -> m.off |> Expect.equal (Analysis.offFrom m.setup)
                        , Analysis.line >> Expect.equal Nothing
                        , Analysis.analyzable >> Expect.equal True
                        ]
        , test "FLIP swaps the trays" <|
            \_ ->
                sendAll [ PickedBrush Erase, Pressed Primary (Point 6), PickedBrush (Paint White), Pressed Primary (Tray White), PressedFlip ] page
                    |> .off
                    |> Expect.equal { white = 0, black = 1 }
        , fuzz edits "ANALYZE is on exactly when every checker is placed or off, a move has its roll, and the setup checks" <|
            \msgs ->
                let
                    m =
                        sendAll msgs page

                    complete =
                        Analysis.toPlace White ( m.setup, m.off ) == 0 && Analysis.toPlace Black ( m.setup, m.off ) == 0

                    rolled =
                        m.setup.ask /= Move Nothing
                in
                Expect.all
                    [ Analysis.analyzable >> Expect.equal (complete && rolled && Setup.check m.setup == Nothing)
                    , \_ -> List.all (\c -> Analysis.toPlace c ( m.setup, m.off ) >= 0) [ White, Black ] |> Expect.equal True
                    , \_ ->
                        if complete then
                            m.off |> Expect.equal (Analysis.offFrom m.setup)

                        else
                            Expect.pass
                    ]
                    m
        ]


{-| Any run of what the page's controls send, from the opening.
-}
edits : Fuzzer (List Msg)
edits =
    let
        targets =
            List.map Point (List.range 1 24) ++ [ Bar White, Bar Black, Tray White, Tray Black ]
    in
    Fuzz.listOfLengthBetween 0 80
        (Fuzz.oneOf
            [ Fuzz.map2 Pressed (Fuzz.oneOfValues [ Primary, Secondary ]) (Fuzz.oneOfValues targets)
            , Fuzz.oneOfValues
                [ PickedBrush (Paint White)
                , PickedBrush (Paint Black)
                , PickedBrush Erase
                , PickedTurn White
                , PickedTurn Black
                , PickedRoll ( 3, 1 )
                , PickedRoll ( 6, 6 )
                , OpenedRolls
                , ClosedRolls
                , PickedDouble
                , PickedTake
                , CycledCube
                , CycledOwner
                , ToggledGame
                , SteppedLength 1
                , SteppedLength -1
                , SteppedScore White 1
                , SteppedScore Black 1
                , SteppedScore White -1
                , ToggledCrawford
                , PressedOpening
                , PressedClear
                , PressedFlip
                ]
            ]
        )
