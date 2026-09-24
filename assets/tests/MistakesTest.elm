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
        , lead
        , today
        , patched
        , why
        , noJargon
        ]


band : String -> Int -> Int -> { grade : String, total : Int, patched : Int }
band grade total done =
    { grade = grade, total = total, patched = done }


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
        , test "one band's own line: the name, and the share patched" <|
            \_ ->
                Mistakes.line (band "very_bad" 61 23)
                    |> Expect.equal "Very bad · 23 of 61 patched"
        , test "a band with nothing in it still reads as a line" <|
            \_ ->
                Mistakes.line (band "doubtful" 0 0)
                    |> Expect.equal "Dubious · 0 of 0 patched"
        ]


lead : Test
lead =
    describe "what the practice home leads with"
        [ test "the worst band, and how much of it is fixed" <|
            \_ ->
                Mistakes.lead [ band "very_bad" 61 23, band "bad" 118 40 ]
                    |> Expect.equal (Just "You have made 61 very bad moves. You have patched 23.")
        , test "the worst band the player actually has, not the worst there is" <|
            \_ ->
                Mistakes.lead [ band "very_bad" 0 0, band "bad" 12 3 ]
                    |> Expect.equal (Just "You have made 12 bad moves. You have patched 3.")
        , test "nothing at all when no band holds anything" <|
            \_ ->
                Mistakes.lead [ band "very_bad" 0 0, band "bad" 0 0 ]
                    |> Expect.equal Nothing
        , test "and nothing when the answer carried no bands" <|
            \_ -> Mistakes.lead [] |> Expect.equal Nothing
        ]


today : Test
today =
    describe "the one button"
        [ test "what today still asks of you, as a verb" <|
            \_ ->
                Mistakes.fixLabel { done = 2, target = 5 }
                    |> Expect.equal "FIX 3 TODAY"
        , test "a day worked through says so" <|
            \_ ->
                Mistakes.fixLabel { done = 5, target = 5 }
                    |> Expect.equal "DONE FOR TODAY"
        , test "and a day gone past its goal is still done, not negative" <|
            \_ ->
                Mistakes.fixLabel { done = 9, target = 5 }
                    |> Expect.equal "DONE FOR TODAY"
        ]


patched : Test
patched =
    describe "patched"
        [ test "what it means, said once and quietly" <|
            \_ ->
                Mistakes.patchedNote 4
                    |> Expect.equal "Patched: right four times running."
        , test "the milestone, on the reveal" <|
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
                             , Mistakes.line (band "bad" 3 1)
                             , Mistakes.patchedNote 4
                             , Mistakes.milestone 4
                             , Mistakes.fixLabel { done = 0, target = 3 }
                             , Mistakes.whyLine { grade = "bad", opponent = "Charlie" }
                             ]
                                ++ List.filterMap identity
                                    [ Mistakes.lead [ band "very_bad" 61 23 ]
                                    , Mistakes.patchedRun [ "very_bad" ]
                                    ]
                            )
                        )
            in
            List.filter (\word -> String.contains word everything) [ "card", "deck", "flashcard" ]
                |> Expect.equal []
