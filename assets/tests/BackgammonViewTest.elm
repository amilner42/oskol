module BackgammonViewTest exposing (suite)

{-| The backgammon board: pure update logic and rendered DOM facts, driven by
real fixture payloads.
-}

import Dict
import Drag
import Expect
import FixtureLoader exposing (Fixture)
import Games.Backgammon.View as View exposing (Msg(..), Out(..))
import Html
import Html.Attributes
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (ParamKind(..), Schema)
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, classes, tag, text)


suite : Test
suite =
    describe "backgammon board"
        [ describe "update"
            [ test "playing a move sends it and clears the selection" <|
                \_ ->
                    let
                        ( m1, out1 ) =
                            View.update (SelectFrom "13") View.init

                        ( m2, out2 ) =
                            View.update (PlayMove "13" "8") m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just "13") m1.selectedFrom
                        , \_ -> Expect.equal NoOut out1
                        , \_ -> Expect.equal Nothing m2.selectedFrom
                        , \_ -> Expect.equal (Send (Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ])) out2
                        ]
                        ()
            , test "selecting the same source again clears it" <|
                \_ ->
                    View.init
                        |> View.update (SelectFrom "13")
                        |> Tuple.first
                        |> View.update (SelectFrom "13")
                        |> Tuple.first
                        |> .selectedFrom
                        |> Expect.equal Nothing
            , test "playing a pair sends both moves in order" <|
                \_ ->
                    View.update (PlayPair { from = "13", to = "9" } { from = "11", to = "9" }) View.init
                        |> Tuple.second
                        |> Expect.equal
                            (SendMany
                                [ Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "9" ) ]
                                , Protocol.encodeAction "move" [ ( "from", E.string "11" ), ( "to", E.string "9" ) ]
                                ]
                            )
            , test "simple actions send their name with no params" <|
                \_ ->
                    View.update (Simple "roll") View.init
                        |> Tuple.second
                        |> Expect.equal (Send (Protocol.encodeAction "roll" []))
            , test "rematch is reported to the app, not sent as an action" <|
                \_ ->
                    View.update Rematch View.init |> Tuple.second |> Expect.equal WantRematch
            ]
        , describe "destination-first tap resolution"
            (let
                base =
                    { selected = Nothing
                    , moves = []
                    , sources = []
                    , mineAt = \_ -> 0
                    , unusedDice = []
                    }
             in
             [ test "exactly one legal move landing on the point plays it" <|
                \_ ->
                    View.resolveTap { base | moves = [ { from = "13", to = "8" } ], unusedDice = [ 5, 3 ] } "8"
                        |> Expect.equal (Just (PlayMove "13" "8"))
             , test "two moves from different origins onto an empty point stage the pair" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9" }, { from = "11", to = "9" }, { from = "24", to = "20" } ]
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal (Just (PlayPair { from = "13", to = "9" } { from = "11", to = "9" }))
             , test "two moves onto a point I already occupy are ambiguous" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9" }, { from = "11", to = "9" } ]
                            , mineAt =
                                \loc ->
                                    if loc == "9" then
                                        1

                                    else
                                        0
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal Nothing
             , test "doubles with two checkers at the origin stage the pair onto an empty point" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "10" } ]
                            , mineAt =
                                \loc ->
                                    if loc == "13" then
                                        5

                                    else
                                        0
                            , unusedDice = [ 3, 3, 3, 3 ]
                        }
                        "10"
                        |> Expect.equal (Just (PlayPair { from = "13", to = "10" } { from = "13", to = "10" }))
             , test "doubles with one checker at the origin play a single move" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "10" } ]
                            , mineAt =
                                \loc ->
                                    if loc == "13" then
                                        1

                                    else
                                        0
                            , unusedDice = [ 3, 3 ]
                        }
                        "10"
                        |> Expect.equal (Just (PlayMove "13" "10"))
             , test "bearing off never auto-stages a pair" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "3", to = "off" } ]
                            , mineAt =
                                \loc ->
                                    if loc == "3" then
                                        3

                                    else
                                        0
                            , unusedDice = [ 3, 3, 3, 3 ]
                        }
                        "off"
                        |> Expect.equal (Just (PlayMove "3" "off"))
             , test "a point that is also one of my movable origins selects the origin instead" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "8", to = "5" }, { from = "13", to = "8" } ]
                            , sources = [ "8", "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "8"
                        |> Expect.equal (Just (SelectFrom "8"))
             , test "three moves landing on the same point are ambiguous" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9" }, { from = "11", to = "9" }, { from = "12", to = "9" } ]
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal Nothing
             , test "with a selection, a legal destination plays that move" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "8" }, { from = "6", to = "8" } ]
                            , sources = [ "13", "6" ]
                        }
                        "8"
                        |> Expect.equal (Just (PlayMove "13" "8"))
             , test "with a selection, tapping the selected point clears it" <|
                \_ ->
                    View.resolveTap
                        { base | selected = Just "13", moves = [ { from = "13", to = "8" } ], sources = [ "13" ] }
                        "13"
                        |> Expect.equal (Just Clear)
             , test "with a selection, tapping another origin switches the selection" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "8" }, { from = "6", to = "2" } ]
                            , sources = [ "13", "6" ]
                        }
                        "6"
                        |> Expect.equal (Just (SelectFrom "6"))
             ]
            )
        , describe "dragging a checker"
            (let
                press =
                    { origin = "13", color = "white", tap = Just (SelectFrom "13"), targets = [ "8" ], x = 100, y = 100 }

                zone =
                    { loc = "8", left = 200, top = 300, width = 50, height = 120 }

                step msg =
                    Tuple.first >> View.update msg
             in
             [ test "pressing a checker asks Main for that origin's drop zones" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> Tuple.second
                        |> Expect.equal (NeedZones [ "8" ])
             , test "a drop on a legal zone stages the move, like a tap would" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (GotDropZones [ zone ])
                        |> step (DragMoved { x = 225, y = 360 })
                        |> step (DragReleased { x = 225, y = 360 })
                        |> Expect.equal ( View.init, Send (Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ]) )
             , test "a drop off every zone sends nothing and snaps back" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (GotDropZones [ zone ])
                        |> step (DragMoved { x = 150, y = 150 })
                        |> step (DragReleased { x = 150, y = 150 })
                        |> Expect.equal ( View.init, NoOut )
             , test "a release under the threshold resolves the stored tap" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (DragMoved { x = 104, y = 103 })
                        |> step (DragReleased { x = 104, y = 103 })
                        |> Expect.equal ( { selectedFrom = Just "13", drag = Drag.idle }, NoOut )
             , test "pointercancel snaps back without sending" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (DragMoved { x = 225, y = 360 })
                        |> step DragCancelled
                        |> Expect.equal ( View.init, NoOut )
             ]
            )
        , describe "rendering fixtures" (List.map perFixture (FixtureLoader.byGame "backgammon"))
        ]


ctx : String -> Protocol.Update -> View.Model -> View.Ctx
ctx playerId update model =
    { playerId = playerId
    , scene = update.scene
    , legal = update.legal
    , model = model
    , clock = Nothing
    , receivedAt = 0
    , now = 0
    , nameOf = identity
    , rematchReady = []
    , away = []
    , finished =
        case update.outcome of
            Protocol.Finished winners ->
                Just winners

            Protocol.Ongoing ->
                Nothing
    }


legalFroms : List Schema -> List String
legalFroms legal =
    legal
        |> List.filter (\s -> s.name == "move")
        |> List.filterMap
            (\s ->
                s.params
                    |> List.filter (\p -> p.name == "from")
                    |> List.head
                    |> Maybe.andThen
                        (\p ->
                            case p.kind of
                                Choice ((id, _) :: _) ->
                                    Just id

                                _ ->
                                    Nothing
                        )
            )
        |> unique


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


perFixture : Fixture -> Test
perFixture fixture =
    let
        p1Views =
            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p1")

        p2Views =
            (fixture.initial :: List.map .updates fixture.steps) |> List.filterMap (Dict.get "p2")

        render playerId u =
            View.view (ctx playerId u View.init) |> Query.fromHtml
    in
    describe fixture.name
        [ test "thirty checkers are always on the board" <|
            \_ ->
                p1Views
                    |> List.map (\u -> render "p1" u |> Query.findAll [ class "checker" ] |> Query.count (Expect.equal 30))
                    |> allPass
        , test "exactly the legal source points are marked, for both players" <|
            \_ ->
                (List.map (\u -> ( "p1", u )) p1Views ++ List.map (\u -> ( "p2", u )) p2Views)
                    |> List.map
                        (\( id, u ) ->
                            let
                                pointSources =
                                    legalFroms u.legal |> List.filter (\f -> f /= "bar") |> List.length
                            in
                            render id u |> Query.findAll [ class "bg-point", class "source" ] |> Query.count (Expect.equal pointSources)
                        )
                    |> allPass
        , test "PLAY appears exactly when the turn can be played" <|
            \_ ->
                p1Views
                    |> List.map
                        (\u ->
                            let
                                expected =
                                    if List.any (\s -> s.name == "play") u.legal then
                                        1

                                    else
                                        0
                            in
                            render "p1" u |> Query.findAll [ tag "button", text "PLAY" ] |> Query.count (Expect.equal expected)
                        )
                    |> allPass
        , test "a waiting player is told whose turn it is" <|
            \_ ->
                p2Views
                    |> List.filter (\u -> (Protocol.sceneData (D.nullable D.string) "to_act" u.scene |> Maybe.withDefault Nothing) == Just "p1")
                    |> List.map (\u -> render "p2" u |> Query.has [ text "WAITING FOR P1" ])
                    |> allPass
        , test "clicking a source point selects it" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal |> List.any (\f -> f /= "bar"))
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.filter (\f -> f /= "bar") |> List.head |> Maybe.withDefault ""
                            in
                            render "p1" u
                                |> Query.find [ class "bg-point", class "source", attribute (Html.Attributes.title ("Point " ++ from)) ]
                                |> Event.simulate Event.click
                                |> Event.expect (SelectFrom from)
                        )
                    |> Maybe.withDefault Expect.pass
        , test "exactly the legal origins offer a draggable checker" <|
            \_ ->
                (List.map (\u -> ( "p1", u )) p1Views ++ List.map (\u -> ( "p2", u )) p2Views)
                    |> List.map
                        (\( id, u ) ->
                            render id u
                                |> Query.findAll [ attribute (Html.Attributes.attribute "data-drag-capture" "") ]
                                |> Query.count (Expect.equal (List.length (legalFroms u.legal)))
                        )
                    |> allPass
        , test "mid-drag, a ghost checker rides the pointer and the origin's points highlight" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal /= [])
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.head |> Maybe.withDefault ""

                                pointDests =
                                    u.legal
                                        |> List.filter (\s -> s.name == "move")
                                        |> List.filter (\s -> List.any (\p -> p.name == "from" && p.kind == Choice [ ( from, from ) ]) s.params)
                                        |> List.filterMap
                                            (\s ->
                                                s.params
                                                    |> List.filter (\p -> p.name == "to")
                                                    |> List.head
                                                    |> Maybe.andThen
                                                        (\p ->
                                                            case p.kind of
                                                                Choice ((to, _) :: _) ->
                                                                    Just to

                                                                _ ->
                                                                    Nothing
                                                        )
                                            )
                                        |> List.filter ((/=) "off")
                                        |> unique

                                model =
                                    View.init
                                        |> View.update (DragPressed { origin = from, color = "white", tap = Nothing, targets = [], x = 0, y = 0 })
                                        |> Tuple.first
                                        |> View.update (DragMoved { x = 40, y = 40 })
                                        |> Tuple.first

                                rendered =
                                    View.view (ctx "p1" u model) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.has [ class "bg-drag-ghost" ]
                                , \_ -> rendered |> Query.findAll [ class "bg-point", class "target" ] |> Query.count (Expect.equal (List.length pointDests))
                                ]
                                ()
                        )
                    |> Maybe.withDefault Expect.pass
        , test "after selecting a source the destinations show ghost checkers" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal |> List.any (\f -> f /= "bar"))
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.filter (\f -> f /= "bar") |> List.head |> Maybe.withDefault ""

                                destinations =
                                    u.legal
                                        |> List.filter (\s -> s.name == "move")
                                        |> List.filter (\s -> List.any (\p -> p.name == "from" && p.kind == Choice [ ( from, from ) ]) s.params)
                                        |> List.length
                            in
                            View.view (ctx "p1" u { selectedFrom = Just from, drag = Drag.idle })
                                |> Query.fromHtml
                                |> Query.findAll [ class "ghost" ]
                                |> Query.count (Expect.equal destinations)
                        )
                    |> Maybe.withDefault Expect.pass
        , test "the game-over panel offers a rematch once the match is decided" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> u.outcome /= Protocol.Ongoing)
                    |> List.map (\u -> render "p1" u |> Query.has [ text "REMATCH" ])
                    |> allPass
        ]


{-| `Expect.all` rejects an empty list; a fixture that never reaches a state is
not a failure of the renderer.
-}
allPass : List Expect.Expectation -> Expect.Expectation
allPass expectations =
    case expectations of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map always expectations) ()
