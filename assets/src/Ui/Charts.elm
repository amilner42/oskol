module Ui.Charts exposing
    ( days
    , daysSentence
    , grid
    , gridColumns
    , gridFromCounts
    , gridStepping
    , ladder
    , miniRing
    , num
    , patched
    , prLine
    , ring
    , rolling
    , windowPr
    )

{-| The pictures the signed-in home is allowed: your PR over time, your
mistakes as a ladder, the last thirty days, and one bar per band of
mistake showing how much of it you have patched.

They are the only drawings on that page -- everything else is type and
white space -- so they are deliberately small and quiet: no axes, no
grid, no legend, no tooltip. Each one is inline SVG laid out in a
`viewBox`, so it reads at 320 and grows to a desktop column without a
second set of numbers; each one carries a `<title>` and an `aria-label`
sentence that says the same thing the picture does, because a number
nobody can hear is not a number.

Everything here is pure: a list in, `Html msg` out. No model, no message,
no page. The page ticket wires them; this module knows nothing about
where they land.

The palette is the notebook's own (`assets/css/app.css`): `--ink` for the
mark that matters, `--pencil` for the mark that is context. The ladder is
the one place that interpolates, so it carries the two ends of its ramp
as literals -- the paper grey of an empty slot and `.g-best`'s green --
and says so.

-}

import Html exposing (Html)
import Html.Attributes exposing (attribute)
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr



-- PR LINE


{-| Every graded game a small dot, and the rolling decision-weighted PR
drawn through them. Oldest first.

`window` is how many games the line averages over (the home passes 20).
There are no axes: the y scale comes from the data with a little
headroom, and the line's lowest and highest values are labelled where
they occur, which is the only scale a reader needs to answer "am I
improving?".

A PR is lower-is-better, and the y axis is the plain one -- a bigger
number sits higher -- so a line that falls is a player getting better.

Under three graded games there is nothing worth a slope, so it draws a
flat placeholder (`data-placeholder="true"`) and no numbers.

-}
prLine : { games : List { pr : Float, decisions : Int }, window : Int } -> Html msg
prLine config =
    let
        games =
            config.games

        count =
            List.length games
    in
    if count < 3 then
        figure "chart-pr"
            "0 0 320 96"
            "Not enough graded games to chart yet."
            [ attribute "data-placeholder" "true" ]
            [ Svg.line
                [ SvgAttr.x1 (num prPadX)
                , SvgAttr.y1 (num (prPadTop + prPlotH / 2))
                , SvgAttr.x2 (num (320 - prPadX))
                , SvgAttr.y2 (num (prPadTop + prPlotH / 2))
                , SvgAttr.stroke "var(--pencil)"
                , SvgAttr.strokeWidth "1.5"
                , SvgAttr.strokeOpacity "0.35"
                , SvgAttr.strokeDasharray "4 5"
                , SvgAttr.strokeLinecap "round"
                ]
                []
            ]

    else
        let
            line =
                rolling config.window games

            scale =
                prScale games line

            dots =
                List.indexedMap
                    (\i game ->
                        Svg.circle
                            [ SvgAttr.cx (num (prX count i))
                            , SvgAttr.cy (num (scale game.pr))
                            , SvgAttr.r "2"
                            , SvgAttr.fill "var(--pencil)"
                            , SvgAttr.fillOpacity "0.5"
                            ]
                            []
                    )
                    games

            points =
                List.indexedMap (\i value -> Maybe.map (\v -> ( prX count i, scale v )) value) line

            strokes =
                List.map prStroke (runs points)
        in
        figure "chart-pr"
            "0 0 320 96"
            (prSentence count line)
            [ attribute "data-games" (String.fromInt count) ]
            (dots ++ strokes ++ prLabels count line scale)


{-| The rolling decision-weighted PR at each game, oldest first: the value
at game `i` is taken over games `i - window + 1 .. i`.

The engine scores one game as `error / decisions * 500`, so a window's
own PR is the sum of the errors over the sum of the decisions, times 500.
A game's error is `pr * decisions / 500`, and the two 500s cancel: the
window's PR is exactly the decision-weighted mean of its games' PRs, so a
nine-turn game does not weigh like an eighty-nine-turn one. That
cancellation is why this is safe to compute from `pr` and `decisions`
alone, with no error column on the wire.

A window whose games made no decisions at all has no PR: it is `Nothing`,
never zero, and the line is simply not drawn across it.

-}
rolling : Int -> List { pr : Float, decisions : Int } -> List (Maybe Float)
rolling window games =
    let
        size =
            max 1 window
    in
    List.indexedMap
        (\i _ -> windowPr (List.take (min size (i + 1)) (List.drop (max 0 (i + 1 - size)) games)))
        games


{-| The decision-weighted PR of one bag of games, or `Nothing` when they
carry no decisions between them. See `rolling` for why this is a weighted
mean and not a mean of ratios.
-}
windowPr : List { pr : Float, decisions : Int } -> Maybe Float
windowPr games =
    let
        decisions =
            List.sum (List.map (\g -> toFloat g.decisions) games)

        weighted =
            List.sum (List.map (\g -> g.pr * toFloat g.decisions) games)
    in
    if decisions <= 0 then
        Nothing

    else
        Just (weighted / decisions)


prPadX : Float
prPadX =
    8


prPadTop : Float
prPadTop =
    14


prPlotH : Float
prPlotH =
    68


prX : Int -> Int -> Float
prX count i =
    let
        span =
            320 - 2 * prPadX
    in
    if count <= 1 then
        prPadX + span / 2

    else
        prPadX + span * toFloat i / toFloat (count - 1)


{-| Value to y, from the data with a little headroom so no mark sits on
an edge. A run of identical PRs still gets a band to sit in the middle
of rather than a division by zero.
-}
prScale : List { pr : Float, decisions : Int } -> List (Maybe Float) -> (Float -> Float)
prScale games line =
    let
        values =
            List.map .pr games ++ List.filterMap identity line

        lo =
            Maybe.withDefault 0 (List.minimum values)

        hi =
            Maybe.withDefault 0 (List.maximum values)

        headroom =
            max 0.5 ((hi - lo) * 0.15)

        low =
            lo - headroom

        high =
            hi + headroom
    in
    \value -> prPadTop + prPlotH * (high - value) / max 0.001 (high - low)


prStroke : List ( Float, Float ) -> Svg msg
prStroke run =
    Svg.polyline
        [ SvgAttr.points (String.join " " (List.map (\( x, y ) -> num x ++ "," ++ num y) run))
        , SvgAttr.fill "none"
        , SvgAttr.stroke "var(--ink)"
        , SvgAttr.strokeWidth "1.8"
        , SvgAttr.strokeLinecap "round"
        , SvgAttr.strokeLinejoin "round"
        ]
        []


{-| The line's best and worst, labelled at the point each happens, which
is the whole of the scale a reader is given. A label near the right edge
hangs to the left of its point so it never leaves the box.

A player whose every window came out the same has one value, not two, so
a flat line is labelled once rather than twice in the same place.

-}
prLabels : Int -> List (Maybe Float) -> (Float -> Float) -> List (Svg msg)
prLabels count line scale =
    let
        drawn =
            List.filterMap (\( i, value ) -> Maybe.map (Tuple.pair i) value)
                (List.indexedMap Tuple.pair line)

        lowest =
            best (<) drawn

        highest =
            best (>) drawn

        at pick nudge =
            case pick of
                Nothing ->
                    []

                Just ( i, value ) ->
                    let
                        x =
                            prX count i

                        rightish =
                            x > 320 / 2
                    in
                    [ Svg.text_
                        [ SvgAttr.x
                            (num
                                (if rightish then
                                    x - 4

                                 else
                                    x + 4
                                )
                            )
                        , SvgAttr.y (num (clamp 8 92 (scale value + nudge)))
                        , SvgAttr.textAnchor
                            (if rightish then
                                "end"

                             else
                                "start"
                            )
                        , SvgAttr.fontSize "8"
                        , SvgAttr.fill "var(--pencil)"
                        ]
                        [ Svg.text (oneDecimal value) ]
                    ]
    in
    if Maybe.map Tuple.second highest == Maybe.map Tuple.second lowest then
        at highest (-3.5)

    else
        at highest (-3.5) ++ at lowest 8.5


{-| The first entry whose value wins under `better`, so the min and the
max come out of one walk and ties keep the earlier game.
-}
best : (Float -> Float -> Bool) -> List ( Int, Float ) -> Maybe ( Int, Float )
best better entries =
    List.foldl
        (\entry carry ->
            case carry of
                Nothing ->
                    Just entry

                Just held ->
                    if better (Tuple.second entry) (Tuple.second held) then
                        Just entry

                    else
                        Just held
        )
        Nothing
        entries


prSentence : Int -> List (Maybe Float) -> String
prSentence count line =
    let
        recent =
            List.foldl (\value carry -> Maybe.withDefault carry (Maybe.map Just value)) Nothing line

        games =
            "PR over your last " ++ String.fromInt count ++ " games"
    in
    case recent of
        Nothing ->
            games ++ "."

        Just value ->
            games ++ ", recent " ++ oneDecimal value ++ "."



-- LADDER


{-| The practice deck as eight bars, level 0 on the left ("new") to level
7 on the right ("known"), so mastering a mistake is a card climbing off
the left.

The bars scale to the tallest, and their colour deepens across the levels
from the paper grey of an empty slot to `.g-best`'s green, so the climb
reads as a climb and not as eight arbitrary columns. A count sits on top
of a bar that has one; only the two ends are labelled, because the six
levels between them have no names a player would recognise.

A deck with nothing in it still draws its eight empty slots: the shape of
what practice will fill.

-}
ladder : List Int -> Html msg
ladder counts =
    let
        levels =
            List.take 8 (counts ++ List.repeat 8 0)

        top =
            Maybe.withDefault 0 (List.maximum levels)

        bars =
            List.indexedMap (ladderBar top) levels
    in
    figure "chart-ladder"
        "0 0 320 110"
        (ladderSentence levels)
        [ attribute "data-cards" (String.fromInt (List.sum levels)) ]
        (List.concat bars ++ [ endLabel 0 "new", endLabel 7 "known" ])


ladderBase : Float
ladderBase =
    88


ladderTop : Float
ladderTop =
    20


ladderBarW : Float
ladderBarW =
    (320 - 2 * 10 - 7 * 6) / 8


ladderX : Int -> Float
ladderX level =
    10 + toFloat level * (ladderBarW + 6)


ladderBar : Int -> Int -> Int -> List (Svg msg)
ladderBar top level count =
    let
        x =
            ladderX level

        full =
            ladderBase - ladderTop

        height =
            if top <= 0 then
                0

            else
                full * toFloat count / toFloat top

        slot =
            Svg.rect
                [ SvgAttr.x (num x)
                , SvgAttr.y (num ladderTop)
                , SvgAttr.width (num ladderBarW)
                , SvgAttr.height (num full)
                , SvgAttr.rx "2"
                , SvgAttr.fill "none"
                , SvgAttr.stroke "var(--pencil)"
                , SvgAttr.strokeOpacity "0.3"
                , SvgAttr.strokeWidth "1"
                ]
                []

        bar =
            if count <= 0 then
                []

            else
                [ Svg.rect
                    [ SvgAttr.x (num x)
                    , SvgAttr.y (num (ladderBase - height))
                    , SvgAttr.width (num ladderBarW)
                    , SvgAttr.height (num height)
                    , SvgAttr.rx "2"
                    , SvgAttr.fill (ladderColour level)
                    , attribute "data-count" (String.fromInt count)
                    ]
                    []
                , Svg.text_
                    [ SvgAttr.x (num (x + ladderBarW / 2))
                    , SvgAttr.y (num (ladderBase - height - 4))
                    , SvgAttr.textAnchor "middle"
                    , SvgAttr.fontSize "9"
                    , SvgAttr.fill "var(--ink)"
                    ]
                    [ Svg.text (String.fromInt count) ]
                ]
    in
    slot :: bar


endLabel : Int -> String -> Svg msg
endLabel level label =
    Svg.text_
        [ SvgAttr.x (num (ladderX level + ladderBarW / 2))
        , SvgAttr.y "101"
        , SvgAttr.textAnchor "middle"
        , SvgAttr.fontSize "8"
        , SvgAttr.fill "var(--pencil)"
        ]
        [ Svg.text label ]


{-| Level 0's paper grey to level 7's `.g-best` green (#1f7a45), mixed
straight in RGB: eight steps is few enough that nothing muddy happens in
the middle.
-}
ladderColour : Int -> String
ladderColour level =
    let
        t =
            toFloat level / 7

        mix from to =
            round (from + (to - from) * t)
    in
    "rgb(" ++ String.fromInt (mix 222 31) ++ "," ++ String.fromInt (mix 217 122) ++ "," ++ String.fromInt (mix 203 69) ++ ")"


ladderSentence : List Int -> String
ladderSentence levels =
    let
        total =
            List.sum levels
    in
    if total <= 0 then
        "Practice deck: no cards yet."

    else
        "Practice deck: "
            ++ plural total "card"
            ++ ", "
            ++ String.fromInt (Maybe.withDefault 0 (List.head levels))
            ++ " new, "
            ++ String.fromInt (Maybe.withDefault 0 (List.head (List.reverse levels)))
            ++ " known."



-- DAYS


{-| The last thirty days, oldest first, today at the right: a square per
day, filled in ink where there was practice and drawn in pencil where
there was not.

It is a record and not a goal -- there is no streak here on purpose --
so the only words are how long a stretch you are looking at.

-}
days : List Bool -> Html msg
days marks =
    let
        padded =
            List.repeat 30 False ++ marks

        thirty =
            List.drop (List.length padded - 30) padded
    in
    figure "chart-days"
        "0 0 320 30"
        (daysSentence thirty)
        [ attribute "data-practiced" (String.fromInt (List.length (List.filter identity thirty))) ]
        (List.indexedMap dayCell thirty
            ++ [ Svg.text_
                    [ SvgAttr.x "3.5"
                    , SvgAttr.y "25"
                    , SvgAttr.fontSize "7"
                    , SvgAttr.fill "var(--pencil)"
                    ]
                    [ Svg.text "30 days" ]
               ]
        )


dayCell : Int -> Bool -> Svg msg
dayCell index practiced =
    let
        common =
            [ SvgAttr.x (num (3.5 + toFloat index * 10.5))
            , SvgAttr.y "3"
            , SvgAttr.width "8.5"
            , SvgAttr.height "8.5"
            , SvgAttr.rx "1.5"
            ]

        paint =
            if practiced then
                [ SvgAttr.fill "var(--ink)" ]

            else
                [ SvgAttr.fill "none"
                , SvgAttr.stroke "var(--pencil)"
                , SvgAttr.strokeOpacity "0.45"
                , SvgAttr.strokeWidth "1"
                ]
    in
    Svg.rect (common ++ paint) []


daysSentence : List Bool -> String
daysSentence thirty =
    let
        hit =
            List.length (List.filter identity thirty)
    in
    if hit == 0 then
        "No practice in the last 30 days."

    else
        "Practiced on " ++ plural hit "day" ++ " of the last 30."



-- A BAND, AND THE THREE STATES ITS MISTAKES ARE IN


{-| `.g-best`'s green, as the ladder's top rung uses it: the one colour
on this page that means "there, done".
-}
patchedGreen : String
patchedGreen =
    "#1f7a45"


{-| One band of mistakes as a bar, in the three states a mistake can be
in: the ones being worked on in the highlighter yellow the doubtful band
is marked in, then the ones patched in the same green the best move is
drawn in, over the paper of the ones not started.

**Two colours, because patched takes weeks.** Level 4 is four right
answers, and the earliest a card reaches it is twelve days after the
first: a bar that only knew patched from not-patched would sit empty
while a player was working through fifty mistakes. In progress is drawn
first, patched beside it, in the order `Ui.Mistakes.line` says them, so
a card being fixed is visibly somewhere.

**The one picture here that is not read out.** Every other one carries
its own sentence because nothing else says what it says; this one is
always drawn under its line in words (`Ui.Mistakes.line`, which is handed
in and kept on the `<title>` for a hover), so a reader who is told both
hears the same thing twice. It is `aria-hidden` and the words beside it
are what is read.

The two states are clamped against the band: neither can draw wider than
the mistakes it is about, and together they never pass its end.

-}
patched : { total : Int, inProgress : Int, patched : Int, sentence : String } -> Html msg
patched band =
    let
        total =
            max 0 band.total

        done =
            clamp 0 total band.patched

        going =
            clamp 0 (total - done) band.inProgress

        width n =
            if total <= 0 then
                0

            else
                barW * toFloat n / toFloat total

        part name fill x n =
            if n <= 0 then
                []

            else
                [ Svg.rect
                    [ SvgAttr.x (num (width x))
                    , SvgAttr.y "0"
                    , SvgAttr.width (num (width n))
                    , SvgAttr.height "10"
                    , SvgAttr.rx "2"
                    , SvgAttr.fill fill
                    , attribute "data-part" name
                    ]
                    []
                ]
    in
    Svg.svg
        [ SvgAttr.viewBox "0 0 320 10"
        , SvgAttr.class "chart-patched quiet w-full h-auto block"
        , attribute "aria-hidden" "true"
        , attribute "data-total" (String.fromInt total)
        , attribute "data-in-progress" (String.fromInt going)
        , attribute "data-patched" (String.fromInt done)
        ]
        (Svg.title [] [ Svg.text band.sentence ]
            :: Svg.rect
                [ SvgAttr.x "0"
                , SvgAttr.y "0"
                , SvgAttr.width (num barW)
                , SvgAttr.height "10"
                , SvgAttr.rx "2"
                , SvgAttr.fill barRest
                , attribute "data-part" "to-fix"
                ]
                []
            :: part "in-progress" barGoing 0 going
            ++ part "patched" patchedGreen going done
        )


barW : Float
barW =
    320


{-| Paper, for a mistake still to fix.
-}
barRest : String
barRest =
    "rgb(222,217,203)"


{-| The highlighter yellow `.g-doubtful` is marked in: work under way,
which is not yet the green that means done.
-}
barGoing : String
barGoing =
    "#d9a100"



-- THE MASTERY GRID


{-| A deck's size and how much of it is learnt, in one picture: a square
per position, coloured by the rung it is on.

  - paper for a position never started,
  - a pale yellow for one started and back at the bottom rung (a miss),
  - three deepening yellows for levels 1 to 3 -- the highlighter is the
    work under way,
  - the best move's green from the patched rung up,
  - paper with a hairline of ink for one the player put away (NEVER).

Squares are 10 units on a 12 pitch, `columns` to a row. Left out, the
columns are a tier's: `ceil (sqrt n * 1.6)`, at most 24, so a handful of
mistakes is a small block and a few hundred a wide one, and the area of
the block is how many there are. The `viewBox` is a function of the count
alone, so a page can hold the grid's place before it knows a single level
and nothing moves when they land. Drawn at `--sq` (CSS) a square, and
never wider than its column.

The picture says nothing a reader cannot hear: it is `aria-hidden`, and
the sentence beside it (handed in, and kept on the `<title>` for a hover)
is the state line in words.

-}
grid : { cells : List { level : Int, status : String }, columns : Maybe Int, patchedLevel : Int, sentence : String } -> Html msg
grid config =
    let
        count =
            List.length config.cells

        columns =
            gridColumns config.columns count

        rows =
            max 1 (ceiling (toFloat count / toFloat columns))

        width =
            toFloat columns * gridPitch - (gridPitch - gridSquare)

        height =
            toFloat rows * gridPitch - (gridPitch - gridSquare)

        square index cell =
            let
                x =
                    toFloat (modBy columns index) * gridPitch

                y =
                    toFloat (index // columns) * gridPitch

                ( fill, edge ) =
                    gridPaint config.patchedLevel cell

                lit =
                    cell.status /= "new" && cell.status /= "suspended"
            in
            Svg.rect
                ([ SvgAttr.x (num x)
                 , SvgAttr.y (num y)
                 , SvgAttr.width (num gridSquare)
                 , SvgAttr.height (num gridSquare)
                 , SvgAttr.rx "2"
                 , SvgAttr.fill fill
                 , attribute "data-level" (String.fromInt cell.level)
                 , attribute "data-status" cell.status
                 , SvgAttr.class
                    (if lit then
                        "grid-sq is-lit"

                     else
                        "grid-sq"
                    )
                 , attribute "style" ("--i:" ++ String.fromInt index)
                 ]
                    ++ (case edge of
                            Just colour ->
                                [ SvgAttr.stroke colour, SvgAttr.strokeWidth "1" ]

                            Nothing ->
                                []
                       )
                )
                []
    in
    Svg.svg
        [ SvgAttr.viewBox ("0 0 " ++ num (max width gridSquare) ++ " " ++ num (max height gridSquare))
        , SvgAttr.class "chart-grid block"
        , attribute "aria-hidden" "true"
        , attribute "data-count" (String.fromInt count)
        , attribute "data-columns" (String.fromInt columns)
        , attribute "data-rows" (String.fromInt rows)
        , attribute "style" ("--cols:" ++ String.fromInt columns ++ ";--rows:" ++ String.fromInt rows)
        ]
        (Svg.title [] [ Svg.text config.sentence ] :: List.indexedMap square config.cells)


{-| The same grid with some of its squares stepping up: each stepping
square is drawn twice, the shade it was under the shade it is now, and
the one on top carries `grid-step` and its place in the sequence
(`--k`, oldest first) so the page can bring it in one after another. The
picture's box is `grid`'s for the same count, so swapping one for the
other moves nothing. Every other square is drawn exactly as `grid` draws
it, and with reduced motion the top square is simply there.
-}
gridStepping :
    { cells : List { level : Int, status : String, from : Maybe { level : Int, status : String }, order : Int }
    , columns : Maybe Int
    , patchedLevel : Int
    , sentence : String
    }
    -> Html msg
gridStepping config =
    let
        count =
            List.length config.cells

        columns =
            gridColumns config.columns count

        rows =
            max 1 (ceiling (toFloat count / toFloat columns))

        width =
            toFloat columns * gridPitch - (gridPitch - gridSquare)

        height =
            toFloat rows * gridPitch - (gridPitch - gridSquare)

        rect index cell extra =
            let
                ( fill, edge ) =
                    gridPaint config.patchedLevel cell
            in
            Svg.rect
                ([ SvgAttr.x (num (toFloat (modBy columns index) * gridPitch))
                 , SvgAttr.y (num (toFloat (index // columns) * gridPitch))
                 , SvgAttr.width (num gridSquare)
                 , SvgAttr.height (num gridSquare)
                 , SvgAttr.rx "2"
                 , SvgAttr.fill fill
                 ]
                    ++ extra
                    ++ (case edge of
                            Just colour ->
                                [ SvgAttr.stroke colour, SvgAttr.strokeWidth "1" ]

                            Nothing ->
                                []
                       )
                )
                []

        square index cell =
            let
                now =
                    { level = cell.level, status = cell.status }

                marks =
                    [ attribute "data-level" (String.fromInt cell.level)
                    , attribute "data-status" cell.status
                    ]
            in
            case cell.from of
                Just was ->
                    [ rect index was [ SvgAttr.class "grid-sq is-was", attribute "data-was" (String.fromInt was.level) ]
                    , rect index
                        now
                        (marks
                            ++ [ SvgAttr.class "grid-sq grid-step"
                               , attribute "data-step" (String.fromInt cell.order)
                               , attribute "style" ("--k:" ++ String.fromInt cell.order)
                               ]
                        )

                    -- A ring that spreads from the square as it steps up and
                    -- fades: the eye goes to the square that changed. Unseen
                    -- when nothing moves.
                    , Svg.rect
                        [ SvgAttr.x (num (toFloat (modBy columns index) * gridPitch))
                        , SvgAttr.y (num (toFloat (index // columns) * gridPitch))
                        , SvgAttr.width (num gridSquare)
                        , SvgAttr.height (num gridSquare)
                        , SvgAttr.rx "2"
                        , SvgAttr.fill "none"
                        , SvgAttr.stroke (Tuple.first (gridPaint config.patchedLevel now))
                        , SvgAttr.strokeWidth "1.5"
                        , SvgAttr.class "grid-ping"
                        , attribute "style" ("--k:" ++ String.fromInt cell.order)
                        ]
                        []
                    ]

                Nothing ->
                    [ rect index now (marks ++ [ SvgAttr.class "grid-sq" ]) ]
    in
    Svg.svg
        [ SvgAttr.viewBox ("0 0 " ++ num (max width gridSquare) ++ " " ++ num (max height gridSquare))
        , SvgAttr.class "chart-grid is-stepping block"
        , attribute "aria-hidden" "true"
        , attribute "data-count" (String.fromInt count)
        , attribute "data-columns" (String.fromInt columns)
        , attribute "data-rows" (String.fromInt rows)
        , attribute "style" ("--cols:" ++ String.fromInt columns ++ ";--rows:" ++ String.fromInt rows)
        ]
        (Svg.title [] [ Svg.text config.sentence ] :: List.concat (List.indexedMap square config.cells))


{-| A tier's columns, or the ones asked for: `ceil (sqrt n * 1.6)`, never
more than 24 and never more than there are squares.
-}
gridColumns : Maybe Int -> Int -> Int
gridColumns asked count =
    case asked of
        Just n ->
            max 1 n

        Nothing ->
            count
                |> toFloat
                |> sqrt
                |> (*) 1.6
                |> ceiling
                |> min 24
                |> min count
                |> max 1


gridSquare : Float
gridSquare =
    10


gridPitch : Float
gridPitch =
    12


{-| A square's fill, and the edge it is drawn with when it has one.
-}
gridPaint : Int -> { level : Int, status : String } -> ( String, Maybe String )
gridPaint patchedLevel cell =
    if cell.status == "suspended" then
        ( barRest, Just "#23243a" )

    else if cell.status == "new" then
        ( barRest, Nothing )

    else if cell.level >= max 1 patchedLevel then
        ( patchedGreen, Nothing )

    else
        case cell.level of
            1 ->
                ( "#f2d27a", Nothing )

            2 ->
                ( "#e6bd3a", Nothing )

            3 ->
                ( "#d9a100", Nothing )

            _ ->
                ( "#f6e7b8", Nothing )


{-| The same squares from counts alone, in the order that reads as
progress: patched first, then the yellows deepest first, then the ones
started and back at the bottom, then the ones never started. What the
practice home draws, where it has the counts but not each position.

`levels` is how many sit on each rung, lowest first; the untouched are
counted among the bottom rung's and are taken back out of it.

-}
gridFromCounts : { levels : List Int, untouched : Int, total : Int } -> List { level : Int, status : String }
gridFromCounts counts =
    let
        onRung =
            List.indexedMap Tuple.pair counts.levels

        started rung n =
            if rung == 0 then
                max 0 (n - counts.untouched)

            else
                max 0 n

        lit =
            onRung
                |> List.reverse
                |> List.concatMap (\( rung, n ) -> List.repeat (started rung n) { level = rung, status = "active" })

        untouched =
            List.repeat (max 0 (counts.total - List.length lit)) { level = 0, status = "new" }
    in
    List.take (max 0 counts.total) (lit ++ untouched)



-- TODAY'S RING


{-| Today: how much of today's set is done. A 40-unit ring, the paper
track under the best move's green, and the fraction in the middle in the
pixel font -- "3/5" -- or a check drawn in once the set is done, or a
dash on a day with nothing in it.

The arc is the one thing on the page that moves when an answer lands, so
it is drawn as a dash over a path of length 100 and the page animates the
dash alone; the ring's box never changes. `aria-hidden`: its words are
beside it.

-}
ring : { done : Int, target : Int, label : String } -> Html msg
ring config =
    let
        done =
            max 0 config.done

        target =
            max 0 config.target

        complete =
            target > 0 && done >= target

        fraction =
            if target <= 0 then
                0

            else
                min 1 (toFloat done / toFloat target)

        middle =
            if complete then
                Svg.path
                    [ SvgAttr.d "M13.5 20.5 L18 25 L27 15"
                    , SvgAttr.fill "none"
                    , SvgAttr.stroke patchedGreen
                    , SvgAttr.strokeWidth "3.4"
                    , SvgAttr.strokeLinecap "round"
                    , SvgAttr.strokeLinejoin "round"
                    , SvgAttr.class "ring-check"
                    , attribute "pathLength" "1"
                    ]
                    []

            else
                let
                    words =
                        if target <= 0 then
                            "—"

                        else
                            String.fromInt done ++ "/" ++ String.fromInt target
                in
                Svg.text_
                    [ SvgAttr.x "20"
                    , SvgAttr.y "20"
                    , SvgAttr.textAnchor "middle"
                    , SvgAttr.dominantBaseline "central"
                    , SvgAttr.fontSize (num (min 8 (24 / toFloat (max 1 (String.length words)))))
                    , SvgAttr.class "ring-words"
                    , SvgAttr.fill "var(--ink)"
                    ]
                    [ Svg.text words ]
    in
    Svg.svg
        [ SvgAttr.viewBox "0 0 40 40"
        , SvgAttr.class
            (if complete then
                "chart-ring is-done block"

             else
                "chart-ring block"
            )
        , attribute "aria-hidden" "true"
        , attribute "data-done" (String.fromInt done)
        , attribute "data-target" (String.fromInt target)
        ]
        [ Svg.title [] [ Svg.text config.label ]
        , ringTrack 16 4
        , ringArc 16 4 fraction
        , middle
        ]


{-| The same ring at row size: the arc alone, no words -- at 20 pixels a
fraction is a smudge, and the row says its number beside it.
-}
miniRing : { done : Int, target : Int, label : String } -> Html msg
miniRing config =
    let
        target =
            max 0 config.target

        fraction =
            if target <= 0 then
                0

            else
                min 1 (toFloat (max 0 config.done) / toFloat target)
    in
    Svg.svg
        [ SvgAttr.viewBox "0 0 40 40"
        , SvgAttr.class
            (if target > 0 && config.done >= target then
                "chart-ring mini is-done block"

             else
                "chart-ring mini block"
            )
        , attribute "aria-hidden" "true"
        , attribute "data-done" (String.fromInt (max 0 config.done))
        , attribute "data-target" (String.fromInt target)
        ]
        [ Svg.title [] [ Svg.text config.label ]
        , ringTrack 15 7
        , ringArc 15 7 fraction
        ]


ringTrack : Float -> Float -> Svg msg
ringTrack radius stroke =
    Svg.circle
        [ SvgAttr.cx "20"
        , SvgAttr.cy "20"
        , SvgAttr.r (num radius)
        , SvgAttr.fill "none"
        , SvgAttr.stroke barRest
        , SvgAttr.strokeWidth (num stroke)
        ]
        []


ringArc : Float -> Float -> Float -> Svg msg
ringArc radius stroke fraction =
    Svg.circle
        [ SvgAttr.cx "20"
        , SvgAttr.cy "20"
        , SvgAttr.r (num radius)
        , SvgAttr.fill "none"
        , SvgAttr.stroke patchedGreen
        , SvgAttr.strokeWidth (num stroke)
        , SvgAttr.strokeLinecap
            (if fraction > 0 && fraction < 1 then
                "round"

             else
                "butt"
            )
        , attribute "pathLength" "100"
        , SvgAttr.strokeDasharray (num (fraction * 100) ++ " 100")
        , SvgAttr.transform "rotate(-90 20 20)"
        , SvgAttr.class "ring-arc"
        , attribute "data-fraction" (num fraction)
        , attribute "style" ("--arc:" ++ num (fraction * 100))
        ]
        []



-- THE FRAME


{-| One picture: a `viewBox` and nothing fixed in pixels, the sentence as
both a `<title>` and an `aria-label`, and `role="img"` so a reader is
told one thing rather than read every rectangle.
-}
figure : String -> String -> String -> List (Html.Attribute msg) -> List (Svg msg) -> Html msg
figure name box sentence extra body =
    Svg.svg
        ([ SvgAttr.viewBox box
         , SvgAttr.class (name ++ " quiet w-full h-auto block")
         , attribute "role" "img"
         , attribute "aria-label" sentence
         ]
            ++ extra
        )
        (Svg.title [] [ Svg.text sentence ] :: body)



-- NUMBERS AND WORDS


{-| The maximal runs of consecutive `Just`s, so a gap in the rolling line
(a window with no decisions in it) breaks the stroke instead of being
drawn straight through. A run of one point is dropped: a polyline of a
single point draws nothing.
-}
runs : List (Maybe a) -> List (List a)
runs values =
    let
        step value ( current, done ) =
            case value of
                Just v ->
                    ( v :: current, done )

                Nothing ->
                    ( [], current :: done )
    in
    let
        ( leading, rest ) =
            List.foldr step ( [], [] ) values
    in
    List.filter (\run -> List.length run > 1) (leading :: rest)


{-| A PR as the books write it: one decimal, always, so "8" reads as
"8.0". `Games.Backgammon.View` has the same helper for the same reason;
this module stays clear of the backgammon modules on purpose.
-}
oneDecimal : Float -> String
oneDecimal value =
    let
        n =
            round (abs value * 10)

        sign =
            if value < 0 && n /= 0 then
                "-"

            else
                ""
    in
    sign ++ String.fromInt (n // 10) ++ "." ++ String.fromInt (modBy 10 n)


plural : Int -> String -> String
plural n noun =
    String.fromInt n
        ++ " "
        ++ noun
        ++ (if n == 1 then
                ""

            else
                "s"
           )


{-| A coordinate, short: SVG wants text and a trailing `.0` on every
number makes the attributes twice as long for nothing.

Exported, because it is about SVG and not about any of these pictures:
`Ui.Rolls` draws its bars with it rather than keeping a second copy.

-}
num : Float -> String
num value =
    let
        rounded =
            toFloat (round (value * 100)) / 100
    in
    if rounded == toFloat (round rounded) then
        String.fromInt (round rounded)

    else
        String.fromFloat rounded
