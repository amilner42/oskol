module Games.Backgammon.View exposing (Model, Msg(..), Out(..), init, update, view)

{-| A backgammon board on the protocol Scene, in the notebook multicade style.

Moving is two clicks: a checker's point (or the bar), then a destination
(a point or the bear-off tray). Legal sources and destinations come from
the `move` schemas the server sends, so the board never needs the rules.

-}

import Dict
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (ParamKind(..), PlayerInfo, Scene, Schema, Token)


type alias Model =
    { selectedFrom : Maybe String }


type Msg
    = SelectFrom String
    | MoveTo String
    | Clear
    | Simple String
    | Rematch


type Out
    = NoOut
    | Send E.Value
    | WantRematch


init : Model
init =
    { selectedFrom = Nothing }


update : Msg -> Model -> ( Model, Out )
update msg model =
    case msg of
        SelectFrom loc ->
            if model.selectedFrom == Just loc then
                ( init, NoOut )

            else
                ( { model | selectedFrom = Just loc }, NoOut )

        Clear ->
            ( init, NoOut )

        MoveTo loc ->
            case model.selectedFrom of
                Just from ->
                    ( init
                    , Send
                        (Protocol.encodeAction "move"
                            [ ( "from", E.string from ), ( "to", E.string loc ) ]
                        )
                    )

                Nothing ->
                    ( model, NoOut )

        Simple name ->
            ( init, Send (Protocol.encodeAction name []) )

        Rematch ->
            ( model, WantRematch )



-- LEGAL MOVES


type alias Move =
    { from : String, to : String }


moves : List Schema -> List Move
moves legal =
    legal
        |> List.filter (\s -> s.name == "move")
        |> List.filterMap
            (\s ->
                case ( choice "from" s, choice "to" s ) of
                    ( Just from, Just to ) ->
                        Just { from = from, to = to }

                    _ ->
                        Nothing
            )


choice : String -> Schema -> Maybe String
choice name schema =
    schema.params
        |> List.filter (\p -> p.name == name)
        |> List.head
        |> Maybe.andThen
            (\p ->
                case p.kind of
                    Choice ((id, _) :: _) ->
                        Just id

                    _ ->
                        Nothing
            )


hasAction : String -> List Schema -> Bool
hasAction name legal =
    List.any (\s -> s.name == name) legal


labelOf : String -> List Schema -> String
labelOf name legal =
    legal |> List.filter (\s -> s.name == name) |> List.head |> Maybe.map .label |> Maybe.withDefault name



-- VIEW


type alias Ctx =
    { playerId : String
    , scene : Scene
    , legal : List Schema
    , model : Model
    , clock : Html Msg
    , nameOf : String -> String
    , rematchReady : List String
    , finished : Maybe (List String)
    }


view : Ctx -> Html Msg
view ctx =
    let
        me =
            Protocol.findPlayer ctx.playerId ctx.scene

        them =
            Protocol.opponentOf ctx.playerId ctx.scene

        myColor =
            me |> Maybe.andThen (Protocol.playerData D.string "color") |> Maybe.withDefault "white"

        legalMoves =
            moves ctx.legal

        sources =
            legalMoves |> List.map .from |> unique

        targets =
            case ctx.model.selectedFrom of
                Just from ->
                    legalMoves |> List.filter (\m -> m.from == from) |> List.map .to

                Nothing ->
                    []

        board =
            { ctx = ctx, myColor = myColor, sources = sources, targets = targets }
    in
    div [ class "paper min-h-screen-safe flex flex-col items-center px-3 py-3 sm:px-6 sm:py-5 gap-3 sm:gap-4" ]
        [ viewHeader ctx me them
        , div [ class "w-full max-w-5xl grid gap-3 sm:gap-4 lg:grid-cols-[1fr_16rem]" ]
            [ viewBoard board
            , viewSide ctx me them legalMoves
            ]
        , case ctx.finished of
            Just winners ->
                viewGameOver ctx winners

            Nothing ->
                text ""
        ]


unique : List comparable -> List comparable
unique =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                acc ++ [ x ]
        )
        []



-- HEADER


viewHeader : Ctx -> Maybe PlayerInfo -> Maybe PlayerInfo -> Html Msg
viewHeader ctx me them =
    let
        target =
            Protocol.sceneData D.int "target" ctx.scene |> Maybe.withDefault 0

        gameNumber =
            Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1

        crawford =
            Protocol.sceneData (D.field "crawford" D.bool) "cube" ctx.scene |> Maybe.withDefault False

        matchLabel =
            if target <= 0 then
                "UNLIMITED"

            else if target == 1 then
                "SINGLE GAME"

            else
                "MATCH TO " ++ String.fromInt target
    in
    div [ class "w-full max-w-5xl flex items-center justify-between gap-3" ]
        [ div [ class "flex items-center gap-3" ]
            [ span [ class "pixel text-[10px] sm:text-xs" ] [ text "BACKGAMMON" ]
            , span [ class "pixel text-[8px] sm:text-[9px] px-2 py-1", style "background" "var(--highlighter)", style "border" "2px solid var(--ink)" ]
                [ text matchLabel ]
            , span [ class "pixel text-[8px] sm:text-[9px]", style "color" "var(--pencil)" ]
                [ text ("GAME " ++ String.fromInt gameNumber) ]
            , if crawford then
                span [ class "pixel text-[8px] px-2 py-1", style "border" "2px solid var(--red)", style "color" "var(--red)" ] [ text "CRAWFORD" ]

              else
                text ""
            ]
        , div [ class "flex items-center gap-3" ]
            [ viewScorePill "1P" me "var(--pen)"
            , viewScorePill "2P" them "var(--red)"
            ]
        ]


viewScorePill : String -> Maybe PlayerInfo -> String -> Html Msg
viewScorePill tag player color =
    case player of
        Just p ->
            div [ class "flex items-center gap-2 pix-sm px-2 py-1" ]
                [ span [ class "pixel text-[8px]", style "color" color ] [ text tag ]
                , span [ class "font-bold text-sm truncate max-w-[6rem]" ] [ text p.name ]
                , span [ class "pixel text-[10px]" ] [ text (String.fromInt (Protocol.counter "score" p)) ]
                ]

        Nothing ->
            text ""



-- BOARD


type alias Board =
    { ctx : Ctx
    , myColor : String
    , sources : List String
    , targets : List String
    }


{-| Point numbers by visual position, so the viewer's home board is bottom right.
-}
rows : String -> ( List Int, List Int )
rows myColor =
    if myColor == "black" then
        ( List.range 1 12 |> List.reverse, List.range 13 24 )

    else
        ( List.range 13 24, List.range 1 12 |> List.reverse )


viewBoard : Board -> Html Msg
viewBoard board =
    let
        ( top, bottom ) =
            rows board.myColor

        half list_ =
            ( List.take 6 list_, List.drop 6 list_ )

        ( topLeft, topRight ) =
            half top

        ( bottomLeft, bottomRight ) =
            half bottom

        me =
            board.ctx.playerId

        themId =
            Protocol.opponentOf me board.ctx.scene |> Maybe.map .id |> Maybe.withDefault ""
    in
    div [ class "bg-board p-2 sm:p-3 select-none" ]
        [ div [ class "grid grid-cols-[6fr_auto_6fr_auto] gap-1 sm:gap-2" ]
            [ div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topLeft)
            , viewBar board themId True
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topRight)
            , viewTray board themId
            , div [ class "col-span-4 flex items-center justify-center gap-4 py-2 sm:py-3" ] (viewMiddle board)
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomLeft)
            , viewBar board me False
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomRight)
            , viewTray board me
            ]
        ]


pointColor : Int -> String
pointColor index =
    if modBy 2 index == 0 then
        "#f1dcb3"

    else
        "#f6b8b2"


viewPoint : Board -> Bool -> Int -> Int -> Html Msg
viewPoint board isTop index point =
    let
        id =
            String.fromInt point

        tokens =
            Protocol.zoneTokens ("point:" ++ id) board.ctx.scene

        isSource =
            List.member id board.sources

        isTarget =
            List.member id board.targets

        isSelected =
            board.ctx.model.selectedFrom == Just id

        click =
            if isTarget then
                [ onClick (MoveTo id) ]

            else if isSource then
                [ onClick (SelectFrom id) ]

            else
                []
    in
    div
        ([ classList
            [ ( "bg-point h-28 sm:h-40 flex flex-col items-center gap-px px-px", True )
            , ( "top", isTop )
            , ( "bottom flex-col-reverse", not isTop )
            , ( "source cursor-pointer", isSource )
            , ( "target cursor-pointer", isTarget )
            , ( "selected", isSelected )
            ]
         , attribute "style" ("--point: " ++ pointColor (index + (if isTop then 0 else 1)))
         , title ("Point " ++ id)
         ]
            ++ click
        )
        (viewStack tokens ++ [ span [ class "pixel text-[7px] relative", style "color" "var(--pencil)" ] [ text id ] ])


viewStack : List Token -> List (Html Msg)
viewStack tokens =
    let
        shown =
            List.take 5 tokens

        extra =
            List.length tokens - 5
    in
    List.map viewChecker shown
        ++ (if extra > 0 then
                [ span [ class "pixel text-[8px] relative" ] [ text ("+" ++ String.fromInt extra) ] ]

            else
                []
           )


viewChecker : Token -> Html Msg
viewChecker token =
    let
        color =
            Protocol.tokenProp D.string "color" token |> Maybe.withDefault "white"
    in
    div [ classList [ ( "checker relative shrink-0", True ), ( "white", color == "white" ), ( "black", color /= "white" ) ], title token.id ] []


viewBar : Board -> String -> Bool -> Html Msg
viewBar board ownerId isTop =
    let
        tokens =
            Protocol.zoneTokens ("bar:" ++ ownerId) board.ctx.scene

        mine =
            ownerId == board.ctx.playerId

        isSource =
            mine && List.member "bar" board.sources

        isSelected =
            mine && board.ctx.model.selectedFrom == Just "bar"
    in
    div
        ([ classList
            [ ( "w-8 sm:w-12 flex flex-col items-center gap-px py-1", True )
            , ( "flex-col-reverse", not isTop )
            , ( "cursor-pointer", isSource )
            ]
         , style "background" "var(--paper-2)"
         , style "border-left" "3px solid var(--ink)"
         , style "border-right" "3px solid var(--ink)"
         , style "outline" (if isSelected then "3px solid var(--pen)" else if isSource then "3px dashed var(--pen)" else "none")
         , title "Bar"
         ]
            ++ (if isSource then
                    [ onClick (SelectFrom "bar") ]

                else
                    []
               )
        )
        (viewStack tokens)


viewTray : Board -> String -> Html Msg
viewTray board ownerId =
    let
        count =
            Protocol.findZone ("off:" ++ ownerId) board.ctx.scene |> Maybe.map .count |> Maybe.withDefault 0

        mine =
            ownerId == board.ctx.playerId

        isTarget =
            mine && List.member "off" board.targets
    in
    div
        ([ classList
            [ ( "w-10 sm:w-14 flex flex-col items-center justify-center gap-1 px-1", True )
            , ( "cursor-pointer", isTarget )
            ]
         , style "border" (if isTarget then "3px dashed var(--marker-green)" else "3px solid var(--ink)")
         , style "background" (if isTarget then "#eaf7ec" else "var(--paper-2)")
         , title "Borne off"
         ]
            ++ (if isTarget then
                    [ onClick (MoveTo "off") ]

                else
                    []
               )
        )
        [ span [ class "pixel text-[7px]", style "color" "var(--pencil)" ] [ text "OFF" ]
        , span [ class "pixel text-xs" ] [ text (String.fromInt count) ]
        ]


viewMiddle : Board -> List (Html Msg)
viewMiddle board =
    let
        dice =
            Protocol.zoneTokens "dice" board.ctx.scene

        cube =
            Protocol.zoneTokens "cube" board.ctx.scene |> List.head
    in
    List.map viewDie dice
        ++ (case cube of
                Just token ->
                    [ viewCube board token ]

                Nothing ->
                    []
           )


viewDie : Token -> Html Msg
viewDie token =
    let
        value =
            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1

        used =
            Protocol.tokenProp D.bool "used" token |> Maybe.withDefault False
    in
    div [ classList [ ( "die", True ), ( "used", used ) ] ]
        [ div [ class "grid grid-cols-3 grid-rows-3 w-6 h-6" ] (pips value) ]


pips : Int -> List (Html Msg)
pips value =
    let
        on =
            case value of
                1 ->
                    [ 4 ]

                2 ->
                    [ 2, 6 ]

                3 ->
                    [ 2, 4, 6 ]

                4 ->
                    [ 0, 2, 6, 8 ]

                5 ->
                    [ 0, 2, 4, 6, 8 ]

                _ ->
                    [ 0, 2, 3, 5, 6, 8 ]
    in
    List.range 0 8
        |> List.map
            (\i ->
                div [ class "flex items-center justify-center" ]
                    [ div
                        [ classList [ ( "w-1.5 h-1.5 rounded-full", True ), ( "invisible", not (List.member i on)) ]
                        , style "background" "var(--ink)"
                        ]
                        []
                    ]
            )


viewCube : Board -> Token -> Html Msg
viewCube board token =
    let
        value =
            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1

        owner =
            Protocol.tokenProp (D.nullable D.string) "owner" token |> Maybe.withDefault Nothing

        ownerLabel =
            case owner of
                Just id ->
                    if id == board.ctx.playerId then
                        "1P"

                    else
                        "2P"

                Nothing ->
                    "CENTRE"
    in
    div [ class "flex flex-col items-center gap-1 ml-4", title ("Cube, " ++ ownerLabel) ]
        [ div [ class "cube pixel text-[10px]" ]
            [ text
                (if value == 1 then
                    "64"

                 else
                    String.fromInt value
                )
            ]
        , span [ class "pixel text-[7px]", style "color" "var(--pencil)" ] [ text ownerLabel ]
        ]



-- SIDE PANEL


viewSide : Ctx -> Maybe PlayerInfo -> Maybe PlayerInfo -> List Move -> Html Msg
viewSide ctx me them legalMoves =
    let
        toMove =
            Protocol.sceneData (D.nullable D.string) "to_move" ctx.scene |> Maybe.withDefault Nothing

        toAct =
            Protocol.sceneData (D.nullable D.string) "to_act" ctx.scene |> Maybe.withDefault Nothing

        pendingFrom =
            Protocol.sceneData (D.field "pending_from" (D.nullable D.string)) "cube" ctx.scene |> Maybe.withDefault Nothing

        dice =
            Protocol.sceneData (D.list D.int) "dice" ctx.scene |> Maybe.withDefault []

        myTurn =
            toAct == Just ctx.playerId

        status =
            if ctx.finished /= Nothing then
                "MATCH OVER"

            else if pendingFrom /= Nothing && myTurn then
                "DOUBLE OFFERED. TAKE OR DROP?"

            else if pendingFrom /= Nothing then
                "WAITING FOR THE TAKE…"

            else if myTurn && hasAction "roll" ctx.legal then
                "YOUR TURN. ROLL!"

            else if myTurn && legalMoves /= [] then
                case ctx.model.selectedFrom of
                    Just from ->
                        "MOVE FROM " ++ String.toUpper from ++ " TO…"

                    Nothing ->
                        "PLAY " ++ String.join " · " (List.map String.fromInt dice)

            else
                "WAITING FOR " ++ String.toUpper (toMove |> Maybe.map ctx.nameOf |> Maybe.withDefault "OPPONENT")
    in
    div [ class "flex flex-col gap-3" ]
        [ div [ class "game-panel p-3 flex flex-col gap-3" ]
            [ viewPlayerRow "1P" me toMove "var(--pen)"
            , viewPlayerRow "2P" them toMove "var(--red)"
            , ctx.clock
            ]
        , div [ class "game-panel p-3 flex flex-col gap-2" ]
            [ span [ class "pixel text-[9px] leading-relaxed", style "color" (if myTurn then "var(--pen)" else "var(--pencil)") ]
                [ span [ classList [ ( "mr-1", True ), ( "blink", myTurn && ctx.finished == Nothing ), ( "invisible", not myTurn ) ] ] [ text "▶" ]
                , text status
                ]
            , div [ class "flex flex-wrap gap-2" ]
                (List.filterMap identity
                    [ actionButton ctx "roll" "pen"
                    , actionButton ctx "double" "yellow"
                    , actionButton ctx "take" "green"
                    , actionButton ctx "drop" ""
                    ]
                )
            , if ctx.model.selectedFrom /= Nothing then
                button [ class "pixel text-[8px] underline self-start", style "color" "var(--pencil)", onClick Clear ] [ text "CANCEL SELECTION" ]

              else
                text ""
            , if hasAction "resign" ctx.legal && ctx.finished == Nothing then
                button [ class "pixel text-[8px] self-end", style "color" "var(--pencil)", onClick (Simple "resign") ] [ text "RESIGN" ]

              else
                text ""
            ]
        ]


actionButton : Ctx -> String -> String -> Maybe (Html Msg)
actionButton ctx name color =
    if hasAction name ctx.legal then
        Just
            (button
                [ class ("btn-arcade pixel text-[9px] px-4 py-3 " ++ color)
                , onClick (Simple name)
                ]
                [ text (String.toUpper (labelOf name ctx.legal)) ]
            )

    else
        Nothing


viewPlayerRow : String -> Maybe PlayerInfo -> Maybe String -> String -> Html Msg
viewPlayerRow tag player toMove color =
    case player of
        Just p ->
            div [ classList [ ( "flex items-center justify-between gap-2 px-2 py-1.5", True ), ( "bg-[color:var(--paper-2)]", toMove == Just p.id ) ] ]
                [ div [ class "flex items-center gap-2 min-w-0" ]
                    [ span [ class "pixel text-[8px]", style "color" color ] [ text tag ]
                    , span [ class "font-bold truncate" ] [ text p.name ]
                    , if Protocol.hasFlag "owns_cube" p then
                        span [ class "pixel text-[7px] px-1", style "background" "var(--highlighter)" ] [ text "CUBE" ]

                      else
                        text ""
                    ]
                , div [ class "flex items-center gap-3 pixel text-[8px]", style "color" "var(--pencil)" ]
                    [ span [ title "pips" ] [ text (String.fromInt (Protocol.counter "pips" p) ++ " PIPS") ]
                    , span [ title "borne off" ] [ text (String.fromInt (Protocol.counter "off" p) ++ " OFF") ]
                    ]
                ]

        Nothing ->
            text ""



-- GAME OVER


viewGameOver : Ctx -> List String -> Html Msg
viewGameOver ctx winners =
    let
        iWon =
            List.member ctx.playerId winners

        winnerName =
            winners |> List.head |> Maybe.map ctx.nameOf |> Maybe.withDefault "Nobody"

        meReady =
            List.member ctx.playerId ctx.rematchReady

        theyReady =
            ctx.rematchReady |> List.any (\id -> id /= ctx.playerId)
    in
    div [ class "fixed inset-0 z-50 flex items-center justify-center p-4", style "background" "rgba(35, 36, 58, 0.55)" ]
        [ div [ class "pix bg-white p-6 sm:p-8 max-w-md w-full text-center flex flex-col gap-4" ]
            [ span [ class "pixel text-[10px]", style "color" "var(--red)" ] [ text "GAME OVER" ]
            , span [ class "pixel text-base sm:text-lg leading-relaxed" ]
                [ text
                    (if iWon then
                        "YOU WIN!"

                     else
                        String.toUpper winnerName ++ " WINS"
                    )
                ]
            , span [ class "text-sm", style "color" "var(--pencil)" ]
                [ text
                    (case ( meReady, theyReady ) of
                        ( True, True ) ->
                            "Starting the rematch…"

                        ( True, False ) ->
                            "Waiting for your opponent to accept…"

                        ( False, True ) ->
                            "Your opponent wants a rematch!"

                        _ ->
                            "Play again?"
                    )
                ]
            , button
                [ class "btn-arcade pixel text-[10px] px-6 py-4 green"
                , disabled meReady
                , onClick Rematch
                ]
                [ text
                    (if meReady then
                        "READY"

                     else
                        "REMATCH"
                    )
                ]
            , Html.a [ Html.Attributes.href "/", class "pixel text-[8px] underline", style "color" "var(--pencil)" ] [ text "ALL GAMES" ]
            ]
        ]
