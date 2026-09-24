module ChartsTest exposing (suite)

{-| The home's pictures: the PR line, the practice ladder, the 30-day
strip, today's ring and the deck in one bar.

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
        , ring
        , mastery
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



-- TODAY'S RING


ring : Test
ring =
    describe "today's ring"
        [ test "a day with nothing answered draws no arc, and says so" <|
            \_ ->
                Charts.ring { done = 0, target = 10 }
                    |> Query.fromHtml
                    |> Expect.all
                        -- the track, and nothing over it
                        [ Query.findAll [ tag "circle" ] >> Query.count (Expect.equal 1)
                        , Query.has [ attr "aria-label" "0 of today's 10 answered." ]
                        , Query.find [ tag "text" ] >> Query.has [ text "0" ]
                        ]
        , test "a day part way through fills its share of the ring" <|
            \_ ->
                Charts.ring { done = 4, target = 10 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "circle" ] >> Query.count (Expect.equal 2)
                        , Query.has [ attr "data-fraction" "0.4" ]
                        , Query.has [ attr "aria-label" "4 of today's 10 answered." ]
                        , Query.find [ tag "text" ] >> Query.has [ text "4" ]
                        ]
        , test "the day's ten done fills the ring and says so plainly" <|
            \_ ->
                Charts.ring { done = 10, target = 10 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ attr "data-fraction" "1" ]
                        , Query.has [ attr "aria-label" "Today's 10: done." ]
                        , Query.find [ tag "text" ] >> Query.has [ text "10" ]
                        ]
        , test "past the goal the ring stays full and the count stays true" <|
            \_ ->
                -- KEEP GOING is uncapped, so a day can run past its ten.
                Charts.ring { done = 13, target = 10 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ attr "data-fraction" "1" ]
                        , Query.find [ tag "text" ] >> Query.has [ text "13" ]
                        ]
        , test "no goal draws an empty ring rather than dividing by it" <|
            \_ ->
                Charts.ring { done = 0, target = 0 }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "circle" ] >> Query.count (Expect.equal 1)
                        , Query.has [ attr "aria-label" "No goal for today." ]
                        ]
        ]



-- A BAND, AND THE THREE STATES ITS MISTAKES ARE IN


mastery : Test
mastery =
    describe "a band in its three states"
        [ test "in progress and patched are drawn side by side, in proportion" <|
            \_ ->
                -- Of 61: 30 in progress is 157.38 wide, and the 23
                -- patched start where those end and run 120.66.
                Charts.patched
                    { total = 61
                    , inProgress = 30
                    , patched = 23
                    , sentence = "Very bad · 30 in progress · 23 patched · of 61"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ tag "rect", attr "data-part" "to-fix" ]
                            >> Query.has [ attr "width" "320" ]
                        , Query.find [ tag "rect", attr "data-part" "in-progress" ]
                            >> Query.has [ attr "x" "0", attr "width" "157.38" ]
                        , Query.find [ tag "rect", attr "data-part" "patched" ]
                            >> Query.has [ attr "x" "157.38", attr "width" "120.66" ]

                        -- The line in words is printed beside it, so the
                        -- bar itself is not read out a second time.
                        , Query.has [ attr "aria-hidden" "true" ]
                        , Query.find [ tag "title" ]
                            >> Query.has [ text "Very bad · 30 in progress · 23 patched · of 61" ]
                        , Query.has
                            [ attr "data-total" "61"
                            , attr "data-in-progress" "30"
                            , attr "data-patched" "23"
                            ]
                        ]
        , -- The deck the human hit: nothing patched for weeks, and half
          -- the band in rotation. The bar must not be empty.
          test "a band with nothing patched still shows the work under way" <|
            \_ ->
                Charts.patched
                    { total = 111
                    , inProgress = 50
                    , patched = 0
                    , sentence = "Very bad · 50 in progress · 0 patched · of 111"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ tag "rect", attr "data-part" "in-progress" ]
                            >> Query.has [ attr "x" "0", attr "width" "144.14" ]
                        , Query.hasNot [ attr "data-part" "patched" ]
                        ]
        , test "a band nobody has touched draws the bar and nothing over it" <|
            \_ ->
                Charts.patched
                    { total = 12
                    , inProgress = 0
                    , patched = 0
                    , sentence = "Bad · 0 in progress · 0 patched · of 12"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 1)
                        , Query.hasNot [ attr "data-part" "patched" ]
                        , Query.hasNot [ attr "data-part" "in-progress" ]
                        ]
        , test "a band entirely patched is full, and in progress is gone" <|
            \_ ->
                Charts.patched
                    { total = 12
                    , inProgress = 0
                    , patched = 12
                    , sentence = "Bad · 0 in progress · 12 patched · of 12"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ tag "rect", attr "data-part" "patched" ]
                            >> Query.has [ attr "x" "0", attr "width" "320" ]
                        , Query.hasNot [ attr "data-part" "in-progress" ]
                        ]
        , test "a band with no mistakes in it draws an empty bar, not a full one" <|
            \_ ->
                Charts.patched
                    { total = 0
                    , inProgress = 0
                    , patched = 0
                    , sentence = "Dubious · 0 in progress · 0 patched · of 0"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 1)
                        , Query.hasNot [ attr "data-part" "patched" ]
                        ]
        , test "more patched than made is clamped: a bar never draws past its band" <|
            \_ ->
                Charts.patched
                    { total = 10
                    , inProgress = 0
                    , patched = 40
                    , sentence = "Bad · 0 in progress · 40 patched · of 10"
                    }
                    |> Query.fromHtml
                    |> Query.find [ tag "rect", attr "data-part" "patched" ]
                    |> Query.has [ attr "width" "320" ]
        , -- Nonsense the server cannot send, drawn as something rather
          -- than as a bar running off its own end: patched keeps its
          -- share and what is in progress takes what is left.
          test "and the two together never pass the end of the band" <|
            \_ ->
                Charts.patched
                    { total = 10
                    , inProgress = 9
                    , patched = 8
                    , sentence = "Bad · 9 in progress · 8 patched · of 10"
                    }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ tag "rect", attr "data-part" "in-progress" ]
                            >> Query.has [ attr "x" "0", attr "width" "64" ]
                        , Query.find [ tag "rect", attr "data-part" "patched" ]
                            >> Query.has [ attr "x" "64", attr "width" "256" ]
                        ]
        ]
