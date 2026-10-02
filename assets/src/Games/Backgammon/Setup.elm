module Games.Backgammon.Setup exposing
    ( Setup, Color(..), Ask(..), Match
    , opening, empty, flip, other
    , offWhite, offBlack, canDouble
    , check
    , pointsMessage, countMessage, tooManyMessage, noneMessage, noRollMessage, dieMessage
    , cubeValueMessage, ownedAtOneMessage, unownedMessage, lengthMessage, scoreMessage
    , crawfordMessage, cubeOwnedMessage, crawfordDoubleMessage, deadCubeMessage, gameOverMessage
    , toJson, decoder
    , fromQuestion
    )

{-| A position a player sets up on the analysis board: the checkers, who
is to play, what is asked (a roll to play, a double, a take), the cube and
the score. The client's twin of `src/oskol/analysis/setup.gleam`, field for
field, and the same JSON on the wire.

    points      24 signed counts, point 1 first, in White's numbering
                (White moves 24 -> 1, as `backgammon/board` has it):
                positive is White, negative is Black
    whiteBar, blackBar
    toPlay      the colour the question is put to: the mover for a roll
                and for a double, the taker for a take
    ask         Move (Just (high, low)) a roll to play; Move Nothing no
                roll picked yet (what `/analysis` opens on, and what
                `check` answers "Pick a roll" to; the Gleam twin's `no_roll`,
                0-0, and `dice: null` on the wire); Double the mover's cube
                decision before the roll; Take the answer to a double the
                other colour has just offered
    cubeValue, cubeOwner
                the cube as it stands; for a Take, as it stood before the
                double (the doubler turns it, the taker will own it)
    match       Nothing is unlimited play, which is money with Jacoby, as
                every unlimited game here is; Just {length, white, black,
                crawford} a match, with each colour's score (points won,
                not points away)

Borne off is derived: fifteen less what is on the points and the bar.

Dice are kept high die first. `Xgid.decode` and `fromQuestion` write them
that way, and an editor that lets a player pick "1-3" should store (3, 1):
the question the server asks about the roll is the same either way, and
the XGID writes the high die first.

The server is the authority on whether a position can be asked
(`setup.check` in Gleam); `check` here is the line the page shows under
the board while the player sets it up, in the same sentences.

-}

import Games.Backgammon.Puzzle as Puzzle
import Json.Decode as D
import Json.Encode as E


type alias Setup =
    { points : List Int
    , whiteBar : Int
    , blackBar : Int
    , toPlay : Color
    , ask : Ask
    , cubeValue : Int
    , cubeOwner : Maybe Color
    , match : Maybe Match
    }


type Color
    = White
    | Black


type Ask
    = Move (Maybe ( Int, Int ))
    | Double
    | Take


{-| A match to `length`, with each colour's score.
-}
type alias Match =
    { length : Int, white : Int, black : Int, crawford : Bool }


other : Color -> Color
other color =
    case color of
        White ->
            Black

        Black ->
            White



-- QUICK STARTS


{-| The starting position, White to play, no roll picked yet, the cube in
the middle, unlimited play: what `/analysis` opens on.
-}
opening : Setup
opening =
    { points =
        [ -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2 ]
    , whiteBar = 0
    , blackBar = 0
    , toPlay = White
    , ask = Move Nothing
    , cubeValue = 1
    , cubeOwner = Nothing
    , match = Nothing
    }


{-| No checkers anywhere, otherwise as `opening`: CLEAR.
-}
empty : Setup
empty =
    { opening | points = List.repeat 24 0 }


{-| The same position with the colours swapped: each point p becomes
25 - p with its owner changed, the bars swap, and so do the cube's owner,
the scores and who is to play. The question it asks is the same one.
-}
flip : Setup -> Setup
flip setup =
    { points = setup.points |> List.reverse |> List.map negate
    , whiteBar = setup.blackBar
    , blackBar = setup.whiteBar
    , toPlay = other setup.toPlay
    , ask = setup.ask
    , cubeValue = setup.cubeValue
    , cubeOwner = Maybe.map other setup.cubeOwner
    , match = Maybe.map (\m -> { m | white = m.black, black = m.white }) setup.match
    }



-- DERIVED


onPoints : Color -> Setup -> Int
onPoints color setup =
    setup.points
        |> List.map
            (\n ->
                case color of
                    White ->
                        max 0 n

                    Black ->
                        max 0 (negate n)
            )
        |> List.sum


onBoard : Color -> Setup -> Int
onBoard color setup =
    onPoints color setup
        + (case color of
            White ->
                setup.whiteBar

            Black ->
                setup.blackBar
          )


{-| White's checkers borne off: fifteen less the rest.
-}
offWhite : Setup -> Int
offWhite setup =
    15 - onBoard White setup


offBlack : Setup -> Int
offBlack setup =
    15 - onBoard Black setup


{-| Could `color` offer a double in this position? The engine's own rule
(`analysis.engine_can_double`): not in the Crawford game, not on a cube
the other side owns, and not on a dead cube -- one that already covers
what `color` needs to win the match.
-}
canDouble : Color -> Setup -> Bool
canDouble color setup =
    doubleRefusal color setup == Nothing


doubleRefusal : Color -> Setup -> Maybe String
doubleRefusal color setup =
    let
        away =
            setup.match
                |> Maybe.map
                    (\m ->
                        case color of
                            White ->
                                m.length - m.white

                            Black ->
                                m.length - m.black
                    )
    in
    if setup.cubeOwner == Just (other color) then
        Just (cubeOwnedMessage (other color))

    else if Maybe.map .crawford setup.match == Just True then
        Just crawfordDoubleMessage

    else
        case away of
            Just a ->
                if setup.cubeValue >= a then
                    Just (deadCubeMessage color)

                else
                    Nothing

            Nothing ->
                Nothing



-- CHECK
--
-- Word for word the refusals of `src/oskol/analysis/setup.gleam`, under the
-- same names in camel case, so the line under the board is the sentence
-- the server would answer with.


{-| The wire sent something that is not a board. The editor never does.
-}
pointsMessage : String
pointsMessage =
    "A board has 24 points"


{-| A point or a bar with a count outside 0..15.
-}
countMessage : String
countMessage =
    "A point holds 0 to 15 checkers"


{-| "White has 17 checkers; 15 is the most".
-}
tooManyMessage : Color -> Int -> String
tooManyMessage color n =
    colorName color ++ " has " ++ String.fromInt n ++ " checkers; 15 is the most"


{-| "Put some Black checkers on the board".
-}
noneMessage : Color -> String
noneMessage color =
    "Put some " ++ colorName color ++ " checkers on the board"


noRollMessage : String
noRollMessage =
    "Pick a roll"


dieMessage : String
dieMessage =
    "A die shows 1 to 6"


cubeValueMessage : String
cubeValueMessage =
    "The cube is 1, 2, 4, 8, 16, 32 or 64"


ownedAtOneMessage : String
ownedAtOneMessage =
    "A cube at 1 sits in the center"


unownedMessage : String
unownedMessage =
    "A cube above 1 belongs to somebody"


lengthMessage : String
lengthMessage =
    "A match is 1 to 25 points"


{-| "Each score is 0 to 6 in a match to 7".
-}
scoreMessage : Int -> String
scoreMessage length =
    "Each score is 0 to " ++ String.fromInt (length - 1) ++ " in a match to " ++ String.fromInt length


crawfordMessage : String
crawfordMessage =
    "Crawford needs somebody one point away"


{-| The doubler does not hold the cube: `owner` does.
-}
cubeOwnedMessage : Color -> String
cubeOwnedMessage owner =
    "No double is possible here: the cube is " ++ colorName owner ++ "'s"


crawfordDoubleMessage : String
crawfordDoubleMessage =
    "No double is possible here: this is the Crawford game"


{-| The cube already covers what the doubler needs to win the match.
-}
deadCubeMessage : Color -> String
deadCubeMessage doubler =
    "No double is possible here: the cube already covers what " ++ colorName doubler ++ " needs"


gameOverMessage : String
gameOverMessage =
    "The game is over in this position"


{-| The first thing that stops this position being asked, in the sentence
the page shows under the board, or Nothing when it can be asked. The same
order and the same words as the Gleam `setup.check`: the board's shape,
the counts, too many of a color, a color with none on the board, the
roll, the cube, the match, Crawford, a double or take the doubler could
not have made, and a game that is over.

A color with nothing on the board is "Put some ... checkers" while the
other color has none borne off (a board being set up); when the other has
borne some off too, it is a race somebody has finished, and that is
`gameOverMessage`.

The one refusal of the server's this cannot give is a roll that plays
nothing ("That roll has no legal moves here", from `setup.turn`): that
takes a move generator, which the client does not have.

-}
check : Setup -> Maybe String
check setup =
    let
        white =
            onBoard White setup

        black =
            onBoard Black setup

        when condition reason =
            if condition then
                Just reason

            else
                Nothing

        inRange low high n =
            n >= low && n <= high

        dice =
            case setup.ask of
                Move Nothing ->
                    Just noRollMessage

                Move (Just ( a, b )) ->
                    when (not (inRange 1 6 a && inRange 1 6 b)) dieMessage

                _ ->
                    Nothing

        match =
            setup.match
                |> Maybe.andThen
                    (\m ->
                        if not (inRange 1 25 m.length) then
                            Just lengthMessage

                        else if not (inRange 0 (m.length - 1) m.white && inRange 0 (m.length - 1) m.black) then
                            Just (scoreMessage m.length)

                        else
                            when (m.crawford && m.white /= m.length - 1 && m.black /= m.length - 1) crawfordMessage
                    )

        cube =
            case setup.ask of
                Double ->
                    doubleRefusal setup.toPlay setup

                Take ->
                    doubleRefusal (other setup.toPlay) setup

                Move _ ->
                    Nothing
    in
    [ when (List.length setup.points /= 24) pointsMessage
    , when (not (List.all (inRange -15 15) setup.points && inRange 0 15 setup.whiteBar && inRange 0 15 setup.blackBar)) countMessage
    , when (white > 15) (tooManyMessage White white)
    , when (black > 15) (tooManyMessage Black black)
    , when (white == 0 && (black == 0 || black == 15)) (noneMessage White)
    , when (black == 0 && (white == 0 || white == 15)) (noneMessage Black)
    , dice
    , when (not (List.member setup.cubeValue [ 1, 2, 4, 8, 16, 32, 64 ])) cubeValueMessage
    , when (setup.cubeValue == 1 && setup.cubeOwner /= Nothing) ownedAtOneMessage
    , when (setup.cubeValue /= 1 && setup.cubeOwner == Nothing) unownedMessage
    , match
    , cube
    , when (white == 0 || black == 0) gameOverMessage
    ]
        |> List.filterMap identity
        |> List.head


colorName : Color -> String
colorName color =
    case color of
        White ->
            "White"

        Black ->
            "Black"



-- WIRE


{-| The wire shape `src/oskol/analysis/setup.gleam` reads and writes:

    { points: [24 ints], white_bar, black_bar, to_play: "white" | "black",
      ask: "move" | "double" | "take", dice: [high, low] | null,
      cube: {value, owner: "center" | "white" | "black"},
      match: {length, white, black, crawford} | null }

-}
toJson : Setup -> E.Value
toJson setup =
    E.object
        [ ( "points", E.list E.int setup.points )
        , ( "white_bar", E.int setup.whiteBar )
        , ( "black_bar", E.int setup.blackBar )
        , ( "to_play", E.string (colorWire setup.toPlay) )
        , ( "ask"
          , E.string
                (case setup.ask of
                    Move _ ->
                        "move"

                    Double ->
                        "double"

                    Take ->
                        "take"
                )
          )
        , ( "dice"
          , case setup.ask of
                Move (Just ( a, b )) ->
                    E.list E.int [ a, b ]

                _ ->
                    E.null
          )
        , ( "cube"
          , E.object
                [ ( "value", E.int setup.cubeValue )
                , ( "owner", E.string (setup.cubeOwner |> Maybe.map colorWire |> Maybe.withDefault "center") )
                ]
          )
        , ( "match"
          , case setup.match of
                Just m ->
                    E.object
                        [ ( "length", E.int m.length )
                        , ( "white", E.int m.white )
                        , ( "black", E.int m.black )
                        , ( "crawford", E.bool m.crawford )
                        ]

                Nothing ->
                    E.null
          )
        ]


decoder : D.Decoder Setup
decoder =
    D.map8 Setup
        (D.field "points" (D.list D.int))
        (D.field "white_bar" D.int)
        (D.field "black_bar" D.int)
        (D.field "to_play" colorDecoder)
        (D.map2 Tuple.pair (D.field "ask" D.string) (D.field "dice" (D.nullable (D.list D.int)))
            |> D.andThen
                (\( ask, dice ) ->
                    case ( ask, dice ) of
                        ( "move", Nothing ) ->
                            D.succeed (Move Nothing)

                        ( "move", Just [ a, b ] ) ->
                            D.succeed (Move (Just ( a, b )))

                        ( "double", _ ) ->
                            D.succeed Double

                        ( "take", _ ) ->
                            D.succeed Take

                        _ ->
                            D.fail ("not an ask: " ++ ask)
                )
        )
        (D.at [ "cube", "value" ] D.int)
        (D.at [ "cube", "owner" ] D.string
            |> D.andThen
                (\owner ->
                    case owner of
                        "center" ->
                            D.succeed Nothing

                        "white" ->
                            D.succeed (Just White)

                        "black" ->
                            D.succeed (Just Black)

                        _ ->
                            D.fail ("not a cube owner: " ++ owner)
                )
        )
        (D.field "match"
            (D.nullable
                (D.map4 Match
                    (D.field "length" D.int)
                    (D.field "white" D.int)
                    (D.field "black" D.int)
                    (D.field "crawford" D.bool)
                )
            )
        )


colorWire : Color -> String
colorWire color =
    case color of
        White ->
            "white"

        Black ->
            "black"


colorDecoder : D.Decoder Color
colorDecoder =
    D.string
        |> D.andThen
            (\s ->
                case s of
                    "white" ->
                        D.succeed White

                    "black" ->
                        D.succeed Black

                    _ ->
                        D.fail ("not a colour: " ++ s)
            )



-- FROM A PUZZLE


{-| A puzzle as its page shows it, set up on the analysis board: what
`/analysis?p=<id>` opens. `kind` is the puzzle's own ("move", "double",
"take"), because the question alone cannot tell a double from a take on a
centred cube.

The question `GET /papi/puzzles/:id` sends is the shown one
(`handlers/puzzles.shown`): the solver is White at the bottom, both
colours counted in White's numbering, the cube owner and the away scores
from the solver's side -- and for a take the solver is the taker, so the
take becomes a `Take` ask from the taker's side with Black the doubler.

A question carries away scores, not the match length, so the match is
read back as the shortest one that leaves those aways: a match to the
larger of the two, the side further away at 0. The engine asks the same
question of it (it is the aways that matter), and the Gleam
`from_question` reads it back the same way.

-}
fromQuestion : String -> Puzzle.Question -> Setup
fromQuestion kind q =
    let
        ask =
            case ( kind, q.dice ) of
                ( "double", _ ) ->
                    Double

                ( "take", _ ) ->
                    Take

                ( _, [ a, b ] ) ->
                    Move (Just ( max a b, min a b ))

                _ ->
                    Move Nothing
    in
    { points = List.map2 (-) q.board.white.points q.board.black.points
    , whiteBar = q.board.white.bar
    , blackBar = q.board.black.bar
    , toPlay = White
    , ask = ask
    , cubeValue = q.cube.value
    , cubeOwner =
        case q.cube.owner of
            "mover" ->
                Just White

            "opponent" ->
                Just Black

            _ ->
                Nothing
    , match =
        q.score
            |> Maybe.map
                (\score ->
                    let
                        length =
                            max score.moverAway score.opponentAway
                    in
                    { length = length
                    , white = length - score.moverAway
                    , black = length - score.opponentAway
                    , crawford = q.crawford
                    }
                )
    }
