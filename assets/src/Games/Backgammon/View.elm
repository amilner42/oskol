module Games.Backgammon.View exposing (Ctx, Model, Move, Msg(..), Out(..), Press, TapContext, dropZoneId, init, resolveTap, update, view)

{-| A backgammon board on the protocol Scene, in the notebook multicade style.

The whole play experience (both players, board, dice, cube, actions, clocks)
fits one phone screen with no scrolling: identity bars hug the board on the
viewer's side and the opponent's, and every action (roll, double, take, drop,
play, undo) lives in the board's centre band.

Moving is destination-first: tapping a point where exactly one legal move
lands plays it, tapping a point where an unambiguous pair of moves would
land two checkers (making a point) stages both, and anything ambiguous
falls back to two taps: a checker's point (or the bar), then a destination.
Legal moves come from the `move` schemas the server sends, so the board
never invents legality.

Checkers can also be dragged, through the `Drag` state machine: every
legal origin (the whole point column, or the bar) is a drag source, so
grabbing any checker of the stack -- or the point itself -- drags that
origin's top checker. A press remembers what a plain tap there would have
done, so tap-to-move is untouched; past the threshold a ghost checker
rides the pointer and a translucent checker of the mover's colour marks
each legal destination. Drop targets are hit-tested geometrically:
pressing asks Main (the `NeedZones` Out) for the client rects of the
origin's legal destinations via `Browser.Dom.getElement` -- the whole point
column, or the tray, under the ids `dropZoneId` names -- and releasing on
one stages that move. Releasing anywhere else snaps the checker back and
sends nothing.

-}

import Drag
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ParamKind(..), PlayerInfo, Scene, Schema, Token)
import View.Clock


type alias Model =
    { selectedFrom : Maybe String
    , drag : Drag.State String Msg -- the item a drag carries is my checker colour
    }


{-| A press on a draggable checker: where, my colour (for the ghost), what
a plain tap there would have done (resolved at press time, by the same
`resolveTap` the click handlers use), and the origin's legal destinations
(so Main can measure their drop zones).
-}
type alias Press =
    { origin : String
    , color : String
    , tap : Maybe Msg
    , targets : List String
    , x : Float
    , y : Float
    }


type Msg
    = SelectFrom String
    | PlayMove String String
    | PlayPair Move Move
    | Clear
    | Simple String
    | Rematch
    | DragPressed Press
    | DragMoved { x : Float, y : Float }
    | DragReleased { x : Float, y : Float }
    | DragCancelled
    | GotDropZones (List Drag.Zone)
    | Ignore


type Out
    = NoOut
    | Send E.Value
    | SendMany (List E.Value)
    | WantRematch
    | NeedZones (List String)


init : Model
init =
    { selectedFrom = Nothing, drag = Drag.idle }


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

        PlayMove from to ->
            ( init, Send (encodeMove from to) )

        PlayPair a b ->
            ( init, SendMany [ encodeMove a.from a.to, encodeMove b.from b.to ] )

        Simple name ->
            ( init, Send (Protocol.encodeAction name []) )

        Rematch ->
            ( model, WantRematch )

        DragPressed p ->
            ( { model | drag = Drag.press { origin = p.origin, item = p.color, tap = p.tap, x = p.x, y = p.y } }
            , NeedZones p.targets
            )

        DragMoved pos ->
            ( { model | drag = Drag.move pos model.drag }, NoOut )

        DragReleased pos ->
            case Drag.release pos model.drag of
                ( drag, Drag.Drop from to ) ->
                    -- A drop stages the move exactly as a tap would.
                    update (PlayMove from to) { model | drag = drag }

                ( drag, Drag.Tap tap ) ->
                    update tap { model | drag = drag }

                ( drag, Drag.None ) ->
                    ( { model | drag = drag }, NoOut )

        DragCancelled ->
            ( { model | drag = Drag.idle }, NoOut )

        GotDropZones zones ->
            ( { model | drag = Drag.setZones zones model.drag }, NoOut )

        Ignore ->
            ( model, NoOut )


{-| The DOM id Main uses to measure a drop target (a point number or "off").
-}
dropZoneId : String -> String
dropZoneId loc =
    "bg-drop-" ++ loc


encodeMove : String -> String -> E.Value
encodeMove from to =
    Protocol.encodeAction "move" [ ( "from", E.string from ), ( "to", E.string to ) ]



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



-- TAP RESOLUTION
--
-- What a tap on a location means, derived entirely from the enumerated
-- legal moves. Destination-first: an unambiguous landing plays itself.


type alias TapContext =
    { selected : Maybe String
    , moves : List Move
    , sources : List String

    -- my checkers currently at a location ("bar", "off" or a point id)
    , mineAt : String -> Int

    -- values of the dice not yet used this turn
    , unusedDice : List Int
    }


{-| Resolve a tap on `dest`.

  - a selection is active: play selected -> dest if legal, toggle the
    selection off, or switch to another of my source points;
  - no selection, dest is one of my movable points (or the bar): select it;
  - exactly one legal move lands on dest: play it -- unless the dice are
    doubles and a second identical move would land a second checker on an
    empty-of-mine point, in which case stage the pair (make the point);
  - exactly two legal moves from different origins land on an
    empty-of-mine dest (one per die, necessarily): stage both;
  - anything else is ambiguous: no auto-move, select an origin instead.

-}
resolveTap : TapContext -> String -> Maybe Msg
resolveTap tc dest =
    let
        landing =
            List.filter (\m -> m.to == dest) tc.moves

        isSource =
            List.member dest tc.sources
    in
    case tc.selected of
        Just from ->
            if List.any (\m -> m.from == from && m.to == dest) tc.moves then
                Just (PlayMove from dest)

            else if dest == from then
                Just Clear

            else if isSource then
                Just (SelectFrom dest)

            else
                Nothing

        Nothing ->
            if isSource then
                Just (SelectFrom dest)

            else
                case landing of
                    [ m ] ->
                        if dest /= "off" && isDoubles tc.unusedDice && tc.mineAt m.from >= 2 && tc.mineAt dest == 0 then
                            Just (PlayPair m m)

                        else
                            Just (PlayMove m.from m.to)

                    [ a, b ] ->
                        if a.from /= b.from && dest /= "off" && tc.mineAt dest == 0 then
                            Just (PlayPair a b)

                        else
                            Nothing

                    _ ->
                        Nothing


{-| At most two dice values are ever distinct; two or more unused dice with
one value means doubles.
-}
isDoubles : List Int -> Bool
isDoubles dice =
    case dice of
        a :: b :: _ ->
            a == b

        _ ->
            False



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
    , away : List String -- seated players whose connection is down
    }


{-| The seat this viewer watches from: their own, or the first player's for
a spectator. Seating (bottom of the board) follows it; ownership of checkers
and actions still follows `ctx.playerId`.
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


toActId : Ctx -> Maybe String
toActId ctx =
    Protocol.sceneData (D.nullable D.string) "to_act" ctx.scene |> Maybe.withDefault Nothing


view : Ctx -> Html Msg
view ctx =
    let
        me =
            seatOf ctx

        them =
            Protocol.opponentOf (seatId ctx) ctx.scene

        myColor =
            colorOf me

        legalMoves =
            moves ctx.legal

        sources =
            legalMoves |> List.map .from |> unique

        drag =
            Drag.active ctx.model.drag

        -- While a drag is up, its origin's destinations highlight; otherwise
        -- the tapped selection's, if any.
        targets =
            case ( drag, ctx.model.selectedFrom ) of
                ( Just d, _ ) ->
                    legalMoves |> List.filter (\m -> m.from == d.origin) |> List.map .to

                ( Nothing, Just from ) ->
                    legalMoves |> List.filter (\m -> m.from == from) |> List.map .to

                ( Nothing, Nothing ) ->
                    []

        board =
            { ctx = ctx
            , myColor = myColor
            , sources = sources
            , targets = targets
            , drag = drag
            , hovered = Drag.hover ctx.model.drag
            , tap = tapContext ctx legalMoves sources
            }
    in
    div [ class "paper h-screen-safe overflow-hidden flex flex-col items-center px-2 py-2 sm:px-6 sm:py-4 gap-2" ]
        [ viewHeader ctx
        , div [ class "flex-1 min-h-0 w-full max-w-5xl grid gap-3 sm:gap-4 content-center lg:grid-cols-[minmax(0,1fr)_15rem]" ]
            [ div [ class "min-w-0 flex flex-col justify-center gap-2" ]
                [ viewPlayerBar ctx them False
                , viewBoard board
                , viewPlayerBar ctx me True
                ]
            , viewRail ctx
            ]
        , case drag of
            Just d ->
                viewDragGhost d

            Nothing ->
                text ""
        , case ctx.finished of
            Just winners ->
                viewGameOver ctx winners

            Nothing ->
                text ""
        ]


{-| The checker riding the pointer during a drag, in viewport coordinates
(the same space the drop zones are measured in).
-}
viewDragGhost : Drag.Active String -> Html Msg
viewDragGhost d =
    div
        [ class "bg-drag-ghost"
        , style "left" (String.fromFloat d.x ++ "px")
        , style "top" (String.fromFloat d.y ++ "px")
        ]
        [ div
            [ classList
                [ ( "checker", True )
                , ( "white", d.item == "white" )
                , ( "black", d.item /= "white" )
                ]
            ]
            []
        ]


tapContext : Ctx -> List Move -> List String -> TapContext
tapContext ctx legalMoves sources =
    let
        myColor =
            colorOf (Protocol.findPlayer ctx.playerId ctx.scene)

        mineAt loc =
            case loc of
                "bar" ->
                    Protocol.zoneTokens ("bar:" ++ ctx.playerId) ctx.scene |> List.length

                "off" ->
                    Protocol.findZone ("off:" ++ ctx.playerId) ctx.scene |> Maybe.map .count |> Maybe.withDefault 0

                point ->
                    Protocol.zoneTokens ("point:" ++ point) ctx.scene
                        |> List.filter (\t -> Protocol.tokenProp D.string "color" t == Just myColor)
                        |> List.length

        unusedDice =
            Protocol.zoneTokens "dice" ctx.scene
                |> List.filter (\t -> Protocol.tokenProp D.bool "used" t /= Just True)
                |> List.filterMap (Protocol.tokenProp D.int "value")
    in
    { selected = ctx.model.selectedFrom
    , moves = legalMoves
    , sources = sources
    , mineAt = mineAt
    , unusedDice = unusedDice
    }


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
    div [ class "w-full max-w-5xl flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            [ span [ class "pixel text-[9px] sm:text-xs whitespace-nowrap" ] [ text "BACKGAMMON" ]
            , span [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 whitespace-nowrap", style "border" "2px solid var(--ink)", style "background" "#fff" ]
                [ text (matchLabel ++ (if target > 1 then " · G" ++ String.fromInt gameNumber else "")) ]
            , if crawford then
                span [ class "pixel text-[7px] sm:text-[8px] px-1.5 py-1 whitespace-nowrap", style "border" "2px solid var(--bg-sky)", style "color" "var(--bg-sky)" ] [ text "CRAWFORD" ]

              else
                text ""
            ]
        , if hasAction "resign" ctx.legal && ctx.finished == Nothing then
            button [ class "pixel text-[8px] underline", style "color" "var(--pencil)", onClick (Simple "resign") ] [ text "RESIGN" ]

          else
            text ""
        ]



-- PLAYER BARS
--
-- One identity bar per player, anchored at that player's side of the board:
-- checker swatch, name, YOU, match score, pips, cube badge and (on phones)
-- that player's clock. The player to act gets the sky treatment.


viewPlayerBar : Ctx -> Maybe PlayerInfo -> Bool -> Html Msg
viewPlayerBar ctx player isMe =
    case player of
        Just p ->
            let
                active =
                    toActId ctx == Just p.id && ctx.finished == Nothing

                color =
                    colorOf (Just p)
            in
            div
                [ classList
                    [ ( "player-bar flex items-center gap-2 px-2 py-1.5 sm:px-3 sm:py-2", True )
                    , ( "active", active )
                    ]
                ]
                [ div [ class ("swatch shrink-0 " ++ color), title (p.name ++ " plays " ++ color) ] []
                , span [ class "font-bold text-sm sm:text-base truncate" ] [ text p.name ]
                , if isMe && p.id == ctx.playerId then
                    span [ class "pixel text-[7px] px-1 py-0.5 shrink-0", style "background" "var(--bg-sky)", style "color" "#fff" ] [ text "YOU" ]

                  else
                    text ""
                , if Protocol.hasFlag "owns_cube" p then
                    span [ class "pixel text-[7px] px-1 py-0.5 shrink-0", style "border" "2px solid var(--ink)", title "Owns the doubling cube" ] [ text "CUBE" ]

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
                , span [ class "pixel text-[7px] sm:text-[8px] whitespace-nowrap", style "color" "var(--pencil)", title "Pip count" ]
                    [ text (String.fromInt (Protocol.counter "pips" p) ++ " PIPS") ]
                , span [ class "score-chip pixel text-[9px] sm:text-[10px] shrink-0", title "Match score" ]
                    [ text (String.fromInt (Protocol.counter "score" p)) ]
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
        clock =
            View.Clock.view
                { clock = ctx.clock
                , playerId = seatId ctx
                , receivedAt = ctx.receivedAt
                , now = ctx.now
                , nameOf = ctx.nameOf
                }

        enabled =
            ctx.clock |> Maybe.map .enabled |> Maybe.withDefault False
    in
    div [ class "hidden lg:flex flex-col gap-3 justify-center" ]
        [ if enabled then
            div [ class "game-panel p-3 flex flex-col gap-2 items-end" ]
                [ span [ class "pixel text-[8px] self-start", style "color" "var(--pencil)" ] [ text "CLOCK" ]
                , clock
                ]

          else
            text ""
        ]



-- BOARD


type alias Board =
    { ctx : Ctx
    , myColor : String
    , sources : List String
    , targets : List String
    , drag : Maybe (Drag.Active String)
    , hovered : Maybe String
    , tap : TapContext
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
            seatId board.ctx

        themId =
            Protocol.opponentOf me board.ctx.scene |> Maybe.map .id |> Maybe.withDefault ""
    in
    div [ class "bg-board p-1.5 sm:p-3 select-none" ]
        [ div [ class "grid grid-cols-[6fr_auto_6fr_auto] gap-1 sm:gap-2" ]
            [ div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topLeft)
            , viewBar board themId True
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topRight)
            , viewTray board themId
            , div [ class "col-span-4 flex items-center justify-center gap-2 sm:gap-4 min-h-[3.5rem] sm:min-h-[4rem] py-1" ]
                (viewMiddle board)
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomLeft)
            , viewBar board me False
            , div [ class "grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomRight)
            , viewTray board me
            ]
        ]


pointColor : Int -> String
pointColor index =
    if modBy 2 index == 0 then
        "#3fa7d6"

    else
        "#d8e9f4"


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

        dragging =
            board.drag /= Nothing

        click =
            case resolveTap board.tap id of
                Just msg ->
                    [ onClick msg, class "cursor-pointer" ]

                Nothing ->
                    []

        -- A movable origin is draggable across its whole column (any checker
        -- of the stack, or the point itself); a short press there still taps.
        interaction =
            if isSource then
                dragAttrs board id

            else
                click
    in
    div
        ([ classList
            [ ( "bg-point h-36 sm:h-44 flex flex-col items-center gap-px px-px", True )
            , ( "top", isTop )
            , ( "bottom flex-col-reverse", not isTop )
            , ( "source", isSource )
            , ( "target", isTarget && not dragging )
            , ( "selected", isSelected )
            ]
         , attribute "style" ("--point: " ++ pointColor (index + (if isTop then 0 else 1)))
         , title ("Point " ++ id)
         , Html.Attributes.id (dropZoneId id)
         ]
            ++ interaction
        )
        (viewStack { pick = isSource, picked = isSelected, lifted = liftedAt board id } tokens
            ++ (if isTarget then
                    [ if dragging then
                        dropGhost board (board.hovered == Just id)

                      else
                        div [ class "ghost relative shrink-0" ] []
                    ]

                else
                    []
               )
        )


{-| Where a dragged checker would land: a translucent checker of the
dragger's colour, firming up under the pointer. No boxes, no outlines --
the tap flow keeps its own dashed slot.
-}
dropGhost : Board -> Bool -> Html Msg
dropGhost board firm =
    div
        [ classList
            [ ( "checker drop-ghost relative shrink-0", True )
            , ( "white", board.myColor == "white" )
            , ( "black", board.myColor /= "white" )
            , ( "firm", firm )
            ]
        ]
        []


{-| The origin of the active drag shows its top checker dimmed in place.
-}
liftedAt : Board -> String -> Bool
liftedAt board loc =
    board.drag |> Maybe.map (\d -> d.origin == loc) |> Maybe.withDefault False


{-| Drag handlers for a legal origin's whole column. The press carries
what a tap there would do -- the same `resolveTap` answer the click
handlers use -- and the origin's legal destinations, for Main to measure.
-}
dragAttrs : Board -> String -> List (Html.Attribute Msg)
dragAttrs board origin =
    if List.member origin board.sources then
        Drag.sourceAttrs
            { press =
                \pos ->
                    DragPressed
                        { origin = origin
                        , color = board.myColor
                        , tap = resolveTap board.tap origin
                        , targets = board.tap.moves |> List.filter (\m -> m.from == origin) |> List.map .to |> unique
                        , x = pos.x
                        , y = pos.y
                        }
            , move = DragMoved
            , release = DragReleased
            , cancel = DragCancelled
            , ignore = Ignore
            }

    else
        []


{-| What the top checker of a stack carries: the tap affordances, and the
dimmed in-place state while its origin is being dragged.
-}
type alias Marks =
    { pick : Bool, picked : Bool, lifted : Bool }


noMarks : Marks
noMarks =
    { pick = False, picked = False, lifted = False }


viewStack : Marks -> List Token -> List (Html Msg)
viewStack marks tokens =
    let
        shown =
            List.take 5 tokens

        extra =
            List.length tokens - 5

        lastIndex =
            List.length shown - 1
    in
    List.indexedMap
        (\i t ->
            viewChecker (if i == lastIndex then marks else noMarks)
                (if i == lastIndex && extra > 0 then
                    Just (extra + 5)

                 else
                    Nothing
                )
                t
        )
        shown


{-| A checker; the top one of a tall stack carries the stack's full count.
-}
viewChecker : Marks -> Maybe Int -> Token -> Html Msg
viewChecker marks count token =
    let
        color =
            Protocol.tokenProp D.string "color" token |> Maybe.withDefault "white"
    in
    div
        [ classList
            [ ( "checker relative shrink-0 transition-transform", True )
            , ( "white", color == "white" )
            , ( "black", color /= "white" )
            , ( "pick", marks.pick && not marks.picked )
            , ( "picked", marks.picked )
            , ( "lifted", marks.lifted )
            ]
        , title token.id
        ]
        (case count of
            Just n ->
                [ span [ class "checker-count" ] [ text (String.fromInt n) ] ]

            Nothing ->
                []
        )


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

        click =
            if mine then
                case resolveTap board.tap "bar" of
                    Just msg ->
                        [ onClick msg, class "cursor-pointer" ]

                    Nothing ->
                        []

            else
                []

        -- My whole bar drags when a bar entry is legal; a short press taps.
        interaction =
            if mine && isSource then
                dragAttrs board "bar"

            else
                click
    in
    div
        ([ classList
            [ ( "bg-bar w-7 sm:w-11 flex flex-col items-center gap-px py-1", True )
            , ( "flex-col-reverse", not isTop )
            ]
         , title "Bar"
         ]
            ++ interaction
        )
        (viewStack
            { pick = isSource
            , picked = isSelected
            , lifted = mine && liftedAt board "bar"
            }
            tokens
        )


viewTray : Board -> String -> Html Msg
viewTray board ownerId =
    let
        count =
            Protocol.findZone ("off:" ++ ownerId) board.ctx.scene |> Maybe.map .count |> Maybe.withDefault 0

        mine =
            ownerId == board.ctx.playerId

        isTarget =
            mine && List.member "off" board.targets

        click =
            if mine then
                case resolveTap board.tap "off" of
                    Just msg ->
                        [ onClick msg, class "cursor-pointer" ]

                    Nothing ->
                        []

            else
                []
    in
    div
        ([ classList
            [ ( "bg-tray w-9 sm:w-14 flex flex-col items-center justify-center gap-1 px-1", True )
            , ( "target", isTarget && board.drag == Nothing )
            ]
         , title "Borne off"
         ]
            ++ (if mine then
                    [ Html.Attributes.id (dropZoneId "off") ]

                else
                    []
               )
            ++ click
        )
        [ span [ class "pixel text-[7px]", style "color" "rgba(35, 36, 58, 0.5)" ] [ text "OFF" ]
        , span [ class "pixel text-xs" ] [ text (String.fromInt count) ]
        , if isTarget then
            case board.drag of
                Just _ ->
                    dropGhost board (board.hovered == Just "off")

                Nothing ->
                    div [ class "ghost" ] []

          else
            text ""
        ]



-- CENTRE BAND
--
-- Dice, cube, and every action, on the board itself: nothing to act on
-- ever renders below the fold.


viewMiddle : Board -> List (Html Msg)
viewMiddle board =
    let
        ctx =
            board.ctx

        -- The dice zone keeps last turn's spent dice around until the next
        -- roll; during a roll/double/take/drop decision they are noise.
        deciding =
            List.any (\n -> hasAction n ctx.legal) [ "roll", "take", "drop" ]

        dice =
            Protocol.zoneTokens "dice" ctx.scene
                |> List.filter
                    (\t -> not (deciding && Protocol.tokenProp D.bool "used" t == Just True))

        cube =
            Protocol.zoneTokens "cube" ctx.scene |> List.head

        pendingFrom =
            Protocol.sceneData (D.field "pending_from" (D.nullable D.string)) "cube" ctx.scene |> Maybe.withDefault Nothing

        myTurn =
            toActId ctx == Just ctx.playerId

        waitingName =
            toActId ctx |> Maybe.map ctx.nameOf |> Maybe.withDefault "OPPONENT"

        statusText s =
            span [ class "pixel text-[8px] sm:text-[9px] px-1", style "color" "var(--pencil)" ] [ text s ]

        actions =
            List.filterMap identity
                [ actionButton ctx "roll" "sky"
                , actionButton ctx "double" "plain"
                , actionButton ctx "take" "sky"
                , actionButton ctx "drop" "plain"
                , actionButton ctx "undo" "plain"
                , actionButton ctx "play" "sky"
                ]

        status =
            if ctx.finished /= Nothing then
                []

            else if actions /= [] then
                []

            else if pendingFrom /= Nothing && not myTurn then
                [ statusText "WAITING FOR THE TAKE…" ]

            else if not myTurn then
                [ statusText ("WAITING FOR " ++ String.toUpper waitingName) ]

            else
                []
    in
    List.map viewDie dice
        ++ (case cube of
                Just token ->
                    [ viewCube ctx token ]

                Nothing ->
                    []
           )
        ++ actions
        ++ status


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
                        [ classList [ ( "w-1.5 h-1.5 rounded-full", True ), ( "invisible", not (List.member i on) ) ]
                        , style "background" "var(--ink)"
                        ]
                        []
                    ]
            )


viewCube : Ctx -> Token -> Html Msg
viewCube ctx token =
    let
        value =
            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1
    in
    div [ class "cube pixel text-[10px]", title "Doubling cube" ]
        [ text
            (if value == 1 then
                "64"

             else
                String.fromInt value
            )
        ]


actionButton : Ctx -> String -> String -> Maybe (Html Msg)
actionButton ctx name variant =
    if hasAction name ctx.legal then
        Just
            (button
                [ class ("btn-arcade pixel text-[9px] px-3 py-3 sm:px-4 whitespace-nowrap " ++ variant)
                , onClick (Simple name)
                ]
                [ text (String.toUpper (labelOf name ctx.legal)) ]
            )

    else
        Nothing



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

        scoreline =
            ctx.scene.players
                |> List.map (\p -> p.name ++ " " ++ String.fromInt (Protocol.counter "score" p))
                |> String.join " · "
    in
    div [ class "fixed inset-0 z-50 flex items-center justify-center p-4", style "background" "rgba(35, 36, 58, 0.55)" ]
        [ div [ class "pix bg-white p-6 sm:p-8 max-w-md w-full text-center flex flex-col gap-4" ]
            [ span [ class "pixel text-[10px]", style "color" "var(--bg-sky)" ] [ text "GAME OVER" ]
            , span [ class "pixel text-base sm:text-lg leading-relaxed" ]
                [ text
                    (if iWon then
                        "YOU WIN!"

                     else
                        String.toUpper winnerName ++ " WINS"
                    )
                ]
            , span [ class "pixel text-[9px]", style "color" "var(--pencil)" ] [ text scoreline ]
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
