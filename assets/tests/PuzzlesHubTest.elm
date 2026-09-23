module PuzzlesHubTest exposing (suite)

{-| The practice home on the server's three answers: an account's deck,
a guest's mistakes, and nobody's empty list. What each shows, what
PRACTICE hands the shell, what TRY ONE does with a puzzle and with an
empty pool, and what KEEP GOING does when there is nothing more.
-}

import Api
import Api.Practice as Practice
import Expect
import Html
import Html.Attributes
import Page.Puzzles as Hub exposing (Msg(..), Out(..))
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, id, tag, text)


suite : Test
suite =
    describe "the practice home"
        [ decoding
        , anAccount
        , aGuest
        , aStranger
        ]



-- THE SERVER'S ANSWERS


accountJson : String
accountJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4. What's your play?","due":true},{"id":"bbbbbbbb","kind":"double","prompt":"White to play. Double?","due":false}],"cursor":null,"counts":{"due":12,"new_today":4,"new_tomorrow":10,"deck":231},"mistakes":null,"game":null}"""


doneJson : String
doneJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":0,"new_today":0,"new_tomorrow":4,"deck":231},"mistakes":null,"game":null}"""


emptyDeckJson : String
emptyDeckJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":0,"new_today":10,"new_tomorrow":0,"deck":0},"mistakes":null,"game":null}"""


guestJson : String
guestJson =
    """{"ok":true,"puzzles":[{"id":"cccccccc","kind":"move","prompt":"White to play 5-2. What's your play?","due":false},{"id":"dddddddd","kind":"take","prompt":"White is doubled. Take?","due":false}],"cursor":null,"counts":null,"mistakes":{"puzzles":23,"games":4},"game":null}"""


nobodyJson : String
nobodyJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":null,"mistakes":null,"game":null}"""


parse : String -> Result Api.Error Practice.Practice
parse =
    Api.parseBody Practice.practiceDecoder


loaded : String -> Hub.Model
loaded json =
    Hub.init Session.empty { tz = "Europe/Paris" }
        |> Tuple.first
        |> send (GotPractice (parse json))


send : Msg -> Hub.Model -> Hub.Model
send msg model =
    Hub.update msg model |> (\( next, _, _ ) -> next)


out : Msg -> Hub.Model -> Out
out msg model =
    Hub.update msg model |> (\( _, _, o ) -> o)


rendered : Hub.Model -> Query.Single Msg
rendered model =
    Hub.view model |> Query.fromHtml



-- DECODING


decoding : Test
decoding =
    describe "decoding"
        [ test "an account's session: the list and the counts" <|
            \_ ->
                parse accountJson
                    |> Result.map (\p -> ( List.map .id p.puzzles, p.counts, p.mistakes ))
                    |> Expect.equal (Ok ( [ "aaaaaaaa", "bbbbbbbb" ], Just { due = 12, newToday = 4, newTomorrow = 10, deck = 231 }, Nothing ))
        , test "a guest's: the list and what is theirs" <|
            \_ ->
                parse guestJson
                    |> Result.map (\p -> ( List.map .due p.puzzles, p.counts, p.mistakes ))
                    |> Expect.equal (Ok ( [ False, False ], Nothing, Just { puzzles = 23, games = 4 } ))
        , test "nobody's: nothing, and not an error" <|
            \_ ->
                parse nobodyJson
                    |> Expect.equal (Ok { puzzles = [], counts = Nothing, mistakes = Nothing })
        , test "a count that is not a number is refused, not defaulted" <|
            \_ ->
                parse """{"ok":true,"puzzles":[],"counts":{"due":"twelve","new_today":4,"new_tomorrow":10,"deck":231},"mistakes":null}"""
                    |> Result.map (\_ -> ())
                    |> Expect.err
        , test "the wire's three visitors" <|
            \_ ->
                Expect.all
                    [ \_ -> parse accountJson |> Result.map (Hub.state >> isAccount) |> Expect.equal (Ok True)
                    , \_ -> parse guestJson |> Result.map (Hub.state >> isGuest) |> Expect.equal (Ok True)
                    , \_ -> parse nobodyJson |> Result.map Hub.state |> Expect.equal (Ok Hub.Stranger)

                    -- An account with an empty deck has nothing of its own yet.
                    , \_ -> parse emptyDeckJson |> Result.map Hub.state |> Expect.equal (Ok Hub.Stranger)
                    ]
                    ()
        ]


isAccount : Hub.State -> Bool
isAccount state =
    case state of
        Hub.Account _ _ ->
            True

        _ ->
            False


isGuest : Hub.State -> Bool
isGuest state =
    case state of
        Hub.Guest _ _ ->
            True

        _ ->
            False



-- AN ACCOUNT


anAccount : Test
anAccount =
    describe "an account with a deck"
        [ test "reads its counts in one line, and is offered PRACTICE" <|
            \_ ->
                rendered (loaded accountJson)
                    |> Expect.all
                        [ Query.find [ id "hub-headline" ] >> Query.has [ text "12 due · 4 new today · 231 in your deck" ]
                        , Query.find [ id "hub-practice" ] >> Query.has [ text "PRACTICE" ]
                        , Query.hasNot [ id "hub-try-one" ]
                        , Query.hasNot [ id "hub-unsaved" ]
                        ]
        , test "PRACTICE hands the shell the run, in the deck's order" <|
            \_ ->
                out PressedPractice (loaded accountJson)
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ])
        , test "the words are the wire's numbers" <|
            \_ ->
                Hub.countsLine { due = 1, newToday = 0, newTomorrow = 3, deck = 9 }
                    |> Expect.equal "1 due · 9 in your deck"
        , test "nothing due and nothing new is done for today, with KEEP GOING" <|
            \_ ->
                rendered (loaded doneJson)
                    |> Expect.all
                        [ Query.find [ id "hub-headline" ] >> Query.has [ text "Done for today." ]
                        , Query.find [ id "hub-counts" ] >> Query.has [ text "4 new tomorrow · 231 in your deck" ]
                        , Query.find [ id "hub-keep-going" ] >> Query.has [ text "KEEP GOING" ]
                        , Query.hasNot [ id "hub-practice" ]
                        ]
        , test "KEEP GOING's answer is the run when it brought puzzles" <|
            \_ ->
                loaded doneJson
                    |> send PressedKeepGoing
                    |> out (GotMore (parse accountJson))
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ])
        , test "and a line when it brought nothing" <|
            \_ ->
                loaded doneJson
                    |> send PressedKeepGoing
                    |> send (GotMore (parse doneJson))
                    |> rendered
                    |> Query.find [ id "hub-note" ]
                    |> Query.has [ text "every puzzle in your deck" ]
        , test "an account with an empty deck is offered what a stranger is" <|
            \_ ->
                rendered (loaded emptyDeckJson)
                    |> Expect.all
                        [ Query.has [ id "hub-try-one" ]
                        , Query.hasNot [ id "hub-practice" ]
                        , Query.hasNot [ id "hub-keep-going" ]
                        ]
        ]



-- A GUEST


aGuest : Test
aGuest =
    describe "a guest with games behind them"
        [ test "reads what is theirs, that nothing is kept yet, and is offered PRACTICE" <|
            \_ ->
                rendered (loaded guestJson)
                    |> Expect.all
                        [ Query.find [ id "hub-headline" ] >> Query.has [ text "23 mistakes from your 4 games" ]
                        , Query.find [ id "hub-unsaved" ] >> Query.has [ text "not saved" ]
                        , Query.find [ id "hub-practice" ] >> Query.has [ text "PRACTICE" ]
                        , Query.hasNot [ id "hub-try-one" ]
                        ]
        , test "PRACTICE runs their mistakes" <|
            \_ ->
                out PressedPractice (loaded guestJson)
                    |> Expect.equal (StartRun [ "cccccccc", "dddddddd" ])
        , test "one of each is singular" <|
            \_ ->
                Hub.mistakesLine { puzzles = 1, games = 1 }
                    |> Expect.equal "1 mistake from your 1 game"
        , test "the sign-in is a line until pressed, then the one component" <|
            \_ ->
                let
                    model =
                        loaded guestJson
                in
                Expect.all
                    [ \_ -> rendered model |> Query.hasNot [ id "signin" ]
                    , \_ -> rendered model |> Query.find [ id "hub-signin-open" ] |> Event.simulate Event.click |> Event.expect OpenedSignIn
                    , \_ -> rendered (send OpenedSignIn model) |> Query.find [ id "hub-signin" ] |> Query.has [ id "signin", id "signin-email" ]
                    ]
                    ()
        ]



-- A STRANGER


aStranger : Test
aStranger =
    describe "a stranger"
        [ test "is told what this is, and offered one to try" <|
            \_ ->
                rendered (loaded nobodyJson)
                    |> Expect.all
                        [ Query.find [ id "hub-about" ] >> Query.has [ text "Every mistake the engine finds", text "share any puzzle with a link" ]
                        , Query.find [ id "hub-try-one" ] >> Query.has [ text "TRY ONE" ]
                        , Query.hasNot [ id "hub-practice" ]
                        , Query.has [ id "hub-signin-open" ]
                        ]
        , test "TRY ONE asks for a puzzle, and goes to the one it is given" <|
            \_ ->
                let
                    model =
                        loaded nobodyJson |> send PressedTryOne
                in
                Expect.all
                    [ \_ -> rendered model |> Query.find [ id "hub-try-one" ] |> Query.has [ attribute (Html.Attributes.disabled True) ]
                    , \_ -> out (GotRandom (Ok { id = "eeeeeeee", kind = "move", prompt = "White to play 3-1. What's your play?" })) model |> Expect.equal (Go "/puzzles/eeeeeeee")
                    ]
                    ()
        , test "an empty pool is a sentence under the button, not a dead end" <|
            \_ ->
                loaded nobodyJson
                    |> send PressedTryOne
                    |> send (GotRandom (Err (Api.ApiError { code = "not_found", message = "There are no puzzles yet." })))
                    |> rendered
                    |> Expect.all
                        [ Query.find [ id "hub-note" ] >> Query.has [ text "There are no puzzles yet." ]
                        , Query.find [ id "hub-try-one" ] >> Query.hasNot [ attribute (Html.Attributes.disabled True) ]
                        ]
        ]
