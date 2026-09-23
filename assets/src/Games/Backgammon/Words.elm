module Games.Backgammon.Words exposing
    ( answerInWords
    , answerWhy
    , chanceCells
    , cubeChances
    , cubeLine
    , cubeVerdict
    , doubleInWords
    , doubleWhy
    , gradeTag
    , inWords
    , lost
    , moveInWords
    , noDoubleInWords
    , noDoubleWhy
    , properDouble
    , signed
    , spoken
    , standing
    , tooGood
    , verdictTag
    )

{-| What the analysis engine's verdict says, in words and in numbers.

The replay reads these and so does a puzzle's reveal: a move's two
sentences, the cube's, the three equities with the engine's pick in ink,
a candidate's chances as cells, and the grade tags. Everything here is
pure -- a verdict, a cube review, a name -- and knows nothing about a
page: no model, no record, no message. The pieces that need the replay's
own state (which step is open, which line the reader tapped) stay in
`Page/Replay.elm`.

The cube's call arrives as a `Replay.Optimal`, never as the engine's
prose: every sentence branches on the type, so "No Double" is read once,
in the decoder, and nowhere else.

**`tooGood` has a twin in Gleam**: `oskol/puzzles.too_good`, on the same
three inputs in the same order (the call, the no-double equity, the
double-pass equity), because a puzzle's stored answer carries the flag
and the replay works it out from the report. Change one and change the
other, or the same position will be read two ways.

-}

import Games.Backgammon.Replay as Replay exposing (Candidate, Optimal(..))
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (attribute, class, classList)


{-| A cube decision's tag. The engine grades a right decision "ok"; on
the page it is Best, as a right move is.
-}
verdictTag : Replay.Verdict -> Html msg
verdictTag verdict =
    case verdict.mistake of
        Nothing ->
            gradeTag "best"

        Just _ ->
            gradeTag verdict.grade


inWords : String -> Html msg
inWords sentence =
    if sentence == "" then
        text ""

    else
        div [ class "rp-words" ] [ text sentence ]


{-| How the doubler stands, from their winning chances alone.
-}
standing : String -> Float -> String
standing who win =
    if win < 0.45 then
        who ++ " is losing here"

    else if win < 0.55 then
        "The game is close here"

    else if win < 0.72 then
        who ++ " is winning here"

    else
        who ++ " is well ahead here"


{-| The verdict on what was done with the cube, in the shape the move's
sentence has: "correctly did not double", "doubled, a bad mistake".
-}
cubeVerdict : String -> String -> Replay.Verdict -> String
cubeVerdict who did verdict =
    case verdict.mistake of
        Nothing ->
            who ++ " correctly " ++ did ++ "."

        Just _ ->
            let
                size =
                    case verdict.grade of
                        "doubtful" ->
                            "a dubious"

                        "bad" ->
                            "a bad"

                        "very_bad" ->
                            "a very bad"

                        _ ->
                            "a small"
            in
            who ++ " " ++ did ++ ", " ++ size ++ " mistake."


{-| Too good to double: the engine says "no double" for that too, but
its equities give it away, since playing on is worth more than the point
a pass would hand over.

The twin of Gleam's `oskol/puzzles.too_good`; keep the two in step.

-}
tooGood : Optimal -> Float -> Float -> Bool
tooGood optimal noDouble doublePass =
    optimal == NoDouble && noDouble >= doublePass


{-| A double the engine agrees with. Ahead, that is the chances; behind,
it is the match score (a trailer who must win this game anyway, or a
score where the cube is worth more turned), and the sentence says so
rather than calling a 35% double "winning".
-}
properDouble : String -> Float -> String
properDouble who win =
    if win >= 0.55 then
        standing who win ++ " by enough to double."

    else
        "At this score the cube is worth turning for " ++ who ++ " even at " ++ Replay.formatPercent win ++ " to win."


{-| The engine's word on a double that was offered: the verdict, then why.
-}
doubleInWords : String -> String -> Replay.CubeReview -> String
doubleInWords who opp cube =
    cubeVerdict who "doubled" cube.doubler ++ " " ++ doubleWhy who opp cube


{-| Why, on a double that was offered (or is being asked about): the
position in the engine's terms, with nothing about what was done.
-}
doubleWhy : String -> String -> Replay.CubeReview -> String
doubleWhy who opp cube =
    let
        win =
            cube.probs |> Maybe.map .win |> Maybe.withDefault 0.5
    in
    if tooGood cube.optimal cube.noDouble cube.doublePass then
        who ++ " is winning here by too much: " ++ opp ++ " can pass for a single point, when playing on for the gammon is worth more."

    else
        case cube.optimal of
            NoDouble ->
                if win < 0.5 then
                    who ++ " is losing here: doubling hands " ++ opp ++ " a cube they are glad to take."

                else
                    standing who win ++ ", but not by enough to make the cube worth turning: " ++ opp ++ " has an easy take, and waiting keeps the chance to double later."

            DoublePass ->
                standing who win ++ " by enough that " ++ opp ++ " should pass."

            _ ->
                properDouble who win


{-| The engine's word on a cube that stayed where it was: the verdict,
then why.
-}
noDoubleInWords : String -> String -> Replay.CubeReview -> String
noDoubleInWords who opp cube =
    cubeVerdict who "did not double" cube.doubler ++ " " ++ noDoubleWhy who opp cube


{-| Why, on a cube that stayed where it was: the position in the engine's
terms, with nothing about what was done.
-}
noDoubleWhy : String -> String -> Replay.CubeReview -> String
noDoubleWhy who opp cube =
    let
        win =
            cube.probs |> Maybe.map .win |> Maybe.withDefault 0.5
    in
    if tooGood cube.optimal cube.noDouble cube.doublePass then
        who ++ " is winning here by too much to double: better to play on for the gammon than to let " ++ opp ++ " pass for a point."

    else
        case cube.optimal of
            DoublePass ->
                standing who win ++ " by enough that " ++ opp ++ " should pass: doubling would have taken the point."

            NoDouble ->
                if win < 0.5 then
                    who ++ " is losing here, and the cube stays where it is."

                else if win < 0.55 then
                    "The game is close here: not a double yet."

                else
                    standing who win ++ ", but not by enough to double yet: " ++ opp ++ " would have an easy take, and the cube is worth more held."

            _ ->
                properDouble who win


{-| The engine's word on the answer to a double, from the taker's side:
the verdict, then why.
-}
answerInWords : String -> Replay.CubeReview -> Replay.Verdict -> String
answerInWords taker cube verdict =
    let
        did =
            if cube.response == Just Replay.Pass then
                "passed"

            else
                "took"
    in
    cubeVerdict taker did verdict ++ " " ++ answerWhy taker cube


{-| Why, from the taker's side: the position in the engine's terms, with
nothing about what was done.
-}
answerWhy : String -> Replay.CubeReview -> String
answerWhy taker cube =
    let
        shouldPass =
            cube.optimal == DoublePass || tooGood cube.optimal cube.noDouble cube.doublePass

        -- the taker's own chances: the doubler's, the other way round
        win =
            cube.probs |> Maybe.map (\p -> 1 - p.win) |> Maybe.withDefault 0.5
    in
    if shouldPass then
        taker ++ " is losing here by too much to take: a pass gives up one point rather than risking two or more."

    else if win >= 0.5 then
        taker ++ " is the favourite here, double or not: an easy take."

    else
        taker ++ " is behind here but has enough to play on for double the stake."


{-| The chances a cube decision was judged on, in the move table's
columns: the doubler's wins, their gammons, the gammons against them.
-}
cubeChances : String -> Replay.CubeReview -> Html msg
cubeChances who cube =
    case cube.probs of
        Just p ->
            div [ class "rp-top rp-cube-top" ]
                [ div [ class "rp-top-head" ]
                    [ span [] []
                    , span [ class "rp-col", Html.Attributes.title "How often the doubler wins" ] [ text "win" ]
                    , span [ class "rp-col", Html.Attributes.title "How often they win a gammon" ] [ text "gam+" ]
                    , span [ class "rp-col", Html.Attributes.title "How often they get gammoned" ] [ text "gam−" ]
                    ]
                , div [ class "rp-cand rp-cube-row" ]
                    ([ span [ class "rp-cand-move" ] [ text who ] ] ++ chanceCells (Just p))
                ]

        Nothing ->
            text ""


{-| What a move did, in two sentences: what was played, by its grade, and
what the best move gives instead, on the three things a move changes: how
often you win, how often you win a gammon, how often you get gammoned.
The best move's gains come first, then what it gives up.
-}
moveInWords : String -> { a | grade : String, played : Candidate, best : Candidate } -> Html msg
moveInWords who m =
    case ( m.played.probs, m.best.probs ) of
        ( Just played, Just best ) ->
            let
                -- best less played, in points of a percent
                wins =
                    (best.win - played.win) * 100

                gammons =
                    (best.gammonWin - played.gammonWin) * 100

                gammoned =
                    (best.gammonLoss - played.gammonLoss) * 100

                amount d =
                    Replay.fixed1 (abs d) ++ "%"

                matters d =
                    abs d >= 0.5

                gains =
                    List.filterMap identity
                        [ if wins > 0 && matters wins then
                            Just (amount wins ++ " more wins")

                          else
                            Nothing
                        , if gammons > 0 && matters gammons then
                            Just (amount gammons ++ " more gammons")

                          else
                            Nothing
                        , if gammoned < 0 && matters gammoned then
                            Just (amount gammoned ++ " fewer gammons against")

                          else
                            Nothing
                        ]

                costs =
                    List.filterMap identity
                        [ if wins < 0 && matters wins then
                            Just (amount wins ++ " fewer wins")

                          else
                            Nothing
                        , if gammons < 0 && matters gammons then
                            Just (amount gammons ++ " fewer gammons")

                          else
                            Nothing
                        , if gammoned > 0 && matters gammoned then
                            Just (amount gammoned ++ " more gammons against")

                          else
                            Nothing
                        ]

                played_ =
                    case m.grade of
                        "best" ->
                            who ++ " played the best move."

                        "ok" ->
                            who ++ " played a fine move."

                        "doubtful" ->
                            who ++ " played a dubious move."

                        "bad" ->
                            who ++ " played a bad move."

                        "very_bad" ->
                            who ++ " played a very bad move."

                        _ ->
                            who ++ " played a move the engine would not."

                best_ =
                    if m.grade == "best" then
                        ""

                    else if m.grade == "ok" then
                        " The best move here is a shade better."

                    else
                        case ( gains, costs ) of
                            ( [], [] ) ->
                                " The best move here is better by the engine's count, though the chances differ by less than half a point."

                            ( _, [] ) ->
                                " The best move here results in " ++ spoken gains ++ "."

                            ( [], _ ) ->
                                " The best move here gives up " ++ spoken costs ++ ", but comes out ahead once every roll is counted."

                            _ ->
                                " The best move here results in " ++ spoken gains ++ ", at the cost of " ++ spoken costs ++ "."
            in
            div [ class "rp-words" ] [ text (played_ ++ best_) ]

        _ ->
            text ""


{-| "a", "a and b", "a, b and c".
-}
spoken : List String -> String
spoken parts =
    case List.reverse parts of
        [] ->
            ""

        [ one ] ->
            one

        last :: rest ->
            String.join ", " (List.reverse rest) ++ " and " ++ last


lost : Float -> Html msg
lost equity =
    if equity > 0 then
        span [ class "rp-lost tabular-nums" ] [ text ("−" ++ Replay.formatEquity equity) ]

    else
        text ""


{-| The engine's call on the cube: the three equities as labelled cells,
the one it picks in ink.
-}
cubeLine : Replay.CubeReview -> Html msg
cubeLine cube =
    let
        cell label value picked =
            div [ classList [ ( "rp-cube-eq", True ), ( "is-pick", picked ) ] ]
                [ span [ class "rp-cube-label" ] [ text label ]
                , span [ class "rp-cube-value tabular-nums" ] [ text (signed value) ]
                ]
    in
    div [ class "rp-cube" ]
        [ div [ class "rp-cube-eqs" ]
            [ cell "No double" cube.noDouble (cube.optimal == NoDouble)
            , cell "Double, take" cube.doubleTake (cube.optimal == DoubleTake)
            , cell "Double, pass" cube.doublePass (cube.optimal == DoublePass)
            ]
        ]


signed : Float -> String
signed x =
    if x >= 0 then
        "+" ++ Replay.formatEquity x

    else
        "−" ++ Replay.formatEquity (abs x)


{-| A candidate's chances as three cells: wins, gammons won, gammons
lost. Empty cells when the report has none.
-}
chanceCells : Maybe Replay.Probs -> List (Html msg)
chanceCells probs =
    let
        cell extra x =
            span [ class ("rp-col tabular-nums" ++ extra) ] [ text (Replay.fixed1 (x * 100)) ]
    in
    case probs of
        Just p ->
            [ cell "" p.win
            , cell "" p.gammonWin
            , cell "" p.gammonLoss
            ]

        Nothing ->
            List.repeat 3 (span [ class "rp-col" ] [])


gradeTag : String -> Html msg
gradeTag grade =
    span [ class ("rp-grade g-" ++ grade), attribute "data-grade" grade ] [ text (Replay.gradeLabel grade) ]
