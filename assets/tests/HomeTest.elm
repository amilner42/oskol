module HomeTest exposing (suite)

{-| The signed-in home on the server's answers.

The JSON below is `GET /papi/me/home` as the handler really writes it
(`src/oskol/handlers/home.gleam`; the shape is asserted end to end in
`test/oskol_web/controllers/api/home_api_test.exs`), trimmed to the games
each case needs: a full home, one with fewer than three graded games, one
with nothing at all in it, and the one line a browser with no account is
sent.

What is checked here is what the page does with them: that every section
draws, that each empty state says the brief's words, that the form prints
no numbers it has not earned, that MORE appends the next page and then
goes, and that a guest's answer sends the shell back to the guest home
rather than drawing an empty one.

-}

import Api
import Api.Home as Home
import Api.Practice as Practice
import Expect
import Html
import Html.Attributes
import Page.Home as Page exposing (Msg(..), Out(..))
import Session
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (attribute, id, text)
import Time


suite : Test
suite =
    describe "the signed-in home"
        [ decoding
        , theBar
        , liveGames
        , form
        , practice
        , recentGames
        , aGuest
        , numbers
        ]



-- THE SERVER'S ANSWERS


{-| A player with everything: two live games (the second one theirs to
move), three graded games, a deck with cards at three levels and two days
practised, and more games behind the first page.
-}
fullJson : String
fullJson =
    """
{"ok":true,"signed_in":true,
 "live":[
   {"slug":"backgammon","id":"aaaaaa","path":"/backgammon/aaaaaa","status":"playing",
    "opponent":"Bob","format":"Match to 3","clock":"Blitz","your_move":false,
    "time":{"mine_ms":180000,"theirs_ms":120000,"running":"theirs","free_ms":12000,"age_s":4},
    "idle_s":40},
   {"slug":"backgammon","id":"bbbbbb","path":"/backgammon/bbbbbb","status":"playing",
    "opponent":"Carol","format":"Single game","clock":null,"your_move":true,
    "time":null,"idle_s":3600}],
 "form":{"games":3,"recent":6.2,"career":7.8,
         "sentence":"Recent 6.2, better than your career 7.8.",
         "series":[{"game_id":"g1","game_number":1,"pr":9.0,"error":5.4,"decisions":30,"ended_at":1790000000000},
                   {"game_id":"g2","game_number":1,"pr":7.5,"error":4.5,"decisions":30,"ended_at":1790100000000},
                   {"game_id":"g3","game_number":1,"pr":4.0,"error":2.4,"decisions":30,"ended_at":1790200000000}]},
 "practice":{"due":12,"deck":231,"ladder":[40,30,20,10,5,4,3,2],
             "days":[false,false,false,false,false,false,false,false,false,false,
                     false,false,false,false,false,false,false,false,false,false,
                     false,false,false,false,false,false,false,false,true,true]},
 "recent":[
   {"game_id":"g3","game_number":1,"slug":"backgammon","path":"/backgammon/g3/replay?game=1",
    "opponent":"Dave","result":{"won":true,"points":2,"kind":"gammon"},
    "pr":4.0,"error":2.4,"decisions":30,"ended_at":1790200000000},
   {"game_id":"g2","game_number":1,"slug":"backgammon","path":"/backgammon/g2/replay?game=1",
    "opponent":"Carol","result":{"won":false,"points":1,"kind":"single"},
    "pr":7.5,"error":4.5,"decisions":30,"ended_at":1790100000000},
   {"game_id":"g1","game_number":1,"slug":"backgammon","path":"/backgammon/g1/replay?game=1",
    "opponent":"Bob","result":null,
    "pr":18.0,"error":10.8,"decisions":30,"ended_at":1790000000000}],
 "more":true,"next":"1790000000000:1:g1"}
"""


{-| Two graded games: under the floor, so there is no rating to print.
-}
youngJson : String
youngJson =
    """
{"ok":true,"signed_in":true,
 "live":[],
 "form":{"games":2,"recent":null,"career":null,
         "sentence":"Play 3 games and your PR appears here.",
         "series":[{"game_id":"g1","game_number":1,"pr":9.0,"error":5.4,"decisions":30,"ended_at":1790000000000},
                   {"game_id":"g2","game_number":1,"pr":7.5,"error":4.5,"decisions":30,"ended_at":1790100000000}]},
 "practice":{"due":0,"deck":0,"ladder":[0,0,0,0,0,0,0,0],"days":[]},
 "recent":[],"more":false,"next":null}
"""


{-| A brand-new account: nothing anywhere.
-}
emptyJson : String
emptyJson =
    """
{"ok":true,"signed_in":true,
 "live":[],
 "form":{"games":0,"recent":null,"career":null,
         "sentence":"Play 3 games and your PR appears here.","series":[]},
 "practice":{"due":0,"deck":0,"ladder":[0,0,0,0,0,0,0,0],"days":[]},
 "recent":[],"more":false,"next":null}
"""


guestJson : String
guestJson =
    """{"ok":true,"signed_in":false}"""


{-| The page after the first: two more games, and the end of the list.
-}
nextPageJson : String
nextPageJson =
    """
{"ok":true,
 "games":[
   {"game_id":"f2","game_number":1,"slug":"backgammon","path":"/backgammon/f2/replay?game=1",
    "opponent":"Erin","result":{"won":true,"points":3,"kind":"backgammon"},
    "pr":3.1,"error":1.86,"decisions":30,"ended_at":1789900000000},
   {"game_id":"f1","game_number":1,"slug":"backgammon","path":"/backgammon/f1/replay?game=1",
    "opponent":"Frank","result":{"won":false,"points":1,"kind":"single"},
    "pr":11.0,"error":6.6,"decisions":30,"ended_at":1789800000000}],
 "more":false,"next":null}
"""



-- DRIVING THE PAGE


parse : String -> Result Api.Error Home.Answer
parse =
    Api.parseBody Home.answerDecoder


session : Session.Session
session =
    { csrf = "token"
    , guestName = Nothing
    , prefs = Session.empty.prefs
    , user = Just { email = "ari@oskol.test", name = Just "arie1" }
    }


loaded : String -> Page.Model
loaded json =
    Page.init session
        |> Tuple.first
        |> send (GotHome (parse json))


send : Msg -> Page.Model -> Page.Model
send msg model =
    Page.update msg model |> (\( next, _, _ ) -> next)


out : Msg -> Page.Model -> Out
out msg model =
    Page.update msg model |> (\( _, _, o ) -> o)


{-| The page as it is drawn, with the shell's JOIN standing in for itself.
-}
render : Page.Model -> Query.Single Msg
render model =
    Html.div [] (Page.view { join = Html.text "JOIN", toMsg = identity } model)
        |> Query.fromHtml



-- DECODING


decoding : Test
decoding =
    describe "the answer"
        [ test "a browser with no account is told only that" <|
            \_ ->
                Expect.equal (Ok Home.Guest) (parse guestJson)
        , test "a full home decodes every section" <|
            \_ ->
                case parse fullJson of
                    Ok (Home.Mine home) ->
                        Expect.all
                            [ \h -> Expect.equal 2 (List.length h.live)
                            , \h -> Expect.equal (Just 6.2) h.form.recent
                            , \h -> Expect.equal (Just 7.8) h.form.career
                            , \h -> Expect.equal 3 (List.length h.form.series)
                            , \h -> Expect.equal 12 h.practice.due
                            , \h -> Expect.equal [ 40, 30, 20, 10, 5, 4, 3, 2 ] h.practice.ladder
                            , \h -> Expect.equal 30 (List.length h.practice.days)
                            , \h -> Expect.equal 3 (List.length h.recent)
                            , \h -> Expect.equal True h.more
                            , \h -> Expect.equal (Just "1790000000000:1:g1") h.next
                            ]
                            home

                    _ ->
                        Expect.fail "expected a signed-in home"
        , test "a rating that came as null is nothing, never a flawless zero" <|
            \_ ->
                case parse youngJson of
                    Ok (Home.Mine home) ->
                        Expect.equal ( Nothing, Nothing ) ( home.form.recent, home.form.career )

                    _ ->
                        Expect.fail "expected a signed-in home"
        , test "a malformed list fails the answer rather than becoming an empty one" <|
            \_ ->
                -- A player with games drawn as a player with none is the
                -- same page as a bug, so this has to be an error.
                case parse (String.replace "\"recent\":[" "\"recent\":[3," fullJson) of
                    Err _ ->
                        Expect.pass

                    Ok _ ->
                        Expect.fail "a malformed game was swallowed"
        ]



-- THE BAR


theBar : Test
theBar =
    describe "the bar"
        [ test "names the account and offers the three things to start" <|
            \_ ->
                render (loaded fullJson)
                    |> Expect.all
                        [ Query.has [ id "home-bar" ]
                        , Query.find [ id "account-button" ] >> Query.has [ text "arie1" ]
                        , Query.has [ id "home-play" ]
                        , Query.has [ id "home-puzzles" ]
                        , Query.has [ id "bg-theme-button" ]
                        , Query.has [ text "JOIN" ]
                        ]
        , test "is there before the answer is, and nothing else is" <|
            \_ ->
                render (Page.init session |> Tuple.first)
                    |> Expect.all
                        [ Query.has [ id "home-bar" ]
                        , Query.has [ id "home-loading" ]
                        , Query.hasNot [ id "home-live" ]
                        ]
        , test "PUZZLES goes to the practice home" <|
            \_ ->
                loaded fullJson
                    |> out PressedPuzzles
                    |> Expect.equal (Go "/puzzles")
        , test "the account menu opens, and LOG OUT is behind it" <|
            \_ ->
                loaded fullJson
                    |> send ToggledAccount
                    |> render
                    |> Query.find [ id "account-menu" ]
                    |> Query.has [ id "logout" ]
        , test "a failed answer says so once, with a way to ask again" <|
            \_ ->
                loaded fullJson
                    |> send (GotHome (Err Api.NetworkError))
                    |> render
                    |> Expect.all
                        [ Query.find [ id "home-failed" ] >> Query.has [ text "Lost the connection. Try again." ]
                        , Query.has [ id "home-retry" ]
                        , Query.hasNot [ id "home-live-list" ]
                        ]
        ]



-- LIVE GAMES


liveGames : Test
liveGames =
    describe "live games"
        [ test "lists every room, your move first" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "home-live-list" ]
                    |> Query.children []
                    |> Expect.all
                        [ Query.count (Expect.equal 2)

                        -- Carol's is the caller's move, and second in the
                        -- answer: it comes first on the page.
                        , Query.index 0 >> Query.has [ id "resume-bbbbbb", text "vs Carol", text "Your move" ]
                        , Query.index 1 >> Query.has [ id "resume-aaaaaa", text "vs Bob", text "Their move" ]
                        ]
        , test "one tap into a game is the room's own URL" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "resume-bbbbbb" ]
                    |> Query.has [ attribute (Html.Attributes.href "/backgammon/bbbbbb") ]
        , test "with none, it says so and offers a game" <|
            \_ ->
                render (loaded emptyJson)
                    |> Query.find [ id "home-live" ]
                    |> Expect.all
                        [ Query.has [ text "No games on. Play a friend from a link." ]
                        , Query.has [ id "home-live-play" ]
                        ]
        ]



-- FORM


form : Test
form =
    describe "form"
        [ test "prints the two numbers, the sentence and the line" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "home-form" ]
                    |> Expect.all
                        [ Query.find [ id "home-form-recent" ]
                            >> Query.has [ text "6.2", text "Recent (last 20)" ]
                        , Query.find [ id "home-form-career" ]
                            >> Query.has [ text "7.8", text "Career" ]
                        , Query.find [ id "home-form-sentence" ]
                            >> Query.has [ text "Recent 6.2, better than your career 7.8." ]

                        -- The line itself, over all three games (the
                        -- picture names how many it drew).
                        , Query.has [ attribute (Html.Attributes.attribute "data-games" "3") ]
                        ]
        , test "under three graded games there are no numbers and no line" <|
            \_ ->
                render (loaded youngJson)
                    |> Query.find [ id "home-form" ]
                    |> Expect.all
                        [ Query.find [ id "home-form-sentence" ]
                            >> Query.has [ text "Play 3 games and your PR appears here." ]
                        , Query.hasNot [ id "home-form-recent" ]
                        , Query.hasNot [ id "home-form-career" ]
                        , Query.findAll [ Selector.tag "svg" ] >> Query.count (Expect.equal 0)
                        ]
        ]



-- PRACTICE


practice : Test
practice =
    describe "practice"
        [ test "says what is due and draws the deck" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "home-practice" ]
                    |> Expect.all
                        [ Query.find [ id "home-due" ] >> Query.has [ text "12 due" ]
                        , Query.has [ id "home-practice-start" ]


                        -- The ladder over all 114 cards, and the strip
                        -- with the two days practised in it.
                        , Query.has [ attribute (Html.Attributes.attribute "data-cards" "114") ]
                        , Query.has [ attribute (Html.Attributes.attribute "data-practised" "2") ]
                        , Query.has [ text "your deck" ]
                        ]
        , test "an empty deck says what fills it, and offers nothing to run" <|
            \_ ->
                render (loaded emptyJson)
                    |> Query.find [ id "home-practice" ]
                    |> Expect.all
                        [ Query.has [ text "Your mistakes become puzzles here after your first graded game." ]
                        , Query.hasNot [ id "home-practice-start" ]
                        , Query.findAll [ Selector.tag "svg" ] >> Query.count (Expect.equal 0)
                        ]
        , test "PRACTICE hands the shell the deck's puzzles, in order" <|
            \_ ->
                loaded fullJson
                    |> send PressedPractice
                    |> out (GotDeck (Api.parseBody Practice.practiceDecoder deckJson))
                    |> Expect.equal (StartRun [ "aaaaaaaa", "bbbbbbbb" ])
        , test "a deck with nothing in it right now starts no run, and says so" <|
            \_ ->
                let
                    model =
                        loaded fullJson
                            |> send PressedPractice
                            |> send (GotDeck (Api.parseBody Practice.practiceDecoder emptyDeckJson))
                in
                render model
                    |> Query.find [ id "home-practice-note" ]
                    |> Query.has [ text "Nothing to practise right now." ]
        ]


deckJson : String
deckJson =
    """{"ok":true,"puzzles":[{"id":"aaaaaaaa","kind":"move","prompt":"White to play 6-4.","due":true},{"id":"bbbbbbbb","kind":"double","prompt":"Double?","due":false}],"counts":{"due":12,"new_today":4,"new_tomorrow":10,"deck":231},"mistakes":null}"""


emptyDeckJson : String
emptyDeckJson =
    """{"ok":true,"puzzles":[],"counts":{"due":0,"new_today":0,"new_tomorrow":0,"deck":231},"mistakes":null}"""



-- RECENT GAMES


recentGames : Test
recentGames =
    describe "recent games"
        [ test "one line per game, each a link to its replay" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "home-recent-list" ]
                    |> Query.children []
                    |> Expect.all
                        [ Query.count (Expect.equal 3)
                        , Query.index 0
                            >> Query.has
                                [ text "Dave"
                                , text "won 2 · gammon"
                                , text "4.0"
                                , attribute (Html.Attributes.href "/backgammon/g3/replay?game=1")
                                ]
                        , Query.index 1 >> Query.has [ text "Carol", text "lost 1" ]
                        ]
        , test "a game with no record row shows no result rather than a guess" <|
            \_ ->
                render (loaded fullJson)
                    |> Query.find [ id "home-game-g1-1" ]
                    |> Query.has [ text "—" ]
        , test "each rating carries its grade's colour" <|
            \_ ->
                render (loaded fullJson)
                    |> Expect.all
                        [ Query.find [ id "home-game-g3-1" ] >> Query.has [ Selector.class "g-best" ]
                        , Query.find [ id "home-game-g2-1" ] >> Query.has [ Selector.class "g-ok" ]
                        , Query.find [ id "home-game-g1-1" ] >> Query.has [ Selector.class "g-very_bad" ]
                        ]
        , test "MORE appends the next page and then goes" <|
            \_ ->
                let
                    after =
                        loaded fullJson
                            |> send PressedMore
                            |> send (GotMore (Api.parseBody Home.pageDecoder nextPageJson))
                in
                render after
                    |> Expect.all
                        [ Query.find [ id "home-recent-list" ]
                            >> Query.children []
                            >> Query.count (Expect.equal 5)
                        , Query.find [ id "home-game-f1-1" ] >> Query.has [ text "Frank" ]
                        , Query.hasNot [ id "home-more" ]
                        ]
        , test "with no more behind them there is nothing to press" <|
            \_ ->
                render (loaded youngJson)
                    |> Query.hasNot [ id "home-more" ]
        , test "with none at all, one line says where they will be" <|
            \_ ->
                render (loaded emptyJson)
                    |> Query.find [ id "home-recent" ]
                    |> Expect.all
                        [ Query.has [ text "Your finished games appear here once the engine has graded them." ]
                        , Query.hasNot [ id "home-recent-list" ]
                        ]
        ]



-- A GUEST


aGuest : Test
aGuest =
    describe "a browser with no account"
        [ test "is sent back to the guest home rather than shown an empty one" <|
            \_ ->
                Page.init session
                    |> Tuple.first
                    |> out (GotHome (parse guestJson))
                    |> Expect.equal SignedOut
        , test "logging out does the same" <|
            \_ ->
                loaded fullJson
                    |> out (LoggedOut (Ok ()))
                    |> Expect.equal SignedOut
        ]



-- THE SMALL PURE PARTS


numbers : Test
numbers =
    describe "the bands and the lines"
        [ test "five and under is the best moves' green" <|
            \_ ->
                Expect.equal [ "g-best", "g-best" ] [ Page.prBand 0.0, Page.prBand 5.0 ]
        , test "up to ten is the quiet band" <|
            \_ ->
                Expect.equal [ "g-ok", "g-ok" ] [ Page.prBand 5.1, Page.prBand 10.0 ]
        , test "above ten is the red" <|
            \_ ->
                Expect.equal "g-very_bad" (Page.prBand 10.1)
        , test "a result names the kind only when it was more than a game" <|
            \_ ->
                Expect.equal
                    [ "won 2 · gammon", "lost 1", "won 3 · backgammon", "—" ]
                    [ Page.resultLine (Just { won = True, points = 2, kind = "gammon" })
                    , Page.resultLine (Just { won = False, points = 1, kind = "single" })
                    , Page.resultLine (Just { won = True, points = 3, kind = "backgammon" })
                    , Page.resultLine Nothing
                    ]
        , test "a date drops the year while it is this one, and keeps it otherwise" <|
            \_ ->
                -- 2026-09-23T00:00:00Z and 2025-09-23T00:00:00Z.
                Expect.equal
                    [ "23 Sep", "23 Sep 2025" ]
                    [ Page.dateLine Time.utc 2026 1790121600000
                    , Page.dateLine Time.utc 2026 1758585600000
                    ]
        ]
