port module Main exposing (ConnectionStatus(..), Flags, Model, Msg(..), applyPayload, init, main, update)

{-| The one client for every game. It decodes the gamekit protocol, keeps the
latest payload, and hands the scene to a renderer: a bespoke view where a
game has one, the generic renderer otherwise.
-}

import Browser
import Browser.Dom
import Games.Backgammon.View as Backgammon
import Games.Chess.View as Chess
import Games.Poker.View as Poker
import Generic.View
import Html exposing (Html)
import Html.Attributes exposing (class)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (GamePayload, ServerMessage(..))
import Task
import Time
import Url exposing (percentEncode)
import View.Clock



-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- PORTS


port sendToChannel : E.Value -> Cmd msg


port receiveFromChannel : (E.Value -> msg) -> Sub msg


port navigateToUrl : String -> Cmd msg



-- MODEL


type alias Flags =
    { gameId : String
    , gameSlug : String
    , playerId : Maybe String
    , seatToken : Maybe String
    }


type ConnectionStatus
    = Disconnected
    | Connecting
    | Connected


type alias Model =
    { gameId : String
    , gameSlug : String
    , playerId : Maybe String
    , seatToken : Maybe String -- this seat's credential, carried into a rematch
    , payload : Maybe GamePayload -- latest protocol payload from the server
    , legal : List Protocol.Schema -- legal action schemas for this player
    , generic : Generic.View.Model
    , backgammon : Backgammon.Model
    , chess : Chess.Model
    , poker : Poker.Model
    , clockReceivedAt : Int -- client time (ms) when the latest clock snapshot arrived
    , nowMs : Int -- client time (ms), refreshed while a clock runs
    , connectionStatus : ConnectionStatus
    , error : Maybe String
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { gameId = flags.gameId
      , gameSlug = flags.gameSlug
      , playerId = flags.playerId
      , seatToken = flags.seatToken
      , payload = Nothing
      , legal = []
      , generic = Generic.View.init
      , backgammon = Backgammon.init
      , chess = Chess.init
      , poker = Poker.init
      , clockReceivedAt = 0
      , nowMs = 0
      , connectionStatus = Connecting
      , error = Nothing
      }
    , Cmd.none
    )



-- UPDATE


type Msg
    = ServerMessageReceived ServerMessage
    | GenericMsg Generic.View.Msg
    | BackgammonMsg Backgammon.Msg
    | ChessMsg Chess.Msg
    | PokerMsg Poker.Msg
    | PokerAutoDeal
    | ClockSynced Time.Posix
    | ClockTick Time.Posix
    | RematchGameReady String
    | ChannelError String
    | ConnectionStatusChanged ConnectionStatus
    | RequestRematch
    | NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ServerMessageReceived message ->
            case message of
                GameMessage payload ->
                    applyPayload payload model

                LobbyMessage ->
                    ( { model | connectionStatus = Connected }, Cmd.none )

                ErrorMessage err ->
                    update (ChannelError err) model

                RematchReadyMessage rematchGameId ->
                    update (RematchGameReady rematchGameId) model

                StatusMessage status ->
                    update (ConnectionStatusChanged (connectionStatusFromString status)) model

        GenericMsg genericMsg ->
            let
                ( generic, maybeAction ) =
                    Generic.View.update genericMsg model.generic
            in
            ( { model | generic = generic, error = Nothing }
            , maybeAction |> Maybe.map sendToChannel |> Maybe.withDefault Cmd.none
            )

        BackgammonMsg bgMsg ->
            let
                ( bg, out ) =
                    Backgammon.update bgMsg model.backgammon

                updated =
                    { model | backgammon = bg, error = Nothing }
            in
            case out of
                Backgammon.NoOut ->
                    ( updated, Cmd.none )

                Backgammon.Send value ->
                    ( updated, sendToChannel value )

                Backgammon.SendMany values ->
                    ( updated, Cmd.batch (List.map sendToChannel values) )

                Backgammon.WantRematch ->
                    update RequestRematch updated

                Backgammon.NeedZones targets ->
                    ( updated, measureDropZones targets )

        ChessMsg chessMsg ->
            let
                ( chess, out ) =
                    Chess.update chessMsg model.chess

                updated =
                    { model | chess = chess, error = Nothing }
            in
            case out of
                Chess.NoOut ->
                    ( updated, Cmd.none )

                Chess.Send value ->
                    ( updated, sendToChannel value )

                Chess.WantRematch ->
                    update RequestRematch updated

        PokerMsg pokerMsg ->
            let
                ( poker, out ) =
                    Poker.update pokerMsg model.poker

                updated =
                    { model | poker = poker, error = Nothing }
            in
            case out of
                Poker.NoOut ->
                    ( updated, Cmd.none )

                Poker.Send value ->
                    ( updated, sendToChannel value )

                Poker.WantRematch ->
                    update RequestRematch updated

        PokerAutoDeal ->
            case pokerCtx model of
                Just ctx ->
                    if Poker.wantsAutoDeal ctx then
                        ( model, sendToChannel (Protocol.encodeAction "deal" []) )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ClockSynced posix ->
            ( { model | clockReceivedAt = Time.posixToMillis posix, nowMs = Time.posixToMillis posix }
            , Cmd.none
            )

        ClockTick posix ->
            ( { model | nowMs = Time.posixToMillis posix }, Cmd.none )

        RematchGameReady rematchGameId ->
            ( model
            , navigateToUrl (rematchUrl model rematchGameId)
            )

        ChannelError err ->
            ( { model | error = Just err }, Cmd.none )

        ConnectionStatusChanged status ->
            ( { model | connectionStatus = status }, Cmd.none )

        RequestRematch ->
            ( model, sendToChannel Protocol.encodeRematch )

        NoOp ->
            ( model, Cmd.none )


{-| Absorb a server payload: remember it and the legal actions, resync the
clock to client time, and let backgammon roll for the viewer when there is
no doubling decision to make (`Backgammon.autoRoll`; fires at most once
per arriving state, so nothing here can loop).
-}
applyPayload : GamePayload -> Model -> ( Model, Cmd Msg )
applyPayload payload model =
    let
        ( backgammon, rollCmd ) =
            if model.gameSlug == "backgammon" then
                Backgammon.autoRoll payload.update.legal model.backgammon
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
            }

        -- A rematch accepted while this client was away arrives in the
        -- payload rather than as a rematch_ready push: follow it.
        follow =
            case payload.rematchGameId of
                Just rematchGameId ->
                    if List.member payload.playerId payload.rematchReady && (model.payload |> Maybe.andThen .rematchGameId) /= Just rematchGameId then
                        navigateToUrl (rematchUrl updated rematchGameId)

                    else
                        Cmd.none

                Nothing ->
                    Cmd.none
    in
    ( updated
    , Cmd.batch [ Task.perform ClockSynced Time.now, follow, rollCmd ]
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


pokerCtx : Model -> Maybe Poker.Ctx
pokerCtx model =
    case ( model.gameSlug, model.payload ) of
        ( "poker", Just payload ) ->
            Just
                { playerId = payload.playerId
                , scene = payload.update.scene
                , legal = payload.update.legal
                , model = model.poker
                , clock = Just payload.update.clock
                , receivedAt = model.clockReceivedAt
                , now = model.nowMs
                , nameOf = nameOf model
                , rematchReady = payload.rematchReady
                , finished = finishedWinners payload
                , away = awayIds payload
                }

        _ ->
            Nothing



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveFromChannel handleChannelMessage
        , if clockRunning model then
            Time.every 200 ClockTick

          else
            Sub.none
        , case pokerCtx model of
            Just ctx ->
                if Poker.wantsAutoDeal ctx then
                    Time.every 3500 (\_ -> PokerAutoDeal)

                else
                    Sub.none

            Nothing ->
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
            Html.div [ class "paper min-h-screen flex flex-col items-center justify-center gap-4 px-6 text-center" ]
                (case model.error of
                    Just err ->
                        [ Html.p [ class "pixel text-xs" ] [ Html.text "THIS GAME IS GONE" ]
                        , Html.p [ class "text-sm", Html.Attributes.style "color" "var(--pencil)" ] [ Html.text err ]
                        , Html.a [ Html.Attributes.href ("/" ++ model.gameSlug), class "btn-arcade" ] [ Html.text "START A NEW ONE" ]
                        ]

                    Nothing ->
                        [ Html.p [ class "pixel text-xs" ]
                            [ Html.text
                                (case model.connectionStatus of
                                    Disconnected ->
                                        "DISCONNECTED"

                                    _ ->
                                        "CONNECTING..."
                                )
                            ]
                        ]
                )

        Just payload ->
            let
                finished =
                    finishedWinners payload

                game =
                    case ( model.gameSlug, pokerCtx model ) of
                        ( "backgammon", _ ) ->
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
                                    }
                                )

                        ( "chess", _ ) ->
                            Html.map ChessMsg
                                (Chess.view
                                    { playerId = payload.playerId
                                    , scene = payload.update.scene
                                    , legal = payload.update.legal
                                    , model = model.chess
                                    , clock = Just payload.update.clock
                                    , receivedAt = model.clockReceivedAt
                                    , now = model.nowMs
                                    , nameOf = nameOf model
                                    , rematchReady = payload.rematchReady
                                    , finished = finished
                                    , away = awayIds payload
                                    }
                                )

                        ( "poker", Just ctx ) ->
                            Html.map PokerMsg (Poker.view ctx)

                        _ ->
                            Html.map GenericMsg
                                (Generic.View.view
                                    { playerId = payload.playerId
                                    , scene = payload.update.scene
                                    , legal = payload.update.legal
                                    , model = model.generic
                                    , clock = Just payload.update.clock
                                    , receivedAt = model.clockReceivedAt
                                    , now = model.nowMs
                                    , nameOf = nameOf model
                                    , finished = finished
                                    , away = awayIds payload
                                    }
                                )
            in
            Html.div []
                [ game
                , case model.error of
                    Just err ->
                        Html.div [ class "fixed bottom-2 left-1/2 -translate-x-1/2 z-40 pixel text-[10px] bg-white border-2 border-black px-3 py-2" ]
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
