module Ui.Mistakes exposing
    ( bandName
    , bandWord
    , fixLabel
    , lead
    , line
    , milestone
    , moves
    , patchedNote
    , patchedRun
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


{-| A band as the server counts it: how bad, how many, how many patched.
-}
type alias Band =
    { grade : String, total : Int, patched : Int }


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


{-| What the practice home leads with: the worst band the player actually
has, and how much of it they have fixed.

    "You have made 61 very bad moves. You have patched 23."

Nothing when there is no mistake of any band: the page has its own words
for a player with nothing to fix yet.

-}
lead : List Band -> Maybe String
lead bands =
    case List.filter (\band -> band.total > 0) bands of
        [] ->
            Nothing

        worst :: _ ->
            Just
                ("You have made "
                    ++ moves worst.total worst.grade
                    ++ ". You have patched "
                    ++ String.fromInt worst.patched
                    ++ "."
                )


{-| One band's own line: "Very bad · 23 of 61 patched".
-}
line : Band -> String
line band =
    bandName band.grade
        ++ " · "
        ++ String.fromInt band.patched
        ++ " of "
        ++ String.fromInt band.total
        ++ " patched"


{-| What patched means, said once and quietly under the bars. The number
is the server's (`deck.patched_level`), so this cannot drift from it.
-}
patchedNote : Int -> String
patchedNote level =
    "Patched: right " ++ times level ++ " running."


{-| The moment the whole thing exists for, on the reveal's level line.
The rest of that line says when it comes back.
-}
milestone : Int -> String
milestone level =
    "Patched. " ++ String.toUpper (String.left 1 (word level)) ++ String.dropLeft 1 (word level) ++ " right in a row"


{-| The button on the practice home: what today still asks of you, in one
verb. Everything due and the new mistakes the day allows are one number
here; a day that is finished says so and the way on is KEEP GOING.
-}
fixLabel : { done : Int, target : Int } -> String
fixLabel today =
    if today.target - today.done <= 0 then
        "DONE FOR TODAY"

    else
        "FIX " ++ String.fromInt (today.target - today.done) ++ " TODAY"


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
