module Session exposing (Session, decoder, withGuestName)

{-| What the page hands the app on boot: the CSRF token every /papi write
carries, and the display name this browser last played under.

Guest identity itself is a silent, session-cookie affair (see
`OskolWeb.Plugs.GuestId`): the plug mints it on every request through the
browser pipeline, including the one that served this page, and every /papi
call rides the same cookie. Nothing about it is in the client's hands. The
name is the one thing the forms want to show, so the shell page carries it
in the flags rather than costing a round trip.

-}

import Json.Decode as D exposing (Decoder)


type alias Session =
    { csrf : String
    , guestName : Maybe String
    }


decoder : Decoder Session
decoder =
    D.map2 Session
        (D.oneOf [ D.field "csrf" D.string, D.succeed "" ])
        (D.oneOf [ D.field "guestName" (D.nullable D.string), D.succeed Nothing ]
            |> D.map (Maybe.andThen blankToNothing)
        )


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
