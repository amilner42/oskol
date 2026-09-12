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
import Test.Html.Selector exposing (attribute, class, classes, id, tag, text)


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
                    View.update (PlayPair { from = "13", to = "9", die = 4 } { from = "11", to = "9", die = 2 }) View.init
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
                    , direction = -1
                    , theirsAt = \_ -> 0
                    }
             in
             [ test "exactly one legal move landing on the point plays it" <|
                \_ ->
                    View.resolveTap { base | moves = [ { from = "13", to = "8", die = 5 } ], unusedDice = [ 5, 3 ] } "8"
                        |> Expect.equal (Just (PlayMove "13" "8"))
             , test "two moves from different origins onto an empty point stage the pair" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9", die = 4 }, { from = "11", to = "9", die = 2 }, { from = "24", to = "20", die = 4 } ]
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal (Just (PlayPair { from = "13", to = "9", die = 4 } { from = "11", to = "9", die = 2 }))
             , test "two moves onto an opponent's blot make the point and hit" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9", die = 4 }, { from = "11", to = "9", die = 2 } ]
                            , sources = [ "13", "11" ]
                            , unusedDice = [ 4, 2 ]
                            , theirsAt =
                                \loc ->
                                    if loc == "9" then
                                        1

                                    else
                                        0
                        }
                        "9"
                        |> Expect.equal (Just (PlayPair { from = "13", to = "9", die = 4 } { from = "11", to = "9", die = 2 }))
             , test "one move onto a point I already hold is not played by tapping it" <|
                \_ ->
                    -- three on the 7, one on the 10, a 3 left: tapping the 7
                    -- does not drag the 10 in
                    View.resolveTap
                        { base
                            | moves = [ { from = "10", to = "7", die = 3 } ]
                            , sources = [ "10" ]
                            , unusedDice = [ 3 ]
                            , mineAt =
                                \loc ->
                                    if loc == "7" then
                                        3

                                    else if loc == "10" then
                                        1

                                    else
                                        0
                        }
                        "7"
                        |> Expect.equal Nothing
             , test "one move onto an opponent's blot is played by tapping it" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "10", to = "7", die = 3 } ]
                            , sources = [ "10" ]
                            , unusedDice = [ 3 ]
                            , theirsAt =
                                \loc ->
                                    if loc == "7" then
                                        1

                                    else
                                        0
                        }
                        "7"
                        |> Expect.equal (Just (PlayMove "10" "7"))
             , test "two moves onto a point I already occupy are ambiguous" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9", die = 4 }, { from = "11", to = "9", die = 2 } ]
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
                            | moves = [ { from = "13", to = "10", die = 3 } ]
                            , mineAt =
                                \loc ->
                                    if loc == "13" then
                                        5

                                    else
                                        0
                            , unusedDice = [ 3, 3, 3, 3 ]
                        }
                        "10"
                        |> Expect.equal (Just (PlayPair { from = "13", to = "10", die = 3 } { from = "13", to = "10", die = 3 }))
             , test "doubles with one checker at the origin play a single move" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "10", die = 3 } ]
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
                            | moves = [ { from = "3", to = "off", die = 3 } ]
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
                            | moves = [ { from = "8", to = "5", die = 3 }, { from = "13", to = "8", die = 5 } ]
                            , sources = [ "8", "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "8"
                        |> Expect.equal (Just (SelectFrom "8"))
             , test "three moves landing on the same point are ambiguous" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9", die = 4 }, { from = "11", to = "9", die = 2 }, { from = "12", to = "9", die = 3 } ]
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal Nothing
             , test "with a selection, a legal destination plays that move" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "8", die = 5 }, { from = "6", to = "8", die = 2 } ]
                            , sources = [ "13", "6" ]
                        }
                        "8"
                        |> Expect.equal (Just (PlayMove "13" "8"))
             , test "with a selection and no dice left, tapping the selected point clears it" <|
                \_ ->
                    View.resolveTap
                        { base | selected = Just "13", moves = [ { from = "13", to = "8", die = 5 } ], sources = [ "13" ] }
                        "13"
                        |> Expect.equal (Just Clear)
             , test "tapping the selected checker again plays it with the next die" <|
                \_ ->
                    -- dice 5 then 3, both unused: the 5 goes first
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "10", die = 3 }, { from = "13", to = "8", die = 5 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "13"
                        |> Expect.equal (Just (PlayMove "13" "8"))
             , test "the next die is the first unused one, reading left to right" <|
                \_ ->
                    -- the 5 is spent: the 3 is next
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "10", die = 3 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 3 ]
                        }
                        "13"
                        |> Expect.equal (Just (PlayMove "13" "10"))
             , test "if the leftmost die cannot play that checker, the one after it does" <|
                \_ ->
                    -- the 5 is next but only the 3 is legal from 13: the 3 plays
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "10", die = 3 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "13"
                        |> Expect.equal (Just (PlayMove "13" "10"))
             , test "if no die can play that checker, the second tap only clears" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "8", to = "5", die = 3 } ]
                            , sources = [ "13", "8" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "13"
                        |> Expect.equal (Just Clear)
             , test "the second tap works from the bar too" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "bar"
                            , moves = [ { from = "bar", to = "21", die = 4 }, { from = "bar", to = "23", die = 2 } ]
                            , sources = [ "bar" ]
                            , unusedDice = [ 2, 4 ]
                        }
                        "bar"
                        |> Expect.equal (Just (PlayMove "bar" "23"))
             , test "with a selection, tapping another origin switches the selection" <|
                \_ ->
                    View.resolveTap
                        { base
                            | selected = Just "13"
                            , moves = [ { from = "13", to = "8", die = 5 }, { from = "6", to = "2", die = 4 } ]
                            , sources = [ "13", "6" ]
                        }
                        "6"
                        |> Expect.equal (Just (SelectFrom "6"))
             ]
            )
        , describe "one checker, several dice"
            (let
                base =
                    { selected = Nothing
                    , moves = []
                    , sources = []
                    , mineAt = \_ -> 0
                    , unusedDice = []
                    , direction = -1
                    , theirsAt = \_ -> 0
                    }

                -- white on 13 with 5 and 3: 13 -> 8 -> 5 or 13 -> 10 -> 5
                both =
                    { base
                        | moves = [ { from = "13", to = "8", die = 5 }, { from = "13", to = "10", die = 3 } ]
                        , sources = [ "13" ]
                        , unusedDice = [ 5, 3 ]
                    }

                held points loc =
                    if List.member loc points then
                        2

                    else
                        0
             in
             [ test "both dice reach a point beyond either die, by the dice in order" <|
                \_ ->
                    View.pathsFrom both "13"
                        |> Expect.equal [ { to = "5", steps = [ { from = "13", to = "8", die = 5 }, { from = "8", to = "5", die = 3 } ] } ]
             , test "the route that hits a blot wins over the dice order" <|
                \_ ->
                    View.pathsFrom
                        { both
                            | theirsAt =
                                \loc ->
                                    if loc == "10" then
                                        1

                                    else
                                        0
                        }
                        "13"
                        |> Expect.equal [ { to = "5", steps = [ { from = "13", to = "10", die = 3 }, { from = "10", to = "5", die = 5 } ] } ]
             , test "a route through a point the opponent holds is not a route" <|
                \_ ->
                    -- 8 is held: 13 -> 8 is not even a legal first step, so
                    -- only 13 -> 10 -> 5 remains; hold 5 too and nothing does
                    Expect.all
                        [ \_ ->
                            View.pathsFrom { both | moves = [ { from = "13", to = "10", die = 3 } ], theirsAt = held [ "8" ] } "13"
                                |> List.map .to
                                |> Expect.equal [ "5" ]
                        , \_ ->
                            View.pathsFrom { both | theirsAt = held [ "5" ] } "13"
                                |> Expect.equal []
                        ]
                        ()
             , test "a point one die already reaches is not listed twice" <|
                \_ ->
                    -- 4-4 ... no: 5 and 3 from 13 reach 8 and 10 by one die;
                    -- with 8 also reachable by the 3 from 11 that is still
                    -- one die. Here: 3 then 5 lands on 5, 5 then 3 too. Only 5.
                    View.reachableFrom both "13"
                        |> Expect.equal [ "8", "10", "5" ]
             , test "a double chains two, three and four of the same die" <|
                \_ ->
                    View.pathsFrom
                        { base
                            | moves = [ { from = "24", to = "21", die = 3 } ]
                            , sources = [ "24" ]
                            , unusedDice = [ 3, 3, 3, 3 ]
                        }
                        "24"
                        |> List.map .to
                        |> Expect.equal [ "18", "15", "12" ]
             , test "a chain stops at the first held point" <|
                \_ ->
                    View.pathsFrom
                        { base
                            | moves = [ { from = "24", to = "21", die = 3 } ]
                            , sources = [ "24" ]
                            , unusedDice = [ 3, 3, 3, 3 ]
                            , theirsAt = held [ "15" ]
                        }
                        "24"
                        |> List.map .to
                        |> Expect.equal [ "18" ]
             , test "a tap on a point several dice away plays the moves in a row" <|
                \_ ->
                    View.resolveTap { both | selected = Just "13" } "5"
                        |> Expect.equal (Just (PlayPath [ { from = "13", to = "8", die = 5 }, { from = "8", to = "5", die = 3 } ]))
             , test "a drop on a point several dice away sends the moves in a row" <|
                \_ ->
                    let
                        press =
                            { origin = "13"
                            , color = "white"
                            , tap = Nothing
                            , targets = [ "8", "10", "5" ]
                            , plans = [ ( "5", [ { from = "13", to = "8", die = 5 }, { from = "8", to = "5", die = 3 } ] ) ]
                            , x = 100
                            , y = 100
                            }

                        zone =
                            { loc = "5", left = 200, top = 300, width = 50, height = 120 }
                    in
                    View.update (DragPressed press) View.init
                        |> Tuple.first
                        |> View.update (GotDropZones [ zone ])
                        |> Tuple.first
                        |> View.update (DragMoved { x = 225, y = 360 })
                        |> Tuple.first
                        |> View.update (DragReleased { x = 225, y = 360 })
                        |> Tuple.second
                        |> Expect.equal
                            (SendMany
                                [ Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ]
                                , Protocol.encodeAction "move" [ ( "from", E.string "8" ), ( "to", E.string "5" ) ]
                                ]
                            )
             ]
            )
        , describe "dragging a checker"
            (let
                press =
                    { origin = "13", color = "white", tap = Just (SelectFrom "13"), targets = [ "8" ], plans = [], x = 100, y = 100 }

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
                        |> Expect.equal ( { selectedFrom = Just "13", drag = Drag.idle, plans = [], rotation = 0, autoRolled = False, picker = Nothing, roll = settled }, NoOut )
             , test "pointercancel snaps back without sending" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (DragMoved { x = 225, y = 360 })
                        |> step DragCancelled
                        |> Expect.equal ( View.init, NoOut )
             ]
            )
        , describe "auto-roll"
            (let
                schema name =
                    { name = name, label = name, params = [] }
             in
             [ test "rolls by itself when doubling is not on offer" <|
                \_ ->
                    View.autoRoll [ schema "roll", schema "resign" ] View.init
                        |> Expect.equal
                            ( { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = 0, autoRolled = True, picker = Nothing, roll = settled }
                            , Just (Protocol.encodeAction "roll" [])
                            )
             , test "the same state never rolls twice" <|
                \_ ->
                    View.autoRoll [ schema "roll" ] { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = 0, autoRolled = True, picker = Nothing, roll = settled }
                        |> Expect.equal ( { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = 0, autoRolled = True, picker = Nothing, roll = settled }, Nothing )
             , test "keeps the choice when double is also legal" <|
                \_ ->
                    View.autoRoll [ schema "roll", schema "double" ] View.init
                        |> Expect.equal ( View.init, Nothing )
             , test "keeps the choice when pick is also legal" <|
                \_ ->
                    View.autoRoll [ schema "roll", schema "pick" ] View.init
                        |> Expect.equal ( View.init, Nothing )
             , test "disarms as soon as rolling stops being the pending action" <|
                \_ ->
                    View.autoRoll [ schema "move" ] { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = 0, autoRolled = True, picker = Nothing, roll = settled }
                        |> Expect.equal ( View.init, Nothing )
             , test "a whole turn rolls exactly once: qualify, roll, advance, re-qualify" <|
                \_ ->
                    let
                        step legal ( model, sends ) =
                            let
                                ( next, out ) =
                                    View.autoRoll legal model
                            in
                            ( next
                            , sends
                                + (if out == Nothing then
                                    0

                                   else
                                    1
                                  )
                            )
                    in
                    -- pre-roll state arrives twice (reconnect replay), then
                    -- the rolled state, then the next turn's pre-roll.
                    ( View.init, 0 )
                        |> step [ schema "roll" ]
                        |> step [ schema "roll" ]
                        |> step [ schema "move" ]
                        |> step [ schema "roll" ]
                        |> Tuple.second
                        |> Expect.equal 2
             ]
            )
        , describe "pick dice twist"
            (let
                schema name =
                    { name = name, label = name, params = [] }

                step msg =
                    Tuple.first >> View.update msg

                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)
             in
             [ test "the picker collects two values and confirm sends the pick" <|
                \_ ->
                    View.update OpenPicker View.init
                        |> step (PickFace 6)
                        |> step (PickFace 6)
                        |> step ConfirmPick
                        |> Expect.equal
                            ( View.init
                            , Send (Protocol.encodeAction "pick" [ ( "die1", E.int 6 ), ( "die2", E.int 6 ) ])
                            )
             , test "confirm before both dice are chosen sends nothing" <|
                \_ ->
                    View.update OpenPicker View.init
                        |> step (PickFace 3)
                        |> step ConfirmPick
                        |> Expect.equal ( { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = 0, autoRolled = False, picker = Just [ 3 ], roll = settled }, NoOut )
             , test "a third face is ignored" <|
                \_ ->
                    View.update OpenPicker View.init
                        |> step (PickFace 3)
                        |> step (PickFace 4)
                        |> step (PickFace 5)
                        |> Tuple.first
                        |> .picker
                        |> Expect.equal (Just [ 3, 4 ])
             , test "tapping a chosen die takes it back" <|
                \_ ->
                    View.update OpenPicker View.init
                        |> step (PickFace 3)
                        |> step (PickFace 4)
                        |> step (UnpickAt 0)
                        |> Tuple.first
                        |> .picker
                        |> Expect.equal (Just [ 4 ])
             , test "cancel closes the picker without sending" <|
                \_ ->
                    View.update OpenPicker View.init
                        |> step (PickFace 3)
                        |> step CancelPick
                        |> Expect.equal ( View.init, NoOut )
             , test "PICK DICE renders exactly when pick is legal" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ ->
                                    View.view (ctx "p1" { u | legal = [ schema "roll", schema "pick" ] } View.init)
                                        |> Query.fromHtml
                                        |> Query.has [ id "pick-dice-open" ]
                                , \_ ->
                                    View.view (ctx "p1" { u | legal = [ schema "roll", schema "double" ] } View.init)
                                        |> Query.fromHtml
                                        |> Query.hasNot [ id "pick-dice-open" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "an open picker shows six faces, confirm and cancel" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                model =
                                    View.update OpenPicker View.init |> Tuple.first

                                rendered =
                                    View.view (ctx "p1" { u | legal = [ schema "roll", schema "pick" ] } model)
                                        |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.has [ id "pick-dice-panel" ]
                                , \_ -> rendered |> Query.findAll [ tag "button", attribute (Html.Attributes.id "pick-face-6") ] |> Query.count (Expect.equal 1)
                                , \_ -> rendered |> Query.has [ id "pick-confirm" ]
                                , \_ -> rendered |> Query.has [ id "pick-cancel" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a stale open picker hides once pick stops being legal" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                model =
                                    View.update OpenPicker View.init |> Tuple.first
                            in
                            View.view (ctx "p1" { u | legal = [ schema "move" ] } model)
                                |> Query.fromHtml
                                |> Query.hasNot [ id "pick-dice-panel" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "a roll that plays nothing"
            (let
                schema name label =
                    { name = name, label = label, params = [] }

                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                -- The same update the server would send on a dance: the
                -- scene says `no_moves`, and the mover's only action is the
                -- pass the engine labelled for it.
                danced u =
                    { u
                        | scene = withData "no_moves" (E.bool True) u.scene
                        , legal = [ schema "play" "No moves — pass turn", schema "resign" "Resign" ]
                    }
             in
             [ test "the mover is told, beside the dice, and gets the pass button" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" (danced u) View.init) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.has [ id "bg-no-moves", text "NO LEGAL MOVES" ]
                                , \_ -> rendered |> Query.has [ id "bg-no-moves", text "TURN PASSES" ]
                                , \_ ->
                                    rendered
                                        |> Query.find [ id "bg-action-play" ]
                                        |> Query.has [ text "NO MOVES — PASS TURN" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the waiting player reads it too, named, with nothing to press" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                -- p2 is not the player to act, and a
                                -- watcher's own legal list is empty.
                                rendered =
                                    View.view (ctx "p2" { u | scene = withData "no_moves" (E.bool True) u.scene, legal = [] } View.init)
                                        |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.has [ id "bg-no-moves", text "TURN PASSES" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-action-play" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "an ordinary turn says nothing of the kind" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (ctx "p1" u View.init)
                                |> Query.fromHtml
                                |> Query.hasNot [ id "bg-no-moves" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the danced dice are all still on the board, none of them spent" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                dice =
                                    Protocol.zoneTokens "dice" u.scene |> List.length
                            in
                            View.view (ctx "p1" (danced u) View.init)
                                |> Query.fromHtml
                                |> Query.findAll [ class "die" ]
                                |> Query.count (Expect.equal dice)

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "dice between turns"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                -- The projection leaves last turn's roll in the dice zone
                -- while the next player decides to roll or double; the
                -- phase is what says the turn is over.
                between phase u =
                    let
                        scene =
                            u.scene
                    in
                    { u | scene = { scene | phase = phase }, legal = [] }

                diceShown playerId u expectation =
                    View.view (ctx playerId u View.init)
                        |> Query.fromHtml
                        |> Query.findAll [ class "die" ]
                        |> Query.count expectation
             in
             [ test "the dice zone in the fixture is not empty, so the cases below mean something" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Protocol.zoneTokens "dice" u.scene |> List.length |> Expect.greaterThan 0

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "once the turn has passed nobody sees any dice" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ -> diceShown "p1" (between "rolling" u) (Expect.equal 0)
                                , \_ -> diceShown "p2" (between "rolling" u) (Expect.equal 0)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a pending double shows no dice either" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            diceShown "p2" (between "doubled" u) (Expect.equal 0)

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a live roll shows every die of it" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            diceShown "p2" { u | scene = (\s -> { s | phase = "moving" }) u.scene }
                                (Expect.equal (Protocol.zoneTokens "dice" u.scene |> List.length))

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "the mover's dice"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                moverOf u =
                    Protocol.sceneData (D.nullable D.string) "to_move" u.scene
                        |> Maybe.withDefault Nothing
                        |> Maybe.withDefault ""

                colorOf id u =
                    Protocol.findPlayer id u.scene
                        |> Maybe.andThen (Protocol.playerData D.string "color")
                        |> Maybe.withDefault "?"

                other id =
                    if id == "p1" then
                        "p2"

                    else
                        "p1"

                -- The dice in the left and the right halves of the centre band.
                diceInBand index playerId u =
                    View.view (ctx playerId u View.init)
                        |> Query.fromHtml
                        |> Query.findAll [ class "bg-band" ]
                        |> Query.index index
                        |> Query.findAll [ class "die" ]
             in
             [ test "they are thrown in the mover's checker colour" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                color =
                                    colorOf (moverOf u) u

                                check playerId =
                                    View.view (ctx playerId u View.init)
                                        |> Query.fromHtml
                                        |> Query.findAll [ class "die" ]
                                        |> Query.each (Query.has [ class color ])
                            in
                            Expect.all [ \_ -> check "p1", \_ -> check "p2", \_ -> List.member color [ "white", "black" ] |> Expect.equal True ] ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the mover sees them on their own side, the right half" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                n =
                                    Protocol.zoneTokens "dice" u.scene |> List.length
                            in
                            Expect.all
                                [ \_ -> diceInBand 0 (moverOf u) u |> Query.count (Expect.equal 0)
                                , \_ -> diceInBand 1 (moverOf u) u |> Query.count (Expect.equal n)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the opponent sees them across the board, the left half" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                n =
                                    Protocol.zoneTokens "dice" u.scene |> List.length

                                watcher =
                                    other (moverOf u)

                                theirs =
                                    { u | legal = [] }
                            in
                            Expect.all
                                [ \_ -> diceInBand 0 watcher theirs |> Query.count (Expect.equal n)
                                , \_ -> diceInBand 1 watcher theirs |> Query.count (Expect.equal 0)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "tapping the dice"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                -- p1 to move with an ordinary roll, all of it unused
                twoDice u =
                    withDice [ 6, 4 ] u

                model rotation =
                    { selectedFrom = Nothing, drag = Drag.idle, plans = [], rotation = rotation, autoRolled = False, picker = Nothing, roll = settled }

                selecting from m =
                    { m | selectedFrom = Just from }

                nextDie rotation u =
                    View.view (ctx "p1" (twoDice u) (model rotation))
                        |> Query.fromHtml
                        |> Query.find [ class "die", class "next" ]
             in
             [ test "a tap on the dice keeps the selected checker and rotates" <|
                \_ ->
                    View.update RotateDice (selecting "13" (model 0))
                        |> Expect.equal ( selecting "13" (model 1), NoOut )
             , test "with a checker selected, the die that stands up is the one that will play it" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                -- the 6 (leftmost) cannot move 13; the 4 can
                                onlyFour =
                                    { u | legal = [ { name = "play", label = "Play", params = [] }, moveSchema "13" "9" 4 ] }
                            in
                            View.view (ctx "p1" (twoDice onlyFour) (selecting "13" (model 0)))
                                |> Query.fromHtml
                                |> Query.find [ class "die", class "next" ]
                                |> Query.has [ attribute (Html.Attributes.attribute "data-die" "die:1") ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the next die stands out: the first one, then the one after" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ -> nextDie 0 u |> Query.has [ attribute (Html.Attributes.attribute "data-die" "die:0") ]
                                , \_ -> nextDie 1 u |> Query.has [ attribute (Html.Attributes.attribute "data-die" "die:1") ]
                                , \_ -> nextDie 2 u |> Query.has [ attribute (Html.Attributes.attribute "data-die" "die:0") ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the mover's dice are a control; the other player's are not" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ -> View.view (ctx "p1" (twoDice u) (model 0)) |> Query.fromHtml |> Query.has [ class "dice-row", class "rotates" ]
                                , \_ -> View.view (ctx "p2" { u | legal = [] } View.init) |> Query.fromHtml |> Query.hasNot [ class "rotates" ]
                                , \_ -> View.view (ctx "p2" { u | legal = [] } View.init) |> Query.fromHtml |> Query.hasNot [ class "next" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a new roll starts unrotated" <|
                \_ ->
                    View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] (model 3)
                        |> .rotation
                        |> Expect.equal 0
             ]
            )
        , describe "the dice roll animation"
            [ test "a dice_rolled event is a roll watched landing; other events are not" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] View.init
                                |> .roll
                                |> Expect.equal { seq = 1, watched = True }
                        , \_ ->
                            View.noteEvents [ Protocol.Custom "turn_started" E.null, Protocol.Message "hi" ] View.init
                                |> .roll
                                |> Expect.equal settled
                        , \_ ->
                            -- A reconnect brings a payload with no events:
                            -- the dice are simply there, already thrown.
                            View.noteEvents [] View.init |> .roll |> Expect.equal settled
                        , \_ ->
                            -- ...and being told about a state after the fact
                            -- never un-watches the roll that is on the board,
                            -- which would cut a running tumble short.
                            View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] View.init
                                |> View.noteEvents [ Protocol.Custom "move_staged" E.null ]
                                |> .roll
                                |> Expect.equal { seq = 1, watched = True }
                        ]
                        ()
            , test "clearing the interaction state does not forget the roll" <|
                \_ ->
                    View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] View.init
                        |> View.update (SelectFrom "13")
                        |> Tuple.first
                        |> View.update Clear
                        |> Tuple.first
                        |> .roll
                        |> Expect.equal { seq = 1, watched = True }
            , test "every unspent die carries a tumbling reel of five other faces" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                -- The dice that were thrown: at most the two
                                -- of the roll itself (see the doubles tests).
                                unspent =
                                    Protocol.zoneTokens "dice" u.scene
                                        |> List.filter (\t -> Protocol.tokenProp D.bool "used" t /= Just True)
                                        |> List.length
                                        |> min 2

                                rendered =
                                    View.view (ctx "p1" u watching) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal unspent)
                                , \_ -> rendered |> Query.findAll [ class "die-frame" ] |> Query.count (Expect.equal (unspent * 5))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "a double throws two dice and earns the other two" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" (withDice [ 5, 5, 5, 5 ] u) watching) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "die" ] |> Query.count (Expect.equal 4)
                                , \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered |> Query.findAll [ class "earned" ] |> Query.count (Expect.equal 2)
                                , -- Only what tumbles carries a reel.
                                  \_ -> rendered |> Query.findAll [ class "die-tumble" ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered |> Query.findAll [ class "die-frame" ] |> Query.count (Expect.equal 10)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "an ordinary roll throws both of its dice and earns none" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" (withDice [ 6, 3 ] u) watching) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "die" ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered |> Query.findAll [ class "earned" ] |> Query.count (Expect.equal 0)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "dice this client did not watch land mount settled, with no reel at all" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                -- A join, a reload, a rehydrated room, a
                                -- spectator sitting down mid-turn: the throw
                                -- is over, so there is nothing to play.
                                rendered =
                                    View.view (ctx "p1" (withDice [ 5, 5, 5, 5 ] u) View.init) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "die" ] |> Query.count (Expect.equal 4)
                                , \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 0)
                                , \_ -> rendered |> Query.findAll [ class "earned" ] |> Query.count (Expect.equal 0)
                                , \_ -> rendered |> Query.findAll [ class "die-tumble" ] |> Query.count (Expect.equal 0)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "the roll the client did watch is the only one that moves" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                -- The same payload, once as a snapshot and
                                -- once with the event that carried it.
                                snapshot =
                                    View.view (ctx "p1" (withDice [ 6, 3 ] u) View.init) |> Query.fromHtml

                                live =
                                    View.view (ctx "p1" (withDice [ 6, 3 ] u) watching) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> snapshot |> Query.hasNot [ class "die-tumble" ]
                                , \_ -> live |> Query.has [ class "die-tumble" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "the same double reads the same way to a spectator" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                spectated =
                                    withDice [ 5, 5, 5, 5 ] u

                                rendered =
                                    View.view
                                        (ctx "" { spectated | legal = [], scene = asSpectator spectated.scene } watching)
                                        |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered |> Query.findAll [ class "earned" ] |> Query.count (Expect.equal 2)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            ]
        , describe "a clock held by the turn delay"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                withClock moveMs now u =
                    let
                        base =
                            ctx "p1" u View.init
                    in
                    { base
                        | clock =
                            Just
                                { enabled = True
                                , label = "3 min + 2 s, 12 s delay every turn"
                                , timedOut = Nothing
                                , players =
                                    [ { id = "p1", remainingMs = 180000, moveMs = moveMs, running = True }
                                    , { id = "p2", remainingMs = 180000, moveMs = 0, running = False }
                                    ]
                                }
                        , receivedAt = 0
                        , now = now
                    }
             in
             [ test "the delay counts down beside the frozen clock" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            -- One in the player's bar (phones), one in the
                            -- desktop rail: both say the same thing.
                            View.view (withClock 12000 3000 u)
                                |> Query.fromHtml
                                |> Query.findAll [ class "delay-pip" ]
                                |> Query.each (Query.has [ text "+9" ])

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "once the delay is spent the clock is plain again" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (withClock 12000 12001 u)
                                |> Query.fromHtml
                                |> Query.hasNot [ class "delay-pip" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "rendering fixtures" (List.map perFixture (FixtureLoader.byGame "backgammon"))
        ]


{-| A `move` schema as the engine sends it: from, to and the die it spends.
-}
moveSchema : String -> String -> Int -> Schema
moveSchema from to die =
    { name = "move"
    , label = from ++ " → " ++ to ++ " (" ++ String.fromInt die ++ ")"
    , params =
        [ { name = "from", kind = Choice [ ( from, from ) ] }
        , { name = "to", kind = Choice [ ( to, to ) ] }
        , { name = "die", kind = Choice [ ( String.fromInt die, String.fromInt die ) ] }
        ]
    }


{-| A scene with one entry of its `data` replaced: the states the renderer
must show are easier to name here than to hunt for in a playout.
-}
withData : String -> E.Value -> Protocol.Scene -> Protocol.Scene
withData field value scene =
    let
        existing =
            D.decodeValue (D.dict D.value) scene.data |> Result.withDefault Dict.empty
    in
    { scene | data = E.dict identity identity (Dict.insert field value existing) }


{-| An update whose dice zone holds exactly these faces, numbered the way
the projection numbers them (`die:0` upwards, the pair a double earns
last). None of them spent: this is the roll as it lands.
-}
withDice : List Int -> Protocol.Update -> Protocol.Update
withDice faces update =
    let
        token index value =
            { id = "die:" ++ String.fromInt index
            , kind = "die"
            , faceUp = True
            , position = Nothing
            , props =
                E.object
                    [ ( "value", E.int value )
                    , ( "used", E.bool False )
                    , ( "picked", E.bool False )
                    ]
            }

        dice =
            List.indexedMap token faces

        zones =
            List.map
                (\zone ->
                    if zone.id == "dice" then
                        { zone | tokens = dice, count = List.length dice }

                    else
                        zone
                )
                update.scene.zones

        scene =
            update.scene
    in
    { update | scene = { scene | zones = zones } }


{-| The same scene as nobody in particular sees it.
-}
asSpectator : Protocol.Scene -> Protocol.Scene
asSpectator scene =
    { scene | viewer = Nothing }


{-| The roll a client was only told about: whatever is on the board got
there before it was looking.
-}
settled : View.Roll
settled =
    { seq = 0, watched = False }


{-| A client that watched this roll land, which is the only thing that ever
lets the dice move.
-}
watching : View.Model
watching =
    View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] View.init


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
        , test "pressing anywhere on a source point primes a drag whose tap is the old click" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal |> List.any (\f -> f /= "bar"))
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.filter (\f -> f /= "bar") |> List.head |> Maybe.withDefault ""

                                result =
                                    render "p1" u
                                        |> Query.find [ class "bg-point", class "source", attribute (Html.Attributes.title ("Point " ++ from)) ]
                                        |> Event.simulate (Event.custom "pointerdown" (pointerEvent 10 10))
                                        |> Event.toResult
                            in
                            case result of
                                Ok (DragPressed p) ->
                                    Expect.equal ( from, Just (SelectFrom from) ) ( p.origin, p.tap )

                                _ ->
                                    Expect.fail "pointerdown on a source point should prime a drag press"
                        )
                    |> Maybe.withDefault Expect.pass
        , test "the cube is a fixture exactly when the format has one, and the bar one column" <|
            \_ ->
                p1Views
                    |> List.map
                        (\u ->
                            let
                                rendered =
                                    render "p1" u

                                cubes =
                                    if cubeEnabled u then
                                        1

                                    else
                                        0
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "cube" ] |> Query.count (Expect.equal cubes)
                                , \_ -> rendered |> Query.findAll [ class "bg-bar" ] |> Query.count (Expect.equal 1)
                                ]
                                ()
                        )
                    |> allPass
        , test "a centred cube shows 64" <|
            \_ ->
                p1Views
                    |> List.filter cubeEnabled
                    |> List.head
                    |> Maybe.map (\u -> render "p1" u |> Query.find [ class "cube" ] |> Query.has [ text "64" ])
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
        , test "mid-drag, a ghost rides the pointer and translucent checkers mark the destinations, without boxes" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal /= [])
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.head |> Maybe.withDefault ""

                                dests =
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
                                        |> unique

                                model =
                                    View.init
                                        |> View.update (DragPressed { origin = from, color = "white", tap = Nothing, targets = [], plans = [], x = 0, y = 0 })
                                        |> Tuple.first
                                        |> View.update (DragMoved { x = 40, y = 40 })
                                        |> Tuple.first

                                rendered =
                                    View.view (ctx "p1" u model) |> Query.fromHtml
                            in
                            -- every one-die destination has a ghost; the
                            -- points several dice reach (checked in "one
                            -- checker, several dice") may add a few more.
                            Expect.all
                                [ \_ -> rendered |> Query.has [ class "bg-drag-ghost" ]
                                , \_ -> rendered |> Query.findAll [ class "drop-ghost" ] |> Query.count (Expect.atLeast (List.length dests))
                                , \_ ->
                                    dests
                                        |> List.map (\to -> rendered |> Query.find [ id (View.dropZoneId to) ] |> Query.has [ class "drop-ghost" ])
                                        |> allPass
                                , \_ -> rendered |> Query.findAll [ class "target" ] |> Query.count (Expect.equal 0)
                                ]
                                ()
                        )
                    |> Maybe.withDefault Expect.pass
        , test "after selecting a source, only the next die's landing shows a ghost checker" <|
            \_ ->
                p1Views
                    |> List.filter (\u -> legalFroms u.legal |> List.any (\f -> f /= "bar"))
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            let
                                from =
                                    legalFroms u.legal |> List.filter (\f -> f /= "bar") |> List.head |> Maybe.withDefault ""

                                -- the first unused die of the roll, as it sits on the board
                                nextDie =
                                    Protocol.zoneTokens "dice" u.scene
                                        |> List.filter (\tok -> Protocol.tokenProp D.bool "used" tok /= Just True)
                                        |> List.filterMap (Protocol.tokenProp D.int "value")
                                        |> List.head

                                destinations =
                                    u.legal
                                        |> List.filter (\s -> s.name == "move")
                                        |> List.filter (\s -> List.any (\p -> p.name == "from" && p.kind == Choice [ ( from, from ) ]) s.params)
                                        |> List.filter (\s -> List.any (\p -> p.name == "die" && Just p.kind == Maybe.map (\d -> Choice [ ( String.fromInt d, String.fromInt d ) ]) nextDie) s.params)
                                        |> List.length
                                        |> min 1
                            in
                            View.view (ctx "p1" u { selectedFrom = Just from, drag = Drag.idle, plans = [], rotation = 0, autoRolled = False, picker = Nothing, roll = settled })
                                |> Query.fromHtml
                                |> Query.findAll [ class "drop-ghost" ]
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


cubeEnabled : Protocol.Update -> Bool
cubeEnabled u =
    Protocol.sceneData (D.field "enabled" D.bool) "cube" u.scene |> Maybe.withDefault False


{-| A full PointerEvent payload, everything the library's decoder reads.
-}
pointerEvent : Float -> Float -> E.Value
pointerEvent x y =
    E.object
        [ ( "pointerId", E.int 1 )
        , ( "isPrimary", E.bool True )
        , ( "pointerType", E.string "mouse" )
        , ( "width", E.float 1 )
        , ( "height", E.float 1 )
        , ( "pressure", E.float 0 )
        , ( "tiltX", E.float 0 )
        , ( "tiltY", E.float 0 )
        , ( "altKey", E.bool False )
        , ( "ctrlKey", E.bool False )
        , ( "metaKey", E.bool False )
        , ( "shiftKey", E.bool False )
        , ( "button", E.int 0 )
        , ( "clientX", E.float x )
        , ( "clientY", E.float y )
        , ( "offsetX", E.float x )
        , ( "offsetY", E.float y )
        , ( "pageX", E.float x )
        , ( "pageY", E.float y )
        , ( "screenX", E.float x )
        , ( "screenY", E.float y )
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
