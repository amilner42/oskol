module Games.Poker.View exposing (Ctx, Model, Msg(..), Out(..), Table, init, sizing, table, update, view, wantsAutoDeal)

{-| A heads-up hold'em table on the protocol Scene, phone first.

The opponent sits at the top, the board and pot in the middle, your cards
and the action bar at the bottom. Everything the buttons may do comes from
the legal schemas: a bet or raise carries its bounds as a number param.

-}

import Dict exposing (Dict)
import Html exposing (Html, button, div, input, span, text)
import Html.Attributes as A exposing (class, classList, disabled, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ClockPlayer, ParamKind(..), PlayerInfo, Scene, Schema, Token)


type alias Model =
    { amount : Maybe Int }


type Msg
    = Simple String
    | SetAmount String
    | SendAmount String Int
    | Rematch


type Out
    = NoOut
    | Send E.Value
    | WantRematch


init : Model
init =
    { amount = Nothing }


update : Msg -> Model -> ( Model, Out )
update msg model =
    case msg of
        Simple name ->
            ( init, Send (Protocol.encodeAction name []) )

        SetAmount raw ->
            ( { model | amount = String.toInt raw }, NoOut )

        SendAmount name total ->
            ( init, Send (Protocol.encodeAction name [ ( "amount", E.int total ) ]) )

        Rematch ->
            ( model, WantRematch )



-- READING THE SCENE


type alias Card =
    { id : String, code : String, rank : Int, suit : String }


type alias HandResult =
    { winners : List ( String, Int ), won : String, descriptions : Dict String String }


type alias Table =
    { pot : Int
    , street : Maybe String
    , phase : String
    , format : String
    , toCall : Int
    , canCheck : Bool
    , smallBlind : Int
    , bigBlind : Int
    , level : Int
    , handsUntilLevelUp : Maybe Int
    , handNumber : Int
    , button : String
    , nextButton : String
    , lastResult : Maybe HandResult
    , winnerId : Maybe String
    }


table : Scene -> Table
table scene =
    let
        int key =
            Protocol.sceneData D.int key scene |> Maybe.withDefault 0

        str key =
            Protocol.sceneData D.string key scene |> Maybe.withDefault ""
    in
    { pot = int "pot"
    , street = Protocol.sceneData D.string "street" scene
    , phase = str "phase"
    , format = str "format"
    , toCall = int "to_call"
    , canCheck = Protocol.sceneData D.bool "can_check" scene |> Maybe.withDefault False
    , smallBlind = int "small_blind"
    , bigBlind = int "big_blind"
    , level = int "level"
    , handsUntilLevelUp = Protocol.sceneData D.int "hands_until_level_up" scene
    , handNumber = int "hand_number"
    , button = str "button"
    , nextButton = str "next_button"
    , lastResult = Protocol.sceneData resultDecoder "last_result" scene
    , winnerId = Protocol.sceneData D.string "winner_id" scene
    }


resultDecoder : D.Decoder HandResult
resultDecoder =
    D.map3 HandResult
        (D.field "winners" (D.list (D.map2 Tuple.pair (D.field "player_id" D.string) (D.field "amount" D.int))))
        (D.field "won" D.string)
        (D.field "descriptions" (D.dict D.string))


cardFromToken : Token -> Maybe Card
cardFromToken token =
    Maybe.map3 (Card token.id)
        (Protocol.tokenProp D.string "code" token)
        (Protocol.tokenProp D.int "rank" token)
        (Protocol.tokenProp D.string "suit" token)


cardsIn : String -> Scene -> List Card
cardsIn zoneId scene =
    Protocol.zoneTokens zoneId scene |> List.filterMap cardFromToken


{-| Face-down cards a zone reports without showing.
-}
hiddenCount : String -> Scene -> Int
hiddenCount zoneId scene =
    case Protocol.findZone zoneId scene of
        Just zone ->
            if List.isEmpty zone.tokens then
                zone.count

            else
                0

        Nothing ->
            0


hasAction : String -> List Schema -> Bool
hasAction name legal =
    List.any (\s -> s.name == name) legal


labelOf : String -> List Schema -> String
labelOf name legal =
    legal |> List.filter (\s -> s.name == name) |> List.head |> Maybe.map .label |> Maybe.withDefault name


{-| The bet or raise on offer with its bounds, from the number param.
-}
sizing : List Schema -> Maybe { name : String, label : String, min : Int, max : Int }
sizing legal =
    legal
        |> List.filter (\s -> s.name == "bet" || s.name == "raise")
        |> List.head
        |> Maybe.andThen
            (\s ->
                case s.params of
                    [ { kind } ] ->
                        case kind of
                            Number min max ->
                                Just { name = s.name, label = s.label, min = min, max = max }

                            _ ->
                                Nothing

                    _ ->
                        Nothing
            )


{-| The client deals the next hand for the button after a short pause.
-}
wantsAutoDeal : Ctx -> Bool
wantsAutoDeal ctx =
    let
        t =
            table ctx.scene
    in
    ctx.finished == Nothing && t.phase == "hand_over" && t.nextButton == ctx.playerId && hasAction "deal" ctx.legal



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
    , rematchReady : List String
    , finished : Maybe (List String)
    }


view : Ctx -> Html Msg
view ctx =
    let
        t =
            table ctx.scene

        me =
            Protocol.findPlayer ctx.playerId ctx.scene

        them =
            ctx.scene.players |> List.filter (\p -> p.id /= ctx.playerId) |> List.head

        spectating =
            me == Nothing
    in
    div [ class "paper min-h-screen flex flex-col items-center px-3 py-3 gap-3 select-none" ]
        [ viewHeader ctx t
        , case them of
            Just p ->
                viewSeat ctx t p False

            Nothing ->
                text ""
        , viewFelt ctx t
        , case me of
            Just p ->
                viewSeat ctx t p True

            Nothing ->
                case ctx.scene.players of
                    p :: _ ->
                        viewSeat ctx t p False

                    [] ->
                        text ""
        , if spectating then
            div [ class "pixel text-[10px]", A.style "color" "var(--pencil)" ] [ text "SPECTATING" ]

          else
            viewActions ctx t
        ]


viewHeader : Ctx -> Table -> Html Msg
viewHeader ctx t =
    let
        blinds =
            String.fromInt t.smallBlind ++ "/" ++ String.fromInt t.bigBlind

        format =
            if t.format == "cash" then
                "CASH " ++ blinds

            else
                "SIT & GO · LEVEL " ++ String.fromInt t.level ++ " · " ++ blinds

        levelHint =
            case ( t.format, t.handsUntilLevelUp ) of
                ( "sng", Just n ) ->
                    " · UP IN " ++ String.fromInt n

                _ ->
                    ""
    in
    div [ class "w-full max-w-md flex items-center justify-between pixel text-[9px]", A.style "color" "var(--pencil)" ]
        [ span [] [ text ("POKER · " ++ format ++ levelHint) ]
        , span [ id_ "hand-number" ]
            [ text
                (if t.handNumber > 0 then
                    "HAND " ++ String.fromInt t.handNumber

                 else
                    ""
                )
            ]
        ]


id_ : String -> Html.Attribute msg
id_ =
    A.id


viewSeat : Ctx -> Table -> PlayerInfo -> Bool -> Html Msg
viewSeat ctx t player mine =
    let
        zone =
            "hole:" ++ player.id

        faces =
            cardsIn zone ctx.scene

        backs =
            hiddenCount zone ctx.scene

        stack =
            Protocol.counter "stack" player

        bet =
            Protocol.counter "bet" player

        folded =
            Protocol.hasFlag "folded" player

        allIn =
            Protocol.hasFlag "all_in" player

        toAct =
            Protocol.hasFlag "to_act" player

        isButton =
            Protocol.hasFlag "button" player

        net =
            Protocol.counter "net" player

        cards =
            div [ class "flex gap-1.5", classList [ ( "opacity-40", folded ) ] ]
                (List.map (viewCard mine) faces ++ List.repeat backs (viewBack mine))

        info =
            div [ class "flex flex-col gap-1 min-w-0" ]
                [ div [ class "flex items-center gap-2" ]
                    [ span
                        [ class "font-black text-lg truncate"
                        , classList [ ( "text-player", mine ), ( "text-opponent", not mine ) ]
                        ]
                        [ text player.name ]
                    , if isButton then
                        span [ class "pixel text-[8px] px-1.5 py-0.5", A.style "border" "2px solid var(--ink)", A.style "background" "var(--highlighter)", A.title "Dealer button" ] [ text "D" ]

                      else
                        text ""
                    ]
                , div [ class "flex items-center gap-2 text-sm" ]
                    [ span [ class "font-mono font-bold tabular-nums", A.attribute "data-stack" player.id ] [ text (String.fromInt stack) ]
                    , if t.format == "cash" && net /= 0 then
                        span
                            [ class "font-mono text-xs tabular-nums"
                            , A.style "color"
                                (if net > 0 then
                                    "var(--marker-green)"

                                 else
                                    "var(--red)"
                                )
                            ]
                            [ text
                                ((if net > 0 then
                                    "+"

                                  else
                                    ""
                                 )
                                    ++ String.fromInt net
                                )
                            ]

                      else
                        text ""
                    , if allIn then
                        span [ class "pixel text-[8px]", A.style "color" "var(--red)" ] [ text "ALL IN" ]

                      else if folded then
                        span [ class "pixel text-[8px]", A.style "color" "var(--pencil)" ] [ text "FOLDED" ]

                      else
                        text ""
                    ]
                , viewTimer ctx player.id toAct
                ]

        betChip =
            if bet > 0 then
                span [ class "chip font-mono text-sm tabular-nums", A.attribute "data-bet" player.id ] [ text (String.fromInt bet) ]

            else
                text ""
    in
    div
        [ class "w-full max-w-md flex items-center justify-between gap-3 pix-sm px-3 py-2"
        , classList [ ( "seat-active", toAct ) ]
        , A.attribute "data-seat" player.id
        ]
        (if mine then
            [ cards, betChip, info ]

         else
            [ info, betChip, cards ]
        )


viewTimer : Ctx -> String -> Bool -> Html msg
viewTimer ctx playerId toAct =
    case ctx.clock of
        Just clock ->
            if clock.enabled then
                case List.filter (\p -> p.id == playerId) clock.players of
                    player :: _ ->
                        let
                            elapsed =
                                if player.running then
                                    max 0 (ctx.now - ctx.receivedAt)

                                else
                                    0

                            moveLeft =
                                max 0 (player.moveMs - elapsed)

                            bankLeft =
                                max 0 (player.remainingMs - max 0 (elapsed - player.moveMs))
                        in
                        div [ class "font-mono text-xs tabular-nums flex items-center gap-2", classList [ ( "text-[color:var(--red)]", player.running && moveLeft == 0 ) ] ]
                            [ if player.running then
                                span [ class "font-bold" ] [ text (String.fromInt ((moveLeft + 999) // 1000) ++ "s") ]

                              else
                                text ""
                            , span [ A.style "color" "var(--pencil)" ] [ text ("bank " ++ Protocol.formatClock bankLeft) ]
                            ]

                    [] ->
                        text ""

            else
                text ""

        Nothing ->
            if toAct then
                span [ class "pixel text-[8px]", A.style "color" "var(--pen)" ] [ text "TO ACT" ]

            else
                text ""


viewFelt : Ctx -> Table -> Html Msg
viewFelt ctx t =
    let
        board =
            cardsIn "board" ctx.scene

        slots =
            List.map (viewCard False) board ++ List.repeat (5 - List.length board) viewSlot

        streetLabel =
            case ( t.phase, t.street ) of
                ( "betting", Just s ) ->
                    String.toUpper s

                _ ->
                    ""
    in
    div [ class "w-full max-w-md felt flex flex-col items-center gap-2 px-3 py-4" ]
        [ div [ class "flex gap-1.5", id_ "board" ] slots
        , div [ class "flex items-center gap-3" ]
            [ span [ class "chip font-mono text-sm tabular-nums", id_ "pot" ] [ text ("POT " ++ String.fromInt t.pot) ]
            , span [ class "pixel text-[9px]", A.style "color" "var(--pencil)" ] [ text streetLabel ]
            ]
        , viewBanner ctx t
        ]


viewBanner : Ctx -> Table -> Html Msg
viewBanner ctx t =
    case ( ctx.finished, t.lastResult ) of
        ( Just winners, _ ) ->
            div [ class "pixel text-[10px] text-center", id_ "banner" ]
                [ text
                    (case winners of
                        [ w ] ->
                            String.toUpper (ctx.nameOf w) ++ " WINS"

                        _ ->
                            "ALL SQUARE"
                    )
                ]

        ( Nothing, Just result ) ->
            if t.phase == "hand_over" then
                let
                    line =
                        case ( result.won, result.winners ) of
                            ( "split", _ ) ->
                                "SPLIT POT"

                            ( _, ( w, amount ) :: _ ) ->
                                String.toUpper (ctx.nameOf w) ++ " WINS " ++ String.fromInt amount

                            _ ->
                                ""

                    shown =
                        Dict.toList result.descriptions
                            |> List.map (\( id, d ) -> ctx.nameOf id ++ ": " ++ d)
                in
                div [ class "text-center space-y-1", id_ "banner" ]
                    (span [ class "pixel text-[10px]" ] [ text line ]
                        :: List.map (\s -> div [ class "text-xs", A.style "color" "var(--pencil)" ] [ text s ]) shown
                    )

            else
                text ""

        _ ->
            text ""


viewActions : Ctx -> Table -> Html Msg
viewActions ctx t =
    let
        legal =
            ctx.legal

        myTurn =
            hasAction "check" legal || hasAction "call" legal || hasAction "fold" legal
    in
    div [ class "w-full max-w-md flex flex-col gap-2", id_ "actions" ]
        (case ( ctx.finished, hasAction "deal" legal, myTurn ) of
            ( Just _, _, _ ) ->
                [ viewRematch ctx ]

            ( Nothing, True, _ ) ->
                [ button [ class "btn-arcade green pixel text-[11px] px-6 py-4 w-full", onClick (Simple "deal") ] [ text "NEXT HAND ▶" ]
                , div [ class "text-center text-xs", A.style "color" "var(--pencil)" ]
                    [ text
                        (if t.nextButton == ctx.playerId then
                            "Dealing in a moment…"

                         else
                            "Waiting for " ++ ctx.nameOf t.nextButton ++ " to deal…"
                        )
                    ]
                ]

            ( Nothing, False, True ) ->
                viewBetting ctx t

            ( Nothing, False, False ) ->
                [ div [ class "text-center pixel text-[10px] py-3", A.style "color" "var(--pencil)" ]
                    [ text
                        (case Protocol.sceneData D.string "to_act" ctx.scene of
                            Just id ->
                                "WAITING FOR " ++ String.toUpper (ctx.nameOf id)

                            Nothing ->
                                ""
                        )
                    ]
                , viewLeave ctx
                ]
        )


viewBetting : Ctx -> Table -> List (Html Msg)
viewBetting ctx t =
    let
        legal =
            ctx.legal

        main =
            div [ class "grid grid-cols-3 gap-2" ]
                [ if hasAction "fold" legal then
                    button [ class "btn-arcade pixel text-[10px] px-2 py-3", onClick (Simple "fold") ] [ text "FOLD" ]

                  else
                    div [] []
                , if hasAction "check" legal then
                    button [ class "btn-arcade yellow pixel text-[10px] px-2 py-3", onClick (Simple "check") ] [ text "CHECK" ]

                  else if hasAction "call" legal then
                    button [ class "btn-arcade yellow pixel text-[10px] px-2 py-3", onClick (Simple "call") ] [ text (String.toUpper (labelOf "call" legal)) ]

                  else
                    div [] []
                , case sizing legal of
                    Just s ->
                        let
                            amount =
                                clampAmount s ctx.model.amount
                        in
                        button [ class "btn-arcade green pixel text-[10px] px-2 py-3", onClick (SendAmount s.name amount), id_ "size-button" ]
                            [ text (String.toUpper s.label ++ " " ++ String.fromInt amount) ]

                    Nothing ->
                        if hasAction "all_in" legal then
                            button [ class "btn-arcade green pixel text-[10px] px-2 py-3", onClick (Simple "all_in") ] [ text (String.toUpper (labelOf "all_in" legal)) ]

                        else
                            div [] []
                ]

        sizer =
            case sizing legal of
                Just s ->
                    let
                        amount =
                            clampAmount s ctx.model.amount

                        myBet =
                            Protocol.findPlayer ctx.playerId ctx.scene |> Maybe.map (Protocol.counter "bet") |> Maybe.withDefault 0

                        potRaise =
                            myBet + t.toCall + t.pot + t.toCall

                        preset label total =
                            button
                                [ class "tile px-2 py-1 text-xs font-semibold"
                                , classList [ ( "tile-mine", clamp s.min s.max total == amount ) ]
                                , onClick (SetAmount (String.fromInt (clamp s.min s.max total)))
                                ]
                                [ text label ]
                    in
                    [ div [ class "flex items-center gap-2" ]
                        [ input
                            [ type_ "range"
                            , A.min (String.fromInt s.min)
                            , A.max (String.fromInt s.max)
                            , A.step (String.fromInt (max 1 t.bigBlind))
                            , value (String.fromInt amount)
                            , onInput SetAmount
                            , class "flex-1"
                            , id_ "size-slider"
                            ]
                            []
                        , input
                            [ type_ "number"
                            , A.min (String.fromInt s.min)
                            , A.max (String.fromInt s.max)
                            , value (String.fromInt amount)
                            , onInput SetAmount
                            , class "name-field w-24 px-2 py-1 font-mono text-sm"
                            , id_ "size-input"
                            ]
                            []
                        ]
                    , div [ class "flex flex-wrap gap-1.5" ]
                        [ preset "MIN" s.min
                        , preset "½ POT" (myBet + t.toCall + (t.pot + t.toCall) // 2)
                        , preset "POT" potRaise
                        , preset "ALL IN" s.max
                        ]
                    ]

                Nothing ->
                    []
    in
    sizer ++ [ main, viewLeave ctx ]


clampAmount : { a | min : Int, max : Int } -> Maybe Int -> Int
clampAmount s chosen =
    case chosen of
        Just n ->
            clamp s.min s.max n

        Nothing ->
            s.min


viewLeave : Ctx -> Html Msg
viewLeave ctx =
    if hasAction "resign" ctx.legal then
        div [ class "text-right" ]
            [ button [ class "text-[11px] underline", A.style "color" "var(--pencil)", onClick (Simple "resign") ]
                [ text (labelOf "resign" ctx.legal) ]
            ]

    else
        text ""


viewRematch : Ctx -> Html Msg
viewRematch ctx =
    let
        mine =
            List.member ctx.playerId ctx.rematchReady

        theirs =
            List.any (\id -> id /= ctx.playerId) ctx.rematchReady
    in
    div [ class "flex flex-col items-center gap-2 py-2" ]
        [ button
            [ class "btn-arcade green pixel text-[11px] px-6 py-4 w-full"
            , onClick Rematch
            , disabled mine
            ]
            [ text
                (if mine then
                    "WAITING FOR OPPONENT…"

                 else
                    "REMATCH"
                )
            ]
        , if theirs && not mine then
            span [ class "pixel text-[9px]", A.style "color" "var(--pen)" ] [ text "YOUR OPPONENT WANTS A REMATCH" ]

          else
            text ""
        ]



-- CARDS


viewCard : Bool -> Card -> Html msg
viewCard large card =
    let
        red =
            card.suit == "hearts" || card.suit == "diamonds"

        rank =
            String.dropRight 1 card.code
                |> (\r ->
                        if String.startsWith "10" card.code then
                            "10"

                        else
                            r
                   )
    in
    div
        [ class "pcard"
        , classList [ ( "red", red ), ( "lg", large ) ]
        , A.attribute "data-card" card.code
        ]
        [ span [ class "rank" ] [ text rank ]
        , span [ class "suit" ] [ text (suitSymbol card.suit) ]
        ]


viewBack : Bool -> Html msg
viewBack large =
    div [ class "pcard back", classList [ ( "lg", large ) ], A.attribute "data-card" "back" ] []


viewSlot : Html msg
viewSlot =
    div [ class "pcard slot" ] []


suitSymbol : String -> String
suitSymbol suit =
    case suit of
        "hearts" ->
            "♥"

        "diamonds" ->
            "♦"

        "clubs" ->
            "♣"

        _ ->
            "♠"
