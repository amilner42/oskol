port module Page.Play exposing
    ( ConnectionStatus(..)
    , Model
    , Msg(..)
    , Out(..)
    , applyPayload
    , framed
    , init
    , storePref
    , subscriptions
    , title
    , update
    , view
    )

{-| `/:slug/:id` — the one client for every game. It decodes the gamekit
protocol, keeps the latest payload, and hands the scene to the game's
view (backgammon is the one game there is).

This is the SPA's third page, and it was the whole app before it: the game
experience below `view` is unchanged, and so is the channel wiring. What
changed is the way in. The page used to be handed its game by data
attributes on a server-rendered div; now it takes the game id and the seat
token from the route and asks JavaScript to open the channel
(`joinGameChannel`), which is the one thing Elm cannot do itself.

A room whose game has not started yet answers with a lobby payload rather
than a scene, and that is the waiting room: the seat waits where it will
play. It carries the invite link, the game code and the two names, exactly
as the LiveView's lobby did.

-}

import Api
import Api.Catalog as Catalog
import Browser.Dom
import Dict exposing (Dict)
import Games.Backgammon.View as Backgammon
import Html exposing (Html)
import Html.Attributes exposing (attribute, class, id)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Process
import Protocol exposing (GamePayload, ServerMessage(..))
import Route
import Session exposing (Session)
import Task
import Time
import Ui.Notebook as Notebook
import Url exposing (percentEncode)
import View.Clock



-- PORTS


port sendToChannel : E.Value -> Cmd msg


port receiveFromChannel : (E.Value -> msg) -> Sub msg


{-| Open (or re-open) the game channel for a room. JavaScript owns the
socket; every message either way still goes through the two ports above.
-}
port joinGameChannel : { gameId : String, seatToken : Maybe String } -> Cmd msg


{-| Hand an invite link to the platform: the native sheet on a phone, the
clipboard everywhere else. The result comes back on `shareResult`.
-}
port shareInvite : String -> Cmd msg


port shareResult : (String -> msg) -> Sub msg


{-| Keep a display preference in this browser's own storage, so the board is
already the right colour on the next first paint -- before (and without)
the round trip to `/papi/me/prefs`, and for a visitor whose guest cookie is
gone. The server's copy is still the one that follows a guest between
browsers.
-}
port storePref : { key : String, value : String } -> Cmd msg



-- MODEL


type ConnectionStatus
    = Disconnected
    | Connecting
    | Connected


{-| The preference key the backgammon board's colours are kept under; the
server keeps the same string (`oskol/guests/prefs.gleam`).
-}
backgammonThemeKey : String
backgammonThemeKey =
    "backgammon_theme"


type alias Model =
    { origin : String -- scheme, host and port of this page, for the invite link
    , gameId : String
    , gameSlug : String
    , playerId : Maybe String
    , seatToken : Maybe String -- this seat's credential, carried into a rematch
    , payload : Maybe GamePayload -- latest protocol payload from the server
    , lobby : Maybe Protocol.Lobby -- the room before it has a game in it
    , legal : List Protocol.Schema -- legal action schemas for this player
    , backgammon : Backgammon.Model
    , clockReceivedAt : Int -- client time (ms) when the latest clock snapshot arrived
    , nowMs : Int -- client time (ms), refreshed while a clock runs
    , connectionStatus : ConnectionStatus
    , shareLabel : Maybe String
    , error : Maybe String
    , session : Session -- the CSRF token /papi writes carry
    , prefs : Dict String String -- this viewer's display preferences (a board's colours)
    , picked : List String -- preference keys this viewer set here, which no answer may undo
    }


init :
    Session
    ->
        { origin : String
        , slug : String
        , gameId : String
        , seatToken : Maybe String
        }
    -> ( Model, Cmd Msg )
init session config =
    ( { origin = config.origin
      , gameId = config.gameId
      , gameSlug = config.slug
      , playerId = Nothing
      , seatToken = config.seatToken
      , payload = Nothing
      , lobby = Nothing
      , legal = []
      , backgammon = Backgammon.init
      , clockReceivedAt = 0
      , nowMs = 0
      , connectionStatus = Connecting
      , shareLabel = Nothing
      , error = Nothing
      , session = session
      , prefs = session.prefs
      , picked = []
      }
    , Cmd.batch
        -- One tick late, deliberately: a port message sent while the program
        -- is still being initialised has nobody subscribed to it yet.
        [ Task.perform (\_ -> ChannelRequested) (Process.sleep 0)

        -- What this guest picked on any of their browsers. The flags
        -- already carried what this one stored locally, so the board is
        -- painted before this answers; this is what follows them about.
        , Catalog.fetchPrefs session GotPrefs
        ]
    )


{-| The tab's title: the game, and once it is on, who you are playing
("Mikey · Backgammon"), so a row of tabs reads as a row of opponents. A
spectator's tab names both players.
-}
title : Model -> String
title model =
    let
        game =
            String.toUpper (String.left 1 model.gameSlug) ++ String.dropLeft 1 model.gameSlug
    in
    case model.payload of
        Just payload ->
            case List.filter (\p -> p.id /= payload.playerId) payload.players |> List.map .name of
                [] ->
                    game

                others ->
                    if List.any (\p -> p.id == payload.playerId) payload.players then
                        String.join " vs " others ++ " · " ++ game

                    else
                        String.join " vs " (List.map .name payload.players) ++ " · " ++ game

        Nothing ->
            game


{-| True while this page is the lobby (or on its way to it): those states
belong inside the site's chrome, the table does not.
-}
framed : Model -> Bool
framed model =
    model.payload == Nothing



-- UPDATE


type Msg
    = ChannelRequested
    | ServerMessageReceived ServerMessage
    | BackgammonMsg Backgammon.Msg
    | ClockSynced Time.Posix
    | ClockTick Time.Posix
    | RematchGameReady String
    | ChannelError String
    | ConnectionStatusChanged ConnectionStatus
    | RequestRematch
    | ShareInvite
    | ShareReported String
    | ShareLabelCleared
    | GotPrefs (Result Api.Error (Dict String String))
    | PrefSaved (Result Api.Error (Dict String String))
    | NoOp


{-| Where this page wants to go next. Routing belongs to the shell, so the
page names the URL and `Main` pushes it — which also keeps the page a plain
value the test suite can drive without a `Browser.Navigation.Key`.
-}
type Out
    = NoOut
    | Navigate String
      -- A display preference this viewer just picked: the shell keeps it
      -- for the rest of the visit, so leaving the table and coming back
      -- does not undo it.
    | Remember String String


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        ChannelRequested ->
            stay model (joinGameChannel { gameId = model.gameId, seatToken = model.seatToken })

        ServerMessageReceived message ->
            case message of
                GameMessage payload ->
                    applyPayload payload model

                LobbyMessage lobby ->
                    stay
                        { model
                            | connectionStatus = Connected
                            , lobby = Just lobby
                            , playerId = lobby.playerId
                            , error = Nothing
                        }
                        Cmd.none

                ErrorMessage err ->
                    update (ChannelError err) model

                RematchReadyMessage rematchGameId ->
                    update (RematchGameReady rematchGameId) model

                StatusMessage status ->
                    update (ConnectionStatusChanged (connectionStatusFromString status)) model

        BackgammonMsg bgMsg ->
            let
                ( bg, out ) =
                    Backgammon.update bgMsg model.backgammon

                updated =
                    { model | backgammon = bg, error = Nothing }
            in
            case out of
                Backgammon.NoOut ->
                    stay updated Cmd.none

                Backgammon.Send value ->
                    stay updated (sendToChannel value)

                Backgammon.SendMany values ->
                    -- One port message, not a batch: the moves of one
                    -- checker have to reach the room in order, and Cmd.batch
                    -- promises no order.
                    stay updated (sendToChannel (E.object [ ( "type", E.string "actions" ), ( "actions", E.list identity values ) ]))

                Backgammon.WantRematch ->
                    update RequestRematch updated

                Backgammon.NeedZones targets ->
                    stay updated (measureDropZones targets)

                Backgammon.WantRecord ->
                    -- The earlier games' turns are not in every update: the
                    -- room serves them to a seat that asks, on its token.
                    case model.seatToken of
                        Just token ->
                            stay updated
                                (Api.get model.session
                                    (recordUrl model token)
                                    (D.field "record" D.value)
                                    (Result.mapError (always ()) >> Backgammon.GotRecord >> BackgammonMsg)
                                )

                        Nothing ->
                            -- a spectator is never offered a game to open;
                            -- should one ask anyway, it is a failed fetch
                            update (BackgammonMsg (Backgammon.GotRecord (Err ()))) updated

                Backgammon.ChoseTheme name ->
                    -- Three places keep it: the page (instantly), this
                    -- browser (so the next first paint is right) and the
                    -- guest's row (so their other browsers follow).
                    ( { updated
                        | prefs = Dict.insert backgammonThemeKey name updated.prefs
                        , picked = backgammonThemeKey :: updated.picked
                      }
                    , Cmd.batch
                        [ storePref { key = backgammonThemeKey, value = name }
                        , Catalog.savePref model.session backgammonThemeKey name PrefSaved
                        ]
                    , Remember backgammonThemeKey name
                    )

        ClockSynced posix ->
            stay
                { model
                    | clockReceivedAt = Time.posixToMillis posix
                    , nowMs = Time.posixToMillis posix
                }
                Cmd.none

        ClockTick posix ->
            stay { model | nowMs = Time.posixToMillis posix } Cmd.none

        RematchGameReady rematchGameId ->
            ( model, Cmd.none, Navigate (rematchUrl model rematchGameId) )

        ChannelError err ->
            stay { model | error = Just err } Cmd.none

        ConnectionStatusChanged status ->
            stay { model | connectionStatus = status } Cmd.none

        RequestRematch ->
            stay model (sendToChannel Protocol.encodeRematch)

        ShareInvite ->
            stay model (shareInvite (inviteUrl model))

        ShareReported result ->
            case result of
                "shared" ->
                    stay model Cmd.none

                "copied" ->
                    stay { model | shareLabel = Just "Copied!" } clearShareLabel

                _ ->
                    stay { model | shareLabel = Just "Copy failed" } clearShareLabel

        ShareLabelCleared ->
            stay { model | shareLabel = Nothing } Cmd.none

        GotPrefs (Ok prefs) ->
            keep (absorb prefs model) model

        GotPrefs (Err _) ->
            -- A preference is a nicety: a board that stays the colour this
            -- browser last stored is a perfectly good outcome.
            stay model Cmd.none

        PrefSaved (Ok prefs) ->
            keep (absorb prefs model) model

        PrefSaved (Err _) ->
            stay model Cmd.none

        NoOp ->
            stay model Cmd.none


stay : Model -> Cmd Msg -> ( Model, Cmd Msg, Out )
stay model cmd =
    ( model, cmd, NoOut )


clearShareLabel : Cmd Msg
clearShareLabel =
    Process.sleep 1500 |> Task.perform (\_ -> ShareLabelCleared)


{-| Absorb a server payload: remember it and the legal actions, resync the
clock to client time, and let backgammon roll for the viewer when there is
no doubling decision to make (`Backgammon.autoRoll`; fires at most once
per arriving state, so nothing here can loop).
-}
applyPayload : GamePayload -> Model -> ( Model, Cmd Msg, Out )
applyPayload payload model =
    let
        ( backgammon, rollCmd ) =
            if model.gameSlug == "backgammon" then
                -- Note the dice that just landed (they animate from the
                -- event, not from a diff), then roll if there is nothing
                -- to decide.
                model.backgammon
                    |> Backgammon.noteEvents payload.update.events
                    |> Backgammon.autoRoll payload.update.legal
                    |> Tuple.mapSecond (Maybe.map sendToChannel >> Maybe.withDefault Cmd.none)

            else
                ( model.backgammon, Cmd.none )

        updated =
            { model
                | payload = Just payload
                , playerId = Just payload.playerId
                , legal = payload.update.legal
                , backgammon = backgammon
                , connectionStatus = Connected
                , lobby = Nothing
            }

        -- A rematch accepted while this client was away arrives in the
        -- payload rather than as a rematch_ready push: follow it.
        follow =
            case payload.rematchGameId of
                Just rematchGameId ->
                    if List.member payload.playerId payload.rematchReady && (model.payload |> Maybe.andThen .rematchGameId) /= Just rematchGameId then
                        Navigate (rematchUrl updated rematchGameId)

                    else
                        NoOut

                Nothing ->
                    NoOut
    in
    ( updated
    , Cmd.batch [ Task.perform ClockSynced Time.now, rollCmd ]
    , follow
    )


{-| Measure the drop zones for a backgammon drag: the client rects of the
origin's legal destinations, by the DOM ids the board view puts on them.
Coordinates are viewport-relative (`getElement` reports page coordinates,
so the scroll offset is subtracted); a target the DOM does not have right
now is simply skipped.
-}
measureDropZones : List String -> Cmd Msg
measureDropZones targets =
    targets
        |> List.map
            (\loc ->
                Browser.Dom.getElement (Backgammon.dropZoneId loc)
                    |> Task.map
                        (\found ->
                            Just
                                { loc = loc
                                , left = found.element.x - found.viewport.x
                                , top = found.element.y - found.viewport.y
                                , width = found.element.width
                                , height = found.element.height
                                }
                        )
                    |> Task.onError (\_ -> Task.succeed Nothing)
            )
        |> Task.sequence
        |> Task.perform (List.filterMap identity >> Backgammon.GotDropZones >> BackgammonMsg)


{-| Seated players whose connection is currently down.
-}
awayIds : GamePayload -> List String
awayIds payload =
    payload.players |> List.filter (\p -> not p.connected) |> List.map .id


connectionStatusFromString : String -> ConnectionStatus
connectionStatusFromString status =
    case status of
        "connected" ->
            Connected

        "connecting" ->
            Connecting

        _ ->
            Disconnected


{-| Where this room's whole record is read, on this seat's token.
-}
recordUrl : Model -> String -> String
recordUrl model token =
    "/papi/games/" ++ model.gameSlug ++ "/rooms/" ++ model.gameId ++ "/record?t=" ++ percentEncode token


{-| A rematch is the same players in the same seats, so the seat token
carries over unchanged: it is the only thing the new room needs.
-}
rematchUrl : Model -> String -> String
rematchUrl model rematchGameId =
    "/"
        ++ model.gameSlug
        ++ "/"
        ++ rematchGameId
        ++ (case model.seatToken of
                Just token ->
                    "?t=" ++ percentEncode token

                Nothing ->
                    ""
           )


{-| The plain invite link for this room: no token, nothing identifying. What
it offers is the room's decision, not the link's.
-}
inviteUrl : Model -> String
inviteUrl model =
    model.origin ++ Route.href (Route.invite model.gameSlug model.gameId)


nameOf : Model -> String -> String
nameOf model playerId =
    model.payload
        |> Maybe.andThen (\p -> Protocol.findPlayer playerId p.update.scene)
        |> Maybe.map .name
        |> Maybe.withDefault playerId


clockRunning : Model -> Bool
clockRunning model =
    case model.payload of
        Just payload ->
            payload.update.clock.enabled && List.any .running payload.update.clock.players

        Nothing ->
            False


finishedWinners : GamePayload -> Maybe (List String)
finishedWinners payload =
    case payload.update.outcome of
        Protocol.Ongoing ->
            Nothing

        Protocol.Finished winners ->
            Just winners


{-| Absorbing the server's answer also writes it to this browser, or the
two would disagree for good: a board picked on another browser would arrive
a round trip late on every single load here, painting the old one first.
-}
keep : Model -> Model -> ( Model, Cmd Msg, Out )
keep updated before =
    updated.prefs
        |> Dict.toList
        |> List.filter (\( key, value ) -> Dict.get key before.prefs /= Just value)
        |> List.map (\( key, value ) -> storePref { key = key, value = value })
        |> Cmd.batch
        |> stay updated


{-| What the server says this guest keeps, over what this browser had:
the row is the copy that follows them between browsers, so it wins where
this page has not been touched. It never wins over a pick made here: an
answer to a request that left before the tap must not drag the board back
to the board that was.
-}
absorb : Dict String String -> Model -> Model
absorb prefs model =
    { model
        | prefs =
            Dict.union
                (Dict.filter (\key _ -> not (List.member key model.picked)) prefs)
                model.prefs
    }


{-| The board this viewer looks at: what they picked, or the default.
-}
theme : Model -> String
theme model =
    Dict.get backgammonThemeKey model.prefs
        |> Maybe.withDefault Backgammon.defaultTheme


-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveFromChannel handleChannelMessage
        , shareResult ShareReported
        , if clockRunning model then
            Time.every 200 ClockTick

          else
            Sub.none
        ]


handleChannelMessage : E.Value -> Msg
handleChannelMessage value =
    case D.decodeValue Protocol.serverMessageDecoder value of
        Ok message ->
            ServerMessageReceived message

        Err err ->
            ChannelError (D.errorToString err)



-- VIEW


view : Model -> Html Msg
view model =
    case model.payload of
        Nothing ->
            Html.section [ class "mt-4 sm:mt-6" ]
                [ Html.div [ class "pix p-4 sm:p-8" ]
                    [ case ( model.error, model.lobby ) of
                        ( Just err, _ ) ->
                            gameGone model err

                        ( Nothing, Just lobby ) ->
                            waiting model lobby

                        ( Nothing, Nothing ) ->
                            Html.p [ class "pixel text-xs text-center" ]
                                [ Html.text
                                    (case model.connectionStatus of
                                        Disconnected ->
                                            "DISCONNECTED"

                                        _ ->
                                            "CONNECTING..."
                                    )
                                ]
                    ]
                ]

        Just payload ->
            let
                finished =
                    finishedWinners payload

                game =
                    case model.gameSlug of
                        "backgammon" ->
                            Html.map BackgammonMsg
                                (Backgammon.view
                                    { playerId = payload.playerId
                                    , scene = payload.update.scene
                                    , legal = payload.update.legal
                                    , model = model.backgammon
                                    , clock = Just payload.update.clock
                                    , receivedAt = model.clockReceivedAt
                                    , now = model.nowMs
                                    , nameOf = nameOf model
                                    , rematchReady = payload.rematchReady
                                    , finished = finished
                                    , away = awayIds payload
                                    , theme = theme model
                                    }
                                )

                        _ ->
                            -- Every registered game has a view; a slug
                            -- without one never reaches a table.
                            Html.p [ class "pixel text-xs text-center" ]
                                [ Html.text "NO VIEW FOR THIS GAME" ]
            in
            Html.div []
                [ game
                , case model.error of
                    Just err ->
                        Html.div
                            [ class "fixed bottom-2 left-1/2 -translate-x-1/2 z-40 pixel text-[10px] bg-white border-2 border-black px-3 py-2"
                            , id "play-error"
                            ]
                            [ Html.text err ]

                    Nothing ->
                        Html.text ""
                , case model.connectionStatus of
                    Disconnected ->
                        Html.div [ class "fixed top-2 left-1/2 -translate-x-1/2 z-40 pixel text-[10px] bg-white border-2 border-black px-3 py-2" ]
                            [ Html.text "RECONNECTING..." ]

                    _ ->
                        Html.text ""
                ]


{-| The room is not there any more (an hour idle, or a link that was never
good). Say so rather than reconnecting forever.
-}
gameGone : Model -> String -> Html Msg
gameGone model message =
    Html.div [ class "space-y-4 text-center", id "game-gone" ]
        [ Html.p [ class "pixel text-xs" ] [ Html.text "THIS GAME IS GONE" ]
        , Html.p [ class "text-sm", Notebook.style "color: var(--pencil)" ] [ Html.text message ]
        , Html.a
            [ Html.Attributes.href (Route.href (Route.gameLanding model.gameSlug))
            , class "btn-arcade inline-block"
            ]
            [ Html.text "START A NEW ONE" ]
        ]


{-| The waiting room: your seat is taken and the table is set, and all that
is missing is the other player. The link and the code are the two ways to
get them here; the game starts the moment either one lands.
-}
waiting : Model -> Protocol.Lobby -> Html Msg
waiting model lobby =
    let
        me =
            model.playerId
                |> Maybe.andThen
                    (\playerId ->
                        List.head (List.filter (\c -> c.id == playerId) lobby.connections)
                    )

        opponent =
            lobby.connections
                |> List.filter (\c -> Just c.id /= model.playerId)
                |> List.head
                |> Maybe.map .name
    in
    Html.div [ class "space-y-7" ]
        [ Html.div [ class "flex items-center justify-center gap-4 sm:gap-8" ]
            [ Html.div [ class "text-center min-w-[7rem]" ]
                [ Html.p [ class "pixel text-[9px] mb-1", Notebook.style "color: var(--pen)" ]
                    [ Html.text "1P" ]
                , Html.p [ class "text-player text-xl sm:text-2xl font-black truncate" ]
                    [ Html.text (me |> Maybe.map .name |> Maybe.withDefault "You") ]
                ]
            , Html.span [ class "pixel text-[10px]", Notebook.style "color: var(--pencil)" ]
                [ Html.text "VS" ]
            , Html.div [ class "text-center min-w-[7rem]" ]
                [ Html.p [ class "pixel text-[9px] mb-1", Notebook.style "color: var(--red)" ]
                    [ Html.text "2P" ]
                , case opponent of
                    Just name ->
                        Html.p [ class "text-opponent text-xl sm:text-2xl font-black truncate" ]
                            [ Html.text name ]

                    Nothing ->
                        Html.p
                            [ class "text-xl sm:text-2xl font-black blink"
                            , Notebook.style "color: var(--pencil)"
                            ]
                            [ Html.text "?" ]
                ]
            ]
        , Html.p
            [ id "setup-summary"
            , class "text-center font-semibold"
            , Notebook.style "color: var(--ink)"
            ]
            [ Html.text (Maybe.withDefault "" lobby.summary) ]
        , Html.div
            [ class "pix-sm p-4 text-center", Notebook.style "background: var(--paper-2)" ]
            [ Html.p [ class "pixel text-[10px] mb-2", Notebook.style "color: var(--ink)" ]
                [ Html.text "INVITE PLAYER 2" ]
            , inviteBox model
            , Html.div [ class "mt-3 pt-3", Notebook.style "border-top: 2px dashed var(--pencil)" ]
                [ Html.p [ class "pixel text-[9px] mb-1", Notebook.style "color: var(--pencil)" ]
                    [ Html.text "OR THEY CAN JOIN WITH CODE" ]
                , Html.p
                    [ id "game-code"
                    , class "pixel text-xl sm:text-2xl tracking-[0.3em]"
                    , Notebook.style "color: var(--ink)"
                    ]
                    [ Html.text model.gameId ]
                ]
            ]
        , Html.p [ class "text-center text-sm", Notebook.style "color: var(--pencil)" ]
            [ Html.text "Waiting for your opponent to open the link or enter the code… the game starts the moment they join." ]
        ]


{-| Native share on phones, clipboard elsewhere: the label says which
happened and goes back to COPY a moment later.
-}
inviteBox : Model -> Html Msg
inviteBox model =
    let
        url =
            inviteUrl model
    in
    Html.button
        [ Html.Attributes.type_ "button"
        , id "invite-button"
        , attribute "data-url" url
        , onClick ShareInvite
        , class "inline-flex items-center gap-2 max-w-full pix-flat px-3 py-2 text-sm hover:bg-[color:var(--highlighter)]"
        , Notebook.style "color: var(--ink)"
        ]
        [ Html.span [ class "hero-link w-4 h-4 shrink-0" ] []
        , Html.span [ id "share-link", class "truncate font-mono" ] [ Html.text url ]
        , Html.span [ attribute "data-label" "", class "pixel text-[9px] whitespace-nowrap" ]
            [ Html.text (Maybe.withDefault "COPY" model.shareLabel) ]
        ]
