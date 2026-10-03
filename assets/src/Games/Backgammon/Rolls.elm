module Games.Backgammon.Rolls exposing
    ( Cell
    , Grid
    , Sign(..)
    , allRolls
    , canonical
    , decoder
    , helped
    , hurt
    , inWords
    , label
    , levelInWords
    , mirrored
    , near
    , ramp
    , short
    , signName
    , signOf
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

**A cell's value is the roll's own equity.** Not the roll against the
position's average -- the roll against an even game. Zero means neither
player is ahead, so a winning position reads green and a losing one reads
red, and the grid answers "how good is this position" before it answers
"which roll do I want". The engine's own figure (`Grid.equity`) is the
weighted mean of the rows it sent -- exactly, to six decimals (Aveline
`bg-roll-breakdown`) -- so it is read off the wire, never recomputed, and
now stands in the same units as every cell under it.

**The scale is fixed and absolute: `ramp`.** +1 is the far green end, -1
the far red end, anything beyond is clamped, and nothing is re-centred or
normalised per grid. That is the property the whole feature turns on: a
colour means the same equity in the opening as in a bear-off, and in both
halves of a comparison. A scale that stretched to fit each grid would make
two pictures of the same number look different.

**There are no bands.** An earlier draft had seven, on the site's grade
boundaries; both were wrong here. The boundaries measure what a player
*gave up*, and no cell in this grid contains a mistake -- the engine plays
the best move for every roll. And coarseness was a defence against drawing
noise when the scale was a few tenths wide; at ±1 the engine's worst error
against a rollout (0.15) is a fifteenth of the ramp, so interpolating is
reading the number, not the noise. `signOf` is all that stays discrete, and
only because the sign must be legible without colour.

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
  - `value` is the roll's equity, on the absolute scale (a comparison grid
    puts the difference between two plays here instead).
  - `sign` is which way, with a dead zone round nothing: the one thing in
    the picture that is not allowed to depend on colour.
  - `best` is the engine's play for the roll, already as notation.

-}
type alias Cell =
    { dice : ( Int, Int )
    , weight : Int
    , value : Float
    , sign : Sign
    , best : String
    }


{-| Which way a cell goes, and nothing about how far.
-}
type Sign
    = Up
    | Zero
    | Down



-- THE WIRE


{-| The grid as `/papi` sends it.

It refuses anything it could not draw, and anything that would draw a lie:

  - the twenty-one canonical rolls must all be there, once each, or the map
    has a hole in it;
  - each weight must be the one its dice imply, or a double's bar is as
    wide as a non-double's and the picture says they are equally likely;
  - and the rows must average to the `equity` above them, because every
    cell's value is its row less that figure. A grid whose headline did not
    come from its own rows would shift all thirty-six values -- and so
    every band, and the count of what helps -- by one silent constant,
    which is the same class of lie as the other two and the only one that
    would look entirely plausible.

The third is held to 0.005, a quarter of the narrowest band: wide enough
for the rounding in six decimals of JSON, far too narrow for an engine that
has started answering about a different position.

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

        mean =
            List.sum (List.map (\r -> toFloat r.weight * r.equity) rows) / 36
    in
    if List.length rows /= 21 then
        D.fail ("a grid is 21 rolls, not " ++ String.fromInt (List.length rows))

    else if not (List.isEmpty missing) then
        D.fail ("the grid is missing " ++ String.join ", " (List.map label missing))

    else if not (List.isEmpty misweighed) then
        D.fail ("a weight is not the roll's: " ++ String.join ", " (List.map (.dice >> label) misweighed))

    else if abs (mean - equity) > 0.005 then
        D.fail
            ("the rolls do not average to the grid's equity: "
                ++ Words.signed mean
                ++ " against "
                ++ Words.signed equity
            )

    else
        D.succeed
            { level = level
            , equity = equity
            , cells = List.map cellOf rows
            }


cellOf : Row -> Cell
cellOf row =
    { dice = row.dice
    , weight = row.weight
    , value = row.equity
    , sign = signOf row.equity
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


{-| A pair of faces as this module keys them: smaller first.

**The rest of the client does not write a roll this way.** A record's dice
are sorted with the higher face first (`state.gleam`: `int.compare(b, a)`),
which is how backgammon is spoken and what `Replay` decodes; the wire sorts
the other way because it is indexing, not speaking. So anything a page hands
in -- the roll that was thrown, the cell a reader tapped -- goes through
this before it is compared with a cell, or 6-5 would match nothing and 6-6
would match, and the map would look half-broken rather than broken.

-}
canonical : ( Int, Int ) -> ( Int, Int )
canonical ( a, b ) =
    ( min a b, max a b )


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


{-| How many of the thirty-six leave the player on roll ahead: the weight
of every cell whose sign is up.

**By sign, which is what the picture shows.** This sentence is what a
reader who cannot see the drawing is given instead of it, and the drawing's
one discrete mark is the hatching, which is `signOf` and nothing else. So a
cell that is counted here is a cell that is not hatched, and the dead zone
means neither claims a roll whose number prints as `0`.

-}
helped : List Cell -> Int
helped cells =
    weightIn Up cells


{-| And how many leave them behind. The ones inside the dead zone are
neither, which is why these two need not add up to thirty-six.
-}
hurt : List Cell -> Int
hurt cells =
    weightIn Down cells


weightIn : Sign -> List Cell -> Int
weightIn sign cells =
    cells
        |> List.filter (\c -> c.sign == sign)
        |> List.map .weight
        |> List.sum



-- THE SCALE


{-| Where a value sits on the fixed scale: 0 at an even game, 1 at the far
end, clamped beyond it.

**Nothing here looks at the other cells**, which is the whole point. The
same equity is the same colour in the opening, in a bear-off, and in both
halves of a comparison; a scale that stretched to each grid's own spread
would draw two pictures of one number differently.

A value past 1 is a position already won by more than a point -- a gammon
in hand -- and past -1 the same the other way round. Those are real, and
they clamp: the ends say "as good as it gets" rather than re-scaling every
other cell to make room for one.

-}
ramp : Float -> Float
ramp value =
    min 1 (abs value)


{-| The dead zone round nothing: half a hundredth.

Exactly the width at which `short` gives up and prints `0`, so the three
ways a cell can say it is neutral cannot disagree -- no colour, no hatching
and no number, and counted in neither total.

-}
near : Float
near =
    0.005


{-| Which way a cell goes, and nothing about how far. The one discrete
thing left in the picture, and only because the sign must be legible to a
reader for whom red and green are one colour.
-}
signOf : Float -> Sign
signOf value =
    if value >= near then
        Up

    else if value <= -near then
        Down

    else
        Zero


{-| A sign's name, which is its class suffix and its `data-sign`.
-}
signName : Sign -> String
signName sign =
    case sign of
        Up ->
            "up"

        Zero ->
            "zero"

        Down ->
            "down"



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


{-| A value in a cell, where a cell is about fifty pixels across: `+.39`,
`−.10`, `0`. Two decimals and no leading zero, a bare `0` for anything
inside half a hundredth, and one decimal with the unit once a value reaches
1 (`+1.4`) -- which an equity does in a position with a live gammon. The
bands are what carry the size; the number is a reminder, not a measurement.
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
        let
            -- rounded to the tenth, not truncated: 1.05 is +1.1
            tenths =
                round (abs value * 10)
        in
        sign ++ String.fromInt (tenths // 10) ++ "." ++ String.fromInt (modBy 10 tenths)

    else
        sign ++ "." ++ String.padLeft 2 '0' (String.fromInt hundredths)
