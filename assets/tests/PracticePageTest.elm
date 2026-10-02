module PracticePageTest exposing (suite)

{-| A deck's own page (`/practice/<slug>`) on `GET /papi/practice/decks/:slug`:
the card at page size -- a square per position in the deck's own order,
today's ring, the legend, the state line, the one button -- and under it
where its positions stand, the month, and what a tier cost.

Each of the five decks for an account; a guest's tier (their count, every
square paper, PRACTICE); a stranger's tier (one line and the way back);
a set nobody has added (START for an account, TRY and the sign-in line
for anybody else); and the button in each of its states.
-}

import Api
import Api.Decks as Decks
import Api.Practice as Practice
import Api.PracticeDecks as PracticeDecks
import Expect
import Html.Attributes
import Page.Practice as PracticePage exposing (Msg(..), Out(..))
import Session
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)
import Time
import Ui.Deck exposing (Action(..))
import Ui.Deck
import Ui.Decks as DeckWords
import Ui.Mistakes as Mistakes


suite : Test
suite =
    describe "a deck's own page"
        [ decoding
        , theFive
        , theButton
        , theDetails
        , aGuest
        , aStranger
        , words
        , manage
        ]



-- THE SERVER'S ANSWERS


now : Int
now =
    1800000000000


day : Int
day =
    86400000


type alias StandingIn =
    { total : Int, untouched : Int, inProgress : Int, patched : Int, due : Int, newLeft : Int, done : Int, levels : List Int }


standing : StandingIn -> String
standing s =
    let
        n =
            String.fromInt
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
        ++ String.join "," (List.map n s.levels)
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


{-| A cell: its rung, its status and when it is next due.
-}
cell : Int -> ( Int, String, Int ) -> String
cell index ( level, status, due ) =
    "{\"id\":\"k"
        ++ String.fromInt index
        ++ "\",\"level\":"
        ++ String.fromInt level
        ++ ",\"due\":"
        ++ String.fromInt due
        ++ ",\"status\":\""
        ++ status
        ++ "\",\"position\":"
        ++ String.fromInt index
        ++ ",\"band\":\"very_bad\"}"


page : { deck : String, cells : List ( Int, String, Int ), days : List Bool } -> String
page p =
    "{\"ok\":true,\"deck\":"
        ++ p.deck
        ++ ",\"cells\":["
        ++ String.join "," (List.indexedMap cell p.cells)
        ++ "],\"days\":["
        ++ String.join ","
            (List.map
                (\b ->
                    if b then
                        "true"

                    else
                        "false"
                )
                p.days
            )
        ++ "],\"patched_level\":4}"


{-| Nine days of the last thirty had practice.
-}
nineDays : List Bool
nineDays =
    List.repeat 21 False ++ List.repeat 9 True


{-| `n` cells: `started` of them at their levels, due `inDays` from now,
the rest never shown.
-}
cellsOf : Int -> List Int -> Int -> List ( Int, String, Int )
cellsOf n started inDays =
    List.map (\level -> ( level, "active", now + inDays * day )) started
        ++ List.repeat (n - List.length started) ( 0, "new", now )


{-| Two back at the start, three at level 1, two at 2, one at 3, six
patched; the rest of 44 never shown.
-}
veryBadStarted : List Int
veryBadStarted =
    [ 0, 0, 1, 1, 1, 2, 2, 3, 4, 4, 5, 6, 4, 7 ]


veryBadCost : String
veryBadCost =
    """{"games":11,"lost":11.33,"lost_patched":0.66,"pr":8.3,"pr_without":4.8,"pr_patched":7.7}"""


veryBadDeck : StandingIn -> String -> String
veryBadDeck s cost =
    deck { id = "very_bad", slug = "very-bad", kind = "mistakes", name = "Very bad moves", mark = "??", size = s.total, pace = 3, joined = True, standing = standing s, cost = cost }


{-| The very bad moves with work today: four due, three new, two done.
-}
veryBad : StandingIn
veryBad =
    { total = 44, untouched = 30, inProgress = 8, patched = 6, due = 4, newLeft = 3, done = 2, levels = [ 32, 3, 2, 1, 4, 1, 1, 0 ] }


veryBadJson : String
veryBadJson =
    page { deck = veryBadDeck veryBad veryBadCost, cells = cellsOf 44 veryBadStarted 0, days = nineDays }


keepGoingJson : String
keepGoingJson =
    page
        { deck = veryBadDeck { veryBad | due = 0, newLeft = 0, done = 5 } veryBadCost
        , cells = cellsOf 44 veryBadStarted 3
        , days = nineDays
        }


anywayJson : String
anywayJson =
    page
        { deck = veryBadDeck { veryBad | untouched = 0, inProgress = 38, due = 0, newLeft = 0, done = 0 } veryBadCost
        , cells = cellsOf 44 (List.repeat 38 1 ++ List.repeat 6 4) 1
        , days = nineDays
        }


noCostJson : String
noCostJson =
    page { deck = veryBadDeck veryBad "null", cells = cellsOf 44 veryBadStarted 0, days = nineDays }


tierJson : String -> String -> String -> String -> Int -> String
tierJson id slug name mark size =
    page
        { deck =
            deck
                { id = id
                , slug = slug
                , kind = "mistakes"
                , name = name
                , mark = mark
                , size = size
                , pace = 3
                , joined = True
                , standing = standing { total = size, untouched = size - 2, inProgress = 2, patched = 0, due = 1, newLeft = 3, done = 0, levels = [ size - 2, 2, 0, 0, 0, 0, 0, 0 ] }
                , cost = "null"
                }
        , cells = cellsOf size [ 1, 1 ] 0
        , days = nineDays
        }


setJson : String -> String -> Int -> Bool -> String
setJson id name size joined =
    let
        s =
            if joined then
                { total = size, untouched = size - 7, inProgress = 3, patched = 4, due = 2, newLeft = 5, done = 1, levels = [ size - 6, 2, 1, 0, 4, 0, 0, 0 ] }

            else
                { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0, levels = [] }
    in
    page
        { deck = deck { id = id, slug = String.replace "_" "-" id, kind = "set", name = name, mark = "", size = size, pace = 5, joined = joined, standing = standing s, cost = "null" }
        , cells =
            if joined then
                cellsOf size [ 0, 1, 1, 2, 3, 4, 4, 4, 4 ] 0

            else
                []
        , days = nineDays
        }


guestJson : String
guestJson =
    page
        { deck = deck { id = "bad", slug = "bad", kind = "mistakes", name = "Bad moves", mark = "?", size = 12, pace = 3, joined = False, standing = "null", cost = "null" }
        , cells = []
        , days = List.repeat 30 False
        }


strangerTierJson : String
strangerTierJson =
    page
        { deck = deck { id = "very_bad", slug = "very-bad", kind = "mistakes", name = "Very bad moves", mark = "??", size = 0, pace = 3, joined = False, standing = "null", cost = "null" }
        , cells = []
        , days = List.repeat 30 False
        }


strangerSetJson : String
strangerSetJson =
    page
        { deck = deck { id = "openings", slug = "openings", kind = "set", name = "Openings", mark = "", size = 15, pace = 5, joined = False, standing = "null", cost = "null" }
        , cells = []
        , days = List.repeat 30 False
        }


parse : String -> Result Api.Error PracticeDecks.Page
parse =
    Api.parseBody PracticeDecks.pageDecoder


arie : Session.Session
arie =
    Session.withUser (Just { email = "arie@example.com", name = Just "arie" }) Session.empty


loaded : String -> PracticePage.Model
loaded json =
    PracticePage.init arie { tz = "Europe/Paris", slug = "very-bad" }
        |> Tuple.first
        |> send (GotNow (Time.millisToPosix now))
        |> send (GotPage (parse json))


send : Msg -> PracticePage.Model -> PracticePage.Model
send msg model =
    PracticePage.update msg model |> (\( next, _, _ ) -> next)


out : Msg -> PracticePage.Model -> Out
out msg model =
    PracticePage.update msg model |> (\( _, _, o ) -> o)


rendered : String -> Query.Single Msg
rendered json =
    loaded json |> PracticePage.view |> Query.fromHtml


dataAttr : String -> String -> Test.Html.Selector.Selector
dataAttr name value =
    attribute (Html.Attributes.attribute name value)


theDeck : String -> PracticeDecks.Deck
theDeck json =
    case parse json of
        Ok p ->
            p.deck

        Err _ ->
            Debug.todo "the fixture parses"


goSays : String -> String -> Expect.Expectation
goSays json label =
    rendered json |> Query.find [ id "practice-go" ] |> Query.has [ text label ]


grid : String -> Query.Single Msg
grid json =
    rendered json |> Query.find [ id "practice-grid" ] |> Query.find [ tag "svg" ]



-- DECODING


decoding : Test
decoding =
    describe "the answer"
        [ test "decodes: the deck, a cell per position with when it is due, thirty days" <|
            \_ ->
                case parse veryBadJson of
                    Ok p ->
                        Expect.all
                            [ \_ -> Expect.equal 44 (List.length p.cells)
                            , \_ -> Expect.equal 30 (List.length p.days)
                            , \_ -> Expect.equal (Just now) (List.head p.cells |> Maybe.map .due)
                            , \_ -> Expect.equal "very-bad" p.deck.slug
                            ]
                            ()

                    Err _ ->
                        Expect.fail "the page did not decode"
        , test "a cell with no due date is an error, not a guess" <|
            \_ ->
                parse ("""{"ok":true,"deck":""" ++ veryBadDeck veryBad "null" ++ ""","cells":[{"id":"k","level":1,"status":"active","position":1,"band":"bad"}],"days":[],"patched_level":4}""")
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "until it lands the page holds its place, and says which deck after" <|
            \_ ->
                PracticePage.init arie { tz = "", slug = "very-bad" }
                    |> Tuple.first
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Query.has [ id "practice-loading" ]
        , test "the title is the deck's name" <|
            \_ -> loaded veryBadJson |> PracticePage.title |> Expect.equal "Very bad moves · Practice"
        ]



-- THE FIVE


theFive : Test
theFive =
    describe "each of the five, for an account"
        [ test "the very bad moves: a square per position, in the deck's order" <|
            \_ ->
                grid veryBadJson
                    |> Expect.all
                        [ Query.has [ dataAttr "data-count" "44" ]
                        , Query.findAll [ dataAttr "data-status" "active" ] >> Query.count (Expect.equal 14)
                        , -- The first two cells are the two missed: the grid
                          -- is the deck's own order, not sorted by level.
                          Query.findAll [ tag "rect" ] >> Query.first >> Query.has [ dataAttr "data-level" "0", dataAttr "data-status" "active" ]
                        ]
        , test "the bad moves" <|
            \_ -> grid (tierJson "bad" "bad" "Bad moves" "?" 71) |> Query.has [ dataAttr "data-count" "71" ]
        , test "the dubious moves" <|
            \_ -> grid (tierJson "doubtful" "dubious" "Dubious moves" "?!" 141) |> Query.has [ dataAttr "data-count" "141" ]
        , test "the openings, fifteen to a row" <|
            \_ -> grid (setJson "openings" "Openings" 15 True) |> Query.has [ dataAttr "data-count" "15", dataAttr "data-columns" "15" ]
        , test "the replies, a row per opening" <|
            \_ -> grid (setJson "opening_replies" "Opening replies" 315 True) |> Query.has [ dataAttr "data-count" "315", dataAttr "data-columns" "21", dataAttr "data-rows" "15" ]
        , test "today's ring reads done over today's set" <|
            \_ ->
                rendered veryBadJson
                    |> Query.find [ id "practice-today" ]
                    |> Query.find [ tag "svg" ]
                    |> Query.has [ dataAttr "data-done" "2", dataAttr "data-target" "9" ]
        , test "the legend under a tier's grid climbs from to learn to mastered" <|
            \_ ->
                rendered veryBadJson
                    |> Query.find [ id "practice-legend" ]
                    |> Expect.all
                        [ Query.has [ text "to learn" ]
                        , Query.has [ text "level 1" ]
                        , Query.has [ text "mastered" ]
                        , Query.hasNot [ text "patched" ]
                        , Query.hasNot [ text "learned" ]
                        ]
        , test "the legend under a set's grid says the same words" <|
            \_ ->
                rendered (setJson "openings" "Openings" 15 True)
                    |> Query.find [ id "practice-legend" ]
                    |> Expect.all [ Query.has [ text "to learn" ], Query.has [ text "mastered" ], Query.hasNot [ text "learned" ], Query.hasNot [ text "patched" ] ]
        , test "no OPEN on the page itself: it is the page" <|
            \_ -> rendered veryBadJson |> Query.findAll [ id "practice-open" ] |> Query.count (Expect.equal 0)
        ]



-- THE BUTTON


theButton : Test
theButton =
    describe "the one button, the practice home's own"
        [ test "FIX ONE while today has work" <|
            \_ -> goSays veryBadJson "TRAIN"
        , test "KEEP GOING once today's set is done and some are unstarted" <|
            \_ -> goSays keepGoingJson "KEEP GOING"
        , test "PRACTICE ANYWAY once everything is started and nothing is due" <|
            \_ -> goSays anywayJson "PRACTICE ANYWAY"
        , test "PRACTICE on a set the account has added" <|
            \_ -> goSays (setJson "openings" "Openings" 15 True) "TRAIN"
        , test "START on a set the account has not" <|
            \_ -> goSays (setJson "openings" "Openings" 15 False) "START"
        , test "a run started here is a run of this tier" <|
            \_ ->
                loaded veryBadJson
                    |> out (GotTierRun (theDeck veryBadJson) FixOne (Api.parseBody Practice.practiceDecoder bandJson))
                    -- the run's ring starts where this page's did: 2 of 9
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ] (Just { done = 2 }) (Just "very_bad") { deckToday = Just { done = 2, target = 9 }, anyway = False, slug = "very-bad" })
        , test "KEEP GOING here hands the run today's set grown by what it started, as the hub does" <|
            \_ ->
                loaded keepGoingJson
                    |> out (GotTierRun (theDeck keepGoingJson) KeepGoing (Api.parseBody Practice.practiceDecoder bandJson))
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ] (Just { done = 2 }) (Just "very_bad") { deckToday = Just { done = 5, target = 7 }, anyway = False, slug = "very-bad" })
        , test "PRACTICE ANYWAY here marks the run practice only, as the hub does" <|
            \_ ->
                loaded anywayJson
                    |> out (GotTierRun (theDeck anywayJson) PracticeAnyway (Api.parseBody Practice.practiceDecoder bandJson))
                    |> (\o ->
                            case o of
                                StartRun _ _ _ begun ->
                                    Expect.equal True begun.anyway

                                _ ->
                                    Expect.fail "a run"
                       )
        , test "a run through a set names the set" <|
            \_ ->
                let
                    json =
                        setJson "openings" "Openings" 15 True
                in
                loaded json
                    |> out (GotSetRun (theDeck json) Ui.Deck.Practice (Api.parseBody Decks.sessionDecoder setSessionJson))
                    |> Expect.equal (StartDeckRun [ "oooooooo" ] (Just { done = 1 }) { id = "openings", name = "Openings" } { deckToday = Just { done = 1, target = 8 }, anyway = False, slug = "openings" })
        , test "a press waits, in the same slot" <|
            \_ ->
                loaded veryBadJson
                    |> send (Pressed (theDeck veryBadJson) FixOne)
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Query.find [ id "practice-go" ]
                    |> Expect.all [ Query.has [ text "STARTING…" ], Query.has [ attribute (Html.Attributes.disabled True) ] ]
        , test "an empty answer says so where the quiet line is, and the button comes back" <|
            \_ ->
                loaded veryBadJson
                    |> send (Pressed (theDeck veryBadJson) FixOne)
                    |> send (GotTierRun (theDeck veryBadJson) FixOne (Api.parseBody Practice.practiceDecoder emptyBandJson))
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "practice-quiet" ] >> Query.has [ text "That's every one of these for now." ]
                        , Query.find [ id "practice-go" ] >> Query.has [ text "TRAIN" ]
                        ]
        ]


bandJson : String
bandJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4. What's your play?","due":true},{"id":"bbbbbbbb","kind":"double","prompt":"White to play. Double?","due":false}],"cursor":null,"counts":{"due":12,"new_today":3,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":2},"severity":[],"lead":"very_bad","patched_level":4,"game":null}"""


emptyBandJson : String
emptyBandJson =
    """{"ok":true,"puzzles":[],"cursor":null,"counts":{"due":0,"new_today":0,"new_tomorrow":3,"deck":231},"mistakes":null,"today":{"done":5},"severity":[],"lead":null,"patched_level":4,"game":null}"""


setSessionJson : String
setSessionJson =
    """{"ok":true,"deck":{"id":"openings","name":"Openings","blurb":"b","size":15,"standing":{"joined":true,"total":15,"in_progress":5,"patched":4,"left":11,"due":3,"new_left":0}},"puzzles":[{"id":"oooooooo","kind":"move","prompt":"White to play 2-1. What's your play?","due":true}],"today":{"done":1}}"""



-- UNDER THE CARD


theDetails : Test
theDetails =
    describe "where they stand, the month, what they cost"
        [ test "the due line: today's work" <|
            \_ -> rendered veryBadJson |> Query.find [ id "practice-due" ] |> Query.has [ text "4 due now · 3 new today" ]
        , test "the due line: nothing due, the next in three days" <|
            \_ -> rendered keepGoingJson |> Query.find [ id "practice-due" ] |> Query.has [ text "Nothing due. Next due in 3 days." ]
        , test "the due line: nothing due, the next tomorrow" <|
            \_ -> rendered anywayJson |> Query.find [ id "practice-due" ] |> Query.has [ text "Nothing due. Next due tomorrow." ]
        , test "the ladder in words, from the started ones" <|
            \_ ->
                rendered veryBadJson
                    |> Query.find [ id "practice-ladder" ]
                    |> Query.has [ text "2 back at the start, 3 at level 1, 2 at level 2, 1 at level 3, 6 mastered." ]
        , test "the thirty days, and how many had practice" <|
            \_ ->
                rendered veryBadJson
                    |> Query.find [ id "practice-month" ]
                    |> Expect.all
                        [ Query.has [ text "Practiced on 9 days of the last 30." ]
                        , Query.find [ tag "svg" ] >> Query.has [ dataAttr "data-practiced" "9" ]
                        ]
        , test "a tier with graded games behind it says what it cost, and what patching won back" <|
            \_ ->
                rendered veryBadJson
                    |> Query.find [ id "practice-cost-block" ]
                    |> Expect.all
                        [ Query.has [ text "These cost you 3.5 PR over 11 games. Without them your PR would be 4.8, not 8.3." ]
                        , Query.has [ text "Mastered so far: 0.6 PR won back." ]
                        ]
        , test "no cost counted, no cost card" <|
            \_ -> rendered noCostJson |> Query.findAll [ id "practice-cost-block" ] |> Query.count (Expect.equal 0)
        , test "a set has no cost card" <|
            \_ -> rendered (setJson "openings" "Openings" 15 True) |> Query.findAll [ id "practice-cost-block" ] |> Query.count (Expect.equal 0)
        , test "a set nobody has added has nothing under the card yet" <|
            \_ -> rendered (setJson "openings" "Openings" 15 False) |> Query.findAll [ id "practice-details" ] |> Query.count (Expect.equal 0)
        , test "an account has no sign-in line" <|
            \_ -> rendered veryBadJson |> Query.findAll [ id "practice-signin-line" ] |> Query.count (Expect.equal 0)
        ]



-- A GUEST, A STRANGER


aGuest : Test
aGuest =
    describe "a guest on a tier"
        [ test "their count, every square paper, PRACTICE, and nothing kept" <|
            \_ ->
                rendered guestJson
                    |> Expect.all
                        [ Query.find [ id "practice-unsaved" ] >> Query.has [ text Mistakes.unsavedLine ]
                        , Query.find [ id "practice-state" ] >> Query.has [ text "12 bad moves from your games" ]
                        , Query.find [ id "practice-grid" ] >> Query.findAll [ dataAttr "data-status" "new" ] >> Query.count (Expect.equal 12)
                        , Query.find [ id "practice-go" ] >> Query.has [ text "TRAIN" ]
                        , Query.findAll [ id "practice-today" ] >> Query.count (Expect.equal 0)
                        , Query.findAll [ id "practice-details" ] >> Query.count (Expect.equal 0)
                        , Query.has [ id "practice-signin-open" ]
                        ]
        ]


aStranger : Test
aStranger =
    describe "a stranger"
        [ test "on a tier: one line, and the way back" <|
            \_ ->
                rendered strangerTierJson
                    |> Expect.all
                        [ Query.find [ id "practice-empty-line" ] >> Query.has [ text "Play a game and your mistakes appear here." ]
                        , Query.find [ id "practice-way-back" ] >> Query.has [ attribute (Html.Attributes.href "/puzzles") ]
                        , Query.findAll [ id "practice-card" ] >> Query.count (Expect.equal 0)
                        ]
        , test "on a set: its size, all paper, TRY, and the sign-in line" <|
            \_ ->
                rendered strangerSetJson
                    |> Expect.all
                        [ Query.find [ id "practice-grid" ] >> Query.findAll [ dataAttr "data-status" "new" ] >> Query.count (Expect.equal 15)
                        , Query.find [ id "practice-go" ] >> Query.has [ text "TRY" ]
                        , Query.find [ id "practice-signin-line" ] >> Query.has [ text DeckWords.signInRest ]
                        , Query.find [ id "practice-name" ] >> Query.has [ text "Openings" ]
                        ]
        , test "an account with none of a kind yet is told where they come from" <|
            \_ ->
                rendered (tierJson "very_bad" "very-bad" "Very bad moves" "??" 0)
                    |> Query.find [ id "practice-empty-line" ]
                    |> Query.has [ text "No very bad moves yet. They land here as your games are graded." ]
        , test "the way back is always at the top" <|
            \_ -> rendered strangerSetJson |> Query.find [ id "practice-back" ] |> Query.has [ attribute (Html.Attributes.href "/puzzles") ]
        ]



-- THE WORDS


words : Test
words =
    describe "the page's words"
        [ test "nothing on any of these pages says deck, card or flashcard" <|
            \_ ->
                [ veryBadJson, keepGoingJson, anywayJson, guestJson, strangerTierJson, strangerSetJson, setJson "openings" "Openings" 15 True ]
                    |> List.map
                        (\json ->
                            rendered json
                                |> Query.findAll [ text "deck" ]
                                |> Query.count (Expect.equal 0)
                        )
                    |> List.map (\e -> \_ -> e)
                    |> (\checks -> Expect.all checks ())
        , test "nor card" <|
            \_ ->
                [ veryBadJson, keepGoingJson, anywayJson, guestJson, strangerTierJson, strangerSetJson ]
                    |> List.map (\json -> \_ -> rendered json |> Query.findAll [ text "card" ] |> Query.count (Expect.equal 0))
                    |> (\checks -> Expect.all checks ())
        , test "the ladder says nothing when nothing is started" <|
            \_ -> PracticePage.ladder (Result.withDefault emptyPage (parse strangerSetJson)) |> List.sum |> Expect.equal 0
        , test "next due counts whole days, at least one" <|
            \_ ->
                parse keepGoingJson
                    |> Result.toMaybe
                    |> Maybe.andThen (PracticePage.nextInDays (Time.millisToPosix now))
                    |> Expect.equal (Just 3)
        ]


emptyPage : PracticeDecks.Page
emptyPage =
    { deck = theDeck strangerSetJson, cells = [], days = [], patchedLevel = 4, members = Nothing }



-- AN OWN SET'S PAGE: MANAGE


aQuestion : String
aQuestion =
    """{"board":{"white":{"points":[0,0,0,4,4,5,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],"bar":0,"off":0},"black":{"points":[2,2,0,0,0,0,1,0,0,0,0,0,0,0,0,0,3,3,0,2,2,0,0,0],"bar":0,"off":0}},"dice":[6,4],"cube":{"value":1,"owner":"center"},"score":null,"crawford":false,"jacoby":false}"""


{-| "Openings I like": three positions saved -- one at level 2, one
mastered, one never answered (its question unreadable, so no board).
-}
ownJson : List String -> String
ownJson members =
    "{\"ok\":true,\"deck\":"
        ++ deck
            { id = "K7M2Q9XA"
            , slug = "K7M2Q9XA"
            , kind = "own"
            , name = "Openings I like"
            , mark = ""
            , size = List.length members
            , pace = 5
            , joined = True
            , standing = standing { total = 3, untouched = 1, inProgress = 1, patched = 1, due = 0, newLeft = 1, done = 0, levels = [ 1, 0, 1, 0, 1, 0, 0, 0 ] }
            , cost = "null"
            }
        ++ ",\"cells\":["
        ++ String.join "," (List.indexedMap cell [ ( 2, "active", now + day ), ( 4, "active", now + 9 * day ), ( 0, "new", now ) ])
        ++ "],\"days\":[],\"patched_level\":4,\"members\":["
        ++ String.join "," members
        ++ "]}"


member : Int -> String -> Int -> String -> String
member index prompt level question =
    "{\"id\":\"k"
        ++ String.fromInt index
        ++ "\",\"kind\":\"move\",\"prompt\":\""
        ++ prompt
        ++ "\",\"position\":"
        ++ String.fromInt (index + 1)
        ++ ",\"level\":"
        ++ String.fromInt level
        ++ ",\"question\":"
        ++ question
        ++ "}"


threeJson : String
threeJson =
    ownJson
        [ member 0 "White to play 6-4. What's your play?" 2 aQuestion
        , member 1 "White to play 3-1. What's your play?" 4 aQuestion
        , member 2 "White to play. Double?" 0 "null"
        ]


emptyJson : String
emptyJson =
    "{\"ok\":true,\"deck\":"
        ++ deck
            { id = "Z3W8R1PB"
            , slug = "Z3W8R1PB"
            , kind = "own"
            , name = "Back games"
            , mark = ""
            , size = 0
            , pace = 5
            , joined = True
            , standing = standing { total = 0, untouched = 0, inProgress = 0, patched = 0, due = 0, newLeft = 0, done = 0, levels = [ 0, 0, 0, 0, 0, 0, 0, 0 ] }
            , cost = "null"
            }
        ++ ",\"cells\":[],\"days\":[],\"patched_level\":4,\"members\":[]}"


ownedSet : String -> String -> Int -> Result Api.Error Decks.OwnSet
ownedSet setId name size =
    Ok { id = setId, name = name, size = size, holds = False }


manage : Test
manage =
    describe "an own set's page: MANAGE"
        [ test "its members read off the wire, in the set's order, with their questions" <|
            \_ ->
                case parse threeJson of
                    Ok p ->
                        p.members
                            |> Maybe.map (List.map (\m -> ( m.id, m.level, m.question /= Nothing )))
                            |> Expect.equal (Just [ ( "k0", 2, True ), ( "k1", 4, True ), ( "k2", 0, False ) ])

                    Err _ ->
                        Expect.fail "the page parses"
        , test "the card is a set's, and MANAGE is under it" <|
            \_ ->
                rendered threeJson
                    |> Expect.all
                        [ Query.find [ id "practice-card" ] >> Query.has [ dataAttr "data-kind" "own" ]
                        , Query.find [ id "practice-manage" ] >> Query.has [ text "Manage" ]
                        ]
        , test "the positions as a list: a small board, the prompt, where it stands, an x" <|
            \_ ->
                rendered threeJson
                    |> Query.find [ id "practice-members" ]
                    |> Query.children []
                    |> Expect.all
                        [ Query.count (Expect.equal 3)
                        , Query.index 0 >> Query.has [ id "practice-member-k0", text "White to play 6-4. What's your play?", text "level 2" ]
                        , Query.index 0 >> Query.findAll [ class "bg-still" ] >> Query.count (Expect.equal 1)
                        , Query.index 1 >> Query.has [ text "mastered" ]
                        , Query.index 2 >> Query.has [ text "to learn" ]
                        , Query.index 2 >> Query.findAll [ class "bg-still" ] >> Query.count (Expect.equal 0)
                        , Query.index 0 >> Query.find [ id "practice-remove-k0" ] >> Event.simulate Event.click >> Event.expect (PressedRemove "k0")
                        , Query.index 0 >> Query.find [ tag "a" ] >> Query.has [ attribute (Html.Attributes.href "/puzzles/k0") ]
                        ]
        , test "the name is in its field; RENAME waits for a change" <|
            \_ ->
                rendered threeJson
                    |> Expect.all
                        [ Query.find [ id "practice-rename" ] >> Query.has [ attribute (Html.Attributes.value "Openings I like") ]
                        , Query.find [ id "practice-rename" ] >> Event.simulate (Event.input "Openings I love") >> Event.expect (RenameInput "Openings I love")
                        , Query.find [ id "practice-rename-save" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                        ]
        , test "renamed: the card's name follows, and the line says so" <|
            \_ ->
                loaded threeJson
                    |> send (RenameInput "Openings I love")
                    |> send SubmittedRename
                    |> send (GotRenamed (ownedSet "K7M2Q9XA" "Openings I love" 3))
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ id "practice-name" ] >> Query.has [ text "Openings I love" ]
                        , Query.find [ id "practice-manage-line" ] >> Query.has [ text "Renamed." ]
                        ]
        , test "a refused name is said in the line, in the server's words" <|
            \_ ->
                loaded threeJson
                    |> send (RenameInput "Back games")
                    |> send SubmittedRename
                    |> send (GotRenamed (Err (Api.ApiError { code = "name_taken", message = "You already have a set called that" })))
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Query.find [ id "practice-manage-line" ]
                    |> Query.has [ text "You already have a set called that" ]
        , test "removed: the row goes, the x was held while it was on its way" <|
            \_ ->
                let
                    removing =
                        loaded threeJson |> send (PressedRemove "k0")
                in
                Expect.all
                    [ PracticePage.view >> Query.fromHtml >> Query.find [ id "practice-remove-k0" ] >> Query.has [ attribute (Html.Attributes.disabled True) ]
                    , send (GotRemoved "k0" (ownedSet "K7M2Q9XA" "Openings I like" 2))
                        >> PracticePage.view
                        >> Query.fromHtml
                        >> Query.find [ id "practice-members" ]
                        >> Query.children []
                        >> Query.count (Expect.equal 2)
                    ]
                    removing
        , test "DELETE SET asks once, in place, in the set's name" <|
            \_ ->
                loaded threeJson
                    |> send PressedDelete
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Query.find [ id "practice-delete-slot" ]
                    |> Expect.all
                        [ Query.has [ text "Delete Openings I like? Its positions stay where they are; your progress on them is kept aside." ]
                        , Query.find [ id "practice-delete-yes" ] >> Event.simulate Event.click >> Event.expect ConfirmedDelete
                        , Query.find [ id "practice-delete-no" ] >> Event.simulate Event.click >> Event.expect CancelledDelete
                        , Query.findAll [ id "practice-delete" ] >> Query.count (Expect.equal 0)
                        ]
        , test "KEEP IT puts the button back" <|
            \_ ->
                loaded threeJson
                    |> send PressedDelete
                    |> send CancelledDelete
                    |> PracticePage.view
                    |> Query.fromHtml
                    |> Query.find [ id "practice-delete" ]
                    |> Query.has [ text "DELETE SET" ]
        , test "deleted, the way back is the practice home" <|
            \_ ->
                loaded threeJson
                    |> send PressedDelete
                    |> send ConfirmedDelete
                    |> out (GotDeleted (Ok ()))
                    |> Expect.equal (Go "/puzzles")
        , test "an empty set: OPEN ANALYSIS in the button's place, and the list says how to fill it" <|
            \_ ->
                rendered emptyJson
                    |> Expect.all
                        [ Query.find [ id "practice-open-analysis" ] >> Query.has [ tag "a", attribute (Html.Attributes.href "/analysis") ]
                        , Query.find [ id "practice-members-empty" ] >> Query.has [ text "Nothing here yet. Save a position from the analysis board or from any puzzle." ]
                        ]
        , test "the level words" <|
            \_ ->
                [ DeckWords.levelWord { level = 0, started = False, patchedLevel = 4 }
                , DeckWords.levelWord { level = 2, started = True, patchedLevel = 4 }
                , DeckWords.levelWord { level = 4, started = True, patchedLevel = 4 }
                , DeckWords.levelWord { level = 0, started = True, patchedLevel = 4 }
                ]
                    |> Expect.equal [ "to learn", "level 2", "mastered", "back at the start" ]
        , test "a universal set's page has no MANAGE" <|
            \_ ->
                rendered (setJson "openings" "Openings" 15 True)
                    |> Query.findAll [ id "practice-manage" ]
                    |> Query.count (Expect.equal 0)
        ]
