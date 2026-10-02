module GameLandingTest exposing (suite)

{-| The guest home and the invite: the name check; the home's title, board,
sentence and PLAY NOW (the menus, Sage at once, a friend's name first);
CREATE GAME's dialog as the signed-in home opens it (its dropdowns, the
defaults, the summary, the inline errors); the board picker; the live games
behind the bar's pill; and the invite's three states.
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
import Time
import Ui.Shell as Shell


suite : Test
suite =
    describe "Page.GameLanding"
        [ names
        , homeBoard
        , createDialog
        , opponents
        , picking
        , submitting
        , boardPicker
        , invites
        , resume
        , accounts
        ]



-- SIGNING IN


accounts : Test
accounts =
    describe "signing in"
        [ test "the button says Sign up, and presses" <|
            \_ ->
                home withGamesOpen
                    |> Query.find [ id "signup-cta" ]
                    |> Expect.all
                        [ Query.has [ text "Sign up" ]
                        , Event.simulate Event.click >> Event.expect GameLanding.OpenedSignIn
                        ]
        , test "pressed, the sign-in opens in the panel, under the same promise" <|
            \_ ->
                withGamesOpen
                    |> send GameLanding.OpenedSignIn
                    |> home
                    |> Query.find [ id "guest-note" ]
                    |> Expect.all
                        [ Query.has [ id "signin-email", text "Track progress" ]
                        , Query.hasNot [ id "signup-cta" ]
                        ]
        , test "signed in, the list is just their games: no pitch at all" <|
            \_ ->
                home (signedInAs "her@example.com" withGamesOpen)
                    |> Expect.all
                        [ Query.has [ id "resume-list" ]
                        , Query.hasNot [ id "guest-note" ]
                        ]
        , test "signed in, ☰ names the account, with Log out under it" <|
            \_ ->
                signedInAs "her@example.com" (send GameLanding.ToggledNav withGames)
                    |> Expect.all
                        [ home >> Query.find [ id "nav-who" ] >> Query.has [ text "arie1", attribute (Html.Attributes.attribute "data-identity" "account") ]
                        -- the username, never the email: the bar is on screen for anyone
                        , home >> Query.hasNot [ text "her@example.com" ]
                        , home >> Query.hasNot [ id "nav-signin" ]
                        , home >> Query.find [ id "nav-logout" ] >> Query.has [ text "Log out" ]
                        , home >> Query.find [ id "nav-logout" ] >> Event.simulate Event.click >> Event.expect GameLanding.PressedLogOut
                        ]
        , test "for an account, ☰ leads with PLAY, which opens CREATE GAME and closes ☰" <|
            \_ ->
                signedInAs "her@example.com" (send GameLanding.ToggledNav withGames)
                    |> Expect.all
                        [ home >> Query.find [ id "nav-menu" ] >> Query.has [ id "home-play", text "Play" ]
                        , home >> Query.find [ id "home-play" ] >> Event.simulate Event.click >> Event.expect GameLanding.Started
                        , send GameLanding.Started >> home >> Query.hasNot [ id "nav-menu" ]
                        ]
        , test "a guest's ☰ says Sign in, which opens the sign-in" <|
            \_ ->
                withGames
                    |> Expect.all
                        [ send GameLanding.ToggledNav >> home >> Query.find [ id "nav-signin" ] >> Query.has [ text "Sign in" ]
                        , send GameLanding.ToggledNav >> home >> Query.find [ id "nav-signin" ] >> Event.simulate Event.click >> Event.expect GameLanding.PressedSignInMenu
                        , send GameLanding.PressedSignInMenu >> home >> Query.find [ id "signin-modal" ] >> Query.has [ id "signin-email" ]
                        -- the games list arriving after that sign-in must not open
                        -- LIVE GAMES underneath it (one win, not two)
                        , send GameLanding.PressedSignInMenu
                            >> send (GameLanding.GotMyGames (Ok [ playing ]))
                            >> home
                            >> Query.hasNot [ id "resume-modal" ]
                        ]
        , test "an invite whose seat belongs to an account says so, offers nothing to claim, and offers the sign-in" <|
            \_ ->
                inviteWith Catalog.Owned
                    |> Expect.all
                        [ Query.find [ id "seat-owned" ] >> Query.has [ text "This seat belongs to an account.", text "Sign in as that player to play it here.", id "signin-email" ]
                        , Query.hasNot [ id "join-name" ]
                        , Query.findAll [ tag "button", attribute (Html.Attributes.attribute "id" "reclaim-p1") ] >> Query.count (Expect.equal 0)
                        ]
        ]


signedInAs : String -> GameLanding.Model -> GameLanding.Model
signedInAs email model =
    let
        s =
            model.session
    in
    GameLanding.withSession { s | user = Just { email = email, name = Just "arie1" } } model


inviteWith : Catalog.RoomState -> Query.Single GameLanding.Msg
inviteWith state =
    page { guestName = Nothing } "backgammon" (Just "123456")
        |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))
        |> send (GameLanding.GotRoom (Ok { state = state, inviterName = Just "Alice", summary = Nothing, disconnected = [] }))
        |> render



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
        [ test "is OSKOL, the line under it, the board and the way in" <|
            \_ ->
                home loadedModel
                    |> Expect.all
                        [ Query.find [ class "lh-title" ] >> Query.has [ text "OSKOL" ]
                        , Query.find [ class "lh-tagline" ] >> Query.has [ text "Play backgammon." ]
                        , Query.has [ tag "oskol-demo-board" ]
                        , Query.has [ id "sentence" ]
                        , Query.has [ id "roll-dice" ]
                        ]
        , test "the board is in the default colours" <|
            \_ -> home loadedModel |> Query.find [ class "lh-board" ] |> Query.has [ class "bg-theme-midnight" ]
        , test "draws at once, before the game's data has come" <|
            \_ ->
                home (page { guestName = Nothing } "backgammon" Nothing)
                    |> Expect.all [ Query.has [ id "roll-dice" ], Query.find [ id "sentence" ] >> Query.has [ text "a single game" ] ]
        , test "the sentence starts on a single game against Sage with no clock" <|
            \_ ->
                home loadedModel
                    |> Query.find [ id "sentence" ]
                    |> Expect.all
                        [ Query.find [ id "pick-game" ] >> Query.has [ text "a single game" ]
                        , Query.find [ id "pick-who" ] >> Query.has [ text "Sage" ]
                        , Query.find [ id "sage-clock" ] >> Query.has [ text "no clock" ]
                        , Query.hasNot [ id "pick-clock" ]
                        ]
        , test "and the button rolls the dice" <|
            \_ -> home loadedModel |> Query.find [ id "roll-dice" ] |> Query.has [ text "Play now" ]
        , test "a word of the sentence opens its menu" <|
            \_ ->
                home loadedModel
                    |> Query.find [ id "pick-game" ]
                    |> Event.simulate Event.click
                    |> Event.expect (GameLanding.ToggledMenu GameLanding.GameMenu)
        , test "the game's menu is every format, in the sentence's words, the current one marked" <|
            \_ ->
                home (send (GameLanding.ToggledMenu GameLanding.GameMenu) loadedModel)
                    |> Query.find [ id "pick-game-menu" ]
                    |> Expect.all
                        [ Query.findAll [ attribute (Html.Attributes.attribute "role" "option") ] >> Query.count (Expect.equal 8)
                        , Query.find [ id "pick-game-single" ] >> Query.has [ text "a single game", attribute (Html.Attributes.attribute "aria-selected" "true") ]
                        , Query.find [ id "pick-game-match21" ] >> Query.has [ text "a match to 21" ]
                        , Query.find [ id "pick-game-unlimited" ] >> Query.has [ text "an unlimited match" ]
                        ]
        , test "picking a game says it in the sentence and closes the menu" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.ToggledMenu GameLanding.GameMenu)
                    |> send (GameLanding.PickedFormat "match7")
                    |> home
                    |> Expect.all
                        [ Query.find [ id "pick-game" ] >> Query.has [ text "a match to 7" ]
                        , Query.hasNot [ id "pick-game-menu" ]
                        ]
        , test "against a friend the clock is a menu too, and the button gets a link" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> home
                    |> Expect.all
                        [ Query.find [ id "pick-who" ] >> Query.has [ text "a friend" ]
                        , Query.find [ id "pick-clock" ] >> Query.has [ text "no clock" ]
                        , Query.hasNot [ id "sage-clock" ]
                        , Query.find [ id "roll-dice" ] >> Query.has [ text "Get a link" ]
                        ]
        , test "the clock's menu is the seven the game offers, in words" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> send (GameLanding.ToggledMenu GameLanding.ClockMenu)
                    |> home
                    |> Query.find [ id "pick-clock-menu" ]
                    |> Expect.all
                        [ Query.findAll [ attribute (Html.Attributes.attribute "role" "option") ] >> Query.count (Expect.equal 7)
                        , Query.find [ id "pick-clock-bg5" ] >> Query.has [ text "a 5 min clock" ]
                        , Query.hasNot [ text "Blitz" ]
                        ]
        , test "Escape closes an open menu" <|
            \_ -> Expect.notEqual Sub.none (GameLanding.subscriptions (send (GameLanding.ToggledMenu GameLanding.WhoMenu) loadedModel))
        , test "against Sage, PLAY NOW makes the game at once, under the remembered name" <|
            \_ ->
                send GameLanding.RolledDice loadedModel
                    |> Expect.all [ .busy >> Expect.equal True, .friendAsk >> Expect.equal False, .playerName >> Expect.equal "Alice" ]
        , test "a visitor with no name plays Sage as Guest" <|
            \_ -> send GameLanding.RolledDice blankModel |> .playerName |> Expect.equal "Guest"
        , test "and \"Guest\" is not offered back as a name to a friend" <|
            \_ ->
                page { guestName = Just "Guest" } "backgammon" Nothing
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> send GameLanding.RolledDice
                    |> .playerName
                    |> Expect.equal ""
        , test "and never as Sage, which the room refuses beside the bot" <|
            \_ ->
                page { guestName = Just "sage" } "backgammon" Nothing
                    |> send GameLanding.RolledDice
                    |> .playerName
                    |> Expect.equal "Guest"
        , test "the dice tumble while the game is made" <|
            \_ -> home (send GameLanding.RolledDice loadedModel) |> Query.find [ id "roll-dice" ] |> Query.has [ class "is-rolling" ]
        , test "a game made while the dice are in the air waits for them to land" <|
            \_ ->
                GameLanding.update (GameLanding.Seated (Ok { id = "123456", path = "/backgammon/123456" })) (send GameLanding.RolledDice loadedModel)
                    |> (\( model, _, out ) -> ( out, model.tumbling ))
                    |> Expect.equal ( GameLanding.NoOut, True )
        , test "and then it is the seat to go to" <|
            \_ ->
                loadedModel
                    |> send GameLanding.RolledDice
                    |> send (GameLanding.Seated (Ok { id = "123456", path = "/backgammon/123456" }))
                    |> GameLanding.update GameLanding.DiceLanded
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.TookSeat { name = "Alice", path = "/backgammon/123456" })
        , test "a game made after the dice landed goes at once" <|
            \_ ->
                loadedModel
                    |> send GameLanding.RolledDice
                    |> send GameLanding.DiceLanded
                    |> GameLanding.update (GameLanding.Seated (Ok { id = "123456", path = "/backgammon/123456" }))
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.TookSeat { name = "Alice", path = "/backgammon/123456" })
        , test "and the dice keep tumbling until it has" <|
            \_ -> home (send GameLanding.DiceLanded (send GameLanding.RolledDice loadedModel)) |> Query.find [ id "roll-dice" ] |> Query.has [ class "is-rolling" ]
        , test "against a friend, a guest is asked for the name the friend will read" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> send GameLanding.RolledDice
                    |> Expect.all
                        [ .busy >> Expect.equal False
                        , home >> Query.find [ id "friend-modal" ] >> Query.has [ id "friend-name", text "Invite a friend", id "friend-go" ]
                        ]
        , test "the name dialog submits, and a blank name is refused in it" <|
            \_ ->
                blankModel
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> send GameLanding.RolledDice
                    |> Expect.all
                        [ home >> Query.find [ id "friend-modal" ] >> Query.find [ tag "form" ] >> Event.simulate Event.submit >> Event.expect GameLanding.Submitted
                        , send GameLanding.Submitted >> home >> Query.find [ id "friend-modal" ] >> Query.has [ id "form-error", text "Pick a display name first" ]
                        , send (GameLanding.NameChanged "Bob") >> send GameLanding.Submitted >> .busy >> Expect.equal True
                        ]
        , test "PUZZLES opens the practice home" <|
            \_ ->
                home (send GameLanding.ToggledNav loadedModel)
                    |> Query.find [ id "nav-puzzles" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.PressedPuzzles
        , test "and the shell is told where to go" <|
            \_ ->
                GameLanding.update GameLanding.PressedPuzzles loadedModel
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.Go "/puzzles")
        , test "ANALYSIS, right after PUZZLES, opens the analysis board" <|
            \_ ->
                home (send GameLanding.ToggledNav loadedModel)
                    |> Query.find [ id "nav-analysis" ]
                    |> Expect.all
                        [ Query.has [ text "Analysis" ]
                        , Event.simulate Event.click >> Event.expect GameLanding.PressedAnalysis
                        ]
        , test "and the shell is told to go to /analysis" <|
            \_ ->
                GameLanding.update GameLanding.PressedAnalysis loadedModel
                    |> (\( _, _, out ) -> out)
                    |> Expect.equal (GameLanding.Go "/analysis")
        , test "the menu's ways in, in order: Puzzles, Analysis, Join a game" <|
            \_ ->
                home (send GameLanding.ToggledNav loadedModel)
                    |> Query.find [ id "nav-menu" ]
                    |> Query.findAll [ tag "button" ]
                    |> Expect.all
                        [ Query.index 0 >> Query.has [ id "nav-puzzles" ]
                        , Query.index 1 >> Query.has [ id "nav-analysis" ]
                        , Query.index 2 >> Query.has [ id "nav-join-game" ]
                        ]
        , test "the bar is the bird, the themes and ☰, and nothing else, at every width" <|
            \_ ->
                home loadedModel
                    |> Query.find [ class "lh-bar" ]
                    |> Expect.all
                        [ Query.has [ class "lh-mark", id "bg-theme-button", id "nav-more" ]
                        , Query.hasNot [ id "nav-puzzles" ]
                        , Query.hasNot [ id "nav-join-game" ]
                        , Query.hasNot [ id "nav-signin" ]
                        ]
        , test "the guest's ☰ has no PLAY in it: PLAY NOW is under the board" <|
            \_ -> home (send GameLanding.ToggledNav loadedModel) |> Query.hasNot [ id "home-play" ]
        , test "everything but the themes is behind ☰, and its menu opens on a tap" <|
            \_ ->
                loadedModel
                    |> Expect.all
                        [ home >> Query.find [ id "nav-more" ] >> Event.simulate Event.click >> Event.expect GameLanding.ToggledNav
                        , home >> Query.hasNot [ id "nav-menu" ]
                        , send GameLanding.ToggledNav
                            >> home
                            >> Query.find [ id "nav-menu" ]
                            >> Expect.all
                                [ Query.has [ id "nav-puzzles", text "Puzzles" ]
                                , Query.has [ id "nav-analysis", text "Analysis" ]
                                , Query.has [ id "nav-join-game", text "Join a game" ]
                                , Query.hasNot [ id "nav-themes" ]
                                , Query.has [ id "nav-signin", text "Sign in" ]
                                , Query.hasNot [ id "nav-live" ]
                                ]
                        ]
        , test "a new page closes what the bar had open: the menu, CREATE GAME, the live games" <|
            \_ ->
                send GameLanding.Started (send GameLanding.ToggledNav withGamesOpen)
                    |> GameLanding.closeBar
                    |> home
                    |> Expect.all
                        [ Query.hasNot [ id "nav-menu" ]
                        , Query.hasNot [ id "create-modal" ]
                        , Query.hasNot [ id "resume-modal" ]
                        ]
        , test "the menu's JOIN asks the shell for the code prompt, and closes" <|
            \_ ->
                GameLanding.update GameLanding.PressedNavJoin (send GameLanding.ToggledNav loadedModel)
                    |> (\( model, _, out ) -> ( model.navOpen, out ))
                    |> Expect.equal ( False, GameLanding.OpenJoin )
        , test "the themes stay in the bar, beside ☰" <|
            \_ -> home loadedModel |> Query.find [ class "lh-bar" ] |> Query.has [ id "bg-theme-button", id "nav-more" ]
        , test "who is across the table has its icon: the robot for Sage, two people for a friend" <|
            \_ ->
                loadedModel
                    |> Expect.all
                        [ home >> Query.find [ id "pick-who" ] >> Expect.all [ Query.has [ text "Sage" ], Query.findAll [ tag "svg" ] >> Query.count (Expect.equal 1) ]
                        , send (GameLanding.PickedOpponent GameLanding.AFriend) >> home >> Query.find [ id "pick-who" ] >> Expect.all [ Query.has [ text "a friend" ], Query.findAll [ tag "svg" ] >> Query.count (Expect.equal 1) ]
                        , send (GameLanding.ToggledMenu GameLanding.WhoMenu) >> home >> Query.find [ id "pick-who-menu" ] >> Query.findAll [ tag "svg" ] >> Query.count (Expect.equal 2)
                        ]
        , test "with live games, ☰ wears a dot and its menu leads with them" <|
            \_ ->
                withGames
                    |> Expect.all
                        [ home >> Query.find [ id "nav-more" ] >> Query.has [ class "lh-burger-dot" ]
                        , send GameLanding.ToggledNav >> home >> Query.find [ id "nav-live" ] >> Query.has [ text "2 live games" ]
                        , send GameLanding.ToggledNav >> send GameLanding.OpenedResume >> home >> Query.has [ id "resume-modal" ]
                        ]
        , test "signed in, the menu is the account and Log out" <|
            \_ ->
                signedInAs "her@example.com" loadedModel
                    |> send GameLanding.ToggledNav
                    |> home
                    |> Query.find [ id "nav-menu" ]
                    |> Expect.all [ Query.has [ text "arie1", id "nav-logout" ], Query.hasNot [ id "nav-signin" ] ]
        , test "the board wears the colours this visitor picked" <|
            \_ ->
                pageWith { guestName = Nothing, prefs = [ ( "backgammon_theme", "sand" ) ] }
                    |> home
                    |> Query.find [ class "lh-board" ]
                    |> Query.has [ class "bg-theme-sand" ]
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
        [ test "is closed until the signed-in home's PLAY opens it" <|
            \_ -> dialog (createLoaded (Just "Alice")) |> Query.hasNot [ id "create-modal" ]
        , test "once opened it is a dialog" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-modal" ]
                    |> Query.has [ attribute (Html.Attributes.attribute "role" "dialog"), text "CREATE GAME" ]
        , test "it holds the name, the mode, the clock and START GAME" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.has [ id "create-name", text "YOUR NAME" ]
                        , Query.has [ id "create-mode", text "MODE" ]
                        , Query.has [ id "create-clock", text "CLOCK" ]
                        , Query.has [ id "create-summary" ]
                        , Query.find [ id "create-game" ] >> Query.has [ text "START GAME" ]
                        , Query.has [ id "close-create" ]
                        ]
        , -- The picker is the wire's own list, in the wire's own order: the
          -- long match lengths and the long clocks arrived with no change
          -- here, and this is what says so.
          test "the mode dropdown lists every format, the first chosen" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-mode" ]
                    |> Query.findAll [ tag "option" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 8)
                        , Query.index 0 >> Query.has [ text "Single game", selected True ]
                        , Query.index 2 >> Query.has [ text "Match to 5", value "match5", selected False ]
                        , Query.index 4 >> Query.has [ text "Match to 11", value "match11", selected False ]
                        , Query.index 6 >> Query.has [ text "Match to 21", value "match21", selected False ]
                        , Query.index 7 >> Query.has [ text "Unlimited", value "unlimited" ]
                        ]
        , test "the clock dropdown is the seven the game offers, each with its delay" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-clock" ]
                    |> Query.findAll [ tag "option" ]
                    |> Expect.all
                        [ Query.count (Expect.equal 7)
                        , Query.index 0 >> Query.has [ text "No clock", value "none", selected True ]
                        , Query.index 1 >> Query.has [ text "3 min + 12 s delay", value "bg3" ]
                        , Query.index 2 >> Query.has [ text "5 min + 12 s delay", value "bg5" ]
                        , Query.index 3 >> Query.has [ text "10 min + 12 s delay", value "bg10" ]
                        , Query.index 4 >> Query.has [ text "15 min + 12 s delay", value "bg15" ]
                        , Query.index 5 >> Query.has [ text "30 min + 12 s delay", value "bg30" ]
                        , Query.index 6 >> Query.has [ text "60 min + 12 s delay", value "bg60" ]
                        ]
        , test "a clock the game does not offer is not in it" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-clock" ]
                    |> Query.hasNot [ text "Blitz" ]
        , test "the summary says what the dropdowns add up to" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-summary" ]
                    |> Query.has [ text "Single game: one game, no cube. No clock." ]
        , test "the close button closes it" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "close-create" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.ClosedCreate
        , test "closed, it is gone" <|
            \_ ->
                dialog (send GameLanding.ClosedCreate opened)
                    |> Query.hasNot [ id "create-modal" ]
        , test "if the game's data never came, it says so instead of opening nothing" <|
            \_ ->
                createPage Nothing
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> send GameLanding.Started
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> dialog
                    |> Query.find [ id "create-modal" ]
                    |> Query.has [ id "form-error", text "Something went wrong" ]
        , test "and CREATE GAME asks for it again" <|
            \_ ->
                createPage Nothing
                    |> send (GameLanding.GotGame (Err (Api.ApiError { code = "server_error", message = "Something went wrong" })))
                    |> send GameLanding.Started
                    |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))
                    |> dialog
                    |> Query.find [ id "create-modal" ]
                    |> Query.has [ id "create-mode" ]
        , test "it waits for the game's data: opened early it shows nothing yet" <|
            \_ ->
                createPage Nothing
                    |> send GameLanding.Started
                    |> dialog
                    |> Query.hasNot [ id "create-modal" ]
        ]


-- THE OPPONENT


opponents : Test
opponents =
    describe "choosing an opponent"
        [ test "the dialog offers a friend or the bot, a friend chosen" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.has [ text "OPPONENT" ]
                        , Query.find [ id "create-opponent-friend" ]
                            >> Query.has
                                [ text "A FRIEND"
                                , text "send a link"
                                , attribute (Html.Attributes.attribute "aria-pressed" "true")
                                ]
                        , Query.find [ id "create-opponent-bot" ]
                            >> Query.has
                                [ text "THE BOT"
                                , text "Sage, 4-ply"
                                , attribute (Html.Attributes.attribute "aria-pressed" "false")
                                ]
                        ]
        , test "the bot tile picks the bot" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-opponent-bot" ]
                    |> Event.simulate Event.click
                    |> Event.expect (GameLanding.PickedOpponent GameLanding.TheBot)
        , test "with the bot picked, the clock goes and MODE keeps the row" <|
            \_ ->
                dialog (send (GameLanding.PickedOpponent GameLanding.TheBot) opened)
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.has [ id "create-mode" ]
                        , Query.hasNot [ id "create-clock" ]
                        , Query.findAll [ tag "select" ] >> Query.count (Expect.equal 1)
                        ]
        , test "the summary says who you are playing, and that there is no clock" <|
            \_ ->
                opened
                    |> send (GameLanding.PickedFormat "match7")
                    |> send (GameLanding.PickedOpponent GameLanding.TheBot)
                    |> dialog
                    |> Query.find [ id "create-summary" ]
                    |> Query.has [ text "Match to 7 against Sage. No clock." ]
        , test "the button and the footnote say the game starts now" <|
            \_ ->
                dialog (send (GameLanding.PickedOpponent GameLanding.TheBot) opened)
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.find [ id "create-game" ] >> Query.has [ text "PLAY SAGE" ]
                        , Query.has [ text "Starts now. Sage takes a few seconds a move." ]
                        ]
        , test "a clock picked before the bot was does not ride along" <|
            \_ ->
                opened
                    |> send (GameLanding.PickedClock "bg10")
                    |> send (GameLanding.PickedOpponent GameLanding.TheBot)
                    |> dialog
                    |> Query.find [ id "create-summary" ]
                    |> Query.has [ text "No clock." ]
        , test "going back to a friend brings the clock and the link back" <|
            \_ ->
                opened
                    |> send (GameLanding.PickedOpponent GameLanding.TheBot)
                    |> send (GameLanding.PickedOpponent GameLanding.AFriend)
                    |> dialog
                    |> Query.find [ id "create-modal" ]
                    |> Expect.all
                        [ Query.has [ id "create-clock" ]
                        , Query.find [ id "create-game" ] >> Query.has [ text "START GAME" ]
                        , Query.has [ text "You get a link to send. The game starts when your friend opens it." ]
                        ]
        ]


picking : Test
picking =
    describe "picking"
        [ test "a mode is picked from its dropdown" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-mode" ]
                    |> Event.simulate (Event.input "match5")
                    |> Event.expect (GameLanding.PickedFormat "match5")
        , test "picking a mode selects it and says so in the summary" <|
            \_ ->
                dialog (send (GameLanding.PickedFormat "match5") opened)
                    |> Expect.all
                        [ Query.find [ id "create-mode" ]
                            >> Query.find [ value "match5" ]
                            >> Query.has [ selected True ]
                        , Query.find [ id "create-summary" ]
                            >> Query.has [ text "Match to 5: cube and Crawford rule. No clock." ]
                        ]
        , test "the clock dropdown sends the clock picked" <|
            \_ ->
                dialog opened
                    |> Query.find [ id "create-clock" ]
                    |> Event.simulate (Event.input "bg10")
                    |> Event.expect (GameLanding.PickedClock "bg10")
        , test "a clock picked is selected, and the summary spells it out" <|
            \_ ->
                dialog (send (GameLanding.PickedClock "bg3") opened)
                    |> Expect.all
                        [ Query.find [ id "create-clock" ]
                            >> Query.find [ value "bg3" ]
                            >> Query.has [ selected True ]
                        , Query.find [ id "create-summary" ]
                            >> Query.has [ text "Single game: one game, no cube. 3 min each, 12 s delay every move." ]
                        ]
        , test "the dialog offers a mode and a clock, and nothing else" <|
            \_ ->
                dialog opened
                    |> Query.findAll [ tag "select" ]
                    |> Query.count (Expect.equal 2)
        ]


submitting : Test
submitting =
    describe "submitting"
        [ test "START GAME submits the dialog's form" <|
            \_ ->
                dialog opened
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
                blankCreate
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> dialog
                    |> Query.find [ id "create-modal" ]
                    |> Query.find [ id "form-error" ]
                    |> Query.has [ text "Pick a display name first" ]
        , test "a blank name does not reach the server" <|
            \_ ->
                blankCreate
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> .busy
                    |> Expect.equal False
        , test "a name that is fine leaves the dialog without an error" <|
            \_ ->
                blankCreate
                    |> send GameLanding.Started
                    |> send (GameLanding.NameChanged "Alice")
                    |> send GameLanding.Submitted
                    |> dialog
                    |> Query.hasNot [ id "form-error" ]
        , test "picking anything clears the error" <|
            \_ ->
                blankCreate
                    |> send GameLanding.Started
                    |> send GameLanding.Submitted
                    |> send (GameLanding.PickedFormat "match3")
                    |> dialog
                    |> Query.hasNot [ id "form-error" ]
        , test "a server error comes back as the same line in the dialog" <|
            \_ ->
                blankCreate
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
                    |> dialog
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
                        [ Query.find [ class "lh-board" ] >> Query.has [ class "bg-theme-sand" ]
                        , Query.find [ class "lh-board" ] >> Query.hasNot [ class "bg-theme-midnight" ]
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
                        [ Query.hasNot [ class "lh" ]
                        , Query.hasNot [ id "roll-dice" ]
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
        [ test "arriving with games opens nothing: ☰ has a dot, and offers them" <|
            \_ ->
                withGames
                    |> Expect.all
                        [ home >> Query.hasNot [ id "resume-modal" ]
                        , home >> Query.find [ id "nav-more" ] >> Query.has [ class "lh-burger-dot" ]
                        , send GameLanding.ToggledNav >> home >> Query.find [ id "nav-live" ] >> Query.has [ text "2 live games" ]
                        ]
        , test "☰'s live games open the list, one row each, a link to the seat" <|
            \_ ->
                home withGamesOpen
                    |> Expect.all
                        [ Query.has [ id "resume-modal", text "LIVE GAMES" ]
                        , Query.find [ id "signup-cta" ] >> Query.has [ text "Sign up" ]
                        , Query.find [ id "resume-list" ] >> Query.children [] >> Query.count (Expect.equal 2)
                        , Query.find [ id "resume-123456" ] >> Query.has [ attribute (Html.Attributes.href "/backgammon/123456"), text "Bob", text "Match to 5", text "2 min ago", text "Your move" ]
                        , Query.find [ id "resume-9H302Z" ] >> Query.has [ text "Waiting for a player", text "Lobby" ]
                        ]
        , test "closing it leaves the board, and ☰ its dot" <|
            \_ ->
                home (send GameLanding.ClosedResume withGamesOpen)
                    |> Expect.all
                        [ Query.hasNot [ id "resume-modal" ]
                        , Query.has [ id "roll-dice" ]
                        , Query.find [ id "nav-more" ] >> Query.has [ class "lh-burger-dot" ]
                        ]
        , test "the ✕ closes it" <|
            \_ ->
                home withGamesOpen
                    |> Query.find [ id "close-resume" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.ClosedResume
        , test "and ☰'s live games open it again" <|
            \_ ->
                home (send GameLanding.ToggledNav (send GameLanding.ClosedResume withGames))
                    |> Query.find [ id "nav-live" ]
                    |> Event.simulate Event.click
                    |> Event.expect GameLanding.OpenedResume
        , test "Escape is listened for only while it is open" <|
            \_ ->
                Expect.all
                    [ \m -> Expect.notEqual Sub.none (GameLanding.subscriptions m)
                    , \m -> Expect.equal Sub.none (GameLanding.subscriptions (send GameLanding.ClosedResume m))
                    ]
                    withGamesOpen
        , test "a visitor with nothing to resume sees neither the list, the dot nor the item" <|
            \_ ->
                home (send GameLanding.ToggledNav (send (GameLanding.GotMyGames (Ok [])) loadedModel))
                    |> Expect.all
                        [ Query.hasNot [ id "resume-modal" ]
                        , Query.hasNot [ class "lh-burger-dot" ]
                        , Query.hasNot [ id "nav-live" ]
                        ]
        , test "the list failing to come changes nothing" <|
            \_ ->
                home (send (GameLanding.GotMyGames (Err Api.NetworkError)) loadedModel)
                    |> Query.hasNot [ id "resume-modal" ]
        , test "one game is 1 live game, and their move is quiet" <|
            \_ ->
                send (GameLanding.GotMyGames (Ok [ { playing | yourMove = False } ])) loadedModel
                    |> Expect.all
                        [ send GameLanding.ToggledNav >> home >> Query.find [ id "nav-live" ] >> Query.has [ text "1 live game" ]
                        , send GameLanding.OpenedResume >> home >> Query.find [ id "resume-123456" ] >> Query.has [ text "Their move" ]
                        ]
        , test "the clocks show as of the row, the running side charged for the time since" <|
            \_ ->
                -- 171 s left, running, read 150 s ago: 21 s show; the other side is whole.
                home withGamesOpen
                    |> Query.find [ id "resume-123456" ]
                    |> Query.has [ text "0:21", text "3:00" ]
        , test "my running clock breathes; theirs does not" <|
            \_ ->
                Expect.all
                    [ \m -> home m |> Query.find [ id "resume-123456" ] |> Query.find [ class "clock-live" ] |> Query.has [ text "0:21" ]
                    , \m ->
                        m
                            |> send (GameLanding.GotMyGames (Ok [ { playing | time = Just { mineMs = 171000, theirsMs = 180000, running = Catalog.Theirs, freeMs = 0, ageS = 150 } } ]))
                            |> send GameLanding.OpenedResume
                            |> home
                            |> Query.hasNot [ class "clock-live" ]
                    ]
                    withGamesOpen
        , test "and the seconds tick while the list is open" <|
            \_ ->
                withGamesOpen
                    |> send (GameLanding.ListArrived (Time.millisToPosix 1000000))
                    |> send (GameLanding.Tick (Time.millisToPosix 1010000))
                    |> home
                    |> Query.find [ id "resume-123456" ]
                    |> Query.has [ text "0:11", text "3:00" ]
        , test "the free time on the move is spent before the bank is" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.GotMyGames (Ok [ { playing | time = Just { mineMs = 180000, theirsMs = 180000, running = Catalog.Mine, freeMs = 12000, ageS = 5 } } ]))
                    |> send GameLanding.OpenedResume
                    |> home
                    |> Query.find [ id "resume-123456" ]
                    |> Query.findAll [ class "clock-mine", class "clock-live" ]
                    |> Query.count (Expect.equal 0)
        , test "the free time on the move is spent before the bank is (the running side shows the whole bank)" <|
            \_ ->
                loadedModel
                    |> send (GameLanding.GotMyGames (Ok [ { playing | time = Just { mineMs = 180000, theirsMs = 180000, running = Catalog.Mine, freeMs = 12000, ageS = 5 } } ]))
                    |> send GameLanding.OpenedResume
                    |> home
                    |> Query.find [ id "resume-123456" ]
                    |> Query.find [ class "clock-live" ]
                    |> Query.has [ text "3:00" ]
        , test "the pitch under the list names what an account is for, and the games it would keep" <|
            \_ ->
                home withGamesOpen
                    |> Query.find [ id "guest-note" ]
                    |> Query.has [ text "logged in as a guest on this device", text "Mistake practice", text "Game analysis", text "Track progress", text "Opening guide", text "Match history", text "Every device", id "signup-cta" ]
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
    , closable = False
    , time = Just { mineMs = 171000, theirsMs = 180000, running = Catalog.Mine, freeMs = 0, ageS = 150 }
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
    , closable = True
    , time = Nothing
    , idleS = 30
    }


{-| The home page after the games this browser holds a seat in arrived.
-}
withGames : GameLanding.Model
withGames =
    send (GameLanding.GotMyGames (Ok [ playing, lobby ])) loadedModel


{-| The same, with the bar's "2 live games" pressed. -}
withGamesOpen : GameLanding.Model
withGamesOpen =
    send GameLanding.OpenedResume withGames


{-| CREATE GAME's dialog opened, as the signed-in home opens it
(`GameLanding.createOnly`, then `Started`).
-}
opened : GameLanding.Model
opened =
    send GameLanding.Started (createLoaded (Just "Alice"))


createPage : Maybe String -> GameLanding.Model
createPage guestName =
    GameLanding.createOnly (session guestName []) "backgammon" |> Tuple.first


createLoaded : Maybe String -> GameLanding.Model
createLoaded guestName =
    createPage guestName |> send (GameLanding.GotGame (Api.parseBody Catalog.gamePageDecoder gameJson))


{-| The dialog for a visitor the site has never seen: an empty name field.
-}
blankCreate : GameLanding.Model
blankCreate =
    createLoaded Nothing


dialog : GameLanding.Model -> Query.Single GameLanding.Msg
dialog model =
    Html.div [] [ GameLanding.createModal model ] |> Query.fromHtml


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
    { csrf = "token", guestName = guestName, prefs = Dict.fromList prefs, user = Nothing }


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
    Html.div [] (GameLanding.home (GameLanding.navBar identity model) identity model ++ GameLanding.barModals model)
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
             "default_clock":"none","clocks":["none","bg3","bg5","bg10","bg15","bg30","bg60"],"formats":[]},
     "formats":[
       {"id":"single","name":"Single game","description":"One game, no cube"},
       {"id":"match3","name":"Match to 3","description":"Cube and Crawford rule"},
       {"id":"match5","name":"Match to 5","description":"Cube and Crawford rule"},
       {"id":"match7","name":"Match to 7","description":"Cube and Crawford rule"},
       {"id":"match11","name":"Match to 11","description":"Cube and Crawford rule"},
       {"id":"match15","name":"Match to 15","description":"Cube and Crawford rule"},
       {"id":"match21","name":"Match to 21","description":"Cube and Crawford rule"},
       {"id":"unlimited","name":"Unlimited","description":"Keep playing, cube and Jacoby rule"}],
     "clock_presets":[
       {"id":"none","name":"No clock","description":"Take your time"},
       {"id":"bg3","name":"3 min","description":"3 min each, 12 s delay every move"},
       {"id":"bg5","name":"5 min","description":"5 min each, 12 s delay every move"},
       {"id":"bg10","name":"10 min","description":"10 min each, 12 s delay every move"},
       {"id":"bg15","name":"15 min","description":"15 min each, 12 s delay every move"},
       {"id":"bg30","name":"30 min","description":"30 min each, 12 s delay every move"},
       {"id":"bg60","name":"60 min","description":"60 min each, 12 s delay every move"},
       {"id":"blitz","name":"Blitz","description":"3 min + 2 s per move"}],
     "copy":{"title":"Play backgammon online with a friend",
             "description":"Backgammon from a link.","intro":"From a link.",
             "rules":["Race your fifteen checkers home."],
             "faq":[]}}
    """
