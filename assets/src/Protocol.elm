module Protocol exposing
    ( Clock
    , ClockPlayer
    , Connection
    , Event(..)
    , GamePayload
    , Layout(..)
    , Outcome(..)
    , Param
    , ParamKind(..)
    , PlayerInfo
    , Scene
    , Schema
    , ServerMessage(..)
    , Token
    , Update
    , Zone
    , counter
    , encodeAction
    , encodeRematch
    , eventDecoder
    , findPlayer
    , formatClock
    , remainingNow
    , findZone
    , hasFlag
    , opponentOf
    , payloadDecoder
    , playerData
    , sceneData
    , serverMessageDecoder
    , schemaDecoder
    , sceneDecoder
    , tokenProp
    , tokensMovedTo
    , updateDecoder
    , zoneTokens
    )

{-| The wire protocol shared by every game.

The server sends a Scene (zones of tokens plus per-player counters and
flags), the legal action schemas for this player, the outcome, and the
events that led here. The client sends actions as `{name, params}`.

Nothing in this module knows about any particular game.

-}

import Dict exposing (Dict)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E



-- TYPES


type alias Scene =
    { game : String
    , phase : String
    , viewer : Maybe String
    , players : List PlayerInfo
    , zones : List Zone
    , data : D.Value
    }


type alias PlayerInfo =
    { id : String
    , name : String
    , counters : Dict String Int
    , flags : List String
    , data : D.Value
    }


type Layout
    = Fan
    | Stack
    | Row
    | Grid Int Int
    | Free


type alias Token =
    { id : String
    , kind : String
    , faceUp : Bool
    , position : Maybe ( Int, Int )
    , props : D.Value
    }


type alias Zone =
    { id : String
    , owner : Maybe String
    , layout : Layout
    , tokens : List Token
    , count : Int
    }


type Event
    = TokenMoved String (Maybe String) (Maybe String)
    | CounterChanged String String Int Int
    | Revealed String String
    | PhaseChanged String
    | Message String
    | Custom String D.Value


type ParamKind
    = Select { zone : String, candidates : List String, min : Int, max : Int }
    | Choice (List ( String, String ))
    | Number Int Int


type alias Param =
    { name : String
    , kind : ParamKind
    }


type alias Schema =
    { name : String
    , label : String
    , params : List Param
    }


type Outcome
    = Ongoing
    | Finished (List String)


type alias Update =
    { scene : Scene
    , legal : List Schema
    , outcome : Outcome
    , events : List Event
    , clock : Clock
    }


{-| Clock state as of the moment the server built the update. A running
clock keeps ticking on the client: see `remainingNow`.
-}
type alias Clock =
    { enabled : Bool
    , label : String
    , players : List ClockPlayer
    , timedOut : Maybe String
    }


type alias ClockPlayer =
    { id : String
    , remainingMs : Int
    , moveMs : Int -- free time left on the current move (delay or action allowance)
    , running : Bool
    }


type alias Connection =
    { id : String
    , name : String
    , connected : Bool
    }


type alias GamePayload =
    { game : String
    , gameId : String
    , playerId : String
    , players : List Connection
    , rematchReady : List String
    , rematchGameId : Maybe String
    , update : Update
    }


type ServerMessage
    = LobbyMessage
    | GameMessage GamePayload
    | ErrorMessage String
    | RematchReadyMessage String
    | StatusMessage String



-- QUERIES


findZone : String -> Scene -> Maybe Zone
findZone zoneId scene =
    scene.zones |> List.filter (\z -> z.id == zoneId) |> List.head


zoneTokens : String -> Scene -> List Token
zoneTokens zoneId scene =
    findZone zoneId scene |> Maybe.map .tokens |> Maybe.withDefault []


findPlayer : String -> Scene -> Maybe PlayerInfo
findPlayer playerId scene =
    scene.players |> List.filter (\p -> p.id == playerId) |> List.head


{-| The first player who is not the given one (two-player games).
-}
opponentOf : String -> Scene -> Maybe PlayerInfo
opponentOf playerId scene =
    scene.players |> List.filter (\p -> p.id /= playerId) |> List.head


counter : String -> PlayerInfo -> Int
counter name player =
    Dict.get name player.counters |> Maybe.withDefault 0


hasFlag : String -> PlayerInfo -> Bool
hasFlag name player =
    List.member name player.flags


playerData : Decoder a -> String -> PlayerInfo -> Maybe a
playerData decoder field player =
    D.decodeValue (D.field field decoder) player.data |> Result.toMaybe


sceneData : Decoder a -> String -> Scene -> Maybe a
sceneData decoder field scene =
    D.decodeValue (D.field field decoder) scene.data |> Result.toMaybe


tokenProp : Decoder a -> String -> Token -> Maybe a
tokenProp decoder field token =
    D.decodeValue (D.field field decoder) token.props |> Result.toMaybe


{-| Ids of tokens that moved into the given zone during these events.
-}
tokensMovedTo : String -> List Event -> List String
tokensMovedTo zoneId events =
    events
        |> List.filterMap
            (\event ->
                case event of
                    TokenMoved tokenId _ (Just to) ->
                        if to == zoneId then
                            Just tokenId

                        else
                            Nothing

                    _ ->
                        Nothing
            )



-- DECODERS


serverMessageDecoder : Decoder ServerMessage
serverMessageDecoder =
    D.field "type" D.string
        |> D.andThen
            (\msgType ->
                case msgType of
                    "payload" ->
                        D.field "payload" payloadOrLobbyDecoder

                    "error" ->
                        D.map ErrorMessage (D.field "message" D.string)

                    "rematch_ready" ->
                        D.map RematchReadyMessage (D.field "game_id" D.string)

                    "connection_status" ->
                        D.map StatusMessage (D.field "status" D.string)

                    _ ->
                        D.fail ("Unknown message type: " ++ msgType)
            )


payloadOrLobbyDecoder : Decoder ServerMessage
payloadOrLobbyDecoder =
    D.field "type" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "lobby" ->
                        D.succeed LobbyMessage

                    "game" ->
                        D.map GameMessage payloadDecoder

                    _ ->
                        D.fail ("Unknown payload type: " ++ kind)
            )


payloadDecoder : Decoder GamePayload
payloadDecoder =
    D.map7 GamePayload
        (D.field "game" D.string)
        (D.field "game_id" D.string)
        (D.field "player_id" D.string)
        (D.field "players" (D.list connectionDecoder))
        (D.field "rematch_ready" (D.list D.string))
        (D.field "rematch_game_id" (D.nullable D.string))
        (D.field "update" updateDecoder)


connectionDecoder : Decoder Connection
connectionDecoder =
    D.map3 Connection
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "connected" D.bool)


updateDecoder : Decoder Update
updateDecoder =
    D.map5 Update
        (D.field "scene" sceneDecoder)
        (D.field "legal" (D.list schemaDecoder))
        (D.field "outcome" outcomeDecoder)
        (D.field "events" (D.list eventDecoder))
        (D.field "clock" clockDecoder)


clockDecoder : Decoder Clock
clockDecoder =
    D.map4 Clock
        (D.field "enabled" D.bool)
        (D.field "label" D.string)
        (D.field "players" (D.list clockPlayerDecoder))
        (D.field "timed_out" (D.nullable D.string))


clockPlayerDecoder : Decoder ClockPlayer
clockPlayerDecoder =
    D.map4 ClockPlayer
        (D.field "id" D.string)
        (D.field "remaining_ms" D.int)
        (D.oneOf [ D.field "move_ms" D.int, D.succeed 0 ])
        (D.field "running" D.bool)


sceneDecoder : Decoder Scene
sceneDecoder =
    D.map6 Scene
        (D.field "game" D.string)
        (D.field "phase" D.string)
        (D.field "viewer" (D.nullable D.string))
        (D.field "players" (D.list playerInfoDecoder))
        (D.field "zones" (D.list zoneDecoder))
        (D.field "data" D.value)


playerInfoDecoder : Decoder PlayerInfo
playerInfoDecoder =
    D.map5 PlayerInfo
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "counters" (D.dict D.int))
        (D.field "flags" (D.list D.string))
        (D.field "data" D.value)


zoneDecoder : Decoder Zone
zoneDecoder =
    D.map5 Zone
        (D.field "id" D.string)
        (D.field "owner" (D.nullable D.string))
        (D.field "layout" layoutDecoder)
        (D.field "tokens" (D.list tokenDecoder))
        (D.field "count" D.int)


layoutDecoder : Decoder Layout
layoutDecoder =
    D.field "type" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "fan" ->
                        D.succeed Fan

                    "stack" ->
                        D.succeed Stack

                    "row" ->
                        D.succeed Row

                    "grid" ->
                        D.map2 Grid (D.field "columns" D.int) (D.field "rows" D.int)

                    "free" ->
                        D.succeed Free

                    _ ->
                        D.fail ("Unknown layout: " ++ kind)
            )


tokenDecoder : Decoder Token
tokenDecoder =
    D.map5 Token
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "face" (D.map (\f -> f == "up") D.string))
        (D.field "position" (D.nullable (D.map2 Tuple.pair (D.index 0 D.int) (D.index 1 D.int))))
        (D.field "props" D.value)


eventDecoder : Decoder Event
eventDecoder =
    D.field "type" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "token_moved" ->
                        D.map3 TokenMoved
                            (D.field "token_id" D.string)
                            (D.field "from" (D.nullable D.string))
                            (D.field "to" (D.nullable D.string))

                    "counter_changed" ->
                        D.map4 CounterChanged
                            (D.field "player_id" D.string)
                            (D.field "counter" D.string)
                            (D.field "from" D.int)
                            (D.field "to" D.int)

                    "revealed" ->
                        D.map2 Revealed (D.field "token_id" D.string) (D.field "zone_id" D.string)

                    "phase_changed" ->
                        D.map PhaseChanged (D.field "phase" D.string)

                    "message" ->
                        D.map Message (D.field "text" D.string)

                    "custom" ->
                        D.map2 Custom (D.field "kind" D.string) (D.field "payload" D.value)

                    _ ->
                        D.fail ("Unknown event type: " ++ kind)
            )


schemaDecoder : Decoder Schema
schemaDecoder =
    D.map3 Schema
        (D.field "name" D.string)
        (D.field "label" D.string)
        (D.field "params" (D.list paramDecoder))


paramDecoder : Decoder Param
paramDecoder =
    D.map2 Param
        (D.field "name" D.string)
        paramKindDecoder


paramKindDecoder : Decoder ParamKind
paramKindDecoder =
    D.field "type" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "select" ->
                        D.map4 (\zone candidates min max -> Select { zone = zone, candidates = candidates, min = min, max = max })
                            (D.field "zone" D.string)
                            (D.field "candidates" (D.list D.string))
                            (D.field "min" D.int)
                            (D.field "max" D.int)

                    "choice" ->
                        D.map Choice
                            (D.field "options"
                                (D.list (D.map2 Tuple.pair (D.field "id" D.string) (D.field "label" D.string)))
                            )

                    "number" ->
                        D.map2 Number (D.field "min" D.int) (D.field "max" D.int)

                    _ ->
                        D.fail ("Unknown param type: " ++ kind)
            )


outcomeDecoder : Decoder Outcome
outcomeDecoder =
    D.field "status" D.string
        |> D.andThen
            (\status ->
                case status of
                    "ongoing" ->
                        D.succeed Ongoing

                    "finished" ->
                        D.map Finished (D.field "winners" (D.list D.string))

                    _ ->
                        D.fail ("Unknown outcome: " ++ status)
            )



-- CLOCK HELPERS


{-| Time left for a player right now, given when the update arrived and the
current time (both in milliseconds of the same clock).
-}
remainingNow : ClockPlayer -> Int -> Int -> Int
remainingNow player receivedAt now =
    if player.running then
        max 0 (player.remainingMs - max 0 (now - receivedAt))

    else
        player.remainingMs


{-| "4:05", or "9.4" under ten seconds.
-}
formatClock : Int -> String
formatClock ms =
    let
        totalSeconds =
            ms // 1000

        minutes =
            totalSeconds // 60

        seconds =
            modBy 60 totalSeconds
    in
    if ms < 10000 then
        String.fromInt (ms // 1000) ++ "." ++ String.fromInt (modBy 10 (ms // 100))

    else
        String.fromInt minutes ++ ":" ++ String.padLeft 2 '0' (String.fromInt seconds)



-- ENCODERS


{-| An action for the server: `{type: "action", name, params}`.
-}
encodeAction : String -> List ( String, E.Value ) -> E.Value
encodeAction name params =
    E.object
        [ ( "type", E.string "action" )
        , ( "name", E.string name )
        , ( "params", E.object params )
        ]


encodeRematch : E.Value
encodeRematch =
    E.object [ ( "type", E.string "rematch" ) ]
