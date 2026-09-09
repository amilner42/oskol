module GameLandingTest exposing (suite)

{-| The create page: its pure logic (the name check, the mode grid) and the
DOM facts that make it the page it is — the picker, the settings that follow
a mode, the inline errors, and the invite's three states.
-}

import Api
import Api.Catalog as Catalog
import Expect
import Page.GameLanding as GameLanding
import Session exposing (Session)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector exposing (class, id, text)


suite : Test
suite =
    describe "Page.GameLanding"
        [ names
        , modeGrid
        , createForm
        , picking
        , errors
        , invites
        ]



-- PURE LOGIC


names : Test
names =
    describe "a display name"
        [ test "is trimmed" <|
            \_ -> Expect.equal (Ok "Alice") (GameLanding.cleanName "  Alice  ")
        , test "cannot be blank" <|
            \_ -> Expect.equal (Err "Pick a display name first") (GameLanding.cleanName "   ")
        , test "is 24 characters at most" <|
            \_ ->
                Expect.equal
                    (Err "Names are 24 characters at most")
                    (GameLanding.cleanName (String.repeat 25 "a"))
        , test "24 exactly is fine" <|
            \_ ->
                GameLanding.cleanName (String.repeat 24 "a")
                    |> Expect.equal (Ok (String.repeat 24 "a"))
        , test "trimming happens before the length check" <|
            \_ ->
                GameLanding.cleanName ("  " ++ String.repeat 24 "a" ++ "  ")
                    |> Expect.equal (Ok (String.repeat 24 "a"))
        , test "control characters are not a name" <|
            \_ -> Expect.equal (Err "Invalid name") (GameLanding.cleanName "Al\u{0007}ice")
        , test "neither are zero-width and direction marks" <|
            \_ ->
                [ "Al\u{200B}ice", "Al\u{202E}ice", "Al\u{FEFF}ice" ]
                    |> List.map GameLanding.cleanName
                    |> Expect.equal (List.repeat 3 (Err "Invalid name"))
        , test "accents and emoji are names like any other" <|
            \_ ->
                [ "Émile", "北斗", "Bob 🎲" ]
                    |> List.map GameLanding.cleanName
                    |> Expect.equal [ Ok "Émile", Ok "北斗", Ok "Bob 🎲" ]
        ]


modeGrid : Test
modeGrid =
    describe "the mode grid"
        [ test "one mode fills the row, two share it" <|
            \_ ->
                ( GameLanding.formatGridClass 1, GameLanding.formatGridClass 2 )
                    |> Expect.equal ( "grid-cols-1", "grid-cols-2" )
        , test "three and four stack on a phone" <|
            \_ ->
                ( GameLanding.formatGridClass 3, GameLanding.formatGridClass 4 )
                    |> Expect.equal ( "grid-cols-1 sm:grid-cols-3", "grid-cols-2 sm:grid-cols-4" )
        , test "five (backgammon) falls back to the general shape" <|
            \_ -> Expect.equal "grid-cols-2 sm:grid-cols-3" (GameLanding.formatGridClass 5)
        ]



-- THE PAGE


createForm : Test
createForm =
    describe "the create page"
        [ test "shows the game, its title and its intro" <|
            \_ ->
                loaded
                    |> Query.has
                        [ id "game-title"
                        , text "Poker"
                        , text "Play heads-up poker online with a friend"
                        , text "From a link."
                        ]
        , test "has a name field, a mode per format and the game's clocks" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.has [ id "create-name" ]
                        , Query.has [ id "format-cash" ]
                        , Query.has [ id "format-sng" ]
                        , Query.has [ id "clock-none" ]
                        , Query.has [ id "clock-poker" ]
                        , Query.has [ id "create-game" ]
                        ]
        , test "does not offer a clock the game does not" <|
            \_ -> loaded |> Query.hasNot [ id "clock-blitz" ]
        , test "the first format is selected, and its settings are the ones shown" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.find [ id "format-cash" ] >> Query.has [ class "tile-mine" ]
                        , Query.find [ id "format-sng" ] >> Query.hasNot [ class "tile-mine" ]
                        , Query.has [ id "setting-stake" ]
                        , Query.hasNot [ id "setting-speed" ]
                        ]
        , test "a setting shows its default until it is touched" <|
            \_ ->
                loaded
                    |> Query.find [ id "choice-stake-1-2" ]
                    |> Query.has [ class "tile-mine" ]
        , test "the rules, the modes, the clocks and the questions are all on the page" <|
            \_ ->
                loaded
                    |> Expect.all
                        [ Query.has [ id "rules" ]
                        , Query.has [ id "modes" ]
                        , Query.has [ id "faq" ]
                        , Query.has [ text "Two cards down, five up." ]
                        , Query.has [ text "Is it real money?" ]
                        ]
        , test "the name field prefills the remembered guest name" <|
            \_ -> Expect.equal "Alice" loadedModel.playerName
        , test "a fresh visitor starts with an empty field" <|
            \_ ->
                page { guestName = Nothing } "poker" Nothing
                    |> .playerName
                    |> Expect.equal ""
        ]


picking : Test
picking =
    describe "picking"
        [ test "picking a mode selects it, brings its settings and drops the last mode's" <|
            \_ ->
                let
                    picked =
                        loadedModel
                            |> send (GameLanding.PickedSetting "stake" "2-5")
                            |> send (GameLanding.PickedFormat "sng")
                in
                render picked
                    |> Expect.all
                        [ Query.find [ id "format-sng" ] >> Query.has [ class "tile-mine" ]
                        , Query.has [ id "setting-speed" ]
                        , Query.hasNot [ id "setting-stake" ]
                        ]
        , test "picking a choice marks it and unmarks the default" <|
            \_ ->
                render (send (GameLanding.PickedSetting "stake" "2-5") loadedModel)
                    |> Expect.all
                        [ Query.find [ id "choice-stake-2-5" ] >> Query.has [ class "tile-mine" ]
                        , Query.find [ id "choice-stake-1-2" ] >> Query.hasNot [ class "tile-mine" ]
                        ]
        , test "picking a clock moves the selection off the default" <|
            \_ ->
                render (send (GameLanding.PickedClock "none") loadedModel)
                    |> Expect.all
                        [ Query.find [ id "clock-none" ] >> Query.has [ class "tile-mine" ]
                        , Query.find [ id "clock-poker" ] >> Query.hasNot [ class "tile-mine" ]
                        ]
        ]


errors : Test
errors =
    describe "errors"
        [ test "a blank name is refused inline" <|
            \_ ->
                render (send GameLanding.Submitted blankModel)
                    |> Query.find [ id "form-error" ]
                    |> Query.has [ text "Pick a display name first" ]
        , test "a name that is fine leaves the form alone" <|
            \_ ->
                blankModel
                    |> send (GameLanding.NameChanged "Alice")
                    |> send GameLanding.Submitted
                    |> render
                    |> Query.hasNot [ id "form-error" ]
        , test "picking anything clears the error" <|
            \_ ->
                blankModel
                    |> send GameLanding.Submitted
                    |> send (GameLanding.PickedFormat "sng")
                    |> render
                    |> Query.hasNot [ id "form-error" ]
        , test "a server error comes back as the same line under the form" <|
            \_ ->
                blankModel
                    |> send
                        (GameLanding.Seated
                            (Err
                                (Api.ApiError
                                    { code = "validation_failed"
                                    , message = "That name is already taken"
                                    }
                                )
                            )
                        )
                    |> render
                    |> Query.find [ id "form-error" ]
                    |> Query.has [ text "That name is already taken" ]
        ]


invites : Test
invites =
    describe "an invite link"
        [ test "a free seat asks player 2 for a name" <|
            \_ ->
                invite Catalog.Open
                    |> Expect.all
                        [ Query.has [ id "join-name" ]
                        , Query.has [ id "join-game" ]
                        , Query.has [ text "Alice" ]
                        , Query.has [ text "Cash game · 1 / 2" ]
                        , Query.hasNot [ id "create-game" ]
                        ]
        , test "a full table offers nothing at all" <|
            \_ ->
                invite Catalog.Full
                    |> Expect.all
                        [ Query.has [ id "table-full" ]
                        , Query.has [ text "GAME CODE 123456" ]
                        , Query.hasNot [ id "join-name" ]
                        , Query.hasNot [ id "create-game" ]
                        ]
        , test "a seat whose player is away is offered back by name" <|
            \_ ->
                invite Catalog.Away
                    |> Expect.all
                        [ Query.has [ id "reconnect" ]
                        , Query.has [ id "reclaim-p2" ]
                        , Query.has [ text "CONTINUE?" ]
                        , Query.has [ text "Bob" ]
                        ]
        , test "the reading matter is only on the create page" <|
            \_ -> invite Catalog.Open |> Query.hasNot [ id "rules" ]
        ]



-- HARNESS


loaded : Query.Single GameLanding.Msg
loaded =
    render loadedModel


loadedModel : GameLanding.Model
loadedModel =
    page { guestName = Just "Alice" } "poker" Nothing
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))


{-| The same page for a visitor the site has never seen: an empty name field.
-}
blankModel : GameLanding.Model
blankModel =
    page { guestName = Nothing } "poker" Nothing
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))


invite : Catalog.RoomState -> Query.Single GameLanding.Msg
invite state =
    page { guestName = Nothing } "poker" (Just "123456")
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))
        |> send
            (GameLanding.GotRoom
                (Ok
                    { state = state
                    , inviterName = Just "Alice"
                    , summary = Just "Cash game · 1 / 2"
                    , disconnected =
                        case state of
                            Catalog.Away ->
                                [ { id = "p2", name = "Bob" } ]

                            _ ->
                                []
                    }
                )
            )
        |> render


page : { guestName : Maybe String } -> String -> Maybe String -> GameLanding.Model
page { guestName } slug gameId =
    GameLanding.init (session guestName) slug gameId Nothing
        |> (\( model, _, _ ) -> model)


session : Maybe String -> Session
session guestName =
    { csrf = "token", guestName = guestName }


send : GameLanding.Msg -> GameLanding.Model -> GameLanding.Model
send msg model =
    GameLanding.update msg model |> (\( updated, _, _ ) -> updated)


render : GameLanding.Model -> Query.Single GameLanding.Msg
render model =
    GameLanding.view model |> Query.fromHtml


gameJson : String
gameJson =
    """
    {"ok":true,
     "game":{"slug":"poker","name":"Poker","description":"Hold'em for two.",
             "default_clock":"poker","clocks":["poker","none"],"formats":[]},
     "formats":[
       {"id":"cash","name":"Cash game","description":"Fixed blinds",
        "settings":[{"id":"stake","name":"Stakes","default":"1-2",
                     "choices":[{"id":"1-2","name":"1 / 2"},{"id":"2-5","name":"2 / 5"}]}]},
       {"id":"sng","name":"Sit & go","description":"Blinds rise",
        "settings":[{"id":"speed","name":"Speed","default":"regular",
                     "choices":[{"id":"regular","name":"Regular"},{"id":"turbo","name":"Turbo"}]}]}],
     "clock_presets":[
       {"id":"none","name":"No clock","description":"Take your time"},
       {"id":"blitz","name":"Blitz","description":"3 min + 2 s"},
       {"id":"poker","name":"Standard","description":"20 s per action"}],
     "copy":{"title":"Play heads-up poker online with a friend",
             "description":"Heads-up hold'em.","intro":"From a link.",
             "rules":["Two cards down, five up."],
             "faq":[{"question":"Is it real money?","answer":"No."}]}}
    """
