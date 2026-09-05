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
import Protocol exposing (Layout(..), ParamKind(..), Scene, Schema, Token, Zone)
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
    div [ class "paper min-h-screen-safe p-3 sm:p-5 space-y-4 text-sm", style "color" "var(--ink)" ]
        [ div [ class "flex items-start justify-between gap-4" ]
            [ div []
                [ span [ class "pixel text-xs uppercase" ] [ text scene.game ]
                , span [ class "pixel text-[8px] ml-3", style "color" "var(--pencil)" ] [ text (String.toUpper (scene.phase ++ " · " ++ status)) ]
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
            [ ( "game-panel p-3", True )
            , ( "tile-mine", player.id == playerId )
            ]
        ]
        [ div [ class "font-bold flex items-center gap-2" ]
            [ text player.name
            , span [ class "pixel text-[8px]", style "color" "var(--pencil)" ]
                [ text
                    (if player.id == playerId then
                        "1P"

                     else
                        ""
                    )
                ]
            ]
        , div [ class "flex flex-wrap gap-x-3 pixel text-[8px]", style "color" "var(--pencil)" ]
            (player.counters
                |> Dict.toList
                |> List.map (\( k, v ) -> span [] [ text (k ++ " " ++ String.fromInt v) ])
            )
        , div [ class "pixel text-[8px]", style "color" "var(--pen)" ] [ text (String.toUpper (String.join ", " player.flags)) ]
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
            div [ class "game-panel p-3 overflow-x-auto" ]
                [ div [ class "pixel text-[8px] mb-2", style "color" "var(--pencil)" ] [ text (String.toUpper prefix) ]
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
        [ span [ class "pixel text-[7px]", style "color" "var(--pencil)" ] [ text label ]
        , div [ class "flex flex-col-reverse items-center gap-0.5 min-h-[7rem] w-full py-1", style "background" "var(--paper-2)" ]
            (List.map (viewToken model selectable True) zone.tokens)
        ]


viewZone : Scene -> Model -> List Schema -> Zone -> Html Msg
viewZone scene model legal zone =
    case zone.layout of
        Grid columns _ ->
            viewGridZone model legal zone columns

        _ ->
            viewFlowZone scene model legal zone


{-| A board: tokens laid out by their grid position. Any token can be a
button (a stone, an empty intersection offered as a move candidate).
-}
viewGridZone : Model -> List Schema -> Zone -> Int -> Html Msg
viewGridZone model legal zone columns =
    let
        selectable =
            selectableIn model legal zone.id

        cell token =
            div
                (class "flex items-center justify-center"
                    :: (case token.position of
                            Just ( column, row ) ->
                                [ style "grid-column" (String.fromInt (column + 1))
                                , style "grid-row" (String.fromInt (row + 1))
                                ]

                            Nothing ->
                                []
                       )
                )
                [ viewToken model selectable True token ]
    in
    div [ class "game-panel p-3 overflow-x-auto" ]
        [ div [ class "pixel text-[8px] mb-2", style "color" "var(--pencil)" ]
            [ text (String.toUpper zone.id) ]
        , div
            [ style "display" "grid"
            , style "grid-template-columns" ("repeat(" ++ String.fromInt columns ++ ", 1.65rem)")
            , style "grid-auto-rows" "1.65rem"
            , style "gap" "1px"
            , style "width" "max-content"
            ]
            (List.map cell zone.tokens)
        ]


viewFlowZone : Scene -> Model -> List Schema -> Zone -> Html Msg
viewFlowZone scene model legal zone =
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
    div [ class "game-panel p-3" ]
        [ div [ class "pixel text-[8px] mb-2", style "color" "var(--pencil)" ]
            [ text (label ++ " (" ++ String.fromInt zone.count ++ ")") ]
        , div [ class "flex flex-wrap gap-2 items-center" ]
            (if List.isEmpty zone.tokens then
                List.repeat (min zone.count 12) (div [ class "w-8 h-11", style "background" "var(--paper-2)", style "border" "2px dashed var(--pencil)" ] [])

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
                [ classList (base ++ [ ( "w-8 h-11 card-face", True ) ])
                , style "background" "var(--paper-2)"
                , disabled (not canSelect)
                , onClick (ToggleToken token.id)
                ]
                [ text "?" ]

        ( True, Just c, _ ) ->
            button
                [ classList (base ++ [ ( "checker w-6", True ), ( "white", c == "white" ), ( "black", c /= "white" ) ])
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
                [ classList (base ++ [ ( "die pixel text-[10px]", True ) ])
                , title token.id
                ]
                [ text (String.fromInt v) ]

        ( True, Nothing, Nothing ) ->
            button
                [ classList
                    (base
                        ++ [ ( "card-face px-1", True )
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
                        [ span [ class "pixel text-[8px] mr-2", style "color" "var(--pencil)" ] [ text (String.toUpper ("Waiting for " ++ p.name ++ "…")) ] ]

                Nothing ->
                    if List.isEmpty legal then
                        [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text "WAITING FOR YOUR OPPONENT…" ] ]

                    else
                        []
    in
    div [ class "game-panel p-3 flex flex-wrap gap-2 items-center min-h-[3.5rem]" ]
        (case model.activeAction |> Maybe.andThen (\i -> legal |> List.drop i |> List.head) of
            Nothing ->
                waitingHint
                    ++ List.indexedMap
                        (\index schema ->
                            button
                                [ class "btn-arcade pen pixel text-[8px] px-3 py-2"
                                , onClick (ChooseAction index schema)
                                ]
                                [ text schema.label ]
                        )
                        legal

            Just schema ->
                [ span [ class "pixel text-[8px]" ] [ text (String.toUpper schema.label) ]
                , div [ class "flex flex-wrap gap-1" ] (List.concatMap (viewParam model) schema.params)
                , button [ class "btn-arcade green pixel text-[8px] px-3 py-2", onClick (Submit schema) ] [ text "CONFIRM" ]
                , button [ class "pixel text-[8px] px-3 py-2 underline", style "color" "var(--pencil)", onClick Cancel ] [ text "CANCEL" ]
                ]
        )


viewParam : Model -> Protocol.Param -> List (Html Msg)
viewParam model param =
    case param.kind of
        Select sel ->
            [ span [ class "text-xs self-center", style "color" "var(--pencil)" ]
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
                                [ ( "tile px-2 py-1 text-xs", True )
                                , ( "tile-mine", Dict.get param.name model.choices == Just id )
                                ]
                            , onClick (ChooseOption param.name id)
                            ]
                            [ text label ]
                    )
                    options

            else
                []

        Number min max ->
            [ span [ class "text-xs", style "color" "var(--pencil)" ] [ text (param.name ++ ": " ++ String.fromInt min ++ ".." ++ String.fromInt max) ] ]
