module Ui.Mistakes exposing
    ( Band
    , addsLine
    , allClearLine
    , applyLabel
    , backLine
    , bandName
    , bandWord
    , costHeadline
    , costLine
    , dayStreakLine
    , earlyLine
    , earlyLineUndated
    , everyOnePractised
    , dueLine
    , emptyTierLine
    , ladderLine
    , ladderWords
    , legendParts
    , legendTop
    , strangerTierLine
    , practisedToday
    , freshLine
    , guestPracticeLine
    , guestStateLine
    , keepGoingLine
    , oneDecimal
    , rowLeft
    , scheduledLine
    , stateLine
    , stateParts
    , stepsLine
    , todayDone
    , todayEyebrow
    , unsavedLine
    , wonBackLine
    , workLine
    , goodShapeLine
    , goodShapeWhy
    , gotItGraded
    , gotItUnchecked
    , gotItHolds
    , hasWork
    , knewItWhy
    , knownLine
    , leftToMaster
    , line
    , mark
    , milestone
    , missedNote
    , moves
    , neverWhy
    , nextTierLabel
    , masteredAside
    , masteredRun
    , practiceOnlyRun
    , practiceOnlyTag
    , runSummary
    , soonerWhy
    , tierName
    , whyLine
    )

{-| The words practice is said in.

One rule holds all of them: **the unit is a mistake you made**, and what
you do with it is **train** it. Nothing a player reads here says "card",
"deck" or "flashcard" -- those are how it is stored, not what it is. A
mistake you have started on is **learning**, one you have not is **to
learn**, and one you have stopped making is **mastered** -- the same
three words for the sets (`Ui.Decks`), because it is the same ladder.
Nothing a player reads says "fix" or "patched" (pinned in
`MistakesTest`); `patched` survives only as the wire's name for the top
rungs.

They live in one module because the same sentence is printed in three
places (the practice home, the session, the end of a run) and a phrase
that drifts between them reads like two different products. Every one of
them is pinned in `MistakesTest`.

-}


{-| A band as the server counts it, in its three states: how bad, how
many, how many are learning (`inProgress`), how many are mastered
(`patched`). What is neither is still to learn.

**Three states, not two.** Mastered is four right answers over twelve days
at the very earliest, so a player halfway through fifty of their mistakes
would read "0 mastered" for weeks. What they are working on is progress
and is said out loud.

-}
type alias Band =
    { grade : String, total : Int, inProgress : Int, patched : Int, due : Int, newLeft : Int }


{-| Does this tier still have something to train today? The server has
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
to master. Everything not mastered -- what is *due* changes hour to hour
and is not what anyone is trying to get to zero. The sets say it the same
way.

    "31 left to master"

-}
leftToMaster : Band -> String
leftToMaster band =
    String.fromInt (max 0 (band.total - max 0 band.patched)) ++ " left to master"


{-| Quieter, beside it: "23 mastered". Nothing at all when none is, so a
player on their first day is not shown a zero.
-}
masteredAside : Band -> Maybe String
masteredAside band =
    case max 0 band.patched of
        0 ->
            Nothing

        n ->
            Just (String.fromInt n ++ " mastered")


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


{-| The day: a plain count of what has been answered, misses and all,
and nothing to measure it against. **Practised, never "mastered"**: a
miss masters nothing, and a count that said "8 mastered" over six red
misses is the number that lies. "Mastered" is kept for a mistake that has
actually crossed the top rung.

    "3 practised today"
    "1 practised today"
    "Nothing practised yet today"

-}
practisedToday : Int -> String
practisedToday done =
    case max 0 done of
        0 ->
            "Nothing practised yet today"

        n ->
            String.fromInt n ++ " practised today"


{-| The end of a run, over the marks. A run has no fixed length, so the
words are about what was done and never about what was not.

**One is a whole session.** Stopping after a single mistake is the thing
the page invites, so it must not read as quitting: it gets its own
sentence, warm and finished.

-}
runSummary : { right : Int, total : Int } -> String
runSummary score =
    if score.total <= 0 then
        "Nothing answered."

    else if score.total == 1 then
        if score.right == 1 then
            "One right. That is how it is done."

        else
            "One faced. It comes back tomorrow."

    else
        String.fromInt score.right ++ " of " ++ String.fromInt score.total ++ " right"


{-| One band's own line, in the order the bar is drawn in: what is being
worked on, what is mastered, and how many there are in all.

    "Very bad · 30 learning · 12 mastered · of 61"

-}
line : Band -> String
line band =
    bandName band.grade
        ++ " · "
        ++ String.fromInt (max 0 band.inProgress)
        ++ " learning · "
        ++ String.fromInt (max 0 band.patched)
        ++ " mastered · of "
        ++ String.fromInt (max 0 band.total)


{-| The moment the whole thing exists for, on the reveal's level line.
The rest of that line says when it comes back.
-}
milestone : Int -> String
milestone level =
    "Mastered. " ++ String.toUpper (String.left 1 (word level)) ++ String.dropLeft 1 (word level) ++ " right in a row"


{-| After the reveal the four choices select before they act, and the
line under them says what the selected one would do. Said from the
schedule the answer came back with, so the words are about this
mistake and not about choices in general.

    "Back to the start: it comes back tomorrow. Level 3 → 0."

The level part is left off where it is at the start already.

-}
soonerWhy : Int -> String
soonerWhy levelBefore =
    "Back to the start: it comes back tomorrow."
        ++ (if levelBefore > 0 then
                " Level " ++ String.fromInt levelBefore ++ " → 0."

            else
                ""
           )


{-| GOT IT on an answer the engine passed: what the grade already did,
in the level line's own words ("Level 2 → 3 · back in 7 days").
-}
gotItGraded : String -> String
gotItGraded levelLine =
    "As graded. " ++ levelLine ++ "."


{-| GOT IT where nothing could check the answer: it counts, and holds
the level rather than raising it. The second argument is when it comes
back, "back in 3 days".
-}
gotItUnchecked : Int -> String -> String
gotItUnchecked level backIn =
    "Counts as right, but nothing checked it: level " ++ String.fromInt level ++ " stays · " ++ backIn ++ "."


{-| The same, where the answer did not say how long the level waits (a
schedule stored before it did): the level holds, and no date is guessed.
-}
gotItHolds : Int -> String
gotItHolds level =
    "Counts as right, but nothing checked it: level " ++ String.fromInt level ++ " stays."


{-| GOT IT after a miss is not one of the choices; a tap on it says why
rather than doing nothing.
-}
missedNote : String
missedNote =
    "You missed this one."


{-| The level line after KNEW IT: the mistake went to the top in one
step, because the player said they knew it -- not because they answered
it right seven times, so the line never says they did. The argument is
when it comes back, "back in a year".

    "Marked as known — back in a year"

-}
knownLine : String -> String
knownLine backIn =
    "Marked as known — " ++ backIn


{-| The level line for an answer given before the mistake was due
(PRACTICE ANYWAY, or a second go at one already answered): the reveal is
the whole of it, and the ladder does not move. The argument is the day it
is due, "9 Oct".

    "Not due until 9 Oct — practice only, nothing moves."

-}
earlyLine : String -> String
earlyLine date =
    "Not due until " ++ date ++ " — practice only, nothing moves."


{-| The same, where the answer did not say when it is due.
-}
earlyLineUndated : String
earlyLineUndated =
    "Not due yet — practice only, nothing moves."


{-| Over the board in a run started from PRACTICE ANYWAY, where the day's
count would be: nothing in this run moves anything, the day included.
-}
practiceOnlyTag : String
practiceOnlyTag =
    "Practice only"


{-| Under the score at the end of such a run.
-}
practiceOnlyRun : String
practiceOnlyRun =
    "Practice only: none of these were due, so nothing moved."


{-| The end card's way on, once a press of it found nothing it had not
already put in front of the player.
-}
everyOnePractised : String
everyOnePractised =
    "That's every one of these for now. The ones you get wrong come back on their day."


{-| The way back from the end of a run, to the page it was started from,
named for what that page is:

    "Back to puzzles →"            the practice home
    "Back to very bad moves →"     a deck's own page (its name)
    "Back to the replay →"         a replay
    "Back home →"                  the signed-in home
    "Back to the game →"           the table

-}
backLine : { next : String, name : Maybe String } -> String
backLine back =
    let
        path =
            back.next |> String.split "?" |> List.head |> Maybe.withDefault back.next
    in
    (if path == "/puzzles" then
        "Back to puzzles"

     else if String.startsWith "/practice/" path then
        case back.name of
            Just name ->
                "Back to " ++ String.toLower name

            Nothing ->
                "Back to puzzles"

     else if path == "/" || path == "" then
        "Back home"

     else if String.endsWith "/replay" path then
        "Back to the replay"

     else
        "Back to the game"
    )
        ++ " →"


knewItWhy : String
knewItWhy =
    "I already knew this: to the top, back in a year."


neverWhy : String
neverWhy =
    "Out of your practice for good. It will not come back, and this cannot be undone."


{-| The button that makes a selected choice take effect. NEVER cannot be
undone, so its button says so in the asking.
-}
applyLabel : String -> String
applyLabel outcome =
    if outcome == "never" then
        "YES, NEVER"

    else
        "APPLY"


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


{-| The end of a run, when it mastered anything: "You mastered 2 very bad
moves and 1 bad move." Counted by band, worst first, from the grade of
each mistake the run crossed the rung on. Nothing when it crossed none --
the score has already said how it went.
-}
masteredRun : List String -> Maybe String
masteredRun grades =
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
            Just ("You mastered " ++ join clauses ++ ".")


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



-- THE PRACTICE HOME


{-| A tier in its three states, in the order the grid is filled in:
what is mastered, what is learning, what is still to learn, and how
many there are in all. Each part is said even at zero: the line is also
the grid's legend, and a legend that loses a colour is another legend.

    "12 mastered · 20 learning · 12 to learn · of 44"

-}
stateLine : { total : Int, untouched : Int, inProgress : Int, patched : Int } -> String
stateLine counts =
    String.join " · " (List.map Tuple.second (stateParts counts))


{-| The same line in its parts, each with the state it names
("patched", "in-progress", "to-start", "total": the grid's names, not a
player's), so a page can put the grid's own colour beside each. A set
says it in the same words (`Ui.Decks.stateParts` is this).
-}
stateParts : { total : Int, untouched : Int, inProgress : Int, patched : Int } -> List ( String, String )
stateParts counts =
    [ ( "patched", String.fromInt (max 0 counts.patched) ++ " mastered" )
    , ( "in-progress", String.fromInt (max 0 counts.inProgress) ++ " learning" )
    , ( "to-start", String.fromInt (max 0 counts.untouched) ++ " to learn" )
    , ( "total", "of " ++ String.fromInt (max 0 counts.total) )
    ]


{-| A guest's tier, which nothing is keeping yet: how many, and where
they came from.

    "23 very bad moves from your games"

-}
guestStateLine : Int -> String -> String
guestStateLine n grade =
    moves n grade ++ " from your games"


{-| What one tier cost, over the graded games it was counted in, said in
PR throughout -- the rating the player knows, and the unit the head line
speaks -- so the two numbers in the sentence add up. Raw equity is never
shown: "4.8 points" beside "5.1, not 8.3" reads as a contradiction.

    "These cost you 3.2 PR over 6 games. Without them your PR would be
    5.1, not 8.3."

The cost is the difference of the two figures as they are printed, so
the sentence's own arithmetic always holds.

-}
costLine : { games : Int, pr : Float, prWithout : Float } -> String
costLine cost =
    "These cost you "
        ++ oneDecimal (gap cost.pr cost.prWithout)
        ++ " PR over "
        ++ String.fromInt (max 0 cost.games)
        ++ (if cost.games == 1 then
                " game"

            else
                " games"
           )
        ++ ". Without them your PR would be "
        ++ oneDecimal cost.prWithout
        ++ ", not "
        ++ oneDecimal cost.pr
        ++ "."


{-| What mastering has won back of one tier's cost, once there is any:
the PR the mastered ones were worth.

    "Mastered so far: 0.6 PR won back."

-}
wonBackLine : { pr : Float, prPatched : Float } -> Maybe String
wonBackLine cost =
    wonBack cost |> Maybe.map (\back -> "Mastered so far: " ++ back ++ " PR won back.")


{-| The head of the practice home, over every mistake at once: how much
of the player's rating their mistakes are, and -- once anything is
mastered -- what that has won back.

    ( "Your mistakes are 8.0 of your 8.3 PR."
    , Just "Mastering them has won back 0.6 so far."
    )

-}
costHeadline : { pr : Float, prWithout : Float, prPatched : Float } -> ( String, Maybe String )
costHeadline cost =
    ( "Your mistakes are " ++ oneDecimal (gap cost.pr cost.prWithout) ++ " of your " ++ oneDecimal cost.pr ++ " PR."
    , wonBack { pr = cost.pr, prPatched = cost.prPatched }
        |> Maybe.map (\back -> "Mastering them has won back " ++ back ++ " so far.")
    )


{-| How much PR the mastered ones were worth, to one decimal -- and
nothing at all until that is something a reader could see.
-}
wonBack : { pr : Float, prPatched : Float } -> Maybe String
wonBack cost =
    let
        back =
            gap cost.pr cost.prPatched
    in
    if back <= 0 then
        Nothing

    else
        Just (oneDecimal back)


{-| The quiet line at the top of the practice home: how long the player
has kept showing up, and what today has come to. The streak is left off
at zero rather than said as a zero.

    "5 days running · 3 practised today"
    "1 day running · nothing practised yet today"
    "Nothing practised yet today"

-}
dayStreakLine : { streak : Int, done : Int } -> String
dayStreakLine day =
    let
        today =
            practisedToday day.done
    in
    case max 0 day.streak of
        0 ->
            today

        n ->
            String.fromInt n
                ++ (if n == 1 then
                        " day running · "

                    else
                        " days running · "
                   )
                ++ String.toLower (String.left 1 today)
                ++ String.dropLeft 1 today


{-| Under TRAIN: what today still asks of this tier. Empty when it
asks nothing (and then TRAIN is not the button).

    "4 due now · 3 new today"

-}
workLine : { due : Int, newLeft : Int } -> String
workLine work =
    [ if work.due > 0 then
        Just (String.fromInt work.due ++ " due now")

      else
        Nothing
    , if work.newLeft > 0 then
        Just (String.fromInt work.newLeft ++ " new today")

      else
        Nothing
    ]
        |> List.filterMap identity
        |> String.join " · "


{-| The celebration's head, the moment today's set is done: the same
words for a tier and a set, said as the thing it is, with the number the
ring over the board has been counting to.

    "Today's 5 done."

-}
todayDone : Int -> String
todayDone target =
    "Today's " ++ String.fromInt (max 0 target) ++ " done."


{-| The eyebrow over it.
-}
todayEyebrow : String
todayEyebrow =
    "TODAY"


{-| What this run's answers did, under the celebration's head: how many
climbed a rung and how many of those it mastered. Never "nothing moved":
a run of misses is said as what it is, every one of them coming back.

    "2 stepped up a level · 1 mastered"
    "1 stepped up a level"
    "Every one of these is back on its way"

The sets say it in the same words (`Ui.Decks.stepsLine`).

-}
stepsLine : { stepped : Int, patched : Int } -> String
stepsLine counts =
    if counts.stepped <= 0 && counts.patched <= 0 then
        "Every one of these is back on its way"

    else
        [ if counts.stepped > 0 then
            Just (String.fromInt counts.stepped ++ " stepped up a level")

          else
            Nothing
        , if counts.patched > 0 then
            Just (String.fromInt counts.patched ++ " mastered")

          else
            Nothing
        ]
            |> List.filterMap identity
            |> String.join " · "


{-| Under KEEP GOING, once today's set is done: said as the moment it
is, then what the button does. The sets say it in the same words.

    "Today's 5 done. Keep going adds 3 more."
    "Nothing due here today. Keep going adds 3 more."

-}
keepGoingLine : { done : Int, adds : Int } -> String
keepGoingLine day =
    (if day.done > 0 then
        "Today's " ++ String.fromInt day.done ++ " done."

     else
        "Nothing due here today."
    )
        ++ " Keep going adds "
        ++ String.fromInt (max 0 day.adds)
        ++ " more."


{-| Under KEEP GOING on the celebration, where "Today's 5 done." is
already the card's head: only what the button does.

    "Keep going adds 3 more."

-}
addsLine : Int -> String
addsLine adds =
    "Keep going adds " ++ String.fromInt (max 0 adds) ++ " more."


{-| Under PRACTICE ANYWAY: everything has been started and nothing is
due, so an answer now is practice and moves nothing.
-}
scheduledLine : String
scheduledLine =
    "Everything here is scheduled. Practising early moves nothing."


{-| Under a guest's TRAIN: the order it comes in. That nothing is
kept is said once, over the card.
-}
guestPracticeLine : String
guestPracticeLine =
    "Newest game first, one at a time."


{-| A guest's: nothing they do here is kept.
-}
unsavedLine : String
unsavedLine =
    "Your progress is not saved until you sign in."


{-| A row's number: what is still to master ("23 left"), or for a tier the
visitor has made no mistakes in, that there are none yet.
-}
rowLeft : Int -> String
rowLeft n =
    if n <= 0 then
        "None yet"

    else
        String.fromInt n ++ " left"


{-| An account with no mistakes yet: where they will come from, and what
to do meanwhile.
-}
freshLine : String
freshLine =
    "Your mistakes land here as your games are graded. Until then, learn the openings."


{-| The difference of two ratings as they are printed, to one decimal:
8.3 and 5.1 are 3.2 apart however the unrounded figures fall, so a
sentence that names all three always adds up.
-}
gap : Float -> Float -> Float
gap from to =
    toFloat (round (from * 10) - round (to * 10)) / 10


{-| A rating to one decimal, always: "8" reads as "8.0".
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



-- A DECK'S OWN PAGE


{-| The legend under a deck page's grid, a part per paint in the order a
position climbs them, the same for a mistake and a set:

    "to learn · level 1 · 2 · 3 · mastered"

Each part carries the state it names, so the page can draw the grid's
own colour beside it.

-}
legendParts : String -> List ( String, String )
legendParts top =
    [ ( "to-start", "to learn" )
    , ( "level-1", "level 1" )
    , ( "level-2", "2" )
    , ( "level-3", "3" )
    , ( "patched", top )
    ]


{-| A position at the top of the ladder, a mistake's or a set's.
-}
legendTop : String
legendTop =
    "mastered"


{-| The ladder in words, over the positions that have been started: how
many went back to the start, how many sit on each rung below the top,
and how many are at the top, mastered. A rung with nobody
on it is left out; nothing started is nothing said.

    "2 back at the start, 8 at level 1, 5 at level 2, 3 at level 3, 6 mastered."

-}
ladderLine : { patchedLevel : Int, started : List Int } -> String
ladderLine =
    ladderWords legendTop


{-| The ladder in words with the top said in `top`: what `ladderLine`
is for a mistake and `Ui.Decks.ladderLine` for a set. `started` is how
many started positions sit on each rung, lowest first.
-}
ladderWords : String -> { patchedLevel : Int, started : List Int } -> String
ladderWords top ladder =
    let
        on rung =
            ladder.started |> List.drop rung |> List.head |> Maybe.withDefault 0

        atTop =
            ladder.started |> List.drop (max 1 ladder.patchedLevel) |> List.sum

        parts =
            (( on 0, " back at the start" )
                :: (List.range 1 (max 1 ladder.patchedLevel - 1)
                        |> List.map (\rung -> ( on rung, " at level " ++ String.fromInt rung ))
                   )
            )
                ++ [ ( atTop, " " ++ top ) ]
                |> List.filter (\( n, _ ) -> n > 0)
                |> List.map (\( n, words ) -> String.fromInt n ++ words)
    in
    case parts of
        [] ->
            ""

        _ ->
            String.join ", " parts ++ "."


{-| What is due, on a deck's page: today's work while there is any, else
when the next one comes back -- in whole days, "tomorrow" at one or
less -- else, with nothing in rotation, that nothing is due.

    "12 due now · 3 new today"
    "Nothing due. Next due tomorrow."
    "Nothing due. Next due in 5 days."
    "Nothing due."

-}
dueLine : { due : Int, newLeft : Int, nextInDays : Maybe Int } -> String
dueLine work =
    if work.due > 0 || work.newLeft > 0 then
        workLine { due = work.due, newLeft = work.newLeft }

    else
        case work.nextInDays of
            Just days ->
                if days <= 1 then
                    "Nothing due. Next due tomorrow."

                else
                    "Nothing due. Next due in " ++ String.fromInt days ++ " days."

            Nothing ->
                "Nothing due."


{-| A tier's page for a stranger: nothing of theirs is here yet.
-}
strangerTierLine : String
strangerTierLine =
    "Play a game and your mistakes appear here."


{-| A tier's page for an account with none in it yet.

    "No very bad moves yet. They land here as your games are graded."

-}
emptyTierLine : String -> String
emptyTierLine grade =
    "No " ++ bandWord grade ++ " moves yet. They land here as your games are graded."
