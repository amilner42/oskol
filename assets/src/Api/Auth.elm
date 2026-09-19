module Api.Auth exposing
    ( SignedIn
    , fetchMe
    , logout
    , rename
    , signedInDecoder
    , start
    , withCode
    , withLink
    )

{-| Signing in, over `/papi/auth/*`, and who this browser is (`/papi/me`).

Every call that changes who a browser is is a POST, carrying the page's
CSRF token (`Api`): a GET never signs anyone in.

-}

import Api exposing (Error)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Me, Session, User)


{-| A sign-in that went through: how many of this browser's games came with
it, where the browser was when it asked, and the account.
-}
type alias SignedIn =
    { saved : Int
    , next : String
    , user : Maybe User
    , new : Bool -- this sign-in made the account (and picked its username)
    }


fetchMe : Session -> (Result Error Me -> msg) -> Cmd msg
fetchMe session toMsg =
    Api.get session "/papi/me" Session.meDecoder toMsg


{-| Ask for the mail: a link, and the same sign-in as six digits. The answer
is `ok` whatever the address, so it says nothing about who exists.
-}
start : Session -> { email : String, next : String } -> (Result Error () -> msg) -> Cmd msg
start session { email, next } toMsg =
    Api.post session
        "/papi/auth/start"
        (E.object [ ( "email", E.string email ), ( "next", E.string next ) ])
        (D.succeed ())
        toMsg


withCode : Session -> { email : String, code : String } -> (Result Error SignedIn -> msg) -> Cmd msg
withCode session { email, code } toMsg =
    Api.post session
        "/papi/auth/code"
        (E.object [ ( "email", E.string email ), ( "code", E.string code ) ])
        signedInDecoder
        toMsg


withLink : Session -> String -> (Result Error SignedIn -> msg) -> Cmd msg
withLink session token toMsg =
    Api.post session
        "/papi/auth/link"
        (E.object [ ( "token", E.string token ) ])
        signedInDecoder
        toMsg


logout : Session -> (Result Error () -> msg) -> Cmd msg
logout session toMsg =
    Api.post session "/papi/auth/logout" (E.object []) (D.succeed ()) toMsg


signedInDecoder : Decoder SignedIn
signedInDecoder =
    D.map4 SignedIn
        (D.oneOf [ D.field "saved" D.int, D.succeed 0 ])
        (D.oneOf [ D.field "next" D.string, D.succeed "/" ])
        (D.oneOf [ D.field "user" (D.nullable Session.userDecoder), D.succeed Nothing ])
        (D.oneOf [ D.field "new" D.bool, D.succeed False ])


{-| A signed-in browser renames its account. The server checks the name
and that nobody else has it; the answer is the account as it now is.
-}
rename : Session -> String -> (Result Error User -> msg) -> Cmd msg
rename session name toMsg =
    Api.post session
        "/papi/me/name"
        (E.object [ ( "name", E.string name ) ])
        (D.field "user" Session.userDecoder)
        toMsg
