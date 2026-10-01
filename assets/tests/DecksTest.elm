module DecksTest exposing (suite)

{-| The sets on offer to everyone -- the openings and the replies to them
-- on the practice home: what each visitor is offered, what a press asks
the server for, and what it hands the shell. And the words a set is said
in, which are its own and never a mistake's.
-}

import Api
import Api.Decks as Decks
import Expect
import Test exposing (Test, describe, test)
import Ui.Decks


suite : Test
suite =
    describe "the sets on offer"
        [ decoding
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
        , test "a set in its three states, which is its grid's legend" <|
            \_ ->
                Ui.Decks.stateLine { total = 15, untouched = 5, inProgress = 6, patched = 4 }
                    |> Expect.equal "4 learned · 6 in progress · 5 to start · of 15"
        , test "its size, what START means at its pace, and what TRY is" <|
            \_ ->
                Expect.all
                    [ \_ -> Ui.Decks.sizeEyebrow 315 |> Expect.equal "315 POSITIONS"
                    , \_ -> Ui.Decks.sizeLine 15 |> Expect.equal "15 positions to learn"
                    , \_ -> Ui.Decks.startLine 5 |> Expect.equal "Five new a day, and each comes back until you know it."
                    , \_ -> Ui.Decks.startLine 10 |> Expect.equal "Ten new a day, and each comes back until you know it."
                    , \_ -> Ui.Decks.tryLine |> Expect.equal "Played in order, nothing kept. Sign in to keep your place."
                    , \_ -> Ui.Decks.rowLeft 11 |> Expect.equal "11 left"
                    , \_ -> Ui.Decks.rowLeft 0 |> Expect.equal "All learned"
                    ]
                    ()
        , test "nothing a set says calls it a mistake, a card or a deck" <|
            \_ ->
                [ Ui.Decks.standingLine (standing 11 4)
                , Ui.Decks.stateLine { total = 15, untouched = 5, inProgress = 6, patched = 4 }
                , Ui.Decks.sizeEyebrow 15
                , Ui.Decks.sizeLine 15
                , Ui.Decks.startLine 5
                , Ui.Decks.tryLine
                , Ui.Decks.rowLeft 3
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
