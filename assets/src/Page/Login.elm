module Page.Login exposing
    ( Model
    , Msg
    , Out(..)
    , State(..)
    , flagsDecoder
    , init
    , next
    , signedIn
    , title
    , update
    , view
    , withSession
    )

{-| `/login/<token>` — the page a mailed sign-in link opens.

The server has already read the token and put what it found in the page's
flags; it has written nothing. So there are three things to render:

  - **confirm** — "Sign in as you@example.com", with one button. Pressing it
    POSTs the token to `/papi/auth/link`, which is the only thing that
    consumes it. That is the whole reason this page exists: a GET must not
    sign anyone in, or a mail scanner would spend the link before the player
    saw it. Under it, for the mail read on a phone while the game is on a
    laptop: the code in the same mail signs the laptop in instead.
  - **the win** — "You're in.", how many games came along, CONTINUE back to
    where the player was. The same win the sign-in everywhere else ends on
    (`Ui.SignIn.win`).
  - **expired** — the link is past its fifteen minutes, or has been used.
    The sign-in itself is right there, with the address filled in when the
    page knows it: one press sends a fresh mail.

-}

import Api
import Api.Auth as Auth
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session exposing (Session)
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn
import Ui.Username as Username



-- MODEL


type State
    = -- a live token, for this address, waiting for the button
      Confirm String
      -- the POST is in flight
    | Signing String
      -- signed in: how many of this browser's games came with it, and
      -- whether it was this page's link (rather than a code typed here)
    | Done { saved : Int, viaLink : Bool }
      -- nothing to spend: expired, already used, or never a token at all;
      -- the address, when the page knows it
    | Expired String


type alias Model =
    { session : Session
    , token : String
    , state : State
    , next : String
    , signIn : SignIn.Model -- the fresh mail an expired link offers
    , error : Maybe String -- the press did not go through, and spent nothing
    , username : Maybe Username.Model -- on the win, for an account this sign-in made
    }


type Msg
    = PressedSignIn
    | GotSignIn (Result Api.Error Auth.SignedIn)
    | SignInMsg SignIn.Msg
    | UsernameMsg Username.Msg


{-| A sign-in just went through: the shell re-reads who this browser is.
-}
type Out
    = NoOut
    | SignedIn (Maybe Session.User)


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
                        ( Expired flags.email, flags.next )

                Nothing ->
                    ( Expired "", "/" )
    in
    ( { session = session
      , token = config.token
      , state = state
      , next = where_
      , signIn = freshSignIn where_ state
      , error = Nothing
      , username = Nothing
      }
    , Cmd.none
    )


freshSignIn : String -> State -> SignIn.Model
freshSignIn where_ state =
    let
        email =
            case state of
                Expired address ->
                    address

                Confirm address ->
                    address

                Signing address ->
                    address

                Done _ ->
                    ""
    in
    Tuple.first (SignIn.init { next = where_, email = email })


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


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


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        PressedSignIn ->
            case model.state of
                Confirm email ->
                    ( { model | state = Signing email }
                    , Auth.withLink model.session model.token GotSignIn
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        GotSignIn (Ok result) ->
            ( { model
                | state = Done { saved = result.saved, viaLink = True }
                , next = result.next
                , username = Username.init result
              }
            , Cmd.none
            , SignedIn result.user
            )

        -- Anything but the server's refusal (a lost connection, a 500) has
        -- spent nothing: say so, and the button is there to press again.
        GotSignIn (Err error) ->
            if Api.errorCode error /= "validation_failed" then
                case model.state of
                    Signing address ->
                        ( { model | state = Confirm address, error = Just (Api.errorMessage error) }, Cmd.none, NoOut )

                    _ ->
                        ( model, Cmd.none, NoOut )

            else
                expire model

        SignInMsg signInMsg ->
            let
                ( signIn, cmd, out ) =
                    SignIn.update model.session signInMsg model.signIn

                updated =
                    { model | signIn = signIn }
            in
            case out of
                SignIn.SignedIn result ->
                    ( { updated
                        | state = Done { saved = result.saved, viaLink = False }
                        , next = result.next
                        , username = Username.init result
                      }
                    , Cmd.map SignInMsg cmd
                    , SignedIn result.user
                    )

                _ ->
                    ( updated, Cmd.map SignInMsg cmd, NoOut )

        UsernameMsg sub ->
            case model.username of
                Just username ->
                    let
                        ( named, cmd, renamed ) =
                            Username.update model.session sub username
                    in
                    ( { model | username = Just named }
                    , Cmd.map UsernameMsg cmd
                    , case renamed of
                        Just user ->
                            SignedIn (Just user)

                        Nothing ->
                            NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )


{-| Spent since the page was served (another tab, the other device's code),
or past its time: the fresh mail is the way on.
-}
expire : Model -> ( Model, Cmd Msg, Out )
expire model =
    let
        expired =
            case model.state of
                Signing address ->
                    Expired address

                _ ->
                    Expired ""
    in
    ( { model | state = expired, error = Nothing, signIn = freshSignIn model.next expired }, Cmd.none, NoOut )



-- VIEW


view : Model -> Html Msg
view model =
    Html.section
        [ class "mt-8 sm:mt-12 mx-auto max-w-md q-card sheet p-6 sm:p-8", id "login" ]
        (body model)


body : Model -> List (Html Msg)
body model =
    case model.state of
        Confirm email ->
            confirm email False model.error

        Signing email ->
            confirm email True Nothing

        Done done ->
            [ SignIn.win
                { saved = done.saved
                , note =
                    if done.saved == 0 && done.viaLink then
                        Just "If you were playing on another device, sign in there to bring those games too."

                    else
                        Nothing
                , username = model.username |> Maybe.map (Username.view >> Html.map UsernameMsg)
                }
                (Html.a
                    [ Attr.href model.next
                    , id "login-continue"
                    , class "q-btn w-full px-6 py-3 text-[15px]"
                    ]
                    [ Html.text "CONTINUE" ]
                )
            ]

        Expired _ ->
            [ Notebook.eyebrow "SIGN IN"
            , line "That link has expired. We'll send a fresh one."
            , Html.map SignInMsg (SignIn.view model.signIn)
            ]


confirm : String -> Bool -> Maybe String -> List (Html Msg)
confirm email busy error =
    [ Notebook.eyebrow "SIGN IN"
    , Html.p [ class "text-[20px] sm:text-[22px] font-bold leading-snug mb-5", Notebook.style "color: var(--ink)" ]
        [ Html.text "Sign in as "
        , Html.span [ class "break-all" ] [ Html.text email ]
        ]
    , Html.button
        [ Attr.type_ "button"
        , id "login-confirm"
        , Attr.disabled busy
        , class "q-btn w-full px-6 py-3.5 text-[15px]"
        , onClick PressedSignIn
        ]
        [ Html.text
            (if busy then
                "SIGNING IN…"

             else
                "SIGN IN"
            )
        ]
    , case error of
        Just message ->
            Html.p [ id "login-error", class "text-[13px] font-semibold text-center mt-3", Notebook.style "color: var(--red)" ]
                [ Html.text message ]

        Nothing ->
            Html.text ""
    , Html.p [ class "q-note text-[12.5px] leading-snug text-center mt-4" ]
        [ Html.text "Opened this on another device? Enter the code from the mail there instead." ]
    ]


line : String -> Html msg
line text =
    Html.p [ class "text-base mb-4", Notebook.style "color: var(--ink)" ] [ Html.text text ]
