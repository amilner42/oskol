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
import Dict
import Expect
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)
import Games.Backgammon.View as Board
import Games.Backgammon.Xgid as Xgid
import Html.Attributes
import Json.Decode as D
import Page.Analysis as Analysis exposing (Brush(..), Button(..), Msg(..), Target(..))
import PuzzleApiFixtures
import Route
import Session
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, text)
import Ui.SaveToSet as SaveToSet


suite : Test
suite =
    describe "the analysis board"
        [ painting
        , pointers
        , quickStarts
        , doors
        , theLine
        , settings
        , answering
        , placing
        , whoseMove
        , theNextPosition
        , playingItOut
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
                Analysis.init Session.empty "http://oskol.test" { xgid = Just raw, puzzle = Nothing }
                    |> Tuple.first
                    |> Expect.all
                        [ crawford >> Expect.equal (Just False)
                        , sendAll [ PickedRoll ( 3, 1 ) ] >> Analysis.line >> Expect.equal Nothing
                        , sendAll [ ToggledGame, ToggledGame ] >> crawford >> Expect.equal (Just False)
                        ]
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
        , test "SAVE opens the second row of the actions, under PLAY, and opens the save sheet for the answer's puzzle" <|
            \_ ->
                answered "move"
                    |> Expect.all
                        [ panel >> Query.find [ id "an-actions" ] >> Query.children [] >> Query.index 1 >> Query.has [ id "an-save", text "SAVE" ]
                        , panel >> Query.find [ id "an-actions" ] >> Query.children [] >> Query.index 2 >> Query.has [ id "an-share" ]
                        , panel >> Query.find [ id "an-actions" ] >> Query.children [] >> Query.index 3 >> Query.has [ id "an-open-puzzle" ]
                        , panel >> Query.find [ id "an-save" ] >> Event.simulate Event.click >> Event.expect PressedSave
                        , Analysis.view >> Query.fromHtml >> Query.hasNot [ id "save-modal" ]
                        , send PressedSave >> .save >> Maybe.map .puzzleId >> Expect.equal (Just "fixmove1")
                        , send PressedSave >> Analysis.view >> Query.fromHtml >> Query.find [ id "save-modal" ] >> Query.has [ text "SAVE TO A SET" ]
                        ]
        , test "a guest's SAVE is the sign-in, which comes back to this very position" <|
            \_ ->
                let
                    saving =
                        send PressedSave (answered "move")
                in
                Expect.all
                    [ Analysis.view >> Query.fromHtml >> Query.find [ id "save-signin-line" ] >> Query.has [ text "Sign in to keep this position." ]
                    , .save
                        >> Maybe.andThen .signIn
                        >> Maybe.map .next
                        >> Expect.equal (Just (Route.href (Route.analysisXgid saving.setup)))
                    ]
                    saving
        , test "the sheet's x closes it" <|
            \_ ->
                answered "move"
                    |> send PressedSave
                    |> send (SaveMsg SaveToSet.PressedClose)
                    |> .save
                    |> Expect.equal Nothing
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
        , test "a double too close to call (the reported ND +0.221, D/T +0.224): a double in ink, and close in words" <|
            \_ ->
                sendAll [ PickedDouble, PressedAnalyze, GotAsk 1 (done "double_close") ] page
                    |> panel
                    |> Expect.all
                        [ Query.find [ class "rp-cube-eq", class "is-pick" ] >> Query.has [ text "Double, take" ]
                        , Query.has [ text "Too close to call: doubling gains just 0.003, so either is fine. If doubled, Black takes." ]
                        , Query.hasNot [ text "The game is close here: not a double yet." ]
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




-- PLAYING IT OUT (analysis-play-it-out)


{-| A board drawn from the mover's side (the mover as White), as a
candidate's position and a tree's node are, from signed counts in the
mover's numbering.
-}
boardOf : List Int -> Puzzle.Board
boardOf points =
    let
        white =
            List.map (max 0) points

        black =
            List.map (negate >> max 0) points
    in
    { white = { points = white, bar = 0, off = 15 - List.sum white }
    , black = { points = black, bar = 0, off = 15 - List.sum black }
    }


{-| The opening after 8/5 6/5.
-}
after31 : List Int
after31 =
    [ -2, 0, 0, 0, 2, 4, 0, 2, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2 ]


withRoll31 : Setup
withRoll31 =
    { opening | ask = Move (Just ( 3, 1 )) }


opening : Setup
opening =
    Setup.opening


theNextPosition : Test
theNextPosition =
    describe "Setup.next: the position a choice leaves"
        [ test "a play: the other colour to play, no roll yet" <|
            \_ ->
                Setup.next (Setup.Played { notation = "8/5 6/5", board = boardOf after31 }) withRoll31
                    |> Expect.equal (Ok { opening | points = after31, toPlay = Black, ask = Move Nothing })
        , test "Black's play is turned back round onto the board" <|
            \_ ->
                let
                    black =
                        { opening | toPlay = Black, ask = Move (Just ( 3, 1 )) }
                in
                -- the opening is the same from either side, so Black's 8/5 6/5
                -- is White's after-3-1 board turned round
                Setup.next (Setup.Played { notation = "8/5 6/5", board = boardOf after31 }) black
                    |> Result.map (\s -> ( s.points, s.toPlay ))
                    |> Expect.equal (Ok ( after31 |> List.reverse |> List.map negate, White ))
        , test "a play that bears the last checker off ends the line" <|
            \_ ->
                Setup.next (Setup.Played { notation = "1/off", board = boardOf (List.repeat 23 0 ++ [ -15 ]) }) withRoll31
                    |> Expect.equal (Err "White has borne off.")
        , test "NO DOUBLE: the same colour to roll" <|
            \_ ->
                Setup.next Setup.NoDouble { opening | ask = Double }
                    |> Expect.equal (Ok { opening | ask = Move Nothing })
        , test "DOUBLE: the other colour asked to take, the cube as it stood" <|
            \_ ->
                Setup.next Setup.Doubled { opening | ask = Double }
                    |> Expect.equal (Ok { opening | ask = Take, toPlay = Black })
        , test "TAKE: the cube doubled and the taker's, the doubler to roll" <|
            \_ ->
                Setup.next Setup.Took { opening | ask = Take, toPlay = Black, cubeValue = 2, cubeOwner = Just Black }
                    |> Expect.equal (Ok { opening | ask = Move Nothing, toPlay = White, cubeValue = 4, cubeOwner = Just Black })
        , test "PASS ends the line at the cube's value" <|
            \_ ->
                Expect.all
                    [ \_ -> Setup.next Setup.Passed { opening | ask = Take, toPlay = Black } |> Expect.equal (Err "Black passes. White wins 1 point.")
                    , \_ -> Setup.next Setup.Passed { opening | ask = Take, toPlay = White, cubeValue = 2, cubeOwner = Just White } |> Expect.equal (Err "White passes. Black wins 2 points.")
                    ]
                    ()
        , test "a choice that does not answer the question is no step" <|
            \_ ->
                Setup.next Setup.Took withRoll31 |> Expect.equal (Err "")
        ]


{-| The opening 3-1 answered (the "move" fixture), White to play.
-}
answered31 : Analysis.Model
answered31 =
    sendAll [ PickedRoll ( 3, 1 ), PressedAnalyze, GotAsk 1 (done "move") ] page


lineSteps : Analysis.Model -> List Analysis.Step
lineSteps model =
    (Analysis.lineNow model).steps


platesOf : Analysis.Model -> List String
platesOf model =
    List.map Analysis.plate (lineSteps model)


{-| A turn of one checker 8/5 then 6/5: the opening, the 8/5, then the
terminal board (the opening after 3-1). A tree as the server sends one.
-}
tree31 : Puzzle.Tree
tree31 =
    let
        node points dice moved children =
            { board = boardOf points, diceLeft = dice, terminal = children == [], moved = moved, children = children }

        afterOne =
            [ -2, 0, 0, 0, 1, 5, 0, 2, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2 ]
    in
    { root = "r"
    , nodes =
        Dict.fromList
            [ ( "r", node opening.points [ 3, 1 ] Nothing [ { die = 3, from = "8", to = "5", node = "n1" } ] )
            , ( "n1", node afterOne [ 1 ] (Just { from = "8", to = "5", hit = False }) [ { die = 1, from = "6", to = "5", node = "n2" } ] )
            , ( "n2", node after31 [] (Just { from = "6", to = "5", hit = False }) [] )
            ]
    , lazy = False
    }


{-| White's last checker on the 1, 2-1 to play: bearing it off ends the game.
-}
lastChecker : Analysis.Model
lastChecker =
    let
        points =
            [ 1 ] ++ List.repeat 22 0 ++ [ -15 ]

        setup =
            { opening | points = points, ask = Move (Just ( 2, 1 )) }

        model =
            Analysis.init Session.empty "http://oskol.test" { xgid = Just (Xgid.encode setup), puzzle = Nothing } |> Tuple.first |> send (PickedMode Analysis.Play)

        last =
            { root = "r"
            , nodes =
                Dict.fromList
                    [ ( "r", { board = boardOf points, diceLeft = [ 2, 1 ], terminal = False, moved = Nothing, children = [ { die = 2, from = "1", to = "off", node = "n1" } ] } )
                    , ( "n1", { board = boardOf (List.repeat 23 0 ++ [ -15 ]), diceLeft = [ 1 ], terminal = True, moved = Just { from = "1", to = "off", hit = False }, children = [] } )
                    ]
            , lazy = False
            }
    in
    model |> send (GotMoves model.movesAsked (Ok last))


playingItOut : Test
playingItOut =
    describe "the line"
        [ test "PLAY BEST plays the best: a step with the other colour to play, in PLAY" <|
            \_ ->
                answered31
                    |> send PressedPlayCandidate
                    |> Expect.all
                        [ .line >> .at >> Expect.equal 1
                        , lineSteps >> List.length >> Expect.equal 2
                        , .setup >> .toPlay >> Expect.equal Black
                        , .setup >> .ask >> Expect.equal (Move Nothing)
                        , .mode >> Expect.equal Analysis.Play
                        , .ask >> Expect.equal Analysis.NotAsked
                        , platesOf >> Expect.equal [ "W 3-1 · play 1", "B to roll" ]
                        ]
        , test "PLAY THIS plays the candidate on the board" <|
            \_ ->
                answered31
                    |> sendAll [ Show (Just 2), PressedPlayCandidate ]
                    |> platesOf
                    |> Expect.equal [ "W 3-1 · play 2", "B to roll" ]
        , test "back and forward keep each step's answer, with nothing asked" <|
            \_ ->
                let
                    out =
                        answered31 |> sendAll [ PressedPlayCandidate, PickedRoll ( 6, 4 ), PressedAnalyze ]
                in
                out
                    |> send (GotAsk out.asks (done "move"))
                    |> send (Walked 0)
                    |> Expect.all
                        [ .ask >> isAnswered >> Expect.equal True
                        , .setup >> .ask >> Expect.equal (Move (Just ( 3, 1 )))
                        , send (Walked 1) >> .ask >> isAnswered >> Expect.equal True
                        , send (Walked 1) >> .setup >> .ask >> Expect.equal (Move (Just ( 6, 4 )))
                        , send (Walked 1) >> platesOf >> Expect.equal [ "W 3-1 · play 1", "B 6-4" ]
                        ]
        , test "a different choice at step 1 drops the steps after it" <|
            \_ ->
                answered31
                    |> sendAll
                        [ PressedPlayCandidate
                        , PickedDouble
                        , Chose Setup.Doubled
                        , Chose Setup.Took
                        , Walked 1
                        , Chose Setup.NoDouble
                        ]
                    |> Expect.all
                        [ platesOf >> Expect.equal [ "W 3-1 · play 1", "B no double", "B to roll" ]
                        , .line >> .at >> Expect.equal 2
                        ]
        , test "the same choice again walks on along the line as it was" <|
            \_ ->
                answered31
                    |> sendAll [ PressedPlayCandidate, PickedDouble, Chose Setup.Doubled, Chose Setup.Took, Walked 1, Chose Setup.Doubled ]
                    |> Expect.all
                        [ platesOf >> Expect.equal [ "W 3-1 · play 1", "B doubles", "W takes", "B to roll" ]
                        , .line >> .at >> Expect.equal 2
                        ]
        , test "a new roll at an earlier step drops what came after; another position starts a fresh line" <|
            \_ ->
                answered31
                    |> sendAll [ PressedPlayCandidate, PickedRoll ( 5, 2 ), Walked 0 ]
                    |> Expect.all
                        [ send (PickedRoll ( 6, 1 )) >> platesOf >> Expect.equal [ "W 6-1" ]
                        , send (Walked 1) >> send (PickedTurn White) >> platesOf >> Expect.equal [ "W 5-2" ]
                        ]
        , test "PASS ends the line in its sentence, and nothing more is chosen" <|
            \_ ->
                answered31
                    |> sendAll [ PressedPlayCandidate, PickedDouble, Chose Setup.Doubled, Chose Setup.Passed ]
                    |> Expect.all
                        [ Analysis.ending >> Expect.equal (Just "White passes. Black wins 1 point.")
                        , platesOf >> Expect.equal [ "W 3-1 · play 1", "B doubles", "W passes" ]
                        , Analysis.view >> Query.fromHtml >> Query.find [ id "an-line-end" ] >> Query.has [ text "White passes. Black wins 1 point." ]
                        , Analysis.view >> Query.fromHtml >> Query.hasNot [ id "an-take" ]
                        , send (Chose Setup.Took) >> platesOf >> Expect.equal [ "W 3-1 · play 1", "B doubles", "W passes" ]
                        ]
        , test "PLAY on the table commits the board its path reaches, as it reads" <|
            \_ ->
                let
                    model =
                        sendAll [ PickedRoll ( 3, 1 ), PickedMode Analysis.Play ] page
                in
                model
                    |> sendAll
                        [ GotMoves model.movesAsked (Ok tree31)
                        , BoardOut (Puzzle.Stepped [ "n1" ])
                        , BoardOut (Puzzle.Stepped [ "n2" ])
                        , BoardOut Puzzle.Play
                        ]
                    |> Expect.all
                        [ lineSteps >> List.head >> Maybe.andThen .chosen >> Expect.equal (Just (Setup.Played { notation = "8/5 6/5", board = boardOf after31 }))
                        , .setup >> .points >> Expect.equal after31
                        , .setup >> .toPlay >> Expect.equal Black
                        , platesOf >> Expect.equal [ "W 3-1 · 8/5 6/5", "B to roll" ]
                        ]
        , test "UNDO walks back, and PLAY waits for the whole roll" <|
            \_ ->
                let
                    model =
                        sendAll [ PickedRoll ( 3, 1 ), PickedMode Analysis.Play ] page
                in
                model
                    |> sendAll
                        [ GotMoves model.movesAsked (Ok tree31)
                        , BoardOut (Puzzle.Stepped [ "n1" ])
                        , BoardOut Puzzle.Play
                        , BoardOut Puzzle.Undo
                        ]
                    |> Expect.all
                        [ .path >> Expect.equal []
                        , platesOf >> Expect.equal [ "W 3-1" ]
                        ]
        , test "a play that bears the last checker off ends the line" <|
            \_ ->
                lastChecker
                    |> sendAll [ BoardOut (Puzzle.Stepped [ "n1" ]), BoardOut Puzzle.Play ]
                    |> Expect.all
                        [ Analysis.ending >> Expect.equal (Just "White has borne off.")
                        , platesOf >> Expect.equal [ "W 2-1 · 1/off" ]
                        ]
        , test "a tree for a step no longer on the board is dropped" <|
            \_ ->
                let
                    model =
                        sendAll [ PickedRoll ( 3, 1 ), PickedMode Analysis.Play ] page
                in
                model
                    |> sendAll [ PickedRoll ( 6, 4 ), GotMoves model.movesAsked (Ok tree31) ]
                    |> .moves
                    |> Expect.equal Analysis.MovesAsked
        , test "a choice that does not answer the step's question changes nothing" <|
            \_ ->
                answered31
                    |> send (Chose Setup.Took)
                    |> Expect.all
                        [ platesOf >> Expect.equal [ "W 3-1" ]
                        , .mode >> Expect.equal Analysis.SetUp
                        ]
        , test "PLAY waits for a complete position" <|
            \_ ->
                send PressedClear page
                    |> send (PickedMode Analysis.Play)
                    |> .mode
                    |> Expect.equal Analysis.SetUp
        , test "the plates read who, the roll and the play, or the cube" <|
            \_ ->
                [ { setup = withRoll31, answer = Nothing, chosen = Just (Setup.Played { notation = "8/5 6/5", board = boardOf after31 }) }
                , { setup = { opening | toPlay = Black, ask = Move (Just ( 6, 2 )) }, answer = Nothing, chosen = Nothing }
                , { setup = { opening | toPlay = Black, ask = Move (Just ( 6, 4 )) }, answer = Nothing, chosen = Just (Setup.Played { notation = "", board = boardOf opening.points }) }
                , { setup = opening, answer = Nothing, chosen = Nothing }
                , { setup = { opening | ask = Double }, answer = Nothing, chosen = Just Setup.Doubled }
                , { setup = { opening | ask = Double }, answer = Nothing, chosen = Just Setup.NoDouble }
                , { setup = { opening | ask = Take, toPlay = Black }, answer = Nothing, chosen = Just Setup.Took }
                , { setup = { opening | ask = Take, toPlay = Black }, answer = Nothing, chosen = Just Setup.Passed }
                , { setup = { opening | ask = Take, toPlay = Black }, answer = Nothing, chosen = Nothing }
                ]
                    |> List.map Analysis.plate
                    |> Expect.equal [ "W 3-1 · 8/5 6/5", "B 6-2", "B 6-4 · no play", "W to roll", "W doubles", "W no double", "B takes", "B passes", "B take?" ]
        , test "the strip: a plate per step, the one on the board marked, the arrows where there is somewhere to go" <|
            \_ ->
                answered31
                    |> sendAll [ PressedPlayCandidate, Walked 0 ]
                    |> Analysis.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "an-line" ] >> Query.findAll [ class "an-plate" ] >> Query.count (Expect.equal 2)
                        , Query.find [ id "an-plate-0" ] >> Query.has [ class "is-on" ]
                        , Query.find [ id "an-first" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        , Query.find [ id "an-next" ] >> Event.simulate Event.click >> Event.expect (Walked 1)
                        ]
        , test "notation joins one checker's steps and counts the same move" <|
            \_ ->
                let
                    at_ dice moved children =
                        { board = boardOf opening.points, diceLeft = dice, terminal = children == [], moved = moved, children = children }

                    chain =
                        { root = "r"
                        , nodes =
                            Dict.fromList
                                [ ( "r", at_ [ 6, 6, 6, 6 ] Nothing [ { die = 6, from = "24", to = "18", node = "a" } ] )
                                , ( "a", at_ [ 6, 6, 6 ] (Just { from = "24", to = "18", hit = True }) [ { die = 6, from = "18", to = "12", node = "b" } ] )
                                , ( "b", at_ [ 6, 6 ] (Just { from = "18", to = "12", hit = False }) [ { die = 6, from = "13", to = "7", node = "c" } ] )
                                , ( "c", at_ [ 6 ] (Just { from = "13", to = "7", hit = False }) [ { die = 6, from = "13", to = "7", node = "d" } ] )
                                , ( "d", at_ [] (Just { from = "13", to = "7", hit = False }) [] )
                                ]
                        , lazy = False
                        }
                in
                Analysis.notation chain [ "a", "b", "c", "d" ]
                    |> Expect.equal "24/18*/12 13/7(2)"
        ]


whoseMove : Test
whoseMove =
    describe "whose move it is"
        [ test "TO PLAY: each colour's checker and its word, the chosen one marked, heard as \"White to play\"" <|
            \_ ->
                Analysis.view page
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "an-turn-white" ] >> Query.has [ class "is-on", text "WHITE", attribute (Html.Attributes.attribute "aria-label" "White to play"), attribute (Html.Attributes.attribute "aria-pressed" "true") ]
                        , Query.find [ id "an-turn-black" ] >> Query.has [ text "BLACK", attribute (Html.Attributes.attribute "aria-pressed" "false") ]
                        , Query.find [ id "an-turn-black" ] >> Query.hasNot [ class "is-on" ]
                        , Query.find [ id "an-turn-white" ] >> Query.has [ class "an-chip", class "white" ]
                        ]
        , test "the mover's bar is the one to move, in SET UP too" <|
            \_ ->
                Expect.all
                    [ \_ -> Analysis.view page |> Query.fromHtml |> Query.find [ class "player-bar", class "active" ] |> Query.has [ text "White" ]
                    , \_ -> send (PickedTurn Black) page |> Analysis.view |> Query.fromHtml |> Query.find [ class "player-bar", class "active" ] |> Query.has [ text "Black" ]
                    ]
                    ()
        , test "the position id's row is gone" <|
            \_ ->
                Analysis.view page
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.hasNot [ id "an-xgid" ]
                        , Query.hasNot [ id "an-xgid-copy" ]
                        , Query.hasNot [ id "an-xgid-import" ]
                        ]
        ]
