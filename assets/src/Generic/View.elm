module Generic.View exposing (Ctx, Model, Msg(..), init, update, view)

{-| A plain renderer for any game on the protocol: zones of tokens, player
bars, clocks, and the legal actions as buttons. Games get this for free
before they have a bespoke UI.

The page follows the layout the bespoke boards established: the whole play
experience fits one phone screen with no scrolling — the opponent's
identity bar hugs the top of the board, the viewer's the bottom, the legal
actions live in a band right under the board, clocks are chips in the bars
on phones and a rail beside the board on desktop.

Conventions it understands (all optional props on tokens):

  - `color`: "white" | "black" | any CSS color, drawn as a disc
  - `value`: a number shown on the token (dice)
  - `used`: dims the token

Player conventions: a `to_move` flag marks whose turn it is; `color` in a
player's data draws a swatch; every counter the scene sends is shown in
that player's bar. A scene may declare `grid_style: "intersections"` or
`grid_style: "checker"` (see the grid zone docs below).

Zones whose ids share a prefix before ":" and number more than six (for
example `point:1`..`point:24`) are drawn as one horizontal strip.

-}

import Dict exposing (Dict)
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, Layout(..), ParamKind(..), PlayerInfo, Scene, Schema, Token, Zone)
import Set exposing (Set)
import View.Clock


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


type alias Ctx =
    { playerId : String
    , scene : Scene
    , legal : List Schema
    , model : Model
    , clock : Maybe Clock
    , receivedAt : Int
    , now : Int
    , nameOf : String -> String
    , finished : Maybe (List String)
    , away : List String -- seated players whose connection is down
    }


{-| The seat this viewer watches from: their own, or the first player's for
a spectator. Seating (bottom of the board) follows it.
-}
seatOf : Ctx -> Maybe PlayerInfo
seatOf ctx =
    case Protocol.findPlayer ctx.playerId ctx.scene of
        Just p ->
            Just p

        Nothing ->
            List.head ctx.scene.players


view : Ctx -> Html Msg
view ctx =
    let
        me =
            seatOf ctx

        them =
            Protocol.opponentOf (me |> Maybe.map .id |> Maybe.withDefault ctx.playerId) ctx.scene
    in
    div [ class "paper h-screen-safe overflow-hidden flex flex-col items-center px-2 py-2 sm:px-6 sm:py-4 gap-2 text-sm", style "color" "var(--ink)" ]
        [ viewHeader ctx
        , div [ class "flex-1 min-h-0 w-full max-w-5xl grid gap-2 sm:gap-4 content-center lg:grid-cols-[minmax(0,1fr)_15rem]" ]
            [ div [ class "min-w-0 min-h-0 flex flex-col justify-center gap-2" ]
                [ viewPlayerBar ctx them False
                , div [ class "min-h-0 overflow-auto flex flex-col items-center gap-2" ]
                    (List.map (viewGroup ctx.scene ctx.model ctx.legal) (groupZones ctx.scene.zones))
                , viewActions ctx.scene ctx.playerId ctx.model ctx.legal
                , viewPlayerBar ctx me True
                ]
            , viewRail ctx
            ]
        ]


viewHeader : Ctx -> Html Msg
viewHeader ctx =
    div [ class "w-full max-w-5xl flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            [ span [ class "pixel text-[9px] sm:text-xs uppercase whitespace-nowrap" ] [ text ctx.scene.game ]
            , span
                [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 whitespace-nowrap"
                , style "border" "2px solid var(--ink)"
                , style "background" "#fff"
                ]
                [ text (String.toUpper ctx.scene.phase) ]
            , case ctx.finished of
                Just winners ->
                    span
                        [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 whitespace-nowrap"
                        , style "border" "2px solid var(--bg-sky)"
                        , style "color" "var(--bg-sky)"
                        ]
                        [ text
                            (case winners of
                                [] ->
                                    "DRAW"

                                _ ->
                                    String.toUpper (String.join ", " (List.map ctx.nameOf winners)) ++ " WINS"
                            )
                        ]

                Nothing ->
                    text ""
            ]
        , case ( ctx.finished, indexedSchema "resign" ctx.legal ) of
            ( Nothing, Just ( index, schema ) ) ->
                button
                    [ class "pixel text-[8px] underline"
                    , style "color" "var(--pencil)"
                    , onClick (ChooseAction index schema)
                    ]
                    [ text (String.toUpper schema.label) ]

            _ ->
                text ""
        ]


indexedSchema : String -> List Schema -> Maybe ( Int, Schema )
indexedSchema name legal =
    legal
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, s ) -> s.name == name)
        |> List.head



-- PLAYER BARS
--
-- One identity bar per player, anchored at that player's side of the board:
-- optional color swatch, name, YOU, whatever counters the scene sends, and
-- (on phones) that player's clock. The player to move gets the sky
-- treatment.


viewPlayerBar : Ctx -> Maybe PlayerInfo -> Bool -> Html Msg
viewPlayerBar ctx player isMe =
    case player of
        Just p ->
            let
                active =
                    Protocol.hasFlag "to_move" p && ctx.finished == Nothing
            in
            div
                [ classList
                    [ ( "player-bar w-full flex items-center gap-2 px-2 py-1.5 sm:px-3 sm:py-2", True )
                    , ( "active", active )
                    ]
                ]
                [ case Protocol.playerData D.string "color" p of
                    Just color ->
                        div
                            (classList [ ( "swatch shrink-0", True ), ( "white", color == "white" ), ( "black", color == "black" ) ]
                                :: title (p.name ++ " plays " ++ color)
                                :: (if color == "white" || color == "black" then
                                        []

                                    else
                                        [ style "background" color ]
                                   )
                            )
                            []

                    Nothing ->
                        text ""
                , span [ class "font-bold text-sm sm:text-base truncate" ] [ text p.name ]
                , if isMe && p.id == ctx.playerId then
                    span [ class "pixel text-[7px] px-1 py-0.5 shrink-0", style "background" "var(--bg-sky)", style "color" "#fff" ] [ text "YOU" ]

                  else
                    text ""
                , if List.member p.id ctx.away then
                    span [ class "pixel text-[7px] shrink-0", style "color" "var(--red)", title "Connection lost" ] [ text "AWAY" ]

                  else
                    text ""
                , span
                    [ classList [ ( "pixel text-[8px] shrink-0", True ), ( "blink", active ), ( "invisible", not active ) ]
                    , style "color" "var(--bg-sky)"
                    ]
                    [ text "▶" ]
                , div [ class "flex-1" ] []
                , span [ class "pixel text-[7px] sm:text-[8px] whitespace-nowrap", style "color" "var(--pencil)" ]
                    [ text
                        (p.counters
                            |> Dict.toList
                            |> List.map (\( k, v ) -> String.toUpper k ++ " " ++ String.fromInt v)
                            |> String.join " · "
                        )
                    ]
                , viewClockChip ctx p.id
                ]

        Nothing ->
            text ""


{-| This player's clock, inline in their bar (phones and tablets). On
desktop the shared clock stack lives in the rail instead.
-}
viewClockChip : Ctx -> String -> Html Msg
viewClockChip ctx playerId =
    case ctx.clock of
        Just c ->
            if c.enabled then
                case List.filter (\p -> p.id == playerId) c.players |> List.head of
                    Just player ->
                        let
                            remaining =
                                Protocol.remainingNow player ctx.receivedAt ctx.now

                            expired =
                                c.timedOut == Just player.id || remaining <= 0
                        in
                        span
                            [ classList
                                [ ( "clock-chip font-mono text-xs sm:text-sm lg:hidden", True )
                                , ( "running", player.running && not expired )
                                , ( "expired", expired )
                                ]
                            ]
                            [ span [ class "tabular-nums font-bold" ]
                                [ text
                                    (if expired then
                                        "0:00"

                                     else
                                        Protocol.formatClock remaining
                                    )
                                ]
                            ]

                    Nothing ->
                        text ""

            else
                text ""

        Nothing ->
            text ""



-- DESKTOP RAIL


viewRail : Ctx -> Html Msg
viewRail ctx =
    let
        enabled =
            ctx.clock |> Maybe.map .enabled |> Maybe.withDefault False
    in
    div [ class "hidden lg:flex flex-col gap-3 justify-center" ]
        [ if enabled then
            div [ class "game-panel p-3 flex flex-col gap-2 items-end" ]
                [ span [ class "pixel text-[8px] self-start", style "color" "var(--pencil)" ] [ text "CLOCK" ]
                , View.Clock.view
                    { clock = ctx.clock
                    , playerId = seatOf ctx |> Maybe.map .id |> Maybe.withDefault ctx.playerId
                    , receivedAt = ctx.receivedAt
                    , now = ctx.now
                    , nameOf = ctx.nameOf
                    }
                ]

          else
            text ""
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
        Grid columns rows ->
            viewGridZone scene model legal zone columns rows

        _ ->
            viewFlowZone scene model legal zone


{-| A board: tokens laid out by their grid position. Any token can be a
button (a stone, an empty intersection offered as a move candidate).

A scene may declare `grid_style: "intersections"` in its data (go, and any
other game played on the line crossings): each cell then draws its share of
the board lines on a wood ground, star points come from `star_points`
(`[[col,row],...]`), prop-less tokens become bare tap targets on the
crossings, and stones sit on top.

`grid_style: "checker"` (chess, and any game on alternating squares) paints
the light/dark pattern on the board itself -- the two colors may be hinted
with `checker_colors: [light, dark]` -- so a scene only sends tokens for
occupied squares. Without a declaration a grid renders as plain cells.
-}
viewGridZone : Scene -> Model -> List Schema -> Zone -> Int -> Int -> Html Msg
viewGridZone scene model legal zone columns rows =
    let
        selectable =
            selectableIn model legal zone.id

        gridStyle =
            D.decodeValue (D.field "grid_style" D.string) scene.data |> Result.withDefault ""

        intersections =
            gridStyle == "intersections"

        checker =
            gridStyle == "checker"

        ( checkerLight, checkerDark ) =
            case D.decodeValue (D.field "checker_colors" (D.list D.string)) scene.data of
                Ok (light :: dark :: _) ->
                    ( light, dark )

                _ ->
                    ( "#dce8f2", "#8fb4d2" )

        stars =
            if intersections then
                D.decodeValue
                    (D.field "star_points" (D.list (D.map2 Tuple.pair (D.index 0 D.int) (D.index 1 D.int))))
                    scene.data
                    |> Result.withDefault []

            else
                []

        cell token =
            let
                placement =
                    case token.position of
                        Just ( column, row ) ->
                            [ style "grid-column" (String.fromInt (column + 1))
                            , style "grid-row" (String.fromInt (row + 1))
                            ]

                        Nothing ->
                            []

                lines =
                    case ( intersections, token.position ) of
                        ( True, Just position ) ->
                            crossing columns rows stars position

                        _ ->
                            []
            in
            div
                (class "relative flex items-center justify-center" :: placement)
                -- The token layer is positioned so stones paint over the
                -- lines and star points beneath them.
                (lines
                    ++ [ div [ class "relative z-10 w-full h-full flex items-center justify-center" ]
                            [ gridToken model selectable intersections token ]
                       ]
                )
    in
    div [ class "game-panel p-3 overflow-x-auto" ]
        [ div [ class "pixel text-[8px] mb-2", style "color" "var(--pencil)" ]
            [ text (String.toUpper zone.id) ]
        , div
            ([ style "display" "grid"
             , style "grid-template-columns" ("repeat(" ++ String.fromInt columns ++ ", 1.65rem)")
             , style "grid-auto-rows" "1.65rem"
             , style "width" "max-content"
             ]
                ++ (if intersections then
                        [ style "gap" "0"
                        , style "background" "#dcb35c"
                        , style "padding" "0.4rem"
                        , style "border" "2px solid var(--ink)"
                        ]

                    else if checker then
                        -- The light/dark square pattern is painted on the
                        -- container, so empty squares need no tokens. The
                        -- top-left square is light, as on a chessboard.
                        [ style "gap" "0"
                        , style "border" "2px solid var(--ink)"
                        , style "background-image"
                            ("repeating-conic-gradient(" ++ checkerLight ++ " 0% 25%, " ++ checkerDark ++ " 25% 50%)")
                        , style "background-size" "3.3rem 3.3rem"
                        ]

                    else
                        [ style "gap" "1px" ]
                   )
            )
            (List.map cell zone.tokens)
        ]


{-| The board lines a cell contributes: half segments at the edges so the
boundary is clean, plus a star-point dot where declared.
-}
crossing : Int -> Int -> List ( Int, Int ) -> ( Int, Int ) -> List (Html Msg)
crossing columns rows stars ( column, row ) =
    let
        line attrs =
            div (class "absolute pointer-events-none" :: style "background" "var(--ink)" :: attrs) []

        half at edge =
            if at == 0 then
                ( "50%", "0" )

            else if at == edge - 1 then
                ( "0", "50%" )

            else
                ( "0", "0" )

        ( left, right ) =
            half column columns

        ( top, bottom ) =
            half row rows

        star =
            if List.member ( column, row ) stars then
                [ line
                    [ class "rounded-full"
                    , style "width" "5px"
                    , style "height" "5px"
                    , style "left" "calc(50% - 2.5px)"
                    , style "top" "calc(50% - 2.5px)"
                    ]
                ]

            else
                []
    in
    [ line
        [ style "height" "1px"
        , style "top" "calc(50% - 0.5px)"
        , style "left" left
        , style "right" right
        ]
    , line
        [ style "width" "1px"
        , style "left" "calc(50% - 0.5px)"
        , style "top" top
        , style "bottom" bottom
        ]
    ]
        ++ star


{-| A token in a grid cell. On an intersections board a prop-less token is
the empty crossing itself: an invisible tap target that lights up when it
is a candidate and rings when picked, leaving the lines visible.
-}
gridToken : Model -> Set String -> Bool -> Token -> Html Msg
gridToken model selectable intersections token =
    let
        bare =
            case D.decodeValue (D.keyValuePairs D.value) token.props of
                Ok [] ->
                    True

                _ ->
                    False
    in
    if intersections && bare then
        let
            canSelect =
                Set.member token.id selectable

            selected =
                Set.member token.id model.selected
        in
        button
            [ classList
                [ ( "w-5 h-5 rounded-full z-10", True )
                , ( "ring-2 ring-yellow-400", selected )
                , ( "cursor-pointer", canSelect )
                ]
            , style "background"
                (if selected then
                    "rgba(250, 204, 21, 0.9)"

                 else if canSelect then
                    "rgba(250, 204, 21, 0.45)"

                 else
                    "transparent"
                )
            , title token.id
            , disabled (not canSelect)
            , onClick (ToggleToken token.id)
            ]
            []

    else
        viewToken model selectable True token


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
    div [ class "w-full flex flex-wrap gap-2 items-center justify-center min-h-[3rem] py-1" ]
        (case model.activeAction |> Maybe.andThen (\i -> legal |> List.drop i |> List.head) of
            Nothing ->
                waitingHint
                    ++ (legal
                            |> List.indexedMap Tuple.pair
                            -- Resign lives in the header, out of tap-reach.
                            |> List.filter (\( _, schema ) -> schema.name /= "resign")
                            |> List.map
                                (\( index, schema ) ->
                                    button
                                        [ class "btn-arcade sky pixel text-[9px] px-3 py-3 sm:px-4 whitespace-nowrap"
                                        , onClick (ChooseAction index schema)
                                        ]
                                        [ text (String.toUpper schema.label) ]
                                )
                       )

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
