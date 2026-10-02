module PuzzleCelebrationTest exposing (suite)

{-| The card the puzzle page draws under the reveal when the shell says
an answer finished today's set (`Run.celebrate` decides when; `RunTest`
holds that to "exactly once, on the counted answer that reaches the
target"). Here: that it is drawn after the reveal and under it, never for
a guest; what it says, from the run's own answers and the deck as the
server read it; that its two buttons go on and stop; that the band under
the board gives up ANOTHER and I'M DONE to it; and that its motion is the
CSS's business -- the page only says when it is on the screen, and with
reduced motion it is settled at once.
-}

import Api
import Api.Decks
import Api.PracticeDecks as PracticeDecks
import Dict
import Expect
import Games.Backgammon.Puzzle as Puzzle exposing (Verdict(..))
import Html.Attributes
import Json.Decode as D
import Page.Puzzle as Page exposing (Msg(..))
import PuzzleApiFixtures
import PuzzleRevealFixtures
import Session
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)


suite : Test
suite =
    describe "today's set, done, on the puzzle page"
        [ appearing
        , saying
        , grid
        , goingOn
        , motion
        ]



-- ARRANGING


fixture : List ( String, String ) -> String -> String
fixture all name =
    all |> List.filter (\( n, _ ) -> n == name) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault ""


account : Session.Session
account =
    Session.withUser (Just { email = "arie@example.com", name = Just "arie" }) Session.empty


step : Msg -> Page.Model -> Page.Model
step msg model =
    let
        ( next, _, _ ) =
            Page.update msg model
    in
    next


out : Msg -> Page.Model -> Page.Out
out msg model =
    let
        ( _, _, o ) =
            Page.update msg model
    in
    o


rendered : Page.Model -> Query.Single Msg
rendered model =
    Page.view model |> Query.fromHtml


dataAttr : String -> String -> Test.Html.Selector.Selector
dataAttr name value =
    attribute (Html.Attributes.attribute name value)


{-| The last puzzle of today's five, answered: a run of the very bad moves
(or a set), four done before it.
-}
answered : { session : Session.Session, deck : Maybe Api.Decks.Named } -> Page.Model
answered config =
    let
        ( model, _ ) =
            Page.init config.session
                { id = "p3"
                , hasNext = True
                , inRun = True
                , progress = Just { at = 2, marks = [ Just Pass, Just Fail, Nothing ], ring = Just { done = 4, target = 5 }, anyway = False }
                , tier =
                    if config.deck == Nothing then
                        Just "very_bad"

                    else
                        Nothing
                , deck = config.deck
                , today = Just { done = 4 }
                , origin = "http://oskol.test"
                , share = Nothing
                }

        loaded =
            case D.decodeString Puzzle.decoder (fixture PuzzleApiFixtures.all "move") of
                Ok p ->
                    GotPuzzle (Ok p)

                Err e ->
                    GotPuzzle (Err (Api.DecodeError (D.errorToString e)))

        keyed =
            model |> step loaded |> step (GotKey "key-0123")

        path =
            firstTurn keyed

        body =
            String.replace "\"schedule\":null"
                ("\"schedule\":" ++ fixture PuzzleRevealFixtures.all "schedule_amendable")
                (fixture PuzzleRevealFixtures.all "move_pass")
    in
    case Api.parseBody Puzzle.revealDecoder body of
        Ok r ->
            keyed |> step (BoardOut (Puzzle.Stepped path)) |> step (GotReveal (Ok r))

        Err _ ->
            keyed


firstTurn : Page.Model -> List String
firstTurn model =
    case model.puzzle of
        Page.Loaded p ->
            case p.tree of
                Just tree ->
                    let
                        walk nodeId path =
                            case Dict.get nodeId tree.nodes |> Maybe.map .children of
                                Just (child :: _) ->
                                    walk child.node (child.node :: path)

                                _ ->
                                    List.reverse path
                    in
                    walk tree.root []

                Nothing ->
                    []

        _ ->
            []


{-| What one answer did to its mistake. -}
did : Verdict -> Int -> Int -> Bool -> Page.Answer
did verdict before after patched =
    { verdict = verdict
    , grade = "very_bad"
    , schedule = Just { levelBefore = before, levelAfter = after, due = 0, amendable = True, selfGrade = False, patched = patched, heldDays = Nothing }
    }


{-| The run's answers: a new one right (paper to the first rung), a miss,
and the open one (level 3 to 4: patched).
-}
runAnswers : List ( String, Page.Answer )
runAnswers =
    [ ( "p1", did Pass 0 1 False ), ( "p2", did Fail 2 0 False ), ( "p3", did Pass 3 4 True ) ]


allMissed : List ( String, Page.Answer )
allMissed =
    [ ( "p1", did Fail 1 0 False ), ( "p2", did Fail 2 0 False ), ( "p3", did Fail 0 0 False ) ]


celebrating : List ( String, Page.Answer ) -> Page.Model -> Page.Model
celebrating given model =
    Page.celebrate { target = 5, answered = given } model |> Tuple.first


deckPageJson : { kind : String, cost : String, patched : Int, total : Int } -> String
deckPageJson d =
    """{"ok":true,"deck":{"id":"very_bad","slug":"very-bad","kind":\""""
        ++ d.kind
        ++ """","name":"Very bad moves","mark":"??","size":"""
        ++ String.fromInt d.total
        ++ ""","pace":3,"joined":true,"standing":{"total":"""
        ++ String.fromInt d.total
        ++ ""","untouched":1,"in_progress":2,"patched":"""
        ++ String.fromInt d.patched
        ++ ""","due":0,"new_left":0,"done_today":5,"target_today":5,"levels":[2,1,0,0,1,0,0,0]},"cost":"""
        ++ d.cost
        ++ """},"cells":[{"id":"p1","level":1,"due":0,"status":"active","position":0,"band":"very_bad"},{"id":"p2","level":0,"due":0,"status":"active","position":1,"band":"very_bad"},{"id":"p3","level":4,"due":0,"status":"active","position":2,"band":"very_bad"},{"id":"p4","level":0,"due":0,"status":"new","position":3,"band":"very_bad"}],"days":[],"patched_level":4}"""


readPage : String -> Maybe PracticeDecks.Page
readPage json =
    Api.parseBody PracticeDecks.pageDecoder json |> Result.toMaybe


tierRead : Maybe PracticeDecks.Page
tierRead =
    readPage (deckPageJson { kind = "mistakes", cost = """{"games":11,"lost":11.33,"lost_patched":0.66,"pr":8.3,"pr_without":4.8,"pr_patched":7.7}""", patched = 1, total = 4 })


setRead : Maybe PracticeDecks.Page
setRead =
    readPage (deckPageJson { kind = "set", cost = "null", patched = 4, total = 15 })


read : Maybe PracticeDecks.Page -> Page.Model -> Page.Model
read page model =
    Page.celebrationRead page model |> Tuple.first


card : Query.Single Msg -> Query.Single Msg
card =
    Query.find [ id "pz-today-done" ]


openings : Maybe Api.Decks.Named
openings =
    Just { id = "openings", name = "Openings" }



-- APPEARING


appearing : Test
appearing =
    describe "the card appears"
        [ test "under the reveal, inside it, after the answer: never before it" <|
            \_ ->
                let
                    model =
                        answered { session = account, deck = Nothing } |> celebrating runAnswers
                in
                Expect.all
                    [ \_ -> rendered model |> Query.find [ id "pz-reveal" ] |> Query.has [ id "pz-today-done" ]
                    , \_ -> rendered (answered { session = account, deck = Nothing }) |> Query.hasNot [ id "pz-today-done" ]
                    ]
                    ()
        , test "the band under the board keeps SHARE, and the card holds ANOTHER's and I'M DONE's place" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> rendered
                    |> Expect.all
                        [ Query.find [ id "pz-actions" ] >> Query.has [ id "pz-share" ]
                        , Query.find [ id "pz-actions" ] >> Query.hasNot [ id "pz-next" ]
                        , Query.findAll [ id "pz-done" ] >> Query.count (Expect.equal 1)
                        , card >> Query.has [ id "pz-done" ]
                        ]
        , test "never for a guest: a guest has no day" <|
            \_ ->
                answered { session = Session.empty, deck = Nothing }
                    |> celebrating runAnswers
                    |> rendered
                    |> Query.hasNot [ id "pz-today-done" ]
        , test "once on a page: a second word from the shell changes nothing" <|
            \_ ->
                let
                    once =
                        answered { session = account, deck = Nothing } |> celebrating runAnswers
                in
                Page.celebrate { target = 9, answered = [] } once
                    |> Tuple.first
                    |> rendered
                    |> card
                    |> Query.has [ dataAttr "data-target" "5" ]
        , test "laid out hidden while the deck is read, then drawn" <|
            \_ ->
                let
                    model =
                        answered { session = account, deck = Nothing } |> celebrating runAnswers
                in
                Expect.all
                    [ \_ -> rendered model |> card |> Query.hasNot [ class "is-ready" ]
                    , \_ -> rendered (read tierRead model) |> card |> Query.has [ class "is-ready" ]
                    , -- A read that is slow does not keep the moment waiting.
                      \_ -> rendered (step CelebrationWaited model) |> card |> Query.has [ class "is-ready" ]
                    ]
                    ()
        ]



-- SAYING


saying : Test
saying =
    describe "what it says"
        [ test "today's set, the ring full with its check, and the tier" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read tierRead
                    |> rendered
                    |> card
                    |> Expect.all
                        [ Query.find [ id "pz-today-title" ] >> Query.has [ text "Today's 5 done." ]
                        , Query.find [ id "pz-today-eyebrow" ] >> Query.has [ text "VERY BAD MOVES" ]
                        , Query.find [ id "pz-today-ring" ] >> Query.find [ tag "svg" ] >> Query.has [ dataAttr "data-done" "5", dataAttr "data-target" "5" ]
                        , Query.find [ id "pz-today-ring" ] >> Query.findAll [ tag "path", dataAttr "pathLength" "1" ] >> Query.count (Expect.equal 1)
                        ]
        , test "what moved, counted from the run's schedules" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-steps" ]
                    |> Query.has [ text "2 stepped up a level · 1 mastered" ]
        , test "a run of misses: every one of them coming back, never 'nothing moved'" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating allMissed
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-steps" ]
                    |> Query.has [ text "Every one of these is back on its way" ]
        , test "a choice applied after the card is up changes what it says" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> Page.withAnswered allMissed
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-steps" ]
                    |> Query.has [ text "Every one of these is back on its way" ]
        , test "a tier: what patching has won back, in PR" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read tierRead
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-tail" ]
                    |> Query.has [ text "Mastered so far: 0.6 PR won back." ]
        , test "a tier nothing has been patched in says nothing there, and keeps the line's place" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read (readPage (deckPageJson { kind = "mistakes", cost = """{"games":11,"lost":11.33,"lost_patched":0,"pr":8.3,"pr_without":4.8,"pr_patched":8.3}""", patched = 0, total = 4 }))
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-tail" ]
                    |> Query.has [ text "" ]
        , test "a set: its name, what moved in its own word, and how much of it is learned" <|
            \_ ->
                answered { session = account, deck = openings }
                    |> celebrating runAnswers
                    |> read setRead
                    |> rendered
                    |> card
                    |> Expect.all
                        [ Query.find [ id "pz-today-title" ] >> Query.has [ text "Today's 5 done." ]
                        , Query.find [ id "pz-today-eyebrow" ] >> Query.has [ text "OPENINGS" ]
                        , Query.find [ id "pz-today-steps" ] >> Query.has [ text "2 stepped up a level · 1 mastered" ]
                        , Query.find [ id "pz-today-tail" ] >> Query.has [ text "4 of 15 mastered." ]
                        ]
        ]



-- THE GRID


grid : Test
grid =
    describe "the deck's grid"
        [ test "drawn from the deck as read, a square a position" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read tierRead
                    |> rendered
                    |> Query.find [ id "pz-today-grid" ]
                    |> Query.find [ tag "svg" ]
                    |> Query.has [ dataAttr "data-count" "4" ]
        , test "the squares this run stepped up step up, oldest first, from the shade they had" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read tierRead
                    |> rendered
                    |> Query.find [ id "pz-today-grid" ]
                    |> Expect.all
                        [ -- the new one up to the first rung, and the patched one
                          -- up to the green; the miss went back to the start
                          -- and is drawn as it is, not stepping
                          Query.findAll [ tag "rect", attribute (Html.Attributes.attribute "data-was" "0") ] >> Query.count (Expect.equal 1)
                        , Query.findAll [ dataAttr "data-step" "0", dataAttr "data-level" "1" ] >> Query.count (Expect.equal 1)
                        , Query.findAll [ dataAttr "data-step" "1", dataAttr "data-level" "4" ] >> Query.count (Expect.equal 1)
                        , Query.findAll [ dataAttr "data-was" "3" ] >> Query.count (Expect.equal 1)
                        , Query.findAll [ dataAttr "data-step" "2" ] >> Query.count (Expect.equal 0)
                        ]
        , test "no grid when the deck could not be read: the rest of the card stands" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> read Nothing
                    |> rendered
                    |> card
                    |> Expect.all
                        [ Query.hasNot [ id "pz-today-grid" ]
                        , Query.has [ id "pz-today-title" ]
                        , Query.has [ id "pz-done" ]
                        ]
        ]



-- GOING ON


goingOn : Test
goingOn =
    let
        offered way =
            answered { session = account, deck = Nothing }
                |> celebrating runAnswers
                |> read tierRead
                |> Page.offering (Page.Offered way)
    in
    describe "never a wall"
        [ test "KEEP GOING beside I'M DONE, and what KEEP GOING adds" <|
            \_ ->
                rendered (offered (Page.MoreNew 3))
                    |> card
                    |> Expect.all
                        [ Query.find [ id "pz-keep-going" ] >> Query.has [ text "KEEP GOING", Test.Html.Selector.disabled False ]
                        , Query.find [ id "pz-done" ] >> Query.has [ text "I'M DONE" ]
                        , Query.find [ id "pz-today-way-line" ] >> Query.has [ text "Keep going adds 3 more." ]
                        ]
        , test "KEEP GOING asks the shell to go on, and says it is on its way" <|
            \_ ->
                let
                    model =
                        offered (Page.MoreNew 3)
                in
                Expect.all
                    [ \_ -> out (PressedWay (Page.MoreNew 3)) model |> Expect.equal (Page.GoOn (Page.MoreNew 3))
                    , \_ ->
                        rendered (step (PressedWay (Page.MoreNew 3)) model)
                            |> Query.find [ id "pz-keep-going" ]
                            |> Query.has [ class "is-busy", Test.Html.Selector.disabled True ]
                    ]
                    ()
        , test "nothing left to start: the first button is PRACTICE ANYWAY" <|
            \_ ->
                rendered (offered Page.Anyway)
                    |> card
                    |> Expect.all
                        [ Query.find [ id "pz-anyway" ] >> Query.has [ text "PRACTICE ANYWAY" ]
                        , Query.hasNot [ id "pz-keep-going" ]
                        ]
        , test "I'M DONE ends the run, as it always has" <|
            \_ ->
                out PressedDone (offered (Page.MoreNew 3)) |> Expect.equal Page.WantsEnd
        , test "while the deck is read the first button keeps its place, held back" <|
            \_ ->
                answered { session = account, deck = Nothing }
                    |> celebrating runAnswers
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-way-idle" ]
                    |> Query.has [ class "is-idle", Test.Html.Selector.disabled True ]
        , test "a press that finds nothing says why where the line is" <|
            \_ ->
                offered (Page.MoreNew 3)
                    |> Page.offering (Page.Stopped "Every one of these practised.")
                    |> rendered
                    |> card
                    |> Query.find [ id "pz-today-way-line" ]
                    |> Query.has [ text "Every one of these practised." ]
        ]



-- MOTION


motion : Test
motion =
    let
        drawn =
            answered { session = account, deck = Nothing } |> celebrating runAnswers |> read tierRead
    in
    describe "the motion is the CSS's; the page says when"
        [ test "held on its first frame until the card is on the screen" <|
            \_ ->
                rendered drawn
                    |> card
                    |> Expect.all
                        [ Query.hasNot [ class "is-playing" ]
                        , Query.has [ dataAttr "data-settled" "false" ]
                        ]
        , test "on the screen it plays, and settles when its last keyframe ends -- and not on any other" <|
            \_ ->
                let
                    playing =
                        step (CelebrationInView False) drawn
                in
                Expect.all
                    [ \_ -> rendered playing |> card |> Query.has [ class "is-playing", dataAttr "data-settled" "false" ]
                    , \_ -> rendered (step (CelebrationEnded "pz-cele-arc") playing) |> card |> Query.has [ dataAttr "data-settled" "false" ]
                    , \_ -> rendered (step (CelebrationEnded "pz-cele-settle") playing) |> card |> Query.has [ dataAttr "data-settled" "true" ]
                    ]
                    ()
        , test "with reduced motion the same card, settled at once: the class is the same, the CSS is what differs" <|
            \_ ->
                step (CelebrationInView True) drawn
                    |> rendered
                    |> card
                    |> Query.has [ class "pz-cele", class "is-playing", dataAttr "data-settled" "true" ]
        , test "the squares step 120 ms apart, and the card settles after the last" <|
            \_ ->
                drawn.celebration
                    |> Maybe.map Page.celebrationTiming
                    |> Expect.equal (Just { gridAt = 1000, step = 120, tailAt = 1320, total = 1680 })
        , test "many squares step closer together, so the sequence stays short" <|
            \_ ->
                (answered { session = account, deck = Nothing }
                    |> celebrating (List.map (\n -> ( "q" ++ String.fromInt n, did Pass 0 1 False )) (List.range 1 25))
                ).celebration
                    |> Maybe.map (Page.celebrationTiming >> .step)
                    |> Expect.equal (Just 30)
        ]
