module Api.Practice exposing
    ( Counts
    , Entry
    , Mistakes
    , Practice
    , Random
    , fetch
    , gameMistakes
    , more
    , practiceDecoder
    , random
    , randomDecoder
    , sendTimezone
    , stillWriting
    )

{-| A practice session, over `/papi/practice`, and the practice home's one
endpoint of its own (`/papi/puzzles/random`).

    GET  /papi/practice          {puzzles, counts | null, mistakes | null}
    POST /papi/practice/more     KEEP GOING: ten more into rotation, then the session
    POST /papi/practice/tz       {tz}: where this browser is
    GET  /papi/puzzles/random    TRY ONE: a puzzle whose answer stands clear
    GET  /papi/games/:slug/rooms/:id/puzzles?game=n
                                 a finished game's mistakes, for the seat
                                 the caller holds (the cards, the replay)

A session is never paged: every fetch is the front of the queue, and what
the player has answered has left it. The client keeps the list it was
given and walks it (`Main.run`); "Done for today" is a fetch that comes
back empty.

The decoders are strict about what a page prints (an id, the counts) and
ignore what it does not read (`cursor`, always null; `game`).

-}

import Api exposing (Error)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Session)


{-| One puzzle as a session lists it.
-}
type alias Entry =
    { id : String
    , kind : String
    , prompt : String
    , due : Bool
    }


{-| An account's deck in numbers: due now, how much of today's new budget
is left, how many new ones tomorrow brings, and the deck's size.
-}
type alias Counts =
    { due : Int
    , newToday : Int
    , newTomorrow : Int
    , deck : Int
    }


{-| A guest's: how many mistakes are theirs, from how many games.
-}
type alias Mistakes =
    { puzzles : Int
    , games : Int
    }


{-| The session. `counts` is an account's and only an account's;
`mistakes` a guest's. Nobody -- a stranger with no games -- gets neither
and an empty list.
-}
type alias Practice =
    { puzzles : List Entry
    , counts : Maybe Counts
    , mistakes : Maybe Mistakes
    }


{-| What TRY ONE is given.
-}
type alias Random =
    { id : String
    , kind : String
    , prompt : String
    }


fetch : Session -> (Result Error Practice -> msg) -> Cmd msg
fetch session toMsg =
    Api.get session "/papi/practice" practiceDecoder toMsg


{-| One finished game's mistakes, the caller's own seat's, in order: what
PRACTICE THIS GAME'S N MISTAKES counts and then runs. A 404 is a reader
with no seat here; `stillWriting` is a game whose grade is in but whose
puzzles are still being written, which the page asks again for in a
moment.
-}
gameMistakes : Session -> String -> String -> Int -> (Result Error Practice -> msg) -> Cmd msg
gameMistakes session slug gameId number toMsg =
    Api.get session
        ("/papi/games/" ++ slug ++ "/rooms/" ++ gameId ++ "/puzzles?game=" ++ String.fromInt number)
        practiceDecoder
        toMsg


{-| The one refusal worth asking again after: the review is done and its
puzzles are on their way (a 409, `puzzles_pending`).
-}
stillWriting : Error -> Bool
stillWriting err =
    Api.errorCode err == "puzzles_pending"


{-| KEEP GOING. The answer is the session that results, so one call does.
-}
more : Session -> (Result Error Practice -> msg) -> Cmd msg
more session toMsg =
    Api.post session "/papi/practice/more" (E.object []) practiceDecoder toMsg


{-| Where this browser is, for "due today" and "back tomorrow". Signed in
only: the server refuses it for a guest, who has no deck to keep a day for.
-}
sendTimezone : Session -> String -> (Result Error () -> msg) -> Cmd msg
sendTimezone session tz toMsg =
    Api.post session "/papi/practice/tz" (E.object [ ( "tz", E.string tz ) ]) (D.succeed ()) toMsg


random : Session -> (Result Error Random -> msg) -> Cmd msg
random session toMsg =
    Api.get session "/papi/puzzles/random" randomDecoder toMsg


practiceDecoder : Decoder Practice
practiceDecoder =
    D.map3 Practice
        (D.field "puzzles" (D.list entryDecoder))
        (optional "counts" countsDecoder)
        (optional "mistakes" mistakesDecoder)


{-| A key that may be absent (an older answer, or another endpoint's) or
null, but that is decoded strictly when it is there: a malformed count is
an error, never silently nothing.
-}
optional : String -> Decoder a -> Decoder (Maybe a)
optional key decoder =
    D.maybe (D.field key D.value)
        |> D.andThen
            (\present ->
                case present of
                    Nothing ->
                        D.succeed Nothing

                    Just _ ->
                        D.field key (D.nullable decoder)
            )


entryDecoder : Decoder Entry
entryDecoder =
    D.map4 Entry
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "prompt" D.string)
        (D.field "due" D.bool)


countsDecoder : Decoder Counts
countsDecoder =
    D.map4 Counts
        (D.field "due" D.int)
        (D.field "new_today" D.int)
        (D.field "new_tomorrow" D.int)
        (D.field "deck" D.int)


mistakesDecoder : Decoder Mistakes
mistakesDecoder =
    D.map2 Mistakes
        (D.field "puzzles" D.int)
        (D.field "games" D.int)


randomDecoder : Decoder Random
randomDecoder =
    D.map3 Random
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "prompt" D.string)
