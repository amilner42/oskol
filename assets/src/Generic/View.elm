module Generic.View exposing (Model, Msg(..), init, update, view)

{-| A plain renderer for any game on the protocol: zones of tokens, player
counters, clocks, and the legal actions as buttons. Games get this for free
before they have a bespoke UI.

Conventions it understands (all optional props on tokens):

  - `color`: "white" | "black" | any CSS color, drawn as a disc
  - `value`: a number shown on the token (dice)
  - `used`: dims the token

Zones whose ids share a prefix before ":" and number more than six (for
example `point:1`..`point:24`) are drawn as one horizontal strip.

-}

import Dict exposing (Dict)
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (ParamKind(..), Scene, Schema, Token, Zone)
import Set exposing (Set)


type alias Model =
    { selected : Set String
    , choices : Dict String String
    , activeAction : Maybe Int
    }


type Msg
    = ToggleToken String
    | ChooseAction Int Schema
    | ChooseOption String String
    | Submit Schema
    | Cancel


init : Model
init =
    { selected = Set.empty, choices = Dict.empty, activeAction = Nothing }


{-| Returns the new model and, when an action is complete, the JSON to send.
-}
update : Msg -> Model -> ( Model, Maybe E.Value )
update msg model =
    case msg of
        ToggleToken tokenId ->
            ( { model
                | selected =
                    if Set.member tokenId model.selected then
                        Set.remove tokenId model.selected

                    else
                        Set.insert tokenId model.selected
              }
            , Nothing
            )

        ChooseAction index schema ->
            if needsInput schema then
                ( { init | activeAction = Just index }, Nothing )

            else
                -- Nothing to pick: fire it straight away
                ( init, Just (encode schema init) )

        ChooseOption param option ->
            ( { model | choices = Dict.insert param option model.choices }, Nothing )

        Cancel ->
            ( init, Nothing )

        Submit schema ->
            ( init, Just (encode schema model) )


{-| A schema needs the player to pick something when it has a Select param or
a Choice with more than one option.
-}
needsInput : Schema -> Bool
needsInput schema =
    List.any
        (\param ->
            case param.kind of
                Select _ ->
                    True

                Choice options ->
                    List.length options > 1

                Number min max ->
                    min /= max
        )
        schema.params


encode : Schema -> Model -> E.Value
encode schema model =
    Protocol.encodeAction schema.name
        (List.map
            (\param ->
                case param.kind of
                    Select _ ->
                        ( param.name, E.list E.string (Set.toList model.selected) )

                    Choice options ->
                        ( param.name
                        , Dict.get param.name model.choices
                            |> Maybe.map E.string
                            |> Maybe.withDefault
                                (options |> List.head |> Maybe.map (Tuple.first >> E.string) |> Maybe.withDefault E.null)
                        )

                    Number min _ ->
                        ( param.name, E.int min )
            )
            schema.params
        )



-- VIEW


view :
    { playerId : String
    , scene : Scene
    , legal : List Schema
    , model : Model
    , status : String
    , clock : Html Msg
    }
    -> Html Msg
view { playerId, scene, legal, model, status, clock } =
    div [ class "min-h-screen bg-[#1a1d29] text-gray-100 p-3 sm:p-4 space-y-4 text-sm" ]
        [ div [ class "flex items-start justify-between gap-4" ]
            [ div []
                [ span [ class "text-xl font-bold capitalize" ] [ text scene.game ]
                , span [ class "text-gray-400 ml-3" ] [ text (scene.phase ++ " · " ++ status) ]
                ]
            , clock
            ]
        , div [ class "grid gap-2 sm:grid-cols-2" ] (List.map (viewPlayer playerId) scene.players)
        , viewActions scene playerId model legal
        , div [ class "space-y-3" ] (List.map (viewGroup scene model legal) (groupZones scene.zones))
        ]


viewPlayer : String -> Protocol.PlayerInfo -> Html Msg
viewPlayer playerId player =
    div
        [ classList
            [ ( "rounded-lg p-3 bg-white/5 border", True )
            , ( "border-blue-400", player.id == playerId )
            , ( "border-white/10", player.id /= playerId )
            ]
        ]
        [ div [ class "font-bold flex items-center gap-2" ]
            [ text player.name
            , span [ class "text-xs font-normal text-gray-400" ]
                [ text
                    (if player.id == playerId then
                        "(you)"

                     else
                        ""
                    )
                ]
            ]
        , div [ class "text-gray-300 flex flex-wrap gap-x-3 font-mono text-xs" ]
            (player.counters
                |> Dict.toList
                |> List.map (\( k, v ) -> span [] [ text (k ++ " " ++ String.fromInt v) ])
            )
        , div [ class "text-yellow-300 text-xs" ] [ text (String.join ", " player.flags) ]
        ]



-- ZONES


type ZoneGroup
    = Single Zone
    | Strip String (List Zone)


groupZones : List Zone -> List ZoneGroup
groupZones zones =
    let
        prefixOf zone =
            case String.split ":" zone.id of
                [ p, _ ] ->
                    Just p

                _ ->
                    Nothing

        counts =
            List.foldl
                (\zone acc ->
                    case prefixOf zone of
                        Just p ->
                            Dict.update p (Maybe.withDefault 0 >> (+) 1 >> Just) acc

                        Nothing ->
                            acc
                )
                Dict.empty
                zones

        isStrip zone =
            case prefixOf zone of
                Just p ->
                    (Dict.get p counts |> Maybe.withDefault 0) > 6

                Nothing ->
                    False

        stripPrefixes =
            zones |> List.filter isStrip |> List.filterMap prefixOf |> unique
    in
    List.map (\p -> Strip p (List.filter (\z -> prefixOf z == Just p) zones)) stripPrefixes
        ++ (zones |> List.filter (not << isStrip) |> List.map Single)


unique : List comparable -> List comparable
unique items =
    List.foldl
        (\item acc ->
            if List.member item acc then
                acc

            else
                acc ++ [ item ]
        )
        []
        items


viewGroup : Scene -> Model -> List Schema -> ZoneGroup -> Html Msg
viewGroup scene model legal group =
    case group of
        Single zone ->
            viewZone scene model legal zone

        Strip prefix zones ->
            div [ class "rounded-lg bg-white/5 p-3 overflow-x-auto" ]
                [ div [ class "text-gray-400 text-xs mb-2" ] [ text prefix ]
                , div [ class "flex gap-1 min-w-max" ] (List.map (viewColumn model legal) zones)
                ]


viewColumn : Model -> List Schema -> Zone -> Html Msg
viewColumn model legal zone =
    let
        selectable =
            selectableIn model legal zone.id

        label =
            String.split ":" zone.id |> List.drop 1 |> String.join ":"
    in
    div [ class "flex flex-col items-center gap-0.5 w-8" ]
        [ span [ class "text-[10px] text-gray-500" ] [ text label ]
        , div [ class "flex flex-col-reverse items-center gap-0.5 min-h-[7rem] bg-white/5 rounded w-full py-1" ]
            (List.map (viewToken model selectable True) zone.tokens)
        ]


viewZone : Scene -> Model -> List Schema -> Zone -> Html Msg
viewZone scene model legal zone =
    let
        selectable =
            selectableIn model legal zone.id

        -- "bar:<player id>" reads as "bar · Alice"
        label =
            case ( String.split ":" zone.id, zone.owner ) of
                ( [ prefix, _ ], Just owner ) ->
                    prefix
                        ++ " · "
                        ++ (Protocol.findPlayer owner scene |> Maybe.map .name |> Maybe.withDefault owner)

                _ ->
                    zone.id
    in
    div [ class "rounded-lg bg-white/5 p-3" ]
        [ div [ class "text-gray-400 text-xs mb-2" ]
            [ text (label ++ " (" ++ String.fromInt zone.count ++ ")") ]
        , div [ class "flex flex-wrap gap-2 items-center" ]
            (if List.isEmpty zone.tokens then
                List.repeat (min zone.count 12) (div [ class "w-8 h-11 rounded bg-white/10" ] [])

             else
                List.map (viewToken model selectable False) zone.tokens
            )
        ]


selectableIn : Model -> List Schema -> String -> Set String
selectableIn model legal zoneId =
    case model.activeAction of
        Nothing ->
            Set.empty

        Just index ->
            legal
                |> List.drop index
                |> List.head
                |> Maybe.map .params
                |> Maybe.withDefault []
                |> List.concatMap
                    (\param ->
                        case param.kind of
                            Select sel ->
                                if sel.zone == zoneId then
                                    sel.candidates

                                else
                                    []

                            _ ->
                                []
                    )
                |> Set.fromList


viewToken : Model -> Set String -> Bool -> Token -> Html Msg
viewToken model selectable compact token =
    let
        canSelect =
            Set.member token.id selectable

        color =
            Protocol.tokenProp D.string "color" token

        value =
            Protocol.tokenProp D.int "value" token

        used =
            Protocol.tokenProp D.bool "used" token |> Maybe.withDefault False

        dimmed =
            used || (not canSelect && model.activeAction /= Nothing)

        selectedRing =
            Set.member token.id model.selected

        base =
            [ ( "flex items-center justify-center border text-xs font-bold transition-all", True )
            , ( "ring-2 ring-yellow-400", selectedRing )
            , ( "opacity-40", dimmed )
            , ( "cursor-pointer hover:scale-105", canSelect )
            ]
    in
    case ( token.faceUp, color, value ) of
        ( False, _, _ ) ->
            button
                [ classList (base ++ [ ( "w-8 h-11 rounded bg-gray-700 border-gray-500", True ) ])
                , disabled (not canSelect)
                , onClick (ToggleToken token.id)
                ]
                [ text "?" ]

        ( True, Just c, _ ) ->
            button
                [ classList (base ++ [ ( "w-6 h-6 rounded-full border-black/40", True ) ])
                , style "background" (cssColor c)
                , style "color"
                    (if c == "white" then
                        "#111"

                     else
                        "#eee"
                    )
                , title token.id
                , disabled (not canSelect)
                , onClick (ToggleToken token.id)
                ]
                []

        ( True, Nothing, Just v ) ->
            div
                [ classList (base ++ [ ( "w-9 h-9 rounded-md bg-white text-gray-900 border-gray-300 text-base", True ) ])
                , title token.id
                ]
                [ text (String.fromInt v) ]

        ( True, Nothing, Nothing ) ->
            button
                [ classList
                    (base
                        ++ [ ( "rounded bg-white text-gray-900 border-white px-1", True )
                           , ( "min-w-[2rem] h-11", not compact )
                           , ( "min-w-[1.5rem] h-8", compact )
                           ]
                    )
                , disabled (not canSelect)
                , onClick (ToggleToken token.id)
                ]
                [ text (tokenLabel token) ]


cssColor : String -> String
cssColor c =
    case c of
        "white" ->
            "#f5f5f0"

        "black" ->
            "#2a2a30"

        other ->
            other


tokenLabel : Token -> String
tokenLabel token =
    case D.decodeValue (D.keyValuePairs D.value) token.props of
        Ok pairs ->
            pairs
                |> List.take 3
                |> List.map (\( _, v ) -> E.encode 0 v |> String.replace "\"" "")
                |> String.join " "
                |> (\s ->
                        if s == "" then
                            token.id

                        else
                            s
                   )

        Err _ ->
            token.id



-- ACTIONS


viewActions : Scene -> String -> Model -> List Schema -> Html Msg
viewActions scene playerId model legal =
    let
        -- Convention: a `to_move` flag on a player marks whose turn it is.
        turnOf =
            scene.players |> List.filter (Protocol.hasFlag "to_move") |> List.head

        waitingHint =
            case turnOf of
                Just p ->
                    if p.id == playerId then
                        []

                    else
                        [ span [ class "text-gray-500 mr-2" ] [ text ("Waiting for " ++ p.name ++ "...") ] ]

                Nothing ->
                    if List.isEmpty legal then
                        [ span [ class "text-gray-500" ] [ text "Waiting for your opponent..." ] ]

                    else
                        []
    in
    div [ class "rounded-lg bg-white/5 p-3 flex flex-wrap gap-2 items-center min-h-[3.5rem]" ]
        (case model.activeAction |> Maybe.andThen (\i -> legal |> List.drop i |> List.head) of
            Nothing ->
                waitingHint
                    ++ List.indexedMap
                        (\index schema ->
                            button
                                [ class "px-3 py-2 rounded bg-blue-600 hover:bg-blue-500 text-sm"
                                , onClick (ChooseAction index schema)
                                ]
                                [ text schema.label ]
                        )
                        legal

            Just schema ->
                [ span [ class "text-gray-300" ] [ text schema.label ]
                , div [ class "flex flex-wrap gap-1" ] (List.concatMap (viewParam model) schema.params)
                , button [ class "px-3 py-2 rounded bg-green-600 hover:bg-green-500", onClick (Submit schema) ] [ text "Confirm" ]
                , button [ class "px-3 py-2 rounded bg-gray-600 hover:bg-gray-500", onClick Cancel ] [ text "Cancel" ]
                ]
        )


viewParam : Model -> Protocol.Param -> List (Html Msg)
viewParam model param =
    case param.kind of
        Select sel ->
            [ span [ class "text-xs text-gray-400 self-center" ]
                [ text
                    ("pick "
                        ++ String.fromInt sel.min
                        ++ (if sel.max /= sel.min then
                                "–" ++ String.fromInt sel.max

                            else
                                ""
                           )
                        ++ " from "
                        ++ sel.zone
                        ++ " ("
                        ++ String.fromInt (Set.size model.selected)
                        ++ " chosen)"
                    )
                ]
            ]

        Choice options ->
            if List.length options > 1 then
                List.map
                    (\( id, label ) ->
                        button
                            [ classList
                                [ ( "px-2 py-1 rounded text-xs border", True )
                                , ( "bg-yellow-500 text-gray-900 border-yellow-400", Dict.get param.name model.choices == Just id )
                                , ( "bg-white/10 border-white/20", Dict.get param.name model.choices /= Just id )
                                ]
                            , onClick (ChooseOption param.name id)
                            ]
                            [ text label ]
                    )
                    options

            else
                []

        Number min max ->
            [ span [ class "text-xs text-gray-400" ] [ text (param.name ++ ": " ++ String.fromInt min ++ ".." ++ String.fromInt max) ] ]
