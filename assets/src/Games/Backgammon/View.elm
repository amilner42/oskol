module Games.Backgammon.View exposing (Ctx, Model, Move, Msg(..), Out(..), Press, TapContext, autoRoll, dropZoneId, init, noteEvents, resolveTap, update, view)

{-| A backgammon board on the protocol Scene, in the notebook multicade style.

The whole play experience (both players, board, dice, cube, actions, clocks)
fits one phone screen with no scrolling: identity bars hug the board on the
viewer's side and the opponent's, and every action (roll, double, take, drop,
play, undo) lives in the board's centre band.

Turn the phone and the board takes the screen: in landscape the layout is
driven by height instead of width (`.bg-page` in app.css derives every
board dimension from `100dvh`), and the chrome -- the header and both
identity bars, clocks and all -- moves into a column beside the board
rather than above and below it. The class hooks that landscape needs
(`bg-page`, `bg-main`, `bg-stack`, `bg-header`, `bg-grid`, `bg-points`,
`bg-band`, `bg-cube-rail`, `is-me`) are the only reason this view names
them; the arrangement itself is entirely CSS.

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
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ParamKind(..), PlayerInfo, Scene, Schema, Token)
import View.Clock


type alias Model =
    { selectedFrom : Maybe String
    , drag : Drag.State String Msg -- the item a drag carries is my checker colour
    , autoRolled : Bool -- an automatic roll has been sent for the current server state
    , picker : Maybe (List Int) -- the pick-dice panel is open, with 0-2 values chosen
    , rollSeq : Int -- how many rolls this client has watched land (see `noteEvents`)
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
    | OpenPicker
    | PickFace Int
    | UnpickAt Int
    | CancelPick
    | ConfirmPick
    | Ignore


type Out
    = NoOut
    | Send E.Value
    | SendMany (List E.Value)
    | WantRematch
    | NeedZones (List String)


init : Model
init =
    { selectedFrom = Nothing, drag = Drag.idle, autoRolled = False, picker = Nothing, rollSeq = 0 }


{-| Clear the interaction state (selection, drag, picker) without forgetting
how many rolls have landed: `rollSeq` keys the dice, and forgetting it would
replay the tumble on every tap.
-}
reset : Model -> Model
reset model =
    { init | rollSeq = model.rollSeq }


{-| Count the rolls this client has seen. The dice tumble because a roll's
dice are new DOM elements (they are keyed by `rollSeq`), so the animation
comes from the `dice_rolled` event rather than from diffing the scene: a
reconnect that arrives without events simply shows the dice, already
settled. Main calls this once per arriving payload.
-}
noteEvents : List Protocol.Event -> Model -> Model
noteEvents events model =
    let
        rolls =
            List.length (List.filter isRoll events)

        isRoll event =
            case event of
                Protocol.Custom "dice_rolled" _ ->
                    True

                _ ->
                    False
    in
    { model | rollSeq = model.rollSeq + rolls }


{-| Roll for the viewer when there is nothing to ask: at the start of a
turn whose legal actions offer `roll` alone -- no `double` (Crawford, the
opponent owns the cube) and no `pick` (the twist is off, or the pick is
spent) -- the choice is no choice, so the client sends the roll itself.
Main calls this once per arriving payload. The guard is an edge:
`autoRolled` arms when the qualifying state first appears and clears
only when rolling stops being the pending action, so one turn rolls once
-- replayed payloads of the same state (reconnects) are skipped, and a
failed send cannot loop because nothing retries until the state changes.
-}
autoRoll : List Schema -> Model -> ( Model, Maybe E.Value )
autoRoll legal model =
    if hasAction "roll" legal && not (hasAction "double" legal) && not (hasAction "pick" legal) then
        if model.autoRolled then
            ( model, Nothing )

        else
            ( { model | autoRolled = True }, Just (Protocol.encodeAction "roll" []) )

    else if model.autoRolled then
        ( { model | autoRolled = False }, Nothing )

    else
        ( model, Nothing )


update : Msg -> Model -> ( Model, Out )
update msg model =
    case msg of
        SelectFrom loc ->
            if model.selectedFrom == Just loc then
                ( reset model, NoOut )

            else
                ( { model | selectedFrom = Just loc }, NoOut )

        Clear ->
            ( reset model, NoOut )

        PlayMove from to ->
            ( reset model, Send (encodeMove from to) )

        PlayPair a b ->
            ( reset model, SendMany [ encodeMove a.from a.to, encodeMove b.from b.to ] )

        Simple name ->
            ( reset model, Send (Protocol.encodeAction name []) )

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

        OpenPicker ->
            ( { model | picker = Just [] }, NoOut )

        PickFace value ->
            case model.picker of
                Just chosen ->
                    if List.length chosen < 2 then
                        ( { model | picker = Just (chosen ++ [ value ]) }, NoOut )

                    else
                        ( model, NoOut )

                Nothing ->
                    ( model, NoOut )

        UnpickAt index ->
            case model.picker of
                Just chosen ->
                    ( { model | picker = Just (List.take index chosen ++ List.drop (index + 1) chosen) }, NoOut )

                Nothing ->
                    ( model, NoOut )

        CancelPick ->
            ( { model | picker = Nothing }, NoOut )

        ConfirmPick ->
            case model.picker of
                Just [ a, b ] ->
                    ( reset model
                    , Send (Protocol.encodeAction "pick" [ ( "die1", E.int a ), ( "die2", E.int b ) ])
                    )

                _ ->
                    ( model, NoOut )

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
                    Choice (( id, _ ) :: _) ->
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
    div [ class "bg-page paper h-screen-safe overflow-hidden flex flex-col items-center px-2 py-2 sm:px-6 sm:py-4 gap-2" ]
        [ viewHeader ctx
        , div [ class "bg-main flex-1 min-h-0 w-full max-w-5xl grid gap-3 sm:gap-4 content-center lg:grid-cols-[minmax(0,1fr)_15rem]" ]
            [ div [ class "bg-stack min-w-0 flex flex-col justify-center gap-2" ]
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
    div [ class "bg-header w-full max-w-5xl flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            [ span [ class "pixel text-[9px] sm:text-xs whitespace-nowrap" ] [ text "BACKGAMMON" ]
            , span [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 whitespace-nowrap", style "border" "2px solid var(--ink)", style "background" "#fff" ]
                [ text
                    (matchLabel
                        ++ (if target > 1 then
                                " · G" ++ String.fromInt gameNumber

                            else
                                ""
                           )
                    )
                ]
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

                    -- which side of the board this bar belongs to: in
                    -- landscape the two are placed, not stacked.
                    , ( "is-me", isMe )
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
                , if Protocol.hasFlag "has_pick" p then
                    span
                        [ class "pixel text-[7px] px-1 py-0.5 shrink-0 bg-has-pick"
                        , style "border" "2px solid var(--bg-sky)"
                        , style "color" "var(--bg-sky)"
                        , title "Still holds the dice pick"
                        ]
                        [ text "PICK" ]

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

                            -- The turn's free seconds: the number below is
                            -- held until they are gone.
                            delay =
                                Protocol.delayNow player ctx.receivedAt ctx.now
                        in
                        span
                            [ classList
                                [ ( "clock-chip font-mono text-xs sm:text-sm lg:hidden", True )
                                , ( "running", player.running && not expired )
                                , ( "held", delay > 0 && not expired )
                                , ( "expired", expired )
                                ]
                            , title
                                (if delay > 0 && not expired then
                                    "Delay: this clock is held for "
                                        ++ String.fromInt ((delay + 999) // 1000)
                                        ++ " s"

                                 else
                                    "Time left"
                                )
                            ]
                            [ span [ class "tabular-nums font-bold" ]
                                [ text
                                    (if expired then
                                        "0:00"

                                     else
                                        Protocol.formatClock remaining
                                    )
                                ]
                            , if delay > 0 && not expired then
                                span [ class "delay-pip pixel text-[7px]" ]
                                    [ text ("+" ++ String.fromInt ((delay + 999) // 1000)) ]

                              else
                                text ""
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
    -- Classic geometry: the cube's rail on the far left, the bar one
    -- unbroken column through the middle, the trays on the far right. The
    -- centre band splits at the bar: cube-side actions (double, take, drop,
    -- undo, play) on the left half, the dice and their roll on the right.
    div [ class "bg-board relative p-1.5 sm:p-3 select-none" ]
        -- minmax(0, 6fr) so a wide button in a band can never steal width
        -- from the other half's points.
        [ div [ class "bg-grid grid grid-cols-[auto_minmax(0,6fr)_auto_minmax(0,6fr)_auto] gap-1 sm:gap-2" ]
            [ viewCubeRail board
            , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topLeft)
            , viewBarColumn board themId
            , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) topRight)
            , viewTray board themId
            , div [ class "bg-band min-w-0 flex flex-wrap items-center justify-center gap-2 sm:gap-3 min-h-[3.5rem] sm:min-h-[4rem] py-1" ]
                (viewLeftBand board)
            , div [ class "bg-band min-w-0 flex flex-wrap items-center justify-center gap-2 sm:gap-3 min-h-[3.5rem] sm:min-h-[4rem] py-1" ]
                (viewRightBand board)
            , div [] []
            , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomLeft)
            , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottomRight)
            , viewTray board me
            ]
        , case ( board.ctx.model.picker, hasAction "pick" board.ctx.legal ) of
            ( Just chosen, True ) ->
                viewPicker chosen

            _ ->
                text ""
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
            , ( "selected", isSelected )
            ]
         , attribute "style"
            ("--point: "
                ++ pointColor
                    (index
                        + (if isTop then
                            0

                           else
                            1
                          )
                    )
            )
         , title ("Point " ++ id)
         , Html.Attributes.id (dropZoneId id)
         ]
            ++ interaction
        )
        (viewStack { pick = isSource, picked = isSelected, lifted = liftedAt board id } tokens
            ++ (if isTarget then
                    [ dropGhost board (dragging && board.hovered == Just id) ]

                else
                    []
               )
        )


{-| Where a checker could land (dragging or after a tap-select): a
translucent checker of the mover's colour, firming up under the pointer
while dragging. No boxes, no outlines, ever.
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
            viewChecker
                (if i == lastIndex then
                    marks

                 else
                    noMarks
                )
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


{-| The bar: one unbroken column from the board's top edge to its bottom,
straight through the centre band. Hit checkers enter from their owner's
end -- the opponent's stack down from the top, the viewer's up from the
bottom. The viewer's whole column drags when a bar entry is legal.
-}
viewBarColumn : Board -> String -> Html Msg
viewBarColumn board themId =
    let
        seat =
            seatId board.ctx

        theirTokens =
            Protocol.zoneTokens ("bar:" ++ themId) board.ctx.scene

        myTokens =
            Protocol.zoneTokens ("bar:" ++ seat) board.ctx.scene

        mine =
            seat == board.ctx.playerId

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

        -- The whole bar drags when a bar entry is legal; a short press taps.
        interaction =
            if mine && isSource then
                dragAttrs board "bar"

            else
                click
    in
    div
        ([ class "bg-bar row-span-3 w-7 sm:w-11 flex flex-col items-center gap-px py-1"
         , title "Bar"
         ]
            ++ interaction
        )
        (viewStack noMarks theirTokens
            ++ [ div [ class "flex-1" ] [] ]
            ++ [ div [ class "flex flex-col-reverse items-center gap-px w-full" ]
                    (viewStack
                        { pick = isSource
                        , picked = isSelected
                        , lifted = mine && liftedAt board "bar"
                        }
                        myTokens
                    )
               ]
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
            dropGhost board (board.drag /= Nothing && board.hovered == Just "off")

          else
            text ""
        ]



-- CENTRE BAND
--
-- Every action on the board itself: nothing to act on ever renders below
-- the fold. The band splits at the bar. Left half: cube-side decisions
-- (double, take, drop) and the staging controls (undo, play). Right half:
-- the dice, their roll when doubling is also on offer (otherwise the turn
-- rolls itself -- see `autoRoll`), and the waiting status.


viewLeftBand : Board -> List (Html Msg)
viewLeftBand board =
    List.filterMap identity
        [ actionButton board.ctx "double" "plain"
        , actionButton board.ctx "take" "sky"
        , actionButton board.ctx "drop" "plain"
        , actionButton board.ctx "undo" "plain"
        , actionButton board.ctx "play" "sky"
        ]


viewRightBand : Board -> List (Html Msg)
viewRightBand board =
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

        -- The roll played nothing: the dice stand and the turn is about to
        -- pass. Both seats and any spectator see it, and it stays put until
        -- the mover presses the button, so nobody misses the dice that did
        -- it (see `no_moves` in the backgammon projection).
        noMoves =
            Protocol.sceneData D.bool "no_moves" ctx.scene |> Maybe.withDefault False

        pendingFrom =
            Protocol.sceneData (D.field "pending_from" (D.nullable D.string)) "cube" ctx.scene |> Maybe.withDefault Nothing

        myTurn =
            toActId ctx == Just ctx.playerId

        waitingName =
            toActId ctx |> Maybe.map ctx.nameOf |> Maybe.withDefault "OPPONENT"

        statusText s =
            span [ class "pixel text-[8px] sm:text-[9px] px-1", style "color" "var(--pencil)" ] [ text s ]

        -- ROLL appears only when it is a real choice -- against DOUBLE or
        -- PICK DICE; with roll the sole option the client already rolled
        -- by itself.
        roll =
            if hasAction "double" ctx.legal || hasAction "pick" ctx.legal then
                List.filterMap identity
                    [ actionButton ctx "roll" "sky"
                    , pickButton ctx
                    ]

            else
                []

        pickedTag =
            if List.any (\t -> Protocol.tokenProp D.bool "picked" t == Just True) dice then
                [ span
                    [ class "pixel text-[7px] px-1 py-0.5"
                    , style "background" "var(--bg-sky)"
                    , style "color" "#fff"
                    , title "These dice were picked, not rolled"
                    , Html.Attributes.id "dice-picked-tag"
                    ]
                    [ text "PICKED" ]
                ]

            else
                []

        anyAction =
            roll /= [] || viewLeftBand board /= []

        status =
            if ctx.finished /= Nothing then
                []

            else if noMoves then
                [ viewNoMoves myTurn waitingName ]

            else if anyAction then
                []

            else if pendingFrom /= Nothing && not myTurn then
                [ statusText "WAITING FOR THE TAKE…" ]

            else if not myTurn then
                [ statusText ("WAITING FOR " ++ String.toUpper waitingName) ]

            else
                []
    in
    viewDice ctx.model.rollSeq dice ++ pickedTag ++ roll ++ status


{-| The dice of the turn. They are keyed by the roll that produced them, so
every new roll builds fresh elements and the CSS tumble in `.die.rolling`
plays once, for about a second, before the pips settle. Staging a move
patches the same elements (the key has not moved), so marking a die spent
never restarts the animation.
-}
viewDice : Int -> List Token -> List (Html Msg)
viewDice rollSeq dice =
    [ Keyed.node "div"
        [ class "flex items-center gap-2 sm:gap-3" ]
        (List.map
            (\token ->
                ( "roll-" ++ String.fromInt rollSeq ++ "-" ++ token.id
                , viewDie token
                )
            )
            dice
        )
    ]


{-| "No legal moves": said in plain words next to the dice that did it, to
whoever is looking. The mover also gets the button that passes the turn on
(the `play` action, which the engine labels for the occasion); everyone
else just reads it and waits.
-}
viewNoMoves : Bool -> String -> Html Msg
viewNoMoves myTurn moverName =
    span
        [ class "pixel text-[8px] sm:text-[9px] px-1 leading-relaxed text-center"
        , style "color" "var(--bg-sky)"
        , title "Nothing this roll can play: the turn passes"
        , Html.Attributes.id "bg-no-moves"
        ]
        [ text
            (if myTurn then
                "NO LEGAL MOVES"

             else
                String.toUpper moverName ++ " HAS NO LEGAL MOVES"
            )
        , Html.br [] []
        , text "TURN PASSES"
        ]


{-| The twist's button: opens the dice picker. Legal exactly when `pick`
is -- once per game, gone for good after use.
-}
pickButton : Ctx -> Maybe (Html Msg)
pickButton ctx =
    if hasAction "pick" ctx.legal then
        Just
            (button
                [ class "btn-arcade pixel text-[9px] px-2 py-3 sm:px-4 text-center leading-relaxed plain"
                , Html.Attributes.id "pick-dice-open"
                , onClick OpenPicker
                ]
                [ text "PICK DICE" ]
            )

    else
        Nothing


{-| The pick-dice panel, floated over the board's centre so opening it
never reflows the one-screen layout: six faces to tap (twice for
doubles), the two chosen dice (tap one to take it back), confirm and
cancel.
-}
viewPicker : List Int -> Html Msg
viewPicker chosen =
    let
        slot index =
            case List.drop index chosen |> List.head of
                Just value ->
                    button
                        [ class "die mini"
                        , title "Tap to take this die back"
                        , onClick (UnpickAt index)
                        ]
                        [ miniFace value ]

                Nothing ->
                    div [ class "die mini empty" ] []
    in
    div [ class "absolute inset-x-0 top-1/2 -translate-y-1/2 z-20 flex justify-center pointer-events-none" ]
        [ div [ class "pix bg-white p-2 sm:p-3 flex flex-col items-center gap-2 pointer-events-auto", Html.Attributes.id "pick-dice-panel" ]
            [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text "PICK YOUR DICE" ]
            , div [ class "flex gap-1 sm:gap-1.5" ]
                (List.range 1 6
                    |> List.map
                        (\value ->
                            button
                                [ class "die mini"
                                , classList [ ( "spent", List.length chosen >= 2 ) ]
                                , Html.Attributes.id ("pick-face-" ++ String.fromInt value)
                                , disabled (List.length chosen >= 2)
                                , onClick (PickFace value)
                                ]
                                [ miniFace value ]
                        )
                )
            , div [ class "flex items-center gap-1.5 sm:gap-2" ]
                [ slot 0
                , slot 1
                , button
                    [ class "btn-arcade pixel text-[9px] px-3 py-2 sky"
                    , Html.Attributes.id "pick-confirm"
                    , disabled (List.length chosen /= 2)
                    , onClick ConfirmPick
                    ]
                    [ text "PICK" ]
                , button
                    [ class "btn-arcade pixel text-[9px] px-3 py-2 plain"
                    , Html.Attributes.id "pick-cancel"
                    , onClick CancelPick
                    ]
                    [ text "X" ]
                ]
            ]
        ]


{-| A die face at picker scale.
-}
miniFace : Int -> Html Msg
miniFace value =
    div [ class "grid grid-cols-3 grid-rows-3 w-4 h-4" ]
        (List.range 0 8
            |> List.map
                (\i ->
                    div [ class "flex items-center justify-center" ]
                        [ div
                            [ classList [ ( "w-1 h-1 rounded-full", True ), ( "invisible", not (List.member i (pipsOn value)) ) ]
                            , style "background" "var(--ink)"
                            ]
                            []
                        ]
                )
        )


{-| A die: its settled face, plus a reel of tumbling faces laid over it.
The reel is what the roll animation shows -- CSS walks it in `steps()` for
about a second and then hides it for good (`forwards`), leaving the real
face underneath. Reduced motion drops the reel and the face is all there
ever was.
-}
viewDie : Token -> Html Msg
viewDie token =
    let
        value =
            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1

        used =
            Protocol.tokenProp D.bool "used" token |> Maybe.withDefault False
    in
    div [ classList [ ( "die", True ), ( "used", used ), ( "rolling", not used ) ] ]
        [ div [ class "grid grid-cols-3 grid-rows-3 w-6 h-6" ] (pips value)
        , div [ class "die-tumble", attribute "aria-hidden" "true" ]
            [ div [ class "die-reel" ]
                (List.map
                    (\face ->
                        div [ class "die-frame" ]
                            [ div [ class "grid grid-cols-3 grid-rows-3 w-6 h-6" ] (pips face) ]
                    )
                    (tumbleFaces value)
                )
            ]
        ]


{-| The faces a die shows while it tumbles: five of them, none of them the
one it lands on, in a fixed order per value so the same roll always looks
the same (and a test can name them).
-}
tumbleFaces : Int -> List Int
tumbleFaces value =
    List.range 1 5 |> List.map (\i -> modBy 6 (value + i - 1) + 1)


pips : Int -> List (Html Msg)
pips value =
    List.range 0 8
        |> List.map
            (\i ->
                div [ class "flex items-center justify-center" ]
                    [ div
                        [ classList [ ( "w-1.5 h-1.5 rounded-full", True ), ( "invisible", not (List.member i (pipsOn value)) ) ]
                        , style "background" "var(--ink)"
                        ]
                        []
                    ]
            )


{-| Which cells of the 3x3 grid a die face lights.
-}
pipsOn : Int -> List Int
pipsOn value =
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


{-| The doubling cube's permanent home: a slim rail on the board's far
left, mirroring the trays. The cube always shows -- 64 while centred, as
tradition has it, its value once turned -- and its height tracks the
owner: centred with a centred cube, at the bottom when the viewer's seat
owns it, at the top when the opponent does. A pending offer parks it in
the middle, prominent, at the value on offer (a double is worth twice the
cube; the engine turns it on the take).
-}
viewCubeRail : Board -> Html Msg
viewCubeRail board =
    let
        ctx =
            board.ctx

        cubeData decoder field fallback =
            Protocol.sceneData (D.field field decoder) "cube" ctx.scene |> Maybe.withDefault fallback

        enabled =
            cubeData D.bool "enabled" False

        value =
            cubeData D.int "value" 1

        owner =
            cubeData (D.nullable D.string) "owner" Nothing

        pending =
            cubeData (D.nullable D.string) "pending_from" Nothing /= Nothing

        shown =
            if pending then
                String.fromInt (value * 2)

            else if value <= 1 then
                "64"

            else
                String.fromInt value

        justify =
            if pending then
                "justify-center"

            else
                case owner of
                    Just id ->
                        if id == seatId ctx then
                            "justify-end"

                        else
                            "justify-start"

                    Nothing ->
                        "justify-center"
    in
    -- A cube-less format keeps the rail (the board's geometry holds) but
    -- hangs no cube on it.
    div
        [ class ("bg-cube-rail row-span-3 w-9 sm:w-14 flex flex-col items-center py-2 " ++ justify)
        , title "Doubling cube"
        ]
        (if enabled then
            [ div [ classList [ ( "cube pixel text-[10px]", True ), ( "pending", pending ) ] ] [ text shown ] ]

         else
            []
        )


actionButton : Ctx -> String -> String -> Maybe (Html Msg)
actionButton ctx name variant =
    if hasAction name ctx.legal then
        Just
            (button
                [ class ("btn-arcade pixel text-[9px] px-2 py-3 sm:px-4 text-center leading-relaxed " ++ variant)
                , Html.Attributes.id ("bg-action-" ++ name)
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
