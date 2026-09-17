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
attributes on a server-rendered div; now it takes the game id from the
route and asks JavaScript to open the channel (`joinGameChannel`), which is
the one thing Elm cannot do itself.

Nothing in the URL says who this browser is. The seat it holds, if it holds
one, is the room's own answer, given over the channel against the guest
cookie the websocket carried. A browser the room will not have is sent to
the invite link, which is the one page that says whether there is a seat
for it.

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
import View.Clock



-- PORTS


port sendToChannel : E.Value -> Cmd msg


port receiveFromChannel : (E.Value -> msg) -> Sub msg


{-| Open (or re-open) the game channel for a room. JavaScript owns the
socket; every message either way still goes through the two ports above.
-}
port joinGameChannel : { gameId : String } -> Cmd msg


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
    , ratings : Dict String Float -- each seat's PR so far in this match, once a game of it is graded
    , gamePrs : Dict Int (List ( String, Float )) -- each graded game's PRs, by game number, in seat order
    , awaySince : Dict String Int -- client time (ms) each absent player's drop was noticed
    , awayNew : List String -- players who went missing in the latest payload, awaiting their moment
    , ratingsGraded : Int -- games of this match the engine had answered for, as of the last ask
    , ratingsPolls : Int -- asks made while a grade is on its way; 0 is not waiting for one
    }


init :
    Session
    ->
        { origin : String
        , slug : String
        , gameId : String
        }
    -> ( Model, Cmd Msg )
init session config =
    ( { origin = config.origin
      , gameId = config.gameId
      , gameSlug = config.slug
      , playerId = Nothing
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
      , ratings = Dict.empty
      , gamePrs = Dict.empty
      , awaySince = Dict.empty
      , awayNew = []
      , ratingsGraded = 0
      , ratingsPolls = 0
      }
    , Cmd.batch
        -- One tick late, deliberately: a port message sent while the program
        -- is still being initialised has nobody subscribed to it yet.
        [ Task.perform (\_ -> ChannelRequested) (Process.sleep 0)

        -- What this guest picked on any of their browsers. The flags
        -- already carried what this one stored locally, so the board is
        -- painted before this answers; this is what follows them about.
        , Catalog.fetchPrefs session GotPrefs

        -- How the two of them are playing this match. Asked for once here
        -- and again when the game ends, which is when the engine gets
        -- another game to grade.
        , Catalog.fetchRatings session config.slug config.gameId GotRatings
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
    | GotRatings (Result Api.Error Catalog.Ratings)
    | PollRatings
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
            stay model (joinGameChannel { gameId = model.gameId })

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
            let
                at =
                    Time.posixToMillis posix
            in
            stay
                { model
                    | clockReceivedAt = at
                    , nowMs = at

                    -- Every payload asks for the time right after it lands,
                    -- so this is where a fresh absence gets its real
                    -- moment rather than a clock reading that may be
                    -- minutes stale.
                    , awaySince = notedAway at model
                }
                Cmd.none

        ClockTick posix ->
            stay { model | nowMs = Time.posixToMillis posix } Cmd.none

        RematchGameReady rematchGameId ->
            ( model, Cmd.none, Navigate (rematchUrl model rematchGameId) )

        ChannelError err ->
            -- The room will not have this browser and has told it nothing
            -- else: it holds no seat here. That is not an error to read at
            -- an empty table, it is a trip to the invite link, which is the
            -- one page that says whether there is a seat to take. A refusal
            -- once the table is up (a rejoin after a takeover) stays where
            -- it is: the player is looking at their own game.
            if err == refusedByRoom && model.payload == Nothing && model.lobby == Nothing then
                ( model
                , Cmd.none
                , Navigate (Route.href (Route.invite model.gameSlug model.gameId))
                )

            else
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

        GotRatings (Ok ratings) ->
            stay
                { model
                    | ratings = ratings.prs
                    , gamePrs = ratings.games
                    , ratingsGraded = max model.ratingsGraded ratings.graded
                    , ratingsPolls =
                        if ratings.pending then
                            -- A grade is on its way, whatever else landed:
                            -- keep watching. This is also what makes a page
                            -- opened in the middle of an analysis start.
                            nextPoll (max 1 model.ratingsPolls)

                        else if model.ratingsPolls > 0 && ratings.graded <= model.ratingsGraded then
                            -- Waiting on a game that ended here whose review
                            -- has not even been opened yet: the room queues
                            -- it as the game ends and the queue takes one
                            -- room at a time, so "nothing pending" right now
                            -- is not "nothing coming".
                            nextPoll model.ratingsPolls

                        else
                            -- Nothing owed and nothing outstanding.
                            0
                }
                Cmd.none

        GotRatings (Err _) ->
            -- A PR beside a name is a nicety, and the bars read fine
            -- without one. Keep whatever was there, and let the asking run
            -- out rather than hammering a server that is not answering.
            stay { model | ratingsPolls = nextPoll model.ratingsPolls } Cmd.none

        PollRatings ->
            stay model (Catalog.fetchRatings model.session model.gameSlug model.gameId GotRatings)

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

        -- Who has gone missing since the last update. On the very first
        -- payload nobody has: an opponent who left an hour ago is already
        -- gone, and flashing at them would say the opposite of the truth.
        previousAway =
            if model.connectionStatus /= Connected then
                -- This client was the one that was away. What the room says
                -- now is the first it has heard in a while, so none of it is
                -- news: an opponent listed here may have left long ago.
                awayIds payload

            else
                model.payload |> Maybe.map awayIds |> Maybe.withDefault (awayIds payload)

        updated =
            { model
                | payload = Just payload
                , playerId = Just payload.playerId
                , legal = payload.update.legal
                , backgammon = backgammon
                , connectionStatus = Connected
                , lobby = Nothing
                , awayNew = awayIds payload |> List.filter (\id -> not (List.member id previousAway))
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

        -- A game of this room is over, so the analysis engine has one more
        -- to grade than it did. Asking right now is too early -- the room
        -- queues the review as the game ends and the engine takes a while
        -- -- so this also starts the asking, which runs until the server
        -- says nothing is owed (`GotRatings`).
        gameEnded =
            matchPoints payload > (model.payload |> Maybe.map matchPoints |> Maybe.withDefault (matchPoints payload))

    in
    ( { updated
        | ratingsPolls =
            if gameEnded then
                1

            else
                updated.ratingsPolls
      }
    , Cmd.batch
        [ Task.perform ClockSynced Time.now
        , rollCmd
        , if gameEnded then
            Catalog.fetchRatings model.session model.gameSlug model.gameId GotRatings

          else
            Cmd.none
        ]
    , follow
    )


{-| How often the page asks again while a grade is coming, and how many
times it is willing to. The engine takes minutes on a long game at 4-ply
and works one room at a time, so the wait can be long: five seconds apart
for twenty minutes, the same patience the replay page has. Each ask is one
row read.
-}
pollRatingsEveryMs : Float
pollRatingsEveryMs =
    5000


maxRatingsPolls : Int
maxRatingsPolls =
    240


{-| The next ask, or a stop once the page has asked enough times. Zero
means it is not waiting for anything.
-}
nextPoll : Int -> Int
nextPoll polls =
    if polls > 0 && polls < maxRatingsPolls then
        polls + 1

    else
        0


{-| The points this room has awarded so far, both players' scores added up.
Every game that ends awards at least one, so this rising is how the page
notices a game ending -- which the outcome does not say, since a game
inside a match leaves the match itself ongoing.
-}
matchPoints : GamePayload -> Int
matchPoints payload =
    payload.update.scene.players |> List.map (Protocol.counter "score") |> List.sum


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


{-| When each absent player's drop was noticed. A player already noted
keeps the moment they were first missed, so the seconds their dot flashes
for run from the drop; one who is back is forgotten, so a second drop
flashes again.
-}
notedAway : Int -> Model -> Dict String Int
notedAway at model =
    model.payload
        |> Maybe.map awayIds
        |> Maybe.withDefault []
        |> List.filterMap
            (\id ->
                case Dict.get id model.awaySince of
                    Just since ->
                        Just ( id, since )

                    Nothing ->
                        -- Not noted yet: a moment only if they went missing
                        -- in the payload that just arrived. An absence this
                        -- page found already in progress has no moment, and
                        -- the dot goes straight to gone.
                        if List.member id model.awayNew then
                            Just ( id, at )

                        else
                            Nothing
            )
        |> Dict.fromList


{-| Is any absence still inside its flashing window? The clock is not the
only reason this page needs the time.
-}
flashing : Model -> Bool
flashing model =
    Dict.values model.awaySince
        |> List.any (\since -> model.nowMs - since < Backgammon.presenceFlashMs)


connectionStatusFromString : String -> ConnectionStatus
connectionStatusFromString status =
    case status of
        "connected" ->
            Connected

        "connecting" ->
            Connecting

        _ ->
            Disconnected


{-| What the game channel says to a browser that holds no seat at the room
(`OskolWeb.GameChannel`). It never says which of the reasons it was.
-}
refusedByRoom : String
refusedByRoom =
    "unauthorized"


{-| A rematch is the same players in the same seats, and the room carries
the guest holding each one over, so both browsers walk straight in: the
new room's plain URL is all either of them needs.
-}
rematchUrl : Model -> String -> String
rematchUrl model rematchGameId =
    Route.href (Route.play model.gameSlug rematchGameId)


{-| The plain invite link for this room: nothing identifying, and now the
same URL this page is at. What it offers is the room's decision, not the
link's.
-}
inviteUrl : Model -> String
inviteUrl model =
    model.origin ++ Route.href (Route.invite model.gameSlug model.gameId)


{-| Where a finished game of this room is replayed. A spectator (no seat in
the scene) is offered none, which is a matter of what the table shows, not
of what the replay will open: it opens for anyone.
-}
replayHref : Model -> GamePayload -> Int -> Maybe String
replayHref model payload number =
    if List.any (\p -> p.id == payload.playerId) payload.players then
        Just (Route.href (Route.replay model.gameSlug model.gameId (Just number)))

    else
        Nothing


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
        , if clockRunning model || flashing model then
            Time.every 200 ClockTick

          else
            Sub.none
        , if model.ratingsPolls > 0 then
            Time.every pollRatingsEveryMs (\_ -> PollRatings)

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
                                    , away = Just (awayIds payload)
                                    , awaySince = \id -> Dict.get id model.awaySince
                                    , prOf = \id -> Dict.get id model.ratings
                                    , theme = theme model
                                    , replayHref = replayHref model payload
                                    , gamePrs = \n -> Dict.get n model.gamePrs |> Maybe.withDefault []
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
