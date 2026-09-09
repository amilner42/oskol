module Api exposing
    ( Error(..)
    , errorCode
    , errorMessage
    , get
    , parseBody
    , post
    )

{-| HTTP core for the /papi endpoints.

Every response uses one envelope: `{ok: true, ...payload}` on success,
`{ok: false, error: {code, message}}` on failure — including non-2xx
statuses, which is why the body is parsed here rather than leaning on
`Http.BadStatus`.

Requests go same-origin, so the silent guest cookie rides along with every
one of them and identity needs nothing from the client. Writes carry the
page's CSRF token in `x-csrf-token`.

-}

import Http
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Session)


type Error
    = ApiError { code : String, message : String }
    | NetworkError
    | DecodeError String


{-| What to show a visitor. An API error is already a sentence.
-}
errorMessage : Error -> String
errorMessage err =
    case err of
        ApiError e ->
            e.message

        NetworkError ->
            "Lost the connection. Try again."

        DecodeError _ ->
            "Unexpected response from the server."


{-| The machine-readable half, for the few places that branch on it
(`not_found` is a page, `validation_failed` is a line under a field).
-}
errorCode : Error -> String
errorCode err =
    case err of
        ApiError e ->
            e.code

        NetworkError ->
            "network_error"

        DecodeError _ ->
            "decode_error"


get : Session -> String -> Decoder a -> (Result Error a -> msg) -> Cmd msg
get session path decoder toMsg =
    request session "GET" path Nothing decoder toMsg


post : Session -> String -> E.Value -> Decoder a -> (Result Error a -> msg) -> Cmd msg
post session path body decoder toMsg =
    request session "POST" path (Just body) decoder toMsg


request : Session -> String -> String -> Maybe E.Value -> Decoder a -> (Result Error a -> msg) -> Cmd msg
request session method path maybeBody decoder toMsg =
    Http.request
        { method = method
        , headers = [ Http.header "x-csrf-token" session.csrf ]
        , url = path
        , body =
            case maybeBody of
                Just value ->
                    Http.jsonBody value

                Nothing ->
                    Http.emptyBody
        , expect = expectEnvelope decoder toMsg
        , timeout = Just 30000
        , tracker = Nothing
        }


expectEnvelope : Decoder a -> (Result Error a -> msg) -> Http.Expect msg
expectEnvelope decoder toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    parseBody decoder body

                Http.BadStatus_ _ body ->
                    parseBody decoder body

                Http.NetworkError_ ->
                    Err NetworkError

                Http.Timeout_ ->
                    Err NetworkError

                Http.BadUrl_ url ->
                    Err (DecodeError ("bad url: " ++ url))


{-| The envelope, unwrapped. Exposed for the decoder tests.
-}
parseBody : Decoder a -> String -> Result Error a
parseBody decoder body =
    case D.decodeString (D.field "ok" D.bool) body of
        Ok True ->
            D.decodeString decoder body
                |> Result.mapError (D.errorToString >> DecodeError)

        Ok False ->
            case D.decodeString envelopeErrorDecoder body of
                Ok e ->
                    Err (ApiError e)

                Err _ ->
                    Err (DecodeError "malformed error envelope")

        Err e ->
            Err (DecodeError (D.errorToString e))


envelopeErrorDecoder : Decoder { code : String, message : String }
envelopeErrorDecoder =
    D.field "error"
        (D.map2 (\c m -> { code = c, message = m })
            (D.field "code" D.string)
            (D.field "message" D.string)
        )
