module RollsTest exposing (suite)

{-| The thirty-six rolls: the wire, the mirroring, the fixed scale, and the
two drawings.

The fixture is the opening position at 3-ply. **Four of its rows are the
engine's own, taken off the live engine and pinned here**: 6-6 at +0.489
(`24/18(2) 13/7(2)`), 4-4 at +0.4163, 1-4 at −0.007 (the worst roll) and
1-2 at −0.004, under a grid equity of 0.096737. The other seventeen are
the standard opening plays with equities shaped to leave the weighted mean
exactly where the engine put it, so the invariant below is a real
arithmetic check and the four pinned rows are a real check of the scale.
They are not engine output and must not be quoted as such.

The invariant that makes the whole feature honest: **the rows' weighted
mean is the grid's own equity, exactly** (Aveline `bg-roll-breakdown`,
measured to six decimals on eight boards). It is asserted here and never
recomputed for display.

A cell is the roll's own equity on one fixed scale -- 0 an even game, +-1
the ends -- so the opening comes out mostly green: 32 of its 36 rolls leave
the player on roll ahead, which is what being on roll is worth.

The orientation check, because a sign error here would be the most
embarrassing possible bug: this is correct backgammon, so 6-6 must come
out at the top of the scale and 1-4 at the bottom. If a change puts 2-1
above 6-6, something is inverted.

-}

import Expect exposing (FloatingPointTolerance(..))
import Games.Backgammon.Rolls as Rolls
import Html.Attributes
import Json.Decode as D
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (class, text)
import Ui.Rolls as Rolls_


suite : Test
suite =
    describe "Games.Backgammon.Rolls / Ui.Rolls"
        [ theWire
        , theInvariant
        , theScale
        , theMirror
        , theSort
        , theMap
        , theBars
        , theWords
        ]



-- THE FIXTURE


{-| The opening position's grid, as `/papi` sends it. See the module note on
which rows are the engine's.
-}
fixtureJson : String
fixtureJson =
    """
    { "level": "3ply", "equity": 0.096737, "rows":
      [ { "dice": [1,1], "weight": 1, "equity": 0.345,    "best": "8/7(2) 6/5(2)" }
      , { "dice": [2,2], "weight": 1, "equity": 0.083232, "best": "13/11(2) 24/22(2)" }
      , { "dice": [3,3], "weight": 1, "equity": 0.368,    "best": "8/5(2) 6/3(2)" }
      , { "dice": [4,4], "weight": 1, "equity": 0.4163,   "best": "24/20(2) 13/9(2)" }
      , { "dice": [5,5], "weight": 1, "equity": 0.141,    "best": "8/3(2) 6/1(2)" }
      , { "dice": [6,6], "weight": 1, "equity": 0.489,    "best": "24/18(2) 13/7(2)" }
      , { "dice": [1,2], "weight": 2, "equity": -0.004,   "best": "24/23 13/11" }
      , { "dice": [1,3], "weight": 2, "equity": 0.168,    "best": "8/5 6/5" }
      , { "dice": [1,4], "weight": 2, "equity": -0.007,   "best": "24/23 13/9" }
      , { "dice": [1,5], "weight": 2, "equity": 0.028,    "best": "24/23 13/8" }
      , { "dice": [1,6], "weight": 2, "equity": 0.104,    "best": "13/7 8/7" }
      , { "dice": [2,3], "weight": 2, "equity": 0.06,     "best": "13/11 13/10" }
      , { "dice": [2,4], "weight": 2, "equity": 0.096,    "best": "8/4 6/4" }
      , { "dice": [2,5], "weight": 2, "equity": 0.012,    "best": "13/11 13/8" }
      , { "dice": [2,6], "weight": 2, "equity": 0.055,    "best": "24/18 13/11" }
      , { "dice": [3,4], "weight": 2, "equity": 0.044,    "best": "13/10 13/9" }
      , { "dice": [3,5], "weight": 2, "equity": 0.072,    "best": "8/3 6/3" }
      , { "dice": [3,6], "weight": 2, "equity": 0.04,     "best": "24/18 13/10" }
      , { "dice": [4,5], "weight": 2, "equity": 0.03,     "best": "24/20 13/8" }
      , { "dice": [4,6], "weight": 2, "equity": 0.058,    "best": "24/18 13/9" }
      , { "dice": [5,6], "weight": 2, "equity": 0.064,    "best": "24/13" }
      ]
    }
    """


grid : Rolls.Grid
grid =
    case D.decodeString Rolls.decoder fixtureJson of
        Ok g ->
            g

        Err _ ->
            { level = "?", equity = 0, cells = [] }


{-| The wire with one row swapped by `edit`, for the decoder's refusals.
-}
without : String -> String
without row =
    String.replace row "" fixtureJson



-- THE WIRE


theWire : Test
theWire =
    describe "the decoder, on the fixture"
        [ test "takes the level and the grid's own equity off the wire" <|
            \_ ->
                Expect.all
                    [ .level >> Expect.equal "3ply"
                    , .equity >> Expect.within (Absolute 1.0e-9) 0.096737
                    , .cells >> List.length >> Expect.equal 21
                    ]
                    grid
        , test "carries the engine's play for the roll, as notation" <|
            \_ ->
                cellOf ( 6, 6 )
                    |> Maybe.map .best
                    |> Expect.equal (Just "24/18(2) 13/7(2)")
        , test "weights are 1 for a double and 2 for everything else, summing to 36" <|
            \_ ->
                Expect.all
                    [ List.map .weight >> List.sum >> Expect.equal 36
                    , List.filter (\c -> c.weight == 1) >> List.length >> Expect.equal 6
                    , List.filter (\c -> c.weight == 2) >> List.length >> Expect.equal 15
                    ]
                    grid.cells
        , test "refuses a grid that is not 21 rolls" <|
            \_ ->
                D.decodeString Rolls.decoder
                    (without """, { "dice": [5,6], "weight": 2, "equity": 0.064,    "best": "24/13" }""")
                    |> Result.mapError (always "refused")
                    |> Expect.equal (Err "refused")
        , test "refuses dice the wrong way round" <|
            \_ ->
                D.decodeString Rolls.decoder
                    (String.replace "\"dice\": [1,2]" "\"dice\": [2,1]" fixtureJson)
                    |> Result.mapError (always "refused")
                    |> Expect.equal (Err "refused")
        , test "refuses a weight that is not the roll's -- the bars would lie" <|
            \_ ->
                D.decodeString Rolls.decoder
                    (String.replace """"dice": [6,6], "weight": 1""" """"dice": [6,6], "weight": 2""" fixtureJson)
                    |> Result.mapError (always "refused")
                    |> Expect.equal (Err "refused")
        , test "refuses a headline that is not its own rows' mean -- every cell would be off by one silent constant" <|
            \_ ->
                D.decodeString Rolls.decoder
                    (String.replace "\"equity\": 0.096737" "\"equity\": 0.2" fixtureJson)
                    |> Result.mapError (always "refused")
                    |> Expect.equal (Err "refused")
        , test "but lets six decimals of JSON rounding through" <|
            \_ ->
                -- a thousandth out: well inside the 0.005 the decoder allows,
                -- and far inside the 0.02 that could move a cell's band
                D.decodeString Rolls.decoder
                    (String.replace "\"equity\": 0.096737" "\"equity\": 0.0977" fixtureJson)
                    |> Result.map (.cells >> List.length)
                    |> Expect.equal (Ok 21)
        ]


cellOf : ( Int, Int ) -> Maybe Rolls.Cell
cellOf dice =
    List.head (List.filter (\c -> c.dice == dice) grid.cells)


{-| A made-up grid: 1-1 at a quarter, 2-2 at `top`, everything else level.
Two of these with different `top`s are the same picture of 1-1, which is
what a fixed scale means and what a fitted one would break.
-}
spread : Float -> Rolls.Grid
spread top =
    { level = "3ply"
    , equity = 0
    , cells =
        List.map2
            (\dice value ->
                { dice = dice
                , weight = Rolls.weightOf dice
                , value = value
                , sign = Rolls.signOf value
                , best = "24/18(2) 13/7(2)"
                }
            )
            Rolls.allRolls
            (0.25 :: top :: List.repeat 19 0)
    }



-- THE INVARIANT


theInvariant : Test
theInvariant =
    describe "the rows average to the grid's own equity"
        [ test "the weighted mean of the rolls is the engine's figure, exactly" <|
            \_ ->
                -- the cells ARE the equities now, so this is the headline
                -- and the thirty-six numbers under it being one quantity
                grid.cells
                    |> List.map (\c -> toFloat c.weight * c.value)
                    |> List.sum
                    |> (\total -> total / 36)
                    |> Expect.within (Absolute 1.0e-9) grid.equity
        , test "and a cell is the roll's own equity, not the roll against that mean" <|
            \_ ->
                -- 6-6 is the engine's +0.489 and reads +0.489, whatever the
                -- position it sits in averages to
                cellOf ( 6, 6 )
                    |> Maybe.map .value
                    |> Maybe.withDefault 0
                    |> Expect.within (Absolute 1.0e-9) 0.489
        ]



-- THE SCALE


theScale : Test
theScale =
    describe "the fixed scale"
        [ test "0 is an even game, 1 is the far end, and past it clamps" <|
            \_ ->
                Expect.equal
                    (List.map Rolls.ramp [ 0, 0.25, 0.489, 1, 1.4, 3, -0.25, -1, -2.6 ])
                    [ 0, 0.25, 0.489, 1, 1, 1, 0.25, 1, 1 ]
        , test "it does not look at the other cells: the same equity draws the same bar in any grid" <|
            \_ ->
                -- The property the whole change turns on. One grid where
                -- nothing else reaches a twentieth and one where another roll
                -- is a whole point: +0.25 must draw at exactly the same
                -- height in both. A scale fitted to each grid's own spread
                -- would put it near the top of the first.
                let
                    height top =
                        Rolls_.view { config | drawing = Rolls_.Bars } (spread top)
                            |> Query.fromHtml
                            |> Query.find [ attr "data-dice" "1-1" ]
                in
                Expect.all
                    [ \_ -> height 0.05 |> Query.has [ attr "height" "36.5" ]
                    , \_ -> height 1 |> Query.has [ attr "height" "36.5" ]
                    ]
                    ()
        , test "the dead zone is exactly where the number stops printing" <|
            \_ ->
                -- no colour, no hatching, no number and in neither count:
                -- the four ways of saying nothing cannot disagree
                Expect.equal
                    (List.map (\v -> ( Rolls.signName (Rolls.signOf v), Rolls.short v ))
                        [ 0.006, 0.005, 0.0049, 0, -0.0049, -0.005, -0.006 ]
                    )
                    [ ( "up", "+.01" )
                    , ( "up", "+.01" )
                    , ( "zero", "0" )
                    , ( "zero", "0" )
                    , ( "zero", "0" )
                    , ( "down", "−.01" )
                    , ( "down", "−.01" )
                    ]
        , test "the dead zone is the one `near` names, not a literal somewhere else" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal (Rolls.signOf Rolls.near) Rolls.Up
                    , \_ -> Expect.equal (Rolls.signOf -Rolls.near) Rolls.Down
                    ]
                    ()
        , test "the opening's four pinned rolls land where backgammon says" <|
            \_ ->
                -- a map that puts 2-1 above 6-6 is inverted
                Expect.equal
                    (List.map
                        (\d ->
                            ( Rolls.label d
                            , Maybe.map (.sign >> Rolls.signName) (cellOf d)
                            , Maybe.map (.value >> Rolls.short) (cellOf d)
                            )
                        )
                        [ ( 6, 6 ), ( 4, 4 ), ( 1, 4 ), ( 1, 2 ) ]
                    )
                    [ ( "6-6", Just "up", Just "+.49" )
                    , ( "4-4", Just "up", Just "+.42" )
                    , ( "4-1", Just "down", Just "−.01" )
                    , ( "2-1", Just "zero", Just "0" )
                    ]
        ]



-- THE MIRROR


theMirror : Test
theMirror =
    describe "21 rolls become 36 cells"
        [ test "thirty-six cells" <|
            \_ ->
                Rolls.mirrored grid.cells |> List.length |> Expect.equal 36
        , test "a double once, every other roll twice" <|
            \_ ->
                let
                    howMany dice =
                        Rolls.mirrored grid.cells
                            |> List.filter (\c -> c.dice == dice)
                            |> List.length
                in
                Expect.equal (List.map howMany Rolls.allRolls)
                    (List.map Rolls.weightOf Rolls.allRolls)
        , test "and in the right two places: die one down, die two across" <|
            \_ ->
                -- row 1 column 2 and row 2 column 1 are both the roll 2-1;
                -- the diagonal (0, 7, 14, 21, 28, 35) is the doubles.
                let
                    at i =
                        Rolls.mirrored grid.cells
                            |> List.drop i
                            |> List.head
                            |> Maybe.map (.dice >> Rolls.label)
                in
                Expect.equal (List.map at [ 0, 1, 5, 6, 7, 30, 35 ])
                    [ Just "1-1" -- (1,1)
                    , Just "2-1" -- (1,2)
                    , Just "6-1" -- (1,6)
                    , Just "2-1" -- (2,1), the mirror of index 1
                    , Just "2-2" -- (2,2)
                    , Just "6-1" -- (6,1), the mirror of index 5
                    , Just "6-6" -- (6,6)
                    ]
        , test "every cell keeps its roll's value, both sides of the diagonal" <|
            \_ ->
                let
                    valuesOf dice =
                        Rolls.mirrored grid.cells
                            |> List.filter (\c -> c.dice == dice)
                            |> List.map .value
                in
                case valuesOf ( 1, 4 ) of
                    [ a, b ] ->
                        Expect.within (Absolute 1.0e-12) a b

                    other ->
                        Expect.fail ("4-1 should be in two cells, found " ++ String.fromInt (List.length other))
        ]



-- THE SORT


theSort : Test
theSort =
    describe "best first, for the bars"
        [ test "6-6 leads and 4-1 is last -- the opening, as the books have it" <|
            \_ ->
                let
                    order =
                        List.map (.dice >> Rolls.label) (Rolls.sorted grid.cells)
                in
                Expect.equal ( List.head order, List.head (List.reverse order) )
                    ( Just "6-6", Just "4-1" )
        , test "twenty-one bars, never thirty-six" <|
            \_ ->
                Rolls.sorted grid.cells |> List.length |> Expect.equal 21
        , test "the values fall, and never rise" <|
            \_ ->
                let
                    values =
                        List.map .value (Rolls.sorted grid.cells)

                    falling =
                        List.map2 (\a b -> a >= b) values (List.drop 1 values)
                in
                Expect.equal (List.filter not falling) []
        , test "how many of the thirty-six help: the up bands, not merely a positive value" <|
            \_ ->
                -- 1-1, 3-3, 4-4 and 6-6 strong-up and 5-5 slight-up (one
                -- each), 3-1 slight-up (two) = 7. 6-1 is +0.007 and 2-4
                -- -0.0007: both are drawn as the neutral paper, so neither
                -- is counted -- the sentence has to say what the picture
                -- shows or a reader counting the green cells finds two
                -- missing.
                Rolls.helped grid.cells |> Expect.equal 32
        , test "and nothing helps in a grid that is all one band" <|
            \_ ->
                Expect.all
                    [ \_ -> Rolls.hurt grid.cells |> Expect.equal 2
                    , \_ -> Rolls.helped (List.map (\c -> { c | sign = Rolls.Zero }) grid.cells) |> Expect.equal 0
                    , \_ -> Rolls.hurt (List.map (\c -> { c | sign = Rolls.Zero }) grid.cells) |> Expect.equal 0
                    ]
                    ()
        ]



-- THE MAP


type Msg
    = Pick Rolls_.Drawing
    | Numbers
    | Moves
    | Tap ( Int, Int )


config : Rolls_.Config Msg
config =
    { drawing = Rolls_.Map
    , onDrawing = Pick
    , numbers = False
    , onNumbers = Numbers
    , moves = False
    , onMoves = Moves
    , outlined = Nothing
    , tapped = Nothing
    , onTap = Tap
    , mover = "Arie"
    , words = Rolls_.equity
    , attrs = []
    }


attr : String -> String -> Selector.Selector
attr name value =
    Selector.attribute (Html.Attributes.attribute name value)


theMap : Test
theMap =
    describe "the map"
        [ test "thirty-six cells, each a door" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.findAll [ class "rl-cell" ]
                    |> Query.count (Expect.equal 36)
        , test "a cell wears its band, as a class and as data" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.findAll [ attr "data-dice" "6-6" ]
                    |> Query.each
                        (Expect.all
                            [ Query.has [ class "is-up" ]
                            , Query.has [ attr "data-sign" "up" ]
                            , Query.has [ attr "style" "--rl-t:48.9%" ]
                            ]
                        )
        , test "and the worst roll wears its own" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.findAll [ attr "data-dice" "4-1" ]
                    |> Query.each
                        (Expect.all
                            [ Query.has [ class "is-down", attr "data-sign" "down" ]
                            , Query.has [ attr "style" "--rl-t:0.7%" ]
                            ]
                        )
        , test "NUMBERS off hides the values" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.findAll [ class "rl-cell-value" ]
                    |> Query.count (Expect.equal 0)
        , test "NUMBERS on writes one in every cell, short" <|
            \_ ->
                Rolls_.view { config | numbers = True } grid
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ class "rl-cell-value" ] >> Query.count (Expect.equal 36)
                        , Query.findAll [ attr "data-dice" "6-6" ]
                            >> Query.first
                            >> Query.has [ text "+.49" ]
                        ]
        , test "the thrown roll is outlined -- in both its cells, when it has two" <|
            \_ ->
                let
                    outlined on =
                        Rolls_.view { config | outlined = on } grid
                            |> Query.fromHtml
                            |> Query.findAll [ class "rl-cell", class "is-out" ]
                in
                Expect.all
                    [ \_ -> outlined (Just ( 5, 6 )) |> Query.count (Expect.equal 2)
                    , \_ -> outlined (Just ( 6, 6 )) |> Query.count (Expect.equal 1)
                    , \_ -> outlined Nothing |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "and the roll may be handed in either way round -- a record says 6-5, the wire says 5-6" <|
            \_ ->
                -- Replay decodes the record's dice as the record sorts them,
                -- higher face first (state.gleam). Matching on the raw tuple
                -- would ring nothing for 6-5 and still work for 6-6, which
                -- looks half-broken rather than broken.
                Expect.all
                    [ \_ ->
                        Rolls_.view { config | outlined = Just ( 6, 5 ) } grid
                            |> Query.fromHtml
                            |> Query.findAll [ class "rl-cell", class "is-out" ]
                            |> Query.count (Expect.equal 2)
                    , \_ ->
                        Rolls_.view { config | tapped = Just ( 4, 1 ) } grid
                            |> Query.fromHtml
                            |> Query.find [ class "rl-said" ]
                            |> Query.has [ text "4-1 · −0.007 · 2 in 36" ]
                    , \_ ->
                        bars { config | outlined = Just ( 6, 5 ) }
                            |> Query.findAll [ attr "data-out" "true" ]
                            |> Query.count (Expect.equal 1)
                    ]
                    ()
        , test "the switches say which of them are on" <|
            \_ ->
                Rolls_.view { config | numbers = True } grid
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ attr "data-tab" "map" ] >> Query.has [ class "is-on", text "MAP" ]
                        , Query.find [ attr "data-tab" "bars" ] >> Query.has [ attr "aria-pressed" "false" ]
                        , Query.find [ attr "data-switch" "numbers" ] >> Query.has [ attr "aria-pressed" "true", text "NUMBERS" ]
                        , Query.find [ attr "data-switch" "moves" ] >> Query.has [ attr "aria-pressed" "false", text "MOVES" ]
                        ]
        , test "the depth is said under either drawing, from the grid's own equity" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.find [ class "rl-depth" ]
                    |> Query.has [ text "3-ply · averages to +0.097" ]
        ]



-- THE BARS


{-| The bars are SVG, and `Selector.class` reads an element's `className`,
which an SVG element has not got -- so a bar is found by its `data-`, and
counted as a `rect` (the only other mark in the box is the zero `line`).
`ChartsTest` keeps the same helper for the same reason.
-}
bars : Rolls_.Config Msg -> Query.Single Msg
bars c =
    Query.fromHtml (Rolls_.view { c | drawing = Rolls_.Bars } grid)


theBars : Test
theBars =
    describe "the bars"
        [ test "twenty-one bars, best on the left" <|
            \_ ->
                bars config
                    |> Expect.all
                        [ Query.findAll [ Selector.tag "rect" ] >> Query.count (Expect.equal 21)
                        , Query.findAll [ Selector.tag "rect" ] >> Query.first >> Query.has [ attr "data-dice" "6-6" ]
                        , Query.findAll [ Selector.tag "rect" ] >> Query.index 20 >> Query.has [ attr "data-dice" "4-1" ]
                        ]
        , test "a bar is as wide as its roll is likely: a double half a non-double" <|
            \_ ->
                -- the plot is 346 units for 36 rolls, so one roll in 36 is
                -- 9.6111 wide and a 1.2 gap comes off each bar:
                --   a double      1 x 9.6111 - 1.2 =  8.41
                --   anything else 2 x 9.6111 - 1.2 = 18.02
                -- and 18.02 + 1.2 is exactly twice 8.41 + 1.2, which is the
                -- property that matters: the pitch is the probability.
                bars config
                    |> Expect.all
                        [ Query.find [ attr "data-dice" "6-6" ]
                            >> Query.has [ attr "width" "8.41", attr "data-weight" "1" ]
                        , Query.find [ attr "data-dice" "6-5" ]
                            >> Query.has [ attr "width" "18.02", attr "data-weight" "2" ]
                        ]
        , test "zero is a line through the middle, and a good roll is drawn above it" <|
            \_ ->
                bars config
                    |> Expect.all
                        [ Query.findAll [ attr "data-zero" "true" ] >> Query.count (Expect.equal 1)
                        , Query.find [ attr "data-zero" "true" ] >> Query.has [ attr "y1" "186", attr "y2" "186" ]

                        -- and the ends of the fixed scale are drawn with it,
                        -- so a short bar is not read as a flat position
                        , Query.findAll [ Selector.tag "line" ] >> Query.count (Expect.equal 3)
                        , Query.has [ text "+1", text "−1" ]

                        -- 6-6 is the best roll at +0.489, so on the fixed
                        -- scale its bar is 0.489 of the 146 it could reach,
                        -- and it runs up to the zero line: y + height = 186.
                        , Query.find [ attr "data-dice" "6-6" ] >> Query.has [ attr "y" "114.61", attr "height" "71.39" ]

                        -- and a roll at the end of the scale fills it
                        , \_ ->
                            Rolls_.view { config | drawing = Rolls_.Bars } (spread 1.4)
                                |> Query.fromHtml
                                |> Query.find [ attr "data-dice" "2-2" ]
                                |> Query.has [ attr "height" "146" ]

                        -- 4-1 is the worst, so its bar hangs from the line
                        , Query.find [ attr "data-dice" "4-1" ] >> Query.has [ attr "y" "186" ]
                        ]
        , test "the thrown roll is marked here too, once -- the bars do not mirror" <|
            \_ ->
                bars { config | outlined = Just ( 5, 6 ) }
                    |> Expect.all
                        [ Query.findAll [ attr "data-out" "true" ] >> Query.count (Expect.equal 1)
                        , Query.find [ attr "data-out" "true" ] >> Query.has [ attr "data-dice" "6-5" ]
                        ]
        , test "the map is not drawn while the bars are" <|
            \_ ->
                bars config
                    |> Query.findAll [ class "rl-cell" ]
                    |> Query.count (Expect.equal 0)
        ]



-- THE WORDS


theWords : Test
theWords =
    describe "the cell in words"
        [ test "nothing tapped and nothing thrown: an invitation, at a kept height" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.find [ class "rl-said" ]
                    |> Query.has [ class "is-none", text "Tap a roll to see what it does for Arie." ]
        , test "a tap says the roll, the value and how likely it is" <|
            \_ ->
                Rolls_.view { config | tapped = Just ( 1, 4 ) } grid
                    |> Query.fromHtml
                    |> Query.find [ class "rl-said" ]
                    |> Query.has [ text "4-1 · −0.007 · 2 in 36" ]
        , test "MOVES adds the engine's play to it -- the cell has no room for it" <|
            \_ ->
                Rolls_.view { config | tapped = Just ( 6, 6 ), moves = True } grid
                    |> Query.fromHtml
                    |> Query.find [ class "rl-said" ]
                    |> Query.has [ text "6-6: 24/18(2) 13/7(2) · +0.489 · 1 in 36" ]
        , test "the thrown roll is said first, and the tapped one after it" <|
            \_ ->
                Rolls_.view { config | outlined = Just ( 5, 6 ), tapped = Just ( 1, 4 ) } grid
                    |> Query.fromHtml
                    |> Query.findAll [ class "rl-said" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 2)
                        , Query.index 0 >> Query.has [ class "is-rolled", text "ROLLED", text "6-5" ]
                        , Query.index 1 >> Query.has [ class "is-picked", text "TAPPED", text "4-1" ]
                        ]
        , test "tapping the roll you threw says it once, not twice" <|
            \_ ->
                Rolls_.view { config | outlined = Just ( 5, 6 ), tapped = Just ( 5, 6 ) } grid
                    |> Query.fromHtml
                    |> Query.findAll [ class "rl-said" ]
                    |> Query.count (Expect.equal 1)
        , test "every cell is readable without the colours" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.findAll [ attr "data-dice" "4-1" ]
                    |> Query.each (Query.has [ attr "aria-label" "4-1 · −0.007 · 2 in 36" ])
        , test "and the drawing as a whole says the best, the worst and how many help" <|
            \_ ->
                bars config
                    |> Query.find [ attr "data-rolls" "bars" ]
                    |> Query.has
                        [ attr "aria-label"
                            ("The 3-ply equity of every roll for Arie."
                                ++ " Best 6-6 at +0.489, worst 4-1 at −0.007."
                                ++ " Of 36 rolls, 32 ahead and 2 behind."
                            )
                        ]
        , test "the map says the same sentence, so either drawing reads aloud" <|
            \_ ->
                Rolls_.view config grid
                    |> Query.fromHtml
                    |> Query.find [ class "rl-map" ]
                    |> Query.has [ text "", attr "aria-label" "The 3-ply equity of every roll for Arie. Best 6-6 at +0.489, worst 4-1 at −0.007. Of 36 rolls, 32 ahead and 2 behind." ]
        , test "a comparison calls its numbers something else" <|
            \_ ->
                bars { config | words = Rolls_.difference }
                    |> Query.find [ attr "data-rolls" "bars" ]
                    |> Query.has [ attr "aria-label" "The 3-ply difference of every roll for Arie. Best 6-6 at +0.489, worst 4-1 at −0.007. Of 36 rolls, 32 better and 2 worse." ]
        ]
