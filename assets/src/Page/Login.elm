module Page.Login exposing
    ( Model
    , Msg
    , State(..)
    , flagsDecoder
    , init
    , next
    , signedIn
    , title
    , update
    , view
    )

{-| `/login/<token>` — the page a mailed sign-in link opens.

The server has already read the token and put what it found in the page's
flags; it has written nothing. So there are three things to render:

  - **confirm** — "Sign in as you@example.com", with one button. Pressing it
    POSTs the token to `/papi/auth/link`, which is the only thing that
    consumes it. That is the whole reason this page exists: a GET must not
    sign anyone in, or a mail scanner would spend the link before the player
    saw it.
  - **done** — signed in, with how many games came along and a way back to
    where the player was.
  - **expired** — the link is past its fifteen minutes, or has been used.
    Ask for a new one.

Plain for now: the card, the button and the sentences. The offer that sends
people here, and the polish, come with the rest of the flow.

-}

import Api
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Session)
import Ui.Notebook as Notebook



-- MODEL


type State
    = -- a live token, for this address, waiting for the button
      Confirm String
      -- signed in: how many of this browser's games came with it
    | Done Int
      -- nothing to spend: expired, already used, or never a token at all
    | Expired
      -- the POST is in flight
    | Signing String
      -- the POST came back with something to say
    | Failed String String


type alias Model =
    { session : Session
    , token : String
    , state : State
    , next : String
    }


type Msg
    = PressedSignIn
    | GotSignIn (Result Api.Error Int)


{-| What the shell page carried: the state the server read off the token.
Anything unreadable is an expired link, which is the safe thing to say.
-}
flagsDecoder : Decoder { state : String, email : String, next : String }
flagsDecoder =
    D.map3 (\s e n -> { state = s, email = e, next = n })
        (D.oneOf [ D.field "state" D.string, D.succeed "expired" ])
        (D.oneOf [ D.field "email" D.string, D.succeed "" ])
        (D.oneOf [ D.field "next" D.string, D.succeed "/" ])


init : Session -> { token : String, flags : Maybe String } -> ( Model, Cmd Msg )
init session config =
    let
        decoded =
            config.flags
                |> Maybe.map (D.decodeString flagsDecoder)
                |> Maybe.withDefault (Err (D.Failure "no sign-in on this page" E.null))
                |> Result.toMaybe

        ( state, where_ ) =
            case decoded of
                Just flags ->
                    if flags.state == "confirm" && flags.email /= "" then
                        ( Confirm flags.email, flags.next )

                    else
                        ( Expired, flags.next )

                Nothing ->
                    ( Expired, "/" )
    in
    ( { session = session, token = config.token, state = state, next = where_ }
    , Cmd.none
    )


{-| Where this browser was when it asked to sign in: a local path, always.
-}
next : Model -> String
next model =
    model.next


{-| Whether the sign-in went through, so the shell can refresh what it
knows about the visitor.
-}
signedIn : Model -> Bool
signedIn model =
    case model.state of
        Done _ ->
            True

        _ ->
            False


title : Model -> String
title _ =
    "Sign in"



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PressedSignIn ->
            case model.state of
                Confirm email ->
                    ( { model | state = Signing email }
                    , Api.post model.session
                        "/papi/auth/link"
                        (E.object [ ( "token", E.string model.token ) ])
                        savedDecoder
                        GotSignIn
                    )

                _ ->
                    ( model, Cmd.none )

        GotSignIn (Ok saved) ->
            ( { model | state = Done saved }, Cmd.none )

        GotSignIn (Err error) ->
            let
                email =
                    case model.state of
                        Signing address ->
                            address

                        _ ->
                            ""
            in
            ( { model | state = Failed email (Api.errorMessage error) }, Cmd.none )


savedDecoder : Decoder Int
savedDecoder =
    D.oneOf [ D.field "saved" D.int, D.succeed 0 ]



-- VIEW


view : Model -> Html Msg
view model =
    Html.section
        [ class "mt-8 sm:mt-12 q-card p-5 sm:p-8", id "login" ]
        (Notebook.eyebrow "SIGN IN" :: body model)


body : Model -> List (Html Msg)
body model =
    case model.state of
        Confirm email ->
            [ line ("Sign in as " ++ email ++ ".")
            , button "login-confirm" "SIGN IN" False
            ]

        Signing email ->
            [ line ("Signing in as " ++ email ++ "…")
            , button "login-confirm" "SIGNING IN…" True
            ]

        Done saved ->
            [ line ("You're in." ++ savedLine saved)
            , link model.next "CONTINUE"
            ]

        Failed _ message ->
            [ line message
            , link "/" "BACK TO OSKOL"
            ]

        Expired ->
            [ line "That sign-in link has expired. Ask for a new one."
            , link "/" "BACK TO OSKOL"
            ]


savedLine : Int -> String
savedLine saved =
    case saved of
        0 ->
            ""

        1 ->
            " 1 game saved to your account."

        n ->
            " " ++ String.fromInt n ++ " games saved to your account."


line : String -> Html msg
line text =
    Html.p [ class "text-base mb-5", Notebook.style "color: var(--pen)" ] [ Html.text text ]


button : String -> String -> Bool -> Html Msg
button nodeId label busy =
    Html.button
        [ Attr.type_ "button"
        , id nodeId
        , Attr.disabled busy
        , class "q-btn w-full sm:w-auto sm:min-w-[12rem] px-7 py-3.5 text-base"
        , onClick PressedSignIn
        ]
        [ Html.text label ]


link : String -> String -> Html msg
link href label =
    Html.a
        [ Attr.href href
        , id "login-continue"
        , class "q-btn inline-block w-full sm:w-auto sm:min-w-[12rem] px-7 py-3.5 text-base text-center"
        ]
        [ Html.text label ]
