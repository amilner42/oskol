module DecksTest exposing (suite)

{-| The sets on offer to everyone -- the openings and the replies to them
-- on the practice home: what each visitor is offered, what a press asks
the server for, and what it hands the shell. And the words a set is said
in, which are its own and never a mistake's.
-}

import Api
import Api.Decks as Decks
import Expect
import Page.Puzzles as Hub exposing (Msg(..), Out(..))
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (id, text)
import Ui.Decks


suite : Test
suite =
    describe "the sets on offer"
        [ decoding
        , onTheHub
        , words
        ]



-- THE SERVER'S ANSWERS


{-| An account that has added the openings (11 left, 4 learned, three
due) and not the replies.
-}
accountListJson : String
accountListJson =
    """{"ok":true,"decks":[{"id":"openings","name":"Openings","blurb":"The fifteen opening rolls, and the play for each.","size":15,"standing":{"joined":true,"total":15,"in_progress":5,"patched":4,"left":11,"due":3,"new_left":0}},{"id":"opening_replies","name":"Opening replies","blurb":"Your first roll after each opening.","size":315,"standing":{"joined":false,"total":0,"in_progress":0,"patched":0,"left":0,"due":0,"new_left":0}}],"patched_level":4}"""


{-| The openings added, and nothing to do today.
-}
restingListJson : String
restingListJson =
    """{"ok":true,"decks":[{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":{"joined":true,"total":15,"in_progress":11,"patched":4,"left":11,"due":0,"new_left":0}}],"patched_level":4}"""


guestListJson : String
guestListJson =
    """{"ok":true,"decks":[{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":null}],"patched_level":4}"""


sessionJson : String
sessionJson =
    """{"ok":true,"deck":{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":{"joined":true,"total":15,"in_progress":5,"patched":4,"left":11,"due":3,"new_left":0}},"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 2-1. What's your play?","due":true},{"id":"bbbbbbbb","kind":"move","prompt":"White to play 3-1. What's your play?","due":true}],"today":{"done":1}}"""


emptySessionJson : String
emptySessionJson =
    """{"ok":true,"deck":{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":{"joined":true,"total":15,"in_progress":11,"patched":4,"left":11,"due":0,"new_left":0}},"puzzles":[],"today":{"done":3}}"""


list : String -> Result Api.Error (List Decks.Deck)
list =
    Api.parseBody Decks.listDecoder


session : String -> Result Api.Error Decks.Session
session =
    Api.parseBody Decks.sessionDecoder


arie : Session.Session
arie =
    Session.withUser (Just { email = "arie@example.com", name = Just "arie" }) Session.empty


hub : Session.Session -> String -> Hub.Model
hub who json =
    Hub.init who { tz = "Europe/Paris" }
        |> Tuple.first
        |> send (GotDecks (list json))


send : Msg -> Hub.Model -> Hub.Model
send msg model =
    Hub.update msg model |> (\( next, _, _ ) -> next)


out : Msg -> Hub.Model -> Out
out msg model =
    Hub.update msg model |> (\( _, _, o ) -> o)


rendered : Hub.Model -> Query.Single Msg
rendered model =
    Hub.view model |> Query.fromHtml


openings : String -> Decks.Deck
openings json =
    case list json of
        Ok (first :: _) ->
            first

        _ ->
            Debug.todo "the fixture has a first set"



-- DECODING


decoding : Test
decoding =
    describe "decoding"
        [ test "a list reads each set and an account's standing on it" <|
            \_ ->
                case list accountListJson of
                    Ok [ first, second ] ->
                        Expect.all
                            [ \_ -> Expect.equal first.name "Openings"
                            , \_ -> Expect.equal (Maybe.map .left first.standing) (Just 11)
                            , \_ -> Expect.equal (Maybe.map .joined second.standing) (Just False)
                            , \_ -> Expect.equal second.size 315
                            ]
                            ()

                    other ->
                        Expect.fail (Debug.toString other)
        , test "a guest's standing is none at all" <|
            \_ ->
                list guestListJson
                    |> Result.map (List.map .standing)
                    |> Expect.equal (Ok [ Nothing ])
        , test "a session reads its puzzles and the day" <|
            \_ ->
                session sessionJson
                    |> Result.map (\s -> ( List.map .id s.puzzles, s.today ))
                    |> Expect.equal (Ok ( [ "aaaaaaaa", "bbbbbbbb" ], Just { done = 1 } ))
        , test "a standing missing a count is refused rather than guessed" <|
            \_ ->
                list """{"ok":true,"decks":[{"id":"o","name":"O","blurb":"b","size":1,"standing":{"joined":true}}]}"""
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]



-- THE HUB


onTheHub : Test
onTheHub =
    describe "on the practice home"
        [ test "nothing is drawn until the sets land, and nothing while there are none" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Hub.init arie { tz = "" }
                            |> Tuple.first
                            |> rendered
                            |> Query.findAll [ id "decks" ]
                            |> Query.count (Expect.equal 0)
                    , \_ ->
                        hub arie """{"ok":true,"decks":[],"patched_level":4}"""
                            |> rendered
                            |> Query.findAll [ id "decks" ]
                            |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "an account practises a set it added and starts one it has not" <|
            \_ ->
                let
                    rows =
                        hub arie accountListJson |> rendered
                in
                Expect.all
                    [ \_ -> rows |> Query.find [ id "deck-openings-standing" ] |> Query.has [ text "11 left to learn · 4 learned" ]
                    , \_ -> rows |> Query.find [ id "deck-openings-go" ] |> Query.has [ text "PRACTICE" ]
                    , \_ -> rows |> Query.find [ id "deck-opening_replies-go" ] |> Query.has [ text "START" ]
                    , \_ -> rows |> Query.findAll [ id "deck-opening_replies-standing" ] |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "a set with nothing to do today says so and has nothing to press" <|
            \_ ->
                let
                    rows =
                        hub arie restingListJson |> rendered
                in
                Expect.all
                    [ \_ -> rows |> Query.find [ id "deck-openings-resting" ] |> Query.has [ text Ui.Decks.restingLine ]
                    , \_ -> rows |> Query.findAll [ id "deck-openings-go" ] |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "a guest tries a set" <|
            \_ ->
                hub Session.empty guestListJson
                    |> rendered
                    |> Query.find [ id "deck-openings-go" ]
                    |> Query.has [ text "TRY" ]
        , test "pressing a set hands the shell a run of it, named" <|
            \_ ->
                let
                    model =
                        hub arie accountListJson
                in
                Expect.all
                    [ \_ ->
                        rendered model
                            |> Query.find [ id "deck-openings-go" ]
                            |> Event.simulate Event.click
                            |> Event.expect (PressedDeck (openings accountListJson))
                    , \_ ->
                        model
                            |> send (PressedDeck (openings accountListJson))
                            |> out (GotDeckSession { id = "openings", name = "Openings" } (session sessionJson))
                            |> Expect.equal (StartDeckRun [ "aaaaaaaa", "bbbbbbbb" ] (Just { done = 1 }) { id = "openings", name = "Openings" })
                    ]
                    ()
        , test "a session that came back empty says so rather than starting nothing" <|
            \_ ->
                let
                    after =
                        hub arie accountListJson
                            |> send (PressedDeck (openings accountListJson))
                            |> send (GotDeckSession { id = "openings", name = "Openings" } (session emptySessionJson))
                in
                Expect.all
                    [ \_ -> rendered after |> Query.find [ id "deck-openings-resting" ] |> Query.has [ text Ui.Decks.restingLine ]

                    -- The row says it, so nothing says it twice.
                    , \_ -> rendered after |> Query.findAll [ id "decks-note" ] |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "a press that fails says why, in the sets' own card" <|
            \_ ->
                hub arie accountListJson
                    |> send (PressedDeck (openings accountListJson))
                    |> send (GotDeckSession { id = "openings", name = "Openings" } (Api.parseBody Decks.sessionDecoder """{"ok":false,"error":{"code":"not_found","message":"There is no such set of puzzles."}}"""))
                    |> rendered
                    |> Query.find [ id "decks-note" ]
                    |> Query.has [ text "There is no such set of puzzles." ]
        ]



-- THE WORDS


words : Test
words =
    describe "the words"
        [ test "left first, learned beside it once there is some, all of them at the end" <|
            \_ ->
                Expect.all
                    [ \_ -> Ui.Decks.standingLine (standing 15 0) |> Expect.equal "15 left to learn"
                    , \_ -> Ui.Decks.standingLine (standing 11 4) |> Expect.equal "11 left to learn · 4 learned"
                    , \_ -> Ui.Decks.standingLine (standing 0 15) |> Expect.equal "All 15 learned"
                    ]
                    ()
        , test "a run of one is a whole session, in a set's words" <|
            \_ ->
                Expect.all
                    [ \_ -> Ui.Decks.runSummary { right = 1, total = 1 } |> Expect.equal "One right. That is how it is done."
                    , \_ -> Ui.Decks.runSummary { right = 3, total = 5 } |> Expect.equal "3 of 5 right"
                    , \_ -> Ui.Decks.runSummary { right = 0, total = 1 } |> Expect.equal "One played. It comes back tomorrow."
                    , \_ -> Ui.Decks.learnedRun 0 |> Expect.equal Nothing
                    , \_ -> Ui.Decks.learnedRun 2 |> Expect.equal (Just "You learned 2 of them.")
                    , \_ -> Ui.Decks.doneToday 3 |> Expect.equal "3 practised today"
                    ]
                    ()
        , test "nothing a set says calls it a mistake, a card or a deck" <|
            \_ ->
                [ Ui.Decks.standingLine (standing 11 4)
                , Ui.Decks.restingLine
                , Ui.Decks.endSignIn
                , Ui.Decks.runSummary { right = 0, total = 1 }
                , Ui.Decks.doneToday 2
                ]
                    |> List.filter (\line -> List.any (\word -> String.contains word (String.toLower line)) [ "mistake", "card", "deck", "fix" ])
                    |> Expect.equal []
        ]


standing : Int -> Int -> Decks.Standing
standing left patched =
    { joined = True, total = left + patched, inProgress = left, patched = patched, left = left, due = 0, newLeft = 0 }
