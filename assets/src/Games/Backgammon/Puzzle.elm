module Games.Backgammon.Puzzle exposing
    ( Puzzle, Question, Cube, Score, Board, Side
    , Tree, Node, Child, Moved
    , decoder, treeDecoder, nodeDecoder
    , Table, Seat, Out(..), view
    , nodeAt, played, snapshot, pips, pipsAgainst
    )

{-| A puzzle as the server sends it, and the board it is played on.

A puzzle is one position with the mover's whole turn already worked out:
the question (the board, the dice, the cube, the score) and a `tree` of
every legal way to play the roll. The tree is a DAG whose nodes are
positions -- every order of the same checkers is one node -- and whose
edges are single checker moves. Ids are opaque.

The client decides nothing about backgammon here. What may move, what is
hit, which dice are left and whether the turn is complete are all read off
the node; a tap walks to a child and `Undo` walks back, which is why undo
lands on the previous position exactly as it was. The page owns the walk
(`Table.path`); this module only draws the node the path ends on and says
which nodes a tap would walk to.

The mover is always shown as White at the bottom, whatever colour they had
in the game they made the mistake in: the question is stored from their
side of the board, so that is the only way round it reads.

A tree may be `lazy`: the server sent the root alone and the page fetches
each level as it is reached. So a `Stepped` can name a node the tree does
not hold yet. While that is true the board keeps the last position it does
hold on screen, as a picture with nothing to tap but UNDO, rather than
going blank; when the fetch lands the page re-renders and play carries on.

The one arithmetic it does is the pip count, which the wire does not carry
and the identity bars print: a count of the position, not a rule about it.

@docs Puzzle, Question, Cube, Score, Board, Side
@docs Tree, Node, Child, Moved
@docs decoder, treeDecoder, nodeDecoder
@docs Table, Seat, Out, view
@docs nodeAt, played, snapshot, pips, pipsAgainst

-}

import Dict exposing (Dict)
import Games.Backgammon.View as View
import Html exposing (Html)
import Json.Decode as D


{-| `GET /papi/puzzles/:id`: the question, the legal moves, and the
sentence the page asks in. Never the answer.
-}
type alias Puzzle =
    { id : String
    , kind : String -- "move" | "double" | "take"
    , question : Question
    , tree : Maybe Tree -- "move" only
    , prompt : String
    }


{-| The position the puzzle asks about, stored mover-relative: `board.white`
is always the mover, points are numbered from the mover's side (they move
24 -> 1, enter from the bar onto 24..19, bear off from 6..1), and the cube
is named relative to them.
-}
type alias Question =
    { board : Board
    , dice : List Int -- the roll; empty on a cube puzzle
    , cube : Cube
    , score : Maybe Score -- nothing means money or unlimited play
    , crawford : Bool
    , jacoby : Bool
    }


type alias Cube =
    { value : Int
    , owner : String -- "center" | "mover" | "opponent"
    }


type alias Score =
    { moverAway : Int, opponentAway : Int }


type alias Board =
    { white : Side, black : Side }


{-| One colour's checkers: how many on each of the 24 points (index 0 is
point 1), on the bar and borne off.
-}
type alias Side =
    { points : List Int, bar : Int, off : Int }


{-| Every legal way to play the roll. `lazy` says the server sent the root
alone and the rest are fetched a level at a time.
-}
type alias Tree =
    { root : String, nodes : Dict String Node, lazy : Bool }


{-| One position within the turn: what the board looks like, what is left
to play, whether anything more can be played, the step that reached it,
and the steps that lead on from it. A child exists only where the rules
allow it, so `children` is exactly the legal next taps.
-}
type alias Node =
    { board : Board
    , diceLeft : List Int
    , terminal : Bool
    , moved : Maybe Moved -- nothing on the root
    , children : List Child
    }


type alias Moved =
    { from : String, to : String, hit : Bool }


{-| One checker move and the node it reaches. `from` is a point, or "bar";
`to` is a point, or "off".
-}
type alias Child =
    { die : Int, from : String, to : String, node : String }



-- DECODERS


decoder : D.Decoder Puzzle
decoder =
    D.map5 Puzzle
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "question" questionDecoder)
        (optional "tree" treeDecoder)
        (D.field "prompt" D.string)


questionDecoder : D.Decoder Question
questionDecoder =
    D.map6 Question
        (D.field "board" boardDecoder)
        (optional "dice" (D.list D.int) |> D.map (Maybe.withDefault []))
        (D.field "cube" cubeDecoder)
        (optional "score" scoreDecoder)
        (D.field "crawford" D.bool)
        (D.field "jacoby" D.bool)


cubeDecoder : D.Decoder Cube
cubeDecoder =
    D.map2 Cube (D.field "value" D.int) (D.field "owner" D.string)


scoreDecoder : D.Decoder Score
scoreDecoder =
    D.map2 Score (D.field "mover_away" D.int) (D.field "opponent_away" D.int)


boardDecoder : D.Decoder Board
boardDecoder =
    D.map2 Board (D.field "white" sideDecoder) (D.field "black" sideDecoder)


sideDecoder : D.Decoder Side
sideDecoder =
    D.map3 Side (D.field "points" (D.list D.int)) (D.field "bar" D.int) (D.field "off" D.int)


treeDecoder : D.Decoder Tree
treeDecoder =
    D.map3 Tree
        (D.field "root" D.string)
        (D.field "nodes" (D.dict nodeDecoder))
        (optional "lazy" D.bool |> D.map (Maybe.withDefault False))


nodeDecoder : D.Decoder Node
nodeDecoder =
    D.map5 Node
        (D.field "board" boardDecoder)
        (D.field "dice_left" (D.list D.int))
        (D.field "terminal" D.bool)
        (optional "moved" movedDecoder)
        (D.field "children" (D.list childDecoder))


movedDecoder : D.Decoder Moved
movedDecoder =
    D.map3 Moved (D.field "from" D.string) (D.field "to" D.string) (D.field "hit" D.bool)


childDecoder : D.Decoder Child
childDecoder =
    D.map4 Child
        (D.field "die" D.int)
        (D.field "from" D.string)
        (D.field "to" D.string)
        (D.field "node" D.string)


{-| A field that may be absent or null -- and nothing else. A key that is
there is decoded strictly: a malformed tree must fail the whole answer
rather than quietly become a puzzle with nothing to play.
-}
optional : String -> D.Decoder a -> D.Decoder (Maybe a)
optional field dec =
    D.value
        |> D.andThen
            (\value ->
                case D.decodeValue (D.field field D.value) value of
                    Ok _ ->
                        D.field field (D.nullable dec)

                    Err _ ->
                        D.succeed Nothing
            )



-- WALKING THE TREE


{-| The position the path ends on: the root, then one child per id. A path
with a step the tree does not offer is no position at all.
-}
nodeAt : Tree -> List String -> Maybe Node
nodeAt tree path =
    List.foldl
        (\id current ->
            current
                |> Maybe.andThen
                    (\node ->
                        if List.any (\c -> c.node == id) node.children then
                            Dict.get id tree.nodes

                        else
                            Nothing
                    )
        )
        (Dict.get tree.root tree.nodes)
        path


{-| The path as the moves it played, in order: what an attempt is made of.
Nothing where the tree does not hold the whole path, the same answer
`nodeAt` gives: half a turn is not an attempt.
-}
played : Tree -> List String -> Maybe (List Child)
played tree path =
    let
        walk ids current acc =
            case ( ids, current ) of
                ( [], _ ) ->
                    Just (List.reverse acc)

                ( id :: rest, Just node ) ->
                    case node.children |> List.filter (\c -> c.node == id) |> List.head of
                        Just child ->
                            walk rest (Dict.get id tree.nodes) (child :: acc)

                        Nothing ->
                            Nothing

                ( _, Nothing ) ->
                    Nothing
    in
    walk path (Dict.get tree.root tree.nodes) []


{-| The position to draw. Normally the one the path ends on; where the path
runs past what the tree holds -- a lazy tree whose next level has not
arrived -- the last position it does hold, so the board stays on screen
instead of going blank. `False` says it is that stale picture.
-}
shownAt : Tree -> List String -> Maybe ( Node, Bool )
shownAt tree path =
    List.foldl
        (\id current ->
            case current of
                Just ( node, True ) ->
                    if List.any (\c -> c.node == id) node.children then
                        case Dict.get id tree.nodes of
                            Just next ->
                                Just ( next, True )

                            Nothing ->
                                -- the step is a real one, its node has not
                                -- been fetched yet
                                Just ( node, False )

                    else
                        Just ( node, False )

                other ->
                    other
        )
        (Dict.get tree.root tree.nodes |> Maybe.map (\node -> ( node, True )))
        path



-- THE BOARD


{-| Who is shown on one side of the board. A puzzle names nobody by
default: the page decides what, if anything, the bars say. Not which
colour: the mover plays White at the bottom, always, because the question
is stored from their side of the board.
-}
type alias Seat =
    { id : String, name : String }


{-| A puzzle on the board: the question, every legal way to play it, and
how far the player has walked. `swaps` is which die a tap on a checker
plays (the board asks for it with `Swapped`), and `key` tells one puzzle's
dice from the next.
-}
type alias Table =
    { question : Question
    , tree : Tree
    , path : List String -- the nodes stepped to, oldest first; [] is the question itself
    , mover : Seat
    , opponent : Seat
    , scores : List ( String, Int )
    , theme : String
    , swaps : Int
    , key : Int
    }


{-| What the board tells the page. The page appends a `Stepped`'s nodes to
its path and drops the last one on `Undo`; nothing else moves the board.
-}
type Out
    = Stepped (List String) -- walk on to these nodes, in order; a quick pair or the bear-off tray is two
    | Undo
    | Play -- the staged turn is the answer: only ever offered on a terminal node
    | Swapped


view : Table -> Html Out
view table =
    case shownAt table.tree table.path of
        Just ( node, current ) ->
            Html.map out (View.viewPlay (playBoard table node current))

        Nothing ->
            -- not even the root: there is no tree to draw
            Html.text ""


out : View.PlayOut -> Out
out o =
    case o of
        View.Stepped nodes ->
            Stepped nodes

        View.Undo ->
            Undo

        View.Play ->
            Play

        View.Swapped ->
            Swapped


{-| `current` is false while the path runs past what the tree holds: the
last position it does hold is drawn as a picture -- nothing to tap, no
PLAY -- with UNDO still there, so the page can always back out of a step
whose node has not arrived.
-}
playBoard : Table -> Node -> Bool -> View.PlayBoard
playBoard table node current =
    let
        stepsOf n =
            n.children |> List.map (\c -> { move = { from = c.from, to = c.to, die = c.die }, node = c.node })
    in
    { still =
        { players =
            [ { id = table.mover.id, name = table.mover.name, color = "white" }
            , { id = table.opponent.id, name = table.opponent.name, color = "black" }
            ]
        , viewer = table.mover.id
        , scores = table.scores
        , cube = not table.question.crawford
        , theme = table.theme
        , key = table.key
        , position = snapshot table.question.cube table.mover table.opponent node.board
        , mover = Just table.mover.id
        , dice = table.question.dice
        , landed = landedOn table.tree table.path
        , offer = Nothing
        , accounts = Nothing
        }
    , steps =
        if current then
            stepsOf node

        else
            []
    , after = \id -> Dict.get id table.tree.nodes |> Maybe.map stepsOf |> Maybe.withDefault []
    , diceLeft = node.diceLeft
    , terminal = current && node.terminal
    , canUndo = table.path /= []
    , swaps = table.swaps
    }


{-| The points the turn so far has landed checkers on, marked the way the
table marks the last turn's. A checker borne off lands nowhere on the
board, and neither does one that was hit, so neither is marked -- the same
as the replay, whose record only counts points too.
-}
landedOn : Tree -> List String -> List Int
landedOn tree path =
    played tree path
        |> Maybe.withDefault []
        |> List.filterMap (.to >> String.toInt)


{-| The wire's board as the slab draws one. The mover is White and the
opponent Black, because the wire numbers the points from the mover's side:
the mover runs 24 -> 1, which is the way White runs on the slab.
-}
snapshot : Cube -> Seat -> Seat -> Board -> View.Snapshot
snapshot cube mover opponent board =
    let
        mine side =
            { points = side.points, bar = side.bar, off = side.off, pips = pips side }

        theirs side =
            { points = side.points, bar = side.bar, off = side.off, pips = pipsAgainst side }

        owner =
            case cube.owner of
                "mover" ->
                    Just mover.id

                "opponent" ->
                    Just opponent.id

                _ ->
                    Nothing
    in
    { white = mine board.white
    , black = theirs board.black
    , cube = { value = cube.value, owner = owner }
    }


{-| The mover's pip count: they run 24 -> 1, and off the bar they are 25
from home.
-}
pips : Side -> Int
pips side =
    (side.points |> List.indexedMap (\i n -> n * (i + 1)) |> List.sum) + (side.bar * 25)


{-| The opponent's pip count, on the same numbering: they run 1 -> 24.
-}
pipsAgainst : Side -> Int
pipsAgainst side =
    (side.points |> List.indexedMap (\i n -> n * (24 - i)) |> List.sum) + (side.bar * 25)
