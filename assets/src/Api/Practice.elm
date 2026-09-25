module Api.Practice exposing
    ( Band
    , Counts
    , Entry
    , Mistakes
    , Practice
    , Random
    , Today
    , fetch
    , fetchBand
    , gameMistakes
    , practiceDecoder
    , random
    , randomDecoder
    , sendTimezone
    , bandDecoder
    , stillWriting
    , todayDecoder
    )

{-| A practice session, over `/papi/practice`, and the practice home's one
endpoint of its own (`/papi/puzzles/random`).

    GET  /papi/practice          {puzzles, counts | null, mistakes | null,
                                  today | null, severity | null,
                                  lead | null, patched_level}
    GET  /papi/practice?band=g   the same, the puzzles being one tier's
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


{-| The day: how many answers this account has recorded in its own local
day. A plain count -- there is no target and no quota, so there is
nothing to fall short of. An account's only; a guest has no deck, so no
day of theirs is counted.
-}
type alias Today =
    { done : Int
    }


{-| One tier of mistakes in its three states: how bad, how many the
player has made, how many they are working on (started, not there yet)
and how many they have patched (stopped making). What is neither is
untouched, so `inProgress + patched <= total`.

`due` and `newLeft` are what the tier still has to do **today**: what is
due now, and how many mistakes it has never shown that the day's budget
of new ones still allows. A tier with neither is in good shape, which is
a thing the page says out loud.
-}
type alias Band =
    { grade : String
    , total : Int
    , inProgress : Int
    , patched : Int
    , due : Int
    , newLeft : Int
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
    , today : Maybe Today
    , severity : List Band
    , lead : Maybe String
    , patchedLevel : Int
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


{-| FIX ONE: one tier's own queue, due before new and worst first inside
the tier. The grade is one of the server's three; anything else is a 422
rather than the whole deck.
-}
fetchBand : Session -> String -> (Result Error Practice -> msg) -> Cmd msg
fetchBand session grade toMsg =
    Api.get session ("/papi/practice?band=" ++ grade) practiceDecoder toMsg


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
    D.map7 Practice
        (D.field "puzzles" (D.list entryDecoder))
        (optional "counts" countsDecoder)
        (optional "mistakes" mistakesDecoder)
        (optional "today" todayDecoder)
        (D.map (Maybe.withDefault []) (optional "severity" (D.list bandDecoder)))
        (optional "lead" D.string)
        (D.map (Maybe.withDefault 0) (optional "patched_level" D.int))


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


todayDecoder : Decoder Today
todayDecoder =
    D.map Today
        (D.field "done" D.int)


bandDecoder : Decoder Band
bandDecoder =
    D.map6 Band
        (D.field "grade" D.string)
        (D.field "total" D.int)
        -- An answer from before the three states is a deck with nothing
        -- in progress, which is what it used to say; a value that is
        -- there and malformed is still an error.
        (D.map (Maybe.withDefault 0) (optional "in_progress" D.int))
        (D.field "patched" D.int)
        -- The same for an answer from before the tiers knew what they
        -- had to do: nothing due and nothing new reads as in good
        -- shape, which is the safe way round -- it offers no run that
        -- the server would answer empty.
        (D.map (Maybe.withDefault 0) (optional "due" D.int))
        (D.map (Maybe.withDefault 0) (optional "new_left" D.int))


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
