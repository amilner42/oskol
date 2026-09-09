module Page.GameLanding exposing
    ( Model
    , Msg(..)
    , Out(..)
    , cleanName
    , formatGridClass
    , init
    , title
    , update
    , view
    )

{-| `/:slug` — one game's start page.

Without a room in the URL it is the create page: the creator picks a mode,
its settings and a clock, types a name and gets a link. With `?game=` it is
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
import Api.Catalog as Catalog exposing (ClockPreset, Format, Game, GamePage, RoomSeat, Setting)
import GameArt
import Html exposing (Html)
import Html.Attributes exposing (class, href, id)
import Html.Events exposing (onClick, onSubmit)
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
    , otherGames : List Game
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
    }


type Msg
    = GotGame (Result Api.Error GamePage)
    | GotLibrary (Result Api.Error Catalog.Library)
    | GotRoom (Result Api.Error Catalog.Room)
    | PickedFormat String
    | PickedSetting String String
    | PickedClock String
    | NameChanged String
    | Submitted
    | ReclaimedSeat String
    | Seated (Result Api.Error Catalog.Created)
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


init : Session -> String -> Maybe String -> Maybe String -> ( Model, Cmd Msg, Out )
init session slug gameId token =
    let
        model =
            { session = session
            , slug = slug
            , gameId = gameId
            , page = Nothing
            , otherGames = []
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

                -- The way to the other games, at the foot of the page.
                , Catalog.fetchLibrary session GotLibrary
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

        GotLibrary result ->
            ( { model
                | otherGames =
                    result |> Result.map .games |> Result.withDefault model.otherGames
              }
            , Cmd.none
            , NoOut
            )

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


view : Model -> Html Msg
view model =
    case model.page of
        Nothing ->
            case model.loadError of
                Just message ->
                    Html.section [ class "mt-8 sm:mt-12 pix p-4 sm:p-8", id "game-missing" ]
                        [ Html.p [ class "pixel text-[10px] mb-3", style "color: var(--red)" ]
                            [ Html.text "NO SUCH GAME" ]
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

        Just page ->
            Html.div [] (gamePage model page)


gamePage : Model -> GamePage -> List (Html Msg)
gamePage model page =
    [ Html.section
        [ class "cabinet pix mt-3 sm:mt-6"
        , style ("--accent: " ++ GameArt.accent model.slug ++ "; transform: none;")
        , id ("game-hero-" ++ model.slug)
        ]
        [ Html.div
            [ class "marquee pixel text-xs sm:text-base px-4 sm:px-5 py-3 uppercase", id "game-title" ]
            [ Html.text page.game.name ]
        , Html.div [ class "flex items-center gap-3 sm:gap-6 px-4 sm:px-6 py-3.5 sm:py-5" ]
            -- Still here: this page's job is the form below it, not a loop
            -- to watch.
            [ GameArt.art { slug = model.slug, class = "h-14 sm:h-24 shrink-0", animate = False }
            , Html.div [ class "min-w-0" ]
                [ Html.h1
                    [ class "text-lg sm:text-2xl font-black leading-snug", style "color: var(--ink)" ]
                    [ Html.text page.copy.title ]
                , Html.p
                    [ class "mt-1.5 text-sm sm:text-base leading-relaxed", style "color: var(--pencil)" ]
                    [ Html.text page.copy.intro ]
                ]
            ]
        ]
    , Html.section [ class "mt-4 sm:mt-6" ]
        [ Html.div [ class "pix p-4 sm:p-8" ]
            ((case model.error of
                Just message ->
                    [ Html.p
                        [ id "form-error"
                        , class "mb-4 text-sm font-semibold px-4 py-3"
                        , style "border: 2px solid var(--red); color: var(--red); background: #fff3f2"
                        ]
                        [ Html.text message ]
                    ]

                Nothing ->
                    []
             )
                ++ (case model.step of
                        Create ->
                            [ createForm model page ]

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
        ++ (if model.step == Create then
                about model page

            else
                []
           )



-- THE CREATE FORM


createForm : Model -> GamePage -> Html Msg
createForm model page =
    let
        format =
            currentFormat model page

        settings =
            format |> Maybe.map .settings |> Maybe.withDefault []

        twist =
            settings |> List.filter (\setting -> setting.id == "twist") |> List.head

        rest =
            settings |> List.filter (\setting -> setting.id /= "twist")
    in
    Html.form [ onSubmit Submitted, class "space-y-4 sm:space-y-6" ]
        ([ Html.div []
            [ heading "color: var(--pen)" "YOUR NAME"
            , Notebook.nameInput
                { id = "create-name"
                , placeholder = "e.g. Alice"
                , value = model.playerName
                , onInput = NameChanged
                }
            ]
         , Html.div []
            [ heading "color: var(--ink)" "MODE"
            , Html.div
                [ class ("grid gap-2 sm:gap-3 " ++ formatGridClass (List.length page.formats)) ]
                (List.map (formatTile model.format) page.formats)
            ]
         ]
            -- A setting called "twist" gets its own heading; the rest follow.
            ++ (case twist of
                    Just setting ->
                        [ Html.div [ id "twist" ]
                            [ heading "color: var(--ink)" "TWIST"
                            , chipRow (List.map (choiceChip model.selections setting) setting.choices)
                            ]
                        ]

                    Nothing ->
                        []
               )
            ++ List.map
                (\setting ->
                    Html.div [ id ("setting-" ++ setting.id) ]
                        [ heading "color: var(--ink)" (String.toUpper setting.name)
                        , chipRow (List.map (choiceChip model.selections setting) setting.choices)
                        ]
                )
                rest
            ++ [ Html.div []
                    [ heading "color: var(--ink)" "CLOCK"
                    , Html.div [ class "flex flex-wrap gap-2", id "clock-picker" ]
                        (Catalog.offeredClocks page.game page.clocks
                            |> List.map (clockChip model.clock)
                        )
                    ]
               , Html.div [ class "text-center space-y-2 pt-0.5" ]
                    [ Notebook.submitCta { id = "create-game", color = "green", label = "START ▶" }
                    , Html.p [ class "text-sm", style "color: var(--pencil)" ]
                        [ Html.text "You get a link to send. The game starts when your friend opens it." ]
                    ]
               ]
        )


currentFormat : Model -> GamePage -> Maybe Format
currentFormat model page =
    case List.filter (\format -> format.id == model.format) page.formats of
        found :: _ ->
            Just found

        [] ->
            List.head page.formats


heading : String -> String -> Html msg
heading colour text =
    Html.h3 [ class "pixel text-[10px] mb-2", style colour ] [ Html.text text ]


chipRow : List (Html msg) -> Html msg
chipRow =
    Html.div [ class "flex flex-wrap gap-2" ]


formatTile : String -> Format -> Html Msg
formatTile selected format =
    Html.button
        [ Html.Attributes.type_ "button"
        , onClick (PickedFormat format.id)
        , id ("format-" ++ format.id)
        , class (tileClass "tile text-left px-3 sm:px-4 py-3" (selected == format.id))
        ]
        [ Html.div [ class "font-bold leading-snug", style "color: var(--ink)" ]
            [ Html.text format.name ]
        , Html.div
            [ class "text-[11px] sm:text-xs mt-0.5 leading-tight", style "color: var(--pencil)" ]
            [ Html.text format.description ]
        ]


choiceChip : List ( String, String ) -> Setting -> Catalog.Choice -> Html Msg
choiceChip selections setting choice =
    Html.button
        [ Html.Attributes.type_ "button"
        , onClick (PickedSetting setting.id choice.id)
        , id ("choice-" ++ setting.id ++ "-" ++ choice.id)
        , class
            (tileClass "tile px-3.5 py-2.5 text-sm font-semibold"
                (Catalog.settingChoice selections setting == choice.id)
            )
        , style "color: var(--ink)"
        ]
        [ Html.text choice.name ]


clockChip : String -> ClockPreset -> Html Msg
clockChip selected preset =
    Html.button
        [ Html.Attributes.type_ "button"
        , onClick (PickedClock preset.id)
        , id ("clock-" ++ preset.id)
        , Html.Attributes.title preset.description
        , class (tileClass "tile px-3.5 py-2.5 text-sm font-semibold" (selected == preset.id))
        , style "color: var(--ink)"
        ]
        [ Html.text preset.name ]


tileClass : String -> Bool -> String
tileClass base selected =
    if selected then
        base ++ " tile-mine"

    else
        base


{-| Static class names so Tailwind can find them.
-}
formatGridClass : Int -> String
formatGridClass count =
    case count of
        1 ->
            "grid-cols-1"

        2 ->
            "grid-cols-2"

        3 ->
            "grid-cols-1 sm:grid-cols-3"

        4 ->
            "grid-cols-2 sm:grid-cols-4"

        _ ->
            "grid-cols-2 sm:grid-cols-3"



-- THE INVITE


joinForm : Model -> List (Html Msg)
joinForm model =
    (case model.inviterName of
        Just inviter ->
            [ Html.p [ class "mb-1 text-lg" ]
                [ Html.span [ class "text-opponent font-bold" ] [ Html.text inviter ]
                , Html.text " challenged you."
                ]
            ]

        Nothing ->
            []
    )
        ++ (case model.summary of
                Just summary ->
                    [ Html.p
                        [ id "setup-summary"
                        , class "mb-3 text-sm font-semibold"
                        , style "color: var(--ink)"
                        ]
                        [ Html.text summary ]
                    ]

                Nothing ->
                    []
           )
        ++ [ Html.p [ class "pixel text-[10px] mb-3", style "color: var(--red)" ]
                [ Html.text "PLAYER 2 · ENTER YOUR NAME" ]
           , Html.form
                [ onSubmit Submitted, class "grid gap-3 sm:grid-cols-[1fr_auto] items-center" ]
                [ Notebook.nameInput
                    { id = "join-name"
                    , placeholder = "e.g. Bob"
                    , value = model.playerName
                    , onInput = NameChanged
                    }
                , Notebook.submitCta { id = "join-game", color = "red", label = "JOIN GAME" }
                , Html.p [ class "sm:col-span-2 text-sm", style "color: var(--pencil)" ]
                    [ Html.text "The game starts as soon as you join." ]
                ]
           ]


{-| Both players are at the table and neither has gone anywhere. There is
nothing to offer a third visitor: no seat, and no view of the game.
-}
tableFull : String -> Html Msg
tableFull gameId =
    Html.div [ class "space-y-4", id "table-full" ]
        [ Html.p [ class "pixel text-[10px]", style "color: var(--red)" ] [ Html.text "TABLE FULL" ]
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
    Html.div [ class "space-y-4", id "reconnect" ]
        ([ Html.p [ class "pixel text-[10px]", style "color: var(--pen)" ]
            [ Html.text
                (if List.length model.disconnected == 1 then
                    "CONTINUE?"

                 else
                    "WHO ARE YOU?"
                )
            ]
         ]
            ++ (case model.disconnected of
                    [ seat ] ->
                        [ Html.p [ class "text-base", style "color: var(--ink)" ]
                            [ Html.text "Rejoin as "
                            , Html.span [ class "font-bold" ] [ Html.text seat.name ]
                            , Html.text "?"
                            ]
                        ]

                    _ ->
                        []
               )
            ++ [ Html.div [ class "grid gap-3 sm:grid-cols-2" ]
                    (model.disconnected
                        |> List.map
                            (\seat ->
                                Html.button
                                    [ Html.Attributes.type_ "button"
                                    , onClick (ReclaimedSeat seat.id)
                                    , id ("reclaim-" ++ seat.id)
                                    , class "btn-arcade yellow pixel text-[10px] px-4 py-3"
                                    ]
                                    [ Html.text seat.name ]
                            )
                    )
               , gameCode (Maybe.withDefault "" model.gameId)
               ]
        )


gameCode : String -> Html msg
gameCode code =
    Html.p [ class "pixel text-[9px]", style "color: var(--pencil)" ]
        [ Html.text ("GAME CODE " ++ String.toUpper code) ]



-- THE PART THAT IS FOR READING


{-| How it works, the rules in brief, the modes and clocks on offer, a few
questions, and the way to the other games.
-}
about : Model -> GamePage -> List (Html Msg)
about model page =
    [ Html.section [ class "mt-8 sm:mt-12 pix p-4 sm:p-8", id "rules" ]
        [ aboutHeading "text-[10px] sm:text-xs mb-3 sm:mb-4"
            (String.toUpper page.game.name ++ " IN BRIEF")
        , Html.div
            [ class "space-y-3 text-sm sm:text-base leading-relaxed", style "color: var(--ink)" ]
            (List.map (\paragraph -> Html.p [] [ Html.text paragraph ]) page.copy.rules)
        ]
    , Html.section [ class "mt-5 sm:mt-8 grid gap-4 sm:grid-cols-2", id "modes" ]
        [ Html.div [ class "pix-sm p-4 sm:p-5" ]
            [ aboutHeading "text-[10px] mb-3" "MODES"
            , Html.ul [ class "space-y-2 text-sm sm:text-base" ]
                (page.formats |> List.map (\f -> nameAndNote f.name f.description))
            ]
        , Html.div [ class "pix-sm p-4 sm:p-5" ]
            [ aboutHeading "text-[10px] mb-3" "CLOCKS"
            , Html.ul [ class "space-y-2 text-sm sm:text-base" ]
                (Catalog.clocksInGameOrder page.game page.clocks
                    |> List.map (\preset -> nameAndNote preset.name preset.description)
                )
            ]
        ]
    ]
        ++ (if List.isEmpty page.copy.faq then
                []

            else
                [ Html.section [ class "mt-5 sm:mt-8 pix p-4 sm:p-8", id "faq" ]
                    [ aboutHeading "text-[10px] sm:text-xs mb-3 sm:mb-4" "QUESTIONS"
                    , Html.dl [ class "space-y-4 text-sm sm:text-base" ]
                        (page.copy.faq
                            |> List.map
                                (\( question, answer ) ->
                                    Html.div []
                                        [ Html.dt [ class "font-bold", style "color: var(--ink)" ]
                                            [ Html.text question ]
                                        , Html.dd
                                            [ class "mt-1 leading-relaxed"
                                            , style "color: var(--pencil)"
                                            ]
                                            [ Html.text answer ]
                                        ]
                                )
                        )
                    ]
                ]
           )
        ++ (case List.filter (\game -> game.slug /= model.slug) model.otherGames of
                [] ->
                    []

                others ->
                    [ Html.section [ class "mt-8 sm:mt-10 text-center", id "other-games" ]
                        [ Html.div [ class "flex flex-wrap justify-center gap-3" ]
                            (others
                                |> List.map
                                    (\game ->
                                        Html.a
                                            [ href (Route.href (Route.gameLanding game.slug))
                                            , class "pix-flat px-4 py-3 font-bold hover:bg-[color:var(--highlighter)]"
                                            , style "color: var(--ink)"
                                            ]
                                            [ Html.text ("Play " ++ game.name ++ " →") ]
                                    )
                            )
                        ]
                    ]
           )


aboutHeading : String -> String -> Html msg
aboutHeading size text =
    Html.h2 [ class ("pixel " ++ size ++ " leading-loose"), style "color: var(--ink)" ]
        [ Html.text text ]


nameAndNote : String -> String -> Html msg
nameAndNote name note =
    Html.li []
        [ Html.span [ class "font-bold", style "color: var(--ink)" ] [ Html.text name ]
        , Html.text " "
        , Html.span [ class "text-sm", style "color: var(--pencil)" ]
            [ Html.text ("· " ++ note) ]
        ]
