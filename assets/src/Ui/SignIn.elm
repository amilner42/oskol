module Ui.SignIn exposing
    ( Model
    , Msg(..)
    , Out(..)
    , State(..)
    , codeLength
    , init
    , resendAfterMs
    , savedLine
    , update
    , view
    , win
    )

{-| Signing in, the one way it is done everywhere: the LIVE GAMES dialog,
the table's game-over card, an invite whose seat belongs to an account, and
an expired link. Every entry embeds this, so every entry is the same flow in
the same words.

    an email  ->  POST /papi/auth/start {email, next}
              ->  "Check your email", a six-digit field right there
    six digits (typed or pasted: it goes the moment the sixth lands)
              ->  POST /papi/auth/code
              ->  the win: "You're in." and what came with it

The mail also carries a link; opening it is `Page.Login`, which shares the
win (`win`) with this. A quiet "Send again" shows once there has been time
for the mail to arrive, and "Use a different email" goes back a step.

The words name what the player already has (their games, their PR), never
"create an account": signing in is the thing that keeps what they made
here, and a guest who ignores it loses nothing.

-}

import Api
import Api.Auth as Auth
import Html exposing (Html)
import Html.Attributes as Attr exposing (attribute, class, id, type_)
import Html.Events exposing (onClick, onInput, onSubmit)
import Process
import Session exposing (Session)
import Task
import Ui.Notebook as Notebook exposing (style)
import Ui.Username as Username


type State
    = -- the email field
      Asking
      -- the start is in flight
    | Sending
      -- the mail is out: the code field
    | Sent
      -- the code is in flight
    | Checking
      -- signed in
    | Won Auth.SignedIn


type alias Model =
    { next : String -- where the browser was when it asked: a local path
    , email : String
    , code : String
    , state : State
    , error : Maybe String
    , canResend : Bool -- time enough has passed for the mail to have come
    , resent : Bool -- a second mail went out
    , mail : Int -- which mail the resend timer is counting for
    , username : Maybe Username.Model -- on the win, for an account this sign-in made
    }


type Msg
    = EmailChanged String
    | SubmittedEmail
    | GotStart (Result Api.Error ())
    | CodeChanged String
    | SubmittedCode
    | GotCode (Result Api.Error Auth.SignedIn)
    | ResendReady Int
    | PressedResend
    | PressedDifferentEmail
    | PressedContinue
    | UsernameMsg Username.Msg
    | Focused


{-| What the entry does about it: nothing, take note of a sign-in (re-read
who this browser is, and its games), or go on from the win.
-}
type Out
    = NoOut
    | SignedIn Auth.SignedIn
    | Continue String


codeLength : Int
codeLength =
    6


{-| How long before "Didn't get it? Send again" shows.
-}
resendAfterMs : Float
resendAfterMs =
    30000


init : { next : String, email : String } -> ( Model, Cmd Msg )
init config =
    ( { next = config.next
      , email = config.email
      , code = ""
      , state = Asking
      , error = Nothing
      , canResend = False
      , resent = False
      , mail = 0
      , username = Nothing
      }
    , Notebook.focus Focused emailId
    )



-- UPDATE


update : Session -> Msg -> Model -> ( Model, Cmd Msg, Out )
update session msg model =
    case msg of
        EmailChanged email ->
            ( { model | email = email, error = Nothing }, Cmd.none, NoOut )

        SubmittedEmail ->
            if String.trim model.email == "" then
                ( { model | error = Just "Type your email address first." }, Cmd.none, NoOut )

            else if model.state == Asking then
                ( { model | state = Sending, error = Nothing }, send session model, NoOut )

            else
                ( model, Cmd.none, NoOut )

        GotStart (Ok ()) ->
            let
                mail =
                    model.mail + 1
            in
            ( { model | state = Sent, code = "", error = Nothing, canResend = False, mail = mail }
            , Cmd.batch
                [ Process.sleep resendAfterMs |> Task.perform (\_ -> ResendReady mail)
                , Notebook.focus Focused codeId
                ]
            , NoOut
            )

        GotStart (Err error) ->
            if model.state == Sending then
                ( { model | state = Asking, error = Just (Api.errorMessage error) }, Cmd.none, NoOut )

            else
                -- A resend that failed: the code field stays, and says so.
                ( { model | error = Just (Api.errorMessage error), canResend = True }, Cmd.none, NoOut )

        CodeChanged raw ->
            let
                code =
                    raw |> String.filter Char.isDigit |> String.left codeLength

                typed =
                    { model | code = code, error = Nothing }
            in
            -- The sixth digit is the submit: nothing else to press.
            if String.length code == codeLength && model.state == Sent then
                check session typed

            else
                ( typed, Cmd.none, NoOut )

        SubmittedCode ->
            if String.length model.code == codeLength && model.state == Sent then
                check session model

            else
                ( { model | error = Just "The code is six digits." }, Cmd.none, NoOut )

        GotCode (Ok signedIn) ->
            -- Focus on CONTINUE, which also brings the win into view on a
            -- short screen (a phone on its side).
            ( { model | state = Won signedIn, error = Nothing, username = Username.init signedIn }
            , Notebook.focus Focused "signin-continue"
            , SignedIn signedIn
            )

        GotCode (Err error) ->
            ( { model | state = Sent, code = "", error = Just (Api.errorMessage error) }
            , Notebook.focus Focused codeId
            , NoOut
            )

        ResendReady mail ->
            if mail == model.mail && model.state == Sent then
                ( { model | canResend = True }, Cmd.none, NoOut )

            else
                ( model, Cmd.none, NoOut )

        PressedResend ->
            if model.state == Sent && model.canResend then
                ( { model | canResend = False, resent = True, error = Nothing }, send session model, NoOut )

            else
                ( model, Cmd.none, NoOut )

        PressedDifferentEmail ->
            ( { model | state = Asking, code = "", error = Nothing, canResend = False, resent = False, mail = model.mail + 1 }
            , Notebook.focus Focused emailId
            , NoOut
            )

        PressedContinue ->
            case model.state of
                Won signedIn ->
                    ( model, Cmd.none, Continue signedIn.next )

                _ ->
                    ( model, Cmd.none, NoOut )

        UsernameMsg sub ->
            case ( model.username, model.state ) of
                ( Just username, Won signedIn ) ->
                    let
                        ( named, cmd, renamed ) =
                            Username.update session sub username
                    in
                    ( { model | username = Just named }
                    , Cmd.map UsernameMsg cmd
                    , case renamed of
                        -- The entry re-reads who this browser is, so the
                        -- bar shows the new name at once.
                        Just user ->
                            SignedIn { signedIn | user = Just user }

                        Nothing ->
                            NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        Focused ->
            ( model, Cmd.none, NoOut )


send : Session -> Model -> Cmd Msg
send session model =
    Auth.start session { email = String.trim model.email, next = model.next } GotStart


check : Session -> Model -> ( Model, Cmd Msg, Out )
check session model =
    ( { model | state = Checking, error = Nothing }
    , Auth.withCode session { email = String.trim model.email, code = model.code } GotCode
    , NoOut
    )



-- VIEW


emailId : String
emailId =
    "signin-email"


codeId : String
codeId =
    "signin-code"


view : Model -> Html Msg
view model =
    Html.div [ id "signin", class "signin" ]
        (case model.state of
            Asking ->
                asking model False

            Sending ->
                asking model True

            Sent ->
                sent model False

            Checking ->
                sent model True

            Won signedIn ->
                [ win
                    { saved = signedIn.saved
                    , note = Nothing
                    , username = model.username |> Maybe.map (Username.view >> Html.map UsernameMsg)
                    }
                    (Html.button
                        [ type_ "button"
                        , id "signin-continue"
                        , class "q-btn w-full px-6 py-3 text-[15px]"
                        , onClick PressedContinue
                        ]
                        [ Html.text "CONTINUE" ]
                    )
                ]
        )


asking : Model -> Bool -> List (Html Msg)
asking model busy =
    [ Html.form [ id "signin-form", onSubmit SubmittedEmail, class "flex flex-col gap-2.5" ]
        [ Html.label [ class "block" ]
            [ Html.span [ class "sr-only" ] [ Html.text "Your email" ]
            , Html.input
                [ type_ "email"
                , id emailId
                , Attr.name "email"
                , Attr.value model.email
                , Attr.placeholder "you@example.com"
                , attribute "autocomplete" "email"
                , attribute "autocapitalize" "off"
                , attribute "spellcheck" "false"
                , attribute "inputmode" "email"
                , Attr.disabled busy
                , class "q-field signin-field w-full px-4 py-3 text-base"
                , onInput EmailChanged
                ]
                []
            ]
        , errorLine model
        , Html.button
            [ type_ "submit"
            , id "signin-send"
            , Attr.disabled busy
            , class "q-btn w-full px-6 py-3 text-[15px]"
            ]
            [ Html.text
                (if busy then
                    "SENDING…"

                 else
                    "EMAIL ME A SIGN-IN LINK"
                )
            ]
        , Html.p [ class "q-note text-[12.5px] text-center leading-snug" ]
            [ Html.text "A link and a six-digit code. No password, nothing to remember." ]
        ]
    ]


sent : Model -> Bool -> List (Html Msg)
sent model busy =
    [ Html.div [ id "signin-sent", class "signin-sent flex flex-col gap-2.5" ]
        [ Html.p [ class "text-[17px] font-bold leading-tight text-center", style "color: var(--ink)" ]
            [ Html.text "Check your email" ]
        , Html.p [ class "q-note text-[13px] leading-snug text-center" ]
            [ Html.text "We sent a link and a code to "
            , Html.span [ class "font-semibold break-all", style "color: var(--ink)" ] [ Html.text (String.trim model.email) ]
            , Html.text
                (if model.resent then
                    " again. Tap the link, or type the code here."

                 else
                    ". Tap the link, or type the code here."
                )
            ]
        , Html.form [ onSubmit SubmittedCode ]
            [ Html.label [ class "block" ]
                [ Html.span [ class "sr-only" ] [ Html.text "The six-digit code" ]
                , Html.input
                    [ type_ "text"
                    , id codeId
                    , Attr.name "code"
                    , Attr.value model.code
                    , Attr.placeholder "000000"
                    , attribute "inputmode" "numeric"
                    , attribute "autocomplete" "one-time-code"
                    , attribute "pattern" "[0-9]*"
                    , Attr.maxlength 12
                    , Attr.disabled busy
                    , class "q-field signin-code w-full px-4 py-3 text-center tabular-nums"
                    , onInput CodeChanged
                    ]
                    []
                ]
            ]
        , if busy then
            Html.p [ class "q-note text-[13px] text-center" ] [ Html.text "Checking…" ]

          else
            errorLine model
        , Html.div [ class "flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-[13px]" ]
            [ if model.canResend then
                Html.button
                    [ type_ "button", id "signin-resend", class "signin-link", onClick PressedResend ]
                    [ Html.text "Didn't get it? Send again" ]

              else
                Html.text ""
            , Html.button
                [ type_ "button", id "signin-different", class "signin-link", onClick PressedDifferentEmail ]
                [ Html.text "Use a different email" ]
            ]
        ]
    ]


errorLine : Model -> Html msg
errorLine model =
    case model.error of
        Just message ->
            Html.p [ id "signin-error", class "text-[13px] font-semibold text-center", style "color: var(--red)" ]
                [ Html.text message ]

        Nothing ->
            Html.text ""


{-| The win: "You're in.", what came with it, and the way on. Shared with
the page a mailed link opens (`Page.Login`), which adds a `note`.
-}
win : { saved : Int, note : Maybe String, username : Maybe (Html msg) } -> Html msg -> Html msg
win config continue =
    Html.div [ id "signin-win", class "signin-win flex flex-col items-center gap-3 text-center" ]
        [ Html.span [ class "signin-tick", attribute "aria-hidden" "true" ] [ Html.text "✓" ]
        , Html.p [ class "signin-win-title text-[28px] sm:text-[32px] font-bold leading-none" ]
            [ Html.span [ class "hl px-1" ] [ Html.text "You're in." ] ]
        , Html.p [ id "signin-saved", class "text-[15px] leading-snug", style "color: var(--ink)" ]
            [ Html.text (savedLine config.saved) ]
        , case config.note of
            Just note ->
                Html.p [ id "signin-note", class "q-note text-[13px] leading-snug" ] [ Html.text note ]

            Nothing ->
                Html.text ""
        , Maybe.withDefault (Html.text "") config.username
        , Html.div [ class "w-full pt-1" ] [ continue ]
        ]


{-| What came with the account, in one sentence.
-}
savedLine : Int -> String
savedLine saved =
    case saved of
        0 ->
            "Your games will be saved to your account from now on."

        1 ->
            "1 game saved to your account."

        n ->
            String.fromInt n ++ " games saved to your account."
