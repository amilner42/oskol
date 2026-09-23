module Ui.Charts exposing (days, ladder, prLine, rolling, windowPr)

{-| The three pictures the signed-in home is allowed: your PR over time,
your practice deck as a ladder, and the last thirty days.

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
        [ attribute "data-practised" (String.fromInt (List.length (List.filter identity thirty))) ]
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
dayCell index practised =
    let
        common =
            [ SvgAttr.x (num (3.5 + toFloat index * 10.5))
            , SvgAttr.y "3"
            , SvgAttr.width "8.5"
            , SvgAttr.height "8.5"
            , SvgAttr.rx "1.5"
            ]

        paint =
            if practised then
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
        "Practised on " ++ plural hit "day" ++ " of the last 30."



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
