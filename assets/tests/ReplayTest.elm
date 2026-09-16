module ReplayTest exposing (suite)

{-| The replay page on real answers: the record and the analysis of seed
room 000011 (a match to 3, three games), as the server sent them.

What is held here: the decoders read the engine's review as the server
reshapes it; the board at every step is the record's (a turn's dice and
landings, a double's cube on offer); a proposed move is the engine's
position; stepping, game switching, the keyboard and swipes move where they
should and never past a game's ends; and the analysis arriving -- pending,
then done, or a new answer replacing the last -- fills in without moving
the viewer. The page asks again only while something is pending.

-}

import Dict
import Expect
import Html.Attributes
import Games.Backgammon.Replay as Replay exposing (Annotation(..), Entry(..), MoveReview(..), Status(..))
import Json.Decode as D
import Page.Replay as Page exposing (Loadable(..), Msg(..), Showing(..))
import ReplayFixtures
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Replay"
        [ decoding
        , boards
        , stepping
        , analysisArriving
        , polling
        , words
        , rendered
        ]



-- FIXTURES


record : Replay.Record
record =
    case D.decodeString Replay.recordDecoder ReplayFixtures.record of
        Ok r ->
            r

        Err err ->
            Debug.todo (D.errorToString err)


{-| The same record as the server answers a reader who holds no seat: the
board still faces a side, but it is nobody's own.
-}
shared : Replay.Record
shared =
    case D.decodeString Replay.recordDecoder (String.replace "\"seated\":true" "\"seated\":false" ReplayFixtures.record) of
        Ok r ->
            r

        Err err ->
            Debug.todo (D.errorToString err)


reviews : String -> Replay.Reviews
reviews json =
    case D.decodeString Replay.reviewsDecoder json of
        Ok r ->
            r

        Err err ->
            Debug.todo (D.errorToString err)


done : Replay.Reviews
done =
    reviews ReplayFixtures.reviewsDone


game : Int -> Replay.Game
game number =
    case Replay.findGame number record of
        Just g ->
            g

        Nothing ->
            Debug.todo "no such game"


session =
    { csrf = "", guestName = Nothing, prefs = Dict.empty }


{-| The page with the record in, on game `wanted`.
-}
loaded : Maybe Int -> Page.Model
loaded wanted =
    Page.init session { slug = "backgammon", gameId = "000011", game = wanted }
        |> Tuple.first
        |> Page.update (GotRecord (Ok record))
        |> Tuple.first


run : List Msg -> Page.Model -> Page.Model
run msgs model =
    List.foldl (\msg m -> Page.update msg m |> Tuple.first) model msgs



-- DECODING


decoding : Test
decoding =
    describe "the answers decode"
        [ test "the record: every game, the seat the token opens, the start and the cube" <|
            \_ ->
                Expect.all
                    [ \r -> Expect.equal [ 1, 2, 3 ] (List.map .number r.games)
                    , \r -> Expect.equal "0bec7bb403d96f546cf96b17b2dffa9c" r.you
                    , \r -> Expect.equal True r.seated
                    , \r -> Expect.equal False shared.seated
                    , \r -> Expect.equal True r.cube
                    , \r -> Expect.equal 3 r.target
                    , \r -> Expect.equal [ 0, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 ] r.start.white.points
                    ]
                    record
        , test "the engine's review: every game's status and the turns it graded" <|
            \_ ->
                Expect.equal
                    [ ( 1, Done ), ( 2, Done ), ( 3, Done ) ]
                    (done |> Dict.toList |> List.map (\( n, g ) -> ( n, g.status )))
        , test "a turn's grade, its best move and what the played one lost" <|
            \_ ->
                case done |> Replay.gameReview 3 |> Maybe.andThen .review |> Maybe.andThen (\r -> Replay.moveAt r 0) of
                    Just ( _, Moved m ) ->
                        Expect.all
                            [ \_ -> Expect.equal "bad" m.grade
                            , \_ -> Expect.equal "24/14" m.best.notation
                            , \_ -> Expect.equal True (m.equityLost > 0.08)
                            , \_ -> Expect.equal True m.played.played
                            , \_ -> Expect.notEqual Nothing m.best.position
                            , \_ -> Expect.equal [ 11 ] m.best.landed
                            ]
                            ()

                    other ->
                        Expect.fail ("no graded move on game 3's first line: " ++ Debug.toString other)
        , test "a double and its pass are judged on their own lines" <|
            \_ ->
                case done |> Replay.gameReview 1 |> Maybe.andThen .review of
                    Just r ->
                        Expect.all
                            [ \_ ->
                                case Replay.annotationsAt r 1 of
                                    [ DoubleNote _ cube ] ->
                                        Expect.equal ( Just "wrong_double", "very_bad" ) ( cube.doubler.mistake, cube.doubler.grade )

                                    other ->
                                        Expect.fail (Debug.toString other)
                            , \_ ->
                                case Replay.annotationsAt r 2 of
                                    [ AnswerNote _ _ verdict ] ->
                                        Expect.equal (Just "wrong_pass") verdict.mistake

                                    other ->
                                        Expect.fail (Debug.toString other)
                            ]
                            ()

                    Nothing ->
                        Expect.fail "game 1 has no review"
        , test "each player's PR, errors and luck" <|
            \_ ->
                case done |> Replay.gameReview 3 |> Maybe.andThen .review of
                    Just r ->
                        Expect.equal 2 (List.length (List.filter (\t -> t.pr > 0) r.players))

                    Nothing ->
                        Expect.fail "no review"
        , test "the depth the engine searched at" <|
            \_ ->
                done
                    |> Replay.gameReview 3
                    |> Maybe.andThen .review
                    |> Maybe.andThen .levels
                    |> Expect.equal (Just { moves = "2ply", cube = "3ply" })
        , test "a review that does not read is no review, not a broken page" <|
            \_ ->
                D.decodeString Replay.reviewsDecoder """{"ok":true,"games":[{"game_number":1,"status":"done","turns":3,"review":{"nonsense":1}}]}"""
                    |> Result.map (Dict.get 1 >> Maybe.map (\g -> ( g.status, g.review )))
                    |> Expect.equal (Ok (Just ( Done, Nothing )))
        ]



-- THE BOARD AT EACH STEP


boards : Test
boards =
    describe "the board at each step is the record's"
        [ test "step 0 is the start: no dice, nothing landed" <|
            \_ ->
                Replay.stillAt record (game 3) 0
                    |> (\s -> ( s.position == record.start, s.dice, s.landed ))
                    |> Expect.equal ( True, [], [] )
        , test "a turn's step is the board it left, with its dice and landings" <|
            \_ ->
                case List.head (game 3).entries of
                    Just (TurnEntry t) ->
                        Replay.stillAt record (game 3) 1
                            |> (\s -> ( s.position == t.position, s.dice, ( s.landed, s.mover ) ))
                            |> Expect.equal ( True, t.dice, ( t.landed, Just t.player ) )

                    _ ->
                        Expect.fail "game 3 opens with a turn"
        , test "a double puts the cube on offer on the board the turn before left" <|
            \_ ->
                let
                    s =
                        Replay.stillAt record (game 1) 2

                    before =
                        Replay.stillAt record (game 1) 1
                in
                Expect.equal
                    ( Just 2, True, [] )
                    ( Maybe.map .value s.offer, s.position == before.position, s.dice )
        , test "a take turns the cube to the taker at the doubled value" <|
            \_ ->
                let
                    g =
                        { number = 9, entries = [ DoubleEntry { player = "a", value = 2 }, TakeEntry "b" ] }
                in
                Replay.stillAt record g 2
                    |> .position
                    |> .cube
                    |> Expect.equal { value = 2, owner = Just "b" }
        , test "a proposed move is the engine's position, the turn's dice, its landings" <|
            \_ ->
                case done |> Replay.gameReview 3 |> Maybe.andThen .review |> Maybe.andThen (\r -> Replay.moveAt r 0) of
                    Just ( _, Moved m ) ->
                        let
                            still =
                                Replay.stillAt record (game 3) 1
                        in
                        case Replay.stillForCandidate still m.best of
                            Just shown ->
                                Expect.all
                                    [ \_ -> Expect.equal still.dice shown.dice
                                    , \_ -> Expect.equal [ 11 ] shown.landed
                                    , \_ -> Expect.notEqual still.position.black shown.position.black
                                    , \_ -> Expect.equal still.position.cube shown.position.cube
                                    ]
                                    ()

                            Nothing ->
                                Expect.fail "the best move has no position"

                    _ ->
                        Expect.fail "no graded move"
        , test "the played candidate's position is the record's own" <|
            \_ ->
                case done |> Replay.gameReview 3 |> Maybe.andThen .review |> Maybe.andThen (\r -> Replay.moveAt r 0) of
                    Just ( _, Moved m ) ->
                        Replay.stillForCandidate (Replay.stillAt record (game 3) 1) m.played
                            |> Maybe.map (\s -> s.position == (Replay.stillAt record (game 3) 1).position)
                            |> Expect.equal (Just True)

                    _ ->
                        Expect.fail "no graded move"
        ]



-- STEPPING


stepping : Test
stepping =
    describe "stepping"
        [ test "the replay opens on the game the link names, at the start" <|
            \_ -> loaded (Just 2) |> (\m -> ( m.game, m.step )) |> Expect.equal ( 2, 0 )
        , test "with no game named it opens the last finished game (the fixture cuts game 3 short)" <|
            \_ -> loaded Nothing |> .game |> Expect.equal 2
        , test "a game the room does not have is ignored" <|
            \_ -> loaded (Just 9) |> .game |> Expect.equal 2
        , test "next and previous move one line; never before the start" <|
            \_ ->
                loaded (Just 3)
                    |> run [ Next, Next, Next, Prev, Prev, Prev, Prev ]
                    |> .step
                    |> Expect.equal 0
        , test "last is the game's last line, and next stops there" <|
            \_ ->
                loaded (Just 1)
                    |> run [ Last, Next, Next ]
                    |> .step
                    |> Expect.equal (Replay.lastStep (game 1))
        , test "first goes back to the start" <|
            \_ -> loaded (Just 3) |> run [ Next, Next, First ] |> .step |> Expect.equal 0
        , test "a line of the list jumps to it, within the game" <|
            \_ ->
                loaded (Just 1)
                    |> run [ GoTo 3, GoTo 400 ]
                    |> .step
                    |> Expect.equal (Replay.lastStep (game 1))
        , test "the arrow keys step; Home and End go to the ends; other keys do nothing" <|
            \_ ->
                let
                    key k =
                        D.decodeString Page.keyDecoder ("{\"key\":\"" ++ k ++ "\"}")
                in
                Expect.equal
                    [ Ok Next, Ok Prev, Ok First, Ok Last, Err () ]
                    (List.map (key >> Result.mapError (always ())) [ "ArrowRight", "ArrowLeft", "Home", "End", "a" ])
        , test "picking another game starts it from the beginning, the played move on the board" <|
            \_ ->
                loaded (Just 3)
                    |> run [ Next, Next, Show (Proposed 1), PickGame 2 ]
                    |> (\m -> ( m.game, m.step, m.showing ))
                    |> Expect.equal ( 2, 0, Played )
        , test "picking the game already shown keeps the place" <|
            \_ ->
                loaded (Just 3) |> run [ Next, Next, PickGame 3 ] |> .step |> Expect.equal 2
        , test "stepping puts the played move back on the board" <|
            \_ ->
                loaded (Just 3) |> run [ Next, Show (Proposed 1), Next ] |> .showing |> Expect.equal Played
        , test "a sideways swipe steps: left is forward, right is back" <|
            \_ ->
                loaded (Just 3)
                    |> run
                        [ TouchStarted ( 300, 400 ), TouchEnded ( 200, 410 )
                        , TouchStarted ( 300, 400 ), TouchEnded ( 200, 410 )
                        , TouchStarted ( 200, 400 ), TouchEnded ( 300, 400 )
                        ]
                    |> .step
                    |> Expect.equal 1
        , test "a short or mostly upright touch is not a step" <|
            \_ ->
                loaded (Just 3)
                    |> run [ TouchStarted ( 300, 400 ), TouchEnded ( 280, 400 ), TouchStarted ( 300, 400 ), TouchEnded ( 240, 250 ) ]
                    |> .step
                    |> Expect.equal 0
        ]



-- THE ANALYSIS ARRIVING


analysisArriving : Test
analysisArriving =
    describe "the analysis fills in where the viewer is"
        [ test "pending, then done: the game, the step and the move shown stay" <|
            \_ ->
                loaded (Just 3)
                    |> run
                        [ GotReviews (Ok (reviews ReplayFixtures.reviewsPending))
                        , Next
                        , Next
                        , Next
                        , GotReviews (Ok done)
                        ]
                    |> (\m -> ( ( m.game, m.step, m.showing ), m.reviews |> Maybe.andThen (Replay.gameReview 3) |> Maybe.map .status ))
                    |> Expect.equal ( ( 3, 3, Played ), Just Done )
        , test "a new answer for a game already shown keeps a proposed move on the board" <|
            \_ ->
                loaded (Just 3)
                    |> run
                        [ GotReviews (Ok done)
                        , Next
                        , Show (Proposed 1)
                        , GotReviews (Ok done)
                        ]
                    |> (\m -> ( m.step, m.showing ))
                    |> Expect.equal ( 1, Proposed 1 )
        , test "the record arriving after the analysis changes nothing about it" <|
            \_ ->
                Page.init session { slug = "backgammon", gameId = "000011", game = Just 3 }
                    |> Tuple.first
                    |> run [ GotReviews (Ok done), GotRecord (Ok record) ]
                    |> (\m -> ( m.reviews /= Nothing, m.game ))
                    |> Expect.equal ( True, 3 )
        , test "a replay with no game named still opens, on the first seat" <|
            \_ ->
                Page.init session { slug = "backgammon", gameId = "000011", game = Nothing }
                    |> Tuple.first
                    |> run [ GotRecord (Ok record) ]
                    |> .record
                    |> (\r ->
                            case r of
                                Loaded _ ->
                                    True

                                _ ->
                                    False
                       )
                    |> Expect.equal True
        ]



-- POLLING


polling : Test
polling =
    describe "the page asks again only while something is pending"
        [ test "not before the first answer" <|
            \_ -> loaded (Just 3) |> Page.polling |> Expect.equal False
        , test "while a game is pending" <|
            \_ -> loaded (Just 3) |> run [ GotReviews (Ok (reviews ReplayFixtures.reviewsPending)) ] |> Page.polling |> Expect.equal True
        , test "not once everything is done" <|
            \_ ->
                loaded (Just 3)
                    |> run [ GotReviews (Ok (reviews ReplayFixtures.reviewsPending)), Poll, GotReviews (Ok done) ]
                    |> Page.polling
                    |> Expect.equal False
        , test "not for a game that failed (it waits for TRY AGAIN)" <|
            \_ -> loaded (Just 3) |> run [ GotReviews (Ok (reviews ReplayFixtures.reviewsFailed)) ] |> Page.polling |> Expect.equal False
        , test "and never forever" <|
            \_ ->
                loaded (Just 3)
                    |> run (GotReviews (Ok (reviews ReplayFixtures.reviewsPending)) :: List.repeat 400 Poll)
                    |> Page.polling
                    |> Expect.equal False
        ]



-- WORDS AND NUMBERS


words : Test
words =
    describe "numbers for humans"
        [ test "equity to three decimals" <|
            \_ -> Expect.equal [ "0.046", "0.000", "1.284", "-0.081" ] (List.map Replay.formatEquity [ 0.0456, 0, 1.28361, -0.08104 ])
        , test "PR to one decimal" <|
            \_ -> Expect.equal [ "8.4", "12.1", "0.0" ] (List.map Replay.formatPr [ 8.43, 12.07, 0 ])
        , test "luck signed" <|
            \_ -> Expect.equal [ "+0.412", "−0.021", "0.000" ] (List.map Replay.formatLuck [ 0.4121, -0.0214, 0 ])
        , test "the depth as a player reads it" <|
            \_ ->
                Expect.equal
                    [ "4-ply", "moves 2-ply, cube 3-ply" ]
                    [ Replay.levelLabel { moves = "4ply", cube = "4ply" }, Replay.levelLabel { moves = "2ply", cube = "3ply" } ]
        ]



-- RENDERED


rendered : Test
rendered =
    describe "what the page shows"
        [ test "a pending game says it is being analysed, and that it takes a while" <|
            \_ ->
                loaded (Just 3)
                    |> run [ GotReviews (Ok (reviews ReplayFixtures.reviewsPending)) ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "rp-analysis-state" ]
                    |> Query.has [ Selector.containing [ Selector.text "Analysing game 3 at 4-ply… this can take a few minutes" ] ]
        , test "a graded turn shows its grade and the best move with what was lost" <|
            \_ ->
                loaded (Just 3)
                    |> run [ GotReviews (Ok done), Next ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "rp-note" ]
                    |> Query.has [ Selector.text "Bad", Selector.text "24/14" ]
        , test "no bar tells a reader which seat is theirs: the bars carry a name, a dot and a PR and nothing else" <|
            \_ ->
                Expect.all
                    [ \m -> m |> Page.view |> Query.fromHtml |> Query.hasNot [ Selector.text "YOU" ]
                    , \m -> m |> run [ Flipped ] |> Page.view |> Query.fromHtml |> Query.hasNot [ Selector.text "YOU" ]
                    ]
                    (loaded (Just 3))
        , test "a replayed position is nobody's connection, so no bar wears a presence dot" <|
            \_ ->
                loaded (Just 3)
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "bar-dot" ]
                    |> Query.count (Expect.equal 0)
        , test "the board turns around: the flip control names whose side is at the bottom" <|
            \_ ->
                loaded (Just 3)
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "rp-flip" ]
                    |> Query.has [ Selector.attribute (Html.Attributes.title "Turn the board around (P1 at the bottom)") ]
        , test "flipping puts the other player at the bottom" <|
            \_ ->
                loaded (Just 3)
                    |> run [ Flipped ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "rp-flip" ]
                    |> Query.has [ Selector.attribute (Html.Attributes.title "Turn the board around (P2 at the bottom)") ]
        , test "a stranger is not told an analysis is running that nobody started" <|
            \_ ->
                Page.init session { slug = "backgammon", gameId = "000011", game = Just 3 }
                    |> Tuple.first
                    |> run [ GotRecord (Ok shared), GotReviews (Ok (reviews ReplayFixtures.reviewsPending)) ]
                    |> Expect.all
                        [ \m -> m |> Page.view |> Query.fromHtml |> Query.find [ Selector.id "rp-analysis-state" ] |> Query.has [ Selector.text "has not been analysed yet" ]

                        -- and does not sit there asking again for work that
                        -- was never queued
                        , \m -> m |> Page.polling |> Expect.equal False
                        ]
        , test "a failed game offers to try again" <|
            \_ ->
                loaded (Just 3)
                    |> run [ GotReviews (Ok (reviews ReplayFixtures.reviewsFailed)) ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.id "rp-retry" ]
        , test "the summary says how deep the engine looked" <|
            \_ ->
                loaded (Just 3)
                    |> run [ GotReviews (Ok done), PickTab Page.SummaryTab ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.id "rp-level" ]
                    |> Query.has [ Selector.text "Analysed at moves 2-ply, cube 3-ply" ]
        , test "the move list marks the current line" <|
            \_ ->
                loaded (Just 3)
                    |> run [ Next, Next ]
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "rp-line", Selector.class "is-on" ]
                    |> Query.has [ Selector.id "rp-line-2" ]
        , test "every game of the match can be picked" <|
            \_ ->
                loaded (Just 3)
                    |> Page.view
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "rp-game" ]
                    |> Query.count (Expect.equal 3)
        ]
