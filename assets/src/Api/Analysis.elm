module Api.Analysis exposing
    ( Status(..), Answer, Reveal, Levels, Refusal
    , ask, status, statusDecoder, revealDecoder, refusalOf
    )

{-| The analysis board's two requests (analysis-ask-api): ask the engine
about a setup, and ask again how that is going.

    POST /papi/analysis       Setup.toJson
      -> 200 {status: "done", key, puzzle, reveal}   already stored: no engine time
      -> 202 {status: "pending", key}                queued, or already in flight
      -> 409 dances / 422 validation_failed / 429 rate_limited / 503 engine_down,
         each with the sentence to show; 429 and 503 with error.retry_after_s
    GET /papi/analysis/:key
      -> {status: "pending"} | {status: "done", key, puzzle, reveal}
       | {status: "failed", message}
      -> 404 when the server has forgotten the key (a restart): POST again

`puzzle` is the puzzle page's own body (`Puzzle.decoder`), so the board can
be played on at once. `reveal` is `{best, top, cube, n_legal, levels}`:
`best`, `top` and `cube` are the attempt reveal's own fields, rendered on
the server by the same function, so they are read here with the reveal's
own decoders (`Puzzle.candidateDecoder`, `Puzzle.cubeRevealDecoder`) and
drawn with its renderers.

-}

import Api
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Setup)
import Http
import Json.Decode as D
import Session exposing (Session)


type Status
    = Pending String -- the key; ask `status` again
    | Done Answer
    | Failed String -- the sentence


type alias Answer =
    { key : String, puzzle : Puzzle.Puzzle, reveal : Reveal }


{-| What the engine says about the position, with nobody's answer in it.
A move has `best` and `top` (and `cube` is Nothing); a double or a take has
`cube` (and `best` is Nothing, `top` empty).
-}
type alias Reveal =
    { best : Maybe Puzzle.Candidate
    , top : List Puzzle.Candidate
    , cube : Maybe Puzzle.CubeReveal
    , nLegal : Maybe Int -- how many ways the roll can be played; Nothing for a cube
    , levels : Maybe Levels
    }


{-| The depths the engine searched at, as it names them ("4ply").
-}
type alias Levels =
    { moves : String, cube : String }


{-| A request that did not come back with a status: the error, and for a
refusal that passes with time (429, 503) how many seconds it asks for.
-}
type alias Refusal =
    { error : Api.Error, retryAfter : Maybe Int }


ask : Session -> Setup -> (Result Refusal Status -> msg) -> Cmd msg
ask session setup toMsg =
    Api.send session "POST" "/papi/analysis" (Just (Setup.toJson setup)) (expect statusDecoder toMsg)


status : Session -> String -> (Result Refusal Status -> msg) -> Cmd msg
status session key toMsg =
    Api.send session "GET" ("/papi/analysis/" ++ key) Nothing (expect (statusDecoder |> D.map (withKey key)) toMsg)


expect : D.Decoder Status -> (Result Refusal Status -> msg) -> Http.Expect msg
expect decoder toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    Api.parseBody decoder body |> Result.mapError (\e -> { error = e, retryAfter = Nothing })

                Http.BadStatus_ _ body ->
                    Api.parseBody decoder body |> Result.mapError (refusalOf body)

                Http.NetworkError_ ->
                    Err { error = Api.NetworkError, retryAfter = Nothing }

                Http.Timeout_ ->
                    Err { error = Api.NetworkError, retryAfter = Nothing }

                Http.BadUrl_ url ->
                    Err { error = Api.DecodeError ("bad url: " ++ url), retryAfter = Nothing }


{-| An error envelope and the wait it names, if it names one.
-}
refusalOf : String -> Api.Error -> Refusal
refusalOf body error =
    { error = error
    , retryAfter =
        D.decodeString (D.at [ "error", "retry_after_s" ] D.int) body |> Result.toMaybe
    }


{-| A pending status from the poll does not repeat the key; the asker knows
it.
-}
withKey : String -> Status -> Status
withKey key s =
    case s of
        Pending "" ->
            Pending key

        _ ->
            s


statusDecoder : D.Decoder Status
statusDecoder =
    D.field "status" D.string
        |> D.andThen
            (\s ->
                case s of
                    "pending" ->
                        D.map Pending (D.oneOf [ D.field "key" D.string, D.succeed "" ])

                    "done" ->
                        D.map3 (\key puzzle reveal -> Done { key = key, puzzle = puzzle, reveal = reveal })
                            (D.field "key" D.string)
                            (D.field "puzzle" Puzzle.decoder)
                            (D.field "reveal" revealDecoder)

                    "failed" ->
                        D.map Failed (D.field "message" D.string)

                    _ ->
                        D.fail ("not an analysis status: " ++ s)
            )


revealDecoder : D.Decoder Reveal
revealDecoder =
    D.map5 Reveal
        (D.field "best" (D.nullable Puzzle.candidateDecoder))
        (D.field "top" (D.list Puzzle.candidateDecoder))
        (D.field "cube" (D.nullable Puzzle.cubeRevealDecoder))
        (D.field "n_legal" (D.nullable D.int))
        (D.field "levels"
            (D.nullable
                (D.map2 Levels
                    (D.field "moves" D.string)
                    (D.field "cube" D.string)
                )
            )
        )
