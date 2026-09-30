module Ui.Decks exposing
    ( doneToday
    , endSignIn
    , hasWork
    , learnedRun
    , restingLine
    , runSummary
    , standingLine
    , startLabel
    )

{-| Every sentence the universal sets are said in: the openings and the
replies to them, and whatever sets come after.

The mistakes have their own words (`Ui.Mistakes`): a mistake is **fixed**
and one you have stopped making is **patched**. A set is not made of
anything you did wrong, so a position in one is **learned** -- the same
rung on the same ladder, said as what it is. As with mistakes, nothing a
player reads says card, deck or flashcard.

-}

import Api.Decks exposing (Standing)


{-| Does this set have something to do today?
-}
hasWork : Standing -> Bool
hasWork standing =
    standing.due > 0 || standing.newLeft > 0


{-| "11 left to learn · 4 learned" -- the left first, because that is
what the player is working through; learned quieter beside it, and only
once there is some.
-}
standingLine : Standing -> String
standingLine standing =
    if standing.left == 0 then
        "All " ++ String.fromInt standing.total ++ " learned"

    else if standing.patched == 0 then
        String.fromInt standing.left ++ " left to learn"

    else
        String.fromInt standing.left ++ " left to learn · " ++ String.fromInt standing.patched ++ " learned"


{-| A set that has been added and has nothing to do today.
-}
restingLine : String
restingLine =
    "Nothing due. More of them tomorrow."


{-| What the button on a set says. An account that has added it
practises it, one that has not starts it, and anybody else tries it.
-}
startLabel : { signedIn : Bool, joined : Bool } -> String
startLabel who =
    if who.joined then
        "PRACTICE"

    else if who.signedIn then
        "START"

    else
        "TRY"


{-| The day, in a run through a set: "3 practised today".
-}
doneToday : Int -> String
doneToday done =
    case max 0 done of
        0 ->
            "Nothing practised yet today"

        n ->
            String.fromInt n ++ " practised today"


{-| The end of a run through a set. As with mistakes, one is a whole
session and says so; more than one is the plain count.
-}
runSummary : { right : Int, close : Int, total : Int } -> String
runSummary score =
    if score.total <= 0 then
        "Nothing answered."

    else if score.total == 1 then
        if score.right == 1 then
            "One right. That is how it is done."

        else if score.close == 1 then
            "One played, and close. That counts."

        else
            "One played. It comes back tomorrow."

    else
        String.fromInt score.right ++ " of " ++ String.fromInt score.total ++ " right"


{-| What a run took over the rung: "You learned 2 of them." Nothing when
it took none.
-}
learnedRun : Int -> Maybe String
learnedRun n =
    case n of
        0 ->
            Nothing

        1 ->
            Just "You learned one of them."

        _ ->
            Just ("You learned " ++ String.fromInt n ++ " of them.")


{-| What a guest reads at the end of a run through a set, over the
sign-in.
-}
endSignIn : String
endSignIn =
    "Sign in and we'll keep your place: each comes back until you know it."
