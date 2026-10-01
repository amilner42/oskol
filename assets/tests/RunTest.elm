module RunTest exposing (suite)

{-| A practice run as the shell drives it (`Main` hands every step to
`Run`): what the strip is told, what an answer counts for, and how a run
goes on past the ids it was started with -- it never ends because a page
of twenty did, only when its queue has nothing new, and then the end card
offers KEEP GOING or PRACTICE ANYWAY.
-}

import Api.PracticeDecks as PracticeDecks
import Expect
import Games.Backgammon.Puzzle exposing (Verdict(..))
import Page.Puzzle as Page exposing (Way(..))
import Run exposing (Run, Source(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "a practice run"
        [ starting
        , answering
        , goingOn
        , keepingGoing
        , anyway
        , theWayOn
        ]


ids : String -> Int -> List String
ids prefix n =
    List.range 1 n |> List.map (\i -> prefix ++ String.fromInt i)


tierRun : List String -> Run
tierRun list =
    Run.start { ids = list, next = "/puzzles", source = Band "very_bad", anyway = False, deckToday = Just { done = 2, target = 5 } }
        |> Maybe.withDefault emptyRun


emptyRun : Run
emptyRun =
    { ids = [], at = 0, answers = [], next = "", source = Fixed, anyway = False, served = 0, deckToday = Nothing }


at : Int -> Run -> Run
at n run =
    { run | at = n }


pass : Page.Answer
pass =
    { verdict = Pass, schedule = Just graded, grade = "very_bad" }


miss : Page.Answer
miss =
    { verdict = Fail, schedule = Just graded, grade = "very_bad" }


graded : Games.Backgammon.Puzzle.Schedule
graded =
    { levelBefore = 0, levelAfter = 1, due = 0, amendable = True, selfGrade = False, patched = False, heldDays = Nothing }


early : Page.Answer
early =
    { pass | schedule = Just { graded | amendable = False } }


{-| Answer every puzzle of the run from where it is to its last id, the
way the shell does: answer, then on to the next.
-}
answerAll : Page.Answer -> Run -> Run
answerAll given run =
    let
        ( answered, _ ) =
            Run.answer given run
    in
    case Run.nextId answered of
        Just _ ->
            answerAll given { answered | at = answered.at + 1 }

        Nothing ->
            answered


starting : Test
starting =
    describe "starting"
        [ test "an empty list starts nothing" <|
            \_ ->
                Run.start { ids = [], next = "/puzzles", source = Band "bad", anyway = False, deckToday = Nothing }
                    |> Expect.equal Nothing
        , test "a tier's run is that tier's, with the deck's ring" <|
            \_ ->
                let
                    run =
                        tierRun [ "a", "b" ]
                in
                ( Run.tier run, Run.deck run, Run.progress run |> .ring )
                    |> Expect.equal ( Just "very_bad", Nothing, Just { done = 2, target = 5 } )
        , test "a set's run is named by the set" <|
            \_ ->
                Run.start { ids = [ "o1" ], next = "/puzzles", source = InSet { id = "openings", name = "Openings" }, anyway = False, deckToday = Nothing }
                    |> Maybe.andThen Run.deck
                    |> Expect.equal (Just { id = "openings", name = "Openings" })
        ]


answering : Test
answering =
    describe "answering"
        [ test "an answer counts toward the day and the deck's ring, once" <|
            \_ ->
                let
                    ( once, first ) =
                        Run.answer pass (tierRun [ "a", "b" ])

                    ( twice, second ) =
                        Run.answer miss once
                in
                ( ( first, second ), ( Run.progress twice |> .ring, Run.progress twice |> .marks ) )
                    |> Expect.equal ( ( True, False ), ( Just { done = 3, target = 5 }, [ Just Fail, Nothing ] ) )
        , test "an early answer is practice only: it counts for nothing" <|
            \_ ->
                let
                    ( after, counts ) =
                        Run.answer early (tierRun [ "a" ])
                in
                ( counts, Run.progress after |> .ring )
                    |> Expect.equal ( False, Just { done = 2, target = 5 } )
        , test "the score is what was answered, never the length of the list" <|
            \_ ->
                let
                    ( one, _ ) =
                        Run.answer pass (tierRun (ids "p" 20))
                in
                Run.score one |> Expect.equal { right = 1, total = 1 }
        ]


goingOn : Test
goingOn =
    describe "a run never runs out"
        [ test "a deck's run always has somewhere after its last id: the queue again" <|
            \_ ->
                let
                    run =
                        tierRun [ "a", "b" ] |> at 1
                in
                ( Run.nextId run, Run.goesOn run, Run.queueUrl run )
                    |> Expect.equal ( Nothing, True, Just "/papi/practice?band=very_bad" )
        , test "a set asks its own session again" <|
            \_ ->
                Run.start { ids = [ "o1" ], next = "/puzzles", source = InSet { id = "openings", name = "Openings" }, anyway = False, deckToday = Nothing }
                    |> Maybe.andThen Run.queueUrl
                    |> Expect.equal (Just "/papi/decks/openings")
        , test "a game's mistakes are handed over whole: they end at their last" <|
            \_ ->
                let
                    run =
                        Run.start { ids = [ "a" ], next = "/backgammon/abc", source = Fixed, anyway = False, deckToday = Nothing }
                            |> Maybe.withDefault emptyRun
                in
                ( Run.goesOn run, Run.queueUrl run, Run.offersWays run )
                    |> Expect.equal ( False, Nothing, False )
        , test "past the twentieth, the refetch goes on with what it had not shown" <|
            \_ ->
                let
                    -- Twenty answered: the server's front of the queue is
                    -- now the five it had not sent, and maybe one of the
                    -- twenty again (answered early, say). Only the new ones
                    -- are added.
                    through =
                        tierRun (ids "p" 20) |> answerAll pass

                    refetched =
                        Run.refetched ([ "p20" ] ++ ids "q" 5) through
                in
                ( ( List.length through.answers, Run.nextId through ), ( List.length refetched.ids, Run.nextId refetched ) )
                    |> Expect.equal ( ( 20, Nothing ), ( 25, Just "q1" ) )
        , test "a refetch with nothing new is the end of today's set" <|
            \_ ->
                let
                    done =
                        tierRun [ "a", "b" ] |> answerAll pass |> Run.refetched [ "a", "b" ]
                in
                ( Run.nextId done, List.length done.ids )
                    |> Expect.equal ( Nothing, 2 )
        , test "the marks keep every answer across a refetch" <|
            \_ ->
                tierRun [ "a" ]
                    |> answerAll miss
                    |> Run.refetched [ "b" ]
                    |> at 1
                    |> Run.progress
                    |> (\p -> ( p.at, p.marks ))
                    |> Expect.equal ( 1, [ Just Fail, Nothing ] )
        ]


keepingGoing : Test
keepingGoing =
    describe "KEEP GOING"
        [ test "goes on with the ids it started, and today's set grows by as many: 3/3 reads 3/6" <|
            \_ ->
                let
                    done =
                        Run.start { ids = [ "a", "b", "c" ], next = "/puzzles", source = Band "bad", anyway = False, deckToday = Just { done = 0, target = 3 } }
                            |> Maybe.withDefault emptyRun
                            |> answerAll pass

                    more =
                        Run.keptGoing [ "d", "e", "f" ] done
                in
                ( Run.nextId more, Run.progress more |> .ring )
                    |> Expect.equal ( Just "d", Just { done = 3, target = 6 } )
        ]


anyway : Test
anyway =
    describe "PRACTICE ANYWAY"
        [ test "a run of it asks for the rotation past what it has been handed" <|
            \_ ->
                let
                    run =
                        Run.start { ids = ids "r" 20, next = "/puzzles", source = Band "bad", anyway = True, deckToday = Just { done = 3, target = 3 } }
                            |> Maybe.withDefault emptyRun
                in
                ( Run.queueUrl run, Run.queueUrl (Run.refetched (ids "s" 20) run) )
                    |> Expect.equal
                        ( Just "/papi/practice?band=bad&all=1&from=20"
                        , Just "/papi/practice?band=bad&all=1&from=40"
                        )
        , test "a set's rotation, the same" <|
            \_ ->
                Run.start { ids = ids "r" 20, next = "/puzzles", source = InSet { id = "openings", name = "Openings" }, anyway = True, deckToday = Nothing }
                    |> Maybe.andThen Run.queueUrl
                    |> Expect.equal (Just "/papi/decks/openings?all=1&from=20")
        , test "from the end card, it turns the run into practice only from then on" <|
            \_ ->
                let
                    run =
                        tierRun [ "a" ] |> answerAll pass |> Run.anywayFetched [ "x", "y" ]

                    ( after, counts ) =
                        Run.answer pass (at 1 run)
                in
                ( ( run.anyway, Run.nextId run ), ( counts, Run.progress after |> .ring ), Run.queueUrl after )
                    |> Expect.equal
                        ( ( True, Just "x" )
                        , ( False, Just { done = 3, target = 5 } )
                        , Just "/papi/practice?band=very_bad&all=1&from=2"
                        )
        ]


{-| One tier as `/papi/practice/decks` reads it, with only what `way` reads.
-}
tier : { due : Int, newLeft : Int, untouched : Int, total : Int } -> PracticeDecks.Deck
tier s =
    { id = "very_bad"
    , slug = "very-bad"
    , kind = PracticeDecks.Tier
    , name = "Very bad moves"
    , mark = "??"
    , blurb = ""
    , size = s.total
    , pace = 3
    , joined = True
    , standing =
        Just
            { total = s.total
            , untouched = s.untouched
            , inProgress = s.total - s.untouched
            , patched = 0
            , due = s.due
            , newLeft = s.newLeft
            , doneToday = 3
            , targetToday = 3 + s.due + s.newLeft
            , levels = []
            }
    , cost = Nothing
    }


theWayOn : Test
theWayOn =
    let
        run =
            tierRun [ "a" ]
    in
    describe "the way on from the end card"
        [ test "work left today (I'M DONE pressed early): KEEP GOING goes on with it" <|
            \_ ->
                Run.way run [ tier { due = 2, newLeft = 1, untouched = 10, total = 20 } ]
                    |> Expect.equal (Continue { due = 2, newLeft = 1 })
        , test "today's set done, some never shown: KEEP GOING starts the pace of them" <|
            \_ ->
                Run.way run [ tier { due = 0, newLeft = 0, untouched = 10, total = 20 } ]
                    |> Expect.equal (MoreNew 3)
        , test "no more than are left to start" <|
            \_ ->
                Run.way run [ tier { due = 0, newLeft = 0, untouched = 2, total = 20 } ]
                    |> Expect.equal (MoreNew 2)
        , test "everything started, nothing due: PRACTICE ANYWAY" <|
            \_ ->
                Run.way run [ tier { due = 0, newLeft = 0, untouched = 0, total = 20 } ]
                    |> Expect.equal Anyway
        , test "a deck the page cannot find, or a set not added: nothing" <|
            \_ ->
                let
                    notAdded =
                        tier { due = 0, newLeft = 0, untouched = 15, total = 15 }
                in
                ( Run.way run []
                , Run.way
                    (Run.start { ids = [ "o" ], next = "/puzzles", source = InSet { id = "openings", name = "Openings" }, anyway = False, deckToday = Nothing } |> Maybe.withDefault emptyRun)
                    [ { notAdded | id = "openings", kind = PracticeDecks.Set, joined = False } ]
                )
                    |> Expect.equal ( NoWay, NoWay )
        , test "the end of a run reads the deck's day afresh for the ring" <|
            \_ ->
                Run.withStanding [ tier { due = 0, newLeft = 0, untouched = 10, total = 20 } ] run
                    |> Run.progress
                    |> .ring
                    |> Expect.equal (Just { done = 3, target = 3 })
        ]
