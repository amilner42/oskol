module Page.GameLanding exposing
    ( Model
    , Msg(..)
    , Out(..)
    , cleanName
    , home
    , init
    , isHome
    , title
    , update
    , view
    )

{-| `/` (and `/:slug`) — the game's start page.

Without a room in the URL it is the home page: the board edge to edge
(`Page.HomeBoard`) with CREATE GAME, whose dialog picks a mode, its settings
and a clock, takes a name and gets a link. With `?game=` it is
the invite that link opens, and what it offers depends on the table (see
`Api.Catalog.Room`): a free seat, a seat whose player is away, or nothing at
all. With `?t=` as well it is a seat token, and the only thing to do with
one is open the seat — that lives at `/:slug/:id`, so the page hands over
immediately.

The waiting room the LiveView showed here moved to the game page: a room
with no instance yet answers the game channel with a lobby payload, so the
seat waits where it will play, on a live connection rather than a poll.

-}

import Api
import Dict
import Api.Catalog as Catalog exposing (ClockPreset, Format, GamePage, RoomSeat)
import Html exposing (Html)
import Html.Attributes exposing (class, href, id)
import Html.Events exposing (onClick, onSubmit)
import Games.Backgammon.View
import Page.HomeBoard
import Route
import Session exposing (Session)
import Ui.Notebook as Notebook exposing (style)


{-| Which of the game page's forms is showing, mirroring the LiveView's
`step` assign.
-}
type Step
    = Create
    | PlayerName
    | TableFull
    | Reconnect


type alias Model =
    { session : Session
    , slug : String
    , gameId : Maybe String
    , page : Maybe GamePage
    , loadError : Maybe String
    , step : Step
    , format : String
    , selections : List ( String, String )
    , clock : String
    , playerName : String
    , error : Maybe String
    , inviterName : Maybe String
    , summary : Maybe String
    , disconnected : List RoomSeat
    , busy : Bool
    , started : Bool -- the home page's START A GAME was pressed: show the settings
    , themesOpen : Bool -- the home board's colour list is showing
    }


type Msg
    = GotGame (Result Api.Error GamePage)
    | GotRoom (Result Api.Error Catalog.Room)
    | PickedFormat String
    | PickedSetting String String
    | PickedClock String
    | NameChanged String
    | Submitted
    | ReclaimedSeat String
    | Seated (Result Api.Error Catalog.Created)
    | Started
    | ClosedCreate
    | ToggledThemes
    | PickedTheme String
    | PrefSaved (Result Api.Error (Dict.Dict String String))
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


init : Session -> String -> Maybe String -> Maybe String -> ( Model, Cmd Msg, Out )
init session slug gameId token =
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
            , format = ""
            , selections = []
            , clock = "none"
            , playerName = Maybe.withDefault "" session.guestName
            , error = Nothing
            , inviterName = Nothing
            , summary = Nothing
            , disconnected = []
            , busy = False
            , started = False
            , themesOpen = False
            }
    in
    case ( gameId, token ) of
        -- A seat token is a credential, not a page: take it to the seat.
        ( Just id_, Just seatToken ) ->
            ( model
            , Cmd.none
            , Redirect (Route.href (Route.play slug id_ (Just seatToken)))
            )

        ( Just id_, Nothing ) ->
            ( model
            , Cmd.batch
                [ Catalog.fetchGame session slug GotGame
                , Catalog.fetchRoom session slug id_ GotRoom
                , Notebook.focus NoOp "join-name"
                ]
            , NoOut
            )

        _ ->
            ( model
            , Cmd.batch
                [ Catalog.fetchGame session slug GotGame
                , Notebook.focus NoOp "create-name"
                ]
            , NoOut
            )


title : Model -> String
title model =
    case model.page of
        Just page ->
            page.copy.title

        Nothing ->
            String.toUpper (String.left 1 model.slug) ++ String.dropLeft 1 model.slug



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
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
            ( applyRoom room model, Cmd.none, NoOut )

        GotRoom (Err _) ->
            -- A room that cannot be read is a room to join by name, exactly
            -- as a room that is not there: joining never creates one, so the
            -- attempt is what says so.
            ( { model | step = PlayerName }, Cmd.none, NoOut )

        PickedFormat formatId ->
            -- A format brings its own settings: last format's choices mean
            -- nothing here.
            ( { model | format = formatId, selections = [], error = Nothing }, Cmd.none, NoOut )

        PickedSetting settingId choiceId ->
            ( { model
                | selections =
                    ( settingId, choiceId )
                        :: List.filter (\( id_, _ ) -> id_ /= settingId) model.selections
                , error = Nothing
              }
            , Cmd.none
            , NoOut
            )

        PickedClock clockId ->
            ( { model | clock = clockId, error = Nothing }, Cmd.none, NoOut )

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

        Seated (Ok created) ->
            ( { model | busy = False }
            , Cmd.none
            , TookSeat { name = model.playerName, path = created.path }
            )

        Seated (Err err) ->
            ( { model | busy = False, error = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        NoOp ->
            ( model, Cmd.none, NoOut )


submit : Model -> ( Model, Cmd Msg, Out )
submit model =
    case cleanName model.playerName of
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
                        , selections = model.selections
                        , clock = model.clock
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

        Catalog.Full ->
            { model | step = TableFull, disconnected = [] }

        Catalog.Missing ->
            { model | step = PlayerName, disconnected = [] }


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


{-| The home page: the board with its menu (CREATE GAME, the shell's JOIN
GAME passed in as `join`, and the ones marked soon), the theme picker in its
top bar, and CREATE GAME's dialog over it when it is open.
-}
home : { join : Html msg, toMsg : Msg -> msg } -> Model -> List (Html msg)
home { join, toMsg } model =
    [ Page.HomeBoard.view
        { you = homeName model
        , actions = List.map (Html.map toMsg) (homeActions model)
        , join = join
        , soon = homeSoon
        , theme = homeTheme model
        , picker = Html.map toMsg (themePicker model)
        }
    , Html.map toMsg (createModal model)
    ]


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

        label =
            Games.Backgammon.View.themes
                |> List.filter (\( key, _ ) -> key == current)
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault "BOARD"
    in
    Html.div [ class "bg-themes home-themes shrink-0" ]
        [ Html.button
            [ class "pixel text-[8px] flex items-center gap-1.5 px-1.5 py-1"
            , id "bg-theme-button"
            , Html.Attributes.attribute "aria-expanded"
                (if model.themesOpen then
                    "true"

                 else
                    "false"
                )
            , Html.Attributes.title "Board colours"
            , onClick ToggledThemes
            ]
            [ Html.span [ class ("bg-theme-chip " ++ Games.Backgammon.View.themeClass current) ] []
            , Html.span [ class "bg-ctl-label hidden sm:inline" ] [ Html.text label ]
            ]
        , if model.themesOpen then
            Html.div [ class "bg-theme-list", id "bg-theme-list" ]
                (List.map
                    (\( key, name ) ->
                        Html.button
                            [ class
                                ("bg-theme-option pixel text-[8px]"
                                    ++ (if key == current then
                                            " on"

                                        else
                                            ""
                                       )
                                )
                            , Html.Attributes.attribute "data-theme-option" key
                            , onClick (PickedTheme key)
                            ]
                            [ Html.span [ class ("bg-theme-chip " ++ Games.Backgammon.View.themeClass key) ] []
                            , Html.span [] [ Html.text name ]
                            ]
                    )
                    Games.Backgammon.View.themes
                )

          else
            Html.text ""
        ]


{-| The home page shows the board, not the form: the backgammon page before
anything is chosen, once its data has come.
-}
isHome : Model -> Bool
isHome model =
    -- The board needs none of the page's data (only CREATE GAME's dialog
    -- does), so it draws at once rather than after a flash of the form page.
    model.step == Create && model.gameId == Nothing


homeName : Model -> String
homeName model =
    if String.isEmpty (String.trim model.playerName) then
        "YOU"

    else
        model.playerName


{-| The ways into the site, in the board's right band: creating a game
here; joining one is the shell's (the code prompt), so it is passed in.
-}
homeActions : Model -> List (Html Msg)
homeActions _ =
    [ Html.button
        [ class "btn-arcade home-create pixel text-[9px] sm:text-[11px] px-3 py-3 sm:px-5 text-center leading-relaxed"
        , id "start-game"
        , onClick Started
        ]
        [ Html.text "CREATE GAME" ]
    ]


{-| CREATE GAME's dialog over the board: a name, and the few choices as
dropdowns, each already on its default, so two taps and START is enough.
-}
createModal : Model -> Html Msg
createModal model =
    case ( model.started, model.page ) of
        ( True, Just page ) ->
            let
                format =
                    currentFormat model page

                settings =
                    format |> Maybe.map .settings |> Maybe.withDefault []

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
                            ++ [ Html.label [ class "block" ]
                                    [ Html.span [ class "pixel q-eyebrow text-[8px] block mb-1.5" ] [ Html.text "YOUR NAME" ]
                                    , Notebook.nameInput
                                        { id = "create-name"
                                        , placeholder = "e.g. Alice"
                                        , value = model.playerName
                                        , onInput = NameChanged
                                        }
                                    ]
                               , Html.div [ class "grid grid-cols-2 gap-3" ]
                                    ([ select "MODE" "create-mode" PickedFormat model.format (List.map (\f -> ( f.id, f.name )) page.formats)
                                     , select "CLOCK" "create-clock" PickedClock model.clock (Catalog.offeredClocks page.game page.clocks |> List.map (\c -> ( c.id, clockLabel c )))
                                     ]
                                        ++ List.map
                                            (\setting ->
                                                select
                                                    (if setting.id == "twist" then
                                                        "TWIST"

                                                     else
                                                        String.toUpper setting.name
                                                    )
                                                    ("create-setting-" ++ setting.id)
                                                    (PickedSetting setting.id)
                                                    (Catalog.settingChoice model.selections setting)
                                                    (List.map (\c -> ( c.id, c.name )) setting.choices)
                                            )
                                            settings
                                    )
                               , Html.p [ id "create-summary", class "q-note text-[13px] leading-snug -mt-1" ]
                                    [ Html.text (createSummary model page) ]
                               , Html.button
                                    [ Html.Attributes.type_ "submit"
                                    , id "create-game"
                                    , class "btn-arcade sky pixel w-full text-[11px] px-4 py-3.5"
                                    ]
                                    [ Html.text "START GAME" ]
                               , Html.p [ class "q-note text-xs text-center" ] [ Html.text "You get a link to send. The game starts when your friend opens it." ]
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


{-| The dialog's frame: the dimmed board behind it (a tap on it closes the
dialog), the card with its heading and close button. The layer scrolls when
the card is taller than the screen, as on a phone held sideways.
-}
createDialog : List (Html Msg) -> Html Msg
createDialog content =
    Html.div [ id "create-modal", class "fixed inset-0 z-50 overflow-y-auto flex items-start justify-center px-4 pt-[10vh] sm:pt-[14vh] pb-4" ]
        [ Html.div
            [ class "fixed inset-0"
            , style "background: rgba(20, 22, 38, 0.55)"
            , onClick ClosedCreate
            , Html.Attributes.attribute "aria-hidden" "true"
            ]
            []
        , Html.div
            [ class "q-card relative w-full max-w-sm p-5 sm:p-6"
            , Html.Attributes.attribute "role" "dialog"
            , Html.Attributes.attribute "aria-modal" "true"
            , Html.Attributes.attribute "aria-label" "Create a game"
            ]
            (Html.div [ class "flex items-center justify-between mb-4" ]
                [ Html.h2 [ class "pixel q-eyebrow text-[9px]" ] [ Html.text "CREATE GAME" ]
                , Html.button
                    [ Html.Attributes.type_ "button"
                    , id "close-create"
                    , onClick ClosedCreate
                    , Html.Attributes.attribute "aria-label" "Close"
                    , class "q-note text-base px-2 py-1"
                    ]
                    [ Html.text "✕" ]
                ]
                :: content
            )
        ]


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


{-| The ways in that are on their way.
-}
homeSoon : List (Html msg)
homeSoon =
    [ soonButton "TACTICS"
    , soonButton "ANALYSIS"
    ]


{-| A way in that is not open yet: the same button as the live ones,
dimmed, with SOON in its corner, and nothing to press.
-}
soonButton : String -> Html msg
soonButton label =
    Html.span [ class "btn-arcade plain home-soon relative pixel text-[9px] sm:text-[11px] px-3 py-3 sm:px-5 text-center leading-relaxed", Html.Attributes.attribute "aria-disabled" "true" ]
        [ Html.text label
        , Html.span [ class "home-soon-badge pixel" ] [ Html.text "SOON" ]
        ]


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
        ++ [ Notebook.eyebrow "PLAYER 2 · YOUR NAME"
           , Html.form
                [ onSubmit Submitted, class "grid gap-3 sm:grid-cols-[1fr_auto] items-center" ]
                [ Notebook.nameInput
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
