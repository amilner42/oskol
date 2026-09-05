module Games.Chess.View exposing (Ctx, Model, Move, Msg(..), Out(..), TapContext, init, movesOf, ranksFor, resolveTap, update, view)

{-| A chessboard on the protocol Scene, in the notebook multicade style.

The whole play experience fits one phone screen with no scrolling: the
opponent's identity bar hugs the top of the board, the viewer's the bottom,
clocks are chips in the bars on phones and a rail on desktop, and the board
is oriented with the viewer's color at the bottom.

Moving is two taps, exactly as on the big chess sites: tap one of your
pieces and its legal destinations show as dots (rings on captures), tap a
destination to play. Tapping the piece again or an idle square clears the
selection; tapping another of your pieces switches to it. A pawn reaching
the last rank opens a small picker for the promotion piece — the four
promotion schemas are distinct candidates. Legal moves come only from the
`move` schemas the server sends, so the board never invents legality.

-}

import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (class, classList, style, title)
import Html.Events exposing (onClick, stopPropagationOn)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ParamKind(..), PlayerInfo, Scene, Schema, Token)
import View.Clock


type alias Model =
    { selected : Maybe String
    , promoting : Maybe ( String, String )
    }


type Msg
    = SelectSquare String
    | Play Move
    | OpenPromotion String String
    | Clear
    | Simple String
    | Rematch


type Out
    = NoOut
    | Send E.Value
    | WantRematch


init : Model
init =
    { selected = Nothing, promoting = Nothing }


update : Msg -> Model -> ( Model, Out )
update msg model =
    case msg of
        SelectSquare square ->
            if model.selected == Just square && model.promoting == Nothing then
                ( init, NoOut )

            else
                ( { selected = Just square, promoting = Nothing }, NoOut )

        Play move ->
            ( init, Send (encodeMove move) )

        OpenPromotion from to ->
            ( { selected = Just from, promoting = Just ( from, to ) }, NoOut )

        Clear ->
            ( init, NoOut )

        Simple name ->
            ( init, Send (Protocol.encodeAction name []) )

        Rematch ->
            ( model, WantRematch )


encodeMove : Move -> E.Value
encodeMove move =
    Protocol.encodeAction "move"
        ([ ( "from", E.string move.from ), ( "to", E.string move.to ) ]
            ++ (case move.promotion of
                    Just piece ->
                        [ ( "promotion", E.string piece ) ]

                    Nothing ->
                        []
               )
        )



-- LEGAL MOVES


type alias Move =
    { from : String, to : String, promotion : Maybe String }


movesOf : List Schema -> List Move
movesOf legal =
    legal
        |> List.filter (\s -> s.name == "move")
        |> List.filterMap
            (\s ->
                case ( choice "from" s, choice "to" s ) of
                    ( Just from, Just to ) ->
                        Just { from = from, to = to, promotion = choice "promotion" s }

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



-- TAP RESOLUTION


type alias TapContext =
    { selected : Maybe String
    , promoting : Bool
    , moves : List Move
    , sources : List String
    }


{-| Resolve a tap on `square`.

  - the promotion picker is open: any board tap closes it;
  - a piece is selected: a legal destination plays the move (or opens the
    promotion picker when the only candidates promote), the same square
    clears, another of my movable pieces switches the selection, anything
    else clears;
  - nothing selected: one of my movable pieces selects it.

-}
resolveTap : TapContext -> String -> Maybe Msg
resolveTap tc square =
    if tc.promoting then
        Just Clear

    else
        case tc.selected of
            Just from ->
                let
                    landing =
                        List.filter (\m -> m.from == from && m.to == square) tc.moves
                in
                case landing of
                    [] ->
                        if square == from then
                            Just Clear

                        else if List.member square tc.sources then
                            Just (SelectSquare square)

                        else
                            Just Clear

                    [ move ] ->
                        Just (Play move)

                    _ ->
                        -- Several candidates for one from/to pair are the
                        -- four promotions: let the player pick the piece.
                        Just (OpenPromotion from square)

            Nothing ->
                if List.member square tc.sources then
                    Just (SelectSquare square)

                else
                    Nothing



-- ORIENTATION


{-| Rank digits from the top row of the board to the bottom, for a viewer of
this color: White sees rank 8 on top, Black rank 1.
-}
ranksFor : String -> List Int
ranksFor color =
    if color == "black" then
        List.range 1 8

    else
        List.range 1 8 |> List.reverse


filesFor : String -> List String
filesFor color =
    let
        files =
            [ "a", "b", "c", "d", "e", "f", "g", "h" ]
    in
    if color == "black" then
        List.reverse files

    else
        files



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
    , away : List String
    }


{-| The seat this viewer watches from: their own, or the first player's for
a spectator. Orientation follows it; actions still follow `ctx.playerId`.
-}
seatOf : Ctx -> Maybe PlayerInfo
seatOf ctx =
    case Protocol.findPlayer ctx.playerId ctx.scene of
        Just p ->
            Just p

        Nothing ->
            List.head ctx.scene.players


seatId : Ctx -> String
seatId ctx =
    seatOf ctx |> Maybe.map .id |> Maybe.withDefault ctx.playerId


colorOf : Maybe PlayerInfo -> String
colorOf player =
    player |> Maybe.andThen (Protocol.playerData D.string "color") |> Maybe.withDefault "white"


toMoveId : Ctx -> Maybe String
toMoveId ctx =
    Protocol.sceneData (D.nullable D.string) "to_move" ctx.scene |> Maybe.withDefault Nothing


view : Ctx -> Html Msg
view ctx =
    let
        me =
            seatOf ctx

        them =
            Protocol.opponentOf (seatId ctx) ctx.scene

        legalMoves =
            movesOf ctx.legal

        board =
            { ctx = ctx
            , myColor = colorOf me
            , moves = legalMoves
            , tap =
                { selected = ctx.model.selected
                , promoting = ctx.model.promoting /= Nothing
                , moves = legalMoves
                , sources = legalMoves |> List.map .from |> unique
                }
            }
    in
    div [ class "paper h-screen-safe overflow-hidden flex flex-col items-center px-2 py-2 sm:px-6 sm:py-4 gap-2" ]
        [ viewHeader ctx
        , div [ class "flex-1 min-h-0 w-full max-w-5xl grid gap-3 sm:gap-4 content-center lg:grid-cols-[minmax(0,1fr)_15rem]" ]
            [ div [ class "min-w-0 flex flex-col items-center justify-center gap-2" ]
                [ viewPlayerBar ctx them
                , viewBoard board
                , viewPlayerBar ctx me
                , viewStatus ctx
                ]
            , viewRail ctx
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


viewHeader : Ctx -> Html Msg
viewHeader ctx =
    div [ class "w-full max-w-5xl flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            [ span [ class "pixel text-[9px] sm:text-xs whitespace-nowrap" ] [ text "CHESS" ]
            , span
                [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 whitespace-nowrap"
                , style "border" "2px solid var(--ink)"
                , style "background" "#fff"
                ]
                [ text ("MOVE " ++ String.fromInt (ply ctx // 2 + 1)) ]
            ]
        , if hasAction "resign" ctx.legal && ctx.finished == Nothing then
            button [ class "pixel text-[8px] underline", style "color" "var(--pencil)", onClick (Simple "resign") ] [ text "RESIGN" ]

          else
            text ""
        ]


ply : Ctx -> Int
ply ctx =
    Protocol.sceneData D.int "ply" ctx.scene |> Maybe.withDefault 0



-- PLAYER BARS


viewPlayerBar : Ctx -> Maybe PlayerInfo -> Html Msg
viewPlayerBar ctx player =
    case player of
        Just p ->
            let
                active =
                    toMoveId ctx == Just p.id && ctx.finished == Nothing

                color =
                    colorOf (Just p)

                lead =
                    materialLead ctx p
            in
            div
                [ classList
                    [ ( "player-bar w-full flex items-center gap-2 px-2 py-1.5 sm:px-3 sm:py-2", True )
                    , ( "active", active )
                    ]
                ]
                [ div [ class ("swatch shrink-0 " ++ color), title (p.name ++ " plays " ++ color) ] []
                , span [ class "font-bold text-sm sm:text-base truncate" ] [ text p.name ]
                , if p.id == ctx.playerId then
                    span [ class "pixel text-[7px] px-1 py-0.5 shrink-0", style "background" "var(--bg-sky)", style "color" "#fff" ] [ text "YOU" ]

                  else
                    text ""
                , if Protocol.hasFlag "in_check" p && ctx.finished == Nothing then
                    span [ class "pixel text-[7px] px-1 py-0.5 shrink-0", style "background" "var(--red)", style "color" "#fff" ] [ text "CHECK" ]

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
                , if lead > 0 then
                    span [ class "pixel text-[8px] shrink-0", style "color" "var(--pencil)", title "Material advantage" ]
                        [ text ("+" ++ String.fromInt lead) ]

                  else
                    text ""
                , viewClockChip ctx p.id
                ]

        Nothing ->
            text ""


{-| This player's material advantage in points, zero when behind or level.
-}
materialLead : Ctx -> PlayerInfo -> Int
materialLead ctx player =
    let
        material p =
            Protocol.counter "material" p

        other =
            ctx.scene.players |> List.filter (\p -> p.id /= player.id) |> List.head
    in
    case other of
        Just p ->
            max 0 (material player - material p)

        Nothing ->
            0


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



-- STATUS LINE


viewStatus : Ctx -> Html Msg
viewStatus ctx =
    let
        myTurn =
            toMoveId ctx == Just ctx.playerId

        waitingName =
            toMoveId ctx |> Maybe.map ctx.nameOf |> Maybe.withDefault "OPPONENT"
    in
    if ctx.finished /= Nothing || myTurn || toMoveId ctx == Nothing then
        text ""

    else
        span [ class "pixel text-[8px] sm:text-[9px]", style "color" "var(--pencil)" ]
            [ text ("WAITING FOR " ++ String.toUpper waitingName) ]



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
                    , playerId = seatId ctx
                    , receivedAt = ctx.receivedAt
                    , now = ctx.now
                    , nameOf = ctx.nameOf
                    }
                ]

          else
            text ""
        ]



-- BOARD


type alias Board =
    { ctx : Ctx
    , myColor : String
    , moves : List Move
    , tap : TapContext
    }


{-| Piece token on a square, from the board zone's grid positions
(column 0, row 0 is a8).
-}
pieceAt : Scene -> String -> Maybe Token
pieceAt scene square =
    Protocol.zoneTokens "board" scene
        |> List.filter (\t -> t.position |> Maybe.map squareName |> (==) (Just square))
        |> List.head


squareName : ( Int, Int ) -> String
squareName ( column, row ) =
    let
        file =
            [ "a", "b", "c", "d", "e", "f", "g", "h" ]
                |> List.drop column
                |> List.head
                |> Maybe.withDefault "a"
    in
    file ++ String.fromInt (8 - row)


lastMove : Scene -> List String
lastMove scene =
    Protocol.sceneData (D.nullable (D.list D.string)) "last_move" scene
        |> Maybe.withDefault Nothing
        |> Maybe.withDefault []


{-| The square of the king now in check, when any.
-}
checkedKing : Scene -> Maybe String
checkedKing scene =
    let
        inCheck =
            Protocol.sceneData D.bool "in_check" scene == Just True

        toMoveColor =
            Protocol.sceneData (D.nullable D.string) "to_move" scene
                |> Maybe.withDefault Nothing
                |> Maybe.andThen (\id -> Protocol.findPlayer id scene)
                |> Maybe.andThen (Protocol.playerData D.string "color")
    in
    if inCheck then
        Protocol.zoneTokens "board" scene
            |> List.filter
                (\t ->
                    Protocol.tokenProp D.string "kind" t
                        == Just "king"
                        && Protocol.tokenProp D.string "piece" t
                        == toMoveColor
                )
            |> List.head
            |> Maybe.andThen .position
            |> Maybe.map squareName

    else
        Nothing


viewBoard : Board -> Html Msg
viewBoard board =
    let
        ctx =
            board.ctx

        files =
            filesFor board.myColor

        ranks =
            ranksFor board.myColor

        last =
            lastMove ctx.scene

        check =
            checkedKing ctx.scene

        targets =
            case ctx.model.selected of
                Just from ->
                    board.moves |> List.filter (\m -> m.from == from) |> List.map .to

                Nothing ->
                    []

        squares =
            ranks
                |> List.indexedMap
                    (\rowIndex rank ->
                        files
                            |> List.indexedMap
                                (\colIndex file ->
                                    viewSquare board
                                        { square = file ++ String.fromInt rank
                                        , fileLabel =
                                            if rowIndex == 7 then
                                                Just file

                                            else
                                                Nothing
                                        , rankLabel =
                                            if colIndex == 0 then
                                                Just (String.fromInt rank)

                                            else
                                                Nothing
                                        , last = last
                                        , check = check
                                        , targets = targets
                                        }
                                )
                    )
                |> List.concat
    in
    div
        [ class "relative w-full"
        , style "max-width" "min(100%, calc(100svh - 16rem), 34rem)"
        ]
        [ div [ class "chess-board" ] squares
        , case ctx.model.promoting of
            Just ( from, to ) ->
                viewPromotionPicker board.myColor from to

            Nothing ->
                text ""
        ]


type alias SquareInfo =
    { square : String
    , fileLabel : Maybe String
    , rankLabel : Maybe String
    , last : List String
    , check : Maybe String
    , targets : List String
    }


viewSquare : Board -> SquareInfo -> Html Msg
viewSquare board info =
    let
        ctx =
            board.ctx

        piece =
            pieceAt ctx.scene info.square

        isDark =
            case String.toList info.square of
                [ file, rank ] ->
                    modBy 2 (Char.toCode file + Char.toCode rank) == 0

                _ ->
                    False

        isTarget =
            List.member info.square info.targets

        click =
            case resolveTap board.tap info.square of
                Just msg ->
                    [ onClick msg, class "cursor-pointer" ]

                Nothing ->
                    []
    in
    div
        ([ classList
            [ ( "chess-sq", True )
            , ( "dark", isDark )
            , ( "light", not isDark )
            , ( "last", List.member info.square info.last )
            , ( "selected", ctx.model.selected == Just info.square )
            , ( "check", info.check == Just info.square )
            ]
         , Html.Attributes.attribute "data-square" info.square
         , title info.square
         ]
            ++ click
        )
        (List.filterMap identity
            [ info.rankLabel |> Maybe.map (\r -> span [ class "chess-coord rank" ] [ text r ])
            , info.fileLabel |> Maybe.map (\f -> span [ class "chess-coord file" ] [ text f ])
            , piece |> Maybe.map viewPiece
            , if isTarget then
                Just
                    (div
                        [ classList
                            [ ( "chess-hint", True )
                            , ( "capture", piece /= Nothing )
                            ]
                        ]
                        []
                    )

              else
                Nothing
            ]
        )


viewPiece : Token -> Html Msg
viewPiece token =
    let
        color =
            Protocol.tokenProp D.string "piece" token |> Maybe.withDefault "white"

        kind =
            Protocol.tokenProp D.string "kind" token |> Maybe.withDefault "pawn"
    in
    span
        [ class ("chess-piece " ++ color), title token.id ]
        [ text (solidGlyph kind ++ "\u{FE0E}") ]


{-| Both sides use the solid glyph set, colored by CSS: the outline set
renders too thin to read at board size.
-}
solidGlyph : String -> String
solidGlyph kind =
    case kind of
        "king" ->
            "♚"

        "queen" ->
            "♛"

        "rook" ->
            "♜"

        "bishop" ->
            "♝"

        "knight" ->
            "♞"

        _ ->
            "♟"



-- PROMOTION PICKER


viewPromotionPicker : String -> String -> String -> Html Msg
viewPromotionPicker myColor from to =
    div
        [ class "absolute inset-0 z-30 flex items-center justify-center"
        , style "background" "rgba(35, 36, 58, 0.45)"
        , onClick Clear
        ]
        [ div
            [ class "pix bg-white p-3 sm:p-4 flex flex-col items-center gap-2"
            , stopPropagationOn "click" (D.succeed ( Clear, True ))
            ]
            [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text "PROMOTE TO" ]
            , div [ class "flex gap-2" ]
                (List.map
                    (\( id, kind ) ->
                        button
                            [ class "tile w-12 h-12 sm:w-14 sm:h-14 flex items-center justify-center"
                            , Html.Attributes.attribute "data-promote" id
                            , style "font-size" "2rem"
                            , stopPropagationOn "click"
                                (D.succeed ( Play { from = from, to = to, promotion = Just id }, True ))
                            ]
                            [ span [ class ("chess-piece " ++ myColor) ] [ text (solidGlyph kind ++ "\u{FE0E}") ] ]
                    )
                    [ ( "q", "queen" ), ( "r", "rook" ), ( "b", "bishop" ), ( "n", "knight" ) ]
                )
            ]
        ]



-- GAME OVER


viewGameOver : Ctx -> List String -> Html Msg
viewGameOver ctx winners =
    let
        iWon =
            List.member ctx.playerId winners

        draw =
            List.isEmpty winners

        winnerName =
            winners |> List.head |> Maybe.map ctx.nameOf |> Maybe.withDefault "Nobody"

        reason =
            Protocol.sceneData (D.field "reason" D.string) "result" ctx.scene
                |> Maybe.map (String.replace "_" " ")
                |> Maybe.withDefault ""

        meReady =
            List.member ctx.playerId ctx.rematchReady

        theyReady =
            ctx.rematchReady |> List.any (\id -> id /= ctx.playerId)
    in
    div [ class "fixed inset-0 z-50 flex items-center justify-center p-4", style "background" "rgba(35, 36, 58, 0.55)" ]
        [ div [ class "pix bg-white p-6 sm:p-8 max-w-md w-full text-center flex flex-col gap-4" ]
            [ span [ class "pixel text-[10px]", style "color" "var(--bg-sky)" ] [ text "GAME OVER" ]
            , span [ class "pixel text-base sm:text-lg leading-relaxed" ]
                [ text
                    (if draw then
                        "DRAW"

                     else if iWon then
                        "YOU WIN!"

                     else
                        String.toUpper winnerName ++ " WINS"
                    )
                ]
            , if reason /= "" then
                span [ class "pixel text-[9px]", style "color" "var(--pencil)" ] [ text (String.toUpper ("BY " ++ reason)) ]

              else
                text ""
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
                [ class "btn-arcade pixel text-[10px] px-6 py-4 sky"
                , Html.Attributes.disabled meReady
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
