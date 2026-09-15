module Games.Backgammon.View exposing (Ctx, Model, Move, Msg(..), Out(..), Path, Press, Roll, TapContext, autoRoll, defaultTheme, dropZoneId, init, noteEvents, pathsFrom, reachableFrom, resolveTap, themes, tumbleFaces, update, view)

{-| A backgammon board on the protocol Scene, in the notebook multicade style.

The whole play experience (both players, board, dice, cube, actions, clocks)
fits one phone screen with no scrolling. The table is one dark slab: the
opponent's identity bar, the board and the viewer's bar share a frame. The
points take the slab's whole width: the doubling cube lives on the bar (in
the middle while centred, at the band end of the owner's half once
turned) and each player's bear-off tray is a row of holders in their own
identity bar, beside their name and clock, so no column of the board is
spent on either. Every action (roll, double, take, drop, play, undo)
lives in the board's centre band, and each player's clock in their bar.

Turn the phone and the board takes the screen: in landscape the layout is
driven by height instead of width (`.bg-page` in app.css derives every
board dimension from `100dvh`; a desktop window gets the same treatment,
so a big monitor gets a big board), and the chrome -- the header and both
identity bars, clocks and all -- moves into a column beside the board
rather than above and below it. The class hooks that landscape needs
(`bg-page`, `bg-main`, `bg-stack`, `bg-header`, `bg-grid`, `bg-points`,
`bg-band`, `bg-bar`, `is-me`) are the only reason this view names them;
the arrangement itself is entirely CSS.

Moving is one touch. A tap on a checker of mine that can move (its whole
point, or the bar) plays it with the next die: the first unused die,
reading the dice as they sit, that has a legal move from there. A tap on
the dice swaps them, so the next die is always the left one and the
other die is one tap away too. Destinations still answer a tap of their own: a point where exactly
one legal move lands plays it, and a point where an unambiguous pair of
moves would land two checkers (making a point) stages both. There is no
selection to make or clear; anything a tap cannot say, a drag can. Legal
moves come from the `move` schemas the server sends, so the board never
invents legality.

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

import Dict
import Drag
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ParamKind(..), PlayerInfo, Scene, Schema, Token)
import Svg
import Svg.Attributes as SvgAttr


type alias Model =
    { drag : Drag.State String Msg -- the item a drag carries is my checker colour
    , plans : List ( String, List Move ) -- for the active drag: each destination and the moves that get there
    , swaps : Int -- taps on the dice this roll: odd means the two dice have changed places
    , autoRolled : Bool -- an automatic roll has been sent for the current server state
    , picker : Maybe (List Int) -- the pick-dice panel is open, with 0-2 values chosen
    , resigning : Bool -- the resign panel is open: which stakes to offer
    , themesOpen : Bool -- the board-colour list in the header is showing
    , roll : Roll -- the dice on the board, and whether this client saw them land
    , recordOpen : Bool -- the move list is open as a sheet over the board (phones)
    , viewing : Maybe Int -- a past turn of the record (its index, oldest first) is on the board instead of the live game
    , stale : Bool -- the game moved on while a past turn was on the board
    }


{-| The dice currently on the board: which roll they belong to, and whether
this client watched that roll land.

`seq` keys the dice, so a new roll builds new elements and the CSS in
`.die.rolling` plays once. `watched` is what keeps the throw honest: it is
set only by a `dice_rolled` event arriving on the channel, so dice that came
out of a snapshot -- a join, a reload, a room rehydrated from its log, a
spectator sitting down in the middle of a turn -- mount already settled.
Replaying a throw that happened while nobody was looking is a lie about
what just happened at the table.

-}
type alias Roll =
    { seq : Int, watched : Bool }


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
    , plans : List ( String, List Move ) -- how each target is reached when it takes several dice
    , x : Float
    , y : Float
    }


type Msg
    = PlayMove String String
    | PlayPair Move Move
    | PlayPath (List Move) -- one checker, several dice, in order
    | SwapDice -- the two dice change places: the next die is the left one
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
    | OpenResign
    | CancelResign
    | OfferResign String -- the stakes id from the resign schema's choice
    | ToggleRecord -- open or close the move list sheet
    | ViewTurn Int -- put this turn of the record on the board, read-only
    | ViewLive -- back to the live game
    | ToggleThemes
    | PickTheme String
    | Ignore


type Out
    = NoOut
    | Send E.Value
    | SendMany (List E.Value)
    | WantRematch
    | NeedZones (List String)
    | ChoseTheme String -- this player's board colours: display only, never sent to the room


init : Model
init =
    { drag = Drag.idle
    , plans = []
    , swaps = 0
    , autoRolled = False
    , picker = Nothing
    , resigning = False
    , themesOpen = False

    -- A client starts by being told where the game is, not by watching it
    -- get there: whatever dice the first payload brings are already on the
    -- table.
    , roll = { seq = 0, watched = False }
    , recordOpen = False
    , viewing = Nothing
    , stale = False
    }


{-| Clear the interaction state (drag, pickers) without forgetting
which roll is on the board: `roll` keys the dice, and forgetting it would
replay the tumble on every tap.
-}
reset : Model -> Model
reset model =
    { init | roll = model.roll, swaps = model.swaps, recordOpen = model.recordOpen, viewing = model.viewing, stale = model.stale }


{-| Watch the channel for dice landing. A `dice_rolled` event is this client
seeing the throw happen, so it moves the board on to a new roll and marks it
watched -- the one and only way the dice are allowed to animate. A payload
without one (a join reply, a reconnect, a rehydrated room, an opponent
staging a move) leaves the roll exactly where it was, so nothing remounts
and nothing replays. Main calls this once per arriving payload.
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

        -- A payload with events is the game moving on. A viewer looking at
        -- a past turn is not yanked back; LIVE says there is something new.
        noted =
            if model.viewing /= Nothing && events /= [] then
                { model | stale = True }

            else
                model
    in
    if rolls == 0 then
        noted

    else
        -- a fresh roll: the dice are next in the order they land
        { noted | roll = { seq = noted.roll.seq + rolls, watched = True }, swaps = 0 }


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
        SwapDice ->
            ( { model | swaps = model.swaps + 1 }, NoOut )

        PlayMove from to ->
            ( reset model, Send (encodeMove from to) )

        PlayPair a b ->
            ( reset model, SendMany [ encodeMove a.from a.to, encodeMove b.from b.to ] )

        PlayPath steps ->
            ( reset model, SendMany (List.map (\m -> encodeMove m.from m.to) steps) )

        Simple name ->
            -- a turn played or a roll asked for: the next roll starts unrotated
            ( { init | roll = model.roll, recordOpen = model.recordOpen, viewing = model.viewing, stale = model.stale }, Send (Protocol.encodeAction name []) )

        Rematch ->
            ( model, WantRematch )

        DragPressed p ->
            ( { model | drag = Drag.press { origin = p.origin, item = p.color, tap = p.tap, x = p.x, y = p.y }, plans = p.plans }
            , NeedZones p.targets
            )

        DragMoved pos ->
            ( { model | drag = Drag.move pos model.drag }, NoOut )

        DragReleased pos ->
            case Drag.release pos model.drag of
                ( drag, Drag.Drop from to ) ->
                    -- A drop stages the move exactly as a tap would: one
                    -- die, or the dice in a row that reach there.
                    case List.filter (\( dest, _ ) -> dest == to) model.plans |> List.head of
                        Just ( _, steps ) ->
                            update (PlayPath steps) { model | drag = drag }

                        Nothing ->
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

        ToggleThemes ->
            ( { model | themesOpen = not model.themesOpen }, NoOut )

        PickTheme name ->
            -- The board changes under this player and nobody else: the
            -- theme never enters an action, so nothing is sent to the room.
            ( { model | themesOpen = False }, ChoseTheme name )

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

        OpenResign ->
            -- The offer is made on the live board: a past turn up on the
            -- slab has nothing legal, so the panel would never show there.
            ( { model | resigning = True, viewing = Nothing, stale = False }, NoOut )

        CancelResign ->
            ( { model | resigning = False }, NoOut )

        OfferResign stakes ->
            ( reset model
            , Send (Protocol.encodeAction "resign" [ ( "stakes", E.string stakes ) ])
            )
        ToggleRecord ->
            ( { model | recordOpen = not model.recordOpen }, NoOut )

        ViewTurn index ->
            -- The sheet closes so the board it hides can be seen; MOVES
            -- reopens it, LIVE on the board comes back to the game.
            ( { model | viewing = Just index, recordOpen = False, drag = Drag.idle, picker = Nothing, resigning = False }, NoOut )

        ViewLive ->
            ( { model | viewing = Nothing, stale = False }, NoOut )

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
    { from : String, to : String, die : Int }


{-| The legal moves, each with the die it spends (0 if the schema did not
say, which only an older server would do).
-}
moves : List Schema -> List Move
moves legal =
    legal
        |> List.filter (\s -> s.name == "move")
        |> List.filterMap
            (\s ->
                case ( choice "from" s, choice "to" s ) of
                    ( Just from, Just to ) ->
                        Just
                            { from = from
                            , to = to
                            , die = choice "die" s |> Maybe.andThen String.toInt |> Maybe.withDefault 0
                            }

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
    { moves : List Move
    , sources : List String

    -- my checkers currently at a location ("bar", "off" or a point id)
    , mineAt : String -> Int

    -- values of the dice not yet used this turn, in the order they sit on the board
    , unusedDice : List Int

    -- which way my checkers travel: -1 for white (24 down to 1), +1 for black
    , direction : Int

    -- the opponent's checkers at a point
    , theirsAt : String -> Int
    }


{-| Resolve a tap on `dest`.

  - dest is one of my movable points (or the bar): play its checker with
    the next die -- the first unused one, reading the dice left to right,
    that can play it (`nextDieMove`). An origin is an origin first, even
    when moves also land on it;
  - exactly one legal move lands on dest, a point I do not hold (or off):
    play it -- unless the dice are doubles and a second identical move
    would land a second checker there, in which case stage the pair (make
    the point);
  - exactly two legal moves from different origins land on a dest I do
    not hold (one per die, necessarily): stage both (a quick point). An
    opponent's blot there is fine: the point is made and the blot hit;
  - a point I already hold is never played by tapping it;
  - anything else is ambiguous: no auto-move. A drag reaches it.

-}
resolveTap : TapContext -> String -> Maybe Msg
resolveTap tc dest =
    let
        landing =
            List.filter (\m -> m.to == dest) tc.moves

        isSource =
            List.member dest tc.sources

        -- A tap on a destination is a quick move only onto a point I do
        -- not already hold: it makes a fresh point (on nothing, or on an
        -- opponent's blot, hit and all). Adding to a point of mine is not
        -- what a tap there means.
        fresh loc =
            tc.mineAt loc == 0
    in
    if isSource then
        nextDieMove tc dest |> Maybe.map (\m -> PlayMove m.from m.to)

    else
        case landing of
            [ m ] ->
                if dest /= "off" && isDoubles tc.unusedDice && tc.mineAt m.from >= 2 && fresh dest then
                    Just (PlayPair m m)

                else if dest == "off" || fresh dest then
                    Just (PlayMove m.from m.to)

                else
                    Nothing

            [ a, b ] ->
                if a.from /= b.from && dest /= "off" && fresh dest then
                    Just (PlayPair a b)

                else
                    Nothing

            _ ->
                Nothing


{-| Where one checker at `origin` can go using several dice in a row --
both dice either way round, or two, three or four of a double -- beyond
what a single die reaches (those are `moves`). The first step has to be
a legal move the server listed; every later step lands on a point the
opponent does not hold (two or more checkers), never off the board.

When the two orders of a non-double reach the same point by different
routes, the route whose stop hits a blot wins; when both or neither do,
the dice go left to right. A double has one route.

-}
type alias Path =
    { to : String, steps : List Move }


pathsFrom : TapContext -> String -> List Path
pathsFrom tc origin =
    let
        orderings =
            case tc.unusedDice of
                d :: rest ->
                    if rest == [] then
                        []

                    else if List.all ((==) d) rest then
                        List.range 2 (List.length tc.unusedDice) |> List.map (\n -> List.repeat n d)

                    else
                        case unique tc.unusedDice of
                            [ a, b ] ->
                                [ [ a, b ], [ b, a ] ]

                            _ ->
                                []

                [] ->
                    []

        singleTo =
            tc.moves |> List.filter (\m -> m.from == origin) |> List.map .to

        firstStep die =
            tc.moves
                |> List.filter (\m -> m.from == origin && m.die == die && m.to /= "off")
                |> List.head

        step cur die =
            String.toInt cur
                |> Maybe.map (\p -> p + tc.direction * die)
                |> Maybe.andThen
                    (\p ->
                        if p >= 1 && p <= 24 && tc.theirsAt (String.fromInt p) < 2 then
                            Just { from = cur, to = String.fromInt p, die = die }

                        else
                            Nothing
                    )

        walk dice =
            case dice of
                first :: rest ->
                    firstStep first
                        |> Maybe.andThen
                            (\m ->
                                List.foldl
                                    (\die acc ->
                                        acc |> Maybe.andThen (\steps -> step (lastTo steps) die |> Maybe.map (\n -> steps ++ [ n ]))
                                    )
                                    (Just [ m ])
                                    rest
                            )
                        |> Maybe.map (\steps -> { to = lastTo steps, steps = steps })

                [] ->
                    Nothing

        lastTo steps =
            steps |> List.reverse |> List.head |> Maybe.map .to |> Maybe.withDefault origin

        hits path =
            path.steps
                |> List.take (List.length path.steps - 1)
                |> List.any (\m -> tc.theirsAt m.to == 1)

        -- one path per destination: a hitting route first, then dice order
        pick path found =
            case List.filter (\p -> p.to == path.to) found of
                [] ->
                    found ++ [ path ]

                kept :: _ ->
                    if hits path && not (hits kept) then
                        List.map
                            (\p ->
                                if p.to == path.to then
                                    path

                                else
                                    p
                            )
                            found

                    else
                        found
    in
    orderings
        |> List.filterMap walk
        |> List.filter (\p -> not (List.member p.to singleTo))
        |> List.foldl pick []


{-| Every destination a checker at `origin` can reach: one die, or several.
-}
reachableFrom : TapContext -> String -> List String
reachableFrom tc origin =
    (tc.moves |> List.filter (\m -> m.from == origin) |> List.map .to)
        ++ (pathsFrom tc origin |> List.map .to)


{-| The move that plays `from` with the next die: the first die not yet
used this turn, in the order the dice sit on the board (rotated by taps
on them), that has a legal move from there. If the leftmost die cannot
play that checker but the one after it can, that one plays -- no need to
rotate first. Nothing if no die can.
-}
nextDieMove : TapContext -> String -> Maybe Move
nextDieMove tc from =
    tc.unusedDice
        |> List.filterMap
            (\die ->
                tc.moves
                    |> List.filter (\m -> m.from == from && m.die == die)
                    |> List.head
            )
        |> List.head


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
    , theme : String -- the board's colours, this viewer's own (`themes`)
    }


{-| The eight boards, in the order the picker lists them: the id the server
keeps (`oskol/guests/prefs.gleam`) and the name a player reads. The colours
themselves are in app.css, under the class of the same name, and are what
paints both the board and this row's swatch.
-}
themes : List ( String, String )
themes =
    [ ( "walnut", "WALNUT" )
    , ( "midnight", "MIDNIGHT" )
    , ( "forest", "FOREST FELT" )
    , ( "sand", "SAND" )
    , ( "ivory", "IVORY & EBONY" )
    , ( "cherry", "CHERRY" )
    , ( "slate", "SLATE" )
    , ( "neon", "NEON ARCADE" )
    ]


{-| The board a player who has never picked one gets: the one Oskol shipped
with. Also the fallback for a name this release does not know.
-}
defaultTheme : String
defaultTheme =
    "walnut"


themeClass : String -> String
themeClass name =
    if List.any (\( id, _ ) -> id == name) themes then
        "bg-theme-" ++ name

    else
        "bg-theme-" ++ defaultTheme


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


{-| Whose roll is on the board. `to_act` can differ (the player weighing a
double is acting on the mover's turn); the dice are always the mover's.
-}
toMoveId : Ctx -> Maybe String
toMoveId ctx =
    Protocol.sceneData (D.nullable D.string) "to_move" ctx.scene |> Maybe.withDefault Nothing


{-| The dice are thrown on the mover's side of the board: the viewer's own
half of the centre band (the right) when the roll is theirs, the other
half when it is the opponent's.
-}
moverIsMe : Ctx -> Bool
moverIsMe ctx =
    toMoveId ctx == Just (seatId ctx)


{-| The colour the dice are thrown in: the mover's checkers'.
-}
moverColor : Ctx -> String
moverColor ctx =
    toMoveId ctx |> Maybe.andThen (\id -> Protocol.findPlayer id ctx.scene) |> colorOf


view : Ctx -> Html Msg
view live =
    let
        -- A past turn on the board: the slab is drawn from that turn's
        -- snapshot with nothing legal, so no tap, drag or button lands on it;
        -- the header and the record still read the live game.
        ctx =
            case viewedTurn live of
                Just ( index, turn ) ->
                    { live
                        | scene = snapshotScene live turn
                        , legal = []
                        , finished = Nothing
                        , model = viewingModel index live.model
                    }

                Nothing ->
                    live

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

        tap =
            tapContext ctx legalMoves sources

        -- While a drag is up, everywhere its checker can be dropped shows,
        -- one die or several. Nothing lights up otherwise: a tap plays at
        -- once, so there is never a pending choice to illustrate.
        targets =
            case drag of
                Just d ->
                    reachableFrom tap d.origin

                Nothing ->
                    []

        themId =
            Protocol.opponentOf (seatId ctx) ctx.scene |> Maybe.map .id |> Maybe.withDefault ""

        board =
            { ctx = ctx
            , myColor = myColor
            , sources = sources
            , targets = targets
            , drag = drag
            , hovered = Drag.hover ctx.model.drag
            , tap = tap
            , landed = lastLanded live
            }
    in
    -- On a desktop screen (`lg` and up) the board is sized by the window's
    -- height, not by a fixed width: `.bg-page` in app.css derives every
    -- board dimension from `100dvh`, and the page becomes a column as wide
    -- as the board and its rail, so the header spans exactly that.
    div [ classList [ ( "bg-page " ++ themeClass live.theme ++ " paper h-screen-safe overflow-hidden flex flex-col items-center px-2 py-2 sm:px-6 sm:py-4 gap-2", True ), ( "is-viewing", live.model.viewing /= Nothing ) ] ]
        [ viewHeader live
        , div [ class "bg-main flex-1 min-h-0 w-full max-w-5xl lg:max-w-none grid content-center" ]
            [ div [ class "bg-stack min-w-0 flex flex-col justify-center" ]
                [ viewPlayerBar ctx them False (viewTray board themId False)
                , viewBoard board
                , viewPlayerBar ctx me True (viewTray board (seatId ctx) True)
                ]

            -- The record beside the slab: a desktop column as tall as the
            -- board, or the side column of a phone held sideways (app.css
            -- places it; below that it is the sheet behind MOVES).
            , div [ class "bg-record hidden lg:block", Html.Attributes.id "bg-record" ]
                [ div [ class "bg-record-inner" ] [ viewRecordBody live False ] ]
            ]
        , if live.model.recordOpen then
            viewRecordSheet live

          else
            text ""
        , case drag of
            Just d ->
                viewDragGhost d

            Nothing ->
                text ""
        , case ctx.finished of
            Just winners ->
                viewGameOver live winners

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


{-| The dice not yet used this turn, in the order they are next: as they
sit on the board (`diceInOrder`), so the first of them is always the
next die -- the left one.
-}
unusedDiceTokens : Ctx -> List Token
unusedDiceTokens ctx =
    diceInOrder ctx.model.swaps (Protocol.zoneTokens "dice" ctx.scene)
        |> List.filter (\t -> Protocol.tokenProp D.bool "used" t /= Just True)


{-| The dice as they sit on the board, left to right. A two-die roll
changes places on every tap on the dice (`SwapDice`), so an odd count
shows them the other way round; a double has nothing to swap and the
four sit as they were thrown. This one order drives both what the row
shows and which die a tap on a checker plays.
-}
diceInOrder : Int -> List Token -> List Token
diceInOrder swaps dice =
    case dice of
        [ a, b ] ->
            if modBy 2 swaps == 1 then
                [ b, a ]

            else
                dice

        _ ->
            dice


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
            unusedDiceTokens ctx
                |> List.filterMap (Protocol.tokenProp D.int "value")

        theirsAt point =
            Protocol.zoneTokens ("point:" ++ point) ctx.scene
                |> List.filter (\t -> Protocol.tokenProp D.string "color" t /= Just myColor)
                |> List.length
    in
    { moves = legalMoves
    , sources = sources
    , mineAt = mineAt
    , unusedDice = unusedDice
    , direction =
        if myColor == "white" then
            -1

        else
            1
    , theirsAt = theirsAt
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
    div [ class "bg-header w-full max-w-5xl lg:max-w-none flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            -- The row must survive its longest labels on the narrowest
            -- phone ("MATCH TO 7 · G1" beside CRAWFORD at 320px), so the
            -- badge is the piece that gives way: it clips rather than
            -- running under the picker on the right.
            [ span [ class "pixel text-[9px] sm:text-xs whitespace-nowrap shrink-0" ] [ text "BACKGAMMON" ]
            , span [ class "pixel text-[7px] sm:text-[9px] px-1.5 py-1 min-w-0 truncate", style "border" "2px solid var(--ink)", style "background" "#fff" ]
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
                span [ class "pixel text-[7px] sm:text-[8px] px-1.5 py-1 whitespace-nowrap shrink-0", style "border" "2px solid var(--bg-accent)", style "color" "var(--bg-accent)" ] [ text "CRAWFORD" ]

              else
                text ""
            ]
        , div [ class "flex items-center gap-2 sm:gap-3 shrink-0" ]
            [ -- On a phone the icon is the control, as the board picker's
              -- swatch is: the word would cost a match badge its game number.
              button
                [ class "bg-record-toggle pixel text-[8px] inline-flex items-center gap-1 px-1 py-0.5 lg:hidden"
                , style "color" "var(--pencil)"
                , Html.Attributes.id "bg-record-toggle"
                , title "Moves"
                , attribute "aria-label" "Moves"
                , onClick ToggleRecord
                ]
                [ listIcon, span [ class "bg-ctl-label hidden sm:inline underline" ] [ text "MOVES" ] ]
            , viewThemePicker ctx
            , if hasAction "resign" ctx.legal && ctx.finished == Nothing then
                -- A real button, not a link in the margin: the arcade plate at
                -- header scale, with a flag so it reads before its label does.
                -- It opens the offer panel (`viewResignPanel`); a resignation
                -- is stakes the opponent answers, never sent from here.
                button
                    [ class "btn-arcade plain compact pixel text-[7px] sm:text-[8px] px-1.5 py-1 sm:px-2 inline-flex items-center gap-1 shrink-0"
                    , Html.Attributes.id "bg-resign-open"
                    , title "Offer to resign"
                    , onClick OpenResign
                    ]
                    [ flagIcon, span [ class "bg-ctl-label" ] [ text "RESIGN" ] ]

              else
                text ""
            ]
        ]


{-| The board picker: the name of the board you are looking at, and the
eight to choose from. A tap on the name opens the list (and a second tap
closes it); a tap on a row takes that board. It is display only -- the pick
goes to this player's own preferences and never onto the channel -- so it
is here whatever the state of the game, spectators included.
-}
viewThemePicker : Ctx -> Html Msg
viewThemePicker ctx =
    let
        current =
            themes
                |> List.filter (\( id, _ ) -> id == ctx.theme)
                |> List.head
                |> Maybe.withDefault ( defaultTheme, "WALNUT" )
    in
    div [ class "bg-themes shrink-0" ]
        [ button
            [ class "pixel text-[8px] flex items-center gap-1 px-1 py-0.5"
            , style "color" "var(--pencil)"
            , attribute "id" "bg-theme-button"
            , attribute "aria-expanded"
                (if ctx.model.themesOpen then
                    "true"

                 else
                    "false"
                )
            , title "Board colours"
            , onClick ToggleThemes
            ]
            [ span [ class ("bg-theme-chip " ++ themeClass (Tuple.first current)) ] []

            -- On a phone the swatch is the control: the header has no room
            -- for eleven more characters, and the list names every board.
            , span [ class "bg-ctl-label hidden sm:inline" ] [ text (Tuple.second current) ]
            ]
        , if ctx.model.themesOpen then
            div [ class "bg-theme-list", attribute "id" "bg-theme-list" ]
                (List.map (viewThemeOption ctx.theme) themes)

          else
            text ""
        ]


viewThemeOption : String -> ( String, String ) -> Html Msg
viewThemeOption current ( id, label ) =
    button
        [ classList [ ( "bg-theme-option pixel text-[8px]", True ), ( "on", id == current ) ]
        , attribute "data-theme-option" id
        , onClick (PickTheme id)
        ]
        [ span [ class ("bg-theme-chip " ++ themeClass id) ] []
        , span [] [ text label ]
        ]


{-| The move list's control: four ruled lines, the first short like a
heading.
-}
listIcon : Html Msg
listIcon =
    Svg.svg
        [ SvgAttr.viewBox "0 0 12 12"
        , SvgAttr.width "12"
        , SvgAttr.height "12"
        , SvgAttr.fill "none"
        , SvgAttr.stroke "currentColor"
        , SvgAttr.strokeWidth "1.5"
        , SvgAttr.strokeLinecap "round"
        , attribute "aria-hidden" "true"
        ]
        [ Svg.path [ SvgAttr.d "M1.5 2h5M1.5 5h9M1.5 8h9M1.5 11h9" ] [] ]


{-| A small flag, drawn in one stroke of the current colour: the pole and
a notched pennant. Decorative; the label carries the meaning.
-}
flagIcon : Html Msg
flagIcon =
    Svg.svg
        [ SvgAttr.viewBox "0 0 12 12"
        , SvgAttr.width "10"
        , SvgAttr.height "10"
        , SvgAttr.fill "none"
        , SvgAttr.stroke "currentColor"
        , SvgAttr.strokeWidth "1.5"
        , SvgAttr.strokeLinecap "round"
        , SvgAttr.strokeLinejoin "round"
        , attribute "aria-hidden" "true"
        ]
        [ Svg.path [ SvgAttr.d "M2.5 11V1.5" ] []
        , Svg.path [ SvgAttr.d "M2.5 2h7l-1.6 2.5L9.5 7h-7" ] []
        ]



-- PLAYER BARS
--
-- One identity bar per player, anchored at that player's side of the board:
-- checker swatch, name, YOU, match score, pips, cube badge, that player's
-- bear-off tray and their clock. The bars are the top and bottom of the
-- table's frame; the player to act gets the sky treatment.


viewPlayerBar : Ctx -> Maybe PlayerInfo -> Bool -> Html Msg -> Html Msg
viewPlayerBar ctx player isMe tray =
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
                    [ ( "player-bar flex items-center gap-1.5 sm:gap-2 px-2 py-1.5 sm:px-3 sm:py-2", True )
                    , ( "active", active )

                    -- which side of the board this bar belongs to: in
                    -- landscape the two are placed, not stacked.
                    , ( "is-me", isMe )
                    ]
                ]
                [ div [ class ("swatch shrink-0 " ++ color), title (p.name ++ " plays " ++ color) ] []
                , span [ class "font-bold text-sm sm:text-base truncate" ] [ text p.name ]
                , if isMe && p.id == ctx.playerId then
                    span [ class "bar-tag you pixel text-[7px] px-1 py-0.5 shrink-0" ] [ text "YOU" ]

                  else
                    text ""
                , if Protocol.hasFlag "owns_cube" p then
                    span [ class "bar-tag outline pixel text-[7px] px-1 py-0.5 shrink-0", title "Owns the doubling cube" ] [ text "CUBE" ]

                  else
                    text ""
                , if Protocol.hasFlag "has_pick" p then
                    span
                        [ class "bar-tag pick pixel text-[7px] px-1 py-0.5 shrink-0 bg-has-pick"
                        , title "Still holds the dice pick"
                        ]
                        [ text "PICK" ]

                  else
                    text ""
                , if List.member p.id ctx.away then
                    span [ class "bar-tag away pixel text-[7px] shrink-0", title "Connection lost" ] [ text "AWAY" ]

                  else
                    text ""
                , span
                    [ classList [ ( "bar-turn pixel text-[8px] shrink-0", True ), ( "blink", active ), ( "invisible", not active ) ] ]
                    [ text "▶" ]
                , div [ class "flex-1" ] []
                , tray
                , span [ class "bar-pips pixel text-[7px] sm:text-[8px] whitespace-nowrap", title "Pip count" ]
                    [ text (String.fromInt (Protocol.counter "pips" p) ++ " PIPS") ]
                , span [ class "score-chip pixel text-[9px] sm:text-[10px] shrink-0", title "Match score" ]
                    [ text (String.fromInt (Protocol.counter "score" p)) ]
                , viewClockChip ctx p.id
                ]

        Nothing ->
            text ""


{-| This player's clock, inline in their bar, at every size.
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
                                [ ( "clock-chip font-mono text-xs sm:text-sm", True )
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



-- BOARD


type alias Board =
    { ctx : Ctx
    , myColor : String
    , sources : List String
    , targets : List String
    , drag : Maybe (Drag.Active String)
    , hovered : Maybe String
    , tap : TapContext
    , landed : Dict.Dict Int Int -- point -> how many checkers the last turn landed there
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

        themId =
            Protocol.opponentOf (seatId board.ctx) board.ctx.scene |> Maybe.map .id |> Maybe.withDefault ""
    in
    -- Two felt halves, each a column of six points, the centre band, six
    -- points, with the bar one unbroken column through the middle: the
    -- frame's sides are the board's own padding, so the points get every
    -- pixel of the slab's width. The cube hangs on the bar. The band
    -- splits at the bar: cube-side actions (double, take, drop, undo,
    -- play) on the left half, the dice and their roll on the right.
    div [ class "bg-board relative select-none" ]
        -- minmax(0, 6fr) so a wide button in a band can never steal width
        -- from the other half's points.
        [ div [ class "bg-grid grid grid-cols-[minmax(0,6fr)_auto_minmax(0,6fr)]" ]
            [ viewHalf board topLeft (viewLeftBand board) bottomLeft
            , viewBarColumn board themId
            , viewHalf board topRight (viewRightBand board) bottomRight
            ]
        , case ( board.ctx.model.picker, hasAction "pick" board.ctx.legal ) of
            ( Just chosen, True ) ->
                viewPicker chosen

            _ ->
                text ""
        , if board.ctx.model.resigning && hasAction "resign" board.ctx.legal then
            viewResignPanel board.ctx

          else
            text ""
        ]


{-| One felt half of the board: six points, the centre band, six points.
-}
viewHalf : Board -> List Int -> List (Html Msg) -> List Int -> Html Msg
viewHalf board top band bottom =
    div [ class "bg-half min-w-0 flex flex-col" ]
        [ div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board True) top)
        , div [ class "bg-band min-w-0 flex flex-wrap items-center justify-center gap-2 sm:gap-3 py-1" ] band
        , div [ class "bg-points grid grid-cols-6 gap-0.5 sm:gap-1" ] (List.indexedMap (viewPoint board False) bottom)
        ]


pointColor : Int -> String
pointColor index =
    if modBy 2 index == 0 then
        "var(--bg-point-a)"

    else
        "var(--bg-point-b)"


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
            [ ( "bg-point flex flex-col items-center gap-px px-px", True )
            , ( "top", isTop )
            , ( "bottom flex-col-reverse", not isTop )
            , ( "source", isSource ) -- a legal origin; paints nothing, tests and scripts read it
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
        (viewStackTinted (Dict.get point board.landed |> Maybe.withDefault 0) { lifted = liftedAt board id } tokens
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
                        , targets = reachableFrom board.tap origin |> unique
                        , plans = pathsFrom board.tap origin |> List.map (\p -> ( p.to, p.steps ))
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


{-| What the top checker of a stack carries: dimmed in place while its
origin is being dragged. Which checkers *could* move is deliberately not
marked: the board shows where a checker goes once it is picked up, never
which ones to pick.
-}
type alias Marks =
    { lifted : Bool }


noMarks : Marks
noMarks =
    { lifted = False }


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


{-| A point's stack with its top `n` checkers marked as the ones the last
turn landed there.
-}
viewStackTinted : Int -> Marks -> List Token -> List (Html Msg)
viewStackTinted n marks tokens =
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
            viewCheckerWith (i > lastIndex - n)
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
viewChecker =
    viewCheckerWith False


viewCheckerWith : Bool -> Marks -> Maybe Int -> Token -> Html Msg
viewCheckerWith justMoved marks count token =
    let
        color =
            Protocol.tokenProp D.string "color" token |> Maybe.withDefault "white"
    in
    div
        [ classList
            [ ( "checker relative shrink-0 transition-transform", True )
            , ( "white", color == "white" )
            , ( "black", color /= "white" )
            , ( "lifted", marks.lifted )
            , ( "just-moved", justMoved )
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
    -- Three rows, the halves' own: the opponent's hit checkers hang from
    -- the top of the upper row, the viewer's stand on the bottom of the
    -- lower one, and the cube sits in the middle row while centred or at
    -- the band end of its owner's row once turned (`viewCube`).
    div
        ([ class "bg-bar grid justify-items-center"
         , title "Bar"
         ]
            ++ interaction
        )
        [ div [ class "bg-bar-row theirs flex flex-col items-center justify-between gap-px w-full py-1" ]
            [ div [ class "flex flex-col items-center gap-px w-full" ] (viewStack noMarks theirTokens)
            , viewCube board Theirs
            ]
        , div [ class "bg-bar-row centre flex items-center justify-center w-full" ]
            [ viewCube board Centred ]
        , div [ class "bg-bar-row mine flex flex-col-reverse items-center justify-between gap-px w-full py-1" ]
            [ div [ class "flex flex-col-reverse items-center gap-px w-full" ]
                (viewStack { lifted = mine && liftedAt board "bar" } myTokens)
            , viewCube board Mine
            ]
        ]


{-| A bear-off tray: three holders of five, the way a real board keeps
them, laid along the player's identity bar. Borne-off checkers stack
edge-on, filling the holders from the left, with the count after them.
The viewer's tray is also where a bearing-off checker is dropped or
tapped to.
-}
viewTray : Board -> String -> Bool -> Html Msg
viewTray board ownerId isMine =
    let
        count =
            Protocol.findZone ("off:" ++ ownerId) board.ctx.scene |> Maybe.map .count |> Maybe.withDefault 0

        mine =
            ownerId == board.ctx.playerId

        color =
            colorOf (Protocol.findPlayer ownerId board.ctx.scene)

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

        side =
            if isMine then
                "mine"

            else
                "theirs"

        holder index =
            div [ class "off-holder flex flex-row items-stretch" ]
                (List.repeat (clamp 0 5 (count - 5 * index)) (div [ class ("off-stick " ++ color) ] []))
    in
    div
        ([ class ("bg-tray relative flex flex-row items-center shrink-0 " ++ side)
         , title "Borne off"
         ]
            ++ (if mine then
                    [ Html.Attributes.id (dropZoneId "off") ]

                else
                    []
               )
            ++ click
        )
        (List.map holder [ 0, 1, 2 ]
            -- empty holders say what they are on their own; the count
            -- appears once there is one, and the bar has no room to spare
            ++ (if count > 0 then
                    [ span [ class "off-count pixel text-[8px]" ] [ text (String.fromInt count) ] ]

                else
                    []
               )
            ++ (if isTarget then
                    [ dropGhost board (board.drag /= Nothing && board.hovered == Just "off") ]

                else
                    []
               )
        )



-- CENTRE BAND
--
-- Every action on the board itself: nothing to act on ever renders below
-- the fold. The band splits at the bar. Left half: cube-side decisions
-- (double, take, drop) and the staging controls (undo, play). Right half:
-- the roll button when doubling is also on offer (otherwise the turn
-- rolls itself -- see `autoRoll`), and the waiting status.
--
-- The dice themselves are thrown on the mover's side, like a real set:
-- the right half when the roll is the viewer's, the left half when it is
-- the opponent's, in the mover's colour either way (`viewRoll`). Whose
-- turn it is reads off the board with no words.


viewLeftBand : Board -> List (Html Msg)
viewLeftBand board =
    viewLiveButton board.ctx
        ++ leftButtons board.ctx
        ++ (if moverIsMe board.ctx then
                []

            else
                viewRoll board
           )


{-| The way back from a past turn: in the board's own band, where the
actions would be, so it is never off screen. It says when the game has
moved on meanwhile.
-}
viewLiveButton : Ctx -> List (Html Msg)
viewLiveButton ctx =
    case ctx.model.viewing of
        Just _ ->
            [ button
                [ classList [ ( "btn-arcade pixel text-[8px] sm:text-[9px] px-2 py-1.5 sm:px-3 sm:py-2 sky bg-live", True ), ( "stale", ctx.model.stale ) ]
                , Html.Attributes.id "bg-live"
                , onClick ViewLive
                , title "Back to the live game"
                ]
                [ text
                    (if ctx.model.stale then
                        "LIVE · NEW"

                     else
                        "LIVE"
                    )
                ]
            ]

        Nothing ->
            []


leftButtons : Ctx -> List (Html Msg)
leftButtons ctx =
    List.filterMap identity
        [ actionButton ctx "double" "plain"
        , actionButton ctx "take" "sky"
        , actionButton ctx "drop" "plain"

        -- the opponent's answer to a resignation, the stakes in the label
        , actionButton ctx "accept_resign" "sky"
        , actionButton ctx "decline_resign" "plain"
        , actionButton ctx "undo" "plain"
        , actionButton ctx "play" "sky"
        ]


{-| The resignation on offer, as the scene carries it: who offered, the
stakes, and what accepting pays.
-}
type alias ResignOffer =
    { from : String, stakes : String, points : Int }


resignOffer : Ctx -> Maybe ResignOffer
resignOffer ctx =
    Protocol.sceneData
        (D.map3 ResignOffer (D.field "from" D.string) (D.field "stakes" D.string) (D.field "points" D.int))
        "resign_offer"
        ctx.scene


viewRightBand : Board -> List (Html Msg)
viewRightBand board =
    let
        ctx =
            board.ctx

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

        anyAction =
            roll /= [] || leftButtons ctx /= []

        offer =
            resignOffer ctx

        -- A dance says its piece beside the dice (`viewRoll`), not here,
        -- and a past turn on the board is nobody's wait.
        status =
            if ctx.finished /= Nothing || noMoves || ctx.model.viewing /= Nothing then
                []

            else if anyAction then
                []

            else if Maybe.map .from offer == Just ctx.playerId then
                -- my offer stands: the opponent is deciding
                [ span [ class "pixel text-[8px] sm:text-[9px] px-1", style "color" "var(--pencil)", Html.Attributes.id "bg-resign-pending" ]
                    [ text ("RESIGNATION OFFERED (" ++ (offer |> Maybe.map (.stakes >> String.toUpper) |> Maybe.withDefault "") ++ ")…") ]
                ]

            else if pendingFrom /= Nothing && not myTurn then
                [ statusText "WAITING FOR THE TAKE…" ]

            else if not myTurn then
                [ statusText ("WAITING FOR " ++ String.toUpper waitingName) ]

            else
                []
    in
    (if moverIsMe ctx then
        viewRoll board

     else
        []
    )
        ++ roll
        ++ status


{-| The roll on the board: the mover's dice in the mover's colour, the tag
the pick twist earns, and the word when the roll played nothing.

Dice are on the board only while a roll is live: the moving phase, and a
dance (`no_moves`), where the dice that played nothing stand until the
mover passes. The projection keeps last turn's roll in the zone through
the next player's roll/double decision, but a turn that is over has no
dice to show.

-}
viewRoll : Board -> List (Html Msg)
viewRoll board =
    let
        ctx =
            board.ctx

        dice =
            if List.member ctx.scene.phase [ "moving", "no_moves" ] then
                Protocol.zoneTokens "dice" ctx.scene

            else
                []

        pickedTag =
            if List.any (\t -> Protocol.tokenProp D.bool "picked" t == Just True) dice then
                [ span
                    [ class "pixel text-[7px] px-1 py-0.5"
                    , style "background" "var(--bg-accent)"
                    , style "color" "#fff"
                    , title "These dice were picked, not rolled"
                    , Html.Attributes.id "dice-picked-tag"
                    ]
                    [ text "PICKED" ]
                ]

            else
                []

        -- The roll played nothing: the dice stand and the turn is about to
        -- pass. Both seats and any spectator see it, and it stays put until
        -- the mover presses the button, so nobody misses the dice that did
        -- it (see `no_moves` in the backgammon projection).
        noMoves =
            Protocol.sceneData D.bool "no_moves" ctx.scene |> Maybe.withDefault False

        danced =
            if noMoves && ctx.finished == Nothing then
                [ viewNoMoves (toActId ctx == Just ctx.playerId)
                    (toActId ctx |> Maybe.map ctx.nameOf |> Maybe.withDefault "OPPONENT")
                ]

            else
                []
        -- The mover's dice are a control: the next die (the one a tap on
        -- a checker plays) is the left one, and a tap on the dice swaps
        -- them. Only when there is a choice: a double is one value, and
        -- one die left is no choice. Nobody else's dice do anything.
        myMove =
            toMoveId ctx == Just ctx.playerId && ctx.scene.phase == "moving" && ctx.model.viewing == Nothing

        unused =
            unusedDiceTokens ctx

        hasChoice =
            myMove
                && (unused |> List.filterMap (Protocol.tokenProp D.int "value") |> unique |> List.length) >= 2

        next =
            if hasChoice then
                List.head unused |> Maybe.map .id

            else
                Nothing

        swaps =
            hasChoice
    in
    viewDice { color = moverColor ctx, next = next, swaps = swaps, swapped = ctx.model.swaps } ctx.model.roll dice ++ pickedTag ++ danced


{-| The dice of the turn, in the mover's colour. They are keyed by the roll that produced them, so
every new roll builds fresh elements and the CSS tumble in `.die.rolling`
plays once, for about a second, before the pips settle. Staging a move,
or undoing one, patches the same elements (the key has not moved) and
toggles `used` alone: the roll classes and the reel are a fact about the
throw, not about the die's spent state, so they never come and go with
it, and a die freed by UNDO simply lights back up (see `viewDie`).

Two of them tumble, never four: a double is a two-die roll, and the pair
it earns lands (`.die.earned`) when the tumble is over -- and takes no
room until then, so the throw does not give the double away.

None of them move unless this client watched the roll land (`Roll.watched`):
dice that arrived in a snapshot are already on the table.

For the mover, `next` names the die a tap on a checker plays -- always
the left one -- and `swaps` makes the row a control: a tap swaps the two
dice. The swap is a change of flex `order` and a short slide, never a
move in the DOM: the children stay in the order they were thrown (their
keys never move), because taking a die out of the DOM and putting it back
would restart its roll animation. Each die gets its slot (`slot-0` is the
left) and, once the dice have been swapped at all, a slide class whose
name alternates with the count (`swapped`), so every tap restarts the
slide and nothing else.

-}
viewDice : { color : String, next : Maybe String, swaps : Bool, swapped : Int } -> Roll -> List Token -> List (Html Msg)
viewDice opts roll dice =
    let
        ordered =
            diceInOrder opts.swapped dice

        slotOf token =
            case dice of
                [ _, _ ] ->
                    ordered
                        |> List.indexedMap Tuple.pair
                        |> List.filter (\( _, t ) -> t.id == token.id)
                        |> List.head
                        |> Maybe.map Tuple.first

                _ ->
                    Nothing

        slide =
            case dice of
                [ _, _ ] ->
                    if opts.swapped == 0 then
                        Nothing

                    else if modBy 2 opts.swapped == 1 then
                        Just "slid-a"

                    else
                        Just "slid-b"

                _ ->
                    Nothing
    in
    [ Keyed.node "div"
        ([ classList [ ( "dice-row flex items-center", True ), ( "swaps", opts.swaps ) ]
         , Html.Attributes.id "dice-row"
         ]
            ++ (if opts.swaps then
                    [ onClick SwapDice, title "Tap to swap the dice: the left one plays next" ]

                else
                    []
               )
        )
        (List.map
            (\token ->
                ( "roll-" ++ String.fromInt roll.seq ++ "-" ++ token.id
                , viewDie { color = opts.color, next = opts.next == Just token.id, slot = slotOf token, slide = slide } roll.watched (dieIndex token) token
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
        , style "color" "var(--bg-accent)"
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


{-| The resign panel, floated over the board's centre like the dice picker:
one button per stakes the engine offers (the `resign` schema's `stakes`
choice -- three, or a single alone under Jacoby with a centred cube), each
naming what it hands the opponent with the cube as it stands, and cancel.
A resignation is only an offer; the opponent still has to accept it.
-}
viewResignPanel : Ctx -> Html Msg
viewResignPanel ctx =
    let
        options =
            ctx.legal
                |> List.filter (\s -> s.name == "resign")
                |> List.concatMap .params
                |> List.filter (\p -> p.name == "stakes")
                |> List.concatMap
                    (\p ->
                        case p.kind of
                            Choice choices ->
                                choices

                            _ ->
                                []
                    )

        cube =
            Protocol.sceneData (D.field "value" D.int) "cube" ctx.scene |> Maybe.withDefault 1

        points id =
            cube
                * (case id of
                    "gammon" ->
                        2

                    "backgammon" ->
                        3

                    _ ->
                        1
                  )

        pts n =
            String.fromInt n
                ++ (if n == 1 then
                        " PT"

                    else
                        " PTS"
                   )
    in
    div [ class "absolute inset-x-0 top-1/2 -translate-y-1/2 z-20 flex justify-center pointer-events-none" ]
        [ div [ class "pix bg-white p-2 sm:p-3 flex flex-col items-center gap-2 pointer-events-auto", Html.Attributes.id "bg-resign-panel" ]
            [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text "RESIGN? OFFER THE OPPONENT…" ]
            , div [ class "flex flex-wrap justify-center gap-1.5 sm:gap-2" ]
                (List.map
                    (\( id, label ) ->
                        button
                            [ class "btn-arcade pixel text-[9px] px-3 py-2 plain flex flex-col items-center gap-1"
                            , Html.Attributes.id ("bg-resign-" ++ id)
                            , onClick (OfferResign id)
                            ]
                            [ text (String.toUpper label)
                            , span [ class "text-[7px]", style "color" "var(--pencil)" ] [ text (pts (points id)) ]
                            ]
                    )
                    options
                )
            , button
                [ class "btn-arcade pixel text-[9px] px-3 py-2 plain"
                , Html.Attributes.id "bg-resign-cancel"
                , onClick CancelResign
                ]
                [ text "KEEP PLAYING" ]
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


{-| A die in the mover's colour (`white` or `black`, the checkers'
classes): its settled face, plus a reel of tumbling faces laid over it.
The reel is what the roll animation shows -- CSS walks it in `steps()` for
about a second and then hides it for good (`forwards`), leaving the real
face underneath. Reduced motion drops the reel and the face is all there
ever was.

Only the dice that were actually thrown tumble. A double is still a
two-die roll, so `die:0` and `die:1` are the ones in the air; the two the
double earns (`die:2`, `die:3`) carry no reel and appear beside them when
the tumble settles.

And only a roll this client watched land moves at all: `watched` is false
for dice that came out of a snapshot, and then a die is its face and
nothing else -- no reel in the DOM, no classes, no throw to replay.

Whether a die is spent does not enter into it. A spent die keeps its
`rolling` (or `earned`) class and its reel, both long finished and held
by `forwards`; dropping them while it was used and putting them back
when UNDO freed it would re-add the class and re-create the reel, and
the browser would run the landing all over again. Only `used` changes.

-}
viewDie : { color : String, next : Bool, slot : Maybe Int, slide : Maybe String } -> Bool -> Int -> Token -> Html Msg
viewDie marks watched index token =
    let
        color =
            marks.color

        next =
            marks.next

        value =
            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 1

        used =
            Protocol.tokenProp D.bool "used" token |> Maybe.withDefault False

        -- Of a roll this client watched land, the two dice that were
        -- thrown; of one it was only told about, none. Spent or not.
        thrown =
            watched && index < 2

        earned =
            watched && index >= 2
    in
    div
        [ classList
            [ ( "die", True )
            , ( "white", color == "white" )
            , ( "black", color /= "white" )
            , ( "used", used )
            , ( "next", next && not used )
            , ( "rolling", thrown )
            , ( "earned", earned )
            , ( "slot-0", marks.slot == Just 0 )
            , ( "slot-1", marks.slot == Just 1 )
            , ( "slid-a", marks.slide == Just "slid-a" )
            , ( "slid-b", marks.slide == Just "slid-b" )
            ]
        , attribute "data-die" token.id
        ]
        (div [ class "grid grid-cols-3 grid-rows-3 w-6 h-6" ] (pips value)
            :: (if thrown then
                    [ div [ class "die-tumble", attribute "aria-hidden" "true" ]
                        [ div [ class "die-reel" ]
                            (List.map
                                (\face ->
                                    div [ class "die-frame" ]
                                        [ div [ class "grid grid-cols-3 grid-rows-3 w-6 h-6" ] (pips face) ]
                                )
                                (tumbleFaces index value)
                            )
                        ]
                    ]

                else
                    []
               )
        )


{-| Which die of the roll this token is: the projection numbers them
`die:0` upwards, in the order they were thrown (the two extra dice of a
double come last).
-}
dieIndex : Token -> Int
dieIndex token =
    token.id
        |> String.split ":"
        |> List.drop 1
        |> List.head
        |> Maybe.andThen String.toInt
        |> Maybe.withDefault 0


{-| The faces a die shows while it tumbles: five of them, none of them the
one it lands on, in a fixed order per die and value so the same roll
always looks the same (and a test can name them).

The order depends on which die of the throw this is, never on the value
alone: two dice that land on the same number are a double, and if both
walked the same reel the pair would be obvious from the first frame.
The first die counts up from its face; the second walks the same five
faces in an order that never coincides with the first at any step, so
a double tumbles like two dice and only reads as a double when it lands.

-}
tumbleFaces : Int -> Int -> List Int
tumbleFaces index value =
    let
        offsets =
            if index == 0 then
                [ 1, 2, 3, 4, 5 ]

            else
                [ 4, 1, 5, 2, 3 ]
    in
    List.map (\offset -> modBy 6 (value + offset - 1) + 1) offsets


pips : Int -> List (Html Msg)
pips value =
    List.range 0 8
        |> List.map
            (\i ->
                div [ class "flex items-center justify-center" ]
                    [ div
                        [ classList [ ( "die-pip w-1.5 h-1.5 rounded-full", True ), ( "invisible", not (List.member i (pipsOn value)) ) ] ]
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


{-| Where on the bar a cube belongs: the middle row while nobody owns it
(and while an offer is pending), else the band end of its owner's row.
-}
type CubeSlot
    = Centred
    | Theirs
    | Mine


{-| The doubling cube, in the bar's slot that is its home right now, or
nothing if this is not that slot. The cube always shows -- 64 while
centred, as tradition has it, its value once turned. A pending offer
parks it in the middle, prominent, at the value on offer (a double is
worth twice the cube; the engine turns it on the take). A cube-less
format hangs no cube anywhere.
-}
viewCube : Board -> CubeSlot -> Html Msg
viewCube board slot =
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

        home =
            if pending then
                Centred

            else
                case owner of
                    Just id ->
                        if id == seatId ctx then
                            Mine

                        else
                            Theirs

                    Nothing ->
                        Centred
    in
    if enabled && home == slot then
        div
            [ classList [ ( "cube pixel text-[10px]", True ), ( "pending", pending ) ]
            , title "Doubling cube"
            ]
            [ text shown ]

    else
        text ""


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


-- THE RECORD
--
-- What has been played, read from scene data `record` (oldest first). The
-- engine writes it -- every committed turn in the notation the books use,
-- every cube action, every game result with the running score -- and keeps
-- it in the game state, so a room rebuilt from its log shows the same list.
-- Both players and spectators get the whole thing: nothing in it is secret.
-- This view only lays it out: turns grouped by game with the result line
-- between games, and the finished games as a match history above them once
-- the match is past its first game.


type Entry
    = TurnEntry Turn
    | CubeEntry { player : String, label : String }
    | GameOverEntry GameResult


type alias Turn =
    { player : String, dice : List Int, picked : Bool, moves : List String, position : Snapshot }


{-| The board a turn left, as the engine counted it: per colour, how many
checkers on each of the 24 points (point 1 first), on the bar, borne off,
and the pip count. The client draws it; it never derives it.
-}
type alias Snapshot =
    { white : Side, black : Side }


type alias Side =
    { points : List Int, bar : Int, off : Int, pips : Int }


type alias GameResult =
    { number : Int, winner : String, result : String, points : Int, scores : List ( String, Int ) }


{-| The record as the scene carries it. An entry of a kind this client does
not know is skipped rather than failing the whole list.
-}
recordOf : Scene -> List Entry
recordOf scene =
    Protocol.sceneData (D.list entryDecoder) "record" scene
        |> Maybe.withDefault []
        |> List.filterMap identity


entryDecoder : D.Decoder (Maybe Entry)
entryDecoder =
    let
        cube label =
            D.map (\p -> Just (CubeEntry { player = p, label = label })) (D.field "player" D.string)
    in
    D.field "kind" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "turn" ->
                        D.map5 (\p d k m pos -> Just (TurnEntry (Turn p d k m pos)))
                            (D.field "player" D.string)
                            (D.field "dice" (D.list D.int))
                            (D.field "picked" D.bool)
                            (D.field "moves" (D.list D.string))
                            (D.field "position" snapshotDecoder)

                    "double" ->
                        D.map2 (\p v -> Just (CubeEntry { player = p, label = "Doubles to " ++ String.fromInt v }))
                            (D.field "player" D.string)
                            (D.field "value" D.int)

                    "take" ->
                        cube "Takes"

                    "drop" ->
                        cube "Drops"

                    "resign" ->
                        cube "Resigns"

                    "game_over" ->
                        D.map5 (\n w r pts sc -> Just (GameOverEntry (GameResult n w r pts sc)))
                            (D.field "number" D.int)
                            (D.field "winner" D.string)
                            (D.field "result" D.string)
                            (D.field "points" D.int)
                            (D.field "scores" (D.keyValuePairs D.int))

                    _ ->
                        D.succeed Nothing
            )


snapshotDecoder : D.Decoder Snapshot
snapshotDecoder =
    let
        side =
            D.map4 Side
                (D.field "points" (D.list D.int))
                (D.field "bar" D.int)
                (D.field "off" D.int)
                (D.field "pips" D.int)
    in
    D.map2 Snapshot (D.field "white" side) (D.field "black" side)



-- A PAST TURN ON THE BOARD
--
-- Tapping a turn of the record puts the board it left on the slab. The
-- board view reads a Scene, so the snapshot is turned into one: the same
-- zones and tokens the projection would send for that position (checker
-- ids counted up per colour, the turn's dice on the mover's side, the
-- bar and tray counts), the live cube, and nothing legal. It is only
-- drawing: every count comes from the engine's snapshot.


{-| The turn on the board, if a past one is.
-}
viewedTurn : Ctx -> Maybe ( Int, Turn )
viewedTurn ctx =
    case ctx.model.viewing of
        Just index ->
            recordOf ctx.scene
                |> List.drop index
                |> List.head
                |> Maybe.andThen
                    (\entry ->
                        case entry of
                            TurnEntry t ->
                                Just ( index, t )

                            _ ->
                                Nothing
                    )

        Nothing ->
            Nothing


{-| Where the turn in focus landed checkers: the turn being viewed, or live
the last turn played. Read as the points where the mover's count grew
between the position before that turn and the one it left (the engine's
snapshots), so a checker that only passed through a point is not counted.
-}
lastLanded : Ctx -> Dict.Dict Int Int
lastLanded live =
    let
        entries =
            recordOf live.scene |> List.indexedMap Tuple.pair

        focus =
            case live.model.viewing of
                Just index ->
                    Just index

                Nothing ->
                    lastTurnIndex live

        -- the position before entry `index`: the previous turn of the
        -- same game, else the opening position
        before index =
            entries
                |> List.filter (\( i, _ ) -> i < index)
                |> List.reverse
                |> List.foldl
                    (\( _, e ) acc ->
                        case ( acc, e ) of
                            ( Searching, TurnEntry t ) ->
                                Found t.position

                            ( Searching, GameOverEntry _ ) ->
                                Found opening

                            _ ->
                                acc
                    )
                    Searching
                |> (\r ->
                        case r of
                            Found p ->
                                p

                            Searching ->
                                opening
                   )

        side color snap =
            if color == "white" then
                snap.white

            else
                snap.black
    in
    case focus |> Maybe.andThen (\i -> List.drop i entries |> List.head) of
        Just ( index, TurnEntry turn ) ->
            let
                color =
                    colorOf (Protocol.findPlayer turn.player live.scene)

                prev =
                    (side color (before index)).points

                now =
                    (side color turn.position).points
            in
            List.map2 (\a b -> b - a) prev now
                |> List.indexedMap (\i d -> ( i + 1, d ))
                |> List.filter (\( _, d ) -> d > 0)
                |> Dict.fromList

        _ ->
            Dict.empty


type Search
    = Searching
    | Found Snapshot


{-| The opening position, per colour, points 1..24 (White moves 24 to 1). -}
opening : Snapshot
opening =
    let
        at pairs =
            List.range 1 24 |> List.map (\p -> pairs |> List.filter (\( q, _ ) -> q == p) |> List.map Tuple.second |> List.sum)
    in
    { white = { points = at [ ( 24, 2 ), ( 13, 5 ), ( 8, 3 ), ( 6, 5 ) ], bar = 0, off = 0, pips = 167 }
    , black = { points = at [ ( 1, 2 ), ( 12, 5 ), ( 17, 3 ), ( 19, 5 ) ], bar = 0, off = 0, pips = 167 }
    }


{-| The index of the last turn in the record, to open the review on.
-}
lastTurnIndex : Ctx -> Maybe Int
lastTurnIndex ctx =
    recordOf ctx.scene
        |> List.indexedMap Tuple.pair
        |> List.filter
            (\( _, e ) ->
                case e of
                    TurnEntry _ ->
                        True

                    _ ->
                        False
            )
        |> List.reverse
        |> List.head
        |> Maybe.map Tuple.first


{-| The model the board is drawn with while a past turn is up: no drag,
no picker, no selection, and dice keyed to the turn (a negative sequence
no live roll can have) that never tumble.
-}
viewingModel : Int -> Model -> Model
viewingModel index model =
    { model
        | drag = Drag.idle
        , plans = []
        , picker = Nothing
        , swaps = 0
        , roll = { seq = -1 - index, watched = False }
    }


snapshotScene : Ctx -> Turn -> Scene
snapshotScene ctx turn =
    let
        scene =
            ctx.scene

        sideOf player =
            if colorOf (Just player) == "white" then
                ( "white", turn.position.white )

            else
                ( "black", turn.position.black )

        -- (zone id, token) for one colour, ids counted up the way the
        -- engine's are: w1.. / b1..
        placed player =
            let
                ( color, side ) =
                    sideOf player

                prefix =
                    String.left 1 color

                checker n =
                    { id = prefix ++ String.fromInt n
                    , kind = "checker"
                    , faceUp = True
                    , position = Nothing
                    , props = E.object [ ( "color", E.string color ) ]
                    }

                spots =
                    List.repeat side.bar ("bar:" ++ player.id)
                        ++ (side.points
                                |> List.indexedMap (\i n -> List.repeat n ("point:" ++ String.fromInt (i + 1)))
                                |> List.concat
                           )
                        ++ List.repeat side.off ("off:" ++ player.id)
            in
            List.indexedMap (\i zoneId -> ( zoneId, checker (i + 1) )) spots

        all =
            List.concatMap placed scene.players

        tokensIn zoneId =
            all |> List.filter (\( z, _ ) -> z == zoneId) |> List.map Tuple.second

        zone id owner =
            let
                tokens =
                    tokensIn id
            in
            { id = id, owner = owner, layout = Protocol.Stack, tokens = tokens, count = List.length tokens }

        pointZones =
            List.range 1 24 |> List.map (\p -> zone ("point:" ++ String.fromInt p) Nothing)

        playerZones =
            scene.players |> List.concatMap (\p -> [ zone ("bar:" ++ p.id) (Just p.id), zone ("off:" ++ p.id) (Just p.id) ])

        dice =
            { id = "dice"
            , owner = Nothing
            , layout = Protocol.Row
            , tokens =
                (case turn.dice of
                    [ a, b ] ->
                        if a == b then
                            [ a, a, a, a ]

                        else
                            turn.dice

                    _ ->
                        turn.dice
                )
                    |> List.indexedMap
                        (\i v ->
                            { id = "die:" ++ String.fromInt i
                            , kind = "die"
                            , faceUp = True
                            , position = Nothing
                            , props = E.object [ ( "value", E.int v ), ( "used", E.bool False ), ( "picked", E.bool turn.picked ) ]
                            }
                        )
            , count = List.length turn.dice
            }

        -- the live cube's value and owner stand in for the turn's (the
        -- snapshot does not carry the cube), but never a double on offer
        cubeData =
            D.decodeValue (D.field "cube" (D.dict D.value)) scene.data
                |> Result.withDefault Dict.empty
                |> Dict.insert "pending_from" E.null
                |> E.dict identity identity

        cube =
            scene.zones |> List.filter (\z -> z.id == "cube")

        players =
            scene.players
                |> List.map
                    (\p ->
                        let
                            ( _, side ) =
                                sideOf p
                        in
                        { p
                            | counters =
                                p.counters
                                    |> Dict.insert "pips" side.pips
                                    |> Dict.insert "off" side.off
                                    |> Dict.insert "bar" side.bar
                            , flags = (p.flags |> List.filter (\f -> f /= "to_move")) ++ (if p.id == turn.player then [ "to_move" ] else [])
                        }
                    )

        data =
            D.decodeValue (D.dict D.value) scene.data
                |> Result.withDefault Dict.empty
                |> Dict.insert "to_move" (E.string turn.player)
                |> Dict.insert "to_act" E.null
                |> Dict.insert "dice" (E.list E.int turn.dice)
                |> Dict.insert "no_moves" (E.bool False)
                |> Dict.insert "staged" (E.int 0)
                |> Dict.insert "turn_complete" (E.bool False)
                |> Dict.insert "cube" cubeData
                |> Dict.remove "resign_offer"
                |> E.dict identity identity
    in
    { scene
        | phase = "moving"
        , players = players
        , zones = pointZones ++ playerZones ++ [ dice ] ++ cube
        , data = data
    }


{-| The record sheet a phone opens from MOVES: the same body as the desktop
column, over the board, closed by its own button or a tap outside it.
-}
viewRecordSheet : Ctx -> Html Msg
viewRecordSheet ctx =
    div [ class "fixed inset-0 z-40 flex items-end sm:items-center justify-center p-3", Html.Attributes.id "bg-record-sheet" ]
        [ div [ class "absolute inset-0", style "background" "rgba(35, 36, 58, 0.55)", onClick ToggleRecord ] []
        , div [ class "bg-record-sheet relative w-full max-w-md flex flex-col min-h-0", style "max-height" "80dvh" ]
            [ viewRecordBody ctx True ]
        ]


{-| The panel: its title (and, as a sheet, its close button), the match
history when the match is past its first game, then the turns. The turn
list is a column that reads bottom-up (`column-reverse` in app.css, so it
opens scrolled to the newest turn and stays there as turns arrive), which
is why the lines go into the DOM newest first.
-}
viewRecordBody : Ctx -> Bool -> Html Msg
viewRecordBody ctx asSheet =
    let
        entries =
            recordOf ctx.scene

        gameNumber =
            Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1

        finished =
            entries
                |> List.filterMap
                    (\e ->
                        case e of
                            GameOverEntry g ->
                                Just g

                            _ ->
                                Nothing
                    )

        isMatch =
            gameNumber > 1

        lines =
            recordLines ctx isMatch entries
    in
    div [ class "bg-record-body" ]
        [ div [ class "bg-record-head" ]
            [ span [ class "pixel text-[8px]" ] [ text "MOVES" ]
            , if ctx.model.viewing /= Nothing then
                button
                    [ classList [ ( "pixel text-[8px] underline bg-live", True ), ( "stale", ctx.model.stale ) ]
                    , style "color" "var(--pencil)"
                    , onClick ViewLive
                    ]
                    [ text
                        (if ctx.model.stale then
                            "LIVE · NEW"

                         else
                            "LIVE"
                        )
                    ]

              else
                text ""
            , if asSheet then
                button [ class "pixel text-[8px] underline", style "color" "var(--pencil)", onClick ToggleRecord ] [ text "CLOSE" ]

              else
                text ""
            ]
        , if isMatch && finished /= [] then
            div [ class "bg-record-games" ] (List.map (viewGameRow ctx) finished)

          else
            text ""
        , if lines == [] then
            div [ class "bg-record-list" ] [ span [ class "bg-record-empty" ] [ text "Nothing played yet." ] ]

          else
            div [ class "bg-record-list" ] (List.reverse lines)
        ]


{-| One finished game in the match history: which game, who won it and how,
and the score it left.
-}
viewGameRow : Ctx -> GameResult -> Html Msg
viewGameRow ctx g =
    div [ class "bg-record-game" ]
        [ span [ class "pixel text-[7px]", style "color" "var(--pencil)" ] [ text ("G" ++ String.fromInt g.number) ]
        , span [ class "font-bold truncate" ] [ text (playerName ctx g.winner) ]
        , span [ style "color" "var(--pencil)" ] [ text (g.result ++ " · " ++ pointsText g.points) ]
        , span [ class "font-bold tabular-nums ml-auto" ] [ text (scoreText ctx g.scores) ]
        ]


{-| The lines of the turn list, oldest first: a game heading at the start of
each game of a match, its turns and cube actions, and its result.
-}
recordLines : Ctx -> Bool -> List Entry -> List (Html Msg)
recordLines ctx isMatch entries =
    let
        heading game =
            div [ class "bg-record-line rl-heading" ] [ span [ class "pixel text-[7px]" ] [ text ("GAME " ++ String.fromInt game) ] ]

        step ( index, entry ) ( game, acc, fresh ) =
            let
                withHeading =
                    if fresh && isMatch then
                        acc ++ [ heading game ]

                    else
                        acc
            in
            case entry of
                GameOverEntry g ->
                    ( game + 1, withHeading ++ [ viewResultLine ctx g ], True )

                _ ->
                    ( game, withHeading ++ [ viewEntryLine ctx index entry ], False )

        ( nextGame, lines, pending ) =
            List.foldl step ( 1, [], True ) (List.indexedMap Tuple.pair entries)
    in
    if pending && isMatch && ctx.finished == Nothing then
        -- a new game has begun and nothing is played in it yet
        lines ++ [ heading nextGame ]

    else
        lines


viewEntryLine : Ctx -> Int -> Entry -> Html Msg
viewEntryLine ctx index entry =
    case entry of
        TurnEntry t ->
            div
                [ classList
                    [ ( "bg-record-line rl-turn cursor-pointer", True )
                    , ( "is-viewing", ctx.model.viewing == Just index )
                    ]
                , title (playerName ctx t.player ++ " · tap to see the board after this turn")
                , onClick (ViewTurn index)
                ]
                [ div [ class ("swatch " ++ playerColor ctx t.player) ] []
                , span [ class "dice" ]
                    [ text (t.dice |> List.map String.fromInt |> String.join "")
                    , if t.picked then
                        span [ class "picked pixel text-[6px]", title "Picked, not rolled" ] [ text "PICK" ]

                      else
                        text ""
                    ]
                , span [ class "moves" ]
                    [ text
                        (if t.moves == [] then
                            "(no play)"

                         else
                            String.join " " t.moves
                        )
                    ]
                ]

        CubeEntry c ->
            div [ class "bg-record-line rl-cube", title (playerName ctx c.player) ]
                [ div [ class ("swatch " ++ playerColor ctx c.player) ] []
                , span [ class "moves" ] [ text c.label ]
                ]

        GameOverEntry g ->
            viewResultLine ctx g


{-| A game's result between the turns: who won, how, for how much, and the
score after it. A drop or a resignation is its own line just above, so the
result only says who won.
-}
viewResultLine : Ctx -> GameResult -> Html Msg
viewResultLine ctx g =
    let
        how =
            case g.result of
                "gammon" ->
                    " wins a gammon"

                "backgammon" ->
                    " wins a backgammon"

                _ ->
                    " wins"
    in
    div [ class "bg-record-line rl-result" ]
        [ span [] [ text (playerName ctx g.winner ++ how ++ " · " ++ pointsText g.points) ]
        , span [ class "tabular-nums ml-auto" ] [ text (scoreText ctx g.scores) ]
        ]


pointsText : Int -> String
pointsText points =
    if points == 1 then
        "1 pt"

    else
        String.fromInt points ++ " pts"


{-| The scores in seat order, the way the header reads them.
-}
scoreText : Ctx -> List ( String, Int ) -> String
scoreText ctx scores =
    ctx.scene.players
        |> List.map (\p -> scores |> List.filter (\( id, _ ) -> id == p.id) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault 0)
        |> List.map String.fromInt
        |> String.join "–"


playerName : Ctx -> String -> String
playerName ctx id =
    Protocol.findPlayer id ctx.scene |> Maybe.map .name |> Maybe.withDefault (ctx.nameOf id)


playerColor : Ctx -> String -> String
playerColor ctx id =
    colorOf (Protocol.findPlayer id ctx.scene)



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
        [ div [ class "bg-card bg-white p-6 sm:p-8 max-w-md w-full text-center flex flex-col gap-4" ]
            [ span [ class "pixel text-[10px]", style "color" "var(--bg-accent)" ] [ text "GAME OVER" ]
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
            , div [ class "flex items-center justify-center gap-4" ]
                [ case lastTurnIndex ctx of
                    Just index ->
                        button [ class "pixel text-[8px] underline", style "color" "var(--pencil)", Html.Attributes.id "bg-review-moves", onClick (ViewTurn index) ] [ text "REVIEW MOVES" ]

                    Nothing ->
                        text ""
                , Html.a [ Html.Attributes.href "/", class "pixel text-[8px] underline", style "color" "var(--pencil)" ] [ text "ALL GAMES" ]
                ]
            ]
        ]
