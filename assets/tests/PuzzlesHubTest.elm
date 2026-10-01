module PuzzlesHubTest exposing (suite)

{-| The practice home on `GET /papi/practice/decks`: five decks, one in
front and four behind it, for an account, a guest and a stranger.

For an account: the deck in front (the server's lead, or the one tapped),
its button in each of its states -- FIX ONE, KEEP GOING, PRACTICE ANYWAY,
START, PRACTICE -- and what each press asks the server for and hands the
shell; the rows, and tapping one; the cost lines there and not there; the
grid and the ring. A fresh account has the openings in front. A guest has
their worst tier and PRACTICE; a stranger TRY ONE and the five as rows.
-}

import Api
import Api.Decks as Decks
import Api.Practice as Practice
import Api.PracticeDecks as PracticeDecks
import Expect
import Html.Attributes
import Page.Puzzles as Hub exposing (Msg(..), Out(..))
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)
import Ui.Deck exposing (Action(..))
import Ui.Mistakes as Mistakes


suite : Test
suite =
    describe "the practice home"
        [ decoding
        , anAccount
        , theButton
        , costs
        , aFreshAccount
        , aGuest
        , aStranger
        ]



-- THE SERVER'S ANSWERS


standing : { total : Int, untouched : Int, inProgress : Int, patched : Int, due : Int, newLeft : Int, done : Int } -> String
standing s =
    let
        n =
            String.fromInt

        -- untouched sit on the bottom rung with the ones missed there;
        -- in progress on 1, patched on 4.
        levels =
            [ s.untouched, s.inProgress, 0, 0, s.patched, 0, 0, 0 ]
    in
    "{\"total\":"
        ++ n s.total
        ++ ",\"untouched\":"
        ++ n s.untouched
        ++ ",\"in_progress\":"
        ++ n s.inProgress
        ++ ",\"patched\":"
        ++ n s.patched
        ++ ",\"due\":"
        ++ n s.due
        ++ ",\"new_left\":"
        ++ n s.newLeft
        ++ ",\"done_today\":"
        ++ n s.done
        ++ ",\"target_today\":"
        ++ n (s.done + s.due + s.newLeft)
        ++ ",\"levels\":["
        ++ String.join "," (List.map n levels)
        ++ "]}"


deck : { id : String, slug : String, kind : String, name : String, mark : String, size : Int, pace : Int, joined : Bool, standing : String, cost : String } -> String
deck d =
    "{\"id\":\""
        ++ d.id
        ++ "\",\"slug\":\""
        ++ d.slug
        ++ "\",\"kind\":\""
        ++ d.kind
        ++ "\",\"name\":\""
        ++ d.name
        ++ "\",\"mark\":\""
        ++ d.mark
        ++ "\",\"blurb\":\"\",\"size\":"
        ++ String.fromInt d.size
        ++ ",\"pace\":"
        ++ String.fromInt d.pace
        ++ ",\"joined\":"
        ++ (if d.joined then
                "true"

            else
                "false"
           )
        ++ ",\"standing\":"
        ++ d.standing
        ++ ",\"cost\":"
        ++ d.cost
        ++ "}"


tier : String -> String -> String -> String -> Int -> String -> String -> String
tier id slug name mark size st cost =
    deck { id = id, slug = slug, kind = "mistakes", name = name, mark = mark, size = size, pace = 3, joined = size > 0, standing = st, cost = cost }


set : String -> String -> Int -> Int -> Bool -> String -> String
set id name size pace joined st =
    deck { id = id, slug = String.replace "_" "-" id, kind = "set", name = name, mark = "", size = size, pace = pace, joined = joined, standing = st, cost = "null" }


veryBadCost : String
veryBadCost =
    """{"games":11,"lost":11.33,"lost_patched":0.66,"pr":8.3,"pr_without":4.8,"pr_patched":7.7}"""


catalog : { decks : List String, lead : String, today : String, streak : Int, costAll : String, mistakes : String } -> String
catalog c =
    "{\"ok\":true,\"decks\":["
        ++ String.join "," c.decks
        ++ "],\"lead\":"
        ++ c.lead
        ++ ",\"today\":"
        ++ c.today
        ++ ",\"streak\":"
        ++ String.fromInt c.streak
        ++ ",\"patched_level\":4,\"cost_all\":"
        ++ c.costAll
        ++ ",\"mistakes\":"
        ++ c.mistakes
        ++ "}"


{-| The very bad moves have work today (four due, three new), two already
answered; the openings are added, the replies are not.
-}
accountJson : String
accountJson =
    accountWith
        (standing { total = 44, untouched = 20, inProgress = 18, patched = 6, due = 4, newLeft = 3, done = 2 })
        veryBadCost


accountWith : String -> String -> String
accountWith veryBad cost =
    catalog
        { decks =
            [ tier "very_bad" "very-bad" "Very bad moves" "??" 44 veryBad cost
            , tier "bad" "bad" "Bad moves" "?" 71 (standing { total = 71, untouched = 45, inProgress = 24, patched = 2, due = 9, newLeft = 3, done = 0 }) "null"
            , tier "doubtful" "dubious" "Dubious moves" "?!" 141 (standing { total = 141, untouched = 123, inProgress = 18, patched = 0, due = 0, newLeft = 3, done = 0 }) "null"
            , set "openings" "Openings" 15 5 True (standing { total = 15, untouched = 8, inProgress = 3, patched = 4, due = 2, newLeft = 5, done = 0 })
            , set "opening_replies" "Opening replies" 315 10 False (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 })
            ]
        , lead = "\"very_bad\""
        , today = "{\"done\":2}"
        , streak = 5
        , costAll = """{"pr":8.3,"pr_without":0.2,"pr_patched":7.7}"""
        , mistakes = "null"
        }


{-| Today's set done for the very bad moves; seventeen still unstarted.
-}
keepGoingJson : String
keepGoingJson =
    accountWith (standing { total = 44, untouched = 17, inProgress = 21, patched = 6, due = 0, newLeft = 0, done = 5 }) veryBadCost


{-| Every very bad move started, none due.
-}
scheduledJson : String
scheduledJson =
    accountWith (standing { total = 44, untouched = 0, inProgress = 38, patched = 6, due = 0, newLeft = 0, done = 0 }) veryBadCost


{-| The same account under three graded games: no rating, so no cost.
-}
noCostJson : String
noCostJson =
    catalog
        { decks =
            [ tier "very_bad" "very-bad" "Very bad moves" "??" 44 (standing { total = 44, untouched = 20, inProgress = 18, patched = 6, due = 4, newLeft = 3, done = 2 }) "null"
            , tier "bad" "bad" "Bad moves" "?" 0 (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 }) "null"
            , tier "doubtful" "dubious" "Dubious moves" "?!" 0 (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 }) "null"
            , set "openings" "Openings" 15 5 False (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 })
            ]
        , lead = "\"very_bad\""
        , today = "{\"done\":0}"
        , streak = 0
        , costAll = "null"
        , mistakes = "null"
        }


freshJson : String
freshJson =
    catalog
        { decks =
            [ tier "very_bad" "very-bad" "Very bad moves" "??" 0 (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 }) "null"
            , tier "bad" "bad" "Bad moves" "?" 0 (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 }) "null"
            , tier "doubtful" "dubious" "Dubious moves" "?!" 0 (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 }) "null"
            , set "openings" "Openings" 15 5 False (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 })
            , set "opening_replies" "Opening replies" 315 10 False (standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0 })
            ]
        , lead = "null"
        , today = "{\"done\":0}"
        , streak = 0
        , costAll = "null"
        , mistakes = "null"
        }


guestJson : String
guestJson =
    catalog
        { decks =
            [ tier "very_bad" "very-bad" "Very bad moves" "??" 0 "null" "null"
            , tier "bad" "bad" "Bad moves" "?" 21 "null" "null"
            , tier "doubtful" "dubious" "Dubious moves" "?!" 2 "null" "null"
            , set "openings" "Openings" 15 5 False "null"
            , set "opening_replies" "Opening replies" 315 10 False "null"
            ]
        , lead = "\"bad\""
        , today = "null"
        , streak = 0
        , costAll = "null"
        , mistakes = """{"puzzles":23,"games":4}"""
        }


strangerJson : String
strangerJson =
    catalog
        { decks =
            [ tier "very_bad" "very-bad" "Very bad moves" "??" 0 "null" "null"
            , tier "bad" "bad" "Bad moves" "?" 0 "null" "null"
            , tier "doubtful" "dubious" "Dubious moves" "?!" 0 "null" "null"
            , set "openings" "Openings" 15 5 False "null"
            , set "opening_replies" "Opening replies" 315 10 False "null"
            ]
        , lead = "null"
        , today = "null"
        , streak = 0
        , costAll = "null"
        , mistakes = "null"
        }


bandJson : String
bandJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4. What's your play?","due":true},{"id":"bbbbbbbb","kind":"double","prompt":"White to play. Double?","due":false}],"cursor":null,"counts":{"due":12,"new_today":3,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":2},"severity":[],"lead":"very_bad","patched_level":4,"game":null}"""


emptyBandJson : String
emptyBandJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":0,"new_today":0,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":5},"severity":[],"lead":null,"patched_level":4,"game":null}"""


setSessionJson : String
setSessionJson =
    """{"ok":true,"deck":{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":{"joined":true,"total":15,"in_progress":5,"patched":4,"left":11,"due":3,"new_left":0}},"puzzles":[{"id":"oooooooo","kind":"move","prompt":"White to play 2-1. What's your play?","due":true}],"today":{"done":1}}"""


parse : String -> Result Api.Error PracticeDecks.Catalog
parse =
    Api.parseBody PracticeDecks.catalogDecoder


arie : Session.Session
arie =
    Session.withUser (Just { email = "arie@example.com", name = Just "arie" }) Session.empty


loaded : String -> Hub.Model
loaded json =
    Hub.init arie { tz = "Europe/Paris" }
        |> Tuple.first
        |> send (GotCatalog (parse json))


send : Msg -> Hub.Model -> Hub.Model
send msg model =
    Hub.update msg model |> (\( next, _, _ ) -> next)


out : Msg -> Hub.Model -> Out
out msg model =
    Hub.update msg model |> (\( _, _, o ) -> o)


rendered : Hub.Model -> Query.Single Msg
rendered model =
    Hub.view model |> Query.fromHtml


deckOf : String -> String -> PracticeDecks.Deck
deckOf json id =
    case parse json of
        Ok c ->
            case List.filter (\d -> d.id == id) c.decks of
                d :: _ ->
                    d

                [] ->
                    Debug.todo ("no deck " ++ id)

        Err _ ->
            Debug.todo "the fixture parses"


card : String -> Query.Single Msg
card json =
    loaded json |> rendered |> Query.find [ id "hub-card" ]


dataAttr : String -> String -> Test.Html.Selector.Selector
dataAttr name value =
    attribute (Html.Attributes.attribute name value)



-- DECODING


decoding : Test
decoding =
    describe "decoding"
        [ test "the five, in order, each with its kind, size, pace and standing" <|
            \_ ->
                parse accountJson
                    |> Result.map (\c -> List.map (\d -> ( d.id, d.size, d.pace )) c.decks)
                    |> Expect.equal
                        (Ok
                            [ ( "very_bad", 44, 3 )
                            , ( "bad", 71, 3 )
                            , ( "doubtful", 141, 3 )
                            , ( "openings", 15, 5 )
                            , ( "opening_replies", 315, 10 )
                            ]
                        )
        , test "the day, the streak, the lead and the cost of every mistake" <|
            \_ ->
                parse accountJson
                    |> Result.map (\c -> ( ( c.lead, c.today, c.streak ), c.costAll ))
                    |> Expect.equal (Ok ( ( Just "very_bad", Just 2, 5 ), Just { pr = 8.3, prWithout = 0.2, prPatched = 7.7 } ))
        , test "a tier's standing, its levels and its cost" <|
            \_ ->
                deckOf accountJson "very_bad"
                    |> (\d -> ( Maybe.map (\s -> ( s.untouched, s.targetToday, s.levels )) d.standing, Maybe.map .prWithout d.cost ))
                    |> Expect.equal ( Just ( 20, 9, [ 20, 18, 0, 0, 6, 0, 0, 0 ] ), Just 4.8 )
        , test "a guest's: no standing, and what is theirs" <|
            \_ ->
                parse guestJson
                    |> Result.map (\c -> ( List.map .standing c.decks |> List.all ((==) Nothing), c.mistakes, c.today ))
                    |> Expect.equal (Ok ( True, Just { puzzles = 23, games = 4 }, Nothing ))
        , test "a count that is not a number is refused, not defaulted" <|
            \_ ->
                parse (String.replace "\"size\":44" "\"size\":\"44\"" accountJson)
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "a sixth kind of deck is refused rather than guessed at" <|
            \_ ->
                parse (String.replace "\"kind\":\"set\"" "\"kind\":\"quiz\"" accountJson)
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "an answer without the newer keys still reads" <|
            \_ ->
                parse (String.replace ",\"pace\":3" "" accountJson |> String.replace ",\"mistakes\":null" "")
                    |> Result.map (\c -> List.map .pace c.decks |> List.take 1)
                    |> Expect.equal (Ok [ 0 ])
        , test "the three visitors, off the answer" <|
            \_ ->
                [ accountJson, freshJson, guestJson, strangerJson ]
                    |> List.map (parse >> Result.map Hub.visitor)
                    |> Expect.equal
                        [ Ok Hub.AnAccount
                        , Ok Hub.AnAccount
                        , Ok (Hub.AGuest { puzzles = 23, games = 4 })
                        , Ok Hub.AStranger
                        ]
        ]



-- AN ACCOUNT


anAccount : Test
anAccount =
    describe "an account"
        [ test "OPEN on the card goes to the deck's own page, and follows the deck tapped in" <|
            \_ ->
                Expect.all
                    [ \_ -> card accountJson |> Query.find [ id "hub-open" ] |> Query.has [ attribute (Html.Attributes.href "/practice/very-bad") ]
                    , \_ ->
                        loaded accountJson
                            |> send (PickedDeck "opening_replies")
                            |> rendered
                            |> Query.find [ id "hub-open" ]
                            |> Query.has [ attribute (Html.Attributes.href "/practice/opening-replies") ]
                    ]
                    ()
        , test "the day: how long it has kept at it, and what today has come to" <|
            \_ ->
                loaded accountJson
                    |> rendered
                    |> Query.find [ id "hub-day" ]
                    |> Query.has [ text "5 days running · 2 practised today" ]
        , test "the lead in front: its mark, its name, its ring, FIX ONE" <|
            \_ ->
                card accountJson
                    |> Expect.all
                        [ Query.has [ dataAttr "data-deck" "very_bad", dataAttr "data-action" "fix-one" ]
                        , Query.has [ text "??" ]
                        , Query.find [ id "hub-name" ] >> Query.has [ text "Very bad moves" ]
                        , Query.find [ id "hub-go" ] >> Query.has [ text "FIX ONE" ]
                        , Query.find [ dataAttr "data-target" "9" ] >> Query.has [ dataAttr "data-done" "2", dataAttr "data-target" "9" ]
                        , Query.find [ id "hub-quiet" ] >> Query.has [ text "4 due now · 3 new today" ]
                        ]
        , test "the grid: a square a mistake, patched first, coloured by rung" <|
            \_ ->
                card accountJson
                    |> Query.find [ tag "svg", Test.Html.Selector.attribute (Html.Attributes.attribute "data-count" "44") ]
                    |> Expect.all
                        [ Query.has [ dataAttr "data-count" "44" ]
                        , Query.findAll [ tag "rect" ] >> Query.count (Expect.equal 44)
                        , Query.findAll [ tag "rect", dataAttr "data-level" "4" ] >> Query.count (Expect.equal 6)
                        , Query.findAll [ tag "rect", dataAttr "data-status" "new" ] >> Query.count (Expect.equal 20)
                        , Query.findAll [ tag "rect" ] >> Query.first >> Query.has [ dataAttr "fill" "#1f7a45" ]
                        ]
        , test "the three states in words, which are the grid's legend" <|
            \_ ->
                card accountJson
                    |> Query.find [ id "hub-state" ]
                    |> Query.has [ dataAttr "aria-label" "6 patched · 18 in progress · 20 to start · of 44" ]
        , test "the other four are rows, in order, each with what is left" <|
            \_ ->
                loaded accountJson
                    |> rendered
                    |> Query.find [ id "hub-rows" ]
                    |> Expect.all
                        [ Query.findAll [ class "dk-row" ] >> Query.count (Expect.equal 4)
                        , Query.find [ id "hub-row-bad" ] >> Query.has [ text "69 left" ]
                        , Query.find [ id "hub-row-openings" ] >> Query.has [ text "11 left" ]
                        , Query.find [ id "hub-row-opening_replies" ] >> Query.has [ text "315 left" ]
                        , Query.findAll [ id "hub-row-very_bad" ] >> Query.count (Expect.equal 0)
                        ]
        , test "tapping a row puts that deck in front, and the lead goes back to the rows" <|
            \_ ->
                let
                    model =
                        loaded accountJson
                in
                Expect.all
                    [ \_ ->
                        rendered model
                            |> Query.find [ id "hub-row-bad" ]
                            |> Event.simulate Event.click
                            |> Event.expect (PickedDeck "bad")
                    , \_ ->
                        model
                            |> send (PickedDeck "bad")
                            |> rendered
                            |> Expect.all
                                [ Query.find [ id "hub-card" ] >> Query.has [ dataAttr "data-deck" "bad" ]
                                , Query.findAll [ id "hub-row-very_bad" ] >> Query.count (Expect.equal 1)
                                , Query.findAll [ id "hub-row-bad" ] >> Query.count (Expect.equal 0)
                                ]
                    ]
                    ()
        , test "a set in front is its name, its size and a grid of its own shape" <|
            \_ ->
                loaded accountJson
                    |> send (PickedDeck "opening_replies")
                    |> rendered
                    |> Query.find [ id "hub-card" ]
                    |> Expect.all
                        [ Query.find [ id "hub-name" ] >> Query.has [ text "Opening replies" ]
                        , Query.has [ text "315 POSITIONS" ]
                        , Query.find [ dataAttr "data-count" "315" ] >> Query.has [ dataAttr "data-columns" "21", dataAttr "data-rows" "15" ]
                        , Query.find [ id "hub-go" ] >> Query.has [ text "START" ]
                        ]
        , test "the timezone goes once, with the first answer" <|
            \_ ->
                let
                    first =
                        Hub.init arie { tz = "Europe/Paris" } |> Tuple.first |> send (GotCatalog (parse accountJson))
                in
                ( first.tzSent, first |> send (GotCatalog (parse accountJson)) |> .tzSent )
                    |> Expect.equal ( True, True )
        ]



-- THE ONE BUTTON


theButton : Test
theButton =
    describe "the one button, by the deck's state"
        [ test "FIX ONE asks for that tier's queue and runs it as that tier" <|
            \_ ->
                loaded accountJson
                    |> send (Pressed (deckOf accountJson "very_bad") FixOne)
                    |> out (GotTierRun (deckOf accountJson "very_bad") FixOne (Api.parseBody Practice.practiceDecoder bandJson))
                    -- The ring over the board starts where the card's was:
                    -- two done of today's nine (two, four due, three new).
                    |> Expect.equal
                        (StartRun [ "aaaaaaaa", "bbbbbbbb" ]
                            (Just { done = 2 })
                            (Just "very_bad")
                            { deckToday = Just { done = 2, target = 9 }, anyway = False, slug = "very-bad" }
                        )
        , test "KEEP GOING hands the run today's set grown by what it started" <|
            \_ ->
                loaded keepGoingJson
                    |> send (Pressed (deckOf keepGoingJson "very_bad") KeepGoing)
                    |> out (GotTierRun (deckOf keepGoingJson "very_bad") KeepGoing (Api.parseBody Practice.practiceDecoder bandJson))
                    |> Expect.equal
                        (StartRun [ "aaaaaaaa", "bbbbbbbb" ]
                            (Just { done = 2 })
                            (Just "very_bad")
                            { deckToday = Just { done = 5, target = 7 }, anyway = False, slug = "very-bad" }
                        )
        , test "PRACTICE ANYWAY marks the run as practice only, the ring left full" <|
            \_ ->
                loaded scheduledJson
                    |> send (Pressed (deckOf scheduledJson "very_bad") PracticeAnyway)
                    |> out (GotTierRun (deckOf scheduledJson "very_bad") PracticeAnyway (Api.parseBody Practice.practiceDecoder bandJson))
                    |> Expect.equal
                        (StartRun [ "aaaaaaaa", "bbbbbbbb" ]
                            (Just { done = 2 })
                            (Just "very_bad")
                            { deckToday = Just { done = 0, target = 0 }, anyway = True, slug = "very-bad" }
                        )
        , test "pressed, the button waits in its slot and says so" <|
            \_ ->
                loaded accountJson
                    |> send (Pressed (deckOf accountJson "very_bad") FixOne)
                    |> rendered
                    |> Query.find [ id "hub-go" ]
                    |> Query.has [ text "STARTING…", Test.Html.Selector.disabled True ]
        , test "today's set done, with some never started: KEEP GOING, and what it adds" <|
            \_ ->
                card keepGoingJson
                    |> Expect.all
                        [ Query.find [ id "hub-go" ] >> Query.has [ text "KEEP GOING" ]
                        , Query.find [ id "hub-quiet" ] >> Query.has [ text "Today's 5 done. Keep going adds 3 more." ]
                        , Query.findAll [ tag "path", dataAttr "pathLength" "1" ] >> Query.count (Expect.equal 1)
                        ]
        , test "everything started and nothing due: PRACTICE ANYWAY" <|
            \_ ->
                card scheduledJson
                    |> Expect.all
                        [ Query.find [ id "hub-go" ] >> Query.has [ text "PRACTICE ANYWAY" ]
                        , Query.find [ id "hub-quiet" ] >> Query.has [ text Mistakes.scheduledLine ]
                        ]
        , test "the button is never a wall: every account's tier with anything in it has one" <|
            \_ ->
                [ accountJson, keepGoingJson, scheduledJson ]
                    |> List.map (\json -> Ui.Deck.action Ui.Deck.Account (deckOf json "very_bad"))
                    |> Expect.equal [ FixOne, KeepGoing, PracticeAnyway ]
        , test "a set added with work is PRACTICE, one not added is START" <|
            \_ ->
                [ "openings", "opening_replies" ]
                    |> List.map (deckOf accountJson >> Ui.Deck.action Ui.Deck.Account)
                    |> Expect.equal [ Practice, Start ]
        , test "a set's press hands the shell a run of it, named" <|
            \_ ->
                loaded accountJson
                    |> send (Pressed (deckOf accountJson "openings") Practice)
                    |> out (GotSetRun (deckOf accountJson "openings") Practice (Api.parseBody Decks.sessionDecoder setSessionJson))
                    |> Expect.equal
                        (StartDeckRun [ "oooooooo" ]
                            (Just { done = 1 })
                            { id = "openings", name = "Openings" }
                            { deckToday = Just { done = 0, target = 7 }, anyway = False, slug = "openings" }
                        )
        , test "a queue that came back empty says so where the quiet line is" <|
            \_ ->
                loaded accountJson
                    |> send (Pressed (deckOf accountJson "very_bad") FixOne)
                    |> send (GotTierRun (deckOf accountJson "very_bad") FixOne (Api.parseBody Practice.practiceDecoder emptyBandJson))
                    |> rendered
                    |> Query.find [ id "hub-quiet" ]
                    |> Query.has [ text "That's every one of these for now." ]
        , test "a press that fails says why, in the same place" <|
            \_ ->
                loaded accountJson
                    |> send (Pressed (deckOf accountJson "openings") Practice)
                    |> send (GotSetRun (deckOf accountJson "openings") Practice (Api.parseBody Decks.sessionDecoder """{"ok":false,"error":{"code":"not_found","message":"There is no such set of puzzles."}}"""))
                    |> rendered
                    |> Query.find [ id "hub-quiet" ]
                    |> Query.has [ text "There is no such set of puzzles." ]
        ]



-- WHAT IT COST


costs : Test
costs =
    describe "what the mistakes cost"
        [ test "the head says how much of the rating is mistakes, and what is won back" <|
            \_ ->
                loaded accountJson
                    |> rendered
                    |> Query.find [ id "hub-cost-all" ]
                    |> Expect.all
                        [ Query.has [ text "Your mistakes are 8.1 of your 8.3 PR." ]
                        , Query.find [ id "hub-won-all" ] >> Query.has [ text "You have won back 0.6 so far." ]
                        ]
        , test "a tier's cost line, and what patching won back of it" <|
            \_ ->
                card accountJson
                    |> Query.find [ id "hub-cost" ]
                    |> Expect.all
                        [ Query.has [ text "These cost you 3.5 PR over 11 games. Without them your PR would be 4.8, not 8.3." ]
                        , Query.find [ id "hub-won" ] >> Query.has [ text "Patched so far: 0.6 PR won back." ]
                        ]
        , test "nothing patched yet: the cost, and no won-back line" <|
            \_ ->
                card (accountWith (standing { total = 44, untouched = 20, inProgress = 24, patched = 0, due = 4, newLeft = 3, done = 2 }) """{"games":11,"lost":11.33,"lost_patched":0,"pr":8.3,"pr_without":4.8,"pr_patched":8.3}""")
                    |> Query.findAll [ id "hub-won" ]
                    |> Query.count (Expect.equal 0)
        , test "no rating behind it: no cost line, and no headline" <|
            \_ ->
                loaded noCostJson
                    |> rendered
                    |> Expect.all
                        [ Query.findAll [ id "hub-cost-all" ] >> Query.count (Expect.equal 0)
                        , Query.findAll [ class "dk-cost" ] >> Query.count (Expect.equal 0)
                        ]
        , test "a set has no cost" <|
            \_ ->
                loaded accountJson
                    |> send (PickedDeck "openings")
                    |> rendered
                    |> Query.findAll [ class "dk-cost" ]
                    |> Query.count (Expect.equal 0)
        ]



-- A FRESH ACCOUNT


aFreshAccount : Test
aFreshAccount =
    describe "a fresh account"
        [ test "is told where its mistakes will come from, and has the openings in front with START" <|
            \_ ->
                loaded freshJson
                    |> rendered
                    |> Expect.all
                        [ Query.find [ id "hub-fresh" ] >> Query.has [ text Mistakes.freshLine ]
                        , Query.find [ id "hub-card" ] >> Query.has [ dataAttr "data-deck" "openings" ]
                        , Query.find [ id "hub-go" ] >> Query.has [ text "START" ]
                        , Query.find [ id "hub-day" ] >> Query.has [ text "Nothing practised yet today" ]
                        ]
        , test "its tiers are quiet rows with nothing to tap" <|
            \_ ->
                loaded freshJson
                    |> rendered
                    |> Query.find [ id "hub-row-very_bad" ]
                    |> Expect.all
                        [ Query.has [ class "is-quiet", text "None yet" ]
                        , Query.has [ tag "p" ]
                        ]
        ]



-- A GUEST


aGuest : Test
aGuest =
    describe "a guest with games"
        [ test "reads what is theirs, that nothing is kept, and has their worst tier in front" <|
            \_ ->
                loaded guestJson
                    |> rendered
                    |> Expect.all
                        [ Query.find [ id "hub-headline" ] >> Query.has [ text "23 mistakes from your 4 games" ]
                        , Query.find [ id "hub-unsaved" ] >> Query.has [ text Mistakes.unsavedLine ]
                        , Query.find [ id "hub-card" ] >> Query.has [ dataAttr "data-deck" "bad" ]
                        , Query.find [ id "hub-go" ] >> Query.has [ text "PRACTICE" ]
                        , Query.find [ id "hub-state" ] >> Query.has [ text "21 bad moves from your games" ]
                        , Query.findAll [ id "hub-today" ] >> Query.count (Expect.equal 0)
                        ]
        , test "every square is paper: nothing is kept" <|
            \_ ->
                card guestJson
                    |> Query.findAll [ tag "rect", dataAttr "data-status" "new" ]
                    |> Query.count (Expect.equal 21)
        , test "PRACTICE runs that tier" <|
            \_ ->
                loaded guestJson
                    |> send (Pressed (deckOf guestJson "bad") Practice)
                    |> out (GotTierRun (deckOf guestJson "bad") Practice (Api.parseBody Practice.practiceDecoder bandJson))
                    -- A guest has no day, so the run draws no ring.
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ] (Just { done = 2 }) (Just "bad") { deckToday = Nothing, anyway = False, slug = "bad" })
        , test "a set in front says TRY" <|
            \_ ->
                loaded guestJson
                    |> send (PickedDeck "openings")
                    |> rendered
                    |> Query.find [ id "hub-go" ]
                    |> Query.has [ text "TRY" ]
        , test "the sign-in is a line until pressed, then the one component" <|
            \_ ->
                let
                    model =
                        loaded guestJson
                in
                Expect.all
                    [ \_ -> rendered model |> Query.findAll [ id "hub-signin-open" ] |> Query.count (Expect.equal 1)
                    , \_ -> model |> send OpenedSignIn |> rendered |> Query.findAll [ id "hub-signin" ] |> Query.count (Expect.equal 1)
                    ]
                    ()
        ]



-- A STRANGER


aStranger : Test
aStranger =
    describe "a stranger"
        [ test "is told what this is, offered one to try, and nothing is in front" <|
            \_ ->
                loaded strangerJson
                    |> rendered
                    |> Expect.all
                        [ Query.find [ id "hub-about" ] >> Query.has [ text "Every mistake the engine finds" ]
                        , Query.find [ id "hub-try-one" ] >> Query.has [ text "TRY ONE" ]
                        , Query.findAll [ id "hub-card" ] >> Query.count (Expect.equal 0)
                        ]
        , test "sees all five as rows: their tiers quiet, the sets to tap" <|
            \_ ->
                loaded strangerJson
                    |> rendered
                    |> Expect.all
                        [ Query.findAll [ class "dk-row" ] >> Query.count (Expect.equal 5)
                        , Query.findAll [ tag "button", class "dk-row" ] >> Query.count (Expect.equal 2)
                        ]
        , test "a set tapped comes in front with TRY" <|
            \_ ->
                loaded strangerJson
                    |> send (PickedDeck "openings")
                    |> rendered
                    |> Query.find [ id "hub-card" ]
                    |> Expect.all
                        [ Query.has [ dataAttr "data-action" "try" ]
                        , Query.find [ id "hub-quiet" ] >> Query.has [ text "Played in order, nothing kept." ]
                        ]
        , test "TRY ONE asks for a puzzle, and goes to the one it is given" <|
            \_ ->
                loaded strangerJson
                    |> send PressedTryOne
                    |> out (GotRandom (Api.parseBody Practice.randomDecoder """{"ok":true,"id":"zzzzzzzz","kind":"move","prompt":"p"}"""))
                    |> Expect.equal (Go "/puzzles/zzzzzzzz")
        , test "an empty pool is a sentence under the button, not a dead end" <|
            \_ ->
                loaded strangerJson
                    |> send PressedTryOne
                    |> send (GotRandom (Api.parseBody Practice.randomDecoder """{"ok":false,"error":{"code":"not_found","message":"No puzzles yet."}}"""))
                    |> rendered
                    |> Query.find [ id "hub-note" ]
                    |> Query.has [ text "No puzzles yet." ]
        , test "nothing is drawn but the eyebrow until the answer lands" <|
            \_ ->
                Hub.init Session.empty { tz = "" }
                    |> Tuple.first
                    |> rendered
                    |> Query.findAll [ id "hub-loading" ]
                    |> Query.count (Expect.equal 1)
        ]
