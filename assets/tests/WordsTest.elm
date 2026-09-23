module WordsTest exposing (suite)

{-| The engine's verdict in words, on made-up verdicts.

`ReplayTest` renders the replay on the real record of seed room 000011
but asserts nothing about the prose. This is where the sentences are
pinned: every grade a move can have, every call the engine can make on a cube, from both sides
of it, and the too-good rule that the Gleam twin (`oskol/puzzles.too_good`)
has to agree with.

The cube's call is a type now, so the strings the engine writes are read
in exactly one place. The last group is the old substring matching turned
into a parser test: the three words the engine actually writes, and a word
from some later engine, which must fall back rather than be guessed at.

-}

import Expect
import Games.Backgammon.Replay as Replay exposing (Optimal(..))
import Games.Backgammon.Words as Words
import Html
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Words"
        [ candidateSentences
        , moveSentences
        , doublerSentences
        , responderSentences
        , tooGoodRule
        , theEnginesWords
        ]



-- FIXTURES


probs : Float -> Float -> Float -> Replay.Probs
probs win gammonWin gammonLoss =
    { win = win
    , gammonWin = gammonWin
    , backgammonWin = 0.01
    , gammonLoss = gammonLoss
    , backgammonLoss = 0.01
    }


candidate : String -> Maybe Replay.Probs -> Replay.Candidate
candidate notation p =
    { rank = 1
    , notation = notation
    , equity = 0.1
    , equityLost = 0.0
    , played = False
    , position = Nothing
    , landed = []
    , probs = p
    }


{-| A move whose best is better on all three counts.
-}
move : String -> { grade : String, played : Replay.Candidate, best : Replay.Candidate }
move grade =
    { grade = grade
    , played = candidate "24/20 6/4" (Just (probs 0.4 0.1 0.15))
    , best = candidate "8/4 6/4" (Just (probs 0.44 0.13 0.12))
    }


verdict : String -> Maybe String -> Replay.Verdict
verdict grade mistake =
    { seat = 0, grade = grade, equityLost = 0.2, mistake = mistake }


right : Replay.Verdict
right =
    verdict "ok" Nothing


{-| A cube review: the call, the three equities, the chances it was
judged on.
-}
cube : Optimal -> Float -> Float -> Float -> Replay.CubeReview
cube optimal noDouble doubleTake doublePass =
    { action = "double"
    , response = Nothing
    , optimal = optimal
    , noDouble = noDouble
    , doubleTake = doubleTake
    , doublePass = doublePass
    , probs = Just (probs 0.6 0.2 0.1)
    , doubler = right
    , taker = Nothing
    }


{-| The same, with the doubler's winning chances set.
-}
winning : Optimal -> Float -> Replay.CubeReview
winning optimal win =
    let
        c =
            cube optimal 0.4 0.5 1.0
    in
    { c | probs = Just (probs win 0.2 0.1) }


{-| The move sentence, whole. `moveInWords` renders exactly one text
node, and `contains` wants that node exactly, so a sentence that drifts
by a word fails here rather than passing on a prefix.
-}
saysMove : String -> { grade : String, played : Replay.Candidate, best : Replay.Candidate } -> Expect.Expectation
saysMove expected m =
    Words.moveInWords "P1" m
        |> Query.fromHtml
        |> Query.contains [ Html.text expected ]



-- MOVES


candidateSentences : Test
candidateSentences =
    describe "a candidate on the board"
        (let
            best =
                candidate "8/4 6/4" (Just (probs 0.44 0.13 0.12))

            says expected c =
                Words.candidateInWords c best |> Query.fromHtml |> Query.contains [ Html.text expected ]
         in
         [ test "the best move is named as such" <|
            \_ -> says "8/4 6/4 is the best move." best
         , test "a bad one is graded off what it gives up, against the best" <|
            \_ ->
                let
                    c =
                        candidate "24/20 6/4" (Just (probs 0.4 0.1 0.15))
                in
                says "24/20 6/4 is a bad move. The best move here results in 4.0% more wins, 3.0% more gammons and 3.0% fewer gammons against." { c | equityLost = 0.1 }
         , test "a dubious one without chances still has its lead" <|
            \_ ->
                let
                    c =
                        candidate "13/9 6/4" Nothing
                in
                says "13/9 6/4 is a dubious move." { c | equityLost = 0.03 }
         , test "the marks are the annotators'" <|
            \_ ->
                Expect.equal [ "✓", "", "?!", "?", "??" ]
                    (List.map (Words.gradeOf >> Words.gradeMark) [ 0, 0.01, 0.03, 0.1, 0.2 ])
         ]
        )


moveSentences : Test
moveSentences =
    describe "what a move did"
        [ test "the best move is said and left alone" <|
            \_ ->
                saysMove "P1 played the best move." (move "best")
        , test "a fine move gets a shade, not a count" <|
            \_ ->
                saysMove "P1 played a fine move. The best move here is a shade better." (move "ok")
        , test "a dubious move gets the gains" <|
            \_ ->
                saysMove
                    "P1 played a dubious move. The best move here results in 4.0% more wins, 3.0% more gammons and 3.0% fewer gammons against."
                    (move "doubtful")
        , test "a bad move" <|
            \_ ->
                saysMove
                    "P1 played a bad move. The best move here results in 4.0% more wins, 3.0% more gammons and 3.0% fewer gammons against."
                    (move "bad")
        , test "a very bad move" <|
            \_ ->
                saysMove
                    "P1 played a very bad move. The best move here results in 4.0% more wins, 3.0% more gammons and 3.0% fewer gammons against."
                    (move "very_bad")
        , test "a grade this page does not know still says something" <|
            \_ ->
                saysMove
                    "P1 played a move the engine would not. The best move here results in 4.0% more wins, 3.0% more gammons and 3.0% fewer gammons against."
                    (move "catastrophic")
        , test "gains and costs are both spoken, gains first" <|
            \_ ->
                let
                    m =
                        move "bad"
                in
                saysMove
                    "P1 played a bad move. The best move here results in 6.0% more wins, at the cost of 4.0% fewer gammons."
                    { m
                        | played = candidate "24/20 6/4" (Just (probs 0.4 0.2 0.1))
                        , best = candidate "8/4 6/4" (Just (probs 0.46 0.16 0.1))
                    }
        , test "a best move that only gives up chances comes out ahead anyway" <|
            \_ ->
                let
                    m =
                        move "bad"
                in
                saysMove
                    "P1 played a bad move. The best move here gives up 4.0% fewer wins and 2.0% more gammons against, but comes out ahead once every roll is counted."
                    { m
                        | played = candidate "24/20 6/4" (Just (probs 0.5 0.2 0.1))
                        , best = candidate "8/4 6/4" (Just (probs 0.46 0.2 0.12))
                    }
        , test "chances that differ by less than half a point are not counted out" <|
            \_ ->
                let
                    m =
                        move "bad"
                in
                saysMove
                    "P1 played a bad move. The best move here is better by the engine's count, though the chances differ by less than half a point."
                    { m
                        | played = candidate "24/20 6/4" (Just (probs 0.4 0.2 0.1))
                        , best = candidate "8/4 6/4" (Just (probs 0.402 0.2 0.1))
                    }
        , test "a report with no chances says nothing rather than guessing" <|
            \_ ->
                let
                    m =
                        move "bad"
                in
                Words.moveInWords "P1" { m | best = candidate "8/4 6/4" Nothing }
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "rp-words" ]
        ]



-- THE CUBE, FROM THE DOUBLER'S SIDE


doublerSentences : Test
doublerSentences =
    describe "the cube, as the doubler is judged"
        [ test "doubling when the engine says no double, behind" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is losing here: doubling hands P2 a cube they are glad to take."
                    (Words.doubleInWords "P1" "P2" (winning NoDouble 0.4))
        , test "doubling when the engine says no double, ahead but not enough" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is winning here, but not by enough to make the cube worth turning: P2 has an easy take, and waiting keeps the chance to double later."
                    (Words.doubleInWords "P1" "P2" (winning NoDouble 0.6))
        , test "doubling when the engine says double/pass" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is well ahead here by enough that P2 should pass."
                    (Words.doubleInWords "P1" "P2" (winning DoublePass 0.8))
        , test "doubling when the engine says double/take" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is winning here by enough to double."
                    (Words.doubleInWords "P1" "P2" (winning DoubleTake 0.6))
        , test "doubling at a score where the cube is worth turning from behind" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. At this score the cube is worth turning for P1 even at 35.0% to win."
                    (Words.doubleInWords "P1" "P2" (winning DoubleTake 0.35))
        , test "doubling when the engine's word is one we do not know falls back" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is winning here by enough to double."
                    (Words.doubleInWords "P1" "P2" (winning (OtherCall "Beaver") 0.6))
        , test "doubling when it was too good to double" <|
            \_ ->
                Expect.equal
                    "P1 doubled, a bad mistake. P1 is winning here by too much: P2 can pass for a single point, when playing on for the gammon is worth more."
                    (Words.doubleInWords "P1" "P2" (tooGoodCube (verdict "bad" (Just "wrong_double"))))
        , test "not doubling when the engine says double/pass" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. P1 is well ahead here by enough that P2 should pass: doubling would have taken the point."
                    (Words.noDoubleInWords "P1" "P2" (winning DoublePass 0.8))
        , test "not doubling while losing" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. P1 is losing here, and the cube stays where it is."
                    (Words.noDoubleInWords "P1" "P2" (winning NoDouble 0.4))
        , test "not doubling in a close game" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. The game is close here: not a double yet."
                    (Words.noDoubleInWords "P1" "P2" (winning NoDouble 0.52))
        , test "not doubling while winning, but not by enough" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. P1 is winning here, but not by enough to double yet: P2 would have an easy take, and the cube is worth more held."
                    (Words.noDoubleInWords "P1" "P2" (winning NoDouble 0.6))
        , test "not doubling when the engine says double/take is a missed double" <|
            \_ ->
                Expect.equal
                    "P1 did not double, a dubious mistake. P1 is winning here by enough to double."
                    (Words.noDoubleInWords "P1"
                        "P2"
                        (withDoubler (verdict "doubtful" (Just "missed_double")) (winning DoubleTake 0.6))
                    )
        , test "not doubling when the engine's word is one we do not know falls back" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. P1 is winning here by enough to double."
                    (Words.noDoubleInWords "P1" "P2" (winning (OtherCall "Beaver") 0.6))
        , test "not doubling when it was too good to double" <|
            \_ ->
                Expect.equal
                    "P1 correctly did not double. P1 is winning here by too much to double: better to play on for the gammon than to let P2 pass for a point."
                    (Words.noDoubleInWords "P1" "P2" (tooGoodCube right))
        , test "a very bad mistake is sized as one" <|
            \_ ->
                Expect.equal
                    "P1 doubled, a very bad mistake. P1 is losing here: doubling hands P2 a cube they are glad to take."
                    (Words.doubleInWords "P1" "P2" (withDoubler (verdict "very_bad" (Just "wrong_double")) (winning NoDouble 0.4)))
        ]


withDoubler : Replay.Verdict -> Replay.CubeReview -> Replay.CubeReview
withDoubler v c =
    { c | doubler = v }


{-| Too good: the engine says no double, and playing on is worth more
than the point a pass hands over.
-}
tooGoodCube : Replay.Verdict -> Replay.CubeReview
tooGoodCube v =
    let
        c =
            cube NoDouble 1.2 0.9 1.0
    in
    { c | probs = Just (probs 0.85 0.5 0.02), doubler = v }



-- THE CUBE, FROM THE RESPONDER'S SIDE


responderSentences : Test
responderSentences =
    describe "the cube, as the answer is judged"
        [ test "passing a double the engine says should be passed" <|
            \_ ->
                Expect.equal
                    "P2 correctly passed. P2 is losing here by too much to take: a pass gives up one point rather than risking two or more."
                    (Words.answerInWords "P2" (answered Replay.Pass (winning DoublePass 0.8)) right)
        , test "taking a double the engine says should be taken, as the favourite" <|
            \_ ->
                Expect.equal
                    "P2 correctly took. P2 is the favourite here, double or not: an easy take."
                    (Words.answerInWords "P2" (answered Replay.Take (winning DoubleTake 0.45)) right)
        , test "taking a double the engine says should be taken, from behind" <|
            \_ ->
                Expect.equal
                    "P2 correctly took. P2 is behind here but has enough to play on for double the stake."
                    (Words.answerInWords "P2" (answered Replay.Take (winning DoubleTake 0.6)) right)
        , test "taking when the engine says no double is still a take" <|
            \_ ->
                Expect.equal
                    "P2 correctly took. P2 is the favourite here, double or not: an easy take."
                    (Words.answerInWords "P2" (answered Replay.Take (winning NoDouble 0.4)) right)
        , test "taking a position that was too good to double is a mistake" <|
            \_ ->
                Expect.equal
                    "P2 took, a very bad mistake. P2 is losing here by too much to take: a pass gives up one point rather than risking two or more."
                    (Words.answerInWords "P2"
                        (answered Replay.Take (tooGoodCube right))
                        (verdict "very_bad" (Just "wrong_take"))
                    )
        , test "passing a take is sized by its grade" <|
            \_ ->
                Expect.equal
                    "P2 passed, a very bad mistake. P2 is the favourite here, double or not: an easy take."
                    (Words.answerInWords "P2"
                        (answered Replay.Pass (winning DoubleTake 0.45))
                        (verdict "very_bad" (Just "wrong_pass"))
                    )
        , test "an answer the engine's word does not cover falls back to the chances" <|
            \_ ->
                Expect.equal
                    "P2 correctly took. P2 is behind here but has enough to play on for double the stake."
                    (Words.answerInWords "P2" (answered Replay.Take (winning (OtherCall "Beaver") 0.6)) right)
        , test "no answer recorded reads as a take" <|
            \_ ->
                Expect.equal
                    "P2 correctly took. P2 is the favourite here, double or not: an easy take."
                    (Words.answerInWords "P2" (winning DoubleTake 0.45) right)
        ]


answered : Replay.Response -> Replay.CubeReview -> Replay.CubeReview
answered r c =
    { c | response = Just r }



-- THE TOO-GOOD RULE, AND THE ENGINE'S OWN WORDS


tooGoodRule : Test
tooGoodRule =
    describe "too good to double"
        [ test "no double, and playing on is worth more than a pass" <|
            \_ ->
                Expect.equal True (Words.tooGood NoDouble 1.2 1.0)
        , test "no double, and playing on is worth exactly the pass" <|
            \_ ->
                Expect.equal True (Words.tooGood NoDouble 1.0 1.0)
        , test "no double, but not worth more than a pass" <|
            \_ ->
                Expect.equal False (Words.tooGood NoDouble 0.4 1.0)
        , test "a double the engine wants is never too good, whatever the equities" <|
            \_ ->
                Expect.equal
                    [ False, False, False ]
                    [ Words.tooGood DoubleTake 1.2 1.0
                    , Words.tooGood DoublePass 1.2 1.0
                    , Words.tooGood (OtherCall "Beaver") 1.2 1.0
                    ]
        ]


theEnginesWords : Test
theEnginesWords =
    describe "the engine's word, read once"
        [ test "the three the engine writes" <|
            \_ ->
                Expect.equal
                    [ NoDouble, DoubleTake, DoublePass ]
                    (List.map Replay.optimalFromEngine [ "No Double", "Double/Take", "Double/Pass" ])
        , test "case does not matter" <|
            \_ ->
                Expect.equal
                    [ NoDouble, DoubleTake, DoublePass ]
                    (List.map Replay.optimalFromEngine [ "no double", "double/take", "double/pass" ])
        , test "too good is not a call: the engine writes no double and the equities say the rest" <|
            \_ ->
                Expect.equal
                    ( NoDouble, True )
                    ( Replay.optimalFromEngine "No Double"
                    , Words.tooGood (Replay.optimalFromEngine "No Double") 1.2 1.0
                    )
        , test "a word from a later engine is kept, not guessed at" <|
            \_ ->
                Expect.equal (OtherCall "Too Good") (Replay.optimalFromEngine "Too Good")
        , test "an unknown word still gets a sentence rather than a crash" <|
            \_ ->
                Expect.equal
                    "P1 correctly doubled. P1 is winning here by enough to double."
                    (Words.doubleInWords "P1" "P2" (winning (Replay.optimalFromEngine "Beaver") 0.6))
        , test "an unknown word marks none of the three equities" <|
            \_ ->
                Words.cubeLine (winning (Replay.optimalFromEngine "Beaver") 0.6)
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "is-pick" ]
                    |> Query.count (Expect.equal 0)
        , test "the engine's call is the one equity in ink" <|
            \_ ->
                Words.cubeLine (winning DoublePass 0.8)
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "is-pick" ]
                    |> Query.has [ Selector.text "Double, pass" ]
        , test "the answer to a double is read the same way" <|
            \_ ->
                Expect.equal
                    [ Replay.Pass, Replay.Take, Replay.Take ]
                    (List.map Replay.responseFromEngine [ "pass", "take", "beaver" ])
        ]
