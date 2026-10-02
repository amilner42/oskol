module Ui.Decks exposing
    ( doneToday
    , endSignIn
    , hasWork
    , ladderLine
    , masteredOf
    , masteredRun
    , legendTop
    , restingLine
    , rowLeft
    , runSummary
    , signInLine
    , signInRest
    , sizeEyebrow
    , sizeLine
    , standingLine
    , startLabel
    , startLine
    , stateLine
    , stateParts
    , stepsLine
    , tryLine
    )

{-| Every sentence the universal sets are said in: the openings and the
replies to them, and whatever sets come after.

A set is said in the mistakes' own words (`Ui.Mistakes`), because it is
the same ladder: you **train** it, a position you have started is
**learning**, one you have not is **to learn**, and one at the top is
**mastered**. As with mistakes, nothing a player reads says card, deck or
flashcard, nor "fix", "patched" or "learned".

-}

import Api.Decks exposing (Standing)
import Ui.Mistakes as Mistakes


{-| Does this set have something to do today?
-}
hasWork : Standing -> Bool
hasWork standing =
    standing.due > 0 || standing.newLeft > 0


{-| "11 left to master · 4 mastered" -- the left first, because that is
what the player is working through; mastered quieter beside it, and only
once there is some.
-}
standingLine : Standing -> String
standingLine standing =
    if standing.left == 0 then
        "All " ++ String.fromInt standing.total ++ " mastered"

    else if standing.patched == 0 then
        String.fromInt standing.left ++ " left to master"

    else
        String.fromInt standing.left ++ " left to master · " ++ String.fromInt standing.patched ++ " mastered"


{-| A set that has been added and has nothing to do today.
-}
restingLine : String
restingLine =
    "Nothing due. More of them tomorrow."


{-| What the button on a set says. An account that has added it
trains it, one that has not starts it, and anybody else tries it.
-}
startLabel : { signedIn : Bool, joined : Bool } -> String
startLabel who =
    if who.joined then
        "TRAIN"

    else if who.signedIn then
        "START"

    else
        "TRY"


{-| The day, in a run through a set: "3 practiced today".
-}
doneToday : Int -> String
doneToday done =
    case max 0 done of
        0 ->
            "Nothing practiced yet today"

        n ->
            String.fromInt n ++ " practiced today"


{-| The end of a run through a set. As with mistakes, one is a whole
session and says so; more than one is the plain count.
-}
runSummary : { right : Int, total : Int } -> String
runSummary score =
    if score.total <= 0 then
        "Nothing answered."

    else if score.total == 1 then
        if score.right == 1 then
            "One right. That is how it is done."

        else
            "One played. It comes back tomorrow."

    else
        String.fromInt score.right ++ " of " ++ String.fromInt score.total ++ " right"


{-| What a run took over the rung: "You mastered 2 of them." Nothing
when it took none.
-}
masteredRun : Int -> Maybe String
masteredRun n =
    case n of
        0 ->
            Nothing

        1 ->
            Just "You mastered one of them."

        _ ->
            Just ("You mastered " ++ String.fromInt n ++ " of them.")


{-| How much of the set is mastered, under the celebration: "4 of 15
mastered." The whole of it, said plainly.
-}
masteredOf : { mastered : Int, total : Int } -> String
masteredOf counts =
    String.fromInt (max 0 counts.mastered) ++ " of " ++ String.fromInt (max 0 counts.total) ++ " mastered."


{-| What a run through a set did, under the celebration: the same line
the mistakes say. "2 stepped up a level · 1 mastered".
-}
stepsLine : { stepped : Int, mastered : Int } -> String
stepsLine counts =
    Mistakes.stepsLine { stepped = counts.stepped, patched = counts.mastered }


{-| A set in its three states, as the grid is filled in: mastered,
learning, still to learn, and how many in all. Every part even at zero,
because the line is the grid's legend too.

    "4 mastered · 6 learning · 5 to learn · of 15"

-}
stateLine : { total : Int, untouched : Int, inProgress : Int, patched : Int } -> String
stateLine counts =
    String.join " · " (List.map Tuple.second (stateParts counts))


{-| The same line in its parts, each with the state it names: the
mistakes' own (`Ui.Mistakes.stateParts`).
-}
stateParts : { total : Int, untouched : Int, inProgress : Int, patched : Int } -> List ( String, String )
stateParts =
    Mistakes.stateParts


{-| A set's size, over its name: "15 POSITIONS".
-}
sizeEyebrow : Int -> String
sizeEyebrow n =
    String.fromInt n
        ++ (if n == 1 then
                " POSITION"

            else
                " POSITIONS"
           )


{-| A set nobody has added, for anybody: how many to learn.

    "15 positions to learn"

-}
sizeLine : Int -> String
sizeLine n =
    String.fromInt n
        ++ (if n == 1 then
                " position to learn"

            else
                " positions to learn"
           )


{-| Under START: what adding the set means, in its own pace.

    "Five new a day, and each comes back until you know it."

-}
startLine : Int -> String
startLine pace =
    String.toUpper (String.left 1 (paceWord pace))
        ++ String.dropLeft 1 (paceWord pace)
        ++ " new a day, and each comes back until you know it."


paceWord : Int -> String
paceWord n =
    case n of
        1 ->
            "one"

        2 ->
            "two"

        3 ->
            "three"

        5 ->
            "five"

        10 ->
            "ten"

        _ ->
            String.fromInt n


{-| Under TRY, for anybody without an account: a walk, nothing kept.
-}
tryLine : String
tryLine =
    "Played in order, nothing kept. Sign in to keep your place."


{-| A row's number for a set: what is left to master of it.
-}
rowLeft : Int -> String
rowLeft n =
    if n <= 0 then
        "All mastered"

    else
        String.fromInt n ++ " left"


{-| What a guest reads at the end of a run through a set, over the
sign-in.
-}
endSignIn : String
endSignIn =
    "Sign in and we'll keep your place: each comes back until you know it."



-- A SET'S OWN PAGE


{-| A position at the top of a set's ladder: mastered, as a mistake's.
-}
legendTop : String
legendTop =
    Mistakes.legendTop


{-| A set's ladder in words.

    "3 back at the start, 7 at level 1, 4 mastered."

-}
ladderLine : { patchedLevel : Int, started : List Int } -> String
ladderLine =
    Mistakes.ladderWords legendTop


{-| Under a set's page, for anybody without an account.
-}
signInLine : String
signInLine =
    "Sign in" ++ signInRest


{-| The same line after its first two words, which the page draws as the
button that opens the sign-in.
-}
signInRest : String
signInRest =
    " to keep your place in these."
