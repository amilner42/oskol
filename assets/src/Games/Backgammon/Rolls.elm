module Games.Backgammon.Rolls exposing
    ( Band(..)
    , Cell
    , Grid
    , allRolls
    , bandName
    , bandOf
    , decoder
    , helped
    , inWords
    , label
    , levelInWords
    , mirrored
    , short
    , sorted
    , weightOf
    )

{-| A position's next roll, all thirty-six of it: what the engine says each
of the twenty-one distinct rolls is worth, and the play it would make.

The wire's shape, fixed and live (`/papi`, `rolls-server`):

    { "level": "3ply", "equity": 0.096737
    , "rows": [ { "dice": [1, 1], "weight": 1, "equity": 0.4163
                , "best": "24/20(2) 13/9(2)" }, ... ] }

**Twenty-one rows, thirty-six cells.** A roll arrives once, `a <= b`,
doubles first, carrying the weight it has in thirty-six: 1 for a double, 2
for everything else. `mirrored` lays the twenty-one out as the six-by-six
grid a player reads, so 6-5 is drawn in two places and 6-6 in one -- which
is the whole reason a map beats a list.

**A cell's value is luck, not equity.** The roll's equity less the
position's own, so zero is neutral, a positive cell is a roll that helps
the player on roll, and the thirty-six values average to exactly nothing.
The engine's own figure (`Grid.equity`) is the weighted mean of the rows it
sent -- exactly, to six decimals (Aveline `bg-roll-breakdown`) -- so it is
read off the wire and never recomputed here.

**The bands are coarse on purpose.** The engine's error against a rollout
is 0.02 to 0.15, so a scale with fine gradations would be drawing noise.
Seven bands, three a side, on the site's own grade boundaries (0.02 /
0.08 / 0.16 -- `Words.gradeOf`), because those are already the numbers this
product calls a nothing, a slip, a mistake and a blunder.

Everything here is pure: a decoder, and arithmetic over the rows. It knows
nothing about a page or a drawing (`Ui.Rolls`).

-}

import Games.Backgammon.Words as Words
import Json.Decode as D exposing (Decoder)


{-| A position's rolls, as the engine answered.

  - `level` is the depth the grid was taken at (`"3ply"`), which is **not**
    the depth of the verdict above it; say both or they read as
    disagreeing.
  - `equity` is the engine's own figure for the position, which is the
    weighted mean of the rows. Shown, never recomputed.
  - `cells` are the twenty-one distinct rolls, in the order the wire sent
    them (doubles first).

-}
type alias Grid =
    { level : String
    , equity : Float
    , cells : List Cell
    }


{-| One roll.

  - `dice` is canonical: `( a, b )` with `a <= b`.
  - `weight` is how many of the thirty-six this roll is: 1 or 2.
  - `value` is luck -- the roll's equity less the grid's.
  - `band` is `value`'s band, the only thing a colour is allowed to read.
  - `best` is the engine's play for the roll, already as notation.

-}
type alias Cell =
    { dice : ( Int, Int )
    , weight : Int
    , value : Float
    , band : Band
    , best : String
    }


{-| Seven bands, three a side of a neutral middle.
-}
type Band
    = StrongUp
    | Up
    | SlightUp
    | Neutral
    | SlightDown
    | Down
    | StrongDown



-- THE WIRE


{-| The grid as `/papi` sends it.

It refuses anything it could not draw: the twenty-one canonical rolls must
all be there, once each, with the weight the dice imply. A grid missing a
roll would draw a hole in the map, and a wrong weight would make a double
look as likely as a non-double in the bars -- both are the picture lying,
so they fail loudly instead.

-}
decoder : Decoder Grid
decoder =
    D.map3 build
        (D.field "level" D.string)
        (D.field "equity" D.float)
        (D.field "rows" (D.list rowDecoder))
        |> D.andThen identity


type alias Row =
    { dice : ( Int, Int )
    , weight : Int
    , equity : Float
    , best : String
    }


rowDecoder : Decoder Row
rowDecoder =
    D.map4 Row
        (D.field "dice" diceDecoder)
        (D.field "weight" D.int)
        (D.field "equity" D.float)
        (D.field "best" D.string)


diceDecoder : Decoder ( Int, Int )
diceDecoder =
    D.list D.int
        |> D.andThen
            (\ns ->
                case ns of
                    [ a, b ] ->
                        if a >= 1 && a <= 6 && b >= 1 && b <= 6 && a <= b then
                            D.succeed ( a, b )

                        else
                            D.fail ("dice must be two faces with a <= b, not " ++ pair a b)

                    _ ->
                        D.fail "dice must be a pair"
            )


build : String -> Float -> List Row -> Decoder Grid
build level equity rows =
    let
        missing =
            List.filter (\d -> not (List.any (\r -> r.dice == d) rows)) allRolls

        misweighed =
            List.filter (\r -> r.weight /= weightOf r.dice) rows
    in
    if List.length rows /= 21 then
        D.fail ("a grid is 21 rolls, not " ++ String.fromInt (List.length rows))

    else if not (List.isEmpty missing) then
        D.fail ("the grid is missing " ++ String.join ", " (List.map label missing))

    else if not (List.isEmpty misweighed) then
        D.fail ("a weight is not the roll's: " ++ String.join ", " (List.map (.dice >> label) misweighed))

    else
        D.succeed
            { level = level
            , equity = equity
            , cells = List.map (cellOf equity) rows
            }


cellOf : Float -> Row -> Cell
cellOf equity row =
    let
        value =
            row.equity - equity
    in
    { dice = row.dice
    , weight = row.weight
    , value = value
    , band = bandOf value
    , best = row.best
    }



-- THE TWENTY-ONE, AND THE THIRTY-SIX


{-| The twenty-one rolls in the order the wire sends them: the six doubles,
then every other pair with the smaller face first.
-}
allRolls : List ( Int, Int )
allRolls =
    List.map (\n -> ( n, n )) (List.range 1 6)
        ++ List.concatMap
            (\a -> List.map (\b -> ( a, b )) (List.range (a + 1) 6))
            (List.range 1 5)


{-| How many of the thirty-six a roll is: a double arrives one way, every
other roll two.
-}
weightOf : ( Int, Int ) -> Int
weightOf ( a, b ) =
    if a == b then
        1

    else
        2


{-| The thirty-six cells in grid order -- die one down the rows, die two
across the columns -- so every non-double is drawn twice, once either side
of the diagonal, and the diagonal is the doubles.

That mirroring is the point of the map: 6-5 takes two cells and 6-6 one, so
the eye is told which roll is twice as likely without being given a number.

Each cell keeps its canonical dice, so the two halves of the grid say the
same roll.

-}
mirrored : List Cell -> List Cell
mirrored cells =
    List.range 1 6
        |> List.concatMap
            (\d1 -> List.map (\d2 -> ( min d1 d2, max d1 d2 )) (List.range 1 6))
        |> List.filterMap (\dice -> find dice cells)


find : ( Int, Int ) -> List Cell -> Maybe Cell
find dice cells =
    List.head (List.filter (\c -> c.dice == dice) cells)


{-| The rolls best first, for the bars. Ties keep the wire's roll order
(doubles before the rest, then by face), so the chart is the same drawing
every time it is asked for.
-}
sorted : List Cell -> List Cell
sorted cells =
    List.sortWith
        (\x y ->
            case compare y.value x.value of
                EQ ->
                    compare (rollIndex x.dice) (rollIndex y.dice)

                other ->
                    other
        )
        cells


rollIndex : ( Int, Int ) -> Int
rollIndex dice =
    allRolls
        |> List.indexedMap (\i d -> ( i, d ))
        |> List.filter (\( _, d ) -> d == dice)
        |> List.head
        |> Maybe.map Tuple.first
        |> Maybe.withDefault 99


{-| How many of the thirty-six help: the weight of every roll above the
position's own average. The companion to the map's colours in a sentence --
"20 in 36 help" -- which is what a reader who cannot see the colours gets.
-}
helped : List Cell -> Int
helped cells =
    cells
        |> List.filter (\c -> c.value > 0)
        |> List.map .weight
        |> List.sum



-- THE BANDS


{-| Which band a value falls in.

The site's own grade boundaries, mirrored about zero: 0.02 is the figure
this product already calls "not a mistake", 0.08 a slip and 0.16 a blunder
(`Words.gradeOf`). Coarser than the colour scale a reader might expect, and
deliberately so -- the engine's error against a rollout is 0.02 to 0.15, so
anything finer would be drawing noise.

A value exactly on a boundary takes the further-out band, as `gradeOf`
does, and the epsilon is there for the same reason: `0.08` arrives from
arithmetic on floats, not as a literal.

-}
bandOf : Float -> Band
bandOf value =
    let
        step =
            if abs value >= 0.16 - 0.000001 then
                3

            else if abs value >= 0.08 - 0.000001 then
                2

            else if abs value >= 0.02 - 0.000001 then
                1

            else
                0
    in
    if step == 0 then
        Neutral

    else if value > 0 then
        case step of
            3 ->
                StrongUp

            2 ->
                Up

            _ ->
                SlightUp

    else
        case step of
            3 ->
                StrongDown

            2 ->
                Down

            _ ->
                SlightDown


{-| A band's name, which is its class suffix and its `data-band`.
-}
bandName : Band -> String
bandName band =
    case band of
        StrongUp ->
            "strong-up"

        Up ->
            "up"

        SlightUp ->
            "slight-up"

        Neutral ->
            "neutral"

        SlightDown ->
            "slight-down"

        Down ->
            "down"

        StrongDown ->
            "strong-down"



-- WORDS AND NUMBERS


{-| A roll as the books write it, the higher face first: `6-5`, `4-1`,
`6-6`. The wire's order is `a <= b` because it is sorting, not speaking.
-}
label : ( Int, Int ) -> String
label ( a, b ) =
    pair (max a b) (min a b)


pair : Int -> Int -> String
pair a b =
    String.fromInt a ++ "-" ++ String.fromInt b


{-| The depth, as a reader says it: `3ply` is "3-ply".
-}
levelInWords : String -> String
levelInWords level =
    case String.split "ply" level of
        [ n, "" ] ->
            n ++ "-ply"

        _ ->
            level


{-| A cell in words: the roll, the play, the value and how likely it is.

    inWords { withMove = True }   "6-6: 24/18(2) 13/7(2) · +0.392 · 1 in 36"
    inWords { withMove = False }  "6-6 · +0.392 · 1 in 36"

This is what a tap puts under the grid, and it is every cell's
`aria-label`, so the map is readable without the colours. `withMove` is the
MOVES switch: a cell in the panel is about fifty pixels across and cannot
hold `24/18(2) 13/7(2)`, so the play is written here or nowhere.

-}
inWords : { withMove : Bool } -> Cell -> String
inWords { withMove } cell =
    String.join " · "
        [ if withMove then
            label cell.dice ++ ": " ++ cell.best

          else
            label cell.dice
        , Words.signed cell.value
        , String.fromInt cell.weight ++ " in 36"
        ]


{-| A value in a cell, where there is room for four characters and no more:
`+.39`, `−.10`, `0`. Two decimals, no leading zero, and a bare `0` for
anything inside half a hundredth -- the bands are what carry the size, so
the number is a reminder, not a measurement.
-}
short : Float -> String
short value =
    let
        hundredths =
            round (abs value * 100)

        sign =
            if hundredths == 0 then
                ""

            else if value > 0 then
                "+"

            else
                "−"
    in
    if hundredths == 0 then
        "0"

    else if hundredths >= 100 then
        sign ++ String.fromInt (hundredths // 100) ++ "." ++ String.fromInt (hundredths // 10 |> modBy 10)

    else
        sign ++ "." ++ String.padLeft 2 '0' (String.fromInt hundredths)
