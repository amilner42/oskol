module CatalogTest exposing (suite)

{-| The /papi contract, from the client's side: the envelope, the landing
decoders, and the two orders a game's clocks are listed in.

The decoders are written to be lax about what they do not need — the
catalogue is generated from the Gleam registry and gains keys whenever a
game does — and strict about what they do. Both halves are asserted here.

-}

import Api
import Api.Catalog as Catalog
import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Api.Catalog"
        [ envelope
        , library
        , gamePage
        , created
        , room
        , clockOrders
        , summaries
        ]



-- THE ENVELOPE


envelope : Test
envelope =
    describe "the response envelope"
        [ test "ok:true unwraps the payload" <|
            \_ ->
                Api.parseBody Catalog.slugDecoder """{"ok":true,"slug":"poker"}"""
                    |> Expect.equal (Ok "poker")
        , test "ok:false is an error with its code and message" <|
            \_ ->
                Api.parseBody Catalog.createdDecoder
                    """{"ok":false,"error":{"code":"validation_failed","message":"Pick a display name first"}}"""
                    |> Expect.equal
                        (Err
                            (Api.ApiError
                                { code = "validation_failed"
                                , message = "Pick a display name first"
                                }
                            )
                        )
        , test "an error envelope reads the same on a 4xx as on a 200" <|
            \_ ->
                Api.parseBody Catalog.slugDecoder
                    """{"ok":false,"error":{"code":"not_found","message":"No game with that code"}}"""
                    |> Result.mapError Api.errorCode
                    |> Expect.equal (Err "not_found")
        , test "a body that is not the envelope at all is a decode error, not a crash" <|
            \_ ->
                case Api.parseBody Catalog.slugDecoder "<!doctype html>" of
                    Err (Api.DecodeError _) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected a decode error, got " ++ Debug.toString other)
        , test "ok:true with a payload the decoder cannot read is a decode error" <|
            \_ ->
                case Api.parseBody Catalog.createdDecoder """{"ok":true,"id":"123456"}""" of
                    Err (Api.DecodeError _) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected a decode error, got " ++ Debug.toString other)
        ]



-- GET /papi/library


library : Test
library =
    describe "GET /papi/library"
        [ test "decodes the games and the ones with no engine yet" <|
            \_ ->
                Api.parseBody Catalog.libraryDecoder libraryJson
                    |> Result.map (\lib -> ( List.map .slug lib.games, List.map .slug lib.comingSoon ))
                    |> Expect.equal (Ok ( [ "poker", "backgammon" ], [ "checkers" ] ))
        , test "keeps the registry's order" <|
            \_ ->
                Api.parseBody Catalog.libraryDecoder libraryJson
                    |> Result.map (.games >> List.map .name)
                    |> Expect.equal (Ok [ "Poker", "Backgammon" ])
        , test "a missing coming_soon is simply empty" <|
            \_ ->
                Api.parseBody Catalog.libraryDecoder """{"ok":true,"games":[]}"""
                    |> Result.map .comingSoon
                    |> Expect.equal (Ok [])
        ]


libraryJson : String
libraryJson =
    """
    {"ok":true,
     "games":[
       {"slug":"poker","name":"Poker","description":"Hold'em for two.","tagline":"Heads-up",
        "min_players":2,"max_players":2,"default_clock":"poker",
        "clocks":["poker","poker_fast","none"],
        "formats":[{"id":"cash","name":"Cash game","description":"Fixed blinds",
                    "config":{"format":0},
                    "settings":[{"id":"stake","name":"Stakes","default":"1-2",
                                 "choices":[{"id":"1-2","name":"1 / 2"},{"id":"2-5","name":"2 / 5"}]}]}]},
       {"slug":"backgammon","name":"Backgammon","description":"The race game.",
        "default_clock":"none","clocks":["none","blitz"],
        "formats":[{"id":"single","name":"Single game","description":"One game, no cube","settings":[]}]}
     ],
     "coming_soon":[{"slug":"checkers","name":"Checkers","description":"Soon."}]}
    """



-- GET /papi/games/:slug


gamePage : Test
gamePage =
    describe "GET /papi/games/:slug"
        [ test "decodes the game, its formats and their settings" <|
            \_ ->
                decodeGame gameJson
                    |> Result.map
                        (\page ->
                            ( List.map .id page.formats
                            , page.formats
                                |> List.concatMap .settings
                                |> List.map (\s -> ( s.id, s.default, List.map .id s.choices ))
                            )
                        )
                    |> Expect.equal
                        (Ok
                            ( [ "cash", "sng" ]
                            , [ ( "stake", "1-2", [ "1-2", "2-5" ] ) ]
                            )
                        )
        , test "decodes the copy the page is built around" <|
            \_ ->
                decodeGame gameJson
                    |> Result.map (\page -> ( page.copy.title, page.copy.rules, page.copy.faq ))
                    |> Expect.equal
                        (Ok
                            ( "Play heads-up poker online with a friend"
                            , [ "Two cards down, five up." ]
                            , [ ( "Is it real money?", "No." ) ]
                            )
                        )
        , test "a game with no copy of its own falls back to the plain prose" <|
            \_ ->
                decodeGame """{"ok":true,"game":{"slug":"go","name":"Go","description":"Territory."}}"""
                    |> Result.map (\page -> ( page.copy.title, page.copy.intro, page.copy.rules ))
                    |> Expect.equal
                        (Ok
                            ( "Play Go online with a friend"
                            , "Territory."
                            , [ "Territory." ]
                            )
                        )
        , test "the remembered guest name comes through, and null is no name" <|
            \_ ->
                ( decodeGame gameJson |> Result.map .guestName
                , decodeGame """{"ok":true,"game":{"slug":"go"},"guest_name":null}"""
                    |> Result.map .guestName
                )
                    |> Expect.equal ( Ok (Just "Alice"), Ok Nothing )
        , test "unknown keys anywhere are ignored" <|
            \_ ->
                decodeGame
                    """{"ok":true,"invented":1,
                        "game":{"slug":"go","name":"Go","surprise":true,
                                "formats":[{"id":"9x9","name":"9×9","description":"Small",
                                            "config":{"size":9},"settings":[],"extra":"?"}]}}"""
                    |> Result.map (.formats >> List.map .name)
                    |> Expect.equal (Ok [ "9×9" ])
        , test "a response with no game at all is an error" <|
            \_ ->
                case decodeGame """{"ok":true}""" of
                    Err (Api.DecodeError _) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected a decode error, got " ++ Debug.toString other)
        ]


decodeGame : String -> Result Api.Error Catalog.GamePage
decodeGame =
    Api.parseBody Catalog.gamePageDecoder


gameJson : String
gameJson =
    """
    {"ok":true,
     "guest_name":"Alice",
     "game":{"slug":"poker","name":"Poker","description":"Hold'em for two.",
             "default_clock":"poker","clocks":["poker","poker_fast","none"],
             "formats":[]},
     "formats":[
       {"id":"cash","name":"Cash game","description":"Fixed blinds",
        "settings":[{"id":"stake","name":"Stakes","default":"1-2",
                     "choices":[{"id":"1-2","name":"1 / 2"},{"id":"2-5","name":"2 / 5"}]}]},
       {"id":"sng","name":"Sit & go","description":"Blinds rise","settings":[]}],
     "clock_presets":[
       {"id":"none","name":"No clock","description":"Take your time"},
       {"id":"poker","name":"Standard","description":"20 s per action"},
       {"id":"poker_fast","name":"Fast","description":"12 s per action"},
       {"id":"blitz","name":"Blitz","description":"3 min + 2 s"}],
     "copy":{"title":"Play heads-up poker online with a friend",
             "description":"Heads-up hold'em.","intro":"From a link.",
             "rules":["Two cards down, five up."],
             "faq":[{"question":"Is it real money?","answer":"No."}]}}
    """



-- POST /papi/games/:slug


created : Test
created =
    describe "POST /papi/games/:slug"
        [ test "sends the format and the name, and the settings and clock they need" <|
            \_ ->
                Catalog.encodeNewGame
                    { format = "cash"
                    , name = "Alice"
                    , selections = [ ( "stake", "2-5" ) ]
                    , clock = "poker"
                    }
                    |> E.encode 0
                    |> Expect.equal
                        """{"format":"cash","name":"Alice","clock":"poker","selections":{"stake":"2-5"}}"""
        , test "decodes the room and the URL that opens the seat" <|
            \_ ->
                Api.parseBody Catalog.createdDecoder
                    """{"ok":true,"id":"123456","path":"/poker/123456?t=secret","player_id":"p1"}"""
                    |> Expect.equal (Ok { id = "123456", path = "/poker/123456?t=secret" })
        , test "a validation failure is the message the form shows" <|
            \_ ->
                Api.parseBody Catalog.createdDecoder
                    """{"ok":false,"error":{"code":"validation_failed","message":"That name is already taken"}}"""
                    |> Result.mapError Api.errorMessage
                    |> Expect.equal (Err "That name is already taken")
        ]



-- GET /papi/games/:slug/rooms/:id


room : Test
room =
    describe "the invite link's read"
        [ test "a free seat comes with the inviter and the setup" <|
            \_ ->
                Api.parseBody Catalog.roomDecoder
                    """{"ok":true,"state":"open","inviter_name":"Alice",
                        "summary":"Match to 3 · Blitz clock","disconnected":[]}"""
                    |> Expect.equal
                        (Ok
                            { state = Catalog.Open
                            , inviterName = Just "Alice"
                            , summary = Just "Match to 3 · Blitz clock"
                            , disconnected = []
                            }
                        )
        , test "a full table offers nothing" <|
            \_ ->
                Api.parseBody Catalog.roomDecoder """{"ok":true,"state":"full"}"""
                    |> Result.map (\r -> ( r.state, r.disconnected ))
                    |> Expect.equal (Ok ( Catalog.Full, [] ))
        , test "a seat whose player is away is named" <|
            \_ ->
                Api.parseBody Catalog.roomDecoder
                    """{"ok":true,"state":"away","disconnected":[{"id":"p2","name":"Bob"}]}"""
                    |> Result.map (\r -> ( r.state, r.disconnected ))
                    |> Expect.equal (Ok ( Catalog.Away, [ { id = "p2", name = "Bob" } ] ))
        , test "a room that is gone says so" <|
            \_ ->
                Api.parseBody Catalog.roomDecoder """{"ok":true,"state":"missing"}"""
                    |> Result.map .state
                    |> Expect.equal (Ok Catalog.Missing)
        , test "a state nobody knows is treated as a free seat, and joining decides" <|
            \_ ->
                Api.parseBody Catalog.roomDecoder """{"ok":true,"state":"quantum"}"""
                    |> Result.map .state
                    |> Expect.equal (Ok Catalog.Open)
        ]



-- THE TWO ORDERS


clockOrders : Test
clockOrders =
    describe "a game's clocks"
        [ test "the picker lists them in preset order" <|
            \_ ->
                decodeGame gameJson
                    |> Result.map
                        (\page -> Catalog.offeredClocks page.game page.clocks |> List.map .id)
                    |> Expect.equal (Ok [ "none", "poker", "poker_fast" ])
        , test "the CLOCKS panel lists them in the game's own order" <|
            \_ ->
                decodeGame gameJson
                    |> Result.map
                        (\page -> Catalog.clocksInGameOrder page.game page.clocks |> List.map .id)
                    |> Expect.equal (Ok [ "poker", "poker_fast", "none" ])
        , test "a preset the game does not offer is in neither" <|
            \_ ->
                decodeGame gameJson
                    |> Result.map
                        (\page ->
                            ( Catalog.offeredClocks page.game page.clocks |> List.map .id
                            , Catalog.clocksInGameOrder page.game page.clocks |> List.map .id
                            )
                                |> (\( a, b ) -> List.member "blitz" a || List.member "blitz" b)
                        )
                    |> Expect.equal (Ok False)
        ]



-- THE SETUP LINE


summaries : Test
summaries =
    describe "the one line describing a setup"
        [ test "format, the chosen settings, then the clock" <|
            \_ ->
                Catalog.summarise cash [ ( "stake", "2-5" ) ] presets "poker"
                    |> Expect.equal "Cash game · 2 / 5 · Standard clock"
        , test "a setting nobody touched shows its default" <|
            \_ ->
                Catalog.summarise cash [] presets "none"
                    |> Expect.equal "Cash game · 1 / 2"
        , test "a twist left off says nothing worth a slot" <|
            \_ ->
                Catalog.summarise single [] presets "none"
                    |> Expect.equal "Single game"
        , test "a twist taken does" <|
            \_ ->
                Catalog.summarise single [ ( "twist", "pick_dice" ) ] presets "none"
                    |> Expect.equal "Single game · Pick your dice"
        , test "the chosen choice of a setting reads back, default otherwise" <|
            \_ ->
                ( Catalog.settingChoice [ ( "stake", "2-5" ) ] stake
                , Catalog.settingChoice [ ( "other", "x" ) ] stake
                )
                    |> Expect.equal ( "2-5", "1-2" )
        ]


stake : Catalog.Setting
stake =
    { id = "stake"
    , name = "Stakes"
    , default = "1-2"
    , choices = [ { id = "1-2", name = "1 / 2" }, { id = "2-5", name = "2 / 5" } ]
    }


cash : Catalog.Format
cash =
    { id = "cash", name = "Cash game", description = "Fixed blinds", settings = [ stake ] }


single : Catalog.Format
single =
    { id = "single"
    , name = "Single game"
    , description = "One game, no cube"
    , settings =
        [ { id = "twist"
          , name = "Pick dice"
          , default = "off"
          , choices =
                [ { id = "off", name = "Off" }
                , { id = "pick_dice", name = "Pick your dice" }
                ]
          }
        ]
    }


presets : List Catalog.ClockPreset
presets =
    [ { id = "none", name = "No clock", description = "Take your time" }
    , { id = "poker", name = "Standard", description = "20 s per action" }
    ]
