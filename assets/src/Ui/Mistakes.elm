module Ui.Mistakes exposing
    ( Band
    , allClearLine
    , bandName
    , bandWord
    , fixedToday
    , goodShapeLine
    , goodShapeWhy
    , hasWork
    , leftToFix
    , line
    , mark
    , milestone
    , moves
    , nextTierLabel
    , patchedAside
    , patchedRun
    , runSummary
    , tierName
    , whyLine
    )

{-| The words practice is said in.

One rule holds all of them: **the unit is a mistake you made**, and the
thing to do with it is fix it. Nothing a player reads here says "card",
"deck" or "flashcard" -- those are how it is stored, not what it is. A
mistake you have stopped making is **patched**, which is a word about the
mistake and not about a schedule.

They live in one module because the same sentence is printed in three
places (the practice home, the session, the end of a run) and a phrase
that drifts between them reads like two different products. Every one of
them is pinned in `MistakesTest`.

-}


{-| A band as the server counts it, in its three states: how bad, how
many, how many are in progress, how many are patched. What is neither is
untouched.

**Three states, not two.** Patched is four right answers over twelve days
at the very earliest, so a player halfway through fifty of their mistakes
would read "0 patched" for weeks. What they are working on is progress
and is said out loud.

-}
type alias Band =
    { grade : String, total : Int, inProgress : Int, patched : Int, due : Int, newLeft : Int }


{-| Does this tier still have something to fix today? The server has
already capped `newLeft` at the day's budget, so this is a read and not
a rule.
-}
hasWork : Band -> Bool
hasWork band =
    band.due > 0 || band.newLeft > 0


{-| The site's own grades, in the words a player reads. "Dubious" rather
than "doubtful": it is what the replay calls the band out loud.
-}
bandName : String -> String
bandName grade =
    case grade of
        "very_bad" ->
            "Very bad"

        "bad" ->
            "Bad"

        "doubtful" ->
            "Dubious"

        other ->
            other


{-| The same, inside a sentence: "2 very bad moves".
-}
bandWord : String -> String
bandWord grade =
    String.toLower (bandName grade)


{-| "61 very bad moves", "1 bad move".
-}
moves : Int -> String -> String
moves n grade =
    String.fromInt n
        ++ " "
        ++ bandWord grade
        ++ (if n == 1 then
                " move"

            else
                " moves"
           )


{-| The annotators' mark for a tier, which is what the replay already
draws beside every move: `??`, `?`, `?!`. A tier is named by its mark
first and its words second, so the hub reads as the game does.

It is `Games.Backgammon.Words.gradeMark`, kept here as well because
every other practice word is here and a page should reach for one
module, not two. The two agree by test (`MistakesTest`).

-}
mark : String -> String
mark grade =
    case grade of
        "very_bad" ->
            "??"

        "bad" ->
            "?"

        "doubtful" ->
            "?!"

        _ ->
            ""


{-| A tier's name under its mark: "Very bad moves".
-}
tierName : String -> String
tierName grade =
    bandName grade ++ " moves"


{-| The one number the hub leads with: how many of this tier are still
to fix. Everything not patched -- what is *due* changes hour to hour and
is not what anyone is trying to get to zero.

    "31 left to fix"

-}
leftToFix : Band -> String
leftToFix band =
    String.fromInt (max 0 (band.total - max 0 band.patched)) ++ " left to fix"


{-| Quieter, beside it: "23 patched". Nothing at all when none is, so a
player on their first day is not shown a zero.
-}
patchedAside : Band -> Maybe String
patchedAside band =
    case max 0 band.patched of
        0 ->
            Nothing

        n ->
            Just (String.fromInt n ++ " patched")


{-| A tier with nothing due and no new ones left today. The moment the
whole page is arranged around: said warmly, in the mark the player
already knows the tier by.

    "Nice -- your ?? moves are in good shape."

-}
goodShapeLine : String -> String
goodShapeLine grade =
    "Nice — your " ++ mark grade ++ " moves are in good shape."


{-| Under it, the honest reason, which is one of two: every mistake of
that tier has been started, or the day's new ones are done and more come
tomorrow.
-}
goodShapeWhy : Band -> String
goodShapeWhy band =
    if max 0 band.total - max 0 band.inProgress - max 0 band.patched > 0 then
        "Nothing due. More of them tomorrow."

    else
        "Nothing due, and you have started every one."


{-| Every tier in good shape: one line, and nothing to press.
-}
allClearLine : String
allClearLine =
    "Nice work — every one of your mistakes is in good shape."


{-| The offer under a tier that is in good shape: the next tier down, by
its mark and its words.

    "WORK ON ? BAD MOVES"

-}
nextTierLabel : String -> String
nextTierLabel grade =
    String.toUpper ("Work on " ++ mark grade ++ " " ++ bandWord grade ++ " moves")


{-| The day, wherever it used to be a ring: a plain count of what has
been answered, and nothing to measure it against.

    "3 fixed today"
    "1 fixed today"
    "Nothing fixed yet today"

-}
fixedToday : Int -> String
fixedToday done =
    case max 0 done of
        0 ->
            "Nothing fixed yet today"

        n ->
            String.fromInt n ++ " fixed today"


{-| The end of a run, over the marks. A run has no fixed length, so the
words are about what was done and never about what was not.

**One is a whole session.** Stopping after a single mistake is the thing
the page invites, so it must not read as quitting: it gets its own
sentence, warm and finished.

-}
runSummary : { right : Int, close : Int, total : Int } -> String
runSummary score =
    if score.total <= 0 then
        "Nothing answered."

    else if score.total == 1 then
        if score.right == 1 then
            "One fixed. That is how it is done."

        else if score.close == 1 then
            "One faced, and close. That counts."

        else
            "One faced. It comes back tomorrow."

    else
        String.fromInt score.right ++ " of " ++ String.fromInt score.total ++ " right"


{-| One band's own line, in the order the bar is drawn in: what is being
worked on, what is patched, and how many there are in all.

    "Very bad · 30 in progress · 12 patched · of 61"

-}
line : Band -> String
line band =
    bandName band.grade
        ++ " · "
        ++ String.fromInt (max 0 band.inProgress)
        ++ " in progress · "
        ++ String.fromInt (max 0 band.patched)
        ++ " patched · of "
        ++ String.fromInt (max 0 band.total)


{-| The moment the whole thing exists for, on the reveal's level line.
The rest of that line says when it comes back.
-}
milestone : Int -> String
milestone level =
    "Patched. " ++ String.toUpper (String.left 1 (word level)) ++ String.dropLeft 1 (word level) ++ " right in a row"


{-| Above the board in a session: why this position is in front of you.

    "A very bad move, from your game vs Charlie"

The opponent is dropped when the room never held a name.

-}
whyLine : { grade : String, opponent : String } -> String
whyLine why =
    "A "
        ++ bandWord why.grade
        ++ " move, from your game"
        ++ (if why.opponent == "" then
                ""

            else
                " vs " ++ why.opponent
           )


{-| The end of a run, when it patched anything: "You patched 2 very bad
moves and 1 bad move." Counted by band, worst first, from the grade of
each mistake the run crossed the rung on. Nothing when it crossed none --
the score has already said how it went.
-}
patchedRun : List String -> Maybe String
patchedRun grades =
    let
        counted grade =
            List.length (List.filter ((==) grade) grades)

        clauses =
            [ "very_bad", "bad", "doubtful" ]
                |> List.filterMap
                    (\grade ->
                        case counted grade of
                            0 ->
                                Nothing

                            n ->
                                Just (moves n grade)
                    )
    in
    case clauses of
        [] ->
            Nothing

        _ ->
            Just ("You patched " ++ join clauses ++ ".")


{-| "a, b and c": an "and" before the last, commas before the rest.
-}
join : List String -> String
join clauses =
    case List.reverse clauses of
        [] ->
            ""

        [ one ] ->
            one

        last :: rest ->
            String.join ", " (List.reverse rest) ++ " and " ++ last


{-| "four times", "once", "twice".
-}
times : Int -> String
times n =
    case n of
        1 ->
            "once"

        2 ->
            "twice"

        _ ->
            word n ++ " times"


{-| Small numbers in words, as the rest of the site writes them.
-}
word : Int -> String
word n =
    case n of
        1 ->
            "one"

        2 ->
            "two"

        3 ->
            "three"

        4 ->
            "four"

        5 ->
            "five"

        6 ->
            "six"

        7 ->
            "seven"

        8 ->
            "eight"

        _ ->
            String.fromInt n
