module MistakesTest exposing (suite)

{-| The words practice is said in, pinned.

They are pinned because they are the product: "we are helping you fix the
worst parts of your game" is a promise made in sentences, and a sentence
that drifts between the three places it is printed reads like two
different products. A phrase changed on purpose changes here too, in one
place, on purpose.

The one rule under all of them: the unit is **a mistake you made**, and
what you do with it is **fix** it. Nothing a player reads says "card",
"deck" or "flashcard".

-}

import Expect
import Test exposing (Test, describe, test)
import Ui.Mistakes as Mistakes


suite : Test
suite =
    describe "the words practice is said in"
        [ bands
        , tiers
        , today
        , runEnd
        , patched
        , why
        , noJargon
        ]


{-| A band in its three states, with nothing to do today.
-}
band : String -> Int -> Int -> Int -> Mistakes.Band
band grade total going done =
    { grade = grade, total = total, inProgress = going, patched = done, due = 0, newLeft = 0 }


{-| The same band, with work: so many due, and so many new ones the day
still allows.
-}
working : String -> Int -> Int -> Int -> Int -> Int -> Mistakes.Band
working grade total going done due newLeft =
    { grade = grade, total = total, inProgress = going, patched = done, due = due, newLeft = newLeft }


bands : Test
bands =
    describe "the site's own bands, in a player's words"
        [ test "each band has a name" <|
            \_ ->
                List.map Mistakes.bandName [ "very_bad", "bad", "doubtful" ]
                    |> Expect.equal [ "Very bad", "Bad", "Dubious" ]
        , test "and a form that sits inside a sentence" <|
            \_ ->
                List.map Mistakes.bandWord [ "very_bad", "bad", "doubtful" ]
                    |> Expect.equal [ "very bad", "bad", "dubious" ]
        , test "a band counted: plural, and singular at one" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.moves 61 "very_bad" |> Expect.equal "61 very bad moves"
                    , \_ -> Mistakes.moves 1 "bad" |> Expect.equal "1 bad move"
                    ]
                    ()
        , test "one band's own line: what is being fixed, what is patched, of how many" <|
            \_ ->
                Mistakes.line (band "very_bad" 61 30 23)
                    |> Expect.equal "Very bad · 30 in progress · 23 patched · of 61"
        , test "a band nobody has touched yet says so without hiding the total" <|
            \_ ->
                Mistakes.line (band "bad" 61 0 0)
                    |> Expect.equal "Bad · 0 in progress · 0 patched · of 61"
        , test "a band entirely patched has nothing left in progress" <|
            \_ ->
                Mistakes.line (band "bad" 12 0 12)
                    |> Expect.equal "Bad · 0 in progress · 12 patched · of 12"
        , test "a band with nothing in it still reads as a line" <|
            \_ ->
                Mistakes.line (band "doubtful" 0 0 0)
                    |> Expect.equal "Dubious · 0 in progress · 0 patched · of 0"
        ]


tiers : Test
tiers =
    describe "one tier in front of you"
        [ test "a tier is named by the mark the replay already draws" <|
            \_ ->
                List.map Mistakes.mark [ "very_bad", "bad", "doubtful" ]
                    |> Expect.equal [ "??", "?", "?!" ]
        , test "and under the mark, in words" <|
            \_ ->
                List.map Mistakes.tierName [ "very_bad", "bad", "doubtful" ]
                    |> Expect.equal [ "Very bad moves", "Bad moves", "Dubious moves" ]
        , test "the one number: everything not patched, not what is due" <|
            \_ ->
                Mistakes.leftToFix (working "very_bad" 61 30 23 5 3)
                    |> Expect.equal "38 left to fix"
        , test "a tier with everything patched is nothing left to fix" <|
            \_ ->
                Mistakes.leftToFix (band "bad" 12 0 12)
                    |> Expect.equal "0 left to fix"
        , test "what is patched, quieter beside it" <|
            \_ ->
                Mistakes.patchedAside (band "very_bad" 61 30 23)
                    |> Expect.equal (Just "23 patched")
        , test "and nothing at all on a first day, rather than a zero" <|
            \_ ->
                Mistakes.patchedAside (band "very_bad" 61 30 0)
                    |> Expect.equal Nothing
        , test "work is anything due, or a new one the day still allows" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.hasWork (working "very_bad" 61 30 23 5 0) |> Expect.equal True
                    , \_ -> Mistakes.hasWork (working "very_bad" 61 30 23 0 3) |> Expect.equal True
                    , \_ -> Mistakes.hasWork (working "very_bad" 61 30 23 0 0) |> Expect.equal False
                    ]
                    ()
        , test "a tier in good shape is said warmly, by its mark" <|
            \_ ->
                Mistakes.goodShapeLine "very_bad"
                    |> Expect.equal "Nice — your ?? moves are in good shape."
        , test "and honestly: more tomorrow while any are untouched" <|
            \_ ->
                Mistakes.goodShapeWhy (band "very_bad" 61 30 23)
                    |> Expect.equal "Nothing due. More of them tomorrow."
        , test "or that every one of them has been started" <|
            \_ ->
                Mistakes.goodShapeWhy (band "very_bad" 61 38 23)
                    |> Expect.equal "Nothing due, and you have started every one."
        , test "every tier in good shape: one line, and nothing to press" <|
            \_ ->
                Mistakes.allClearLine
                    |> Expect.equal "Nice work — every one of your mistakes is in good shape."
        , test "the next tier down, offered by its mark and its words" <|
            \_ ->
                Mistakes.nextTierLabel "bad"
                    |> Expect.equal "WORK ON ? BAD MOVES"
        ]


today : Test
today =
    describe "the day, wherever the ring used to be"
        [ test "a plain count, with nothing to measure it against" <|
            \_ -> Mistakes.fixedToday 3 |> Expect.equal "3 fixed today"
        , test "one is one, not a fraction of anything" <|
            \_ -> Mistakes.fixedToday 1 |> Expect.equal "1 fixed today"
        , test "a day not started yet says so without a goal" <|
            \_ -> Mistakes.fixedToday 0 |> Expect.equal "Nothing fixed yet today"
        ]


{-| The end of a run. The page invites stopping after one mistake, so
one mistake has to read as a finished thing to have done.
-}
runEnd : Test
runEnd =
    describe "what a run ends on"
        [ test "one fixed is a whole session, and says so" <|
            \_ ->
                Mistakes.runSummary { right = 1, close = 0, total = 1 }
                    |> Expect.equal "One fixed. That is how it is done."
        , test "one close still counts" <|
            \_ ->
                Mistakes.runSummary { right = 0, close = 1, total = 1 }
                    |> Expect.equal "One faced, and close. That counts."
        , test "one missed says when it comes back, not that you failed" <|
            \_ ->
                Mistakes.runSummary { right = 0, close = 0, total = 1 }
                    |> Expect.equal "One faced. It comes back tomorrow."
        , test "more than one is the score of what was answered" <|
            \_ ->
                Mistakes.runSummary { right = 7, close = 2, total = 10 }
                    |> Expect.equal "7 of 10 right"
        ]


patched : Test
patched =
    describe "patched"
        [ test "the milestone, on the reveal" <|
            \_ ->
                Mistakes.milestone 4
                    |> Expect.equal "Patched. Four right in a row"
        , test "the end of a run that patched one band" <|
            \_ ->
                Mistakes.patchedRun [ "very_bad", "very_bad" ]
                    |> Expect.equal (Just "You patched 2 very bad moves.")
        , test "two bands, worst first, joined with an and" <|
            \_ ->
                Mistakes.patchedRun [ "bad", "very_bad", "very_bad" ]
                    |> Expect.equal (Just "You patched 2 very bad moves and 1 bad move.")
        , test "all three, commas then an and" <|
            \_ ->
                Mistakes.patchedRun [ "doubtful", "bad", "very_bad" ]
                    |> Expect.equal (Just "You patched 1 very bad move, 1 bad move and 1 dubious move.")
        , test "a run that patched nothing says nothing" <|
            \_ -> Mistakes.patchedRun [] |> Expect.equal Nothing
        ]


why : Test
why =
    describe "why this position is in front of you"
        [ test "how bad it was, and whose game it came from" <|
            \_ ->
                Mistakes.whyLine { grade = "very_bad", opponent = "Charlie" }
                    |> Expect.equal "A very bad move, from your game vs Charlie"
        , test "a game whose other seat never had a name" <|
            \_ ->
                Mistakes.whyLine { grade = "bad", opponent = "" }
                    |> Expect.equal "A bad move, from your game"
        ]


{-| The rule, as a test: nothing a player reads here is about how any of
it is stored.
-}
noJargon : Test
noJargon =
    test "no card, no deck, no flashcard, anywhere in these words" <|
        \_ ->
            let
                everything =
                    String.toLower
                        (String.join " "
                            ([ Mistakes.bandName "very_bad"
                             , Mistakes.line (band "bad" 3 1 1)
                             , Mistakes.milestone 4
                             , Mistakes.fixedToday 3
                             , Mistakes.tierName "very_bad"
                             , Mistakes.leftToFix (band "very_bad" 61 30 23)
                             , Mistakes.goodShapeLine "very_bad"
                             , Mistakes.goodShapeWhy (band "very_bad" 61 30 23)
                             , Mistakes.allClearLine
                             , Mistakes.nextTierLabel "bad"
                             , Mistakes.runSummary { right = 1, close = 0, total = 1 }
                             , Mistakes.whyLine { grade = "bad", opponent = "Charlie" }
                             ]
                                ++ List.filterMap identity
                                    [ Mistakes.patchedAside (band "very_bad" 61 30 23)
                                    , Mistakes.patchedRun [ "very_bad" ]
                                    ]
                            )
                        )
            in
            List.filter (\word -> String.contains word everything) [ "card", "deck", "flashcard" ]
                |> Expect.equal []
