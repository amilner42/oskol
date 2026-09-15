module Session exposing (Session, decoder, pref, withGuestName, withPref)

{-| What the page hands the app on boot: the CSRF token every /papi write
carries, the display name this browser last played under, and the display
preferences it has picked (a backgammon board's colours, say).

Guest identity itself is a silent, session-cookie affair (see
`OskolWeb.Plugs.GuestId`): the plug mints it on every request through the
browser pipeline, including the one that served this page, and every /papi
call rides the same cookie. Nothing about it is in the client's hands. The
name is the one thing the forms want to show, so the shell page carries it
in the flags rather than costing a round trip.

-}

import Dict exposing (Dict)
import Json.Decode as D exposing (Decoder)


type alias Session =
    { csrf : String
    , guestName : Maybe String

    -- Display preferences, keyed the way the server keys them
    -- (`backgammon_theme`). The flags carry what this browser last stored
    -- locally, so a board is the right colour on the first paint; the
    -- server's copy (`/papi/me/prefs`) is what follows this guest between
    -- browsers, and overrides it when it arrives.
    , prefs : Dict String String
    }


decoder : Decoder Session
decoder =
    D.map3 Session
        (D.oneOf [ D.field "csrf" D.string, D.succeed "" ])
        (D.oneOf [ D.field "guestName" (D.nullable D.string), D.succeed Nothing ]
            |> D.map (Maybe.andThen blankToNothing)
        )
        (D.oneOf [ D.field "prefs" (D.dict D.string), D.succeed Dict.empty ])


{-| One preference, if this browser has it.
-}
pref : String -> Session -> Maybe String
pref key session =
    Dict.get key session.prefs


{-| A preference just picked: remembered for the rest of this visit, so
leaving the table and coming back does not undo it.
-}
withPref : String -> String -> Session -> Session
withPref key value session =
    { session | prefs = Dict.insert key value session.prefs }


{-| A name taken at a table is remembered for the next form, so a create or
join that succeeds updates the session in place rather than waiting for the
next page load.
-}
withGuestName : String -> Session -> Session
withGuestName name session =
    { session | guestName = blankToNothing name }


blankToNothing : String -> Maybe String
blankToNothing name =
    if String.trim name == "" then
        Nothing

    else
        Just name
