module BackgammonPuzzleTest exposing (suite)

{-| The puzzle board: a backgammon board with no room behind it, driven by
a hand-written tree (`PuzzleFixtures`) in the shape the wire contract
promises.

Everything here is a fact about the client: which taps the tree offers,
which node each one walks to, and what the slab draws for the node it is
on. No test asserts a rule of backgammon -- the fixture is where the rules
live, exactly as the server's tree is in production.

-}

import Expect
import Games.Backgammon.Puzzle as Puzzle exposing (Out(..))
import Games.Backgammon.View as View
import Html.Attributes
import Json.Decode as D
import PuzzleFixtures
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, classes, id, text)


suite : Test
suite =
    describe "backgammon puzzle board"
        [ describe "the wire"
            [ test "a puzzle is its question, its tree and the sentence it asks" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\p tree ->
                            Expect.all
                                [ \_ -> p.id |> Expect.equal "hit00001"
                                , \_ -> p.kind |> Expect.equal "move"
                                , \_ -> p.prompt |> Expect.equal "White to play 6-4. What's your play?"
                                , \_ -> p.question.dice |> Expect.equal [ 6, 4 ]
                                , \_ -> p.question.cube |> Expect.equal { value = 1, owner = "center" }
                                , \_ -> p.question.score |> Expect.equal Nothing
                                , \_ -> tree.root |> Expect.equal "r"
                                , \_ -> tree.lazy |> Expect.equal False
                                ]
                                ()
                        )
            , test "the root is the question's board with every die still to play" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\p tree ->
                            case Puzzle.nodeAt tree [] of
                                Just root ->
                                    Expect.all
                                        [ \_ -> root.board |> Expect.equal p.question.board
                                        , \_ -> root.diceLeft |> Expect.equal [ 6, 4 ]
                                        , \_ -> root.terminal |> Expect.equal False
                                        , \_ -> root.moved |> Expect.equal Nothing
                                        , \_ -> root.children |> List.length |> Expect.equal 2
                                        ]
                                        ()

                                Nothing ->
                                    Expect.fail "no root"
                        )
            , test "a hit is the node's business: the blot is gone and its owner is on the bar" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\_ tree ->
                            case Puzzle.nodeAt tree [ "n1" ] of
                                Just hit ->
                                    Expect.all
                                        [ \_ -> hit.moved |> Expect.equal (Just { from = "13", to = "7", hit = True })
                                        , \_ -> hit.board.black.bar |> Expect.equal 1
                                        , \_ -> at 7 hit.board.black |> Expect.equal 0
                                        , \_ -> at 7 hit.board.white |> Expect.equal 1
                                        ]
                                        ()

                                Nothing ->
                                    Expect.fail "no node"
                        )
            , test "an entry from the bar comes from \"bar\", a checker borne off goes \"off\"" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            onPuzzle PuzzleFixtures.bar
                                (\_ tree -> children tree [] |> List.map .from |> Expect.equal [ "bar" ])
                        , \_ ->
                            onPuzzle PuzzleFixtures.off
                                (\_ tree -> children tree [] |> List.map .to |> Expect.equal [ "off", "off" ])
                        ]
                        ()
            , test "doubles leave four dice" <|
                \_ ->
                    onPuzzle PuzzleFixtures.doubles
                        (\p tree ->
                            Expect.all
                                [ \_ -> p.question.dice |> Expect.equal [ 3, 3 ]
                                , \_ -> Puzzle.nodeAt tree [] |> Maybe.map .diceLeft |> Expect.equal (Just [ 3, 3, 3, 3 ])
                                ]
                                ()
                        )
            , test "only the larger die is offered where one die is all the turn can play" <|
                \_ ->
                    onPuzzle PuzzleFixtures.bar
                        (\_ tree ->
                            Expect.all
                                [ \_ -> children tree [] |> Expect.equal [ { die = 6, from = "bar", to = "19", node = "n1" } ]
                                , \_ -> Puzzle.nodeAt tree [ "n1" ] |> Maybe.map .terminal |> Expect.equal (Just True)

                                -- the turn is over with the 3 still standing
                                , \_ -> Puzzle.nodeAt tree [ "n1" ] |> Maybe.map .diceLeft |> Expect.equal (Just [ 3 ])
                                ]
                                ()
                        )
            , test "a path the tree does not offer is no position at all" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\_ tree ->
                            Expect.all
                                [ \_ -> Puzzle.nodeAt tree [ "n3" ] |> Expect.equal Nothing
                                , \_ -> Puzzle.nodeAt tree [ "nope" ] |> Expect.equal Nothing
                                ]
                                ()
                        )
            ]
        , describe "staging a turn"
            [ test "a tap on a checker walks to the node the next die reaches" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t -> tapPoint t 13 |> Expect.equal (Ok (Stepped [ "n1" ])))
            , test "a tap on a point exactly one move lands on plays that move" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t -> tapPoint t 9 |> Expect.equal (Ok (Stepped [ "n2" ])))
            , test "the dice are a control: swapped, the same checker plays the other die" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.find [ id "dice-row" ] |> Event.simulate Event.click |> Event.expect Swapped
                                , \_ -> tapPoint { t | swaps = 1 } 13 |> Expect.equal (Ok (Stepped [ "n2" ]))
                                ]
                                ()
                        )
            , test "a double has nothing to swap" <|
                \_ ->
                    onTable PuzzleFixtures.doubles
                        (\t ->
                            rendered t
                                |> Query.find [ id "dice-row" ]
                                |> Event.simulate Event.click
                                |> Event.toResult
                                |> Expect.err
                        )
            , test "a point no child reaches answers nothing" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t -> tapPoint t 20 |> Expect.err)
            , test "the board is the node's: the staged checker has moved" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> checkersOn (rendered (walk t [ "n1" ])) 7 1
                                , \_ -> checkersOn (rendered (walk t [ "n1" ])) 13 1
                                , \_ -> checkersOn (rendered t) 13 2
                                ]
                                ()
                        )
            , test "the dice the turn has spent are marked used" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> diceUsed (rendered t) 2 0
                                , \_ -> diceUsed (rendered (walk t [ "n1" ])) 2 1
                                ]
                                ()
                        )
            , test "PLAY is offered on a terminal node and nowhere else" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.findAll [ id "bg-action-play" ] |> Query.count (Expect.equal 0)
                                , \_ -> rendered (walk t [ "n1" ]) |> Query.findAll [ id "bg-action-play" ] |> Query.count (Expect.equal 0)
                                , \_ -> rendered (walk t [ "n1", "n3" ]) |> Query.find [ id "bg-action-play" ] |> Query.has [ text "PLAY" ]
                                , \_ ->
                                    rendered (walk t [ "n1", "n3" ])
                                        |> Query.find [ id "bg-action-play" ]
                                        |> Event.simulate Event.click
                                        |> Event.expect Play
                                ]
                                ()
                        )
            , test "the mover's pip count is the position's" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.find [ class "player-bar", class "is-me" ] |> Query.has [ text "92 PIPS" ]
                                , \_ -> rendered t |> Query.findAll [ class "player-bar" ] |> Query.index 0 |> Query.has [ text "175 PIPS" ]
                                ]
                                ()
                        )
            ]
        , describe "undo"
            [ test "UNDO is offered once a step has been taken, and not before" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.findAll [ id "bg-action-undo" ] |> Query.count (Expect.equal 0)
                                , \_ -> rendered (walk t [ "n1" ]) |> Query.find [ id "bg-action-undo" ] |> Query.has [ text "UNDO" ]
                                , \_ ->
                                    rendered (walk t [ "n1" ])
                                        |> Query.find [ id "bg-action-undo" ]
                                        |> Event.simulate Event.click
                                        |> Event.expect Undo
                                ]
                                ()
                        )
            , test "the node undo returns to is the one it left, exactly" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\p tree ->
                            -- the page drops the last step; the board it is
                            -- handed back is the parent's own snapshot
                            Expect.all
                                [ \_ -> Puzzle.nodeAt tree [] |> Maybe.map .board |> Expect.equal (Just p.question.board)
                                , \_ -> Puzzle.nodeAt tree [ "n1" ] |> Maybe.map .diceLeft |> Expect.equal (Just [ 4 ])
                                ]
                                ()
                        )
            , test "the board drawn after an undo is the board drawn before the step" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> checkersOn (rendered (walk t [])) 13 2

                                -- the blot the 6 would hit is standing again
                                , \_ -> rendered (walk t []) |> Query.find [ class "bg-point", pointTitle 7 ] |> Query.findAll [ classes [ "checker", "black" ] ] |> Query.count (Expect.equal 1)
                                , \_ ->
                                    rendered (walk t [])
                                        |> Query.find [ class "bg-bar-row", class "theirs" ]
                                        |> Query.findAll [ class "checker" ]
                                        |> Query.count (Expect.equal 0)
                                , \_ -> diceUsed (rendered (walk t [])) 2 0
                                ]
                                ()
                        )
            ]
        , describe "a hit, drawn"
            [ test "the checker that was hit is on the bar, on its owner's side" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ ->
                                    rendered (walk t [ "n1" ])
                                        |> Query.find [ class "bg-bar-row", class "theirs" ]
                                        |> Query.findAll [ class "checker" ]
                                        |> Query.count (Expect.equal 1)
                                , \_ ->
                                    rendered t
                                        |> Query.find [ class "bg-bar-row", class "theirs" ]
                                        |> Query.findAll [ class "checker" ]
                                        |> Query.count (Expect.equal 0)
                                ]
                                ()
                        )
            ]
        , describe "from the bar"
            [ test "the bar answers the tap and walks to the entry" <|
                \_ ->
                    onTable PuzzleFixtures.bar
                        (\t ->
                            Expect.all
                                [ \_ -> tapBar t |> Expect.equal (Ok (Stepped [ "n1" ]))

                                -- the larger die is the only entry, so the
                                -- order the dice sit in changes nothing
                                , \_ -> tapBar { t | swaps = 1 } |> Expect.equal (Ok (Stepped [ "n1" ]))
                                ]
                                ()
                        )
            , test "the entry the tree does not offer cannot be tapped for" <|
                \_ ->
                    onTable PuzzleFixtures.bar
                        (\t -> tapPoint t 22 |> Expect.err)
            , test "a turn that is over with a die left offers PLAY and nothing else" <|
                \_ ->
                    onTable PuzzleFixtures.bar
                        (\t ->
                            let
                                entered =
                                    rendered (walk t [ "n1" ])
                            in
                            Expect.all
                                [ \_ -> entered |> Query.find [ id "bg-action-play" ] |> Query.has [ text "PLAY" ]
                                , \_ -> entered |> Query.findAll [ attribute (Html.Attributes.attribute "data-move-source" "") ] |> Query.count (Expect.equal 0)
                                , \_ -> diceUsed entered 2 1
                                ]
                                ()
                        )
            ]
        , describe "bearing off"
            [ test "the tray takes a checker off with the next die, and the other one after it" <|
                \_ ->
                    onTable PuzzleFixtures.off
                        (\t ->
                            Expect.all
                                [ \_ -> tapTray t |> Expect.equal (Ok (Stepped [ "a", "c" ]))
                                , \_ -> tapTray { t | swaps = 1 } |> Expect.equal (Ok (Stepped [ "b", "c" ]))
                                ]
                                ()
                        )
            , test "each step of that shortcut is a child of the node it leaves" <|
                \_ ->
                    onPuzzle PuzzleFixtures.off
                        (\_ tree ->
                            Expect.all
                                [ \_ -> Puzzle.nodeAt tree [ "a", "c" ] |> Maybe.map .terminal |> Expect.equal (Just True)
                                , \_ -> Puzzle.played tree [ "a", "c" ] |> List.map .die |> Expect.equal [ 5, 2 ]
                                ]
                                ()
                        )
            , test "a tap on the checker itself bears off one" <|
                \_ ->
                    onTable PuzzleFixtures.off
                        (\t -> tapPoint t 2 |> Expect.equal (Ok (Stepped [ "a" ])))
            , test "the tray answers nothing where no checker can come off" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t -> tapTray t |> Expect.err)
            , test "the tray fills as checkers come off" <|
                \_ ->
                    onTable PuzzleFixtures.off
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.find [ class "bg-tray", class "mine" ] |> Query.has [ text "13" ]
                                , \_ -> rendered (walk t [ "a", "c" ]) |> Query.find [ class "bg-tray", class "mine" ] |> Query.has [ text "15" ]
                                ]
                                ()
                        )
            ]
        , describe "doubles"
            [ test "all four dice stand at the start, and one is spent per step" <|
                \_ ->
                    onTable PuzzleFixtures.doubles
                        (\t ->
                            Expect.all
                                [ \_ -> diceUsed (rendered t) 4 0
                                , \_ -> diceUsed (rendered (walk t [ "n1" ])) 4 1
                                , \_ -> diceUsed (rendered (walk t [ "n1", "n2a", "n3b", "n4b" ])) 4 4
                                ]
                                ()
                        )
            , test "a tap on a point two checkers can make is two steps" <|
                \_ ->
                    onTable PuzzleFixtures.doubles
                        (\t ->
                            Expect.all
                                [ \_ -> tapPoint t 10 |> Expect.equal (Ok (Stepped [ "n1", "n2b" ]))
                                , \_ -> checkersOn (rendered (walk t [ "n1", "n2b" ])) 10 2
                                , \_ -> checkersOn (rendered (walk t [ "n1", "n2b" ])) 13 0

                                -- and it really is two steps: the first of
                                -- them is a node of its own to undo to
                                , \_ -> checkersOn (rendered (walk t [ "n1" ])) 10 1
                                ]
                                ()
                        )
            , test "a tap on the checker itself is one step" <|
                \_ ->
                    onTable PuzzleFixtures.doubles
                        (\t -> tapPoint t 13 |> Expect.equal (Ok (Stepped [ "n1" ])))
            ]
        , describe "one node, two orders"
            [ test "the same checkers played the other way round is the same node" <|
                \_ ->
                    onPuzzle PuzzleFixtures.hit
                        (\_ tree ->
                            Expect.all
                                [ \_ -> Puzzle.nodeAt tree [ "n1", "n3" ] |> Expect.equal (Puzzle.nodeAt tree [ "n2", "n3" ])
                                , \_ -> Puzzle.played tree [ "n1", "n3" ] |> List.map .from |> Expect.equal [ "13", "13" ]
                                , \_ -> Puzzle.played tree [ "n1", "n3" ] |> List.map .die |> Expect.equal [ 6, 4 ]
                                , \_ -> Puzzle.played tree [ "n2", "n3" ] |> List.map .die |> Expect.equal [ 4, 6 ]
                                ]
                                ()
                        )
            , test "and it draws the same board either way" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> checkersOn (rendered (walk t [ "n1", "n3" ])) 9 1
                                , \_ -> checkersOn (rendered (walk t [ "n2", "n3" ])) 9 1
                                , \_ -> checkersOn (rendered (walk t [ "n2", "n3" ])) 7 1
                                , \_ ->
                                    rendered (walk t [ "n2", "n3" ])
                                        |> Query.find [ class "bg-bar-row", class "theirs" ]
                                        |> Query.findAll [ class "checker" ]
                                        |> Query.count (Expect.equal 1)
                                ]
                                ()
                        )
            ]
        , describe "both orientations"
            [ test "the mover plays white at the bottom" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\t ->
                            Expect.all
                                [ \_ -> rendered t |> Query.find [ class "bg-point", pointTitle 13 ] |> Query.findAll [ classes [ "checker", "white" ] ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered t |> Query.find [ class "player-bar", class "is-me" ] |> Query.find [ class "swatch" ] |> Query.has [ class "white" ]
                                , \_ -> tapPoint t 13 |> Expect.equal (Ok (Stepped [ "n1" ]))
                                ]
                                ()
                        )
            , test "the same puzzle with the mover in black is the same puzzle" <|
                \_ ->
                    onTable PuzzleFixtures.hit
                        (\white ->
                            let
                                t =
                                    { white
                                        | mover = { id = "mover", name = "Black", color = "black" }
                                        , opponent = { id = "other", name = "White", color = "white" }
                                    }
                            in
                            Expect.all
                                [ \_ -> rendered t |> Query.find [ class "bg-point", pointTitle 13 ] |> Query.findAll [ classes [ "checker", "black" ] ] |> Query.count (Expect.equal 2)
                                , \_ -> rendered t |> Query.find [ class "player-bar", class "is-me" ] |> Query.find [ class "swatch" ] |> Query.has [ class "black" ]
                                , \_ -> rendered t |> Query.find [ class "player-bar", class "is-me" ] |> Query.has [ text "92 PIPS" ]
                                , \_ -> tapPoint t 13 |> Expect.equal (Ok (Stepped [ "n1" ]))
                                , \_ -> checkersOn (rendered (walk t [ "n1" ])) 7 1
                                ]
                                ()
                        )
            ]
        ]



-- THE FIXTURE, AS A PUZZLE AND AS A TABLE


onPuzzle : String -> (Puzzle.Puzzle -> Puzzle.Tree -> Expect.Expectation) -> Expect.Expectation
onPuzzle json f =
    case D.decodeString Puzzle.decoder json of
        Ok p ->
            case p.tree of
                Just tree ->
                    f p tree

                Nothing ->
                    Expect.fail "the puzzle carries no tree"

        Err err ->
            Expect.fail (D.errorToString err)


onTable : String -> (Puzzle.Table -> Expect.Expectation) -> Expect.Expectation
onTable json f =
    onPuzzle json
        (\p tree ->
            f
                { question = p.question
                , tree = tree
                , path = []
                , mover = { id = "mover", name = "White", color = "white" }
                , opponent = { id = "other", name = "Black", color = "black" }
                , scores = [ ( "mover", 0 ), ( "other", 0 ) ]
                , theme = View.defaultTheme
                , swaps = 0
                , key = 1
                }
        )


walk : Puzzle.Table -> List String -> Puzzle.Table
walk table path =
    { table | path = path }


children : Puzzle.Tree -> List String -> List Puzzle.Child
children tree path =
    Puzzle.nodeAt tree path |> Maybe.map .children |> Maybe.withDefault []


at : Int -> Puzzle.Side -> Int
at point side =
    side.points |> List.drop (point - 1) |> List.head |> Maybe.withDefault 0



-- WHAT THE SLAB DRAWS, AND WHAT IT ANSWERS


rendered : Puzzle.Table -> Query.Single Out
rendered table =
    Puzzle.view table |> Query.fromHtml


pointTitle : Int -> Test.Html.Selector.Selector
pointTitle point =
    attribute (Html.Attributes.title ("Point " ++ String.fromInt point))


tapPoint : Puzzle.Table -> Int -> Result String Out
tapPoint table point =
    rendered table
        |> Query.find [ class "bg-point", pointTitle point ]
        |> Event.simulate Event.click
        |> Event.toResult


tapBar : Puzzle.Table -> Result String Out
tapBar table =
    rendered table
        |> Query.find [ class "bg-bar" ]
        |> Event.simulate Event.click
        |> Event.toResult


tapTray : Puzzle.Table -> Result String Out
tapTray table =
    rendered table
        |> Query.find [ class "bg-tray", class "mine" ]
        |> Event.simulate Event.click
        |> Event.toResult


{-| How many checkers a point is drawn with.
-}
checkersOn : Query.Single Out -> Int -> Int -> Expect.Expectation
checkersOn q point n =
    q
        |> Query.find [ class "bg-point", pointTitle point ]
        |> Query.findAll [ class "checker" ]
        |> Query.count (Expect.equal n)


{-| How many dice are drawn, and how many of them the turn has spent.
-}
diceUsed : Query.Single Out -> Int -> Int -> Expect.Expectation
diceUsed q shown used =
    Expect.all
        [ \_ -> q |> Query.findAll [ class "die" ] |> Query.count (Expect.equal shown)
        , \_ -> q |> Query.findAll [ classes [ "die", "used" ] ] |> Query.count (Expect.equal used)
        ]
        ()
