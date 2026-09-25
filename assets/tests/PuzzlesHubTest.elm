module PuzzlesHubTest exposing (suite)

{-| The practice home on the server's three answers: an account's deck,
a guest's mistakes, and nobody's empty list.

For an account that is the one-deck card: which tier is in front, what
it says when the tier still has work and when it is in good shape, the
quiet rows and what tapping one does, and what FIX ONE hands the shell.
Plus what TRY ONE does with a puzzle and with an empty pool.
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


{-| Very bad has work (five due), so it leads and FIX ONE is offered.
-}
accountJson : String
accountJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4. What's your play?","due":true},{"id":"bbbbbbbb","kind":"double","prompt":"White to play. Double?","due":false}],"cursor":null,"counts":{"due":12,"new_today":3,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":2},"severity":[{"grade":"very_bad","total":61,"in_progress":30,"patched":23,"due":5,"new_left":3},{"grade":"bad","total":118,"in_progress":44,"patched":40,"due":7,"new_left":0},{"grade":"doubtful","total":96,"in_progress":9,"patched":12,"due":0,"new_left":0}],"lead":"very_bad","patched_level":4,"game":null}"""


{-| Very bad is in good shape -- nothing due, nothing new left today --
while bad still has seven due, so the card says so and offers bad.
-}
goodShapeJson : String
goodShapeJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":7,"new_today":0,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":5},"severity":[{"grade":"very_bad","total":61,"in_progress":30,"patched":23,"due":0,"new_left":0},{"grade":"bad","total":118,"in_progress":44,"patched":40,"due":7,"new_left":0},{"grade":"doubtful","total":96,"in_progress":9,"patched":12,"due":0,"new_left":0}],"lead":"bad","patched_level":4,"game":null}"""


{-| Nothing anywhere is due and the day's new ones are done: one warm
line, and nothing to press.
-}
allClearJson : String
allClearJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":0,"new_today":0,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":5},"severity":[{"grade":"very_bad","total":61,"in_progress":0,"patched":61,"due":0,"new_left":0},{"grade":"bad","total":118,"in_progress":44,"patched":40,"due":0,"new_left":0},{"grade":"doubtful","total":96,"in_progress":9,"patched":12,"due":0,"new_left":0}],"lead":"very_bad","patched_level":4,"game":null}"""


{-| An account with a deck and no band behind any card of it.
-}
bandlessJson : String
bandlessJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4. What's your play?","due":true}],"cursor":null,"counts":{"due":1,"new_today":3,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":5},"severity":[{"grade":"very_bad","total":0,"in_progress":0,"patched":0,"due":0,"new_left":0},{"grade":"bad","total":0,"in_progress":0,"patched":0,"due":0,"new_left":0},{"grade":"doubtful","total":0,"in_progress":0,"patched":0,"due":0,"new_left":0}],"lead":null,"patched_level":4,"game":null}"""


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
                    |> Expect.equal (Ok ( [ "aaaaaaaa", "bbbbbbbb" ], Just { due = 12, newToday = 3, newTomorrow = 3, deck = 231 }, Nothing ))
        , test "and which tier to lead with, with each tier's work" <|
            \_ ->
                parse accountJson
                    |> Result.map (\p -> ( p.lead, List.map (\b -> ( b.grade, b.due, b.newLeft )) p.severity ))
                    |> Expect.equal
                        (Ok
                            ( Just "very_bad"
                            , [ ( "very_bad", 5, 3 ), ( "bad", 7, 0 ), ( "doubtful", 0, 0 ) ]
                            )
                        )
        , test "a guest's: the list and what is theirs" <|
            \_ ->
                parse guestJson
                    |> Result.map (\p -> ( List.map .due p.puzzles, p.counts, p.mistakes ))
                    |> Expect.equal (Ok ( [ False, False ], Nothing, Just { puzzles = 23, games = 4 } ))
        , test "nobody's: nothing, and not an error" <|
            \_ ->
                parse nobodyJson
                    |> Expect.equal (Ok { puzzles = [], counts = Nothing, mistakes = Nothing, today = Nothing, severity = [], lead = Nothing, patchedLevel = 0 })
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
        [ test "one tier in front: its mark, what is left to fix, one button" <|
            \_ ->
                rendered (loaded accountJson)
                    |> Expect.all
                        [ Query.find [ id "hub-tier" ]
                            >> Query.has [ attribute (Html.Attributes.attribute "data-tier" "very_bad") ]
                        , Query.find [ id "hub-tier" ] >> Query.has [ text "??", text "Very bad moves" ]
                        , Query.find [ id "hub-tier-left" ] >> Query.has [ text "38 left to fix" ]
                        , Query.find [ id "hub-tier-patched" ] >> Query.has [ text "23 patched" ]
                        , Query.find [ id "hub-fix-one" ] >> Query.has [ text "FIX ONE" ]
                        , Query.hasNot [ id "hub-try-one" ]
                        , Query.hasNot [ id "hub-unsaved" ]

                        -- One bar, not three: the other tiers are rows.
                        , Query.findAll [ attribute (Html.Attributes.attribute "data-total" "61") ]
                            >> Query.count (Expect.equal 1)
                        , Query.findAll [ attribute (Html.Attributes.attribute "data-total" "118") ]
                            >> Query.count (Expect.equal 0)
                        ]
        , test "the other tiers are quiet rows, with what is left in each" <|
            \_ ->
                rendered (loaded accountJson)
                    |> Query.find [ id "hub-tier-rows" ]
                    |> Expect.all
                        [ Query.find [ id "hub-tier-row-bad" ] >> Query.has [ text "?", text "Bad moves", text "78 left" ]
                        , Query.find [ id "hub-tier-row-doubtful" ] >> Query.has [ text "?!", text "Dubious moves", text "84 left" ]

                        -- The tier already in front is not also a row.
                        , Query.hasNot [ id "hub-tier-row-very_bad" ]
                        ]
        , test "tapping a quiet row moves the card onto that tier" <|
            \_ ->
                let
                    model =
                        loaded accountJson
                in
                Expect.all
                    [ \_ ->
                        rendered model
                            |> Query.find [ id "hub-tier-row-bad" ]
                            |> Event.simulate Event.click
                            |> Event.expect (PickedTier "bad")
                    , \_ ->
                        rendered (send (PickedTier "bad") model)
                            |> Expect.all
                                [ Query.find [ id "hub-tier" ]
                                    >> Query.has [ attribute (Html.Attributes.attribute "data-tier" "bad") ]
                                , Query.find [ id "hub-tier-left" ] >> Query.has [ text "78 left to fix" ]
                                , Query.find [ id "hub-tier-row-very_bad" ] >> Query.has [ text "38 left" ]
                                ]
                    ]
                    ()
        , test "FIX ONE asks for that tier's queue, and runs it as that tier" <|
            \_ ->
                let
                    model =
                        loaded accountJson
                in
                Expect.all
                    [ \_ ->
                        rendered model
                            |> Query.find [ id "hub-fix-one" ]
                            |> Event.simulate Event.click
                            |> Event.expect (PressedFixOne "very_bad")
                    , -- The run is handed the day the page was told, so
                      -- the count opens where the hub left it.
                      \_ ->
                        model
                            |> send (PressedFixOne "very_bad")
                            |> out (GotBand "very_bad" (parse accountJson))
                            |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ] (Just { done = 2 }) (Just "very_bad"))
                    ]
                    ()
        , test "a tier whose queue came back empty says so rather than starting nothing" <|
            \_ ->
                loaded accountJson
                    |> send (PressedFixOne "very_bad")
                    |> send (GotBand "very_bad" (parse goodShapeJson))
                    |> rendered
                    |> Query.find [ id "hub-note" ]
                    |> Query.has [ text "every mistake of yours" ]
        , test "a tier in good shape says so warmly and offers the next one down" <|
            \_ ->
                rendered (loaded goodShapeJson)
                    |> Expect.all
                        [ Query.find [ id "hub-tier" ]
                            >> Query.has [ attribute (Html.Attributes.attribute "data-tier" "very_bad") ]
                        , Query.find [ id "hub-tier-good" ]
                            >> Query.has [ text "Nice — your ?? moves are in good shape." ]
                        , Query.find [ id "hub-tier-why" ] >> Query.has [ text "More of them tomorrow." ]
                        , Query.find [ id "hub-tier-next" ] >> Query.has [ text "WORK ON ? BAD MOVES" ]
                        , Query.hasNot [ id "hub-fix-one" ]
                        , Query.hasNot [ id "hub-tier-left" ]
                        ]
        , test "and that offer moves the card onto the tier that has the work" <|
            \_ ->
                let
                    model =
                        loaded goodShapeJson
                in
                Expect.all
                    [ \_ ->
                        rendered model
                            |> Query.find [ id "hub-tier-next" ]
                            |> Event.simulate Event.click
                            |> Event.expect (PickedTier "bad")
                    , \_ ->
                        rendered (send (PickedTier "bad") model)
                            |> Expect.all
                                [ Query.find [ id "hub-tier-left" ] >> Query.has [ text "78 left to fix" ]
                                , Query.find [ id "hub-fix-one" ] >> Query.has [ text "FIX ONE" ]
                                ]
                    ]
                    ()
        , test "every tier in good shape: one warm line, and nothing to press" <|
            \_ ->
                rendered (loaded allClearJson)
                    |> Expect.all
                        [ Query.find [ id "hub-tier-good" ]
                            >> Query.has [ text "Nice work — every one of your mistakes is in good shape." ]
                        , Query.hasNot [ id "hub-fix-one" ]
                        , Query.hasNot [ id "hub-tier-next" ]
                        , Query.findAll [ Test.Html.Selector.tag "button" ] >> Query.count (Expect.equal 0)

                        -- The rows are still a record of where things
                        -- stand; they are simply not buttons.
                        , Query.find [ id "hub-tier-row-bad" ] >> Query.has [ text "78 left" ]
                        ]
        , -- A deck with cards in it and no band behind any of them: an
          -- old row, or a game whose sources went. The card has nothing
          -- to name, so the deck is offered whole rather than blank.
          test "a deck no band can be read off is offered whole, not as an empty card" <|
            \_ ->
                rendered (loaded bandlessJson)
                    |> Expect.all
                        [ Query.hasNot [ id "hub-tier" ]
                        , Query.find [ id "hub-headline" ] >> Query.has [ text "231 of your mistakes" ]
                        , Query.find [ id "hub-practice" ] >> Query.has [ text "PRACTICE" ]
                        ]
        , test "an account with an empty deck is offered what a stranger is" <|
            \_ ->
                rendered (loaded emptyDeckJson)
                    |> Expect.all
                        [ Query.has [ id "hub-try-one" ]
                        , Query.hasNot [ id "hub-fix-one" ]
                        , Query.hasNot [ id "hub-tier" ]
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
                    |> Expect.equal (StartRun [ "cccccccc", "dddddddd" ] Nothing Nothing)
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
