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
            [ test "playing a move sends it and leaves the model as it started" <|
                \_ ->
                    View.update (PlayMove "13" "8") View.init
                        |> Expect.equal ( View.init, Send (Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ]) )
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
            , test "picking a board is reported to the app and sends nothing to the room" <|
                \_ ->
                    View.update ToggleThemes View.init
                        |> Tuple.first
                        |> View.update (PickTheme "midnight")
                        |> Expect.equal ( View.init, ChoseTheme "midnight" )
            ]
        , describe "destination-first tap resolution"
            (let
                base =
                    { moves = []
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
             , test "a point that is also one of my movable origins plays the origin instead" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "8", to = "5", die = 3 }, { from = "13", to = "8", die = 5 } ]
                            , sources = [ "8", "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "8"
                        |> Expect.equal (Just (PlayMove "8" "5"))
             , test "three moves landing on the same point are ambiguous" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "9", die = 4 }, { from = "11", to = "9", die = 2 }, { from = "12", to = "9", die = 3 } ]
                            , unusedDice = [ 4, 2 ]
                        }
                        "9"
                        |> Expect.equal Nothing
             , test "a tap on one of my origins plays it with the next die" <|
                \_ ->
                    -- dice 5 then 3, both unused: the 5 goes first
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "10", die = 3 }, { from = "13", to = "8", die = 5 } ]
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
                            | moves = [ { from = "13", to = "10", die = 3 } ]
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
                            | moves = [ { from = "13", to = "10", die = 3 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 5, 3 ]
                        }
                        "13"
                        |> Expect.equal (Just (PlayMove "13" "10"))
             , test "the dice as rotated decide which die plays" <|
                \_ ->
                    -- a tap on the dice put the 3 first
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "10", die = 3 }, { from = "13", to = "8", die = 5 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 3, 5 ]
                        }
                        "13"
                        |> Expect.equal (Just (PlayMove "13" "10"))
             , test "an origin no die can play (the schema named no dice) does nothing" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "8", die = 5 } ]
                            , sources = [ "13" ]
                            , unusedDice = [ 3 ]
                        }
                        "13"
                        |> Expect.equal Nothing
             , test "one tap plays from the bar too" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "bar", to = "21", die = 4 }, { from = "bar", to = "23", die = 2 } ]
                            , sources = [ "bar" ]
                            , unusedDice = [ 2, 4 ]
                        }
                        "bar"
                        |> Expect.equal (Just (PlayMove "bar" "23"))
             , test "a tap on another origin plays that one, not a move between them" <|
                \_ ->
                    View.resolveTap
                        { base
                            | moves = [ { from = "13", to = "8", die = 5 }, { from = "6", to = "2", die = 4 } ]
                            , sources = [ "13", "6" ]
                            , unusedDice = [ 5, 4 ]
                        }
                        "6"
                        |> Expect.equal (Just (PlayMove "6" "2"))
             ]
            )
        , describe "one checker, several dice"
            (let
                base =
                    { moves = []
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
             , test "a tap on a point several dice away is not a move: only a drag reaches it" <|
                \_ ->
                    View.resolveTap both "5"
                        |> Expect.equal Nothing
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
                    { origin = "13", color = "white", tap = Just (PlayMove "13" "8"), targets = [ "8" ], plans = [], x = 100, y = 100 }

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
             , test "a release under the threshold resolves the stored tap: the move plays" <|
                \_ ->
                    View.update (DragPressed press) View.init
                        |> step (DragMoved { x = 104, y = 103 })
                        |> step (DragReleased { x = 104, y = 103 })
                        |> Expect.equal ( View.init, Send (Protocol.encodeAction "move" [ ( "from", E.string "13" ), ( "to", E.string "8" ) ]) )
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
                            ( { drag = Drag.idle, plans = [], swaps = 0, autoRolled = True, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }
                            , Just (Protocol.encodeAction "roll" [])
                            )
             , test "the same state never rolls twice" <|
                \_ ->
                    View.autoRoll [ schema "roll" ] { drag = Drag.idle, plans = [], swaps = 0, autoRolled = True, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }
                        |> Expect.equal ( { drag = Drag.idle, plans = [], swaps = 0, autoRolled = True, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }, Nothing )
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
                    View.autoRoll [ schema "move" ] { drag = Drag.idle, plans = [], swaps = 0, autoRolled = True, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }
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
                        |> Expect.equal ( { drag = Drag.idle, plans = [], swaps = 0, autoRolled = False, picker = Just [ 3 ], resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }, NoOut )
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
        , describe "resigning is an offer of stakes"
            (let
                schema name label =
                    { name = name, label = label, params = [] }

                resignSchema options =
                    { name = "resign", label = "Resign", params = [ { name = "stakes", kind = Choice options } ] }

                allStakes =
                    [ ( "single", "Single" ), ( "gammon", "Gammon" ), ( "backgammon", "Backgammon" ) ]

                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                offerFrom from =
                    withData "resign_offer" (E.object [ ( "from", E.string from ), ( "stakes", E.string "gammon" ), ( "points", E.int 4 ) ])
             in
             [ test "RESIGN opens the panel and a choice sends the stakes" <|
                \_ ->
                    let
                        ( opened, out1 ) =
                            View.update OpenResign View.init

                        ( sent, out2 ) =
                            View.update (OfferResign "gammon") opened
                    in
                    Expect.all
                        [ \_ -> Expect.equal True opened.resigning
                        , \_ -> Expect.equal NoOut out1
                        , \_ -> Expect.equal False sent.resigning
                        , \_ -> Expect.equal (Send (Protocol.encodeAction "resign" [ ( "stakes", E.string "gammon" ) ])) out2
                        ]
                        ()
             , test "cancel closes the panel without sending" <|
                \_ ->
                    View.update OpenResign View.init
                        |> Tuple.first
                        |> View.update CancelResign
                        |> Expect.equal ( View.init, NoOut )
             , test "the panel offers exactly the stakes the schema carries" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                model =
                                    View.update OpenResign View.init |> Tuple.first

                                render legal =
                                    View.view (ctx "p1" { u | legal = legal } model) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> render [ schema "roll" "Roll", resignSchema allStakes ] |> Query.has [ id "bg-resign-panel" ]
                                , \_ -> render [ schema "roll" "Roll", resignSchema allStakes ] |> Query.findAll [ tag "button", attribute (Html.Attributes.id "bg-resign-backgammon") ] |> Query.count (Expect.equal 1)
                                , \_ -> render [ schema "roll" "Roll", resignSchema allStakes ] |> Query.has [ id "bg-resign-cancel" ]

                                -- Jacoby, centred cube: a single is all there is
                                , \_ -> render [ resignSchema [ ( "single", "Single" ) ] ] |> Query.findAll [ tag "button", attribute (Html.Attributes.id "bg-resign-single") ] |> Query.count (Expect.equal 1)
                                , \_ -> render [ resignSchema [ ( "single", "Single" ) ] ] |> Query.hasNot [ id "bg-resign-gammon" ]

                                -- and no panel at all once resign stops being legal (an offer is pending)
                                , \_ -> render [ schema "accept_resign" "Accept gammon" ] |> Query.hasNot [ id "bg-resign-panel" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the opponent answers from the band, the stakes in the label" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" { u | legal = [ schema "accept_resign" "Accept gammon", schema "decline_resign" "Decline" ], scene = offerFrom "p2" u.scene } View.init)
                                        |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.find [ id "bg-action-accept_resign" ] |> Query.has [ text "ACCEPT GAMMON" ]
                                , \_ -> rendered |> Query.find [ id "bg-action-decline_resign" ] |> Query.has [ text "DECLINE" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-resign-open" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-resign-pending" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the resigner sees their offer standing and nothing to press" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" { u | legal = [], scene = offerFrom "p1" u.scene } View.init)
                                        |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.find [ id "bg-resign-pending" ] |> Query.has [ text "RESIGNATION OFFERED (GAMMON)…" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-resign-open" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-action-accept_resign" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "between the games of a match"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                ready =
                    { name = "ready", label = "Ready", params = [] }

                -- p1 has just won a gammon; `readyIds` have said they are ready
                between readyIds u =
                    let
                        scene =
                            u.scene
                                |> withData "between_games"
                                    (E.object
                                        [ ( "ready", E.list E.string readyIds )
                                        , ( "winner", E.string "p1" )
                                        , ( "kind", E.string "gammon" )
                                        , ( "stakes", E.string "gammon" )
                                        , ( "points", E.int 2 )
                                        , ( "cube", E.int 1 )
                                        ]
                                    )
                                |> withData "to_act" E.null
                                |> withData "to_move" E.null
                    in
                    { u | scene = { scene | phase = "between_games" } }

                render viewer legal u =
                    View.view (ctx viewer { u | legal = legal } View.init) |> Query.fromHtml

                withFixture check =
                    case firstUpdate of
                        Just u ->
                            check u

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             in
             [ test "the band shows the result, the score and READY" <|
                \_ ->
                    withFixture
                        (\u ->
                            let
                                rendered =
                                    render "p1" [ ready ] (between [] u)
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.find [ id "bg-game-result" ] |> Query.has [ text "YOU WIN +2" ]
                                , \_ -> rendered |> Query.find [ id "bg-game-result" ] |> Query.has [ text "GAMMON · 0-0" ]

                                -- the game just played can be replayed from here
                                , \_ -> rendered |> Query.find [ id "bg-game-result" ] |> Query.find [ class "bg-replay-link" ] |> Query.has [ text "REPLAY" ]
                                , \_ -> rendered |> Query.find [ id "bg-action-ready" ] |> Query.has [ text "READY" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-ready-status" ]

                                -- the final position is only to look at
                                , \_ -> rendered |> Query.hasNot [ id "dice-row" ]
                                , \_ -> rendered |> Query.hasNot [ id "bg-resign-open" ]
                                ]
                                ()
                        )
             , test "READY sends the ready action" <|
                \_ ->
                    withFixture
                        (\u ->
                            render "p1" [ ready ] (between [] u)
                                |> Query.find [ id "bg-action-ready" ]
                                |> Event.simulate Event.click
                                |> Event.expect (Simple "ready")
                        )
             , test "after pressing it, the player waits for the opponent" <|
                \_ ->
                    withFixture
                        (\u ->
                            let
                                opponent =
                                    Protocol.opponentOf "p1" u.scene |> Maybe.map (.name >> String.toUpper) |> Maybe.withDefault "?"

                                rendered =
                                    render "p1" [] (between [ "p1" ] u)
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.hasNot [ id "bg-action-ready" ]
                                , \_ -> rendered |> Query.find [ id "bg-ready-status" ] |> Query.has [ text ("WAITING FOR " ++ opponent) ]
                                ]
                                ()
                        )
             , test "the other player sees that the opponent is ready, and still has READY" <|
                \_ ->
                    withFixture
                        (\u ->
                            let
                                opponent =
                                    Protocol.opponentOf "p2" u.scene |> Maybe.map (.name >> String.toUpper) |> Maybe.withDefault "?"

                                rendered =
                                    render "p2" [ ready ] (between [ "p1" ] u)
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.find [ id "bg-game-result" ] |> Query.has [ text "P1 WINS +2" ]
                                , \_ -> rendered |> Query.has [ id "bg-action-ready" ]
                                , \_ -> rendered |> Query.find [ id "bg-ready-status" ] |> Query.has [ text (opponent ++ " IS READY") ]
                                ]
                                ()
                        )
             , test "a spectator reads who is ready and has nothing to press" <|
                \_ ->
                    withFixture
                        (\u ->
                            let
                                paused =
                                    between [ "p2" ] u

                                rendered =
                                    render "spectator" [] { paused | scene = asSpectator paused.scene }
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.hasNot [ id "bg-action-ready" ]
                                , \_ -> rendered |> Query.find [ id "bg-ready-status" ] |> Query.has [ text "P2 IS READY" ]
                                , \_ -> rendered |> Query.find [ id "bg-game-result" ] |> Query.has [ text "P1 WINS +2" ]
                                ]
                                ()
                        )
             ]
            )
        , describe "the board picker"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                opened =
                    View.update ToggleThemes View.init |> Tuple.first

                themed name update model =
                    let
                        base =
                            ctx "p1" update model
                    in
                    { base | theme = name }
             in
             [ test "the page wears the board it was given" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (themed "forest" u View.init)
                                |> Query.fromHtml
                                |> Query.has [ class "bg-page", class "bg-theme-forest" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the default board is midnight, the home page's" <|
                \_ -> Expect.equal "midnight" View.defaultTheme
             , test "a board this release does not know falls back to the default" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (themed "burlwood" u View.init)
                                |> Query.fromHtml
                                |> Query.has [ class "bg-theme-midnight" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the list is closed until the control is tapped, then lists every board" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ ->
                                    View.view (ctx "p1" u View.init)
                                        |> Query.fromHtml
                                        |> Query.hasNot [ id "bg-theme-list" ]
                                , \_ ->
                                    View.view (ctx "p1" u opened)
                                        |> Query.fromHtml
                                        |> Query.has [ id "bg-theme-list" ]
                                , \_ ->
                                    View.view (ctx "p1" u opened)
                                        |> Query.fromHtml
                                        |> Query.findAll [ class "bg-theme-option" ]
                                        |> Query.count (Expect.equal (List.length View.themes))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a viewer with nothing legal still gets the picker" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (ctx "p2" { u | legal = [] } View.init)
                                |> Query.fromHtml
                                |> Query.has [ id "bg-theme-button" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             ]
            )
        , describe "the player bars"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                on : (View.Ctx -> View.Ctx) -> (Query.Single Msg -> Expect.Expectation) -> Expect.Expectation
                on build check =
                    case firstUpdate of
                        Just u ->
                            check (View.view (build (ctx "p1" u View.init)) |> Query.fromHtml)

                        Nothing ->
                            Expect.fail "no backgammon fixture"

                cubeOwnedBy owner c =
                    { c
                        | scene =
                            withData "cube"
                                (E.object
                                    [ ( "enabled", E.bool True )
                                    , ( "value", E.int 2 )
                                    , ( "owner", E.string owner )
                                    , ( "pending_from", E.null )
                                    , ( "crawford", E.bool False )
                                    ]
                                )
                                c.scene
                    }
             in
             [ test "no YOU tag: the reader's own bar is simply the one they sit at" <|
                \_ -> on identity (Query.hasNot [ text "YOU" ])
             , test "no CUBE tag: the cube hangs at its owner's end and its title says so" <|
                \_ ->
                    on (cubeOwnedBy "p2")
                        (Expect.all
                            [ Query.hasNot [ text "CUBE" ]
                            , Query.has
                                [ class "cube"
                                , attribute (Html.Attributes.title "Doubling cube: p2 owns it")
                                ]
                            ]
                        )
             , test "a centred cube says so too, rather than naming an owner" <|
                \_ ->
                    on
                        (\c ->
                            { c
                                | scene =
                                    withData "cube"
                                        (E.object
                                            [ ( "enabled", E.bool True )
                                            , ( "value", E.int 1 )
                                            , ( "owner", E.null )
                                            , ( "pending_from", E.null )
                                            , ( "crawford", E.bool False )
                                            ]
                                        )
                                        c.scene
                            }
                        )
                        (Query.has
                            [ class "cube"
                            , attribute (Html.Attributes.title "Doubling cube: centred, either player may double")
                            ]
                        )
             , test "both players connected: two lit dots, no wording" <|
                \_ ->
                    on (\c -> { c | away = Just [] })
                        (Expect.all
                            [ \q -> Query.findAll [ classes [ "bar-dot", "on" ] ] q |> Query.count (Expect.equal 2)
                            , \q -> Query.findAll [ classes [ "bar-dot", "off" ] ] q |> Query.count (Expect.equal 0)
                            , Query.hasNot [ text "AWAY" ]
                            ]
                        )
             , test "a drop flashes first: most of them come straight back" <|
                \_ ->
                    on (\c -> { c | away = Just [ "p2" ], awaySince = \_ -> Just 0, now = 4000 })
                        (Expect.all
                            [ \q -> Query.findAll [ classes [ "bar-dot", "on" ] ] q |> Query.count (Expect.equal 1)
                            , \q -> Query.findAll [ classes [ "bar-dot", "off" ] ] q |> Query.count (Expect.equal 0)
                            , \q ->
                                Query.find [ classes [ "bar-dot", "lost" ] ] q
                                    |> Query.has [ attribute (Html.Attributes.title "Connection lost a moment ago") ]
                            ]
                        )
             , test "an absence that outlasts the flash settles to the pale dot" <|
                \_ ->
                    on (\c -> { c | away = Just [ "p2" ], awaySince = \_ -> Just 0, now = View.presenceFlashMs + 1 })
                        (Expect.all
                            [ \q -> Query.findAll [ classes [ "bar-dot", "lost" ] ] q |> Query.count (Expect.equal 0)
                            , \q ->
                                Query.find [ classes [ "bar-dot", "off" ] ] q
                                    |> Query.has [ attribute (Html.Attributes.title "Connection lost") ]
                            ]
                        )
             , test "the flash runs from the drop, not from the render" <|
                \_ ->
                    -- The same absence, two renders a second apart: what
                    -- decides is how long ago it was noticed.
                    Expect.all
                        [ \_ ->
                            on (\c -> { c | away = Just [ "p2" ], awaySince = \_ -> Just 10000, now = 11000 })
                                (Query.has [ classes [ "bar-dot", "lost" ] ])
                        , \_ ->
                            on (\c -> { c | away = Just [ "p2" ], awaySince = \_ -> Just 10000, now = 16000 })
                                (Query.has [ classes [ "bar-dot", "off" ] ])
                        ]
                        ()
             , test "a player who comes back is steady green again" <|
                \_ ->
                    -- Still noted as having dropped once, but no longer away.
                    on (\c -> { c | away = Just [], awaySince = \_ -> Just 0, now = 1000 })
                        (\q -> Query.findAll [ classes [ "bar-dot", "on" ] ] q |> Query.count (Expect.equal 2))
             , test "where presence is not a fact at all, no dot is drawn" <|
                \_ ->
                    on (\c -> { c | away = Nothing })
                        (\q -> Query.findAll [ class "bar-dot" ] q |> Query.count (Expect.equal 0))
             , test "a player with a match PR wears it beside their name" <|
                \_ ->
                    on
                        (\c ->
                            { c
                                | prOf =
                                    \id ->
                                        if id == "p1" then
                                            Just 8.4

                                        else
                                            Nothing
                            }
                        )
                        (Expect.all
                            [ Query.has [ class "bar-pr", text "Match PR: ", text "8.4" ]
                            , \q -> Query.findAll [ class "bar-pr" ] q |> Query.count (Expect.equal 1)
                            ]
                        )
             , test "a whole number still reads with its decimal" <|
                \_ ->
                    on (\c -> { c | prOf = \_ -> Just 8.0 })
                        (Query.has [ class "bar-pr", text "8.0" ])
             , test "no graded game of this match, nobody wearing a PR" <|
                \_ ->
                    on (\c -> { c | prOf = \_ -> Nothing })
                        (\q -> Query.findAll [ class "bar-pr" ] q |> Query.count (Expect.equal 0))
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

                model swaps =
                    { drag = Drag.idle, plans = [], swaps = swaps, autoRolled = False, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False }

                rendered swaps u =
                    View.view (ctx "p1" (twoDice u) (model swaps)) |> Query.fromHtml

                nextDie swaps u =
                    rendered swaps u |> Query.find [ class "die", class "next" ]

                dieAt slot swaps u =
                    rendered swaps u |> Query.find [ class "die", class ("slot-" ++ String.fromInt slot) ]

                isDie id =
                    Query.has [ attribute (Html.Attributes.attribute "data-die" id) ]
             in
             [ test "a tap on the dice swaps them and touches nothing else" <|
                \_ ->
                    View.update SwapDice (model 0)
                        |> Expect.equal ( model 1, NoOut )
             , test "a tap on a checker plays the die that stands up" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                -- 6 and 4, both playable from 13: as thrown
                                -- the 6 plays, once swapped the 4 does
                                bothPlay =
                                    { u | legal = [ { name = "play", label = "Play", params = [] }, moveSchema "13" "7" 6, moveSchema "13" "9" 4 ] }

                                tapOn13 swaps =
                                    View.view (ctx "p1" (twoDice bothPlay) (model swaps))
                                        |> Query.fromHtml
                                        |> Query.find [ class "bg-point", class "source", attribute (Html.Attributes.title "Point 13") ]
                                        |> Event.simulate (Event.custom "pointerdown" (pointerEvent 10 10))
                                        |> Event.toResult
                                        |> Result.toMaybe
                                        |> Maybe.andThen
                                            (\msg ->
                                                case msg of
                                                    DragPressed p ->
                                                        p.tap

                                                    _ ->
                                                        Nothing
                                            )
                            in
                            Expect.all
                                [ \_ -> tapOn13 0 |> Expect.equal (Just (PlayMove "13" "7"))
                                , \_ -> tapOn13 1 |> Expect.equal (Just (PlayMove "13" "9"))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the next die is the left one: as thrown, then the other once swapped, then back" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ -> nextDie 0 u |> isDie "die:0"
                                , \_ -> dieAt 0 0 u |> isDie "die:0"
                                , \_ -> dieAt 1 0 u |> isDie "die:1"
                                , \_ -> nextDie 1 u |> isDie "die:1"
                                , \_ -> dieAt 0 1 u |> isDie "die:1"
                                , \_ -> dieAt 1 1 u |> isDie "die:0"
                                , \_ -> nextDie 2 u |> isDie "die:0"
                                , \_ -> dieAt 0 2 u |> isDie "die:0"
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a swap never moves a die in the DOM: the children keep their thrown order, only slots change" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                firstChild swaps =
                                    rendered swaps u |> Query.findAll [ class "die" ] |> Query.index 0
                            in
                            Expect.all
                                [ \_ -> firstChild 0 |> isDie "die:0"
                                , \_ -> firstChild 1 |> isDie "die:0"
                                , \_ -> firstChild 2 |> isDie "die:0"
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a swap slides and never re-rolls: the reels are as they were, and the slide class alternates per tap" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                live swaps =
                                    View.view (ctx "p1" (twoDice u) { watching | swaps = swaps }) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> live 0 |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> live 1 |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> live 1 |> Query.findAll [ class "die-tumble" ] |> Query.count (Expect.equal 2)
                                , \_ -> live 0 |> Query.hasNot [ class "slid-a" ]
                                , \_ -> live 0 |> Query.hasNot [ class "slid-b" ]
                                , \_ -> live 1 |> Query.findAll [ class "slid-a" ] |> Query.count (Expect.equal 2)
                                , \_ -> live 1 |> Query.hasNot [ class "slid-b" ]
                                , \_ -> live 2 |> Query.findAll [ class "slid-b" ] |> Query.count (Expect.equal 2)
                                , \_ -> live 2 |> Query.hasNot [ class "slid-a" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the mover's dice are a control; the other player's are not" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            Expect.all
                                [ \_ -> View.view (ctx "p1" (twoDice u) (model 0)) |> Query.fromHtml |> Query.has [ class "dice-row", class "swaps" ]
                                , \_ -> View.view (ctx "p2" { u | legal = [] } View.init) |> Query.fromHtml |> Query.hasNot [ class "swaps" ]
                                , \_ -> View.view (ctx "p2" { u | legal = [] } View.init) |> Query.fromHtml |> Query.hasNot [ class "next" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a double is one value: nothing stands out, nothing swaps, no slots" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                four =
                                    View.view (ctx "p1" (withDice [ 3, 3, 3, 3 ] u) (model 1)) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> four |> Query.hasNot [ class "next" ]
                                , \_ -> four |> Query.hasNot [ class "swaps" ]
                                , \_ -> four |> Query.hasNot [ class "slot-0" ]
                                , \_ -> four |> Query.hasNot [ class "slid-a" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "one die left is no choice either" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            View.view (ctx "p1" (withDice [ 4 ] u) (model 0))
                                |> Query.fromHtml
                                |> Query.hasNot [ class "swaps" ]

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a new roll starts unswapped" <|
                \_ ->
                    View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] (model 3)
                        |> .swaps
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
                        |> View.update OpenPicker
                        |> Tuple.first
                        |> View.update (PlayMove "13" "8")
                        |> Tuple.first
                        |> .roll
                        |> Expect.equal { seq = 1, watched = True }
            , test "every thrown die carries a tumbling reel of five other faces" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                -- The dice that were thrown: at most the two
                                -- of the roll itself (see the doubles tests).
                                thrown =
                                    Protocol.zoneTokens "dice" u.scene
                                        |> List.length
                                        |> min 2

                                rendered =
                                    View.view (ctx "p1" u watching) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> rendered |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal thrown)
                                , \_ -> rendered |> Query.findAll [ class "die-frame" ] |> Query.count (Expect.equal (thrown * 5))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "a spent die keeps its roll classes and reel, so UNDO is a class-only change" <|
                \_ ->
                    -- The same roll, before a move and with one die staged:
                    -- the die element is the same keyed node either way, and
                    -- its animation markup must not differ, or freeing the
                    -- die again would re-create it and replay the landing.
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                fresh =
                                    View.view (ctx "p1" (withDice [ 6, 3 ] u) watching) |> Query.fromHtml

                                staged =
                                    View.view (ctx "p1" (withUsedDie "die:0" (withDice [ 6, 3 ] u)) watching) |> Query.fromHtml

                                spent =
                                    staged |> Query.find [ class "die", attribute (Html.Attributes.attribute "data-die" "die:0") ]
                            in
                            Expect.all
                                [ \_ -> spent |> Query.has [ class "used" ]
                                , \_ -> spent |> Query.has [ class "rolling" ]
                                , \_ -> spent |> Query.findAll [ class "die-tumble" ] |> Query.count (Expect.equal 1)
                                , \_ -> staged |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> fresh |> Query.findAll [ class "rolling" ] |> Query.count (Expect.equal 2)
                                , \_ -> staged |> Query.findAll [ class "die-frame" ] |> Query.count (Expect.equal 10)
                                , \_ -> fresh |> Query.findAll [ class "die-frame" ] |> Query.count (Expect.equal 10)
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
            , test "a double tumbles like two dice: the reels differ at every frame" <|
                \_ ->
                    case FixtureLoader.byGame "backgammon" |> List.head |> Maybe.andThen (\f -> Dict.get "p1" f.initial) of
                        Just u ->
                            let
                                rendered =
                                    View.view (ctx "p1" (withDice [ 5, 5, 5, 5 ] u) watching) |> Query.fromHtml

                                frame dieId i =
                                    rendered
                                        |> Query.find [ class "die", attribute (Html.Attributes.attribute "data-die" dieId) ]
                                        |> Query.findAll [ class "die-frame" ]
                                        |> Query.index i

                                -- a face is drawn by hiding the pips it does
                                -- not light: face n leaves 9 - n hidden
                                hidden dieId i n =
                                    frame dieId i |> Query.findAll [ class "invisible" ] |> Query.count (Expect.equal (9 - n))
                            in
                            Expect.all
                                [ -- the first frames: die 0 shows a 6, die 1 a 3
                                  \_ -> hidden "die:0" 0 6
                                , \_ -> hidden "die:1" 0 3

                                -- and no frame of the two ever agrees
                                , \_ ->
                                    List.map2 (\a b -> a /= b) (View.tumbleFaces 0 5) (View.tumbleFaces 1 5)
                                        |> List.all identity
                                        |> Expect.equal True
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
            , test "for every value, neither reel shows the landing face and the two never coincide" <|
                \_ ->
                    List.range 1 6
                        |> List.all
                            (\v ->
                                let
                                    a =
                                        View.tumbleFaces 0 v

                                    b =
                                        View.tumbleFaces 1 v
                                in
                                List.all identity (List.map2 (/=) a b)
                                    && not (List.member v a)
                                    && not (List.member v b)
                                    && (List.sort a == List.sort b)
                                    && (List.length a == 5)
                            )
                        |> Expect.equal True
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
        , describe "the record"
            (let
                firstUpdate =
                    FixtureLoader.byGame "backgammon"
                        |> List.head
                        |> Maybe.andThen (\f -> Dict.get "p1" f.initial)

                -- a position: per colour the 24 point counts (point 1 first), bar, off, pips
                side points bar off pips =
                    E.object [ ( "points", E.list E.int points ), ( "bar", E.int bar ), ( "off", E.int off ), ( "pips", E.int pips ) ]

                at spots =
                    List.range 1 24 |> List.map (\p -> spots |> List.filter (\( q, _ ) -> q == p) |> List.map Tuple.second |> List.sum)

                cubeAt value owner =
                    E.object [ ( "value", E.int value ), ( "owner", owner |> Maybe.map E.string |> Maybe.withDefault E.null ) ]

                opening =
                    E.object
                        [ ( "white", side (at [ ( 24, 2 ), ( 13, 5 ), ( 8, 3 ), ( 6, 5 ) ]) 0 0 167 )
                        , ( "black", side (at [ ( 1, 2 ), ( 12, 5 ), ( 17, 3 ), ( 19, 5 ) ]) 0 0 167 )
                        , ( "cube", cubeAt 1 Nothing )
                        ]

                -- white: two on its 24 point, thirteen off; black: three on the bar, twelve on point 1;
                -- the cube on 4, black's
                endgame =
                    E.object
                        [ ( "white", side (at [ ( 24, 2 ) ]) 0 13 48 )
                        , ( "black", side (at [ ( 1, 12 ) ]) 3 0 363 )
                        , ( "cube", cubeAt 4 (Just "p2") )
                        ]

                turnAt position player dice moves =
                    E.object
                        [ ( "kind", E.string "turn" )
                        , ( "player", E.string player )
                        , ( "dice", E.list E.int dice )
                        , ( "picked", E.bool False )
                        , ( "moves", E.list E.string moves )
                        , ( "landed", E.list E.int [] )
                        , ( "position", position )
                        ]

                turn =
                    turnAt opening

                cube kind player extra =
                    E.object ([ ( "kind", E.string kind ), ( "player", E.string player ) ] ++ extra)

                gameOver number winner result points scores =
                    E.object
                        [ ( "kind", E.string "game_over" )
                        , ( "number", E.int number )
                        , ( "winner", E.string winner )
                        , ( "result", E.string result )
                        , ( "points", E.int points )
                        , ( "cube", E.int 1 )
                        , ( "scores", E.object (List.map (Tuple.mapSecond E.int) scores) )
                        ]

                -- a match to 3: game 1 was a gammon after a take
                gameOne =
                    [ turn "p1" [ 3, 1 ] [ "8/5*", "6/5" ]
                    , turn "p2" [ 6, 5 ] []
                    , cube "double" "p1" [ ( "value", E.int 2 ) ]
                    , cube "take" "p2" []
                    , turn "p1" [ 4, 4 ] [ "13/9(2)", "24/20(2)" ]
                    , gameOver 1 "p1" "gammon" 4 [ ( "p1", 4 ), ( "p2", 0 ) ]
                    ]

                -- game 1 while it was being played: everything but its result
                gameOneLive =
                    E.list identity (List.take 5 gameOne)

                -- and game 2 on the board: the scene has its one turn and game 1's result
                gameTwo =
                    E.list identity [ turn "p2" [ 2, 1 ] [ "bar/23", "6/5" ] ]

                -- the room is playing a match: only a match has a history
                -- of finished games and per-game headings
                inMatch u =
                    { u | scene = u.scene |> withData "target" (E.int 3) }

                inGameTwo u =
                    withRecord gameTwo 2 u
                        |> withGames (E.list identity [ gameOver 1 "p1" "gammon" 4 [ ( "p1", 4 ), ( "p2", 0 ) ] ])
                        |> inMatch

                -- what the room's /record answers: both games
                archive =
                    E.object
                        [ ( "games"
                          , E.list identity
                                [ E.object [ ( "number", E.int 1 ), ( "entries", E.list identity gameOne ) ]
                                , E.object [ ( "number", E.int 2 ), ( "entries", gameTwo ) ]
                                ]
                          )
                        ]

                withRecord record gameNumber u =
                    { u
                        | scene =
                            u.scene
                                |> withData "record" record
                                |> withData "game_number" (E.int gameNumber)
                    }

                withGames games u =
                    { u | scene = u.scene |> withData "games" games }

                render playerId u =
                    View.view (ctx playerId u View.init) |> Query.fromHtml

                -- a turn that landed a checker on each of `points` (the position is only drawn when viewed)
                landedTurn player points =
                    E.object
                        [ ( "kind", E.string "turn" )
                        , ( "player", E.string player )
                        , ( "dice", E.list E.int [ 3, 1 ] )
                        , ( "picked", E.bool False )
                        , ( "moves", E.list E.string [ "8/5", "6/5" ] )
                        , ( "landed", E.list E.int points )
                        , ( "position", opening )
                        ]

                -- what /record answers, from (number, entries) pairs
                archiveOf games =
                    E.object [ ( "games", E.list (\( n, entries ) -> E.object [ ( "number", E.int n ), ( "entries", E.list identity entries ) ]) games ) ]

                colourOf id u =
                    Protocol.findPlayer id u.scene |> Maybe.andThen (Protocol.playerData D.string "color") |> Maybe.withDefault "white"

                -- the points of the live board holding checkers of this colour
                pointsOfColour colour u =
                    u.scene.zones
                        |> List.filter (\z -> String.startsWith "point:" z.id)
                        |> List.filter (\z -> List.any (\t -> Protocol.tokenProp D.string "color" t == Just colour) z.tokens)
                        |> List.filterMap (\z -> String.toInt (String.dropLeft 6 z.id))

                -- the checkers on this point wearing the last turn's ring
                ringedAt point html =
                    html
                        |> Query.find [ id (View.dropZoneId (String.fromInt point)) ]
                        |> Query.findAll [ class "just-moved" ]

                nameOf id u =
                    Protocol.findPlayer id u.scene |> Maybe.map .name |> Maybe.withDefault id
             in
             [ test "a past turn shows the cube as it stood, not as it stands" <|
                \_ ->
                    -- a match fixture, so the cube is in play; live it is centred on 64
                    case FixtureLoader.byGame "backgammon" |> List.filterMap (\f -> Dict.get "p1" f.initial) |> List.filter cubeEnabled |> List.head of
                        Just u ->
                            let
                                u2 =
                                    withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ], turnAt endgame "p2" [ 6, 6 ] [ "6/off(4)" ] ]) 1 u

                                cubeAfter index =
                                    View.update (ViewTurn index) View.init
                                        |> Tuple.first
                                        |> (\m -> View.view (ctx "p1" u2 m))
                                        |> Query.fromHtml
                                        |> Query.find [ class "cube" ]
                            in
                            Expect.all
                                [ \_ -> render "p1" u2 |> Query.find [ class "cube" ] |> Query.has [ text "64" ]
                                , \_ -> cubeAfter 0 |> Query.has [ text "64" ]
                                , \_ -> cubeAfter 1 |> Query.has [ text "4" ]
                                , \_ -> cubeAfter 1 |> Query.hasNot [ text "64" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon match fixture"
             , test "stepping back puts the board a turn left on the slab, drawn from its snapshot" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                -- turn 0 left the opening position, turn 1 the endgame one
                                u2 =
                                    withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ], turnAt endgame "p2" [ 6, 6 ] [ "6/off(4)" ] ]) 1 u

                                ( viewing, out ) =
                                    View.update (ViewTurn 1) View.init

                                board =
                                    View.view (ctx "p1" u2 viewing) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> Expect.equal NoOut out
                                , \_ -> Expect.equal (Just 1) viewing.viewing

                                -- two white checkers on the board, thirteen sticks in the tray
                                , \_ -> board |> Query.findAll [ class "checker", class "white" ] |> Query.count (Expect.equal 2)
                                , \_ -> board |> Query.findAll [ class "off-stick", class "white" ] |> Query.count (Expect.equal 13)

                                -- black: three on the bar, a stack of twelve on point 1 (five drawn, the top one counting 12)
                                , \_ -> board |> Query.findAll [ class "checker", class "black" ] |> Query.count (Expect.equal 8)
                                , \_ -> board |> Query.find [ class "bg-bar" ] |> Query.findAll [ class "checker", class "black" ] |> Query.count (Expect.equal 3)
                                , \_ -> board |> Query.has [ class "checker-count", text "12" ]

                                -- the turn's dice on the board (a double is four, as live), the pips the engine counted
                                , \_ -> board |> Query.findAll [ class "die" ] |> Query.count (Expect.equal 4)
                                , \_ -> board |> Query.has [ text "363 PIPS", text "48 PIPS" ]

                                -- my own past turn's dice are not the live control they would be
                                , \_ ->
                                    View.view (ctx "p2" u2 viewing)
                                        |> Query.fromHtml
                                        |> Query.find [ id "dice-row" ]
                                        |> Query.hasNot [ class "swaps" ]
                                , \_ -> View.view (ctx "p2" u2 viewing) |> Query.fromHtml |> Query.findAll [ class "die", class "next" ] |> Query.count (Expect.equal 0)

                                -- nothing on it is a control: no legal origin, no action button
                                , \_ -> board |> Query.findAll [ class "source" ] |> Query.count (Expect.equal 0)
                                , \_ -> board |> Query.find [ class "bg-board" ] |> Query.findAll [ class "btn-arcade" ] |> Query.count (Expect.equal 0)
                                , \_ -> board |> Query.find [ id "bg-scrub-live" ] |> Event.simulate Event.click |> Event.expect ViewLive

                                -- the arrows under the board are what puts a turn up
                                , \_ ->
                                    View.view (ctx "p1" u2 View.init)
                                        |> Query.fromHtml
                                        |> Query.find [ id "bg-scrub-back" ]
                                        |> Event.simulate Event.click
                                        |> Event.expect (ViewTurn 1)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the live arrow comes back to the game, and blinks when it moved on meanwhile" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                u2 =
                                    withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ] ]) 1 u

                                viewing =
                                    View.update (ViewTurn 0) View.init |> Tuple.first

                                moved =
                                    View.noteEvents [ Protocol.Custom "turn_played" E.null ] viewing

                                quiet =
                                    View.noteEvents [] viewing

                                ( live, _ ) =
                                    View.update ViewLive moved

                                checkers m =
                                    View.view (ctx "p1" u2 m) |> Query.fromHtml |> Query.findAll [ class "checker" ] |> Query.count (Expect.equal 30)
                            in
                            Expect.all
                                [ \_ -> Expect.equal False viewing.stale
                                , \_ -> Expect.equal True moved.stale
                                , \_ -> Expect.equal (Just 0) moved.viewing
                                , \_ -> Expect.equal False quiet.stale
                                , \_ -> View.view (ctx "p1" u2 moved) |> Query.fromHtml |> Query.find [ id "bg-scrub" ] |> Query.has [ class "stale" ]
                                , \_ -> Expect.equal ( Nothing, False ) ( live.viewing, live.stale )
                                , \_ -> checkers live
                                , \_ -> View.view (ctx "p1" u2 live) |> Query.fromHtml |> Query.find [ id "bg-scrub-live" ] |> Query.has [ attribute (Html.Attributes.disabled True) ]

                                -- a live payload never yanks a viewer back by itself
                                , \_ -> View.noteEvents [ Protocol.Custom "dice_rolled" E.null ] viewing |> .viewing |> Expect.equal (Just 0)

                                -- unless the game it was in has ended: its turns left the scene with it
                                , \_ -> View.noteEvents [ Protocol.Custom "new_game" E.null ] viewing |> (\m -> ( m.viewing, m.stale )) |> Expect.equal ( Nothing, False )

                                -- the flag makes its offer on the live board, where the panel can show
                                , \_ -> View.update OpenResign moved |> Tuple.first |> (\m -> ( m.viewing, m.stale, m.resigning )) |> Expect.equal ( Nothing, False, True )
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the game-over card offers the review, which opens on the last turn" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                u2 =
                                    withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ], cube "resign" "p2" [], gameOver 1 "p1" "resigned" 1 [ ( "p1", 1 ), ( "p2", 0 ) ] ]) 1 u

                                over =
                                    { u2 | outcome = Protocol.Finished [ "p1" ] }

                                card =
                                    View.view (ctx "p1" over View.init) |> Query.fromHtml
                            in
                            Expect.all
                                [ \_ -> card |> Query.find [ id "bg-review-moves" ] |> Event.simulate Event.click |> Event.expect (ViewTurn 0)

                                -- and the replay, with its analysis, of the game just played
                                , \_ -> card |> Query.find [ id "bg-replay" ] |> Query.has [ attribute (Html.Attributes.href "/backgammon/123456/replay?t=tok&game=1") ]

                                -- a spectator has no seat to open a replay on
                                , \_ ->
                                    View.view (let c = ctx "p1" over View.init in { c | replayHref = \_ -> Nothing })
                                        |> Query.fromHtml
                                        |> Query.hasNot [ id "bg-replay" ]

                                -- while reviewing, the card is out of the way and LIVE brings it back
                                , \_ ->
                                    View.view (ctx "p1" over (View.update (ViewTurn 0) View.init |> Tuple.first))
                                        |> Query.fromHtml
                                        |> Query.findAll [ text "REMATCH" ]
                                        |> Query.count (Expect.equal 0)
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "live, the ring is the game on the board's last turn, not an earlier game's" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            case pointsOfColour (colourOf "p1" u) u of
                                a :: b :: _ ->
                                    let
                                        -- game 1's last turn landed on a, game 2's (on the board) on b
                                        one =
                                            [ landedTurn "p1" [ a ], gameOver 1 "p1" "single" 1 [ ( "p1", 1 ), ( "p2", 0 ) ] ]

                                        live =
                                            withRecord (E.list identity [ landedTurn "p1" [ b ] ]) 2 u
                                                |> withGames (E.list identity [ gameOver 1 "p1" "single" 1 [ ( "p1", 1 ), ( "p2", 0 ) ] ])

                                        board m =
                                            View.view (ctx "p1" live m) |> Query.fromHtml
                                    in
                                    Expect.all
                                        [ \_ -> board View.init |> ringedAt b |> Query.count (Expect.equal 1)
                                        , \_ -> board View.init |> ringedAt a |> Query.count (Expect.equal 0)
                                        , \_ -> List.length one |> Expect.equal 2
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "p1 has fewer than two points"

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the ring marks only the mover's checkers: a checker that hit the landed blot does not wear it" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            case ( pointsOfColour (colourOf "p1" u) u, pointsOfColour (colourOf "p2" u) u ) of
                                ( mine :: _, theirs :: _ ) ->
                                    let
                                        -- p2's last turn landed on `theirs` and on `mine`, where a
                                        -- checker of p1's (a staged hit, say) now stands
                                        u2 =
                                            withRecord (E.list identity [ landedTurn "p2" [ theirs, mine ] ]) 1 u

                                        board =
                                            View.view (ctx "p1" u2 View.init) |> Query.fromHtml
                                    in
                                    Expect.all
                                        [ \_ -> board |> ringedAt theirs |> Query.count (Expect.equal 1)
                                        , \_ -> board |> ringedAt mine |> Query.count (Expect.equal 0)
                                        ]
                                        ()

                                _ ->
                                    Expect.fail "a colour has no points"

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "a past turn put up between games shows its dice, not the live result" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                paused =
                                    let
                                        scene =
                                            (withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ], gameOver 1 "p1" "gammon" 2 [ ( "p1", 2 ), ( "p2", 0 ) ] ]) 1 u).scene
                                                |> withData "between_games"
                                                    (E.object
                                                        [ ( "ready", E.list E.string [] )
                                                        , ( "winner", E.string "p1" )
                                                        , ( "kind", E.string "gammon" )
                                                        , ( "stakes", E.string "gammon" )
                                                        , ( "points", E.int 2 )
                                                        , ( "cube", E.int 1 )
                                                        ]
                                                    )
                                                |> withData "to_act" E.null
                                                |> withData "to_move" E.null
                                    in
                                    { u | scene = { scene | phase = "between_games" }, legal = [ { name = "ready", label = "Ready", params = [] } ] }

                                viewing =
                                    View.update (ViewTurn 0) View.init |> Tuple.first

                                page m =
                                    View.view (ctx "p1" paused m) |> Query.fromHtml

                                board m =
                                    page m |> Query.find [ class "bg-board" ]
                            in
                            Expect.all
                                [ -- live: the result, and no dice
                                  \_ -> board View.init |> Query.has [ text "YOU WIN +2" ]

                                -- the past turn: its two dice, no result, no READY
                                , \_ -> board viewing |> Query.findAll [ class "die" ] |> Query.count (Expect.equal 2)
                                , \_ -> board viewing |> Query.hasNot [ text "YOU WIN" ]
                                , \_ -> board viewing |> Query.findAll [ id "bg-game-result" ] |> Query.count (Expect.equal 0)
                                , \_ -> page viewing |> Query.find [ id "bg-scrub-live" ] |> Event.simulate Event.click |> Event.expect ViewLive
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "MATCH opens the panel of games so far and its ✕ shuts it; a single game has no MATCH" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                one =
                                    gameOver 1 "p1" "gammon" 4 [ ( "p1", 4 ), ( "p2", 0 ) ]

                                two =
                                    gameOver 2 "p2" "dropped" 1 [ ( "p1", 4 ), ( "p2", 1 ) ]

                                u3 =
                                    inMatch (withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ] ]) 3 u |> withGames (E.list identity [ one, two ]))

                                ( opened, out ) =
                                    View.update ToggleMatch View.init

                                sheet =
                                    View.view (ctx "p1" u3 opened) |> Query.fromHtml |> Query.find [ id "bg-match-sheet" ]

                                winner n =
                                    nameOf n u3
                            in
                            Expect.all
                                [ \_ -> Expect.equal NoOut out
                                , \_ -> render "p1" u3 |> Query.findAll [ id "bg-match-sheet" ] |> Query.count (Expect.equal 0)
                                , \_ -> render "p1" u3 |> Query.find [ id "bg-match-toggle" ] |> Event.simulate Event.click |> Event.expect ToggleMatch
                                , \_ -> sheet |> Query.find [ id "bg-match-close" ] |> Event.simulate Event.click |> Event.expect ToggleMatch

                                -- one row per game played, then the game on the board
                                , \_ -> sheet |> Query.findAll [ class "bg-match-row" ] |> Query.count (Expect.equal 3)
                                , \_ -> sheet |> Query.find [ attribute (Html.Attributes.attribute "data-game" "1") ] |> Query.has [ text "G1", text (winner "p1"), text "+4", text "4–0", text "…", text "Analysis" ]
                                , \_ -> sheet |> Query.find [ attribute (Html.Attributes.attribute "data-game" "1") ] |> Query.find [ class "bg-match-cell", class "win" ] |> Query.has [ text (winner "p1"), attribute (Html.Attributes.title "gammon") ]
                                , \_ -> sheet |> Query.find [ attribute (Html.Attributes.attribute "data-game" "2") ] |> Query.has [ text (winner "p2"), text "+1", text "4–1" ]
                                , \_ -> sheet |> Query.find [ class "bg-match-row", class "is-live" ] |> Query.has [ text "G3", text "In play" ]
                                , \_ -> sheet |> Query.has [ class "bg-match-score" ]

                                -- the PRs, once the engine has graded a game
                                , \_ ->
                                    View.view (let c = ctx "p1" u3 opened in { c | gamePrs = \n -> if n == 1 then [ ( "p1", 7.4 ), ( "p2", 12.1 ) ] else [] })
                                        |> Query.fromHtml
                                        |> Query.find [ attribute (Html.Attributes.attribute "data-game" "1") ]
                                        |> Expect.all
                                            [ Query.has [ text "7.4", text "12.1" ]
                                            , Query.find [ class "bg-match-cell", class "best" ] >> Query.has [ text "7.4" ]
                                            ]

                                -- a single game: no match, no button, and the ✕ has nothing to close
                                , \_ -> render "p1" u |> Query.findAll [ id "bg-match-toggle" ] |> Query.count (Expect.equal 0)
                                , \_ -> View.view (ctx "p1" u opened) |> Query.fromHtml |> Query.find [ id "bg-match-sheet" ] |> Query.has [ text "In play" ]
                                ]
                                ()

                        Nothing ->
                            Expect.fail "no backgammon fixture"
             , test "the arrows under the board step through the game: first and back before, forward and live after, greyed at the ends" <|
                \_ ->
                    case firstUpdate of
                        Just u ->
                            let
                                u2 =
                                    withRecord (E.list identity [ turn "p1" [ 3, 1 ] [ "8/5", "6/5" ], cube "take" "p2" [], turnAt endgame "p2" [ 6, 6 ] [ "6/off(4)" ] ]) 1 u

                                row m =
                                    View.view (ctx "p1" u2 m) |> Query.fromHtml |> Query.find [ id "bg-scrub" ]

                                atTwo =
                                    View.update (ViewTurn 2) View.init |> Tuple.first

                                atZero =
                                    View.update (ViewTurn 0) View.init |> Tuple.first

                                disabled =
                                    attribute (Html.Attributes.disabled True)
                            in
                            Expect.all
                                [ -- live: the two ways back light, the two ways forward do not
                                  \_ -> row View.init |> Query.find [ id "bg-scrub-back" ] |> Event.simulate Event.click |> Event.expect (ViewTurn 2)
                                , \_ -> row View.init |> Query.find [ id "bg-scrub-first" ] |> Event.simulate Event.click |> Event.expect (ViewTurn 0)
                                , \_ -> row View.init |> Query.find [ id "bg-scrub-forward" ] |> Query.has [ disabled ]
                                , \_ -> row View.init |> Query.find [ id "bg-scrub-live" ] |> Query.has [ disabled ]

                                -- on the last turn: back skips the cube action to the turn before; forward is live
                                , \_ -> row atTwo |> Query.find [ id "bg-scrub-back" ] |> Event.simulate Event.click |> Event.expect (ViewTurn 0)
                                , \_ -> row atTwo |> Query.find [ id "bg-scrub-forward" ] |> Event.simulate Event.click |> Event.expect ViewLive
                                , \_ -> row atTwo |> Query.find [ id "bg-scrub-live" ] |> Event.simulate Event.click |> Event.expect ViewLive

                                -- on the first turn: nothing before it
                                , \_ -> row atZero |> Query.find [ id "bg-scrub-first" ] |> Query.has [ disabled ]
                                , \_ -> row atZero |> Query.find [ id "bg-scrub-back" ] |> Query.has [ disabled ]
                                , \_ -> row atZero |> Query.find [ id "bg-scrub-forward" ] |> Event.simulate Event.click |> Event.expect (ViewTurn 2)

                                -- a game with no turn yet: the row is there, every arrow grey
                                , \_ -> render "p1" (withRecord (E.list identity []) 1 u) |> Query.find [ id "bg-scrub" ] |> Query.findAll [ tag "button", disabled ] |> Query.count (Expect.equal 4)

                                -- the band says nothing about it: no LIVE button
                                , \_ -> View.view (ctx "p1" u2 atTwo) |> Query.fromHtml |> Query.findAll [ id "bg-live" ] |> Query.count (Expect.equal 0)
                                ]
                                ()

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


{-| The same roll with one die staged: its `used` prop set, the way the
projection marks a die a staged move spent.
-}
withUsedDie : String -> Protocol.Update -> Protocol.Update
withUsedDie dieId update =
    let
        spend token =
            if token.id == dieId then
                { token
                    | props =
                        E.object
                            [ ( "value", E.int (Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1) )
                            , ( "used", E.bool True )
                            , ( "picked", E.bool False )
                            ]
                }

            else
                token

        zones =
            List.map
                (\zone ->
                    if zone.id == "dice" then
                        { zone | tokens = List.map spend zone.tokens }

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
    , away = Just []
    , awaySince = \_ -> Nothing
    , prOf = \_ -> Nothing
    , theme = View.defaultTheme
    , replayHref = \n -> Just ("/backgammon/123456/replay?t=tok&game=" ++ String.fromInt n)
    , gamePrs = \_ -> []
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
        , test "the flag under the board is there exactly when resigning is legal" <|
            \_ ->
                p1Views
                    |> List.map
                        (\u ->
                            let
                                expected =
                                    if List.any (\s -> s.name == "resign") u.legal then
                                        1

                                    else
                                        0

                                row =
                                    render "p1" u |> Query.find [ id "bg-actions" ]
                            in
                            Expect.all
                                [ \_ -> row |> Query.findAll [ tag "button", id "bg-resign-open" ] |> Query.count (Expect.equal expected)
                                , \_ -> row |> Query.findAll [ id "bg-resign-open" ] |> Query.keep (tag "svg") |> Query.count (Expect.equal expected)
                                ]
                                ()
                        )
                    |> allPass
        , test "a waiting player is told whose turn it is" <|
            \_ ->
                p2Views
                    |> List.filter (\u -> (Protocol.sceneData (D.nullable D.string) "to_act" u.scene |> Maybe.withDefault Nothing) == Just "p1")
                    |> List.map (\u -> render "p2" u |> Query.has [ text "WAITING FOR P1" ])
                    |> allPass
        , test "pressing anywhere on a source point primes a drag whose tap plays that point" <|
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
                                    case p.tap of
                                        Just (PlayMove origin _) ->
                                            Expect.equal ( from, from ) ( p.origin, origin )

                                        _ ->
                                            Expect.fail "a short press on a source should play it"

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
        , test "with nothing pressed, no ghost checker shows anywhere" <|
            \_ ->
                p1Views
                    |> List.head
                    |> Maybe.map
                        (\u ->
                            View.view (ctx "p1" u { drag = Drag.idle, plans = [], swaps = 0, autoRolled = False, picker = Nothing, resigning = False, themesOpen = False, roll = settled, matchOpen = False, viewing = Nothing, stale = False, still = False })
                                |> Query.fromHtml
                                |> Query.findAll [ class "drop-ghost" ]
                                |> Query.count (Expect.equal 0)
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
