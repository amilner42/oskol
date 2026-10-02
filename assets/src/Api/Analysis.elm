module Api.Analysis exposing (Status(..), ask, status, statusDecoder)

{-| The analysis board's two requests (analysis-ask-api): ask the engine
about a setup, and ask again how that is going.

    POST /papi/analysis       Setup.toJson
      -> 200 {status: "done", key, puzzle, reveal}   already stored: no engine time
      -> 202 {status: "pending", key}                queued, or already in flight
      -> 409 dances / 422 validation_failed / 429 rate_limited / 503 engine_down,
         each with the sentence to show (`Api.errorMessage`)
    GET /papi/analysis/:key
      -> {status: "pending"} | {status: "done", key, puzzle, reveal}
       | {status: "failed", message}

`puzzle` is the puzzle page's own body (`Puzzle.decoder`), so the board can
be played on at once. `reveal` is kept as the server sent it here; the page
that draws the answer (analysis-page-verdict) reads it with the reveal's
decoders.

-}

import Api
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Setup)
import Json.Decode as D
import Session exposing (Session)


type Status
    = Pending String -- the key; ask `status` again
    | Done { key : String, puzzle : Puzzle.Puzzle, reveal : D.Value }
    | Failed String -- the sentence


ask : Session -> Setup -> (Result Api.Error Status -> msg) -> Cmd msg
ask session setup toMsg =
    Api.post session "/papi/analysis" (Setup.toJson setup) statusDecoder toMsg


status : Session -> String -> (Result Api.Error Status -> msg) -> Cmd msg
status session key toMsg =
    Api.get session ("/papi/analysis/" ++ key) (statusDecoder |> D.map (withKey key)) toMsg


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
                            (D.field "reveal" D.value)

                    "failed" ->
                        D.map Failed (D.field "message" D.string)

                    _ ->
                        D.fail ("not an analysis status: " ++ s)
            )
