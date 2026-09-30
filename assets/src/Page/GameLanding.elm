module Page.GameLanding exposing
    ( Model
    , Msg(..)
    , Opponent(..)
    , PickMenu(..)
    , Out(..)
    , cleanName
    , createModal
    , createOnly
    , home
    , init
    , isHome
    , signingIn
    , subscriptions
    , themePicker
    , title
    , update
    , view
    , withSession
    )

{-| `/` (and `/:slug`) — the game's start page.

Without a room in the URL it is the guest's home page (`home`): OSKOL over
"Play backgammon.", a big board playing a game by itself, and one sentence
that is the whole of the choice -- "Play [a single game] against [Sage]
with no clock" -- over one yellow PLAY NOW. Against Sage that starts the
game there and then; against a friend it asks for a name and takes the
seat, and the table is where the link is. With `?game=` it is
the invite that link opens, and what it offers depends on the table (see
`Api.Catalog.Room`): a free seat, a seat whose player is away, or nothing at
all. A seat whose player is away is offered to whoever asks: a seat is
held by the browser that took it, and one nobody is holding is free for
the taking -- friends playing, not security.

This is also where a browser holding no seat at a room ends up: the table
sends it here when the room will not have it, and here it finds out
whether there is a seat for it at all.

The waiting room the LiveView showed here moved to the game page: a room
with no instance yet answers the game channel with a lobby payload, so the
seat waits where it will play, on a live connection rather than a poll.

-}

import Api
import Api.Auth as Auth
import Browser.Events
import Dict
import Api.Catalog as Catalog exposing (ClockPreset, Format, GamePage, MyGame, RoomSeat)
import Html exposing (Html)
import Json.Decode as D
import Process
import Task
import Time
import Html.Attributes exposing (class, classList, href, id)
import Html.Events exposing (onClick, onSubmit)
import Svg
import Svg.Attributes as SvgAttr
import Games.Backgammon.View
import Route
import Session exposing (Session)
import Ui.Identity as Identity
import Ui.LiveGames as LiveGames
import Ui.Notebook as Notebook exposing (style)
import Ui.SignIn as SignIn


{-| Which of the game page's forms is showing, mirroring the LiveView's
`step` assign.
-}
type Step
    = Create
    | PlayerName
    | TableFull
    | SeatOwned
    | Reconnect


{-| Who the creator wants across the table. A friend gets the link this page
has always handed out; the bot sits down at once and the game starts.
-}
type Opponent
    = AFriend
    | TheBot


{-| Which word of the home page's sentence has its menu open.
-}
type PickMenu
    = GameMenu
    | WhoMenu
    | ClockMenu


type alias Model =
    { session : Session
    , slug : String
    , gameId : Maybe String
    , page : Maybe GamePage
    , loadError : Maybe String
    , step : Step
    , format : String
    , clock : String
    , opponent : Opponent
    , playerName : String
    , error : Maybe String
    , inviterName : Maybe String
    , summary : Maybe String
    , disconnected : List RoomSeat
    , busy : Bool
    , started : Bool -- the home page's START A GAME was pressed: show the settings
    , themesOpen : Bool -- the home board's colour list is showing
    , myGames : List MyGame -- the unfinished games this browser holds a seat in
    , resumeOpen : Bool -- the list of them is showing over the board
    , signInOpen : Bool -- the sign-in the guest's bar menu opens, in a dialog of its own
    , fetchedAt : Int -- when the list came, ms since the epoch: the clocks count from here
    , now : Int -- the clock the list's running times are read against
    , signIn : Maybe SignIn.Model -- signing in, open in LIVE GAMES or under an owned seat
    , accountOpen : Bool -- the account's menu on the player's own bar is showing
    , menu : Maybe PickMenu -- the home sentence's word whose menu is open
    , friendAsk : Bool -- PLAY NOW against a friend: the name it is asking for
    , navOpen : Bool -- on a phone, the bar's ☰ menu: all the wide bar carries but the themes
    , tumbling : Bool -- PLAY NOW's dice are still in the air: the table waits for them
    , seatWaiting : Maybe String -- the seat the server made while they were
    }


type Msg
    = GotGame (Result Api.Error GamePage)
    | GotRoom (Result Api.Error Catalog.Room)
    | PickedFormat String
    | PickedClock String
    | PickedOpponent Opponent
    | NameChanged String
    | Submitted
    | ReclaimedSeat String
    | Seated (Result Api.Error Catalog.Created)
    | Started
    | ClosedCreate
    | ToggledThemes
    | PickedTheme String
    | GotMyGames (Result Api.Error (List MyGame))
    | ClosedGame MyGame
    | GameClosed (Result Api.Error ())
    | ListArrived Time.Posix
    | Tick Time.Posix
    | OpenedResume
    | ClosedResume
    | PressedSignInMenu
    | ClosedSignIn
    | PrefSaved (Result Api.Error (Dict.Dict String String))
    | OpenedSignIn
    | SignInMsg SignIn.Msg
    | ToggledAccount
    | PressedPuzzles
    | PressedLogOut
    | LoggedOut (Result Api.Error ())
    | ToggledMenu PickMenu
    | ClosedMenu
    | RolledDice
    | ClosedFriendAsk
    | ToggledNav
    | PressedNavJoin
    | DiceLanded
    | NoOp


{-| What this page needs the shell to do. Routing and the session belong to
`Main`, so the page names the URL and the name and `Main` acts — which also
keeps the page a plain value the test suite can drive without a
`Browser.Navigation.Key`.
-}
type Out
    = NoOut
      -- A URL that was never a page: replace it rather than pushing it.
    | Redirect String
      -- A seat is ours: remember the name it was taken under, then go.
    | TookSeat { name : String, path : String }
      -- A board colour was picked: keep it in this browser and the session.
    | ChoseTheme String
      -- This browser just signed in: the shell re-reads who it is.
    | SignedIn Auth.SignedIn
      -- This browser just logged out: the same.
    | SignedOut
      -- Go on to a page of the site (after a sign-in, where it was asked from).
    | Go String
      -- Open the shell's code prompt (JOIN, from the phone bar's menu).
    | OpenJoin


init : Session -> String -> Maybe String -> ( Model, Cmd Msg, Out )
init session slug gameId =
    let
        model =
            { session = session
            , slug = slug
            , gameId = gameId
            , page = Nothing
            , loadError = Nothing
            , step =
                if gameId == Nothing then
                    Create

                else
                    PlayerName
            , format = "single"
            , clock = "none"
            , opponent =
                -- The home page's sentence starts on Sage: the one game that
                -- can start this second.
                if gameId == Nothing then
                    TheBot

                else
                    AFriend
            , playerName = Maybe.withDefault "" session.guestName
            , error = Nothing
            , inviterName = Nothing
            , summary = Nothing
            , disconnected = []
            , busy = False
            , started = False
            , themesOpen = False
            , myGames = []
            , resumeOpen = False
            , signInOpen = False
            , fetchedAt = 0
            , now = 0
            , signIn = Nothing
            , accountOpen = False
            , menu = Nothing
            , friendAsk = False
            , navOpen = False
            , tumbling = False
            , seatWaiting = Nothing
            }
    in
    case gameId of
        Just id_ ->
            ( model
            , Cmd.batch
                [ Catalog.fetchGame session slug GotGame
                , Catalog.fetchRoom session slug id_ GotRoom
                , Notebook.focus NoOp "join-name"
                ]
            , NoOut
            )

        Nothing ->
            ( model
            , Cmd.batch
                [ Catalog.fetchGame session slug GotGame
                , Catalog.fetchMyGames session GotMyGames
                ]
            , NoOut
            )


{-| CREATE GAME's dialog, and the board picker, on a page that is not this
one: the signed-in home (`Page.Home`) draws its own sections but starts a
game and picks a board through this page's model, `createModal` and
`themePicker`, so there are not two of either to keep in step.

It fetches the game's formats and clock presets and nothing else: the
games this browser holds are the home's own answer (`/papi/me/home`), so
asking `/papi/me/games` a second time here would cost a query for a list
that is already on the page.

-}
createOnly : Session -> String -> ( Model, Cmd Msg )
createOnly session slug =
    let
        ( model, _, _ ) =
            init session slug Nothing
    in
    -- CREATE GAME's dialog still opens on a friend, as it always has.
    ( { model | opponent = AFriend }, Catalog.fetchGame session slug GotGame )


title : Model -> String
title model =
    case model.page of
        Just page ->
            page.copy.title

        Nothing ->
            String.toUpper (String.left 1 model.slug) ++ String.dropLeft 1 model.slug



{-| What the shell learnt about this browser (`/papi/me`): signed in or
not.
-}
withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        OpenedSignIn ->
            if model.session.user == Nothing then
                let
                    ( signIn, cmd ) =
                        SignIn.init { next = signInNext model, email = "" }
                in
                ( { model | signIn = Just signIn }, Cmd.map SignInMsg cmd, NoOut )

            else
                ( model, Cmd.none, NoOut )

        SignInMsg signInMsg ->
            case model.signIn of
                Just signIn ->
                    let
                        ( next, cmd, out ) =
                            SignIn.update model.session signInMsg signIn

                        updated =
                            { model | signIn = Just next }
                    in
                    case out of
                        SignIn.NoOut ->
                            ( updated, Cmd.map SignInMsg cmd, NoOut )

                        -- Signed in: this browser's games are the account's
                        -- now, and the account's games from anywhere else
                        -- are this browser's. Ask again.
                        SignIn.SignedIn signedIn ->
                            ( updated
                            , Cmd.batch [ Cmd.map SignInMsg cmd, Catalog.fetchMyGames model.session GotMyGames ]
                            , SignedIn signedIn
                            )

                        SignIn.Continue path ->
                            case model.step of
                                -- Under an owned seat: on to the table.
                                SeatOwned ->
                                    ( { updated | signIn = Nothing }, Cmd.none, Go path )

                                -- In LIVE GAMES, or the bar's own dialog: back
                                -- to the page, which is theirs now.
                                _ ->
                                    ( { updated | signIn = Nothing, signInOpen = False }, Cmd.none, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        ToggledAccount ->
            ( { model | accountOpen = not model.accountOpen }, Cmd.none, NoOut )

        PressedPuzzles ->
            ( { model | navOpen = False }, Cmd.none, Go (Route.href Route.puzzles) )

        -- The guest's bar menu: the same sign-in, in a dialog of its own.
        PressedSignInMenu ->
            let
                ( opened, cmd, out ) =
                    update OpenedSignIn { model | accountOpen = False, resumeOpen = False, navOpen = False, signInOpen = True }
            in
            ( opened, cmd, out )

        ClosedSignIn ->
            ( { model | signInOpen = False, signIn = Nothing }, Cmd.none, NoOut )

        PressedLogOut ->
            ( { model | accountOpen = False, navOpen = False }, Auth.logout model.session LoggedOut, NoOut )

        -- The page stays: the bar goes back to the guest's name, and the
        -- list to the games this browser holds as a guest.
        LoggedOut _ ->
            ( { model | myGames = [], resumeOpen = False, signIn = Nothing }
            , Catalog.fetchMyGames model.session GotMyGames
            , SignedOut
            )

        Started ->
            case ( model.page, model.loadError ) of
                -- The game's data failed to come: ask again, and the dialog
                -- says what went wrong if it fails again.
                ( Nothing, Just _ ) ->
                    ( { model | started = True, loadError = Nothing }
                    , Catalog.fetchGame model.session model.slug GotGame
                    , NoOut
                    )

                _ ->
                    ( { model | started = True }, Cmd.none, NoOut )

        ToggledThemes ->
            ( { model | themesOpen = not model.themesOpen }, Cmd.none, NoOut )

        -- The games waiting for this browser: the nav offers them ("2 live
        -- games") and the list opens only when that is pressed. Nothing
        -- pops up over the page a player came to play on.
        GotMyGames (Ok games) ->
            ( { model | myGames = games, resumeOpen = model.resumeOpen && not (List.isEmpty games) }
            , Task.perform ListArrived Time.now
            , NoOut
            )

        -- The home page draws the same without it.
        GotMyGames (Err _) ->
            ( model, Cmd.none, NoOut )

        -- The ✕ on a lobby nobody joined. The row goes at once -- the
        -- player asked for it gone and the answer carries nothing to wait
        -- for -- and the list is read again when the server has answered,
        -- which is what puts it back if the close was refused.
        ClosedGame game ->
            ( { model | myGames = List.filter (\g -> g.id /= game.id) model.myGames }
            , Catalog.closeRoom model.session game.slug game.id GameClosed
            , NoOut
            )

        GameClosed _ ->
            ( model, Catalog.fetchMyGames model.session GotMyGames, NoOut )

        ListArrived posix ->
            ( { model | fetchedAt = Time.posixToMillis posix, now = Time.posixToMillis posix }, Cmd.none, NoOut )

        Tick posix ->
            ( { model | now = Time.posixToMillis posix }, Cmd.none, NoOut )

        OpenedResume ->
            ( { model | resumeOpen = True, navOpen = False }, Cmd.none, NoOut )

        ClosedResume ->
            ( { model | resumeOpen = False }, Cmd.none, NoOut )

        PickedTheme name ->
            -- The board changes at once; the shell keeps it in this browser
            -- and the session, and the guest's row keeps it for later.
            ( { model | themesOpen = False, session = Session.withPref themeKey name model.session }
            , Catalog.savePref model.session themeKey name PrefSaved
            , ChoseTheme name
            )

        PrefSaved _ ->
            ( model, Cmd.none, NoOut )

        ClosedCreate ->
            ( { model | started = False, error = Nothing }, Cmd.none, NoOut )

        GotGame (Ok page) ->
            ( { model
                | page = Just page
                , format = page.formats |> List.head |> Maybe.map .id |> Maybe.withDefault ""
                , clock = page.game.defaultClock
                , playerName =
                    if model.playerName == "" then
                        Maybe.withDefault "" page.guestName

                    else
                        model.playerName
              }
            , Cmd.none
            , NoOut
            )

        GotGame (Err err) ->
            ( { model | loadError = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        GotRoom (Ok room) ->
            case room.state of
                -- A seat this browser already holds: straight to the table.
                Catalog.Seated path ->
                    ( model, Cmd.none, Redirect path )

                _ ->
                    ( applyRoom room model, Cmd.none, NoOut )

        GotRoom (Err _) ->
            -- A room that cannot be read is a room to join by name, exactly
            -- as a room that is not there: joining never creates one, so the
            -- attempt is what says so.
            ( { model | step = PlayerName }, Cmd.none, NoOut )

        PickedFormat formatId ->
            ( { model | format = formatId, error = Nothing, menu = Nothing }, Cmd.none, NoOut )

        PickedClock clockId ->
            ( { model | clock = clockId, error = Nothing, menu = Nothing }, Cmd.none, NoOut )

        PickedOpponent opponent ->
            ( { model | opponent = opponent, error = Nothing, menu = Nothing }, Cmd.none, NoOut )

        ToggledMenu which ->
            ( { model
                | menu =
                    if model.menu == Just which then
                        Nothing

                    else
                        Just which
                , themesOpen = False
                , accountOpen = False
              }
            , Cmd.none
            , NoOut
            )

        ClosedMenu ->
            ( { model | menu = Nothing }, Cmd.none, NoOut )

        RolledDice ->
            roll model

        ClosedFriendAsk ->
            ( { model | friendAsk = False, error = Nothing }, Cmd.none, NoOut )

        ToggledNav ->
            ( { model | navOpen = not model.navOpen, menu = Nothing, themesOpen = False, accountOpen = False }, Cmd.none, NoOut )

        PressedNavJoin ->
            ( { model | navOpen = False }, Cmd.none, OpenJoin )

        NameChanged name ->
            ( { model | playerName = name }, Cmd.none, NoOut )

        Submitted ->
            submit model

        ReclaimedSeat playerId ->
            case model.gameId of
                Just gameId ->
                    ( { model | busy = True, error = Nothing }
                    , Catalog.claimSeat model.session model.slug gameId playerId Seated
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        -- The dice get their throw: a game made faster than they land waits
        -- for them (`DiceLanded`), so the button is never a blink.
        Seated (Ok created) ->
            if model.tumbling then
                ( { model | seatWaiting = Just created.path }, Cmd.none, NoOut )

            else
                ( { model | busy = False }
                , Cmd.none
                , TookSeat { name = model.playerName, path = created.path }
                )

        DiceLanded ->
            case model.seatWaiting of
                Just path ->
                    ( { model | tumbling = False, seatWaiting = Nothing, busy = False }
                    , Cmd.none
                    , TookSeat { name = model.playerName, path = path }
                    )

                Nothing ->
                    ( { model | tumbling = False }, Cmd.none, NoOut )

        Seated (Err err) ->
            ( { model | busy = False, tumbling = False, error = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        NoOp ->
            ( model, Cmd.none, NoOut )


{-| The account's username, when this browser is signed in: it plays under
that, and is not asked for a name.
-}
username : Model -> Maybe String
username model =
    model.session.user |> Maybe.andThen .name


{-| PLAY NOW. Against Sage the game is made there and then, under the
name this browser last played under (an account plays under its own); the
dice tumble while it is. Against a friend the friend will read the name
("Arie wants to play"), so a guest is asked for it first; an account is not.
-}
roll : Model -> ( Model, Cmd Msg, Out )
roll model =
    if model.busy then
        ( model, Cmd.none, NoOut )

    else
        case ( model.opponent, username model ) of
            ( TheBot, _ ) ->
                throw (create (sageName model) { model | menu = Nothing })

            ( AFriend, Just name ) ->
                throw (create name { model | menu = Nothing })

            -- "Guest" is what Sage was played under for want of a name,
            -- not a name anyone chose: the friend's dialog does not offer it.
            ( AFriend, Nothing ) ->
                ( { model
                    | friendAsk = True
                    , menu = Nothing
                    , error = Nothing
                    , playerName =
                        if model.playerName == "Guest" then
                            ""

                        else
                            model.playerName
                  }
                , Notebook.focus NoOp "friend-name"
                , NoOut
                )


{-| The dice leave the button and tumble for at least `tumbleMs`, however
fast the server is: the throw is the fun of the button, and a page that
jumps to the table mid-air throws it away.
-}
throw : ( Model, Cmd Msg, Out ) -> ( Model, Cmd Msg, Out )
throw ( model, cmd, out ) =
    ( { model | tumbling = True, seatWaiting = Nothing }
    , Cmd.batch [ cmd, Process.sleep tumbleMs |> Task.perform (\_ -> DiceLanded) ]
    , out
    )


tumbleMs : Float
tumbleMs =
    -- one throw of `.lh-die`'s `lh-tumble` (1.05 s, the second die 0.07 s behind)
    1150


{-| The name a game against Sage is played under: the account's, else the
one this browser last played under, else "Guest". Never "Sage", which the
room refuses beside the bot.
-}
sageName : Model -> String
sageName model =
    case username model of
        Just name ->
            name

        Nothing ->
            case cleanName model.playerName of
                Ok name ->
                    if String.toLower name == "sage" then
                        "Guest"

                    else
                        name

                Err _ ->
                    "Guest"


create : String -> Model -> ( Model, Cmd Msg, Out )
create name model =
    ( { model
        | busy = True
        , error = Nothing
        , playerName =
            if username model == Nothing then
                name

            else
                model.playerName
      }
    , Catalog.createGame model.session
        model.slug
        { format = model.format
        , name = name
        , clock =
            if model.opponent == TheBot then
                "none"

            else
                model.clock
        , opponent = opponentId model.opponent
        }
        Seated
    , NoOut
    )


submit : Model -> ( Model, Cmd Msg, Out )
submit model =
    case
        case username model of
            Just name ->
                Ok name

            Nothing ->
                cleanName model.playerName
    of
        Err message ->
            ( { model | error = Just message }, Cmd.none, NoOut )

        Ok name ->
            case ( model.step, model.gameId ) of
                ( Create, _ ) ->
                    ( { model | busy = True, error = Nothing }
                    , Catalog.createGame model.session
                        model.slug
                        { format = model.format
                        , name = name
                        , clock = model.clock
                        , opponent = opponentId model.opponent
                        }
                        Seated
                    , NoOut
                    )

                ( _, Just gameId ) ->
                    ( { model | busy = True, error = Nothing }
                    , Catalog.joinRoom model.session model.slug gameId name Seated
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )


applyRoom : Catalog.Room -> Model -> Model
applyRoom room model =
    case room.state of
        Catalog.Open ->
            { model
                | step = PlayerName
                , inviterName = room.inviterName
                , summary = room.summary
                , disconnected = room.disconnected
            }

        Catalog.Away ->
            { model | step = Reconnect, disconnected = room.disconnected }

        -- Nothing to claim: its account opens it, so the page offers the
        -- one thing that helps, signing in as that player, and sends them
        -- on to the table after.
        Catalog.Owned ->
            { model
                | step = SeatOwned
                , disconnected = []
                , signIn =
                    Just (Tuple.first (SignIn.init { next = signInNext { model | step = SeatOwned }, email = "" }))
            }

        Catalog.Full ->
            { model | step = TableFull, disconnected = [] }

        Catalog.Missing ->
            { model | step = PlayerName, disconnected = [] }

        -- Handled before it gets here (it is a redirect, not a step).
        Catalog.Seated _ ->
            model


{-| Where a sign-in started here comes back to: the table, from under a
seat that belongs to an account; home, from anywhere else on this page.
-}
signInNext : Model -> String
signInNext model =
    case ( model.step, model.gameId ) of
        ( SeatOwned, Just gameId ) ->
            Route.href (Route.play model.slug gameId)

        _ ->
            Route.href Route.library


{-| A display name: trimmed, bounded, printable. It goes into every payload,
the invite URL and the page title. The server checks it again — this is the
line under the field, not the gate.
-}
cleanName : String -> Result String String
cleanName raw =
    let
        name =
            String.trim raw
    in
    if name == "" then
        Err "Pick a display name first"

    else if String.length name > maxNameLength then
        Err ("Names are " ++ String.fromInt maxNameLength ++ " characters at most")

    else if String.any isControl name then
        Err "Invalid name"

    else
        Ok name


maxNameLength : Int
maxNameLength =
    24


{-| The Unicode "other" categories a name has no business carrying:
controls, the zero-width joiners and marks, and the direction overrides.
-}
isControl : Char -> Bool
isControl char =
    let
        code =
            Char.toCode char
    in
    code
        < 0x20
        || (code >= 0x7F && code <= 0x9F)
        || (code >= 0x200B && code <= 0x200F)
        || (code >= 0x202A && code <= 0x202E)
        || (code >= 0x2060 && code <= 0x2064)
        || code
        == 0xFEFF



-- VIEW


{-| The page when it is not the home page: an invite, and what it offers.
The home page is `home`, which `Main` draws without the paper frame.
-}
view : Model -> Html Msg
view model =
    case model.page of
        Nothing ->
            case model.loadError of
                Just message ->
                    Html.section [ class "mt-8 sm:mt-12 q-card p-5 sm:p-8", id "game-missing" ]
                        [ Notebook.eyebrow "NO SUCH GAME"
                        , Html.p [ class "text-base", style "color: var(--ink)" ] [ Html.text message ]
                        , Html.a
                            [ href (Route.href Route.library)
                            , class "inline-block font-semibold mt-3"
                            , style "color: var(--pen)"
                            ]
                            [ Html.text "Back to the library →" ]
                        ]

                Nothing ->
                    Html.text ""

        Just _ ->
            Html.div [] (formPage model)


{-| The guest's home page. A bar (the bird home; the live games, PUZZLES,
the board picker, the shell's JOIN passed in as `join`, and SIGN IN), OSKOL
over "Play backgammon.", the board playing a game by itself, and the one
sentence and one button that start a game.

Nothing on it moves when a choice changes: the sentence keeps its height
(one line wide, two on a phone, broken after the game), its menus float
over the page, and PLAY NOW keeps the width of its longer label.

-}
home : { join : Html msg, toMsg : Msg -> msg } -> Model -> List (Html msg)
home { join, toMsg } model =
    [ Html.div [ class "lh", id "landing" ]
        [ homeBar join toMsg model
        , Html.map toMsg (homeStage model)

        -- Under the bar's ☰ menu and over the page: a tap beside the menu
        -- closes it. Outside the bar, whose backdrop blur would otherwise
        -- shrink a fixed layer to the bar's own height.
        , if model.navOpen then
            Html.map toMsg (Html.div [ class "lh-nav-scrim", onClick ToggledNav, Html.Attributes.attribute "aria-hidden" "true" ] [])

          else
            Html.text ""
        ]
    , Html.map toMsg (createModal model)
    , Html.map toMsg (resumeModal model)
    , Html.map toMsg (signInModal model)
    , Html.map toMsg (friendModal model)
    ]


homeBar : Html msg -> (Msg -> msg) -> Model -> Html msg
homeBar join toMsg model =
    Html.header [ class "lh-bar" ]
        [ Html.a [ href "/", class "lh-mark", Html.Attributes.attribute "aria-label" "Oskol home" ] [ birdMark ]
        , Html.span [ class "lh-spacer" ] []
        , Html.map toMsg (liveGamesButton model)
        , Html.map toMsg
            (Html.button [ Html.Attributes.type_ "button", id "puzzles", class "lh-navlink", onClick PressedPuzzles ]
                [ Html.text "Puzzles" ]
            )
        , Html.map toMsg (Html.div [ class "lh-themes" ] [ themePicker model ])
        , join
        , Html.map toMsg (homeAccount model)
        , Html.map toMsg (navMenu model)
        ]


{-| A phone's bar is the bird, the themes (they stay: they are the fun one,
and seen they get pressed) and ☰, which only a phone shows. Everything else
the wide bar carries is in its menu -- the live games (and a dot on ☰ when
there are any), signing in or the account, Puzzles, JOIN.
-}
navMenu : Model -> Html Msg
navMenu model =
    Html.div [ class "lh-more" ]
        [ Html.button
            [ Html.Attributes.type_ "button"
            , id "nav-more"
            , class "lh-btn lh-burger"
            , Html.Attributes.attribute "aria-label" "Menu"
            , Html.Attributes.attribute "aria-haspopup" "menu"
            , Html.Attributes.attribute "aria-expanded"
                (if model.navOpen then
                    "true"

                 else
                    "false"
                )
            , onClick ToggledNav
            ]
            [ Svg.svg [ SvgAttr.viewBox "0 0 24 24", SvgAttr.width "20", SvgAttr.height "20", SvgAttr.fill "none", SvgAttr.stroke "currentColor", SvgAttr.strokeWidth "2", SvgAttr.strokeLinecap "round", Html.Attributes.attribute "aria-hidden" "true" ]
                [ Svg.path [ SvgAttr.d "M4 7h16M4 12h16M4 17h16" ] [] ]
            , if List.isEmpty model.myGames then
                Html.text ""

              else
                Html.span [ class "lh-burger-dot", Html.Attributes.attribute "aria-hidden" "true" ] []
            ]
        , if model.navOpen then
            Html.div []
                [ Html.div [ id "nav-menu", class "lh-menu lh-nav-menu", Html.Attributes.attribute "role" "menu" ]
                    ((case List.length model.myGames of
                        0 ->
                            []

                        n ->
                            [ navItem "nav-live"
                                OpenedResume
                                [ Html.span [ class "lh-nav-icon" ] [ Html.span [ class "lh-live-dot", Html.Attributes.attribute "aria-hidden" "true" ] [] ]
                                , Html.text
                                    (String.fromInt n
                                        ++ (if n == 1 then
                                                " live game"

                                            else
                                                " live games"
                                           )
                                    )
                                ]
                            , menuRule
                            ]
                     )
                        ++ [ navItem "nav-puzzles" PressedPuzzles [ navIcon "hero-puzzle-piece", Html.text "Puzzles" ]
                           , navItem "nav-join-game" PressedNavJoin [ navIcon "hero-hashtag", Html.text "Join a game" ]
                           , menuRule
                           ]
                        ++ (case model.session.user of
                                Nothing ->
                                    [ navItem "nav-signin" PressedSignInMenu [ navIcon "hero-user-circle", Html.text "Sign in" ] ]

                                Just user ->
                                    [ Html.p [ class "lh-nav-who" ] [ Identity.badge Identity.Account, Html.span [ class "truncate" ] [ Html.text (Maybe.withDefault "Your account" user.name) ] ]
                                    , navItem "nav-logout" PressedLogOut [ navIcon "hero-arrow-right-start-on-rectangle", Html.text "Log out" ]
                                    ]
                           )
                    )
                ]

          else
            Html.text ""
        ]


{-| The bird, alone: the wordmark is the page's title. -}
birdMark : Html msg
birdMark =
    Svg.svg
        [ SvgAttr.viewBox "0 0 24 24"
        , SvgAttr.width "24"
        , SvgAttr.height "24"
        , SvgAttr.fill "none"
        , SvgAttr.stroke "currentColor"
        , SvgAttr.strokeWidth "2"
        , SvgAttr.strokeLinecap "round"
        , SvgAttr.strokeLinejoin "round"
        , Html.Attributes.attribute "aria-hidden" "true"
        ]
        [ Svg.path [ SvgAttr.d "M16 7h.01" ] []
        , Svg.path [ SvgAttr.d "M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20" ] []
        , Svg.path [ SvgAttr.d "m20 7 2 .5-2 .5" ] []
        , Svg.path [ SvgAttr.d "M10 18v3" ] []
        , Svg.path [ SvgAttr.d "M14 17.75V21" ] []
        , Svg.path [ SvgAttr.d "M7 18a6 6 0 0 0 3.84-10.61" ] []
        ]


{-| "2 live games" in the bar, when there are any: the list of them. -}
liveGamesButton : Model -> Html Msg
liveGamesButton model =
    case List.length model.myGames of
        0 ->
            Html.text ""

        n ->
            let
                label =
                    String.fromInt n
                        ++ (if n == 1 then
                                " live game"

                            else
                                " live games"
                           )
            in
            -- On a phone the pill is the dot and the number: the words go
            -- where there is room for them, and stay for a screen reader.
            Html.button
                [ Html.Attributes.type_ "button"
                , id "resume-games"
                , class "lh-live"
                , Html.Attributes.attribute "aria-label" label
                , onClick OpenedResume
                ]
                [ Html.span [ class "lh-live-dot", Html.Attributes.attribute "aria-hidden" "true" ] []
                , Html.span [ class "lh-live-long" ] [ Html.text label ]
                , Html.span [ class "lh-live-short", Html.Attributes.attribute "aria-hidden" "true" ] [ Html.text (String.fromInt n) ]
                ]


{-| The bar's right end: SIGN IN for a guest; the account, with LOG OUT
behind it, for a browser signed in (it can land here at `/backgammon`).
-}
homeAccount : Model -> Html Msg
homeAccount model =
    case model.session.user of
        Nothing ->
            Html.button [ Html.Attributes.type_ "button", id "signin-button", class "lh-btn", onClick PressedSignInMenu ]
                [ Html.text "Sign in" ]

        Just user ->
            Html.div [ class "relative lh-account-wrap" ]
                [ Html.button
                    [ Html.Attributes.type_ "button"
                    , id "account-button"
                    , class "lh-btn lh-account"
                    , Html.Attributes.attribute "aria-expanded"
                        (if model.accountOpen then
                            "true"

                         else
                            "false"
                        )
                    , Html.Attributes.attribute "aria-haspopup" "menu"
                    , onClick ToggledAccount
                    ]
                    [ Identity.badge Identity.Account
                    , Html.span [ class "truncate" ] [ Html.text (Maybe.withDefault "Your account" user.name) ]
                    ]
                , if model.accountOpen then
                    Html.div [ id "account-menu", class "lh-menu lh-account-menu", Html.Attributes.attribute "role" "menu" ]
                        [ Html.button
                            [ Html.Attributes.type_ "button"
                            , id "logout"
                            , Html.Attributes.attribute "role" "menuitem"
                            , onClick PressedLogOut
                            ]
                            [ Html.text "Log out" ]
                        ]

                  else
                    Html.text ""
                ]


{-| OSKOL, the line under it, the board, and the way in. -}
homeStage : Model -> Html Msg
homeStage model =
    Html.main_ [ class "lh-stage" ]
        [ Html.div [ class "lh-head" ]
            [ Html.h1 [ class "lh-title" ] [ Html.text "OSKOL" ]
            , Html.p [ class "lh-tagline" ] [ Html.text "Play backgammon." ]
            ]
        , Html.div [ class ("lh-board " ++ Games.Backgammon.View.themeClass (homeTheme model)) ]
            [ Html.node "oskol-demo-board" [ class "lh-demo" ] [] ]
        , Html.div [ class "lh-dock" ]
            [ -- Under the open menu and over everything else: a tap beside the
              -- menu closes it. Inside the dock, so it shares the menu's layer.
              if model.menu /= Nothing then
                Html.div [ class "lh-scrim", onClick ClosedMenu, Html.Attributes.attribute "aria-hidden" "true" ] []

              else
                Html.text ""
            , sentence model
            , rollButton model
            , case ( model.error, model.friendAsk ) of
                ( Just message, False ) ->
                    Html.p [ id "form-error", class "lh-error", Html.Attributes.attribute "role" "alert" ] [ Html.text message ]

                _ ->
                    Html.text ""
            ]
        ]


{-| "Play [a single game] against [Sage] with no clock": each word in
brackets a menu. Against Sage the clock is plain words (the bot plays
without one); against a friend it is a menu too.
-}
sentence : Model -> Html Msg
sentence model =
    let
        friend =
            model.opponent == AFriend
    in
    Html.p [ id "sentence", class "lh-sentence" ]
        [ Html.text "Play "
        , pick model GameMenu "pick-game" [ Html.text (formatWords model model.format) ] (gameOptions model)
        , Html.br [ class "lh-br" ] []
        , Html.text " "
        , Html.span [ class "lh-line2" ]
            [ Html.text "against "
            , pick model
                WhoMenu
                "pick-who"
                (if friend then
                    [ friendIcon, Html.text "a friend" ]

                 else
                    [ botIcon, Html.text "Sage" ]
                )
                [ menuOptionWith "pick-who-bot" [ botIcon, Html.text "Sage, our bot" ] (not friend) (PickedOpponent TheBot)
                , menuOptionWith "pick-who-friend" [ friendIcon, Html.text "a friend" ] friend (PickedOpponent AFriend)
                ]
            , Html.text " with "
            , if friend then
                pick model ClockMenu "pick-clock" [ Html.text (clockWords model model.clock) ] (clockOptions model)

              else
                Html.span [ id "sage-clock" ] [ Html.text "no clock" ]
            ]
        ]


{-| One word of the sentence and, when it is open, its menu floating
above it.
-}
pick : Model -> PickMenu -> String -> List (Html Msg) -> List (Html Msg) -> Html Msg
pick model which pickId words options =
    let
        open =
            model.menu == Just which
    in
    Html.span [ class "lh-pick-wrap" ]
        [ Html.button
            [ Html.Attributes.type_ "button"
            , id pickId
            , class "lh-pick"
            , Html.Attributes.attribute "aria-haspopup" "listbox"
            , Html.Attributes.attribute "aria-expanded"
                (if open then
                    "true"

                 else
                    "false"
                )
            , onClick (ToggledMenu which)
            ]
            words
        , if open then
            Html.span [ class "lh-menu lh-pick-menu", id (pickId ++ "-menu"), Html.Attributes.attribute "role" "listbox" ] options

          else
            Html.text ""
        ]


{-| A menu item's icon: a Heroicon in the item's ink, in a fixed-width slot
so every label starts at the same place.
-}
navIcon : String -> Html Msg
navIcon name =
    Html.span [ class "lh-nav-icon" ] [ icon name "w-5 h-5" ]


navItem : String -> Msg -> List (Html Msg) -> Html Msg
navItem itemId msg content =
    Html.button [ Html.Attributes.type_ "button", id itemId, Html.Attributes.attribute "role" "menuitem", onClick msg ] content


{-| Who is across the table, drawn beside the name so the sentence says it
at a glance: Sage is the robot on the board's own chip (Lucide "bot"), a
friend is two people (Lucide "users").
-}
botIcon : Html msg
botIcon =
    lineIcon "lh-who-icon"
        [ Svg.path [ SvgAttr.d "M12 8V4H8" ] []
        , Svg.rect [ SvgAttr.width "16", SvgAttr.height "12", SvgAttr.x "4", SvgAttr.y "8", SvgAttr.rx "2" ] []
        , Svg.path [ SvgAttr.d "M2 14h2" ] []
        , Svg.path [ SvgAttr.d "M20 14h2" ] []
        , Svg.path [ SvgAttr.d "M15 13v2" ] []
        , Svg.path [ SvgAttr.d "M9 13v2" ] []
        ]


friendIcon : Html msg
friendIcon =
    lineIcon "lh-who-icon"
        [ Svg.path [ SvgAttr.d "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" ] []
        , Svg.circle [ SvgAttr.cx "9", SvgAttr.cy "7", SvgAttr.r "4" ] []
        , Svg.path [ SvgAttr.d "M22 21v-2a4 4 0 0 0-3-3.87" ] []
        , Svg.path [ SvgAttr.d "M16 3.13a4 4 0 0 1 0 7.75" ] []
        ]


lineIcon : String -> List (Svg.Svg msg) -> Html msg
lineIcon cls paths =
    Svg.svg
        [ SvgAttr.viewBox "0 0 24 24"
        , SvgAttr.class cls
        , SvgAttr.fill "none"
        , SvgAttr.stroke "currentColor"
        , SvgAttr.strokeWidth "2"
        , SvgAttr.strokeLinecap "round"
        , SvgAttr.strokeLinejoin "round"
        , Html.Attributes.attribute "aria-hidden" "true"
        ]
        paths


menuOption : String -> String -> Bool -> Msg -> Html Msg
menuOption optionId label selected msg =
    menuOptionWith optionId [ Html.text label ] selected msg


menuOptionWith : String -> List (Html Msg) -> Bool -> Msg -> Html Msg
menuOptionWith optionId content selected msg =
    Html.button
        [ Html.Attributes.type_ "button"
        , id optionId
        , Html.Attributes.attribute "role" "option"
        , Html.Attributes.attribute "aria-selected"
            (if selected then
                "true"

             else
                "false"
            )
        , onClick msg
        ]
        [ Html.span [ class "lh-option" ] content ]


menuRule : Html msg
menuRule =
    Html.hr [] []


{-| The game's formats as the sentence says them, single game first, the
matches between rules, then unlimited: the order the server lists them.
-}
gameOptions : Model -> List (Html Msg)
gameOptions model =
    let
        formats =
            model.page |> Maybe.map .formats |> Maybe.withDefault []

        option f =
            menuOption ("pick-game-" ++ f.id) (formatWords model f.id) (f.id == model.format) (PickedFormat f.id)

        isMatch f =
            String.startsWith "match" f.id
    in
    List.map option (List.filter (\f -> f.id == "single") formats)
        ++ [ menuRule ]
        ++ List.map option (List.filter isMatch formats)
        ++ [ menuRule ]
        ++ List.map option (List.filter (\f -> f.id /= "single" && not (isMatch f)) formats)


clockOptions : Model -> List (Html Msg)
clockOptions model =
    case model.page of
        Just page ->
            Catalog.offeredClocks page.game page.clocks
                |> List.map (\c -> menuOption ("pick-clock-" ++ c.id) (clockWords model c.id) (c.id == model.clock) (PickedClock c.id))

        Nothing ->
            []


{-| A format in the sentence's words: "a single game", "a match to 5",
"an unlimited match".
-}
formatWords : Model -> String -> String
formatWords model formatId =
    case formatId of
        "single" ->
            "a single game"

        "unlimited" ->
            "an unlimited match"

        _ ->
            model.page
                |> Maybe.andThen (\page -> List.head (List.filter (\f -> f.id == formatId) page.formats))
                |> Maybe.map (\f -> "a " ++ String.toLower f.name)
                |> Maybe.withDefault ("a " ++ String.replace "match" "match to " formatId)


{-| A clock in the sentence's words: "no clock", "a 5 min clock". -}
clockWords : Model -> String -> String
clockWords model clockId =
    if clockId == "none" then
        "no clock"

    else
        model.page
            |> Maybe.andThen (\page -> List.head (List.filter (\c -> c.id == clockId) page.clocks))
            |> Maybe.map (\c -> "a " ++ c.name ++ " clock")
            |> Maybe.withDefault "a clock"


{-| PLAY NOW, and against a friend GET A LINK: the label is stacked over a
hidden copy of the other, so the button never changes width. The dice
tumble while the game is being made.
-}
rollButton : Model -> Html Msg
rollButton model =
    let
        label =
            if model.opponent == AFriend then
                "Get a link"

            else
                "Play now"

        die n rot =
            Html.span [ class ("lh-die d" ++ String.fromInt n), style ("--rot: " ++ rot) ]
                (List.repeat 9 (Html.i [] []))
    in
    Html.button
        [ Html.Attributes.type_ "button"
        , id "roll-dice"
        , classList [ ( "lh-roll", True ), ( "is-rolling", model.busy || model.tumbling ) ]
        , Html.Attributes.attribute "aria-busy"
            (if model.busy then
                "true"

             else
                "false"
            )
        , onClick RolledDice
        ]
        [ Html.span [ class "lh-stack" ]
            [ Html.span [] [ Html.text label ]
            , Html.span [ class "lh-sizer", Html.Attributes.attribute "aria-hidden" "true" ] [ Html.text "Play now" ]
            , Html.span [ class "lh-sizer", Html.Attributes.attribute "aria-hidden" "true" ] [ Html.text "Get a link" ]
            ]
        , Html.span [ class "lh-dice", Html.Attributes.attribute "aria-hidden" "true" ] [ die 4 "-6deg", die 1 "9deg" ]
        ]


{-| GET A LINK for a guest: the name the friend will read, then the table,
where the link is.
-}
friendModal : Model -> Html Msg
friendModal model =
    if model.friendAsk then
        Html.div [ id "friend-modal", class "lh-dlg" ]
            [ Html.div [ class "lh-dlg-back", onClick ClosedFriendAsk, Html.Attributes.attribute "aria-hidden" "true" ] []
            , Html.form
                [ class "lh-dlg-card"
                , Html.Attributes.attribute "role" "dialog"
                , Html.Attributes.attribute "aria-modal" "true"
                , Html.Attributes.attribute "aria-labelledby" "friend-title"
                , onSubmit Submitted
                ]
                [ Html.button [ Html.Attributes.type_ "button", id "close-friend", class "lh-dlg-x", onClick ClosedFriendAsk, Html.Attributes.attribute "aria-label" "Close" ] [ Html.text "✕" ]
                , Html.h2 [ id "friend-title", class "lh-dlg-title" ] [ Html.text "Invite a friend" ]
                , Html.p [ class "lh-dlg-sub" ]
                    [ Html.text (capitalise (formatWords model model.format) ++ " with " ++ clockWords model model.clock ++ ". You get a link to send; the game starts when they open it.") ]
                , Html.label [ class "lh-field" ]
                    [ Html.span [] [ Html.text "Your name" ]
                    , Html.input
                        [ id "friend-name"
                        , Html.Attributes.value model.playerName
                        , Html.Attributes.placeholder "e.g. Alice"
                        , Html.Attributes.maxlength maxNameLength
                        , Html.Attributes.attribute "autocomplete" "nickname"
                        , Html.Events.onInput NameChanged
                        ]
                        []
                    ]
                , case model.error of
                    Just message ->
                        Html.p [ id "form-error", class "lh-dlg-error", Html.Attributes.attribute "role" "alert" ] [ Html.text message ]

                    Nothing ->
                        Html.text ""
                , Html.button [ Html.Attributes.type_ "submit", id "friend-go", class "lh-go", Html.Attributes.disabled model.busy ]
                    [ Html.text "Get the link" ]
                ]
            ]

    else
        Html.text ""


capitalise : String -> String
capitalise text =
    String.toUpper (String.left 1 text) ++ String.dropLeft 1 text


{-| Escape closes the list of games, as a tap beside it does; and while
it is open with a clock running in it, the seconds tick.
-}
subscriptions : Model -> Sub Msg
subscriptions model =
    if not model.resumeOpen && model.menu == Nothing && not model.friendAsk && not model.navOpen then
        Sub.none

    else
        subscriptionsWhileOpen model


subscriptionsWhileOpen : Model -> Sub Msg
subscriptionsWhileOpen model =
    Sub.batch
        [ if model.resumeOpen then
            Sub.batch
                [ onEscape ClosedResume
                , if List.any clockRunning model.myGames then
                    Time.every 1000 Tick

                  else
                    Sub.none
                ]

          else
            Sub.none
        , case ( model.menu, model.friendAsk ) of
            _ ->
                if model.navOpen then
                    onEscape ToggledNav

                else
                    Sub.none
        , case ( model.menu, model.friendAsk ) of
            ( Just _, _ ) ->
                onEscape ClosedMenu

            ( Nothing, True ) ->
                onEscape ClosedFriendAsk

            _ ->
                Sub.none
        ]


onEscape : Msg -> Sub Msg
onEscape msg =
    Browser.Events.onKeyDown
        (D.field "key" D.string
            |> D.andThen
                (\key ->
                    if key == "Escape" then
                        D.succeed msg

                    else
                        D.fail "ignored key"
                )
        )


clockRunning : MyGame -> Bool
clockRunning game =
    case game.time of
        Just time ->
            time.running /= Catalog.Nobody

        Nothing ->
            False


{-| The board the home page wears: this player's pick, or the default.
-}
homeTheme : Model -> String
homeTheme model =
    Session.pref themeKey model.session |> Maybe.withDefault Games.Backgammon.View.defaultTheme


themeKey : String
themeKey =
    "backgammon_theme"


{-| The board picker in the home board's top bar: the swatch of the board
you are looking at, and the list of all of them.
-}
themePicker : Model -> Html Msg
themePicker model =
    let
        current =
            homeTheme model
    in
    Html.div [ class "bg-themes home-themes shrink-0" ]
        [ Html.button
            [ class "flex items-center gap-2 px-1.5 py-1"
            , id "bg-theme-button"
            , Html.Attributes.attribute "aria-expanded"
                (if model.themesOpen then
                    "true"

                 else
                    "false"
                )
            , Html.Attributes.title "Themes"
            , onClick ToggledThemes
            ]
            [ Html.span [ class ("bg-theme-chip " ++ Games.Backgammon.View.themeClass current) ]
                [ Games.Backgammon.View.themeBoard ]
            , icon "hero-chevron-down" "home-palette w-3.5 h-3.5"
            ]
        , if model.themesOpen then
            Html.div [ class "bg-theme-list", id "bg-theme-list" ]
                (List.map
                    (\( key, name ) ->
                        Html.button
                            [ class
                                ("bg-theme-option"
                                    ++ (if key == current then
                                            " on"

                                        else
                                            ""
                                       )
                                )
                            , Html.Attributes.attribute "data-theme-option" key
                            , Html.Attributes.title name
                            , onClick (PickedTheme key)
                            ]
                            [ Html.span [ class ("bg-theme-chip " ++ Games.Backgammon.View.themeClass key) ]
                                [ Games.Backgammon.View.themeBoard ]
                            , Html.span [ class "bg-theme-name" ] [ Html.text name ]
                            ]
                    )
                    Games.Backgammon.View.themes
                )

          else
            Html.text ""
        ]


{-| A sign-in is open on this page: the email, the six digits, or the win
they end on. The shell asks before it swaps this page for the signed-in
home at `/`, because the win is the answer to what was just done and
CONTINUE from it is what opens that home.
-}
signingIn : Model -> Bool
signingIn model =
    model.signIn /= Nothing


{-| The home page shows the board, not the form: the backgammon page before
anything is chosen, once its data has come.
-}
isHome : Model -> Bool
isHome model =
    -- The board needs none of the page's data (only CREATE GAME's dialog
    -- does), so it draws at once rather than after a flash of the form page.
    model.step == Create && model.gameId == Nothing


{-| CREATE GAME's dialog over the board: a name, and the few choices as
dropdowns, each already on its default, so two taps and START is enough.
-}
createModal : Model -> Html Msg
createModal model =
    case ( model.started, model.page ) of
        ( True, Just page ) ->
            let
                select label selectId onPick selected options =
                    Html.label [ class "block" ]
                        [ Html.span [ class "pixel q-eyebrow text-[8px] block mb-1.5" ] [ Html.text label ]
                        , Html.select
                            [ id selectId
                            , class "q-field w-full px-3 py-2.5 text-[15px]"
                            , Html.Events.onInput onPick
                            ]
                            (List.map
                                (\( value, text ) ->
                                    Html.option
                                        [ Html.Attributes.value value, Html.Attributes.selected (value == selected) ]
                                        [ Html.text text ]
                                )
                                options
                            )
                        ]
            in
            createDialog
                [ Html.form [ onSubmit Submitted, class "space-y-4" ]
                        ((case model.error of
                            Just message ->
                                [ Html.p [ id "form-error", class "text-sm font-semibold", style "color: var(--red)" ] [ Html.text message ] ]

                            Nothing ->
                                []
                         )
                            ++ [ case username model of
                                    Just name ->
                                        playingAs "create-as" name

                                    Nothing ->
                                        Html.label [ class "block" ]
                                            [ Html.span [ class "pixel q-eyebrow text-[8px] block mb-1.5" ] [ Html.text "YOUR NAME" ]
                                            , Notebook.nameInput
                                                { id = "create-name"
                                                , placeholder = "e.g. Alice"
                                                , value = model.playerName
                                                , onInput = NameChanged
                                                }
                                            ]
                               , opponentPicker model
                               , case model.opponent of
                                    -- No clock against the bot: it spends
                                    -- whatever its engine spends, and a clock
                                    -- on one side of a table is not a thing.
                                    -- MODE takes the row rather than sitting
                                    -- in half of it with a gap beside it.
                                    TheBot ->
                                        select "MODE" "create-mode" PickedFormat model.format (List.map (\f -> ( f.id, f.name )) page.formats)

                                    AFriend ->
                                        Html.div [ class "grid grid-cols-2 gap-3" ]
                                            [ select "MODE" "create-mode" PickedFormat model.format (List.map (\f -> ( f.id, f.name )) page.formats)
                                            , select "CLOCK" "create-clock" PickedClock model.clock (Catalog.offeredClocks page.game page.clocks |> List.map (\c -> ( c.id, clockLabel c )))
                                            ]
                               , Html.p [ id "create-summary", class "q-note text-[13px] leading-snug -mt-1" ]
                                    [ Html.text (createSummary model page) ]
                               , Html.button
                                    [ Html.Attributes.type_ "submit"
                                    , id "create-game"
                                    , class "btn-arcade sky pixel w-full text-[11px] px-4 py-3.5"
                                    ]
                                    [ Html.text
                                        (case model.opponent of
                                            TheBot ->
                                                "PLAY SAGE"

                                            AFriend ->
                                                "START GAME"
                                        )
                                    ]
                               , Html.p [ class "q-note text-xs text-center" ]
                                    [ Html.text
                                        (case model.opponent of
                                            TheBot ->
                                                "Starts now. Sage takes a few seconds a move."

                                            AFriend ->
                                                "You get a link to send. The game starts when your friend opens it."
                                        )
                                    ]
                               ]
                        )
                ]

        ( True, Nothing ) ->
            -- The game's data never came: say so rather than open nothing.
            -- Pressing CREATE GAME again asks for it again.
            case model.loadError of
                Just message ->
                    createDialog
                        [ Html.p [ id "form-error", class "text-sm font-semibold", style "color: var(--red)" ]
                            [ Html.text message ]
                        ]

                Nothing ->
                    Html.text ""

        _ ->
            Html.text ""


{-| Who to play: a friend from a link, as this page has always offered, or
the bot. Two tiles rather than a third dropdown, because this is the choice
that changes what the rest of the dialog is for -- and because a player who
came here to play right now should be able to see that they can.
-}
opponentPicker : Model -> Html Msg
opponentPicker model =
    Html.div []
        [ Html.span [ class "pixel q-eyebrow text-[8px] block mb-1.5" ] [ Html.text "OPPONENT" ]
        , Html.div [ class "grid grid-cols-2 gap-3" ]
            [ opponentTile model AFriend "create-opponent-friend" "A FRIEND" "send a link"
            , opponentTile model TheBot "create-opponent-bot" "THE BOT" "Sage, 4-ply"
            ]
        ]


opponentTile : Model -> Opponent -> String -> String -> String -> Html Msg
opponentTile model which tileId label note =
    let
        chosen =
            model.opponent == which
    in
    Html.button
        [ Html.Attributes.type_ "button"
        , id tileId
        , onClick (PickedOpponent which)
        , Html.Attributes.attribute "aria-pressed"
            (if chosen then
                "true"

             else
                "false"
            )
        , classList
            [ ( "q-opt block w-full text-left px-3 py-2.5", True )
            , ( "q-opt-on", chosen )
            ]
        ]
        [ Html.span [ class "pixel text-[9px] block leading-relaxed" ] [ Html.text label ]
        , Html.span [ class "q-note block text-[12px] mt-1" ] [ Html.text note ]
        ]


{-| The id the API reads: `opponent` on POST /papi/games/:slug.
-}
opponentId : Opponent -> String
opponentId opponent =
    case opponent of
        TheBot ->
            "bot"

        AFriend ->
            "friend"


{-| CREATE GAME's frame, on the shared dialog.
-}
createDialog : List (Html Msg) -> Html Msg
createDialog content =
    dialog { id = "create-modal", closeId = "close-create", label = "Create a game", heading = "CREATE GAME", onClose = ClosedCreate } content


{-| A dialog's frame: the dimmed board behind it (a tap on it closes the
dialog), the card with its heading and close button. The layer scrolls when
the card is taller than the screen, as on a phone held sideways.
-}
dialog : { id : String, closeId : String, label : String, heading : String, onClose : Msg } -> List (Html Msg) -> Html Msg
dialog config content =
    Html.div [ id config.id, class "fixed inset-0 z-50 overflow-y-auto flex items-start justify-center px-4 pt-[10vh] sm:pt-[14vh] pb-4" ]
        [ Html.div
            [ class "fixed inset-0"
            , style "background: rgba(20, 22, 38, 0.55)"
            , onClick config.onClose
            , Html.Attributes.attribute "aria-hidden" "true"
            ]
            []
        , Html.div
            [ class "q-card sheet relative w-full max-w-sm p-5 sm:p-6"
            , Html.Attributes.attribute "role" "dialog"
            , Html.Attributes.attribute "aria-modal" "true"
            , Html.Attributes.attribute "aria-label" config.label
            ]
            (Html.div [ class "flex items-center justify-between mb-5" ]
                [ Html.h2 [ class "pixel q-eyebrow text-[9px]" ] [ Html.text config.heading ]
                , Html.button
                    [ Html.Attributes.type_ "button"
                    , id config.closeId
                    , onClick config.onClose
                    , Html.Attributes.attribute "aria-label" "Close"
                    , class "dialog-close w-8 h-8 rounded-full inline-flex items-center justify-center text-sm"
                    ]
                    [ Html.text "✕" ]
                ]
                :: content
            )
        ]



-- YOUR GAMES


{-| The sign-in the guest's bar menu opens: one line on what it is for, and
the same component every other entry uses.
-}
signInModal : Model -> Html Msg
signInModal model =
    case ( model.signInOpen, model.signIn ) of
        ( True, Just signIn ) ->
            dialog { id = "signin-modal", closeId = "close-signin", label = "Sign in", heading = "SIGN IN", onClose = ClosedSignIn }
                [ Html.p [ class "q-note text-[14px] text-center mb-4" ]
                    [ Html.text "Your games and your PR, on every device." ]
                , Html.map SignInMsg (SignIn.view signIn)
                ]

        _ ->
            Html.text ""


{-| The games this browser can pick back up, over the board: one row each,
a link to the seat. Opens on its own when the list arrives with anything
in it; a tap beside it, its ✕ or Escape closes it, and the bar's button
brings it back.
-}
resumeModal : Model -> Html Msg
resumeModal model =
    if model.resumeOpen && not (List.isEmpty model.myGames) then
        dialog { id = "resume-modal", closeId = "close-resume", label = "Your live games", heading = "LIVE GAMES", onClose = ClosedResume }
            [ Html.ul [ id "resume-list", class "space-y-2" ]
                (List.map (LiveGames.row { fetchedAt = model.fetchedAt, now = model.now } ClosedGame) model.myGames)
            , guestNote model
            ]

    else
        Html.text ""


{-| Under the list, its own panel: one line on what holds these games,
the three things an account is for, and the button. This is where someone
who has just felt the game signs up, so it has room. The button names the
games they would keep, and opens the sign-in right here (`Ui.SignIn`).
-}
guestNote : Model -> Html Msg
guestNote model =
    case ( model.session.user, model.signIn ) of
        -- Signed in: these are just their games. Nothing to say.
        ( Just _, Nothing ) ->
            Html.text ""

        -- Signing in: the flow where the button was, under the same
        -- promise; signed in this moment, the win on its own.
        ( _, Just signIn ) ->
            case signIn.state of
                SignIn.Won _ ->
                    Html.div [ id "guest-note", class "pitch mt-6 pt-5" ]
                        [ Html.map SignInMsg (SignIn.view signIn) ]

                _ ->
                    pitch model (Html.map SignInMsg (SignIn.view signIn))

        ( Nothing, Nothing ) ->
            pitch model
                (Html.button
                    [ Html.Attributes.type_ "button"
                    , id "signup-cta"
                    , class "signup w-full flex items-center justify-center gap-2 rounded-xl py-3.5 text-[15px] font-semibold"
                    , onClick OpenedSignIn
                    ]
                    [ Html.text "Sign up" ]
                )


{-| The panel under the list: one line on what holds these games, the line
that sells it, the button, and the six things an account is for.
-}
pitch : Model -> Html Msg -> Html Msg
pitch _ button =
    Html.div [ id "guest-note", class "pitch mt-6 pt-5 flex flex-col gap-4" ]
        [ Html.p [ class "q-note text-[13px] text-center" ]
            [ Html.text "You are logged in as a guest on this device." ]
        , Html.p [ class "pitch-line text-[20px] font-bold leading-tight text-center" ]
            [ Html.text "Want to get better for free?" ]
        , button
        , Html.ul [ class "flex flex-wrap justify-center gap-2" ]
            [ chip "hero-device-phone-mobile" "Every device"
            , chip "hero-magnifying-glass" "4-ply analysis"
            , chip "hero-flag" "Openings"
            , chip "hero-light-bulb" "Mistake practice"
            , chip "hero-arrow-trending-up" "PR over time"
            , chip "hero-lock-closed" "Secure account"
            ]
        ]


{-| One thing an account is for, as a chip: a Heroicon and a few words.
-}
chip : String -> String -> Html Msg
chip iconName label =
    Html.li [ class "pitch-chip inline-flex items-center gap-1.5 rounded-full pl-2.5 pr-3 py-1.5 text-[12.5px] font-semibold" ]
        [ icon iconName "w-4 h-4", Html.text label ]


{-| A Heroicon, by the class the Tailwind plugin makes for it
(`hero-<name>`). It is a mask in the current colour, so the surface decides
the ink.
-}
icon : String -> String -> Html Msg
icon name size =
    Html.span [ class (name ++ " " ++ size ++ " shrink-0"), Html.Attributes.attribute "aria-hidden" "true" ] []



{-| A clock as the dropdown lists it: its name and, when it has one, what
it means in time ("Blitz · 3 min + 2 s per move").
-}
clockLabel : ClockPreset -> String
clockLabel preset =
    if preset.id == "none" then
        preset.name

    else
        preset.name ++ " + 12 s delay"


{-| What the dropdowns add up to, in one line under them.
-}
createSummary : Model -> GamePage -> String
createSummary model page =
    case model.opponent of
        TheBot ->
            -- Against the bot the mode is the only choice left, and what the
            -- player wants to read back is who they are about to play.
            String.trim
                ((currentFormat model page
                    |> Maybe.map (\f -> f.name ++ " against Sage.")
                    |> Maybe.withDefault ""
                 )
                    ++ " No clock."
                )

        AFriend ->
            friendSummary model page


friendSummary : Model -> GamePage -> String
friendSummary model page =
    let
        mode =
            currentFormat model page
                |> Maybe.map (\f -> f.name ++ ": " ++ lowerFirst f.description ++ ".")
                |> Maybe.withDefault ""

        clock =
            Catalog.offeredClocks page.game page.clocks
                |> List.filter (\c -> c.id == model.clock)
                |> List.head
                |> Maybe.map
                    (\c ->
                        if c.id == "none" then
                            "No clock."

                        else
                            c.description ++ "."
                    )
                |> Maybe.withDefault ""
    in
    String.trim (mode ++ " " ++ clock)


lowerFirst : String -> String
lowerFirst text =
    String.toLower (String.left 1 text) ++ String.dropLeft 1 text




formPage : Model -> List (Html Msg)
formPage model =
    [ hero model
    , Html.section []
        [ Html.div [ class "q-card p-5 sm:p-7" ]
            ((case model.error of
                Just message ->
                    [ Html.p
                        [ id "form-error"
                        , class "mb-4 text-sm font-semibold px-4 py-3"
                        , style "border: 1.5px solid var(--red); color: var(--red); background: #fff3f2"
                        ]
                        [ Html.text message ]
                    ]

                Nothing ->
                    []
             )
                ++ (case model.step of
                        -- The create step is the home page (`home`).
                        Create ->
                            []

                        PlayerName ->
                            joinForm model

                        TableFull ->
                            [ tableFull (Maybe.withDefault "" model.gameId) ]

                        SeatOwned ->
                            [ seatOwned model ]

                        Reconnect ->
                            [ reconnect model ]
                   )
            )
        ]
    ]



{-| The head of the page, centred: the pixel title. Nothing else belongs
up here.
-}
hero : Model -> Html Msg
hero model =
    Html.section [ class "pt-8 sm:pt-12 pb-7 sm:pb-10 text-center", id ("game-hero-" ++ model.slug) ]
        [ Html.h1
            [ class "pixel text-lg sm:text-3xl leading-[1.7] sm:leading-[1.6]", id "game-title" ]
            [ Html.text "PLAY BACKGAMMON."
            , Html.br [] []
            , Html.span [ class "hl px-1" ] [ Html.text "WITH A FRIEND." ]
            ]
        ]



-- THE CREATE DIALOG'S PARTS


currentFormat : Model -> GamePage -> Maybe Format
currentFormat model page =
    case List.filter (\format -> format.id == model.format) page.formats of
        found :: _ ->
            Just found

        [] ->
            List.head page.formats



-- THE INVITE


joinForm : Model -> List (Html Msg)
joinForm model =
    (case model.inviterName of
        Just inviter ->
            [ Html.p [ class "q-title text-xl sm:text-2xl mb-1" ]
                [ Html.span [ class "text-opponent" ] [ Html.text inviter ]
                , Html.text " challenged you."
                ]
            ]

        Nothing ->
            []
    )
        ++ (case model.summary of
                Just summary ->
                    [ Html.p
                        [ id "setup-summary", class "q-note mb-4 text-[15px]" ]
                        [ Html.text summary ]
                    ]

                Nothing ->
                    []
           )
        ++ [ Notebook.eyebrow
                (if username model == Nothing then
                    "PLAYER 2 · YOUR NAME"

                 else
                    "PLAYER 2"
                )
           , Html.form
                [ onSubmit Submitted, class "grid gap-3 sm:grid-cols-[1fr_auto] items-center" ]
                [ case username model of
                    Just name ->
                        playingAs "join-as" name

                    Nothing ->
                        Notebook.nameInput
                            { id = "join-name"
                            , placeholder = "e.g. Bob"
                            , value = model.playerName
                            , onInput = NameChanged
                            }
                , Notebook.submitCta { id = "join-game", label = "Join game" }
                , Html.p [ class "sm:col-span-2 q-note text-sm" ]
                    [ Html.text "The game starts as soon as you join." ]
                ]
           ]


{-| Where a name field would be, for a signed-in browser: the name it will
play under, which is its account's.
-}
playingAs : String -> String -> Html Msg
playingAs elementId name =
    Html.p [ id elementId, class "text-[15px] leading-snug", style "color: var(--ink)" ]
        [ Html.span [ class "q-note" ] [ Html.text "Playing as " ]
        , Html.span [ class "font-bold" ] [ Html.text name ]
        ]


{-| Both players are at the table and neither has gone anywhere. There is
nothing to offer a third visitor: no seat, and no view of the game.
-}
tableFull : String -> Html Msg
tableFull gameId =
    Html.div [ class "space-y-3", id "table-full" ]
        [ Notebook.eyebrow "TABLE FULL"
        , Html.p [ class "text-base", style "color: var(--ink)" ]
            [ Html.text "Both players are at this table and connected. If one of them is you, open the link you were given when you sat down." ]
        , Html.a
            [ href (Route.href Route.library)
            , class "inline-block font-semibold"
            , style "color: var(--pen)"
            ]
            [ Html.text "Start your own →" ]
        , gameCode gameId
        ]


{-| The only seat free at this table belongs to an account. There is
nothing to offer: its owner opens it by signing in, and a room code never
will.
-}
seatOwned : Model -> Html Msg
seatOwned model =
    Html.div [ class "space-y-3", id "seat-owned" ]
        [ Notebook.eyebrow "SEAT TAKEN"
        , Html.p [ class "q-title text-xl sm:text-2xl", style "color: var(--ink)" ]
            [ Html.text "This seat belongs to an account." ]
        , case model.signIn of
            Just signIn ->
                Html.div [ class "space-y-4" ]
                    [ case signIn.state of
                        SignIn.Won _ ->
                            Html.text ""

                        _ ->
                            Html.p [ class "text-base", style "color: var(--ink)" ]
                                [ Html.text "Sign in as that player to play it here." ]
                    , Html.div [ class "max-w-sm" ] [ Html.map SignInMsg (SignIn.view signIn) ]
                    ]

            Nothing ->
                Html.text ""
        , Html.a
            [ href (Route.href Route.library)
            , class "inline-block font-semibold pt-1"
            , style "color: var(--pen)"
            ]
            [ Html.text "Start your own \u{2192}" ]
        , gameCode (Maybe.withDefault "" model.gameId)
        ]


{-| A seat at a full table is free because its player is away. Offer it
back: one name to confirm, or both when the table emptied out and we cannot
tell which of them this is.
-}
reconnect : Model -> Html Msg
reconnect model =
    Html.div [ class "space-y-3", id "reconnect" ]
        ([ Notebook.eyebrow
            (if List.length model.disconnected == 1 then
                "CONTINUE?"

             else
                "WHO ARE YOU?"
            )
         ]
            ++ (case model.disconnected of
                    [ seat ] ->
                        [ Html.p [ class "text-base", style "color: var(--ink)" ]
                            [ Html.text "Rejoin as "
                            , Html.span [ class "font-semibold" ] [ Html.text seat.name ]
                            , Html.text "?"
                            ]
                        ]

                    _ ->
                        []
               )
            ++ [ Html.div [ class "flex flex-wrap gap-3" ]
                    (model.disconnected
                        |> List.map
                            (\seat ->
                                Html.button
                                    [ Html.Attributes.type_ "button"
                                    , onClick (ReclaimedSeat seat.id)
                                    , id ("reclaim-" ++ seat.id)
                                    , class "q-btn yellow px-5 py-3 text-base"
                                    ]
                                    [ Html.text seat.name ]
                            )
                    )
               , gameCode (Maybe.withDefault "" model.gameId)
               ]
        )


gameCode : String -> Html msg
gameCode code =
    Html.p [ class "pixel q-eyebrow text-[9px] pt-1" ]
        [ Html.text ("GAME CODE " ++ String.toUpper code) ]
