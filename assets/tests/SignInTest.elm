module SignInTest exposing (suite)

{-| Signing in, the one component every entry embeds (`Ui.SignIn`): an
email, the mail, six digits that go the moment the sixth lands, and the win.
Driven through `update` like any page, with the server's answers handed in
as messages.
-}

import Api
import Expect
import Html.Attributes
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, id, text)
import Ui.SignIn as SignIn


suite : Test
suite =
    describe "Ui.SignIn"
        [ flow
        , errors
        , resending
        , winCopy
        , rendered
        ]


flow : Test
flow =
    describe "email, mail, code, in"
        [ test "an address sends the mail" <|
            \_ ->
                start
                    |> typeEmail "her@example.com"
                    |> step SignIn.SubmittedEmail
                    |> .state
                    |> Expect.equal SignIn.Sending
        , test "the mail out, the code field is right there" <|
            \_ ->
                sent
                    |> .state
                    |> Expect.equal SignIn.Sent
        , test "five digits wait for the sixth" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "48291")
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Sent
                        , .code >> Expect.equal "48291"
                        ]
        , test "the sixth digit is the submit" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "482913")
                    |> .state
                    |> Expect.equal SignIn.Checking
        , test "a pasted code, spaced as the mail prints it, goes too" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "482 913")
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Checking
                        , .code >> Expect.equal "482913"
                        ]
        , test "anything but digits is dropped, and never more than six" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "ab12")
                    |> .code
                    |> Expect.equal "12"
        , test "the server says yes: the win, and the entry is told" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "482913")
                    |> SignIn.update Session.empty (SignIn.GotCode (Ok won))
                    |> (\( model, _, out ) -> ( model.state, out ))
                    |> Expect.equal ( SignIn.Won won, SignIn.SignedIn won )
        , test "CONTINUE goes back to where it was asked from" <|
            \_ ->
                sent
                    |> step (SignIn.GotCode (Ok won))
                    |> SignIn.update Session.empty SignIn.PressedContinue
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (SignIn.Continue "/backgammon/123456")
        , test "a new account is told its username, never its email, and may change it" <|
            \_ ->
                sent
                    |> step (SignIn.GotCode (Ok won))
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "username-name" ] >> Query.has [ text "arie1" ]
                        , Query.has [ id "username-change" ]
                        , Query.hasNot [ text "her@example.com" ]
                        ]
        , test "a returning account is not offered a new name" <|
            \_ ->
                sent
                    |> step (SignIn.GotCode (Ok { won | new = False }))
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Query.hasNot [ id "username-line" ]
        , test "a different email goes back a step, the address kept to edit" <|
            \_ ->
                sent
                    |> step SignIn.PressedDifferentEmail
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Asking
                        , .email >> Expect.equal "her@example.com"
                        ]
        ]


errors : Test
errors =
    describe "what goes wrong reads as a sentence"
        [ test "an empty field says what to do, and sends nothing" <|
            \_ ->
                start
                    |> step SignIn.SubmittedEmail
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Asking
                        , .error >> Expect.equal (Just "Type your email address first.")
                        ]
        , test "a refused address is the server's sentence, back on the field" <|
            \_ ->
                start
                    |> typeEmail "nobody"
                    |> step SignIn.SubmittedEmail
                    |> step (SignIn.GotStart (Err (refusal "That doesn't look like an email address")))
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Asking
                        , .error >> Expect.equal (Just "That doesn't look like an email address")
                        ]
        , test "a wrong code says so and clears the field for another go" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "111111")
                    |> step (SignIn.GotCode (Err (refusal "That code is not right. Check the mail, or ask for a new one.")))
                    |> Expect.all
                        [ .state >> Expect.equal SignIn.Sent
                        , .code >> Expect.equal ""
                        , .error >> Expect.equal (Just "That code is not right. Check the mail, or ask for a new one.")
                        ]
        , test "a lost connection says that" <|
            \_ ->
                sent
                    |> step (SignIn.CodeChanged "111111")
                    |> step (SignIn.GotCode (Err Api.NetworkError))
                    |> .error
                    |> Expect.equal (Just "Lost the connection. Try again.")
        ]


resending : Test
resending =
    describe "Didn't get it? Send again"
        [ test "is not offered the moment the mail goes" <|
            \_ -> sent |> .canResend |> Expect.equal False
        , test "is offered once the wait for this mail is over" <|
            \_ -> sent |> step (SignIn.ResendReady sent.mail) |> .canResend |> Expect.equal True
        , test "a timer for an earlier mail offers nothing" <|
            \_ -> sent |> step (SignIn.ResendReady (sent.mail - 1)) |> .canResend |> Expect.equal False
        , test "sending again waits again, and says it went" <|
            \_ ->
                sent
                    |> step (SignIn.ResendReady sent.mail)
                    |> step SignIn.PressedResend
                    |> Expect.all
                        [ .canResend >> Expect.equal False
                        , .resent >> Expect.equal True
                        , .state >> Expect.equal SignIn.Sent
                        ]
        , test "and the new mail starts a new wait" <|
            \_ ->
                let
                    again =
                        sent
                            |> step (SignIn.ResendReady sent.mail)
                            |> step SignIn.PressedResend
                            |> step (SignIn.GotStart (Ok ()))
                in
                Expect.all
                    [ .mail >> Expect.equal (sent.mail + 1)
                    , step (SignIn.ResendReady sent.mail) >> .canResend >> Expect.equal False
                    , step (SignIn.ResendReady again.mail) >> .canResend >> Expect.equal True
                    ]
                    again
        , test "it waits long enough for a mail to arrive" <|
            \_ -> SignIn.resendAfterMs |> Expect.atLeast 30000
        ]


winCopy : Test
winCopy =
    describe "the win names what came with it"
        [ test "nothing yet: the games from now on" <|
            \_ -> SignIn.savedLine 0 |> Expect.equal "Your games will be saved to your account from now on."
        , test "one game" <|
            \_ -> SignIn.savedLine 1 |> Expect.equal "1 game saved to your account."
        , test "several" <|
            \_ -> SignIn.savedLine 3 |> Expect.equal "3 games saved to your account."
        ]


rendered : Test
rendered =
    describe "on the page"
        [ test "the code field asks a phone for its number pad" <|
            \_ ->
                sent
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Query.find [ id "signin-code" ]
                    |> Query.has
                        [ attribute (Html.Attributes.attribute "inputmode" "numeric")
                        , attribute (Html.Attributes.attribute "autocomplete" "one-time-code")
                        ]
        , test "the step after the email says where the mail went" <|
            \_ ->
                sent
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Query.has [ text "Check your email", text "her@example.com" ]
        , test "Send again is not there until it is offered" <|
            \_ ->
                sent
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Query.hasNot [ id "signin-resend" ]
        , test "the win: You're in, the count, and CONTINUE" <|
            \_ ->
                sent
                    |> step (SignIn.GotCode (Ok won))
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ text "You're in.", text "3 games saved to your account." ]
                        , Query.find [ id "signin-continue" ] >> Event.simulate Event.click >> Event.expect SignIn.PressedContinue
                        ]
        , test "the offer never asks anyone to create an account" <|
            \_ ->
                start
                    |> SignIn.view
                    |> Query.fromHtml
                    |> Query.hasNot [ text "reate an account" ]
        ]



-- HELPERS


start : SignIn.Model
start =
    SignIn.init { next = "/backgammon/123456", email = "" } |> Tuple.first


sent : SignIn.Model
sent =
    start
        |> typeEmail "her@example.com"
        |> step SignIn.SubmittedEmail
        |> step (SignIn.GotStart (Ok ()))


typeEmail : String -> SignIn.Model -> SignIn.Model
typeEmail email =
    step (SignIn.EmailChanged email)


step : SignIn.Msg -> SignIn.Model -> SignIn.Model
step msg model =
    SignIn.update Session.empty msg model |> (\( next, _, _ ) -> next)


won : { saved : Int, next : String, user : Maybe Session.User, new : Bool }
won =
    { saved = 3, next = "/backgammon/123456", user = Just { email = "her@example.com", name = Just "arie1" }, new = True }


refusal : String -> Api.Error
refusal message =
    Api.ApiError { code = "validation_failed", message = message }
