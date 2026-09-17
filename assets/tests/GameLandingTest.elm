module GameLandingTest exposing (suite)

{-| The home page and the invite: the name check, the board with its menu,
CREATE GAME's dialog (its dropdowns, the defaults, the summary, the inline
errors), the board picker, and the invite's three states.
-}

import Api
import Api.Catalog as Catalog
import Dict
import Expect
import Games.Backgammon.View
import Html
import Html.Attributes
import Page.GameLanding as GameLanding
import Session exposing (Session)
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector exposing (attribute, class, id, tag, text)
import Ui.Shell as Shell


suite : Test
suite =
    describe "Page.GameLanding"
        [ names
        , homeBoard
        , createDialog
        , picking
        , submitting
        , boardPicker
        , invites
        , resume
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



-- THE HOME PAGE


homeBoard : Test
homeBoard =
    describe "the home page"
        [ test "is the board, in the default colours" <|
            \_ ->
                home loadedModel
                    |> Query.has [ class "bg-page", class "home-board", class "bg-theme-midnight" ]
        , test "draws at once, before the game's data has come" <|
            \_ ->
                home (page { guestName = Nothing } "backgammon" Nothing)
                    |> Query.has [ class "home-board", id "start-game" ]
        , test "its menu is four entries: create, join, and two on their way" <|
            \_ ->
                home loadedModel
                    |> Query.find [ class "home-menu" ]
                    |> Query.children []
                    |> Expect.all
                        [ Query.count (Expect.equal 4)
                        , Query.index 0 >> Query.has [ id "start-game", text "CREATE GAME" ]
                        , Query.index 1 >> Query.has [ id "join-game-board", text "JOIN GAME" ]
                        , Query.index 2 >> Query.has [ text "TACTICS", text "SOON", disabled ]
                        , Query.index 3 >> Query.has [ text "ANALYSIS", text "SOON", disabled ]
                        ]
        , test "the two on their way are not buttons: nothing to press" <|
            \_ ->
                home loadedModel
                    |> Query.find [ class "home-menu" ]
                    |> Query.findAll [ tag "button" ]
                    |> Query.count (Expect.equal 2)
        , test "JOIN GAME is the shell's code prompt" <|
            \_ ->
                home loadedModel
                    |> Query.find [ id "join-game-board" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.NoOp
        , test "the bar at the foot is the remembered name" <|
            \_ -> home loadedModel |> Query.find [ class "is-me" ] |> Query.has [ text "Alice" ]
        , test "or YOU for a visitor the site has never seen" <|
            \_ -> home blankModel |> Query.find [ class "is-me" ] |> Query.has [ text "YOU" ]
        , test "the board wears the colours this visitor picked" <|
            \_ ->
                pageWith { guestName = Nothing, prefs = [ ( "backgammon_theme", "sand" ) ] }
                    |> home
                    |> Query.has [ class "home-board", class "bg-theme-sand" ]
        , test "the name field prefills the remembered guest name" <|
            \_ -> Expect.equal "Alice" loadedModel.playerName
        , test "a fresh visitor starts with an empty field" <|
            \_ ->
                page { guestName = Nothing } "backgammon" Nothing
                    |> .playerName
                    |> Expect.equal ""
        ]



-- CREATE GAME


createDialog : Test
createDialog =
    describe "CREATE GAME's dialog"
        [ test "is closed until CREATE GAME is pressed" <|
            \_ -> home loadedModel |> Query.hasNot [ id "create-modal" ]
        , test "CREATE GAME opens it" <|
            \_ ->
                home loadedModel
                    |> Query.find [ id "start-game" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.Started
        , test "once opened it is a dialog over the board" <|
            \_ ->
                home opened
                    |> Expect.all
                        [ Query.has [ class "home-board" ]
                        , Query.find [ id "create-modal" ]
                            >> Query.has [ attribute (Html.Attributes.attribute "role" "dialog"), text "CREATE GAME" ]
                        ]
        , test "it holds the name, the mode, the clock, the twist and START GAME" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.has [ id "create-name", text "YOUR NAME" ]
                        , Query.has [ id "create-mode", text "MODE" ]
                        , Query.has [ id "create-clock", text "CLOCK" ]
                        , Query.has [ id "create-setting-twist", text "TWIST" ]
                        , Query.has [ id "create-summary" ]
                        , Query.find [ id "create-game" ] >> Query.has [ text "START GAME" ]
                        , Query.has [ id "close-create" ]
                        ]
        , test "the mode dropdown lists every format, the first chosen" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-mode" ]
                    |> Query.findAll [ tag "option" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 5)
                        , Query.index 0 >> Query.has [ text "Single game", selected True ]
                        , Query.index 2 >> Query.has [ text "Match to 5", value "match5", selected False ]
                        , Query.index 4 >> Query.has [ text "Unlimited", value "unlimited" ]
                        ]
        , test "the clock dropdown is the four the game offers, each with its delay" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-clock" ]
                    |> Query.findAll [ tag "option" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 4)
                        , Query.index 0 >> Query.has [ text "No clock", value "none", selected True ]
                        , Query.index 1 >> Query.has [ text "3 min + 12 s delay", value "bg3" ]
                        , Query.index 2 >> Query.has [ text "5 min + 12 s delay", value "bg5" ]
                        , Query.index 3 >> Query.has [ text "10 min + 12 s delay", value "bg10" ]
                        ]
        , test "a clock the game does not offer is not in it" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-clock" ]
                    |> Query.hasNot [ text "Blitz" ]
        , test "the twist dropdown starts on its default" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-setting-twist" ]
                    |> Query.findAll [ tag "option" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 2)
                        , Query.index 0 >> Query.has [ text "Off", selected True ]
                        , Query.index 1 >> Query.has [ text "Pick your dice, once a game", selected False ]
                        ]
        , test "the summary says what the dropdowns add up to" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-summary" ]
                    |> Query.has [ text "Single game: one game, no cube. No clock." ]
        , test "the close button closes it" <|
            \_ ->
                home opened
                    |> Query.find [ id "close-create" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.ClosedCreate
        , test "closed, it is gone and the board stays" <|
            \_ ->
                home (send GameLanding.ClosedCreate opened)
                    |> Expect.all
                        [ Query.hasNot [ id "create-modal" ]
                        , Query.has [ id "start-game" ]
                        ]
        , test "if the game's data never came, it says so instead of opening nothing" <|
            \_ ->
                page { guestName = Nothing } "backgammon" Nothing
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> send GameLanding.Started
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> home
                    |> Query.find [ id "create-modal" ]
                    |> Query.has [ id "form-error", text "Something went wrong" ]
        , test "and CREATE GAME asks for it again" <|
            \_ ->
                page { guestName = Nothing } "backgammon" Nothing
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> send GameLanding.Started
                    |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))
                    |> home
                    |> Query.find [ id "create-modal" ]
                    |> Query.has [ id "create-mode" ]
        , test "it waits for the game's data: opened early it shows nothing yet" <|
            \_ ->
                page { guestName = Nothing } "backgammon" Nothing
                    |> send GameLanding.Started
                    |> home
                    |> Query.hasNot [ id "create-modal" ]
        ]


picking : Test
picking =
    describe "picking"
        [ test "a mode is picked from its dropdown" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-mode" ]
                    |> Event.simulate (Event.input "match5")
                    |> Event.expect (GameLanding.PickedFormat "match5")
        , test "picking a mode selects it and says so in the summary" <|
            \_ ->
                home (send (GameLanding.PickedFormat "match5") opened)
                    |> Expect.all
                        [ Query.find [ id "create-mode" ]
                            >> Query.find [ value "match5" ]
                            >> Query.has [ selected True ]
                        , Query.find [ id "create-summary" ]
                            >> Query.has [ text "Match to 5: cube and Crawford rule. No clock." ]
                        ]
        , test "picking a mode drops the last mode's settings" <|
            \_ ->
                opened
                    |> send (GameLanding.PickedSetting "twist" "pick_dice")
                    |> send (GameLanding.PickedFormat "match3")
                    |> .selections
                    |> Expect.equal []
        , test "the clock dropdown sends the clock picked" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-clock" ]
                    |> Event.simulate (Event.input "bg10")
                    |> Event.expect (GameLanding.PickedClock "bg10")
        , test "a clock picked is selected, and the summary spells it out" <|
            \_ ->
                home (send (GameLanding.PickedClock "bg3") opened)
                    |> Expect.all
                        [ Query.find [ id "create-clock" ]
                            >> Query.find [ value "bg3" ]
                            >> Query.has [ selected True ]
                        , Query.find [ id "create-summary" ]
                            >> Query.has [ text "Single game: one game, no cube. 3 min each, 12 s delay every move." ]
                        ]
        , test "the twist dropdown sends the choice picked" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-setting-twist" ]
                    |> Event.simulate (Event.input "pick_dice")
                    |> Event.expect (GameLanding.PickedSetting "twist" "pick_dice")
        , test "a twist picked is selected" <|
            \_ ->
                home (send (GameLanding.PickedSetting "twist" "pick_dice") opened)
                    |> Query.find [ id "create-setting-twist" ]
                    |> Query.find [ value "pick_dice" ]
                    |> Query.has [ selected True ]
        ]


submitting : Test
submitting =
    describe "submitting"
        [ test "START GAME submits the dialog's form" <|
            \_ ->
                home opened
                    |> Query.find [ id "create-modal" ]
                    |> Query.find [ tag "form" ]
                    |> Event.simulate Event.submit
                    |> Event.expect GameLanding.Submitted
        , test "a name that is fine asks the server for a room" <|
            \_ ->
                opened
                    |> send GameLanding.Submitted
                    |> Expect.all
                        [ .busy >> Expect.equal True
                        , .error >> Expect.equal Nothing
                        ]
        , test "the room the server made is the seat to go to, under the name typed" <|
            \_ ->
                GameLanding.update
                    (GameLanding.Seated (Ok { id = "123456", path = "/backgammon/123456?t=secret" }))
                    (send GameLanding.Submitted opened)
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.TookSeat { name = "Alice", path = "/backgammon/123456?t=secret" })
        , test "a blank name is refused inline, in the dialog" <|
            \_ ->
                blankModel
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> home
                    |> Query.find [ id "create-modal" ]
                    |> Query.find [ id "form-error" ]
                    |> Query.has [ text "Pick a display name first" ]
        , test "a blank name does not reach the server" <|
            \_ ->
                blankModel
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> .busy
                    |> Expect.equal False
        , test "a name that is fine leaves the dialog without an error" <|
            \_ ->
                blankModel
                    |> send GameLanding.Started
                    |> send (GameLanding.NameChanged "Alice")
                    |> send GameLanding.Submitted
                    |> home
                    |> Query.hasNot [ id "form-error" ]
        , test "picking anything clears the error" <|
            \_ ->
                blankModel
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> send (GameLanding.PickedFormat "match3")
                    |> home
                    |> Query.hasNot [ id "form-error" ]
        , test "a server error comes back as the same line in the dialog" <|
            \_ ->
                blankModel
                    |> send GameLanding.Started
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
                    |> home
                    |> Query.find [ id "create-modal" ]
                    |> Query.find [ id "form-error" ]
                    |> Query.has [ text "That name is already taken" ]
        ]



-- THE BOARD PICKER


boardPicker : Test
boardPicker =
    describe "the board picker in the top bar"
        [ test "shows the board you are looking at, and its list is closed" <|
            \_ ->
                home loadedModel
                    |> Expect.all
                        [ Query.find [ id "bg-theme-button" ] >> Query.has [ class "bg-theme-midnight" ]
                        , Query.hasNot [ id "bg-theme-list" ]
                        ]
        , test "tapping it opens the list" <|
            \_ ->
                home loadedModel
                    |> Query.find [ id "bg-theme-button" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.ToggledThemes
        , test "the list has every board there is, no more and no fewer" <|
            \_ ->
                home (send GameLanding.ToggledThemes loadedModel)
                    |> Query.find [ id "bg-theme-list" ]
                    |> Query.findAll [ class "bg-theme-option" ]
                    |> Query.count (Expect.equal (List.length Games.Backgammon.View.themes))
        , test "an option picks its board" <|
            \_ ->
                home (send GameLanding.ToggledThemes loadedModel)
                    |> Query.find [ attribute (Html.Attributes.attribute "data-theme-option" "sand") ]
                    |> Event.simulate Event.click
                    |> Event.expect (GameLanding.PickedTheme "sand")
        , test "picking one changes the board's class at once and closes the list" <|
            \_ ->
                loadedModel
                    |> send GameLanding.ToggledThemes
                    |> send (GameLanding.PickedTheme "sand")
                    |> home
                    |> Expect.all
                        [ Query.find [ class "home-board" ] >> Query.has [ class "bg-theme-sand" ]
                        , Query.find [ class "home-board" ] >> Query.hasNot [ class "bg-theme-midnight" ]
                        , Query.hasNot [ id "bg-theme-list" ]
                        ]
        , test "and tells the shell to keep it" <|
            \_ ->
                GameLanding.update (GameLanding.PickedTheme "sand") loadedModel
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.ChoseTheme "sand")
        ]



-- THE INVITE


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
                        , Query.has [ text "Match to 5 · 5 min" ]
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
        , test "an invite is its own page, not the home board" <|
            \_ ->
                invite Catalog.Open
                    |> Expect.all
                        [ Query.hasNot [ class "home-board" ]
                        , Query.hasNot [ id "start-game" ]
                        ]
        , test "the home page is only the page with no room in the URL" <|
            \_ ->
                ( GameLanding.isHome loadedModel
                , GameLanding.isHome (page { guestName = Nothing } "backgammon" (Just "123456"))
                )
                    |> Expect.equal ( True, False )
        ]



-- HARNESS


loadedModel : GameLanding.Model
loadedModel =
    page { guestName = Just "Alice" } "backgammon" Nothing
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))



-- YOUR GAMES


resume : Test
resume =
    describe "the games you can resume"
        [ test "arriving with games open, the list is over the board, one row each, a link to the seat" <|
            \_ ->
                home withGames
                    |> Expect.all
                        [ Query.has [ id "resume-modal", text "LIVE GAMES", text "Tap one to rejoin." ]
                        , Query.find [ id "resume-list" ] >> Query.children [] >> Query.count (Expect.equal 2)
                        , Query.find [ id "resume-123456" ] >> Query.has [ attribute (Html.Attributes.href "/backgammon/123456"), text "vs Bob", text "Match to 5", text "5 min", text "2 min ago", text "YOUR MOVE" ]
                        , Query.find [ id "resume-9H302Z" ] >> Query.has [ text "Waiting for a player", text "LOBBY" ]
                        ]
        , test "the bar's button says how many are waiting, and what to do" <|
            \_ ->
                home withGames
                    |> Query.find [ id "resume-games" ]
                    |> Query.has [ text "REJOIN 2 GAMES" ]
        , test "closing it leaves the board and the bar's button" <|
            \_ ->
                home (send GameLanding.ClosedResume withGames)
                    |> Expect.all
                        [ Query.hasNot [ id "resume-modal" ]
                        , Query.has [ id "start-game" ]
                        , Query.has [ id "resume-games" ]
                        ]
        , test "the ✕ closes it" <|
            \_ ->
                home withGames
                    |> Query.find [ id "close-resume" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.ClosedResume
        , test "and the bar's button opens it again" <|
            \_ ->
                home (send GameLanding.ClosedResume withGames)
                    |> Query.find [ id "resume-games" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.OpenedResume
        , test "Escape is listened for only while it is open" <|
            \_ ->
                Expect.all
                    [ \m -> Expect.notEqual Sub.none (GameLanding.subscriptions m)
                    , \m -> Expect.equal Sub.none (GameLanding.subscriptions (send GameLanding.ClosedResume m))
                    ]
                    withGames
        , test "a visitor with nothing to resume sees neither the list nor the button, and the bar shows pips" <|
            \_ ->
                home (send (GameLanding.GotMyGames (Ok [])) loadedModel)
                    |> Expect.all
                        [ Query.hasNot [ id "resume-modal" ]
                        , Query.hasNot [ id "resume-games" ]
                        , Query.has [ class "bar-pips" ]
                        ]
        , test "the list failing to come changes nothing" <|
            \_ ->
                home (send (GameLanding.GotMyGames (Err Api.NetworkError)) loadedModel)
                    |> Query.hasNot [ id "resume-modal" ]
        , test "one game is REJOIN 1 GAME, and their move is quiet" <|
            \_ ->
                home (send (GameLanding.GotMyGames (Ok [ { playing | yourMove = False } ])) loadedModel)
                    |> Expect.all
                        [ Query.find [ id "resume-games" ] >> Query.has [ text "REJOIN 1 GAME" ]
                        , Query.find [ id "resume-123456" ] >> Query.has [ text "THEIR MOVE" ]
                        ]
        , test "the menu is still its four entries: the button lives in the bar, not the band" <|
            \_ ->
                home withGames
                    |> Query.find [ class "home-menu" ]
                    |> Query.children []
                    |> Query.count (Expect.equal 4)
        ]


playing : Catalog.MyGame
playing =
    { slug = "backgammon"
    , id = "123456"
    , path = "/backgammon/123456"
    , status = "playing"
    , opponent = Just "Bob"
    , format = "Match to 5"
    , clock = Just "5 min"
    , yourMove = True
    , idleS = 150
    }


lobby : Catalog.MyGame
lobby =
    { slug = "backgammon"
    , id = "9H302Z"
    , path = "/backgammon/9H302Z"
    , status = "waiting"
    , opponent = Nothing
    , format = "Single game"
    , clock = Nothing
    , yourMove = False
    , idleS = 30
    }


{-| The home page after the games this browser holds a seat in arrived.
-}
withGames : GameLanding.Model
withGames =
    send (GameLanding.GotMyGames (Ok [ playing, lobby ])) loadedModel


{-| The home page with CREATE GAME pressed.
-}
opened : GameLanding.Model
opened =
    send GameLanding.Started loadedModel


{-| The same page for a visitor the site has never seen: an empty name field.
-}
blankModel : GameLanding.Model
blankModel =
    page { guestName = Nothing } "backgammon" Nothing
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))


invite : Catalog.RoomState -> Query.Single GameLanding.Msg
invite state =
    page { guestName = Nothing } "backgammon" (Just "123456")
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))
        |> send
            (GameLanding.GotRoom
                (Ok
                    { state = state
                    , inviterName = Just "Alice"
                    , summary = Just "Match to 5 · 5 min"
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
    GameLanding.init (session guestName []) slug gameId
        |> (\( model, _, _ ) -> model)


{-| The home page for a visitor with display preferences kept.
-}
pageWith : { guestName : Maybe String, prefs : List ( String, String ) } -> GameLanding.Model
pageWith { guestName, prefs } =
    GameLanding.init (session guestName prefs) "backgammon" Nothing
        |> (\( model, _, _ ) -> model)
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))


session : Maybe String -> List ( String, String ) -> Session
session guestName prefs =
    { csrf = "token", guestName = guestName, prefs = Dict.fromList prefs }


send : GameLanding.Msg -> GameLanding.Model -> GameLanding.Model
send msg model =
    GameLanding.update msg model |> (\( updated, _, _ ) -> updated)


{-| The invite page, as `Main` frames it.
-}
render : GameLanding.Model -> Query.Single GameLanding.Msg
render model =
    GameLanding.view model |> Query.fromHtml


{-| The home page as `Main` draws it: the board, with the shell's JOIN GAME
(here wired to `NoOp`) in its menu.
-}
home : GameLanding.Model -> Query.Single GameLanding.Msg
home model =
    Html.div [] (GameLanding.home { join = Shell.joinButton shell, toMsg = identity } model)
        |> Query.fromHtml


shell : Shell.Config GameLanding.Msg
shell =
    { joinOpen = False
    , joinCode = ""
    , joinError = Nothing
    , onOpenJoin = GameLanding.NoOp
    , onCloseJoin = GameLanding.NoOp
    , onJoinCodeInput = \_ -> GameLanding.NoOp
    , onJoinSubmit = GameLanding.NoOp
    }


disabled : Test.Html.Selector.Selector
disabled =
    attribute (Html.Attributes.attribute "aria-disabled" "true")


selected : Bool -> Test.Html.Selector.Selector
selected on =
    attribute (Html.Attributes.selected on)


value : String -> Test.Html.Selector.Selector
value v =
    attribute (Html.Attributes.value v)


{-| What `/papi/games/backgammon` answers, trimmed to what the page reads.
-}
gameJson : String
gameJson =
    """
    {"ok":true,
     "game":{"slug":"backgammon","name":"Backgammon","description":"The classic race game.",
             "default_clock":"none","clocks":["none","bg3","bg5","bg10"],"formats":[]},
     "formats":[
       {"id":"single","name":"Single game","description":"One game, no cube","settings":[TWIST]},
       {"id":"match3","name":"Match to 3","description":"Cube and Crawford rule","settings":[TWIST]},
       {"id":"match5","name":"Match to 5","description":"Cube and Crawford rule","settings":[TWIST]},
       {"id":"match7","name":"Match to 7","description":"Cube and Crawford rule","settings":[TWIST]},
       {"id":"unlimited","name":"Unlimited","description":"Keep playing, cube and Jacoby rule","settings":[TWIST]}],
     "clock_presets":[
       {"id":"none","name":"No clock","description":"Take your time"},
       {"id":"bg3","name":"3 min","description":"3 min each, 12 s delay every move"},
       {"id":"bg5","name":"5 min","description":"5 min each, 12 s delay every move"},
       {"id":"bg10","name":"10 min","description":"10 min each, 12 s delay every move"},
       {"id":"blitz","name":"Blitz","description":"3 min + 2 s per move"}],
     "copy":{"title":"Play backgammon online with a friend",
             "description":"Backgammon from a link.","intro":"From a link.",
             "rules":["Race your fifteen checkers home."],
             "faq":[]}}
    """
        |> String.replace "TWIST"
            """{"id":"twist","name":"Pick dice","default":"off",
                "choices":[{"id":"off","name":"Off"},{"id":"pick_dice","name":"Pick your dice, once a game"}]}"""
