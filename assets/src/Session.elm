module Session exposing
    ( Me
    , Session
    , User
    , decoder
    , empty
    , meDecoder
    , pref
    , userDecoder
    , withGuestName
    , withMe
    , withPref
    , withUser
    )

{-| What the page hands the app on boot: the CSRF token every /papi write
carries, the display name this browser last played under, and the display
preferences it has picked (a backgammon board's colours, say).

Guest identity itself is a silent, session-cookie affair (see
`OskolWeb.Plugs.GuestId`): the plug mints it on every request through the
browser pipeline, including the one that served this page, and every /papi
call rides the same cookie. Nothing about it is in the client's hands. The
name is the one thing the forms want to show, so the shell page carries it
in the flags rather than costing a round trip.

The account signed in on this browser (`user`) comes from `GET /papi/me`,
which the shell asks once on boot and again after a sign-in or a log-out.
Until it answers the visitor is a guest.

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

    -- The account signed in on this browser, if any.
    , user : Maybe User
    }


type alias User =
    { email : String
    , name : Maybe String
    }


{-| What `GET /papi/me` answers.
-}
type alias Me =
    { guestName : Maybe String
    , user : Maybe User
    }


{-| A session with nothing in it: a guest.
-}
empty : Session
empty =
    { csrf = "", guestName = Nothing, prefs = Dict.empty, user = Nothing }


decoder : Decoder Session
decoder =
    D.map3 (\csrf name prefs -> { csrf = csrf, guestName = name, prefs = prefs, user = Nothing })
        (D.oneOf [ D.field "csrf" D.string, D.succeed "" ])
        (D.oneOf [ D.field "guestName" (D.nullable D.string), D.succeed Nothing ]
            |> D.map (Maybe.andThen blankToNothing)
        )
        (D.oneOf [ D.field "prefs" (D.dict D.string), D.succeed Dict.empty ])


{-| `GET /papi/me`. Lax: a missing `user` is a guest.
-}
meDecoder : Decoder Me
meDecoder =
    D.map2 Me
        (D.oneOf [ D.field "guest_name" (D.nullable D.string), D.succeed Nothing ]
            |> D.map (Maybe.andThen blankToNothing)
        )
        (D.oneOf [ D.field "user" (D.nullable userDecoder), D.succeed Nothing ])


userDecoder : Decoder User
userDecoder =
    D.map2 User
        (D.field "email" D.string)
        (D.oneOf [ D.field "name" (D.nullable D.string), D.succeed Nothing ])


{-| What the server just said about this browser. The remembered name only
ever fills a gap: a name taken at a table this visit is newer.
-}
withMe : Me -> Session -> Session
withMe me session =
    { session
        | user = me.user
        , guestName =
            case session.guestName of
                Just _ ->
                    session.guestName

                Nothing ->
                    me.guestName
    }


{-| Signed in (or out) this very moment, before `/papi/me` says so.
-}
withUser : Maybe User -> Session -> Session
withUser user session =
    { session | user = user }


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
