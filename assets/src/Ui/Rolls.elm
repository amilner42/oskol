module Ui.Rolls exposing (Config, Drawing(..), Words, difference, equity, view)

{-| A position's thirty-six rolls, drawn two ways: the six-by-six
temperature map, and the same rolls as bars from best to worst.

One component in three places, as `Ui.Candidates` is one table: the replay's
ROLLS tab, the analysis board's SHOW ROLLS, and two plays compared. Each
page says what its cells are -- which roll was thrown, which cell the
reader tapped, whose roll it is, what the value is called -- and this draws
them the same way.

**The precedent is GNU Backgammon's Temperature Map** (Sho Sengoku): one
cell per roll, coloured by what the roll is worth, with exactly two
switches, for the numbers and for the best play. A player arriving from GNU
should recognise it.

**One fixed, absolute ramp.** A cell is the roll's own equity: 0 is an even
game, +1 the far green end, -1 the far red end, clamped past either. The
scale is the same in every grid and in both halves of a comparison, which
is what lets a reader carry a colour from one picture to another. Nothing
is re-centred on the position's average and nothing is normalised to the
spread in front of it. Two consequences, both wanted: a winning position
reads green and a losing one red, so the map answers "how good is this"
before "which roll do I want"; and two plays that are nearly the same come
out almost entirely neutral, with the one roll that separates them the only
thing with any colour in it.

Two deliberate departures from GNU, both forced:

1.  **The ramp diverges where GNU's is one-sided** (white through dark
    red). Equity is signed and has a real zero; a one-sided ramp cannot
    show a sign. Green is ahead, red is behind, paper is level -- which is
    what green and red already mean everywhere else here (`.g-best`,
    `.g-very_bad`).
2.  **The red arm is hatched.** A red-green pair cannot be told apart by
    anyone with deuteranopia, and the sign is the one thing in this picture
    that must never depend on hue. Every negative cell carries a faint
    45-degree weave -- keyed on `Rolls.signOf`, so it agrees exactly with
    the cell's own number and with the counts in the spoken line. The bars
    need no hatch: a bar's side of the zero line already says it.

**MOVES writes the play under the drawing, not in the cell.** GNU's map is a
window of its own and can afford the notation in the square; ours lives in a
22rem panel, where a cell is about 50 pixels across and `24/18(2) 13/7(2)`
is not going to fit at any size a person can read. So the switch gates the
play in the spoken line and in every cell's `aria-label`, which is where it
is legible at 320 and at a desktop alike -- one behaviour at every width
rather than two.

**The bars are as wide as their rolls are likely.** A double is one cell in
thirty-six and a non-double two, so a double's bar is half the width. Equal
bars would make 6-6 look as important as 6-5, and the picture would lie.

Everything here is pure: a `Config` and a `Grid` in, `Html msg` out. No
model, no subscription, no page. The arithmetic is
`Games.Backgammon.Rolls`.

**How the colour is drawn.** Elm emits one number per cell -- `--rl-t`, the
ramp position as a percentage -- and `assets/css/app.css` mixes it between
three tokens in oklab. So the ends and the middle stay nameable colours in
the stylesheet rather than literals in a view, the interpolation is
perceptually even, and a cell's fill is a pure function of its own equity.
Those tokens are the notebook's own and not the board's, so the drawing is
the same under all twelve board themes -- the panel it sits in is outside
every `.bg-theme-*` scope.

-}

import Games.Backgammon.Rolls as Rolls exposing (Cell, Grid)
import Games.Backgammon.Words as Words
import Html exposing (Attribute, Html, button, div, p, span, text)
import Html.Attributes exposing (attribute, class, classList)
import Html.Events exposing (onClick)
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
import Ui.Charts exposing (num)


{-| Which drawing is on.
-}
type Drawing
    = Map
    | Bars


{-| What this grid's numbers are called. A position's cells are its equity
(`equity`); a comparison's are how much better or worse the second play
does (`difference`). The words appear in the sentence under the drawing and
in the aria-label, so the same picture reads correctly in both places.
-}
type alias Words =
    { value : String
    , up : String
    , down : String
    }


{-| A position's own rolls: the value is the equity the roll leaves, and a
cell that is up is a roll that leaves the player on roll ahead.
-}
equity : Words
equity =
    { value = "equity", up = "ahead", down = "behind" }


{-| Two plays against each other: the value is the difference, and a cell
that is up is a roll the second play does better on.
-}
difference : Words
difference =
    { value = "difference", up = "better", down = "worse" }


{-| What a page says about its rolls.

  - `drawing` is which picture is on; `onDrawing` is told the other one.
  - `numbers` writes the value in each cell; `moves` writes the best play
    in the spoken line and in every cell's `aria-label` (see the note
    above: a cell has no room for a notation at any width we ship).
    `onNumbers` and `onMoves` are the switches.
  - `outlined` is the roll that was actually thrown, ringed in ink and said
    first under the drawing. `Nothing` before a roll. **Either order of the
    faces will do**: a record says 6-5 and the wire says 5-6, so both this
    and `tapped` are put through `Rolls.canonical` before anything is
    compared.
  - `tapped` is the cell the reader last tapped; `onTap` is told a cell's
    dice, canonical.
  - `mover` is the player on roll, named in the sentence.
  - `words` is what the values are called (`luck`, `difference`).
  - `attrs` is anything the page hangs on the component (an id).

-}
type alias Config msg =
    { drawing : Drawing
    , onDrawing : Drawing -> msg
    , numbers : Bool
    , onNumbers : msg
    , moves : Bool
    , onMoves : msg
    , outlined : Maybe ( Int, Int )
    , tapped : Maybe ( Int, Int )
    , onTap : ( Int, Int ) -> msg
    , mover : String
    , words : Words
    , attrs : List (Attribute msg)
    }


{-| The whole thing: the switches, the drawing, the depth, and the cell in
words.

The order is deliberate. The switches are a fixed-height row, so nothing
moves when one is pressed. Both drawings live in the same square box, so
MAP and BARS take turns in one place rather than resizing the panel. The
depth line is next, one line, always. The spoken cell is **last**, because
it is the only part whose height depends on what it says -- a long notation
wraps -- and nothing a reader is looking at sits below it.

-}
view : Config msg -> Grid -> Html msg
view config_ grid =
    let
        -- a page may hand in either order of the faces; everything below
        -- compares against a cell's canonical dice
        config =
            { config_
                | outlined = Maybe.map Rolls.canonical config_.outlined
                , tapped = Maybe.map Rolls.canonical config_.tapped
            }
    in
    div (class "rl" :: config.attrs)
        [ viewBar config
        , div [ class "rl-draw" ]
            [ case config.drawing of
                Map ->
                    viewMap config grid

                Bars ->
                    viewBars config grid
            ]
        , viewDepth grid
        , viewSaid config grid
        ]



-- THE SWITCHES


{-| MAP / BARS and the two switches in one row, in the panel's tab style:
a flex row on an ink rule, the one that is on inverted. A fixed height and
labels that keep their width, so pressing one moves nothing.
-}
viewBar : Config msg -> Html msg
viewBar config =
    let
        press kind name on label_ msg =
            button
                [ classList [ ( "rl-" ++ kind ++ " pixel text-[8px]", True ), ( "is-on", on ) ]
                , attribute ("data-" ++ kind) name
                , attribute "aria-pressed" (bool on)
                , onClick msg
                ]
                [ text label_ ]
    in
    div [ class "rl-controls" ]
        [ div [ class "rl-tabs", attribute "role" "group", attribute "aria-label" "Which drawing" ]
            [ press "tab" "map" (config.drawing == Map) "MAP" (config.onDrawing Map)
            , press "tab" "bars" (config.drawing == Bars) "BARS" (config.onDrawing Bars)
            ]
        , div [ class "rl-switches" ]
            [ press "switch" "numbers" config.numbers "NUMBERS" config.onNumbers
            , press "switch" "moves" config.moves "MOVES" config.onMoves
            ]
        ]


bool : Bool -> String
bool b =
    if b then
        "true"

    else
        "false"



-- THE MAP


{-| Thirty-six cells, six by six, die one down and die two across, each in
its band's colour. The dice sit in a corner at 8px and NUMBERS adds the
value; MOVES does not write in the cell (there is no room) but does reach
every cell's `aria-label`, which is the whole sentence -- so the map is
readable with the colours switched off.
-}
viewMap : Config msg -> Grid -> Html msg
viewMap config grid =
    div
        [ class "rl-map"
        , attribute "role" "group"
        , attribute "aria-label" (sentence config grid)
        ]
        (List.map (viewCell config) (Rolls.mirrored grid.cells))


viewCell : Config msg -> Cell -> Html msg
viewCell config cell =
    button
        [ classList
            [ ( "rl-cell is-" ++ Rolls.signName cell.sign, True )
            , ( "is-lit", lightInk cell )
            , ( "is-out", config.outlined == Just cell.dice )
            , ( "is-tapped", config.tapped == Just cell.dice )
            ]
        , attribute "style" (tStyle cell)
        , attribute "data-sign" (Rolls.signName cell.sign)
        , attribute "data-dice" (Rolls.label cell.dice)
        , attribute "aria-label" (Rolls.inWords { withMove = config.moves } cell)
        , onClick (config.onTap cell.dice)
        ]
        (span [ class "rl-cell-dice pixel" ] [ text (Rolls.label cell.dice) ]
            :: (if config.numbers then
                    [ span [ class "rl-cell-value tabular-nums" ] [ text (Rolls.short cell.value) ] ]

                else
                    []
               )
        )



{-| A cell's place on the ramp, as the one number the stylesheet needs:
`--rl-t` is how far between the neutral and this cell's own end, and
`app.css` mixes the two in oklab from there.
-}
tStyle : Cell -> String
tStyle cell =
    "--rl-t:" ++ num (toFloat (round (Rolls.ramp cell.value * 1000)) / 10) ++ "%"


{-| Where the text turns from black to white, measured rather than chosen:
past 0.72 of the ramp the fill is dark enough that white reads better, and
that crossing is where the worse of the two inks bottoms out at 4.54:1 --
the lowest contrast anywhere on the scale, and still over the 4.5 a number
this size wants. Both ends are the same luminance so one crossing serves
them both; see the measurements in `app.css`.
-}
lightInk : Cell -> Bool
lightInk cell =
    Rolls.ramp cell.value >= 0.72



-- THE BARS


{-| The same rolls best to worst, as `Ui.Charts` draws: inline SVG in a
`viewBox`, no axes, a sentence as both `<title>` and `aria-label`.

Zero is the line through the middle. **A bar is as wide as its roll is
likely** -- a double half a non-double -- so the thirty-six cells of the map
become thirty-six units of width here and the two drawings say the same
thing.

**The height is on the map's scale, not on the grid's own.** A bar reaching
the top is an equity of 1 and nowhere else, so a position where every roll
is worth about the same draws twenty-one flat bars -- which is the truth
about that position, and the thing a per-grid scale would hide by blowing
it up to fill the box. The best and worst rolls are still labelled where
they occur, for the reader who wants the number.

The box is square, the same square the map fills, so the toggle swaps the
drawing without moving the panel.

-}
viewBars : Config msg -> Grid -> Html msg
viewBars config grid =
    let
        cells =
            Rolls.sorted grid.cells

        bars =
            List.foldl (\cell ( x, acc ) -> ( x + toFloat cell.weight, bar config x cell :: acc ))
                ( 0, [] )
                cells
                |> Tuple.second
                |> List.reverse

        said =
            sentence config grid
    in
    Svg.svg
        [ SvgAttr.viewBox "0 0 360 360"
        , SvgAttr.class "rl-bars quiet"
        , attribute "data-rolls" "bars"
        , attribute "role" "img"
        , attribute "aria-label" said
        ]
        (Svg.title [] [ Svg.text said ]
            :: Svg.line
                [ SvgAttr.x1 (num barPadX)
                , SvgAttr.y1 (num barZeroY)
                , SvgAttr.x2 (num (360 - barPadX))
                , SvgAttr.y2 (num barZeroY)
                , SvgAttr.class "rl-bars-zero"
                , attribute "data-zero" "true"
                ]
                []
            :: reach
            ++ bars
            ++ endLabels cells
        )


{-| The ends of the fixed scale, drawn faintly.

Without them the empty half of this box is just empty, and short bars are
ambiguous: a reader cannot tell a flat position from a big scale. With them
the whitespace is the rest of the scale, which is what it is, and the one
property the picture turns on -- that the height means an equity and not a
share of whatever this grid happened to span -- is visible rather than
implied.

-}
reach : List (Svg msg)
reach =
    let
        at y labelY label =
            [ Svg.line
                [ SvgAttr.x1 (num barPadX)
                , SvgAttr.y1 (num y)
                , SvgAttr.x2 (num (360 - barPadX))
                , SvgAttr.y2 (num y)
                , SvgAttr.class "rl-bars-reach"
                ]
                []
            , Svg.text_
                [ SvgAttr.x (num (360 - barPadX - 1))
                , SvgAttr.y (num labelY)
                , SvgAttr.textAnchor "end"
                , SvgAttr.class "rl-bars-reach-label"
                ]
                [ Svg.text label ]
            ]
    in
    -- the labels sit inside the plot, clear of the best and worst roll's own
    -- labels above and below it
    at (barZeroY - barReach) (barZeroY - barReach + 13) "+1"
        ++ at (barZeroY + barReach) (barZeroY + barReach - 5) "−1"


{-| Left and right of the plot, inset from the edges.
-}
barPadX : Float
barPadX =
    7


{-| Zero, a little below the middle: the top of the box carries the best
roll's label and the bottom the worst's.
-}
barZeroY : Float
barZeroY =
    186


{-| How far a bar may reach either way.
-}
barReach : Float
barReach =
    146


{-| One unit of weight, in viewBox units: the thirty-six of them fill the
plot.
-}
barUnit : Float
barUnit =
    (360 - 2 * barPadX) / 36


bar : Config msg -> Float -> Cell -> Svg msg
bar config before cell =
    let
        height =
            max 2 (Rolls.ramp cell.value * barReach)

        y =
            if cell.value >= 0 then
                barZeroY - height

            else
                barZeroY
    in
    Svg.rect
        [ SvgAttr.x (num (barPadX + before * barUnit + 0.6))
        , SvgAttr.y (num y)
        , SvgAttr.width (num (toFloat cell.weight * barUnit - 1.2))
        , SvgAttr.height (num height)
        , SvgAttr.rx "2"
        , SvgAttr.class
            ("rl-bar is-"
                ++ Rolls.signName cell.sign
                ++ (if config.outlined == Just cell.dice then
                        " is-out"

                    else
                        ""
                   )
            )
        , attribute "style" (tStyle cell)
        , attribute "data-dice" (Rolls.label cell.dice)
        , attribute "data-sign" (Rolls.signName cell.sign)
        , attribute "data-weight" (String.fromInt cell.weight)
        , attribute "data-out" (bool (config.outlined == Just cell.dice))
        ]
        []


{-| The two ends named where they are: the best roll over the left end of
the plot, the worst under the right.
-}
endLabels : List Cell -> List (Svg msg)
endLabels cells =
    let
        at anchor x y cell =
            Svg.text_
                [ SvgAttr.x (num x)
                , SvgAttr.y (num y)
                , SvgAttr.textAnchor anchor
                , SvgAttr.class "rl-bars-end"
                ]
                [ Svg.text (Rolls.label cell.dice ++ " " ++ Rolls.short cell.value) ]
    in
    case ( List.head cells, List.head (List.reverse cells) ) of
        ( Just best, Just worst ) ->
            [ at "start" (barPadX + 1) 20 best
            , at "end" (360 - barPadX - 1) 350 worst
            ]

        _ ->
            []


-- THE WORDS UNDER IT


{-| The quiet line that keeps the two numbers from reading as a
disagreement: the grid's depth, and the figure it is the average of. The
engine's own number, never recomputed here.
-}
viewDepth : Grid -> Html msg
viewDepth grid =
    p [ class "rl-depth" ]
        [ text (Rolls.levelInWords grid.level ++ " · averages to " ++ Words.signed grid.equity) ]


{-| The cell in words. The roll that was thrown is said first and always;
the tapped cell follows it, unless it is the same cell. Two lines of room
are kept whether or not there is anything to say, so the usual tap moves
nothing.
-}
viewSaid : Config msg -> Grid -> Html msg
viewSaid config grid =
    let
        say which dice =
            grid.cells
                |> List.filter (\c -> c.dice == dice)
                |> List.head
                |> Maybe.map
                    (\c ->
                        p [ class ("rl-said " ++ which) ]
                            [ span [ class "rl-said-tag pixel" ] [ text (tagOf which) ]
                            , text (Rolls.inWords { withMove = config.moves } c)
                            ]
                    )

        tapped =
            case ( config.tapped, config.outlined ) of
                ( Just d, Just o ) ->
                    if d == o then
                        Nothing

                    else
                        say "is-picked" d

                ( Just d, Nothing ) ->
                    say "is-picked" d

                _ ->
                    Nothing

        lines =
            List.filterMap identity
                [ Maybe.andThen (say "is-rolled") config.outlined, tapped ]
    in
    div [ class "rl-saids" ]
        (if List.isEmpty lines then
            [ p [ class "rl-said is-none" ] [ text ("Tap a roll to see what it does for " ++ config.mover ++ ".") ] ]

         else
            lines
        )


tagOf : String -> String
tagOf which =
    if which == "is-rolled" then
        "ROLLED"

    else
        "TAPPED"


{-| What the picture says, in one sentence, for a reader who is not looking
at it: the best roll, the worst, and how many of the thirty-six fall each
side of the middle.

**Both sides, not just the helpful one.** The hatch on the red arm is there
because the sign of a cell must not depend on hue; a sentence that only
counted the green half would leave the same reader to work the other one
out, and the ones inside the dead zone are neither, so it cannot be
subtracted. The two counts are by sign, which is exactly what the hatch is.

-}
sentence : Config msg -> Grid -> String
sentence config grid =
    let
        cells =
            Rolls.sorted grid.cells

        name cell =
            Rolls.label cell.dice ++ " at " ++ Words.signed cell.value
    in
    case ( List.head cells, List.head (List.reverse cells) ) of
        ( Just best, Just worst ) ->
            String.join " "
                [ "The " ++ Rolls.levelInWords grid.level ++ " " ++ config.words.value ++ " of every roll for " ++ config.mover ++ "."
                , "Best " ++ name best ++ ", worst " ++ name worst ++ "."
                , "Of 36 rolls, "
                    ++ String.fromInt (Rolls.helped grid.cells)
                    ++ " "
                    ++ config.words.up
                    ++ " and "
                    ++ String.fromInt (Rolls.hurt grid.cells)
                    ++ " "
                    ++ config.words.down
                    ++ "."
                ]

        _ ->
            "No rolls."
