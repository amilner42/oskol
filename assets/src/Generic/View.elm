module Generic.View exposing (Model, Msg(..), init, update, view)

{-| A plain renderer for any game on the protocol: zones of tokens, player
counters, and the legal actions as buttons. Games get this for free before
they have a bespoke UI.
-}

import Dict
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (class, classList, disabled)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (ParamKind(..), Scene, Schema, Token, Zone)
import Set exposing (Set)


type alias Model =
    { selected : Set String
    , activeAction : Maybe String
    }


type Msg
    = ToggleToken String
    | ChooseAction String
    | Submit Schema
    | Cancel


init : Model
init =
    { selected = Set.empty, activeAction = Nothing }


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

        ChooseAction name ->
            ( { model | activeAction = Just name, selected = Set.empty }, Nothing )

        Cancel ->
            ( init, Nothing )

        Submit schema ->
            let
                params =
                    schema.params
                        |> List.map
                            (\param ->
                                case param.kind of
                                    Select _ ->
                                        ( param.name, E.list E.string (Set.toList model.selected) )

                                    Choice options ->
                                        ( param.name
                                        , options |> List.head |> Maybe.map (Tuple.first >> E.string) |> Maybe.withDefault E.null
                                        )

                                    Number min _ ->
                                        ( param.name, E.int min )
                            )
            in
            ( init, Just (Protocol.encodeAction schema.name params) )


view : { playerId : String, scene : Scene, legal : List Schema, model : Model, status : String } -> Html Msg
view { playerId, scene, legal, model, status } =
    div [ class "min-h-screen bg-[#1a1d29] text-gray-100 p-4 space-y-4 font-mono text-sm" ]
        [ div [ class "flex items-baseline justify-between" ]
            [ span [ class "text-xl font-bold" ] [ text scene.game ]
            , span [ class "text-gray-400" ] [ text ("phase: " ++ scene.phase ++ " · " ++ status) ]
            ]
        , div [ class "grid gap-2 sm:grid-cols-2" ] (List.map (viewPlayer playerId) scene.players)
        , div [ class "space-y-3" ] (List.map (viewZone model legal) scene.zones)
        , viewActions model legal
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
        [ div [ class "font-bold" ] [ text player.name ]
        , div [ class "text-gray-300 flex flex-wrap gap-x-3" ]
            (player.counters
                |> Dict.toList
                |> List.map (\( k, v ) -> span [] [ text (k ++ " " ++ String.fromInt v) ])
            )
        , div [ class "text-gray-500 text-xs" ] [ text (String.join ", " player.flags) ]
        ]


viewZone : Model -> List Schema -> Zone -> Html Msg
viewZone model legal zone =
    let
        selectable =
            selectableIn model legal zone.id
    in
    div [ class "rounded-lg bg-white/5 p-3" ]
        [ div [ class "text-gray-400 text-xs mb-2" ]
            [ text (zone.id ++ " (" ++ String.fromInt zone.count ++ ")") ]
        , div [ class "flex flex-wrap gap-2" ]
            (if List.isEmpty zone.tokens then
                List.repeat (min zone.count 12) (div [ class "w-10 h-14 rounded bg-white/10" ] [])

             else
                List.map (viewToken model selectable) zone.tokens
            )
        ]


selectableIn : Model -> List Schema -> String -> Set String
selectableIn model legal zoneId =
    legal
        |> List.filter (\s -> Just s.name == model.activeAction)
        |> List.concatMap .params
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


viewToken : Model -> Set String -> Token -> Html Msg
viewToken model selectable token =
    let
        label =
            if token.faceUp then
                tokenLabel token

            else
                "?"

        canSelect =
            Set.member token.id selectable
    in
    button
        [ classList
            [ ( "min-w-10 h-14 px-1 rounded border text-xs flex items-center justify-center", True )
            , ( "bg-white text-gray-900 border-white", token.faceUp )
            , ( "bg-gray-700 border-gray-600", not token.faceUp )
            , ( "ring-2 ring-yellow-400", Set.member token.id model.selected )
            , ( "opacity-50", not canSelect && model.activeAction /= Nothing )
            ]
        , disabled (not canSelect)
        , onClick (ToggleToken token.id)
        ]
        [ text label ]


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


viewActions : Model -> List Schema -> Html Msg
viewActions model legal =
    div [ class "flex flex-wrap gap-2 items-center" ]
        (case model.activeAction of
            Nothing ->
                if List.isEmpty legal then
                    [ span [ class "text-gray-500" ] [ text "Waiting for opponent..." ] ]

                else
                    List.map
                        (\s ->
                            button
                                [ class "px-3 py-2 rounded bg-blue-600 hover:bg-blue-500"
                                , onClick (ChooseAction s.name)
                                ]
                                [ text s.label ]
                        )
                        legal

            Just name ->
                case legal |> List.filter (\s -> s.name == name) |> List.head of
                    Just schema ->
                        [ span [ class "text-gray-300" ] [ text (schema.label ++ ": select, then confirm") ]
                        , button [ class "px-3 py-2 rounded bg-green-600", onClick (Submit schema) ] [ text "Confirm" ]
                        , button [ class "px-3 py-2 rounded bg-gray-600", onClick Cancel ] [ text "Cancel" ]
                        ]

                    Nothing ->
                        [ button [ class "px-3 py-2 rounded bg-gray-600", onClick Cancel ] [ text "Cancel" ] ]
        )
