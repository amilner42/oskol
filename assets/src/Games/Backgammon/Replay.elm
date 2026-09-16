module Games.Backgammon.Replay exposing
    ( Annotation(..)
    , Candidate
    , CubeReview
    , Entry(..)
    , Game
    , GameAnalysis
    , GameReview
    , Index
    , IndexEntry
    , MoveReview(..)
    , Player
    , Record
    , Review
    , Status(..)
    , Still
    , Totals
    , TurnReview
    , Verdict
    , annotationsAt
    , entryAt
    , findGame
    , formatEquity
    , formatLuck
    , formatPr
    , analysisDecoder
    , gameReview
    , indexDecoder
    , indexEntry
    , gradeLabel
    , levelLabel
    , lastStep
    , mistakeLabel
    , moveAt
    , playerNamed
    , recordDecoder
    , stepCount
    , stillAt
    , stillForCandidate
    , wantsPolling
    )

{-| A room's games as the replay page reads them: the whole record (every
game of the match, every line of each, the position after every turn) and
the engine's analysis of the game being read, with the lines each verdict
is about.

The analysis comes in two pieces. The index (`/reviews`) is one line per
game -- its status and its turn count -- and is what the page polls while
something is still being worked on. The analysis itself (`/reviews/<n>`)
is a couple of hundred kilobytes, so it is asked for one game at a time,
the one the reader is looking at, and kept for the session.

Everything here is reading. The positions are the engine's snapshots; the
grades, the best moves and the positions they leave, the cube verdicts and
the luck are the analysis engine's, reshaped by the server
(`oskol/reviews/report`), which also names the record line each verdict
belongs to. Nothing is worked out from the rules.

A game is stepped through its record lines: step 0 is the position before
anyone moved, and step `n` is the board after the game's `n`th line. A turn
shows its dice and the checkers it landed; a double shows the cube on
offer; a take shows it turned.

-}

import Dict exposing (Dict)
import Games.Backgammon.View as View exposing (Side, Snapshot)
import Json.Decode as D exposing (Decoder)



-- THE RECORD


type alias Record =
    { you : String -- the seat the board faces to begin with
    , seated : Bool -- that seat is the reader's own, not just where the board starts
    , players : List Player
    , target : Int -- the match length; 0 for unlimited play, 1 for a single game
    , cube : Bool -- the match is played with the doubling cube
    , start : Snapshot -- the position every game starts from
    , games : List Game
    }


type alias Player =
    { id : String, name : String, color : String }


type alias Game =
    { number : Int, entries : List Entry }


type Entry
    = TurnEntry View.Turn
    | DoubleEntry { player : String, value : Int }
    | TakeEntry String
    | DropEntry String
    | ResignEntry String
    | ResultEntry { number : Int, winner : String, result : String, points : Int, scores : List ( String, Int ) }


recordDecoder : Decoder Record
recordDecoder =
    D.map3 (\you seated r -> r you seated)
        (D.field "you" D.string)
        (D.oneOf [ D.field "seated" D.bool, D.succeed False ])
        (D.field "record"
            (D.map5 (\players target cube start games you seated -> Record you seated players target cube start games)
                (D.field "players" (D.list playerDecoder))
                (D.field "target" D.int)
                (D.oneOf [ D.field "cube" D.bool, D.succeed True ])
                (D.field "start" View.snapshotDecoder)
                (D.field "games" (D.list gameDecoder))
            )
        )


playerDecoder : Decoder Player
playerDecoder =
    D.map3 Player
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "color" D.string)


gameDecoder : Decoder Game
gameDecoder =
    D.map2 Game
        (D.field "number" D.int)
        (D.field "entries" (D.list entryDecoder |> D.map (List.filterMap identity)))


{-| One line of the record. A kind this client does not know is skipped
rather than failing the game.
-}
entryDecoder : Decoder (Maybe Entry)
entryDecoder =
    let
        player =
            D.field "player" D.string
    in
    D.field "kind" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "turn" ->
                        D.map6 (\p d k m pos l -> Just (TurnEntry (View.Turn p d k m pos l)))
                            player
                            (D.field "dice" (D.list D.int))
                            (D.field "picked" D.bool)
                            (D.field "moves" (D.list D.string))
                            (D.field "position" View.snapshotDecoder)
                            (D.oneOf [ D.field "landed" (D.list D.int), D.succeed [] ])

                    "double" ->
                        D.map2 (\p v -> Just (DoubleEntry { player = p, value = v })) player (D.field "value" D.int)

                    "take" ->
                        D.map (Just << TakeEntry) player

                    "drop" ->
                        D.map (Just << DropEntry) player

                    "resign" ->
                        D.map (Just << ResignEntry) player

                    "game_over" ->
                        D.map5
                            (\n w r pts sc ->
                                Just (ResultEntry { number = n, winner = w, result = r, points = pts, scores = sc })
                            )
                            (D.field "number" D.int)
                            (D.field "winner" D.string)
                            (D.field "result" D.string)
                            (D.field "points" D.int)
                            (D.field "scores" (D.keyValuePairs D.int))

                    _ ->
                        D.succeed Nothing
            )


findGame : Int -> Record -> Maybe Game
findGame number record =
    record.games |> List.filter (\g -> g.number == number) |> List.head


playerNamed : Record -> String -> String
playerNamed record id =
    record.players
        |> List.filter (\p -> p.id == id)
        |> List.head
        |> Maybe.map .name
        |> Maybe.withDefault "?"



-- STEPS


{-| Steps in a game: the start, then one per line of its record.
-}
stepCount : Game -> Int
stepCount game =
    List.length game.entries + 1


lastStep : Game -> Int
lastStep game =
    stepCount game - 1


{-| The line a step shows the board after: step `n` is line `n - 1`.
-}
entryAt : Game -> Int -> Maybe Entry
entryAt game step =
    if step <= 0 then
        Nothing

    else
        game.entries |> List.drop (step - 1) |> List.head


{-| What the board shows at one step: the position, the roll on it (a turn's
own dice, on the mover's side), whose turn it was, the checkers that landed
(and whose they are), and the cube -- on offer after a double, turned
after a take.
-}
type alias Still =
    { position : Snapshot
    , mover : Maybe String
    , dice : List Int
    , picked : Bool
    , landed : List Int
    , offer : Maybe { from : String, value : Int }
    }


stillAt : Record -> Game -> Int -> Still
stillAt record game step =
    let
        upTo =
            List.take (max 0 step) game.entries

        -- the board the last turn up to here left, or the start
        position =
            upTo
                |> List.filterMap
                    (\e ->
                        case e of
                            TurnEntry t ->
                                Just t.position

                            _ ->
                                Nothing
                    )
                |> List.reverse
                |> List.head
                |> Maybe.withDefault record.start

        plain =
            { position = position, mover = Nothing, dice = [], picked = False, landed = [], offer = Nothing }

        cube =
            position.cube
    in
    case entryAt game step of
        Just (TurnEntry t) ->
            { plain | mover = Just t.player, dice = t.dice, picked = t.picked, landed = t.landed }

        Just (DoubleEntry d) ->
            { plain | offer = Just { from = d.player, value = d.value } }

        Just (TakeEntry taker) ->
            -- The double just before it is what the take accepted: the cube
            -- at that value, the taker's.
            case upTo |> List.reverse |> List.drop 1 |> List.head of
                Just (DoubleEntry d) ->
                    { plain | position = { position | cube = { cube | value = d.value, owner = Just taker } } }

                _ ->
                    plain

        Just (DropEntry _) ->
            case upTo |> List.reverse |> List.drop 1 |> List.head of
                Just (DoubleEntry d) ->
                    { plain | offer = Just { from = d.player, value = d.value } }

                _ ->
                    plain

        _ ->
            plain


{-| The board a candidate move leaves, drawn the way a played turn is: the
turn's dice, the candidate's landings, the cube as the turn left it.
-}
stillForCandidate : Still -> Candidate -> Maybe Still
stillForCandidate still candidate =
    candidate.position
        |> Maybe.map
            (\sides ->
                { still
                    | position = { white = sides.white, black = sides.black, cube = still.position.cube }
                    , landed = candidate.landed
                }
            )



-- THE REVIEWS


{-| The index: one line per game of the match, with no analysis in it. It
is a few hundred bytes, and it is what the page polls.
-}
type alias Index =
    Dict Int IndexEntry


type alias IndexEntry =
    { status : Status
    , turns : Int -- how many turns the engine is (or will be) asked about
    }


{-| The answer to `/reviews/<n>`: one game's analysis, the only one the
reader is looking at. It is the big one (a couple of hundred kilobytes),
so it is asked for a game at a time and kept for the session.
-}
type alias GameAnalysis =
    { number : Int
    , status : Status
    , turns : Int
    , review : Maybe Review
    }


type Status
    = Pending
    | Done
    | Failed
    | Empty -- the game ended before a turn was completed: nothing to grade
    | Playing -- not over yet
    | Unknown


{-| Where one game stands as the page shows it: its line of the index, and
the analysis itself if that game's has been fetched.
-}
type alias GameReview =
    { status : Status
    , turns : Int
    , review : Maybe Review
    }


type alias Review =
    { players : List Totals
    , turns : List TurnReview
    , levels : Maybe { moves : String, cube : String } -- the engine's search depth, "4ply"
    }


type alias Totals =
    { seat : Int
    , playerId : String
    , name : String
    , color : String
    , pr : Float
    , error : Float
    , luck : Float
    , moveDecisions : Int
    , grades : List ( String, Int )
    , cubeDecisions : Int
    , mistakes : List ( String, Int )
    }


type alias TurnReview =
    { number : Int
    , player : String
    , color : String
    , dice : Maybe ( Int, Int )
    , entry : Maybe Int
    , doubleEntry : Maybe Int
    , answerEntry : Maybe Int
    , move : Maybe MoveReview
    , cube : Maybe CubeReview
    , luck : Maybe Float
    }


type MoveReview
    = Danced
    | Moved
        { grade : String
        , equityLost : Float
        , forced : Bool
        , played : Candidate
        , best : Candidate
        , top : List Candidate
        }


type alias Candidate =
    { rank : Int
    , notation : String
    , equity : Float
    , equityLost : Float
    , played : Bool
    , position : Maybe { white : Side, black : Side }
    , landed : List Int
    }


type alias CubeReview =
    { action : String
    , response : Maybe String
    , optimal : String -- the engine's call, in words: "No Double", "Double/Take"
    , noDouble : Float
    , doubleTake : Float
    , doublePass : Float
    , doubler : Verdict
    , taker : Maybe Verdict
    }


type alias Verdict =
    { seat : Int, grade : String, equityLost : Float, mistake : Maybe String }


indexDecoder : Decoder Index
indexDecoder =
    D.field "games"
        (D.list
            (D.map2 Tuple.pair
                (D.field "game_number" D.int)
                indexEntryDecoder
            )
        )
        |> D.map Dict.fromList


indexEntryDecoder : Decoder IndexEntry
indexEntryDecoder =
    D.map2 IndexEntry
        (D.field "status" D.string |> D.map statusOf)
        (D.oneOf [ D.field "turns" D.int, D.succeed 0 ])


{-| One game's analysis. A review that does not read is shown as no review,
never as a broken page: the replay works without it.
-}
analysisDecoder : Decoder GameAnalysis
analysisDecoder =
    D.map4 GameAnalysis
        (D.field "game_number" D.int)
        (D.field "status" D.string |> D.map statusOf)
        (D.oneOf [ D.field "turns" D.int, D.succeed 0 ])
        (D.oneOf [ D.field "review" (D.nullable reviewDecoder), D.succeed Nothing ])


statusOf : String -> Status
statusOf s =
    case s of
        "pending" ->
            Pending

        "done" ->
            Done

        "failed" ->
            Failed

        "empty" ->
            Empty

        "playing" ->
            Playing

        _ ->
            Unknown


reviewDecoder : Decoder Review
reviewDecoder =
    D.map3 Review
        (D.field "players" (D.list totalsDecoder))
        (D.field "turns" (D.list turnReviewDecoder))
        (D.oneOf
            [ D.field "levels"
                (D.nullable
                    (D.map2 (\m c -> { moves = m, cube = c })
                        (D.field "moves" D.string)
                        (D.field "cube" D.string)
                    )
                )
            , D.succeed Nothing
            ]
        )


totalsDecoder : Decoder Totals
totalsDecoder =
    D.succeed Totals
        |> field "seat" D.int
        |> field "player_id" D.string
        |> field "name" D.string
        |> field "color" D.string
        |> field "pr" D.float
        |> field "error" D.float
        |> field "luck" D.float
        |> andMap (D.at [ "moves", "decisions" ] D.int)
        |> andMap (D.at [ "moves", "grades" ] (D.keyValuePairs D.int))
        |> andMap (D.at [ "cube", "decisions" ] D.int)
        |> andMap (D.at [ "cube", "mistakes" ] (D.keyValuePairs D.int))


turnReviewDecoder : Decoder TurnReview
turnReviewDecoder =
    D.succeed TurnReview
        |> field "number" D.int
        |> field "player_id" D.string
        |> field "color" D.string
        |> andMap
            (D.field "dice"
                (D.nullable (D.list D.int)
                    |> D.map
                        (\d ->
                            case d of
                                Just [ a, b ] ->
                                    Just ( a, b )

                                _ ->
                                    Nothing
                        )
                )
            )
        |> andMap (optionalInt "entry")
        |> andMap (optionalInt "double_entry")
        |> andMap (optionalInt "answer_entry")
        |> andMap (D.oneOf [ D.field "move" (D.nullable moveDecoder), D.succeed Nothing ])
        |> andMap (D.oneOf [ D.field "cube" (D.nullable cubeDecoder), D.succeed Nothing ])
        |> andMap (D.oneOf [ D.field "luck" (D.nullable D.float), D.succeed Nothing ])


optionalInt : String -> Decoder (Maybe Int)
optionalInt name =
    D.oneOf [ D.field name (D.nullable D.int), D.succeed Nothing ]


moveDecoder : Decoder MoveReview
moveDecoder =
    D.oneOf [ D.field "danced" D.bool, D.succeed False ]
        |> D.andThen
            (\danced ->
                if danced then
                    D.succeed Danced

                else
                    D.map6 (\g e f p b t -> Moved { grade = g, equityLost = e, forced = f, played = p, best = b, top = t })
                        (D.field "grade" D.string)
                        (D.field "equity_lost" D.float)
                        (D.field "forced" D.bool)
                        (D.field "played" candidateDecoder)
                        (D.field "best" candidateDecoder)
                        (D.field "top" (D.list candidateDecoder))
            )


candidateDecoder : Decoder Candidate
candidateDecoder =
    let
        sides =
            D.map2 (\w b -> { white = w, black = b })
                (D.field "white" View.sideDecoder)
                (D.field "black" View.sideDecoder)
    in
    D.succeed Candidate
        |> field "rank" D.int
        |> field "notation" D.string
        |> field "equity" D.float
        |> field "equity_lost" D.float
        |> andMap (D.oneOf [ D.field "played" D.bool, D.succeed False ])
        |> andMap (D.oneOf [ D.field "position" (D.nullable sides), D.succeed Nothing ])
        |> andMap (D.oneOf [ D.field "landed" (D.nullable (D.list D.int)) |> D.map (Maybe.withDefault []), D.succeed [] ])


cubeDecoder : Decoder CubeReview
cubeDecoder =
    D.succeed CubeReview
        |> field "action" D.string
        |> andMap (D.oneOf [ D.field "response" (D.nullable D.string), D.succeed Nothing ])
        |> field "optimal" D.string
        |> andMap (D.at [ "equities", "no_double" ] D.float)
        |> andMap (D.at [ "equities", "double_take" ] D.float)
        |> andMap (D.at [ "equities", "double_pass" ] D.float)
        |> field "doubler" verdictDecoder
        |> andMap (D.oneOf [ D.field "taker" (D.nullable verdictDecoder), D.succeed Nothing ])


verdictDecoder : Decoder Verdict
verdictDecoder =
    D.map4 Verdict
        (D.field "seat" D.int)
        (D.field "grade" D.string)
        (D.field "equity_lost" D.float)
        (D.oneOf [ D.field "mistake" (D.nullable D.string), D.succeed Nothing ])


field : String -> Decoder a -> Decoder (a -> b) -> Decoder b
field name decoder =
    andMap (D.field name decoder)


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    D.map2 (|>)


indexEntry : Int -> Index -> Maybe IndexEntry
indexEntry number index =
    Dict.get number index


{-| One game as the page shows it: its line of the index, with the analysis
of that game if it has been fetched.
-}
gameReview : Int -> Index -> Dict Int Review -> Maybe GameReview
gameReview number index held =
    Dict.get number index
        |> Maybe.map (\entry -> GameReview entry.status entry.turns (Dict.get number held))


{-| Whether the page should ask again: some game's analysis is still being
worked on. The index is what it asks for, and it costs a rounding error.
-}
wantsPolling : Index -> Bool
wantsPolling index =
    index |> Dict.values |> List.any (\g -> g.status == Pending)


{-| The engine's depth as a player reads it: "4ply" is "4-ply"; moves and
cube named apart only when they differ.
-}
levelLabel : { moves : String, cube : String } -> String
levelLabel levels =
    let
        words level =
            String.replace "ply" "-ply" level
    in
    if levels.moves == levels.cube then
        words levels.moves

    else
        "moves " ++ words levels.moves ++ ", cube " ++ words levels.cube



-- VERDICTS ON A LINE


{-| What the engine said about one line of the record.
-}
type Annotation
    = MoveNote TurnReview MoveReview
    | DoubleNote TurnReview CubeReview -- the doubler's decision
    | AnswerNote TurnReview CubeReview Verdict -- the taker's (take or pass)
    | NoDoubleNote TurnReview CubeReview -- a roll that could have been a double


annotationsAt : Review -> Int -> List Annotation
annotationsAt review index =
    review.turns
        |> List.concatMap
            (\t ->
                List.filterMap identity
                    [ if t.doubleEntry == Just index then
                        Maybe.map (DoubleNote t) t.cube

                      else
                        Nothing
                    , if t.answerEntry == Just index then
                        t.cube |> Maybe.andThen (\c -> Maybe.map (AnswerNote t c) c.taker)

                      else
                        Nothing
                    , if t.entry == Just index && t.doubleEntry == Nothing then
                        t.cube
                            |> Maybe.andThen
                                (\c ->
                                    if c.action == "no_double" && c.doubler.mistake /= Nothing then
                                        Just (NoDoubleNote t c)

                                    else
                                        Nothing
                                )

                      else
                        Nothing
                    , if t.entry == Just index then
                        Maybe.map (MoveNote t) t.move

                      else
                        Nothing
                    ]
            )


{-| The move grade of the turn on a line, for the move list's tags.
-}
moveAt : Review -> Int -> Maybe ( TurnReview, MoveReview )
moveAt review index =
    review.turns
        |> List.filter (\t -> t.entry == Just index)
        |> List.head
        |> Maybe.andThen (\t -> Maybe.map (Tuple.pair t) t.move)



-- WORDS AND NUMBERS


gradeLabel : String -> String
gradeLabel grade =
    case grade of
        "best" ->
            "Best"

        "ok" ->
            "OK"

        "doubtful" ->
            "Doubtful"

        "bad" ->
            "Bad"

        "very_bad" ->
            "Very bad"

        other ->
            other


mistakeLabel : String -> String
mistakeLabel mistake =
    case mistake of
        "missed_double" ->
            "Missed double"

        "wrong_double" ->
            "Wrong double"

        "wrong_take" ->
            "Wrong take"

        "wrong_pass" ->
            "Wrong pass"

        other ->
            other


{-| Equity to three decimals, always signed for a loss: `−0.045`.
-}
formatEquity : Float -> String
formatEquity x =
    fixed 3 x


formatPr : Float -> String
formatPr x =
    fixed 1 x


{-| Luck as a signed equity: `+0.215`, `−0.087`.
-}
formatLuck : Float -> String
formatLuck x =
    if x > 0 then
        "+" ++ fixed 3 x

    else if x < 0 then
        "−" ++ fixed 3 (abs x)

    else
        fixed 3 x


{-| A number to a fixed count of decimals, rounded half away from zero.
-}
fixed : Int -> Float -> String
fixed digits x =
    let
        factor =
            10 ^ digits

        n =
            round (abs x * toFloat factor)

        sign =
            if x < 0 && n /= 0 then
                "-"

            else
                ""

        fraction =
            if digits > 0 then
                "." ++ String.padLeft digits '0' (String.fromInt (modBy factor n))

            else
                ""
    in
    sign ++ String.fromInt (n // factor) ++ fraction
