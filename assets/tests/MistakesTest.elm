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
        , choices
        , theHome
        , aDecksPage
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
                Mistakes.runSummary { right = 1, total = 1 }
                    |> Expect.equal "One fixed. That is how it is done."
        , test "one missed says when it comes back, not that you failed" <|
            \_ ->
                Mistakes.runSummary { right = 0, total = 1 }
                    |> Expect.equal "One faced. It comes back tomorrow."
        , test "more than one is the score of what was answered" <|
            \_ ->
                Mistakes.runSummary { right = 7, total = 10 }
                    |> Expect.equal "7 of 10 right"
        , test "nothing a run ends on calls an answer close: 0.02 given up is a miss" <|
            \_ ->
                [ Mistakes.runSummary { right = 0, total = 1 }
                , Mistakes.runSummary { right = 1, total = 1 }
                , Mistakes.runSummary { right = 3, total = 4 }
                ]
                    |> List.filter (String.contains "close")
                    |> Expect.equal []
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


choices : Test
choices =
    describe "what each of the four choices would do, said before it is done"
        [ test "SOONER: back to the start, and from where" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.soonerWhy 3 |> Expect.equal "Back to the start: it comes back tomorrow. Level 3 → 0."
                    , \_ -> Mistakes.soonerWhy 0 |> Expect.equal "Back to the start: it comes back tomorrow."
                    ]
                    ()
        , test "GOT IT on a graded pass: the level line's own words" <|
            \_ ->
                Mistakes.gotItGraded "Level 2 → 3 · back in 7 days"
                    |> Expect.equal "As graded. Level 2 → 3 · back in 7 days."
        , test "GOT IT where nothing checked the answer: the level holds" <|
            \_ ->
                Mistakes.gotItUnchecked 2 "back in 3 days"
                    |> Expect.equal "Counts as right, but nothing checked it: level 2 stays · back in 3 days."
        , test "GOT IT where the answer did not say how long the level holds" <|
            \_ ->
                Mistakes.gotItHolds 2
                    |> Expect.equal "Counts as right, but nothing checked it: level 2 stays."
        , test "GOT IT after a miss says why it is not a choice" <|
            \_ -> Mistakes.missedNote |> Expect.equal "You missed this one."
        , test "KNEW IT and NEVER" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.knewItWhy |> Expect.equal "I already knew this: to the top, back in a year."
                    , \_ -> Mistakes.neverWhy |> Expect.equal "Out of your practice for good. It will not come back, and this cannot be undone."
                    ]
                    ()
        , test "APPLY, and NEVER's button asks in its own words" <|
            \_ ->
                List.map Mistakes.applyLabel [ "sooner", "got_it", "knew_it", "never" ]
                    |> Expect.equal [ "APPLY", "APPLY", "APPLY", "YES, NEVER" ]
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
                             , Mistakes.runSummary { right = 1, total = 1 }
                             , Mistakes.whyLine { grade = "bad", opponent = "Charlie" }
                             , Mistakes.soonerWhy 3
                             , Mistakes.gotItGraded "Level 2 → 3 · back in 7 days"
                             , Mistakes.gotItUnchecked 2 "back in 3 days"
                             , Mistakes.missedNote
                             , Mistakes.knewItWhy
                             , Mistakes.neverWhy
                             , Mistakes.stateLine { total = 44, untouched = 12, inProgress = 20, patched = 12 }
                             , Mistakes.guestStateLine 23 "very_bad"
                             , Mistakes.costLine { games = 6, pr = 8.3, prWithout = 5.1 }
                             , Tuple.first (Mistakes.costHeadline { pr = 8.3, prWithout = 0.3, prPatched = 7.7 })
                             , Mistakes.dayStreakLine { streak = 5, done = 3 }
                             , Mistakes.workLine { due = 4, newLeft = 3 }
                             , Mistakes.keepGoingLine { done = 5, adds = 3 }
                             , Mistakes.scheduledLine
                             , Mistakes.unsavedLine
                             , Mistakes.guestPracticeLine
                             , Mistakes.rowLeft 23
                             , Mistakes.freshLine
                             , Mistakes.ladderLine { patchedLevel = 4, started = [ 2, 8, 5, 3, 6, 0, 0, 0 ] }
                             , Mistakes.dueLine { due = 0, newLeft = 0, nextInDays = Just 3 }
                             , Mistakes.strangerTierLine
                             , Mistakes.emptyTierLine "very_bad"
                             , String.join " " (List.map Tuple.second (Mistakes.legendParts Mistakes.legendTop))
                             ]
                                ++ List.filterMap identity
                                    [ Mistakes.patchedAside (band "very_bad" 61 30 23)
                                    , Mistakes.patchedRun [ "very_bad" ]
                                    , Mistakes.wonBackLine { pr = 8.3, prPatched = 7.7 }
                                    , Tuple.second (Mistakes.costHeadline { pr = 8.3, prWithout = 0.3, prPatched = 7.7 })
                                    ]
                            )
                        )
            in
            List.filter (\word -> String.contains word everything) [ "card", "deck", "flashcard" ]
                |> Expect.equal []



{-| The practice home's words: a tier's three states, what it cost, the
day, and the line under each of the one button's states.
-}
theHome : Test
theHome =
    describe "the practice home"
        [ test "a tier in its three states, every part even at zero, then how many" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.stateLine { total = 44, untouched = 12, inProgress = 20, patched = 12 } |> Expect.equal "12 patched · 20 in progress · 12 to start · of 44"
                    , \_ -> Mistakes.stateLine { total = 3, untouched = 3, inProgress = 0, patched = 0 } |> Expect.equal "0 patched · 0 in progress · 3 to start · of 3"
                    , \_ -> Mistakes.guestStateLine 23 "very_bad" |> Expect.equal "23 very bad moves from your games"
                    , \_ -> Mistakes.guestStateLine 1 "bad" |> Expect.equal "1 bad move from your games"
                    ]
                    ()
        , test "what a tier cost, and what patching won back of it" <|
            \_ ->
                Expect.all
                    -- Said in PR throughout: the cost is the gap between the two
                    -- ratings the sentence names (8.3 - 5.1), never the equity
                    -- the mistakes gave up (4.84 on this account), which is
                    -- another unit and reads as a contradiction beside them.
                    [ \_ -> Mistakes.costLine { games = 6, pr = 8.3, prWithout = 5.1 } |> Expect.equal "These cost you 3.2 PR over 6 games. Without them your PR would be 5.1, not 8.3."
                    , \_ -> Mistakes.costLine { games = 1, pr = 9, prWithout = 7 } |> Expect.equal "These cost you 2.0 PR over 1 game. Without them your PR would be 7.0, not 9.0."
                    -- The gap is of the printed figures, so it always adds up.
                    , \_ -> Mistakes.costLine { games = 3, pr = 8.26, prWithout = 5.14 } |> Expect.equal "These cost you 3.2 PR over 3 games. Without them your PR would be 5.1, not 8.3."
                    , \_ -> Mistakes.costLine { games = 6, pr = 8.3, prWithout = 5.1 } |> String.contains "point" |> Expect.equal False
                    , \_ -> Mistakes.wonBackLine { pr = 8.3, prPatched = 7.7 } |> Expect.equal (Just "Patched so far: 0.6 PR won back.")
                    , \_ -> Mistakes.wonBackLine { pr = 8.3, prPatched = 8.3 } |> Expect.equal Nothing
                    , \_ -> Mistakes.wonBackLine { pr = 8.3, prPatched = 8.28 } |> Expect.equal Nothing
                    ]
                    ()
        , test "the headline: how much of the rating is mistakes, then what is won back once anything is" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.costHeadline { pr = 8.3, prWithout = 0.3, prPatched = 7.7 } |> Expect.equal ( "Your mistakes are 8.0 of your 8.3 PR.", Just "You have won back 0.6 so far." )
                    , \_ -> Mistakes.costHeadline { pr = 8.3, prWithout = 0.3, prPatched = 8.3 } |> Expect.equal ( "Your mistakes are 8.0 of your 8.3 PR.", Nothing )
                    ]
                    ()
        , test "the day: the streak left off at zero, the count said in words at zero" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.dayStreakLine { streak = 5, done = 3 } |> Expect.equal "5 days running · 3 fixed today"
                    , \_ -> Mistakes.dayStreakLine { streak = 1, done = 0 } |> Expect.equal "1 day running · nothing fixed yet today"
                    , \_ -> Mistakes.dayStreakLine { streak = 0, done = 0 } |> Expect.equal "Nothing fixed yet today"
                    , \_ -> Mistakes.dayStreakLine { streak = 0, done = 2 } |> Expect.equal "2 fixed today"
                    ]
                    ()
        , test "the line under each button" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.workLine { due = 4, newLeft = 3 } |> Expect.equal "4 due now · 3 new today"
                    , \_ -> Mistakes.workLine { due = 0, newLeft = 3 } |> Expect.equal "3 new today"
                    , \_ -> Mistakes.workLine { due = 2, newLeft = 0 } |> Expect.equal "2 due now"
                    , \_ -> Mistakes.keepGoingLine { done = 5, adds = 3 } |> Expect.equal "Today's 5 done. Keep going adds 3 more."
                    , \_ -> Mistakes.keepGoingLine { done = 0, adds = 3 } |> Expect.equal "Nothing due here today. Keep going adds 3 more."
                    , \_ -> Mistakes.scheduledLine |> Expect.equal "Everything here is scheduled. Practising early moves nothing."
                    , \_ -> Mistakes.unsavedLine |> Expect.equal "Your progress is not saved until you sign in."
                    , \_ -> Mistakes.rowLeft 23 |> Expect.equal "23 left"
                    , \_ -> Mistakes.rowLeft 0 |> Expect.equal "None yet"
                    ]
                    ()
        ]



{-| A deck's own page: the legend, the ladder in words, what is due, and
the two lines a tier with nothing of the visitor's in it says.
-}
aDecksPage : Test
aDecksPage =
    describe "a deck's own page"
        [ test "the legend climbs the grid's paints and ends on patched" <|
            \_ ->
                Mistakes.legendParts Mistakes.legendTop
                    |> List.map Tuple.second
                    |> String.join " · "
                    |> Expect.equal "to start · level 1 · 2 · 3 · patched"
        , test "the ladder in words, rungs with nobody on them left out" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.ladderLine { patchedLevel = 4, started = [ 0, 8, 5, 3, 0, 0, 0, 0 ] } |> Expect.equal "8 at level 1, 5 at level 2, 3 at level 3."
                    , \_ -> Mistakes.ladderLine { patchedLevel = 4, started = [ 2, 8, 0, 3, 4, 1, 0, 1 ] } |> Expect.equal "2 back at the start, 8 at level 1, 3 at level 3, 6 patched."
                    , \_ -> Mistakes.ladderLine { patchedLevel = 4, started = [ 0, 0, 0, 0, 0, 0, 0, 0 ] } |> Expect.equal ""
                    , \_ -> Mistakes.ladderLine { patchedLevel = 4, started = [] } |> Expect.equal ""
                    ]
                    ()
        , test "the due line in its three shapes" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.dueLine { due = 12, newLeft = 3, nextInDays = Just 1 } |> Expect.equal "12 due now · 3 new today"
                    , \_ -> Mistakes.dueLine { due = 0, newLeft = 0, nextInDays = Just 1 } |> Expect.equal "Nothing due. Next due tomorrow."
                    , \_ -> Mistakes.dueLine { due = 0, newLeft = 0, nextInDays = Just 0 } |> Expect.equal "Nothing due. Next due tomorrow."
                    , \_ -> Mistakes.dueLine { due = 0, newLeft = 0, nextInDays = Just 5 } |> Expect.equal "Nothing due. Next due in 5 days."
                    , \_ -> Mistakes.dueLine { due = 0, newLeft = 0, nextInDays = Nothing } |> Expect.equal "Nothing due."
                    ]
                    ()
        , test "nothing of yours here: a stranger, and an account with none yet" <|
            \_ ->
                Expect.all
                    [ \_ -> Mistakes.strangerTierLine |> Expect.equal "Play a game and your mistakes appear here."
                    , \_ -> Mistakes.emptyTierLine "doubtful" |> Expect.equal "No dubious moves yet. They land here as your games are graded."
                    ]
                    ()
        ]
