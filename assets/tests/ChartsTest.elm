module ChartsTest exposing (suite)

{-| The home's three pictures: the PR line, the practice ladder and the
30-day strip.

The rolling PR is pinned against a weighted mean worked out by hand on a
five-game sample with deliberately unequal decision counts, because the
whole point of weighting is that a short game must not weigh like a long
one -- a plain mean would pass a sample where every game had the same
number of decisions, so this one does not.

-}

import Expect
import Html.Attributes
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (tag, text)
import Ui.Charts as Charts


suite : Test
suite =
    describe "Ui.Charts"
        [ prMath
        , prDrawing
        , ladder
        , days
        ]


{-| An SVG presentation attribute, as the selectors want it.
-}
attr : String -> String -> Selector.Selector
attr name value =
    Selector.attribute (Html.Attributes.attribute name value)



-- THE PR LINE'S ARITHMETIC


{-| Five games whose decision counts are all different, so a weighted
mean and a plain mean cannot agree.
-}
sample : List { pr : Float, decisions : Int }
sample =
    [ { pr = 10.0, decisions = 10 }
    , { pr = 2.0, decisions = 40 }
    , { pr = 8.0, decisions = 20 }
    , { pr = 4.0, decisions = 30 }
    , { pr = 6.0, decisions = 50 }
    ]


prMath : Test
prMath =
    describe "the rolling decision-weighted PR"
        [ test "a full window is the weighted mean, not the plain one" <|
            \_ ->
                let
                    -- (10*10 + 2*40 + 8*20 + 4*30 + 6*50) / (10+40+20+30+50)
                    -- = (100 + 80 + 160 + 120 + 300) / 150 = 760 / 150
                    byHand =
                        760 / 150

                    plain =
                        (10 + 2 + 8 + 4 + 6) / 5
                in
                Charts.windowPr sample
                    |> Expect.all
                        [ \got -> Expect.equal (Just True) (Maybe.map (\v -> abs (v - byHand) < 1.0e-9) got)
                        , \got -> Expect.equal (Just False) (Maybe.map (\v -> abs (v - plain) < 1.0e-9) got)
                        ]
        , test "the line's five points are the hand-computed running windows" <|
            \_ ->
                let
                    byHand =
                        [ 100 / 10
                        , (100 + 80) / (10 + 40)
                        , (100 + 80 + 160) / (10 + 40 + 20)
                        , (100 + 80 + 160 + 120) / (10 + 40 + 20 + 30)
                        , (100 + 80 + 160 + 120 + 300) / (10 + 40 + 20 + 30 + 50)
                        ]
                in
                Charts.rolling 20 sample
                    |> Expect.equal (List.map Just byHand)
        , test "a window of 3 drops the games that fell out of it" <|
            \_ ->
                let
                    -- the last point covers games 3..5 only:
                    -- (8*20 + 4*30 + 6*50) / (20 + 30 + 50)
                    last =
                        (160 + 120 + 300) / 100
                in
                Charts.rolling 3 sample
                    |> List.reverse
                    |> List.head
                    |> Expect.equal (Just (Just last))
        , test "games with no decisions have no PR, and never a zero" <|
            \_ ->
                Charts.windowPr [ { pr = 5.0, decisions = 0 }, { pr = 9.0, decisions = 0 } ]
                    |> Expect.equal Nothing
        ]



-- THE PR LINE'S DRAWING


prDrawing : Test
prDrawing =
    describe "the PR line"
        [ test "draws a dot per game" <|
            \_ ->
                Charts.prLine { games = sample, window = 20 }
                    |> Query.fromHtml
                    |> Query.findAll [ tag "circle" ]
                    |> Query.count (Expect.equal 5)
        , test "draws one stroke through the rolling values" <|
            \_ ->
                Charts.prLine { games = sample, window = 20 }
                    |> Query.fromHtml
                    |> Query.findAll [ tag "polyline" ]
                    |> Query.count (Expect.equal 1)
        , test "labels the line's lowest and highest values, and nothing else" <|
            \_ ->
                -- The rolling values above are 10, 3.6, 34/7, 4.6 and
                -- 76/15: the highest is the first game's 10.0 and the
                -- lowest the second's 3.6, so those two are the labels
                -- and there are no others.
                Charts.prLine { games = sample, window = 20 }
                    |> Query.fromHtml
                    |> Query.findAll [ tag "text" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 2)
                        , Query.index 0 >> Query.has [ text "10.0" ]
                        , Query.index 1 >> Query.has [ text "3.6" ]
                        ]
        , test "a flat line is labelled once, not twice in the same place" <|
            \_ ->
                -- Every window comes out at 7.0, so the lowest and the
                -- highest are one value and there is one label.
                Charts.prLine
                    { games = [ { pr = 7.0, decisions = 10 }, { pr = 7.0, decisions = 40 }, { pr = 7.0, decisions = 25 } ]
                    , window = 20
                    }
                    |> Query.fromHtml
                    |> Query.findAll [ tag "text" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 1)
                        , Query.index 0 >> Query.has [ text "7.0" ]
                        ]
        , test "the sentence names the games and the recent value" <|
            \_ ->
                Charts.prLine { games = sample, window = 20 }
                    |> Query.fromHtml
                    |> Query.has [ attr "aria-label" "PR over your last 5 games, recent 5.1." ]
        , test "under three games it is a flat placeholder with no marks and no numbers" <|
            \_ ->
                Charts.prLine { games = List.take 2 sample, window = 20 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ attr "data-placeholder" "true" ]
                        , Query.findAll [ tag "circle" ] >> Query.count (Expect.equal 0)
                        , Query.findAll [ tag "polyline" ] >> Query.count (Expect.equal 0)
                        , Query.findAll [ tag "text" ] >> Query.count (Expect.equal 0)
                        , Query.findAll [ tag "line" ] >> Query.count (Expect.equal 1)
                        ]
        , test "three games is enough to draw" <|
            \_ ->
                Charts.prLine { games = List.take 3 sample, window = 20 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.hasNot [ attr "data-placeholder" "true" ]
                        , Query.findAll [ tag "circle" ] >> Query.count (Expect.equal 3)
                        ]
        ]



-- THE LADDER


ladder : Test
ladder =
    describe "the practice ladder"
        [ test "a bar per non-empty level, at heights proportional to the max" <|
            \_ ->
                -- full height is 88 - 20 = 68; the max is 8, so a 4 is 34,
                -- a 2 is 17 and a 1 is 8.5.
                Charts.ladder [ 8, 4, 2, 0, 0, 0, 0, 1 ]
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect", attr "data-count" "8" ]
                            >> Query.index 0
                            >> Query.has [ attr "height" "68" ]
                        , Query.findAll [ tag "rect", attr "data-count" "4" ]
                            >> Query.index 0
                            >> Query.has [ attr "height" "34" ]
                        , Query.findAll [ tag "rect", attr "data-count" "2" ]
                            >> Query.index 0
                            >> Query.has [ attr "height" "17" ]
                        , Query.findAll [ tag "rect", attr "data-count" "1" ]
                            >> Query.index 0
                            >> Query.has [ attr "height" "8.5" ]
                        ]
        , test "eight slots are drawn whatever the deck holds" <|
            \_ ->
                Charts.ladder [ 8, 4, 2, 0, 0, 0, 0, 1 ]
                    |> Query.fromHtml
                    |> Query.findAll [ tag "rect", attr "height" "68", attr "fill" "none" ]
                    |> Query.count (Expect.equal 8)
        , test "an empty deck is eight empty slots and no bars" <|
            \_ ->
                Charts.ladder (List.repeat 8 0)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 8)
                        , Query.findAll [ tag "rect", attr "fill" "none" ] >> Query.count (Expect.equal 8)
                        , Query.has [ attr "aria-label" "Practice deck: no cards yet." ]
                        ]
        , test "a count is shown on a level that has one, and only there" <|
            \_ ->
                -- three non-empty levels, plus the two end labels
                Charts.ladder [ 8, 4, 2, 0, 0, 0, 0, 0 ]
                    |> Query.fromHtml
                    |> Query.findAll [ tag "text" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 5)
                        , Query.index 0 >> Query.has [ text "8" ]
                        , Query.index 1 >> Query.has [ text "4" ]
                        , Query.index 2 >> Query.has [ text "2" ]
                        , Query.index 3 >> Query.has [ text "new" ]
                        , Query.index 4 >> Query.has [ text "known" ]
                        ]
        , test "the colour deepens from the paper grey to the best green" <|
            \_ ->
                Charts.ladder (List.repeat 8 1)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ attr "fill" "rgb(222,217,203)" ] >> Query.count (Expect.equal 1)
                        , Query.findAll [ attr "fill" "rgb(31,122,69)" ] >> Query.count (Expect.equal 1)
                        ]
        , test "the sentence counts the deck, the new and the known" <|
            \_ ->
                Charts.ladder [ 8, 4, 2, 0, 0, 0, 0, 1 ]
                    |> Query.fromHtml
                    |> Query.has [ attr "aria-label" "Practice deck: 15 cards, 8 new, 1 known." ]
        , test "a short list is padded to eight levels rather than drawn short" <|
            \_ ->
                Charts.ladder [ 3, 1 ]
                    |> Query.fromHtml
                    |> Query.findAll [ tag "rect", attr "fill" "none" ]
                    |> Query.count (Expect.equal 8)
        ]



-- THE 30-DAY STRIP


days : Test
days =
    describe "the 30-day strip"
        [ test "thirty cells and a label" <|
            \_ ->
                Charts.days (List.repeat 30 False)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 30)
                        , Query.findAll [ tag "text" ] >> Query.index 0 >> Query.has [ text "30 days" ]
                        ]
        , test "a practised day is filled in ink, an idle one outlined in pencil" <|
            \_ ->
                Charts.days (List.repeat 12 True ++ List.repeat 18 False)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect", attr "fill" "var(--ink)" ]
                            >> Query.count (Expect.equal 12)
                        , Query.findAll [ tag "rect", attr "stroke" "var(--pencil)" ]
                            >> Query.count (Expect.equal 18)
                        , Query.has [ attr "aria-label" "Practised on 12 days of the last 30." ]
                        ]
        , test "today is the rightmost cell" <|
            \_ ->
                -- 29 idle days then today: the one filled cell is the last
                -- one drawn, at the far right of the strip.
                Charts.days (List.repeat 29 False ++ [ True ])
                    |> Query.fromHtml
                    |> Query.findAll [ tag "rect" ]
                    |> Query.index 29
                    |> Query.has [ attr "fill" "var(--ink)" ]
        , test "a short history is padded at the old end, so today stays at the right" <|
            \_ ->
                Charts.days [ True, False, True ]
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 30)
                        , Query.findAll [ tag "rect", attr "fill" "var(--ink)" ]
                            >> Query.count (Expect.equal 2)
                        , Query.findAll [ tag "rect" ] >> Query.index 29 >> Query.has [ attr "fill" "var(--ink)" ]
                        , Query.findAll [ tag "rect" ] >> Query.index 27 >> Query.has [ attr "fill" "var(--ink)" ]
                        ]
        , test "a longer history keeps the newest thirty" <|
            \_ ->
                Charts.days (List.repeat 40 True ++ List.repeat 5 False)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 30)
                        , Query.findAll [ tag "rect", attr "fill" "var(--ink)" ]
                            >> Query.count (Expect.equal 25)
                        ]
        , test "no practice at all still draws the strip and says so" <|
            \_ ->
                Charts.days []
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 30)
                        , Query.has [ attr "aria-label" "No practice in the last 30 days." ]
                        ]
        ]
