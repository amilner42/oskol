module Games.Backgammon.View exposing (Ctx, Model, Move, Msg(..), Out(..), PlayBoard, PlayOut(..), Presence(..), Roll, Save(..), Side, Snapshot, Step, StillBoard, TapContext, Turn, autoRoll, defaultTheme, init, noteEvents, presenceFlashMs, presenceOf, resolveTap, sideDecoder, snapshotDecoder, themeBoard, themeClass, themes, tumbleFaces, update, view, viewPlay, viewStill)

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
selection to make or clear. If both dice can move the same checker, tapping
the dice first chooses the other one; later moves in the turn use the newly
staged position. Legal moves come from the `move` schemas the server sends,
so the board never invents legality.

-}

import Dict
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, style, title)
import Html.Events exposing (onClick)
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (Clock, ParamKind(..), PlayerInfo, Scene, Schema, Token)
import Svg
import Svg.Attributes as SvgAttr
import Ui.Identity as Identity
import Ui.Scrub
import Ui.Shell
import Ui.SignIn


type alias Model =
    { swaps : Int -- taps on the dice this roll: odd means the two dice have changed places
    , autoRolled : Bool -- an automatic roll has been sent for the current server state
    , resigning : Bool -- the resign panel is open: which stakes to offer
    , themesOpen : Bool -- the board-colour list in the header is showing
    , roll : Roll -- the dice on the board, and whether this client saw them land
    , matchOpen : Bool -- the match panel (the games so far) is open as a sheet over the board
    , viewing : Maybe Int -- a past turn of the game on the board (its index in the record, oldest first) is up instead of the live position
    , stale : Bool -- the game moved on while a past turn was on the board
    , still : Bool -- a board drawn for the replay (`viewStill`): no live game behind it, so no way back to one
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


type Msg
    = PlayMove String String Int
    | PlayPair Move Move
    | BearOff Int -- stage the server-owned quick path, preferring this (left) die
    | SwapDice -- the two dice change places: the next die is the left one
    | Simple String
    | Rematch
    | OpenResign
    | CancelResign
    | OfferResign String -- the stakes id from the resign schema's choice
    | ToggleMatch -- open or close the match panel
    | ViewTurn Int -- put this turn of the game on the board, read-only
    | ViewLive -- back to the live game
    | ToggleThemes
    | PickTheme String
    | OpenedSave -- the game-over card's "Save this game and your PR"
    | SaveMsg Ui.SignIn.Msg
    | Ignore


type Out
    = NoOut
    | Send E.Value
    | SendMany (List E.Value)
    | WantRematch
    | ChoseTheme String -- this player's board colours: display only, never sent to the room
    | OpenSave -- open the sign-in on the game-over card
    | ForSave Ui.SignIn.Msg -- the sign-in on the game-over card, for the page to run


init : Model
init =
    { swaps = 0
    , autoRolled = False
    , resigning = False
    , themesOpen = False

    -- A client starts by being told where the game is, not by watching it
    -- get there: whatever dice the first payload brings are already on the
    -- table.
    , roll = { seq = 0, watched = False }
    , matchOpen = False
    , viewing = Nothing
    , stale = False
    , still = False
    }


{-| Clear the interaction state (panels) without forgetting
which roll is on the board: `roll` keys the dice, and forgetting it would
replay the tumble on every tap.
-}
reset : Model -> Model
reset model =
    { init | roll = model.roll, swaps = model.swaps, matchOpen = model.matchOpen, viewing = model.viewing, stale = model.stale }


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
        -- Unless the game they were looking into has just ended: its turns
        -- leave the scene with it (they are under its result line now), so
        -- there is nothing left to hold on the board.
        newGame =
            List.any
                (\event ->
                    case event of
                        Protocol.Custom "new_game" _ ->
                            True

                        _ ->
                            False
                )
                events

        noted =
            if model.viewing /= Nothing && newGame then
                { model | viewing = Nothing, stale = False }

            else if model.viewing /= Nothing && events /= [] then
                { model | stale = True }

            else
                model
    in
    if rolls == 0 then
        noted

    else
        -- a fresh roll: the dice are next in canonical high-first order
        { noted | roll = { seq = noted.roll.seq + rolls, watched = True }, swaps = 0 }


{-| Roll for the viewer when there is nothing to ask: at the start of a
turn whose legal actions offer `roll` alone -- no `double` (Crawford, or
the opponent owns the cube) -- the choice is no choice, so the client
sends the roll itself.
Main calls this once per arriving payload. The guard is an edge:
`autoRolled` arms when the qualifying state first appears and clears
only when rolling stops being the pending action, so one turn rolls once
-- replayed payloads of the same state (reconnects) are skipped, and a
failed send cannot loop because nothing retries until the state changes.
-}
autoRoll : List Schema -> Model -> ( Model, Maybe E.Value )
autoRoll legal model =
    if hasAction "roll" legal && not (hasAction "double" legal) then
        if model.autoRolled then
            ( model, Nothing )

        else
            ( { model | autoRolled = True }, Just (Protocol.encodeAction "roll" []) )

    else if model.autoRolled then
        ( { model | autoRolled = False }, Nothing )

    else
        ( model, Nothing )


{-| What the game-over card offers a guest: nothing (signed in, or a
spectator), the one line that opens the sign-in, or the sign-in itself,
which the page runs.
-}
type Save
    = NoSave
    | SaveOffered
    | Saving Ui.SignIn.Model


update : Msg -> Model -> ( Model, Out )
update msg model =
    case msg of
        OpenedSave ->
            ( model, OpenSave )

        SaveMsg saveMsg ->
            ( model, ForSave saveMsg )

        SwapDice ->
            ( { model | swaps = model.swaps + 1 }, NoOut )

        PlayMove from to die ->
            ( reset model, Send (encodeMove from to die) )

        PlayPair a b ->
            ( reset model, SendMany [ encodeMove a.from a.to a.die, encodeMove b.from b.to b.die ] )

        BearOff firstDie ->
            ( reset model, Send (Protocol.encodeAction "bear_off" [ ( "first_die", E.string (String.fromInt firstDie) ) ]) )

        Simple name ->
            -- a turn played or a roll asked for: the next roll starts unrotated
            ( { init | roll = model.roll, matchOpen = model.matchOpen, viewing = model.viewing, stale = model.stale }, Send (Protocol.encodeAction name []) )

        Rematch ->
            ( model, WantRematch )

        ToggleThemes ->
            ( { model | themesOpen = not model.themesOpen }, NoOut )

        PickTheme name ->
            -- The board changes under this player and nobody else: the
            -- theme never enters an action, so nothing is sent to the room.
            ( { model | themesOpen = False }, ChoseTheme name )

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

        ToggleMatch ->
            ( { model | matchOpen = not model.matchOpen }, NoOut )

        ViewTurn index ->
            -- A past turn on the board: nothing else may be up over it.
            ( { model | viewing = Just index, matchOpen = False, resigning = False }, NoOut )

        ViewLive ->
            ( { model | viewing = Nothing, stale = False }, NoOut )

        Ignore ->
            ( model, NoOut )


encodeMove : String -> String -> Int -> E.Value
encodeMove from to die =
    Protocol.encodeAction "move" [ ( "from", E.string from ), ( "to", E.string to ), ( "selected_die", E.string (String.fromInt die) ) ]



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
    , canBearOff : Bool

    -- my checkers currently at a location ("bar", "off" or a point id)
    , mineAt : String -> Int

    -- values of the dice not yet used this turn, in the order they sit on the board
    , unusedDice : List Int
    }


{-| Resolve a tap on `dest`.

  - dest is one of my movable points (or the bar): play its checker with
    the next die -- the first unused one, reading the dice left to right,
    that can play it (`nextDieMove`). An origin is an origin first, even
    when moves also land on it;
  - the bear-off tray asks the engine to stage its longest legal quick path,
    preferring the visible left die;
  - exactly one legal move lands on dest, a point I do not hold (or off):
    play it -- unless the dice are doubles and a second identical move
    would land a second checker there, in which case stage the pair (make
    the point);
  - exactly two legal moves from different origins land on a dest I do
    not hold (one per die, necessarily): stage both (a quick point). An
    opponent's blot there is fine: the point is made and the blot hit;
  - a point I already hold is never played by tapping it;
  - anything else is ambiguous: tap an origin (and, when needed, swap the
    dice first) instead.

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
        nextDieMove tc dest |> Maybe.map moveMessage

    else if dest == "off" then
        if tc.canBearOff then
            List.head tc.unusedDice |> Maybe.map BearOff

        else
            Nothing

    else
        case landing of
            [ m ] ->
                if dest /= "off" && isDoubles tc.unusedDice && tc.mineAt m.from >= 2 && fresh dest then
                    Just (PlayPair m m)

                else if dest == "off" || fresh dest then
                    Just (moveMessage m)

                else
                    Nothing

            [ a, b ] ->
                if a.from /= b.from && dest /= "off" && fresh dest then
                    Just (PlayPair a b)

                else
                    Nothing

            _ ->
                Nothing


moveMessage : Move -> Msg
moveMessage move =
    PlayMove move.from move.to move.die


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
    , away : Maybe (List String) -- seated players whose connection is down; Nothing where presence is not a fact (a still board)
    , awaySince :
        String
        -> Maybe Int -- client time (ms) an absent player's drop was noticed
    , prOf :
        String
        -> Maybe Float -- a player's PR so far in this match, once a game of it has been graded
    , theme : String -- the board's colours, this viewer's own (`themes`)
    , replayHref :
        Int
        -> Maybe String -- where a finished game (by number) is replayed, for a seat
    , gamePrs :
        Int
        -> List ( String, Float ) -- each player's PR in a finished game (by number), once graded; [] until then
    , save : Save -- the sign-in the game-over card offers a guest
    , accounts : Maybe (List String) -- the seats an account owns; Nothing where that is not known (no badge at all)
    }


{-| The boards, in the order the picker lists them: the id the server
keeps (`oskol/guests/prefs.gleam`) and the name a player reads. The colours
themselves are in app.css, under the class of the same name, and are what
paints both the board and this row's swatch.
-}
themes : List ( String, String )
themes =
    [ ( "midnight", "MIDNIGHT" )
    , ( "walnut", "WALNUT" )
    , ( "forest", "FOREST FELT" )
    , ( "emerald", "EMERALD" )
    , ( "ocean", "OCEAN" )
    , ( "arctic", "ARCTIC" )
    , ( "royal", "ROYAL" )
    , ( "sunset", "SUNSET" )
    , ( "sakura", "SAKURA" )
    , ( "cherry", "CHERRY" )
    , ( "copper", "COPPER" )
    , ( "espresso", "ESPRESSO" )
    , ( "sand", "SAND" )
    , ( "ivory", "IVORY & EBONY" )
    , ( "slate", "SLATE" )
    , ( "neon", "NEON ARCADE" )
    ]


{-| The board a player who has never picked one gets: the one Oskol shipped
with. Also the fallback for a name this release does not know.
-}
defaultTheme : String
defaultTheme =
    "midnight"


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
view arrived =
    let
        -- A past turn that the record no longer has (a reconnect into a
        -- new game while one was up) is nothing to show: the board is
        -- live, and says so, rather than read-only with no way out.
        live =
            if arrived.model.viewing /= Nothing && viewedTurn arrived == Nothing then
                { arrived | model = (\m -> { m | viewing = Nothing, stale = False }) arrived.model }

            else
                arrived

        -- A past turn on the board: the slab is drawn from that turn's
        -- snapshot with nothing legal, so no tap or button lands on it;
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

        tap =
            tapContext ctx legalMoves sources

        themId =
            Protocol.opponentOf (seatId ctx) ctx.scene |> Maybe.map .id |> Maybe.withDefault ""

        board =
            { ctx = ctx
            , myColor = myColor
            , sources = sources
            , resolve = resolveTap tap
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

            -- Under the slab, not on it: the match panel's door, the arrows
            -- that look back through the game, and the way to resign.
            , viewActions live
            ]
        , if live.model.matchOpen then
            viewMatchSheet live

          else
            text ""
        , case ctx.finished of
            Just winners ->
                viewGameOver live winners

            Nothing ->
                text ""
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
    in
    { moves = legalMoves
    , sources = sources
    , canBearOff = hasAction "bear_off" ctx.legal
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
    div [ class "bg-header w-full max-w-5xl lg:max-w-none flex items-center justify-between gap-2" ]
        [ div [ class "flex items-center gap-2 sm:gap-3 min-w-0" ]
            -- The mark, then the match: the badge is the piece that gives
            -- way on the narrowest phone, clipping rather than running
            -- under the picker.
            [ Ui.Shell.mark
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
        , viewThemePicker ctx
        ]


{-| The row under the slab: the arrows that look back through the game on
the board on the outsides, and between them the match (the games so far)
and the flag (resign), icons only, all one size. A single game has no
match and no match button; the flag is there while resigning is on.
-}
viewActions : Ctx -> Html Msg
viewActions ctx =
    let
        target =
            Protocol.sceneData D.int "target" ctx.scene |> Maybe.withDefault 0

        match =
            if target /= 1 then
                [ Ui.Scrub.plate { id = "bg-match-toggle", label = "The match so far", icon = "hero-bars-3", onPress = Just ToggleMatch } ]

            else
                []

        resign =
            if hasAction "resign" ctx.legal && ctx.finished == Nothing then
                -- It opens the offer panel (`viewResignPanel`); a resignation
                -- is stakes the opponent answers, never sent from here.
                [ Ui.Scrub.plate { id = "bg-resign-open", label = "Offer to resign", icon = "hero-flag", onPress = Just OpenResign } ]

            else
                []
    in
    div [ class "bg-actions w-full max-w-5xl lg:max-w-none flex items-center justify-center", Html.Attributes.id "bg-actions" ]
        [ viewScrub ctx (match ++ resign) ]


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
            [ span [ class ("bg-theme-chip " ++ themeClass (Tuple.first current)) ] [ themeBoard ]
            , span [ class "bg-theme-chevron hero-chevron-down w-3.5 h-3.5", attribute "aria-hidden" "true" ] []
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
        [ classList [ ( "bg-theme-option", True ), ( "on", id == current ) ]
        , attribute "data-theme-option" id
        , title label
        , onClick (PickTheme id)
        ]
        [ span [ class ("bg-theme-chip " ++ themeClass id) ] [ themeBoard ]
        , span [ class "bg-theme-name" ] [ text label ]
        ]


{-| A board in miniature, painted by the very tokens the real one uses: the
frame, the felt, four points of each colour, a man of each set and the
accent. It is the swatch, so a player picks a board by looking at a board
rather than at its name.
-}
themeBoard : Html msg
themeBoard =
    let
        point x up =
            Svg.polygon
                [ SvgAttr.points
                    (if up then
                        String.fromFloat x ++ ",22 " ++ String.fromFloat (x + 4) ++ ",9 " ++ String.fromFloat (x + 8) ++ ",22"

                     else
                        String.fromFloat x ++ ",2 " ++ String.fromFloat (x + 4) ++ ",15 " ++ String.fromFloat (x + 8) ++ ",2"
                    )
                , SvgAttr.fill
                    (if up then
                        "var(--bg-point-a)"

                     else
                        "var(--bg-point-b)"
                    )
                ]
                []
    in
    Svg.svg
        [ SvgAttr.viewBox "0 0 48 24"
        , SvgAttr.width "100%"
        , SvgAttr.height "100%"
        , SvgAttr.preserveAspectRatio "none"
        , attribute "aria-hidden" "true"
        ]
        [ Svg.rect [ SvgAttr.x "0", SvgAttr.y "0", SvgAttr.width "48", SvgAttr.height "24", SvgAttr.fill "var(--bg-frame)" ] []
        , Svg.rect [ SvgAttr.x "2", SvgAttr.y "2", SvgAttr.width "44", SvgAttr.height "20", SvgAttr.fill "var(--bg-felt)" ] []
        , Svg.g [] (List.map (\i -> point (3 + toFloat i * 9) True) (List.range 0 4))
        , Svg.g [] (List.map (\i -> point (7.5 + toFloat i * 9) False) (List.range 0 3))
        , Svg.rect [ SvgAttr.x "22", SvgAttr.y "2", SvgAttr.width "4", SvgAttr.height "20", SvgAttr.fill "var(--bg-frame)" ] []
        , Svg.circle [ SvgAttr.cx "9", SvgAttr.cy "18", SvgAttr.r "3.4", SvgAttr.fill "var(--bg-checker-light)", SvgAttr.stroke "var(--bg-checker-edge)", SvgAttr.strokeWidth "0.8" ] []
        , Svg.circle [ SvgAttr.cx "39", SvgAttr.cy "6", SvgAttr.r "3.4", SvgAttr.fill "var(--bg-checker-dark)", SvgAttr.stroke "var(--bg-checker-edge)", SvgAttr.strokeWidth "0.8" ] []
        , Svg.circle [ SvgAttr.cx "24", SvgAttr.cy "12", SvgAttr.r "2.6", SvgAttr.fill "var(--bg-accent)" ] []
        ]



-- PLAYER BARS
--
-- One identity bar per player, anchored at that player's side of the board:
-- checker swatch, name, the dot that says their connection is up, their PR
-- so far in this match once a game of it is graded, the pick badge, that
-- player's bear-off tray, pips, match score and clock. The bars are the top
-- and bottom of the table's frame; the player to act gets the sky
-- treatment.
--
-- No tag says whose seat this is: the reader's own bar is the one at the
-- bottom, where they are sitting. None says who owns the cube either -- the
-- cube hangs at its owner's end of the bar on the board, which is where a
-- backgammon player looks for it (see `viewCube`).


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
                [ div [ class ("swatch shrink-0 " ++ color), title (ctx.nameOf p.id ++ " plays " ++ color) ] []
                , case ctx.accounts of
                    Just owned ->
                        Identity.badge (List.member p.id owned)

                    Nothing ->
                        text ""

                -- The room's name for the seat, not the one the game started
                -- with: an account's seat is named by its account.
                , span [ class "font-bold text-sm sm:text-base truncate" ] [ text (ctx.nameOf p.id) ]
                , viewPresenceDot ctx p.id
                , viewRating ctx p.id
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


{-| How present a player is, as their dot shows it.
-}
type Presence
    = Here
    | JustGone -- dropped a moment ago, and most of those come straight back
    | Gone


{-| How long a fresh absence flashes before the dot settles to gone. Most
disconnections inside this window are a phone changing network or a tab
waking up, and they fix themselves; saying "gone" straight away would be
wrong more often than right.
-}
presenceFlashMs : Int
presenceFlashMs =
    5000


{-| Where this player stands, from the absences the room reported and when
each was noticed. `now` moves; the moment the drop was noticed does not, so
the five seconds run from the drop and not from the last render.
-}
presenceOf : Ctx -> String -> Maybe Presence
presenceOf ctx playerId =
    case ctx.away of
        Nothing ->
            Nothing

        Just away ->
            if not (List.member playerId away) then
                Just Here

            else
                case ctx.awaySince playerId of
                    Just since ->
                        if ctx.now - since < presenceFlashMs then
                            Just JustGone

                        else
                            Just Gone

                    Nothing ->
                        Just Gone


{-| Is this player still on the other end of the line? A small dot beside
the name: steady green while their connection is up, flashing green for the
first few seconds of an absence, and a quiet grey once it has lasted.
Coming back at any point returns it to steady green.

It is drawn only where connections are a fact: a still board in the replay
knows nothing about anyone's presence (`away` is `Nothing` there), and a
dot that is always lit would be a lie.

-}
viewPresenceDot : Ctx -> String -> Html Msg
viewPresenceDot ctx playerId =
    case presenceOf ctx playerId of
        Nothing ->
            text ""

        Just presence ->
            span
                [ classList
                    [ ( "bar-dot shrink-0", True )
                    , ( "on", presence == Here )
                    , ( "lost", presence == JustGone )
                    , ( "off", presence == Gone )
                    ]
                , title
                    (case presence of
                        Here ->
                            "Connected"

                        JustGone ->
                            "Connection lost a moment ago"

                        Gone ->
                            "Connection lost"
                    )
                ]
                []


{-| This player's performance rating so far in this match, quietly beside
the name: the mean of the games of it the analysis engine has graded. The
server does the averaging and decides when there is one to do; here it is
either a number to print or nothing at all.
-}
viewRating : Ctx -> String -> Html Msg
viewRating ctx playerId =
    case ctx.prOf playerId of
        Nothing ->
            text ""

        Just pr ->
            span
                [ class "bar-pr pixel text-[7px] sm:text-[8px] shrink-0 whitespace-nowrap"
                , title "Performance rating over the graded games of this match (lower is better)"
                ]
                -- A phone's portrait bar has no room for the long form:
                -- with a clock and a bear-off count on it, "Match PR:" is
                -- what pushes the name out (a clocked phone drops the PR
                -- altogether, in app.css). The title says it in full
                -- everywhere, and a sideways phone has room for both.
                [ span [ class "hidden sm:inline" ] [ text "Match PR: " ]
                , span [ class "sm:hidden" ] [ text "PR " ]
                , text (oneDecimal pr)
                ]


{-| A PR as the books write it: one decimal, always, so "8" reads as "8.0"
and the two bars line up.
-}
oneDecimal : Float -> String
oneDecimal value =
    let
        tenths =
            round (value * 10)

        sign =
            if tenths < 0 then
                "-"

            else
                ""

        magnitude =
            abs tenths
    in
    sign ++ String.fromInt (magnitude // 10) ++ "." ++ String.fromInt (modBy 10 magnitude)


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

    -- What a tap on a location plays, if anything. The table resolves it
    -- against the server's legal moves; a still board answers nothing; a
    -- puzzle board answers only the taps its tree can honour (`viewPlay`).
    , resolve : String -> Maybe Msg
    , landed : Landed -- where the last turn landed checkers, and whose they are
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

        click =
            case board.resolve id of
                Just msg ->
                    [ onClick msg, class "cursor-pointer" ]

                Nothing ->
                    []
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
         ]
            ++ (if isSource then
                    [ attribute "data-move-source" "" ]

                else
                    []
               )
            ++ click
        )
        (viewStackTinted board.landed.color (Dict.get point board.landed.points |> Maybe.withDefault 0) tokens)


viewStack : List Token -> List (Html Msg)
viewStack tokens =
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
                (if i == lastIndex && extra > 0 then
                    Just (extra + 5)

                 else
                    Nothing
                )
                t
        )
        shown


{-| A point's stack with its top `n` checkers marked as the ones the last
turn landed there, as long as they are the mover's `color`. A point holds
one colour at a time: if its top is the other colour, what landed there
has been hit since (the viewer staging a hit on a blot the last turn left).
-}
viewStackTinted : String -> Int -> List Token -> List (Html Msg)
viewStackTinted color n tokens =
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
            viewCheckerWith (i > lastIndex - n && (Protocol.tokenProp D.string "color" t |> Maybe.withDefault "white") == color)
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
viewChecker : Maybe Int -> Token -> Html Msg
viewChecker =
    viewCheckerWith False


viewCheckerWith : Bool -> Maybe Int -> Token -> Html Msg
viewCheckerWith justMoved count token =
    let
        color =
            Protocol.tokenProp D.string "color" token |> Maybe.withDefault "white"
    in
    div
        [ classList
            [ ( "checker relative shrink-0 transition-transform", True )
            , ( "white", color == "white" )
            , ( "black", color /= "white" )
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
bottom. The viewer taps anywhere on the bar when entry is legal.
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
                case board.resolve "bar" of
                    Just msg ->
                        [ onClick msg, class "cursor-pointer" ]

                    Nothing ->
                        []

            else
                []
    in
    -- Three rows, the halves' own: the opponent's hit checkers hang from
    -- the top of the upper row, the viewer's stand on the bottom of the
    -- lower one, and the cube sits in the middle row while centred or at
    -- the band end of its owner's row once turned (`viewCube`).
    div
        ([ class "bg-bar grid justify-items-center"
         , title "Bar"
         ]
            ++ (if isSource then
                    [ attribute "data-move-source" "" ]

                else
                    []
               )
            ++ click
        )
        [ div [ class "bg-bar-row theirs flex flex-col items-center justify-between gap-px w-full py-1" ]
            [ div [ class "flex flex-col items-center gap-px w-full" ] (viewStack theirTokens)
            , viewCube board Theirs
            ]
        , div [ class "bg-bar-row centre flex items-center justify-center w-full" ]
            [ viewCube board Centred ]
        , div [ class "bg-bar-row mine flex flex-col-reverse items-center justify-between gap-px w-full py-1" ]
            [ div [ class "flex flex-col-reverse items-center gap-px w-full" ]
                (viewStack myTokens)
            , viewCube board Mine
            ]
        ]


{-| A bear-off tray: three holders of five, the way a real board keeps
them, laid along the player's identity bar. Borne-off checkers stack
edge-on, filling the holders from the left, with the count after them.
The viewer's tray is also where a bearing-off checker is tapped to.
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

        click =
            if mine then
                case board.resolve "off" of
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
    case betweenGames board.ctx of
        Just between ->
            [ viewGameResult board.ctx between ]

        Nothing ->
            leftButtons board.ctx
                ++ (if moverIsMe board.ctx then
                        []

                    else
                        viewRoll board
                   )


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
    case betweenGames board.ctx of
        Just between ->
            viewReadyUp board.ctx between

        Nothing ->
            viewRightBandInPlay board


viewRightBandInPlay : Board -> List (Html Msg)
viewRightBandInPlay board =
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

        -- ROLL appears only when it is a real choice -- against DOUBLE;
        -- with roll the sole option the client already rolled by itself.
        roll =
            if hasAction "double" ctx.legal then
                List.filterMap identity [ actionButton ctx "roll" "sky" ]

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



-- BETWEEN GAMES
--
-- A game of a match (or of unlimited play) is over and the next one waits
-- until both players say READY. The finished game's final position stays on
-- the board -- nothing on it is legal, so nothing on it answers a tap -- and
-- the band says how the game went (left half) and who is ready (right half).
-- Everything here reads the scene's `between_games` and the `ready` schema;
-- the client decides nothing about it.


{-| How the game just played ended, and who has said they are ready for
the next one (the scene's `between_games`, present only in that phase).
-}
type alias BetweenGames =
    { ready : List String, winner : String, kind : String, points : Int }


betweenGames : Ctx -> Maybe BetweenGames
betweenGames ctx =
    Protocol.sceneData
        (D.map4 BetweenGames
            (D.field "ready" (D.list D.string))
            (D.field "winner" D.string)
            (D.field "kind" D.string)
            (D.field "points" D.int)
        )
        "between_games"
        ctx.scene


{-| The result of the game just played and the match score: who won, how
many points, how, and the score as it now stands (the viewer's first; a
spectator reads it in seat order).
-}
viewGameResult : Ctx -> BetweenGames -> Html Msg
viewGameResult ctx between =
    let
        headline =
            (if between.winner == ctx.playerId then
                "YOU WIN"

             else
                String.toUpper (ctx.nameOf between.winner) ++ " WINS"
            )
                ++ " +"
                ++ String.fromInt between.points

        how =
            case between.kind of
                "dropped" ->
                    "DOUBLE DROPPED"

                other ->
                    String.toUpper other

        scoreOf p =
            String.fromInt (Protocol.counter "score" p)

        seated =
            List.any (\p -> p.id == ctx.playerId) ctx.scene.players

        score =
            case ( seated, seatOf ctx, Protocol.opponentOf (seatId ctx) ctx.scene ) of
                ( True, Just me, Just them ) ->
                    scoreOf me ++ "-" ++ scoreOf them

                _ ->
                    ctx.scene.players |> List.map scoreOf |> String.join "-"
    in
    span
        [ class "pixel text-[8px] sm:text-[9px] px-1 leading-relaxed text-center min-w-0"
        , Html.Attributes.id "bg-game-result"
        ]
        [ span [ style "color" "var(--bg-accent)" ] [ text headline ]
        , Html.br [] []
        , span [ style "color" "var(--pencil)" ] [ text (how ++ " · " ++ score) ]
        , case ctx.replayHref (Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1) of
            Just _ ->
                span [] [ Html.br [] [], replayLink ctx (Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1) "REPLAY" ]

            Nothing ->
                text ""
        ]


{-| READY for a player who has not pressed it (and, beside it, word that
the opponent already has); once pressed, who is still to press it. A
spectator reads who is ready.
-}
viewReadyUp : Ctx -> BetweenGames -> List (Html Msg)
viewReadyUp ctx between =
    let
        status s =
            span
                [ class "pixel text-[8px] sm:text-[9px] px-1 leading-relaxed text-center"
                , style "color" "var(--pencil)"
                , Html.Attributes.id "bg-ready-status"
                ]
                [ text s ]

        seated =
            List.any (\p -> p.id == ctx.playerId) ctx.scene.players

        opponentName =
            Protocol.opponentOf (seatId ctx) ctx.scene
                |> Maybe.map (.id >> ctx.nameOf >> String.toUpper)
                |> Maybe.withDefault "OPPONENT"

        theyAreReady =
            List.any (\id -> id /= ctx.playerId) between.ready
    in
    case actionButton ctx "ready" "sky" of
        Just ready ->
            ready
                :: (if theyAreReady then
                        [ status (opponentName ++ " IS READY") ]

                    else
                        []
                   )

        Nothing ->
            if seated && List.member ctx.playerId between.ready then
                [ status ("WAITING FOR " ++ opponentName) ]

            else if seated then
                []

            else
                case between.ready of
                    id :: _ ->
                        [ status (String.toUpper (ctx.nameOf id) ++ " IS READY") ]

                    [] ->
                        [ status "NEXT GAME SOON" ]


{-| The roll on the board: the mover's dice in the mover's colour, and the
word when the roll played nothing.

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
                && (unused |> List.filterMap (Protocol.tokenProp D.int "value") |> unique |> List.length)
                >= 2

        next =
            if hasChoice then
                List.head unused |> Maybe.map .id

            else
                Nothing

        swaps =
            hasChoice
    in
    viewDice { color = moverColor ctx, next = next, swaps = swaps, swapped = ctx.model.swaps } ctx.model.roll dice ++ danced


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


{-| The resign panel, floated over the board's centre:
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

            -- Where it hangs is who owns it, and that is the whole answer:
            -- no bar tag repeats it. The title says it in words.
            , title
                (if pending then
                    "Doubling cube: a double is on offer"

                 else
                    case owner of
                        Just id ->
                            "Doubling cube: " ++ ctx.nameOf id ++ " owns it"

                        Nothing ->
                            "Doubling cube: centred, either player may double"
                )
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
-- What has been played. The engine writes it -- every committed turn in the
-- notation the books use, every cube action, every game result with the
-- running score -- and keeps it in the game state, so a room rebuilt from
-- its log shows the same list. The scene carries the game on the board
-- (`record`, oldest first) and one result line per finished game (`games`);
-- a finished game's own turns come from the room's `/record` when a player
-- opens it from the match history (`Archive`). Nothing in any of it is
-- secret. This view only lays it out: one game's turns at a time, its
-- result at the end, and the finished games as a match history above.


type Entry
    = TurnEntry Turn
    | CubeEntry { player : String, label : String }
    | GameOverEntry GameResult


type alias Turn =
    { player : String, dice : List Int, moves : List String, position : Snapshot, landed : List Int }


{-| The board a turn left, as the engine counted it: per colour, how many
checkers on each of the 24 points (point 1 first), on the bar, borne off,
and the pip count; and the cube as it stood. The client draws it; it never
derives it.
-}
type alias Snapshot =
    { white : Side, black : Side, cube : { value : Int, owner : Maybe String } }


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


{-| The finished games' result lines, oldest first, as the scene carries
them (`games`).
-}
gamesOf : Scene -> List GameResult
gamesOf scene =
    Protocol.sceneData (D.list entryDecoder) "games" scene
        |> Maybe.withDefault []
        |> List.filterMap
            (\e ->
                case e of
                    Just (GameOverEntry g) ->
                        Just g

                    _ ->
                        Nothing
            )


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
                        D.map5 (\p d m pos l -> Just (TurnEntry (Turn p d m pos l)))
                            (D.field "player" D.string)
                            (D.field "dice" (D.list D.int))
                            (D.field "moves" (D.list D.string))
                            (D.field "position" snapshotDecoder)
                            -- where each checker that moved ended up; absent
                            -- from records written before it existed
                            (D.oneOf [ D.field "landed" (D.list D.int), D.succeed [] ])

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
    D.map3 Snapshot
        (D.field "white" sideDecoder)
        (D.field "black" sideDecoder)
        (D.field "cube"
            (D.map2 (\v o -> { value = v, owner = o })
                (D.field "value" D.int)
                (D.field "owner" (D.nullable D.string))
            )
        )


sideDecoder : D.Decoder Side
sideDecoder =
    D.map4 Side
        (D.field "points" (D.list D.int))
        (D.field "bar" D.int)
        (D.field "off" D.int)
        (D.field "pips" D.int)



-- A PAST TURN ON THE BOARD
--
-- Tapping a turn of the record puts the board it left on the slab. The
-- board view reads a Scene, so the snapshot is turned into one: the same
-- zones and tokens the projection would send for that position (checker
-- ids counted up per colour, the turn's dice on the mover's side, the
-- bar and tray counts, the cube as it stood), and nothing legal. It is
-- only drawing: every count comes from the engine's snapshot.


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


{-| Where the turn in focus landed checkers, as the engine recorded it:
the turn being viewed, or live the last turn of the game on the board.
Live reads the scene's own record, never the list: the list may be
showing an earlier game (`browsing`), whose last turn landed on a board
that is not this one. The colour is the mover's: only their checkers
wear the ring, so a checker of the other colour sitting on one of those
points (the viewer staging a hit on a blot that just landed) does not.
-}
lastLanded : Ctx -> Landed
lastLanded live =
    let
        focus =
            case live.model.viewing of
                Just index ->
                    recordOf live.scene |> List.drop index |> List.head

                Nothing ->
                    let
                        entries =
                            recordOf live.scene
                    in
                    lastTurnIn entries |> Maybe.andThen (\i -> entries |> List.drop i |> List.head)
    in
    case focus of
        Just (TurnEntry turn) ->
            { color = colorOf (Protocol.findPlayer turn.player live.scene)
            , points = List.foldl (\p acc -> Dict.update p (\c -> Just (1 + Maybe.withDefault 0 c)) acc) Dict.empty turn.landed
            }

        _ ->
            { color = "", points = Dict.empty }


{-| The checkers a turn landed: the mover's colour, and point to how many.
-}
type alias Landed =
    { color : String, points : Dict.Dict Int Int }


{-| The index of the last turn in the list, to open the review on.
-}
lastTurnIndex : Ctx -> Maybe Int
lastTurnIndex ctx =
    lastTurnIn (recordOf ctx.scene)


lastTurnIn : List Entry -> Maybe Int
lastTurnIn entries =
    entries
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


{-| The model the board is drawn with while a past turn is up: no live
interaction, and dice keyed to the turn (a negative sequence no live
roll can have) that never tumble.
-}
viewingModel : Int -> Model -> Model
viewingModel index model =
    { model
        | swaps = 0
        , roll = { seq = -1 - index, watched = False }
    }


snapshotScene : Ctx -> Turn -> Scene
snapshotScene ctx turn =
    stillScene ctx.scene turn


{-| A scene for a position: `scene` supplies the players, whether there is
a cube, and the data that describes the match; the position, the mover
and their roll come from `turn`. Everything the live moment says (whose
turn it is to act, a double on offer, a winner) goes.
-}
stillScene : Scene -> { a | player : String, dice : List Int, position : Snapshot } -> Scene
stillScene scene turn =
    let
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
                            , props = E.object [ ( "value", E.int v ), ( "used", E.bool False ) ]
                            }
                        )
            , count = List.length turn.dice
            }

        -- the cube as it stood after the turn: its value and owner from the
        -- snapshot (a turn is never committed with a double on offer); the
        -- live one only says whether this match has a cube at all
        cubeOwner =
            turn.position.cube.owner |> Maybe.map E.string |> Maybe.withDefault E.null

        cubeData =
            D.decodeValue (D.field "cube" (D.dict D.value)) scene.data
                |> Result.withDefault Dict.empty
                |> Dict.insert "value" (E.int turn.position.cube.value)
                |> Dict.insert "owner" cubeOwner
                |> Dict.insert "pending_from" E.null
                |> E.dict identity identity

        cube =
            scene.zones
                |> List.filter (\z -> z.id == "cube")
                |> List.map
                    (\z ->
                        { z
                            | tokens =
                                List.map
                                    (\t -> { t | props = E.object [ ( "value", E.int turn.position.cube.value ), ( "owner", cubeOwner ) ] })
                                    z.tokens
                        }
                    )

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
                            , flags =
                                (p.flags |> List.filter (\f -> f /= "to_move" && f /= "owns_cube"))
                                    ++ (if p.id == turn.player then
                                            [ "to_move" ]

                                        else
                                            []
                                       )
                                    ++ (if turn.position.cube.owner == Just p.id then
                                            [ "owns_cube" ]

                                        else
                                            []
                                       )
                        }
                    )

        -- Everything that describes the live moment goes: a resignation on
        -- offer, the pause between games (whose result the bands would
        -- print beside this turn, in place of its dice) and a winner.
        data =
            D.decodeValue (D.dict D.value) scene.data
                |> Result.withDefault Dict.empty
                |> Dict.remove "between_games"
                |> Dict.insert "winner_id" E.null
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



-- A STILL BOARD
--
-- The replay's board: the table's own slab (both identity bars, the board,
-- the trays, the cube on the bar) drawn for one position, with nothing on
-- it that answers a tap. It is the past-turn view above without a live
-- game behind it: the scene is built from the record's players and the
-- position, then drawn by the same functions the table uses.


{-| One position as the replay shows it: who sits where (`viewer` at the
bottom), the match score beside each name, whether the match has a cube,
the board's colours; then the position, whose roll it was and the dice,
the checkers that landed, and a double on offer (by whom). `key` tells
one step's dice from the next, so they never tumble.
-}
type alias StillBoard =
    { players : List { id : String, name : String, color : String }
    , viewer : String -- whose side is at the bottom
    , scores : List ( String, Int )
    , cube : Bool
    , theme : String
    , key : Int
    , position : Snapshot
    , mover : Maybe String
    , dice : List Int
    , landed : List Int
    , offer : Maybe String
    , accounts : Maybe (List String) -- the seats an account owns, for the badge beside each name
    }


viewStill : msg -> StillBoard -> Html msg
viewStill noop s =
    Html.map (\_ -> noop) (slab s stillOnly)


{-| What a slab answers, beyond being a picture. A still board answers
nothing (`stillOnly`); a puzzle board answers taps against the moves its
tree offers, and puts the staging controls in the band.
-}
type alias Taps =
    { playable : Bool -- the mover is on the clock here: their bar is active, their dice are a control
    , legal : List Schema -- the band's own actions (`undo`, `play`, `bear_off`)
    , moves : List Move -- the legal moves a tap resolves against
    , spent : Maybe (List Int) -- the dice still to play; Nothing leaves every die standing
    , swaps : Int -- taps on the dice: which one plays next
    , honours : Msg -> Bool -- a tap the caller can actually carry out
    }


stillOnly : Taps
stillOnly =
    { playable = False
    , legal = []
    , moves = []
    , spent = Nothing
    , swaps = 0
    , honours = \_ -> False
    }


{-| One position on the table's own slab: both identity bars, the board,
the trays and the cube on the bar, drawn by the functions the table uses.
`taps` decides whether anything on it answers a tap.
-}
slab : StillBoard -> Taps -> Html Msg
slab s taps =
    let
        scoreOf id =
            s.scores |> List.filter (\( p, _ ) -> p == id) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault 0

        base =
            { game = "backgammon"
            , phase = "moving"
            , viewer = Just s.viewer
            , players =
                s.players
                    |> List.map
                        (\p ->
                            { id = p.id
                            , name = p.name
                            , counters = Dict.fromList [ ( "score", scoreOf p.id ) ]
                            , flags = []
                            , data = E.object [ ( "color", E.string p.color ) ]
                            }
                        )
            , zones =
                if s.cube then
                    [ { id = "cube", owner = Nothing, layout = Protocol.Row, tokens = [ { id = "cube", kind = "cube", faceUp = True, position = Nothing, props = E.null } ], count = 1 } ]

                else
                    []
            , data = E.object [ ( "cube", E.object [ ( "enabled", E.bool s.cube ), ( "crawford", E.bool False ) ] ) ]
            }

        drawn =
            stillScene base { player = Maybe.withDefault "" s.mover, dice = s.dice, position = s.position }

        -- a double on offer parks the cube in the middle at twice its value
        offered =
            case s.offer of
                Just from ->
                    { drawn
                        | data =
                            D.decodeValue (D.dict D.value) drawn.data
                                |> Result.withDefault Dict.empty
                                |> Dict.update "cube"
                                    (Maybe.map
                                        (\cube ->
                                            D.decodeValue (D.dict D.value) cube
                                                |> Result.withDefault Dict.empty
                                                |> Dict.insert "pending_from" (E.string from)
                                                |> E.dict identity identity
                                        )
                                    )
                                |> E.dict identity identity
                    }

                Nothing ->
                    drawn

        -- A playable board is the mover's turn: their bar shows it, and
        -- nothing waits for anyone. A still one is nobody's turn.
        scene =
            if taps.playable then
                spendDice taps.spent (withSceneData "to_act" (E.string (Maybe.withDefault "" s.mover)) offered)

            else
                spendDice taps.spent offered

        ctx =
            { playerId = s.viewer
            , scene = scene
            , legal = taps.legal
            , model =
                { init
                    | still = True
                    , swaps = taps.swaps
                    , roll = { seq = -1 - s.key, watched = False }

                    -- a still board is a past turn with no way back to a
                    -- live one; a playable board is the turn itself
                    , viewing =
                        if taps.playable then
                            Nothing

                        else
                            Just s.key
                }
            , clock = Nothing
            , receivedAt = 0
            , now = 0
            , nameOf = \id -> s.players |> List.filter (\p -> p.id == id) |> List.head |> Maybe.map .name |> Maybe.withDefault id
            , rematchReady = []
            , finished = Nothing

            -- A replayed position is nobody's connection: no dot is drawn.
            , away = Nothing
            , awaySince = \_ -> Nothing
            , prOf = \_ -> Nothing
            , theme = s.theme
            , replayHref = \_ -> Nothing
            , gamePrs = \_ -> []
            , save = NoSave
            , accounts = s.accounts
            }

        me =
            seatOf ctx

        themId =
            Protocol.opponentOf (seatId ctx) ctx.scene |> Maybe.map .id |> Maybe.withDefault ""

        moverColour =
            s.mover |> Maybe.andThen (\id -> Protocol.findPlayer id scene) |> colorOf

        sources =
            taps.moves |> List.map .from |> unique

        tap =
            tapContext ctx taps.moves sources

        board =
            { ctx = ctx
            , myColor = colorOf me
            , sources = sources
            , resolve =
                \loc ->
                    resolveTap tap loc
                        |> Maybe.andThen
                            (\msg ->
                                if taps.honours msg then
                                    Just msg

                                else
                                    Nothing
                            )
            , landed =
                { color = moverColour
                , points = List.foldl (\p acc -> Dict.update p (\c -> Just (1 + Maybe.withDefault 0 c)) acc) Dict.empty s.landed
                }
            }
    in
    div [ class ("bg-still " ++ themeClass s.theme) ]
        [ div [ class "bg-stack min-w-0 flex flex-col justify-center" ]
            [ viewPlayerBar ctx (Protocol.opponentOf (seatId ctx) ctx.scene) False (viewTray board themId False)
            , viewBoard board
            , viewPlayerBar ctx me True (viewTray board (seatId ctx) True)
            ]
        ]


{-| Set one field of a scene's `data`.
-}
withSceneData : String -> E.Value -> Scene -> Scene
withSceneData field value scene =
    { scene
        | data =
            D.decodeValue (D.dict D.value) scene.data
                |> Result.withDefault Dict.empty
                |> Dict.insert field value
                |> E.dict identity identity
    }


{-| Mark the dice the turn has already spent. `stillScene` stands every die
of the roll up; given the dice still to play, one token per value still to
come stays standing, reading the roll as it was thrown, and the rest are
used -- so a double's spent dice are the last of its four.
-}
spendDice : Maybe (List Int) -> Scene -> Scene
spendDice left scene =
    case left of
        Nothing ->
            scene

        Just remaining ->
            let
                spend token ( rest, kept ) =
                    let
                        value =
                            Protocol.tokenProp D.int "value" token |> Maybe.withDefault 0

                        unspent =
                            List.member value rest
                    in
                    ( if unspent then
                        dropFirst value rest

                      else
                        rest
                    , { token | props = E.object [ ( "value", E.int value ), ( "used", E.bool (not unspent) ) ] } :: kept
                    )
            in
            { scene
                | zones =
                    scene.zones
                        |> List.map
                            (\z ->
                                if z.id == "dice" then
                                    { z | tokens = List.foldl spend ( remaining, [] ) z.tokens |> Tuple.second |> List.reverse }

                                else
                                    z
                            )
            }


{-| The list without its first occurrence of `x`.
-}
dropFirst : a -> List a -> List a
dropFirst x list =
    case list of
        [] ->
            []

        head :: rest ->
            if head == x then
                rest

            else
                head :: dropFirst x rest



-- A PLAYABLE BOARD, WITH NO ROOM BEHIND IT
--
-- The still board with its taps switched on: a puzzle hands it the moves
-- that are legal right now and the node each one reaches, and hears back
-- which node was stepped to. Every rule -- what may move, what is hit,
-- which dice are left, whether the turn is complete -- has already been
-- decided by whoever built the tree; this board only draws the position
-- it was given and reports the taps it was told to honour.


{-| One legal move and the node it reaches.
-}
type alias Step =
    { move : Move, node : String }


{-| A board that stages a turn with nothing behind it: the picture
(`still`), the moves legal from where the player has walked to, and the
moves legal one step on (`after`, which is what makes the quick-pair and
bear-off shortcuts two legal steps rather than a leap).
-}
type alias PlayBoard =
    { still : StillBoard
    , steps : List Step -- the legal moves from this node
    , after : String -> List Step -- the legal moves from the node a step reaches
    , diceLeft : List Int -- the dice still to play, in the order they sit
    , terminal : Bool -- nothing more can be played: PLAY is offered here and only here
    , canUndo : Bool -- there is a step to take back
    , swaps : Int -- taps on the dice: which one a tap on a checker plays
    }


{-| What the board tells the page. The page owns the walk: it appends the
nodes of a `Stepped` to its path, and drops the last on `Undo`, which is
how undo lands on the previous node's exact position.
-}
type PlayOut
    = Stepped (List String) -- walk on to these nodes, in order; a shortcut is two steps
    | Undo
    | Play
    | Swapped -- the dice changed places


viewPlay : PlayBoard -> Html PlayOut
viewPlay pb =
    Html.map (playOut pb)
        (slab pb.still
            { playable = True
            , legal = playLegal pb
            , moves = List.map .move pb.steps
            , spent = Just pb.diceLeft
            , swaps = pb.swaps
            , honours = \msg -> playSteps pb msg /= Nothing
            }
        )


{-| The band's buttons: the bear-off tray answers a tap only where a
checker can come off, UNDO once something is staged, PLAY once the turn is
complete.
-}
playLegal : PlayBoard -> List Schema
playLegal pb =
    let
        action name =
            { name = name, label = name, params = [] }
    in
    List.filterMap identity
        [ if List.any (\s -> s.move.to == "off") pb.steps then
            Just (action "bear_off")

          else
            Nothing
        , if pb.canUndo then
            Just (action "undo")

          else
            Nothing
        , if pb.terminal then
            Just (action "play")

          else
            Nothing
        ]


playOut : PlayBoard -> Msg -> PlayOut
playOut pb msg =
    case msg of
        SwapDice ->
            Swapped

        Simple "undo" ->
            Undo

        Simple "play" ->
            Play

        _ ->
            -- a tap the tree cannot honour is never wired up in the first
            -- place (`honours`), so this walks nowhere
            Stepped (playSteps pb msg |> Maybe.withDefault [])


{-| The nodes a tap walks to, or nothing where the tree offers no first
step at all. A quick pair and the bear-off shortcut are two steps, and the
second is taken only where it is a child of the node the first one leaves;
where it is not -- the moves cannot both be played, or the node beyond has
not been fetched yet -- the tap still plays the first, which is a legal
move either way. A tap that the tree can honour is never refused.
-}
playSteps : PlayBoard -> Msg -> Maybe (List String)
playSteps pb msg =
    case msg of
        PlayMove from to die ->
            stepTo pb.steps { from = from, to = to, die = die } |> Maybe.map List.singleton

        PlayPair a b ->
            stepTo pb.steps a
                |> Maybe.map
                    (\first ->
                        case stepTo (pb.after first) b of
                            Just second ->
                                [ first, second ]

                            Nothing ->
                                [ first ]
                    )

        BearOff die ->
            bearOffStep pb.steps die
                |> Maybe.map
                    (\first ->
                        case bearOffStep (pb.after first.node) (dropFirst first.move.die pb.diceLeft |> List.head |> Maybe.withDefault 0) of
                            Just second ->
                                [ first.node, second.node ]

                            Nothing ->
                                [ first.node ]
                    )

        _ ->
            Nothing


stepTo : List Step -> Move -> Maybe String
stepTo steps move =
    steps |> List.filter (\s -> s.move == move) |> List.head |> Maybe.map .node


{-| The checker the tray takes off: the one the preferred die bears off if
it can, else whichever can.
-}
bearOffStep : List Step -> Int -> Maybe Step
bearOffStep steps die =
    let
        off =
            List.filter (\s -> s.move.to == "off") steps
    in
    case List.filter (\s -> s.move.die == die) off of
        chosen :: _ ->
            Just chosen

        [] ->
            List.head off


{-| The door to a finished game's replay page, for a seat (the page opens on
its token). A link, so it is a page the browser can open in a tab; a tap
on it opens the replay rather than the row it sits in.
-}
replayLink : Ctx -> Int -> String -> Html Msg
replayLink ctx number label =
    case ctx.replayHref number of
        Just href ->
            Html.a
                [ Html.Attributes.href href
                , class "bg-replay-link pixel text-[7px] underline shrink-0"
                , attribute "data-replay" (String.fromInt number)
                , title ("Replay game " ++ String.fromInt number ++ ", with the engine's analysis")
                , Html.Events.stopPropagationOn "click" (D.succeed ( Ignore, True ))
                ]
                [ text label ]

        Nothing ->
            text ""


{-| The match panel: a column per player headed by their name, their
points so far and their match PR; under it one line per game, newest
first, the game on the board at the top. Opens over the board (the row's
MATCH) and closes on its ✕ or its backdrop.
-}
viewMatchSheet : Ctx -> Html Msg
viewMatchSheet ctx =
    let
        gameNumber =
            Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1

        target =
            Protocol.sceneData D.int "target" ctx.scene |> Maybe.withDefault 0

        finished =
            gamesOf ctx.scene

        heading =
            if target <= 0 then
                "UNLIMITED"

            else
                "MATCH TO " ++ String.fromInt target

        matchPrs =
            ctx.scene.players |> List.filterMap (\p -> ctx.prOf p.id |> Maybe.map (Tuple.pair p.id))

        bestMatchPr =
            matchPrs |> List.sortBy Tuple.second |> List.head |> Maybe.map Tuple.first

        column player =
            let
                score =
                    Protocol.counter "score" player
            in
            div [ class "bg-match-col" ]
                [ span [ class "bg-match-col-name truncate" ] [ text (ctx.nameOf player.id) ]
                , span [ class "bg-match-col-score pixel tabular-nums" ] [ text (String.fromInt score) ]
                , span [ class "bg-match-col-pr tabular-nums inline-flex items-center gap-1" ]
                    [ if bestMatchPr == Just player.id && List.length matchPrs > 1 then
                        span [ class "hero-trophy w-3.5 h-3.5", title "The better match PR", attribute "aria-label" "best" ] []

                      else
                        text ""
                    , text
                        (case ctx.prOf player.id of
                            Just pr ->
                                "PR " ++ oneDecimal pr

                            Nothing ->
                                "PR …"
                        )
                    ]
                ]

        inPlay =
            if betweenGames ctx /= Nothing || ctx.finished /= Nothing then
                []

            else
                [ div [ class "bg-match-row is-live", attribute "data-game" (String.fromInt gameNumber) ]
                    [ span [ class "bg-match-n pixel text-[7px]" ] [ text ("G" ++ String.fromInt gameNumber) ]
                    , span [ class "bg-match-live font-bold flex-1 text-center" ] [ text "In play" ]

                    -- this is the game on the board: the dot says so
                    , span [ class "bg-match-analysis inline-flex items-center justify-center", attribute "aria-hidden" "true" ] [ span [ class "bg-match-here" ] [] ]
                    ]
                ]
    in
    div [ class "fixed inset-0 z-40 flex items-end sm:items-center justify-center p-3", Html.Attributes.id "bg-match-sheet" ]
        [ div [ class "absolute inset-0", style "background" "rgba(35, 36, 58, 0.55)", onClick ToggleMatch ] []
        , div [ class "bg-match relative w-full max-w-md flex flex-col min-h-0" ]
            [ div [ class "bg-match-head" ]
                [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text heading ]
                , button
                    [ class "bg-match-close"
                    , Html.Attributes.id "bg-match-close"
                    , attribute "aria-label" "Close"
                    , onClick ToggleMatch
                    ]
                    [ text "✕" ]
                ]
            , div [ class "bg-match-cols bg-match-row" ]
                [ span [ class "bg-match-n" ] []
                , div [ class "bg-match-cells" ] (List.map column ctx.scene.players)
                , span [ class "bg-match-analysis-gap" ] []
                ]
            , if finished == [] && inPlay == [] then
                div [ class "bg-match-list" ] [ span [ class "bg-match-empty" ] [ text "Nothing played yet." ] ]

              else
                div [ class "bg-match-list" ] (inPlay ++ List.map (viewMatchRow ctx) (List.reverse finished))
            ]
        ]


{-| One finished game on one line, under the players' columns: a cell per
player, the winner's carrying the points in green (how they came is the
chip's tooltip), and in each the player's PR for the game, the better one
with a trophy beside it. At the right the door to its analysis.
-}
viewMatchRow : Ctx -> GameResult -> Html Msg
viewMatchRow ctx g =
    let
        how =
            case g.result of
                "gammon" ->
                    "gammon"

                "backgammon" ->
                    "backgammon"

                "dropped" ->
                    "dropped"

                _ ->
                    "single"

        prs =
            ctx.gamePrs g.number

        prOf id =
            prs |> List.filter (\( p, _ ) -> p == id) |> List.head |> Maybe.map Tuple.second

        best =
            prs |> List.sortBy Tuple.second |> List.head |> Maybe.map Tuple.first

        cell player =
            let
                won =
                    player.id == g.winner

                played_best =
                    best == Just player.id && List.length prs > 1
            in
            div [ classList [ ( "bg-match-cell", True ), ( "win", won ), ( "best", played_best ) ] ]
                [ if won then
                    span [ class "bg-match-points pixel", title how ] [ text ("+" ++ String.fromInt g.points) ]

                  else
                    text ""
                , span [ class "bg-match-pr tabular-nums inline-flex items-center gap-1" ]
                    [ if played_best then
                        -- the better PR of the game: a trophy, in the same grey
                        span [ class "hero-trophy w-3.5 h-3.5", title "The better PR this game", attribute "aria-label" "best" ] []

                      else
                        text ""
                    , text
                        (case prOf player.id of
                            Just value ->
                                oneDecimal value

                            Nothing ->
                                "…"
                        )
                    ]
                ]
    in
    case ctx.replayHref g.number of
        Just href ->
            Html.a
                [ Html.Attributes.href href
                , class "bg-match-row bg-match-door"
                , attribute "data-game" (String.fromInt g.number)
                , attribute "data-replay" (String.fromInt g.number)
                , title ("Game " ++ String.fromInt g.number ++ ": the analysis")
                ]
                [ span [ class "bg-match-n pixel text-[7px]" ] [ text ("G" ++ String.fromInt g.number) ]
                , div [ class "bg-match-cells" ] (List.map cell ctx.scene.players)
                , span [ class "bg-match-analysis inline-flex items-center", attribute "aria-hidden" "true" ] [ span [ class "hero-magnifying-glass w-4 h-4" ] [] ]
                ]

        Nothing ->
            div [ class "bg-match-row", attribute "data-game" (String.fromInt g.number) ]
                [ span [ class "bg-match-n pixel text-[7px]" ] [ text ("G" ++ String.fromInt g.number) ]
                , div [ class "bg-match-cells" ] (List.map cell ctx.scene.players)
                , span [ class "bg-match-analysis-gap" ] []
                ]


{-| The four arrows that look back through the game on the board: to its
first turn, one back, one forward, and to the live position. Nothing is
sent anywhere; a past turn is a picture (`viewedTurn`). Always there, so
the control is learned before it is needed; greyed while there is nothing
to step to.
-}
viewScrub : Ctx -> List (Html Msg) -> Html Msg
viewScrub ctx middle =
    let
        turns =
            recordOf ctx.scene
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( i, e ) ->
                        case e of
                            TurnEntry _ ->
                                Just i

                            _ ->
                                Nothing
                    )

        current =
            ctx.model.viewing

        before =
            case current of
                Just i ->
                    List.filter (\t -> t < i) turns

                Nothing ->
                    turns

        after =
            case current of
                Just i ->
                    List.filter (\t -> t > i) turns

                Nothing ->
                    []

        toLive =
            if current == Nothing then
                Nothing

            else
                Just ViewLive
    in
    if ctx.model.still then
        text ""

    else
        Ui.Scrub.row { id = "bg-scrub", stale = ctx.model.stale }
            { first =
                ( "bg-scrub-first"
                , List.head turns
                    |> Maybe.andThen
                        (\i ->
                            if Just i == current then
                                Nothing

                            else
                                Just (ViewTurn i)
                        )
                )
            , back = ( "bg-scrub-back", List.reverse before |> List.head |> Maybe.map ViewTurn )
            , forward =
                ( "bg-scrub-forward"
                , case List.head after of
                    Just i ->
                        Just (ViewTurn i)

                    Nothing ->
                        toLive
                )
            , last = ( "bg-scrub-live", toLive )
            }
            middle


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
                |> List.map (\p -> ctx.nameOf p.id ++ " " ++ String.fromInt (Protocol.counter "score" p))
                |> String.join " · "
    in
    -- The layer scrolls when the card is taller than the screen (a phone on
    -- its side, the sign-in open in it); short cards stay centred.
    div [ class "fixed inset-0 z-50 overflow-y-auto", style "background" "rgba(35, 36, 58, 0.55)" ]
        [ div [ class "min-h-full flex items-center justify-center p-4" ]
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
                , case ctx.save of
                    NoSave ->
                        text ""

                    -- What the player already has, named: this game, and the
                    -- PR the engine is about to give them for it.
                    SaveOffered ->
                        button
                            [ Html.Attributes.type_ "button"
                            , Html.Attributes.id "save-offer"
                            , class "signin-offer text-[15px] self-center"
                            , onClick OpenedSave
                            ]
                            [ text "Save this game and your PR" ]

                    Saving signIn ->
                        div [ class "text-left border-t pt-4", style "border-color" "rgba(35, 36, 58, 0.12)" ]
                            [ Html.map SaveMsg (Ui.SignIn.view signIn) ]
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
                    , case ctx.replayHref (Protocol.sceneData D.int "game_number" ctx.scene |> Maybe.withDefault 1) of
                        Just href ->
                            Html.a [ Html.Attributes.href href, class "pixel text-[8px] underline", style "color" "var(--pencil)", Html.Attributes.id "bg-replay" ] [ text "REPLAY" ]

                        Nothing ->
                            text ""
                    , Html.a [ Html.Attributes.href "/", class "pixel text-[8px] underline", style "color" "var(--pencil)" ] [ text "ALL GAMES" ]
                    ]
                ]
            ]
        ]
