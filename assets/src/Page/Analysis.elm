port module Page.Analysis exposing
    ( Model, Msg(..), Brush(..), Button(..), Target(..), Press, Asking(..)
    , init, update, view, title, withSession
    , paint, line, analyzable, rolls, longPressMs, defaultMatch
    , puzzleGone
    )

{-| `/analysis` -- the analysis board. A position set up by tapping, with
every setting the engine's question needs, and ANALYZE.

**Setting up.** Over the board a row of three brushes: a white checker, a
black checker, an x. A tap (or a left click) on a point adds one checker of
the brush's colour; where the point holds the other colour it takes one of
those off instead, so a stack is painted over (black 3, 2, 1, then white 1,
2). The x takes one off whatever is there. A right click on a desktop and a
long press on a phone (`longPressMs`, without sliding) are the other
colour's brush -- so with the white brush, left adds White and right adds
Black, the way XG's editor is driven. The two halves of the bar take the
same taps; the trays are what is left of fifteen and take none. A
sixteenth checker of a colour is refused, and that colour's tray flashes
once where it is.

**The settings strip.** Who is to play; what is asked (a roll to play,
picked from a sheet of the 21; DOUBLE?; TAKE?); the cube's value and owner
(the owner is the middle at 1, and a cube turned off 1 goes to whoever is
acting, so the strip never builds a cube `check` refuses); unlimited play
or a match to 1..25 with both scores and Crawford, which can only be on
while somebody is one away. Then OPENING, CLEAR, FLIP, and the position as
an XGID: COPY, and IMPORT from one.

**The line under the strip** is the first thing `Setup.check` says stops
the position being asked, in the server's words; ANALYZE is disabled while
it says anything. Pressing it is `PressedAnalyze`, the seam the verdict
(analysis-page-verdict) fills: the answer's panel is `#an-panel`, under the
board on a phone and beside it otherwise.

**Doors in.** `/analysis` is the opening position, White to play, no roll
picked. `?xgid=` opens on that id, whoever is to play: an id with Black on
roll stays Black to play, so COPY gives back the id that was pasted (FLIP
turns it round). `?p=<id>` reads the puzzle (`GET /papi/puzzles/:id`, no
engine) and opens it as its page shows it (`Setup.fromQuestion`); a puzzle
that is not there opens the opening position and says so.

Nothing moves when anything changes: every control has a fixed-size slot,
the line under the strip is a fixed height, and the sheet and the import
dialog float over the page.

-}

import Api
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Match, Setup)
import Games.Backgammon.View as Board
import Games.Backgammon.Xgid as Xgid
import Html exposing (Html, button, div, input, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, id, readonly, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Process
import Session exposing (Session)
import Task
import Ui.Dialog


{-| Write `text` to the clipboard, or, where the browser will not, select
the position id's field so the reader can copy it themselves.
-}
port copyText : String -> Cmd msg



-- MODEL


type alias Model =
    { session : Session
    , setup : Setup
    , brush : Brush
    , press : Maybe Press -- a finger or a button down on a place of the board
    , presses : Int -- every press is numbered, so a long-press timer knows its own
    , rolling : Bool -- the sheet of the 21 rolls is open
    , lastRoll : Maybe ( Int, Int ) -- the roll ROLL goes back to after DOUBLE? or TAKE?
    , lastMatch : Match -- the match MATCH TO goes back to after UNLIMITED
    , importOpen : Bool
    , importText : String
    , importError : Maybe String
    , refused : Maybe ( Color, Int ) -- the colour a sixteenth was refused for, and how many times: its tray flashes
    , notice : Maybe String -- a door in that could not open what it was asked to; gone at the first edit
    , loading : Bool -- `?p=` is being read
    , copied : Int -- COPY presses; the label says COPIED for a moment after each
    , copiedShown : Bool

    -- The slots the tickets after this one fill: the engine's answer for
    -- the position on the board (analysis-page-verdict), and the line
    -- played out from it (analysis-play-out). Every edit clears `ask`.
    , ask : Asking
    , line : List Setup
    }


{-| What has been asked about the position on the board. Nothing yet: the
verdict's ticket adds the rest.
-}
type Asking
    = NotAsked


type Brush
    = Paint Color
    | Erase


{-| The main button (a tap, a left click) or the other one (a right click,
a long press).
-}
type Button
    = Primary
    | Secondary


type Target
    = Point Int
    | Bar Color


type alias Press =
    { zone : String
    , touch : Bool
    , x : Float
    , y : Float
    , seq : Int
    , long : Bool -- the long press has already acted: lifting does nothing
    }


{-| How long a finger stays down, without sliding, to be the other brush.
-}
longPressMs : Float
longPressMs =
    500


{-| How far a finger may slide before it is a scroll, not a press.
-}
slop : Float
slop =
    10


{-| The match MATCH TO opens on.
-}
defaultMatch : Match
defaultMatch =
    { length = 7, white = 0, black = 0, crawford = False }


{-| "That puzzle is gone."
-}
puzzleGone : String
puzzleGone =
    "That puzzle is gone."


init : Session -> { xgid : Maybe String, puzzle : Maybe String } -> ( Model, Cmd Msg )
init session door =
    let
        base =
            { session = session
            , setup = Setup.opening
            , brush = Paint White
            , press = Nothing
            , presses = 0
            , rolling = False
            , lastRoll = Nothing
            , lastMatch = defaultMatch
            , importOpen = False
            , importText = ""
            , importError = Nothing
            , refused = Nothing
            , notice = Nothing
            , loading = False
            , copied = 0
            , copiedShown = False
            , ask = NotAsked
            , line = []
            }
    in
    case ( door.xgid, door.puzzle ) of
        ( Just raw, _ ) ->
            case Xgid.decode raw of
                Ok setup ->
                    ( remembered { base | setup = setup }, Cmd.none )

                Err reason ->
                    ( { base | notice = Just reason }, Cmd.none )

        ( Nothing, Just puzzleId ) ->
            ( { base | loading = True }
            , Api.get session ("/papi/puzzles/" ++ puzzleId) Puzzle.decoder GotPuzzle
            )

        ( Nothing, Nothing ) ->
            ( base, Cmd.none )


{-| A setup that came in whole (an id, a puzzle): ROLL and MATCH TO go back
to what it had.
-}
remembered : Model -> Model
remembered model =
    { model
        | lastRoll =
            case model.setup.ask of
                Move (Just roll) ->
                    Just roll

                _ ->
                    model.lastRoll
        , lastMatch = Maybe.withDefault model.lastMatch model.setup.match
    }


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


title : Model -> String
title _ =
    "Analysis"


theme : Model -> String
theme model =
    Session.pref "backgammon_theme" model.session |> Maybe.withDefault Board.defaultTheme



-- DERIVED


{-| The fixed line under the strip: what stops the position being asked,
or why the page did not open on what it was asked to, or nothing.
-}
line : Model -> Maybe String
line model =
    if model.loading then
        Just "Opening the puzzle…"

    else
        case model.notice of
            Just notice ->
                Just notice

            Nothing ->
                Setup.check model.setup


{-| ANALYZE is enabled: the position can be asked as it stands.
-}
analyzable : Model -> Bool
analyzable model =
    not model.loading && Setup.check model.setup == Nothing


{-| The 21 rolls, high die first, as the sheet lays them out: one row per
high die, its doubles at the end.
-}
rolls : List (List ( Int, Int ))
rolls =
    List.range 1 6
        |> List.map (\high -> List.range 1 high |> List.map (\low -> ( high, low )))



-- PAINTING


{-| What a press on `target` does with `brush`, or the colour it would have
put a sixteenth of on the board (`Err`), which is refused.

The other button is the other colour's brush; with the x, both buttons
take one off.

-}
paint : Brush -> Button -> Target -> Setup -> Result Color Setup
paint brush button target setup =
    let
        effective =
            case ( brush, button ) of
                ( Paint color, Secondary ) ->
                    Paint (Setup.other color)

                _ ->
                    brush

        full color =
            onBoard color setup >= 15
    in
    case target of
        Point p ->
            let
                n =
                    pointCount p setup

                set count =
                    Ok
                        { setup
                            | points =
                                List.indexedMap
                                    (\i c ->
                                        if i == p - 1 then
                                            count

                                        else
                                            c
                                    )
                                    setup.points
                        }
            in
            case effective of
                Erase ->
                    set (n - sign n)

                Paint color ->
                    if n /= 0 && colorOf n /= color then
                        -- painting over the other colour: one of theirs off
                        set (n - sign n)

                    else if full color then
                        Err color

                    else
                        set (n + unit color)

        Bar barColor ->
            let
                n =
                    barCount barColor setup

                set count =
                    case barColor of
                        White ->
                            Ok { setup | whiteBar = count }

                        Black ->
                            Ok { setup | blackBar = count }
            in
            case effective of
                Erase ->
                    set (max 0 (n - 1))

                Paint color ->
                    if color /= barColor then
                        -- the other colour's half: painting over it
                        set (max 0 (n - 1))

                    else if full color then
                        Err color

                    else
                        set (n + 1)


onBoard : Color -> Setup -> Int
onBoard color setup =
    case color of
        White ->
            15 - Setup.offWhite setup

        Black ->
            15 - Setup.offBlack setup


pointCount : Int -> Setup -> Int
pointCount p setup =
    setup.points |> List.drop (p - 1) |> List.head |> Maybe.withDefault 0


barCount : Color -> Setup -> Int
barCount color setup =
    case color of
        White ->
            setup.whiteBar

        Black ->
            setup.blackBar


sign : Int -> Int
sign n =
    if n > 0 then
        1

    else if n < 0 then
        -1

    else
        0


colorOf : Int -> Color
colorOf n =
    if n > 0 then
        White

    else
        Black


unit : Color -> Int
unit color =
    case color of
        White ->
            1

        Black ->
            -1


targetOf : String -> Maybe Target
targetOf zone =
    case String.split ":" zone of
        [ "point", p ] ->
            String.toInt p |> Maybe.map Point

        [ "bar", "white" ] ->
            Just (Bar White)

        [ "bar", "black" ] ->
            Just (Bar Black)

        _ ->
            Nothing


zoneId : String -> String
zoneId zone =
    case targetOf zone of
        Just (Point p) ->
            "an-pt-" ++ String.fromInt p

        Just (Bar color) ->
            "an-bar-" ++ Setup.colorId color

        Nothing ->
            "an-" ++ zone



-- UPDATE


type Msg
    = PickedBrush Brush
    | Pointer String Board.EditEvent
    | LongPressed Int
    | Pressed Button Target
    | PickedTurn Color
    | OpenedRolls
    | ClosedRolls
    | PickedRoll ( Int, Int )
    | PickedDouble
    | PickedTake
    | CycledCube
    | CycledOwner
    | ToggledGame
    | SteppedLength Int
    | SteppedScore Color Int
    | ToggledCrawford
    | PressedOpening
    | PressedClear
    | PressedFlip
    | PressedCopy
    | CopiedFaded Int
    | OpenedImport
    | ClosedImport
    | ImportInput String
    | ImportSubmitted
    | PressedAnalyze
    | GotPuzzle (Result Api.Error Puzzle.Puzzle)
    | NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PickedBrush brush ->
            ( { model | brush = brush }, Cmd.none )

        Pointer zone event ->
            pointer zone event model

        LongPressed seq ->
            case model.press of
                Just p ->
                    if p.seq == seq && not p.long then
                        ( pressed Secondary p.zone { model | press = Just { p | long = True } }, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Pressed button target ->
            ( press button target model, Cmd.none )

        PickedTurn color ->
            ( edit (\s -> { s | toPlay = color }) model, Cmd.none )

        OpenedRolls ->
            ( edit (\s -> { s | ask = Move model.lastRoll }) { model | rolling = True }, Cmd.none )

        ClosedRolls ->
            ( { model | rolling = False }, Cmd.none )

        PickedRoll ( a, b ) ->
            let
                roll =
                    ( max a b, min a b )
            in
            ( edit (\s -> { s | ask = Move (Just roll) }) { model | rolling = False, lastRoll = Just roll }, Cmd.none )

        PickedDouble ->
            ( edit (\s -> { s | ask = Double }) model, Cmd.none )

        PickedTake ->
            ( edit (\s -> { s | ask = Take }) model, Cmd.none )

        CycledCube ->
            ( edit cycleCube model, Cmd.none )

        CycledOwner ->
            ( edit
                (\s ->
                    if s.cubeValue == 1 then
                        s

                    else
                        { s | cubeOwner = Just (Setup.other (Maybe.withDefault Black s.cubeOwner)) }
                )
                model
            , Cmd.none
            )

        ToggledGame ->
            case model.setup.match of
                Just m ->
                    ( edit (\s -> { s | match = Nothing }) { model | lastMatch = m }, Cmd.none )

                Nothing ->
                    ( edit (\s -> { s | match = Just model.lastMatch }) model, Cmd.none )

        SteppedLength step ->
            ( editMatch
                (\m ->
                    let
                        length =
                            clamp 1 25 (m.length + step)
                    in
                    { m | length = length, white = min m.white (length - 1), black = min m.black (length - 1) }
                )
                model
            , Cmd.none
            )

        SteppedScore color step ->
            ( editMatch
                (\m ->
                    case color of
                        White ->
                            { m | white = clamp 0 (m.length - 1) (m.white + step) }

                        Black ->
                            { m | black = clamp 0 (m.length - 1) (m.black + step) }
                )
                model
            , Cmd.none
            )

        ToggledCrawford ->
            ( editMatch
                (\m ->
                    if oneAway m then
                        { m | crawford = not m.crawford }

                    else
                        m
                )
                model
            , Cmd.none
            )

        PressedOpening ->
            ( edit
                (\s ->
                    { s
                        | points = Setup.opening.points
                        , whiteBar = 0
                        , blackBar = 0
                        , cubeValue = 1
                        , cubeOwner = Nothing
                    }
                )
                model
            , Cmd.none
            )

        PressedClear ->
            ( edit (\s -> { s | points = Setup.empty.points, whiteBar = 0, blackBar = 0 }) model, Cmd.none )

        PressedFlip ->
            ( edit Setup.flip model, Cmd.none )

        PressedCopy ->
            let
                n =
                    model.copied + 1
            in
            ( { model | copied = n, copiedShown = True }
            , Cmd.batch
                [ copyText (Xgid.encode model.setup)
                , Process.sleep 1500 |> Task.perform (\_ -> CopiedFaded n)
                ]
            )

        CopiedFaded n ->
            if n == model.copied then
                ( { model | copiedShown = False }, Cmd.none )

            else
                ( model, Cmd.none )

        OpenedImport ->
            ( { model | importOpen = True, importText = "", importError = Nothing }, Cmd.none )

        ClosedImport ->
            ( { model | importOpen = False }, Cmd.none )

        ImportInput raw ->
            ( { model | importText = raw, importError = Nothing }, Cmd.none )

        ImportSubmitted ->
            case Xgid.decode model.importText of
                Ok setup ->
                    ( remembered (edit (\_ -> setup) { model | importOpen = False, importText = "" }), Cmd.none )

                Err reason ->
                    ( { model | importError = Just reason }, Cmd.none )

        PressedAnalyze ->
            -- The verdict's seam (analysis-page-verdict): nothing is asked
            -- from this page yet.
            ( model, Cmd.none )

        GotPuzzle (Ok puzzle) ->
            ( remembered { model | loading = False, setup = Setup.fromQuestion puzzle.kind puzzle.question }, Cmd.none )

        GotPuzzle (Err err) ->
            ( { model
                | loading = False
                , notice =
                    Just
                        (if Api.errorCode err == "not_found" then
                            puzzleGone

                         else
                            Api.errorMessage err
                        )
              }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )


{-| Every change to the position goes through here: the line's notice and
any answer about the position before are gone with it.
-}
edit : (Setup -> Setup) -> Model -> Model
edit change model =
    { model | setup = change model.setup, notice = Nothing, ask = NotAsked }


editMatch : (Match -> Match) -> Model -> Model
editMatch change =
    edit
        (\s ->
            { s
                | match =
                    Maybe.map
                        (\m ->
                            let
                                changed =
                                    change m
                            in
                            -- Crawford only stands while somebody is one away
                            { changed | crawford = changed.crawford && oneAway changed }
                        )
                        s.match
            }
        )


oneAway : Match -> Bool
oneAway m =
    m.white == m.length - 1 || m.black == m.length - 1


{-| 1, 2, 4 ... 64, then 1 again. The cube is in the middle at 1; turned
off 1, it goes to whoever is acting -- the player to play, or for a take
the doubler -- so every value it shows can be asked.
-}
cycleCube : Setup -> Setup
cycleCube s =
    let
        value =
            if s.cubeValue >= 64 then
                1

            else
                s.cubeValue * 2

        acting =
            case s.ask of
                Take ->
                    Setup.other s.toPlay

                _ ->
                    s.toPlay
    in
    { s
        | cubeValue = value
        , cubeOwner =
            if value == 1 then
                Nothing

            else
                case s.cubeOwner of
                    Just owner ->
                        Just owner

                    Nothing ->
                        Just acting
    }


press : Button -> Target -> Model -> Model
press button target model =
    case paint model.brush button target model.setup of
        Ok setup ->
            edit (\_ -> setup) model

        Err color ->
            { model
                | refused =
                    Just
                        ( color
                        , model.refused |> Maybe.map Tuple.second |> Maybe.withDefault 0 |> (+) 1
                        )
            }


pressed : Button -> String -> Model -> Model
pressed button zone model =
    case targetOf zone of
        Just target ->
            press button target model

        Nothing ->
            model


{-| A pointer on a place of the board. A mouse acts as it lifts (on the
place it went down on), a right click at once. A finger acts as it lifts,
unless it has been down `longPressMs` without sliding, when it acts as the
other brush and lifting does nothing; sliding further than `slop` is a
scroll and does nothing at all. Some phones also send a right click for a
long press: whichever of the two comes first acts, once.
-}
pointer : String -> Board.EditEvent -> Model -> ( Model, Cmd Msg )
pointer zone event model =
    case event of
        Board.Down touch x y ->
            let
                seq =
                    model.presses + 1
            in
            ( { model | presses = seq, press = Just { zone = zone, touch = touch, x = x, y = y, seq = seq, long = False } }
            , if touch then
                Process.sleep longPressMs |> Task.perform (\_ -> LongPressed seq)

              else
                Cmd.none
            )

        Board.Moved x y ->
            case model.press of
                Just p ->
                    if not p.long && (abs (x - p.x) > slop || abs (y - p.y) > slop) then
                        ( { model | press = Nothing }, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Board.Up ->
            case model.press of
                Just p ->
                    if p.zone == zone && not p.long then
                        ( pressed Primary zone { model | press = Nothing }, Cmd.none )

                    else
                        ( { model | press = Nothing }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Board.Cancelled ->
            ( { model | press = Nothing }, Cmd.none )

        Board.Context ->
            case model.press of
                Just p ->
                    if p.touch then
                        if p.long then
                            ( model, Cmd.none )

                        else
                            ( pressed Secondary p.zone { model | press = Just { p | long = True } }, Cmd.none )

                    else
                        ( pressed Secondary zone { model | press = Nothing }, Cmd.none )

                Nothing ->
                    ( pressed Secondary zone model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ classList
            [ ( "rp-page an-page paper", True )
            , ( flashClass model, model.refused /= Nothing )
            ]
        , id "analysis"
        ]
        [ div [ class "rp-head" ]
            [ span [ class "rp-tag pixel text-[7px] sm:text-[8px]" ] [ text "ANALYSIS" ] ]
        , div [ class "rp-main" ]
            [ div [ class "rp-stage" ]
                [ viewBrushes model
                , div [ class "rp-board an-board", id "an-board" ]
                    [ Board.viewEdit
                        { still = still model
                        , zoneId = zoneId
                        , onEdit = Pointer
                        , noop = NoOp
                        }
                    ]
                ]
            , div [ class "rp-side an-side" ]
                [ viewStrip model
                , viewQuick model
                , viewCheck model
                , button
                    [ type_ "button"
                    , id "an-analyze"
                    , class "q-btn yellow an-analyze pixel"
                    , disabled (not (analyzable model))
                    , onClick PressedAnalyze
                    ]
                    [ text "ANALYZE" ]

                -- The answer's place (analysis-page-verdict). Under
                -- everything else here, so whatever fills it moves
                -- nothing above it.
                , div [ class "an-panel", id "an-panel" ] []
                ]
            ]
        , if model.rolling then
            viewRollSheet model

          else
            text ""
        , if model.importOpen then
            viewImport model

          else
            text ""
        ]


{-| The tray that refused a sixteenth flashes: the class alternates with
every refusal, so the animation starts again each time.
-}
flashClass : Model -> String
flashClass model =
    case model.refused of
        Just ( color, n ) ->
            "an-flash-" ++ Setup.colorId color ++ "-" ++ String.fromInt (modBy 2 n)

        Nothing ->
            ""


still : Model -> Board.StillBoard
still model =
    let
        setup =
            model.setup

        doubler =
            Setup.other setup.toPlay
    in
    { players =
        [ { id = Setup.colorId White, name = "White", color = "white" }
        , { id = Setup.colorId Black, name = "Black", color = "black" }
        ]
    , viewer = Setup.colorId White
    , scores =
        case setup.match of
            Just m ->
                [ ( Setup.colorId White, m.white ), ( Setup.colorId Black, m.black ) ]

            Nothing ->
                []
    , cube = True
    , theme = theme model
    , key = 0
    , position = Setup.snapshot setup
    , mover =
        Just
            (Setup.colorId
                (case setup.ask of
                    Take ->
                        doubler

                    _ ->
                        setup.toPlay
                )
            )
    , dice =
        case setup.ask of
            Move (Just ( a, b )) ->
                [ a, b ]

            _ ->
                []
    , landed = []
    , offer =
        case setup.ask of
            Take ->
                Just (Setup.colorId doubler)

            _ ->
                Nothing
    , accounts = Nothing
    }


viewBrushes : Model -> Html Msg
viewBrushes model =
    let
        brushButton brushId brush label content =
            button
                [ type_ "button"
                , id brushId
                , classList [ ( "an-brush", True ), ( "is-on", model.brush == brush ) ]
                , attribute "aria-pressed" (boolString (model.brush == brush))
                , attribute "aria-label" label
                , Html.Attributes.title label
                , onClick (PickedBrush brush)
                ]
                content

        ( tap, other ) =
            case model.brush of
                Paint color ->
                    ( "adds " ++ Setup.colorName color, "adds " ++ Setup.colorName (Setup.other color) )

                Erase ->
                    ( "takes one off", "takes one off" )
    in
    div [ class "an-brushes", id "an-brushes" ]
        [ brushButton "an-brush-white" (Paint White) "White checkers" [ span [ class "an-chip white" ] [] ]
        , brushButton "an-brush-black" (Paint Black) "Black checkers" [ span [ class "an-chip black" ] [] ]
        , brushButton "an-brush-remove" Erase "Take checkers off" [ span [ class "an-x" ] [ text "✕" ] ]
        , span [ class "an-hint an-hint-touch" ]
            [ text
                (if model.brush == Erase then
                    "Tap " ++ tap

                 else
                    "Tap " ++ tap ++ " · hold " ++ other
                )
            ]
        , span [ class "an-hint an-hint-mouse" ]
            [ text
                (if model.brush == Erase then
                    "Click " ++ tap

                 else
                    "Click " ++ tap ++ " · right-click " ++ other
                )
            ]
        ]


viewStrip : Model -> Html Msg
viewStrip model =
    let
        setup =
            model.setup

        match =
            setup.match

        m =
            Maybe.withDefault model.lastMatch match

        inMatch =
            match /= Nothing

        group label content =
            div [ class "an-group" ] [ span [ class "an-label pixel" ] [ text label ], div [ class "an-controls" ] content ]

        seg segId on msg content =
            button
                [ type_ "button"
                , id segId
                , classList [ ( "an-seg", True ), ( "is-on", on ) ]
                , attribute "aria-pressed" (boolString on)
                , onClick msg
                ]
                content

        isMove =
            case setup.ask of
                Move _ ->
                    True

                _ ->
                    False

        stepper stepperId valueContent onStep enabledDown enabledUp extra =
            div [ class "an-stepper", id stepperId ]
                [ button [ type_ "button", id (stepperId ++ "-minus"), class "an-step", disabled (not enabledDown), onClick (onStep -1), attribute "aria-label" "Less" ] [ text "−" ]
                , valueContent
                , button [ type_ "button", id (stepperId ++ "-plus"), class "an-step", disabled (not enabledUp), onClick (onStep 1), attribute "aria-label" "More" ] [ text "+" ]
                ]
                |> (\html -> div [ class ("an-stepper-wrap " ++ extra) ] [ html ])

        score color n =
            stepper ("an-score-" ++ Setup.colorId color)
                (span [ class ("an-score-value pixel " ++ Setup.colorId color), id ("an-score-" ++ Setup.colorId color ++ "-value") ]
                    [ text
                        (if inMatch then
                            String.fromInt n

                         else
                            "–"
                        )
                    ]
                )
                (SteppedScore color)
                (inMatch && n > 0)
                (inMatch && n < m.length - 1)
                ""
    in
    div [ class "an-strip", id "an-strip" ]
        [ div [ class "an-row" ]
            [ group "TO PLAY"
                [ div [ class "an-segs", id "an-turn" ]
                    [ seg "an-turn-white" (setup.toPlay == White) (PickedTurn White) [ span [ class "an-chip white", attribute "aria-label" "White" ] [] ]
                    , seg "an-turn-black" (setup.toPlay == Black) (PickedTurn Black) [ span [ class "an-chip black", attribute "aria-label" "Black" ] [] ]
                    ]
                ]
            , group "ASK"
                [ div [ class "an-segs", id "an-ask" ]
                    [ seg "an-dice" isMove OpenedRolls [ viewDice setup.ask model.lastRoll ]
                    , seg "an-ask-double" (setup.ask == Double) PickedDouble [ text "DOUBLE?" ]
                    , seg "an-ask-take" (setup.ask == Take) PickedTake [ text "TAKE?" ]
                    ]
                ]
            , group "CUBE"
                [ div [ class "an-segs" ]
                    [ button [ type_ "button", id "an-cube", class "an-seg an-cube", onClick CycledCube, attribute "aria-label" "Cube value" ]
                        [ text (String.fromInt setup.cubeValue) ]
                    , button
                        [ type_ "button"
                        , id "an-cube-owner"
                        , class "an-seg an-owner"
                        , disabled (setup.cubeValue == 1)
                        , onClick CycledOwner
                        , attribute "aria-label" "Cube owner"
                        ]
                        [ text
                            (case setup.cubeOwner of
                                Nothing ->
                                    "CENTER"

                                Just White ->
                                    "WHITE"

                                Just Black ->
                                    "BLACK"
                            )
                        ]
                    ]
                ]
            ]
        , div [ class "an-row" ]
            [ group "GAME"
                [ stepper "an-length"
                    (button
                        [ type_ "button"
                        , id "an-game"
                        , classList [ ( "an-seg an-game", True ), ( "is-on", inMatch ) ]
                        , attribute "aria-pressed" (boolString inMatch)
                        , onClick ToggledGame
                        ]
                        [ text
                            (if inMatch then
                                "MATCH TO " ++ String.fromInt m.length

                             else
                                "UNLIMITED"
                            )
                        ]
                    )
                    SteppedLength
                    (inMatch && m.length > 1)
                    (inMatch && m.length < 25)
                    ""
                ]
            , group "SCORE"
                [ score White m.white
                , score Black m.black
                ]
            , group "CRAWFORD"
                [ div [ class "an-segs" ]
                    [ button
                        [ type_ "button"
                        , id "an-crawford"
                        , classList [ ( "an-seg an-crawford", True ), ( "is-on", inMatch && m.crawford ) ]
                        , attribute "aria-pressed" (boolString (inMatch && m.crawford))
                        , attribute "aria-label" "Crawford game"
                        , disabled (not (inMatch && oneAway m))
                        , onClick ToggledCrawford
                        ]
                        [ text
                            (if inMatch && m.crawford then
                                "ON"

                             else
                                "OFF"
                            )
                        ]
                    ]
                ]
            ]
        ]


{-| ROLL's face: the roll picked, high die first, or two blank dice.
-}
viewDice : Ask -> Maybe ( Int, Int ) -> Html msg
viewDice ask lastRoll =
    let
        shown =
            case ask of
                Move roll ->
                    roll

                _ ->
                    lastRoll
    in
    span [ class "an-dice", attribute "aria-label" "Roll" ]
        (case shown of
            Just ( a, b ) ->
                [ miniDie a, miniDie b ]

            Nothing ->
                [ blankDie, blankDie ]
        )


miniDie : Int -> Html msg
miniDie n =
    span [ class "an-die", attribute "data-value" (String.fromInt n) ]
        (List.range 1 9
            |> List.map
                (\cell ->
                    span [ classList [ ( "an-pip", True ), ( "on", List.member cell (pipCells n) ) ] ] []
                )
        )


blankDie : Html msg
blankDie =
    span [ class "an-die blank" ] [ span [ class "an-die-q" ] [ text "?" ] ]


{-| Which cells of a 3x3 grid hold a pip, reading across.
-}
pipCells : Int -> List Int
pipCells n =
    case n of
        1 ->
            [ 5 ]

        2 ->
            [ 3, 7 ]

        3 ->
            [ 3, 5, 7 ]

        4 ->
            [ 1, 3, 7, 9 ]

        5 ->
            [ 1, 3, 5, 7, 9 ]

        _ ->
            [ 1, 3, 4, 6, 7, 9 ]


viewQuick : Model -> Html Msg
viewQuick model =
    let
        quick quickId label msg =
            button [ type_ "button", id quickId, class "q-btn plain an-quick pixel", onClick msg ] [ text label ]
    in
    div [ class "an-quicks" ]
        [ div [ class "an-quick-row" ]
            [ quick "an-opening" "OPENING" PressedOpening
            , quick "an-clear" "CLEAR" PressedClear
            , quick "an-flip" "FLIP" PressedFlip
            ]
        , div [ class "an-xgid-row" ]
            [ input
                [ id "an-xgid"
                , class "q-field an-xgid"
                , readonly True
                , value (Xgid.encode model.setup)
                , attribute "aria-label" "Position id (XGID)"
                , attribute "spellcheck" "false"
                ]
                []
            , button [ type_ "button", id "an-xgid-copy", class "q-btn plain an-quick an-copy pixel", onClick PressedCopy ]
                [ text
                    (if model.copiedShown then
                        "COPIED"

                     else
                        "COPY"
                    )
                ]
            , button [ type_ "button", id "an-xgid-import", class "q-btn plain an-quick pixel", onClick OpenedImport ] [ text "IMPORT" ]
            ]
        ]


viewCheck : Model -> Html Msg
viewCheck model =
    Html.p [ class "an-check", id "an-check", attribute "aria-live" "polite" ]
        [ text (line model |> Maybe.withDefault "") ]


viewRollSheet : Model -> Html Msg
viewRollSheet model =
    let
        picked =
            case model.setup.ask of
                Move roll ->
                    roll

                _ ->
                    Nothing
    in
    div [ class "an-sheet-layer", id "an-roll-sheet" ]
        [ div [ class "an-sheet-dim", onClick ClosedRolls, attribute "aria-hidden" "true" ] []
        , div [ class "an-sheet q-card", attribute "role" "dialog", attribute "aria-label" "Pick a roll" ]
            [ div [ class "an-sheet-head" ]
                [ span [ class "pixel q-eyebrow text-[9px]" ] [ text "PICK A ROLL" ]
                , button [ type_ "button", id "an-roll-close", class "q-note text-base px-2 py-1 -mr-2", onClick ClosedRolls, attribute "aria-label" "Close" ] [ text "✕" ]
                ]
            , div [ class "an-rolls" ]
                (rolls
                    |> List.concatMap
                        (\row ->
                            List.map
                                (\( a, b ) ->
                                    button
                                        [ type_ "button"
                                        , id ("an-roll-" ++ String.fromInt a ++ String.fromInt b)
                                        , classList [ ( "an-roll", True ), ( "is-on", picked == Just ( a, b ) ) ]
                                        , attribute "style" ("grid-row: " ++ String.fromInt a ++ "; grid-column: " ++ String.fromInt b)
                                        , attribute "aria-label" (String.fromInt a ++ "-" ++ String.fromInt b)
                                        , onClick (PickedRoll ( a, b ))
                                        ]
                                        [ miniDie a, miniDie b ]
                                )
                                row
                        )
                )
            ]
        ]


viewImport : Model -> Html Msg
viewImport model =
    Ui.Dialog.view
        { id = "an-import"
        , closeId = "an-import-close"
        , label = "Import a position"
        , heading = "IMPORT A POSITION"
        , onClose = ClosedImport
        , width = "max-w-md"
        }
        [ Html.form [ onSubmit ImportSubmitted, class "flex flex-col gap-2" ]
            [ Html.label [ class "text-sm", Html.Attributes.for "an-import-text" ] [ text "Paste an XGID from XG, GNU Backgammon or a forum post." ]
            , div [ class "flex gap-2" ]
                [ input
                    [ id "an-import-text"
                    , class "q-field flex-1 min-w-0 px-3 py-2 text-sm an-mono"
                    , value model.importText
                    , onInput ImportInput
                    , Html.Attributes.placeholder "XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10"
                    , Html.Attributes.autofocus True
                    , attribute "autocomplete" "off"
                    , attribute "autocapitalize" "off"
                    , attribute "spellcheck" "false"
                    ]
                    []
                , button [ type_ "submit", id "an-import-go", class "q-btn yellow px-4 pixel text-[9px]" ] [ text "IMPORT" ]
                ]
            , Html.p [ class "an-import-error", id "an-import-error" ] [ text (Maybe.withDefault "" model.importError) ]
            ]
        ]


boolString : Bool -> String
boolString b =
    if b then
        "true"

    else
        "false"
