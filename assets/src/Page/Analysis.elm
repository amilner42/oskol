module Page.Analysis exposing
    ( Asking(..)
    , Brush(..)
    , Button(..)
    , Line
    , Mode(..)
    , Model
    , Moves(..)
    , Msg(..)
    , Off
    , Out(..)
    , Press
    , Refusal
    , Step
    , Target(..)
    , analyzable
    , defaultMatch
    , depthLine
    , ending
    , init
    , line
    , lineNow
    , longPressMs
    , notation
    , offFrom
    , paint
    , plate
    , pollLimit
    , puzzleGone
    , rolls
    , shownSetup
    , subscriptions
    , title
    , toPlace
    , tooLongMessage
    , update
    , updateWithOut
    , view
    , withSession
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
same taps.

**Every checker is somewhere.** Each colour's fifteen are on the board,
borne off, or not placed yet (`Off`, `toPlace`). A checker taken off the
board is not placed, never silently borne off; each brush wears a badge
of its colour's not placed. Bearing off is on purpose: a tap on a tray
bears one of those not placed off ("1 off"), the other button or the x
takes one back. A sixteenth checker, a tray with nothing to bear off or
take back, is refused, and that colour's tray flashes once where it is.
CLEAR makes every checker not placed, to build a position from scratch.

**The settings strip.** Who is to play; what is asked (a roll to play,
picked from a sheet of the 21; DOUBLE?; TAKE?); the cube's value and owner
(the owner is the middle at 1, and a cube turned off 1 goes to whoever is
acting, so the strip never builds a cube `check` refuses); unlimited play
or a match to 1..25 with both scores and Crawford, which can only be on
while somebody is one away. Then OPENING, CLEAR and FLIP. TO PLAY is each
colour's checker with its word, the chosen one ringed, never a checker on
an inverted tile; the board's bar for that colour is the one to move and
says "to play".

**The line under the strip** says the first thing left to do: "Place 3
more White checkers" until every checker is placed or off, then the first
thing `Setup.check` says ("Pick a roll", the cube and the match), in the
server's words; ANALYZE is disabled while it says anything, so only a
complete position (whose off is fifteen less the board, as the server
reads it) is ever asked.

**ANALYZE** posts the setup (`Api.Analysis.ask`). A position asked before
comes back at once; otherwise the button's slot becomes a plate of the
same size, "ASKING THE ENGINE… 3 s", and the page asks how it is going
once a second (`Api.Analysis.status`) for up to `pollLimit` seconds. The
answer fills `#an-panel` (under the board on a phone, in the column beside
it otherwise), in the replay's words and its candidate table
(`Ui.Candidates`): a row puts its play on the board, the dice (or the same
row) take it back. A double or a take is the cube's three equities, the
chances and the sentence. Under it, the depth and whether it was asked
just now or already analyzed, SAVE (the position into a set of your own:
`Ui.SaveToSet`, the sheet a puzzle's reveal opens too, which a guest
signs in from with the position kept in the URL), SHARE (the puzzle's
clean link) and OPEN AS PUZZLE. When it cannot: the server's sentence, and TRY AGAIN once any wait
it named has passed. Any change to the position clears the answer.

**Playing it out** (analysis-play-it-out). From a complete position the
board can be played on: PLAY THIS under a move's answer plays the
candidate on the board (the best, with none shown); the head's PLAY
(`#an-mode-play`) turns the board into the puzzle page's table on the
roll's legal plays -- the answer's own tree, or for a position nobody has
analyzed `POST /papi/analysis/moves`, move generation on the server and no
engine -- with UNDO and PLAY in its band; the row over the board offers
ROLL FOR ME (two dice from `elm/random`: a sandbox, not a game), DOUBLE /
NO DOUBLE and TAKE / PASS. Each choice is a step of `line` and the next
position follows by the game's rules (`Setup.next`); a pass, or a play
that bears the last checker off, ends the line in a sentence. The strip
under the board (`#an-line`) walks the line with no fetch, each step
keeping its answer. A new roll or cube question at a step drops the steps
after it (a line, not a tree); any other change to the position starts a
fresh line from it. Nothing is persisted, and the URL keeps the position
the page opened on. In PLAY the player acting sits at the bottom, in their
own colour, as at a table.

**Doors in.** `/analysis` is the opening position, White to play, no roll
picked. `?xgid=` opens on that id, whoever is to play: an id with Black on
roll stays Black to play (FLIP turns it round). `?p=<id>` reads the puzzle (`GET /papi/puzzles/:id`, no
engine) and opens it as its page shows it (`Setup.fromQuestion`); a puzzle
that is not there opens the opening position and says so.

Nothing moves when anything changes: every control has a fixed-size slot,
the line under the strip is a fixed height, and the sheets float over the
page.

-}

import Api
import Api.Analysis as Analysis
import Browser.Dom as Dom
import Dict
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Replay as Replay
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Match, Setup)
import Games.Backgammon.View as Board
import Games.Backgammon.Words as Words
import Games.Backgammon.Xgid as Xgid
import Html exposing (Html, a, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, href, id, type_)
import Html.Events exposing (onClick)
import Json.Decode as D
import Page.Play exposing (shareInvite, shareResult)
import Process
import Random
import Route
import Session exposing (Session)
import Task
import Ui.Candidates as Candidates
import Ui.SaveToSet as SaveToSet
import Ui.Scrub as Scrub


-- MODEL


type alias Model =
    { session : Session
    , origin : String -- scheme, host and port, for the link SHARE hands over
    , setup : Setup
    , off : Off -- each colour's borne off: kept here, since `Setup` counts whatever is not on the board as off
    , brush : Brush
    , press : Maybe Press -- a finger or a button down on a place of the board
    , presses : Int -- every press is numbered, so a long-press timer knows its own
    , cubeHold : Board.Hold -- a cube button in PLAY being held down (`Board.stepHold`)
    , spent : Maybe String -- the place a finger's press was dropped from (a scroll, the browser taking it): its late right click is not a new one
    , rolling : Bool -- the sheet of the 21 rolls is open
    , lastRoll : Maybe ( Int, Int ) -- the roll ROLL goes back to after DOUBLE? or TAKE?
    , lastMatch : Match -- the match MATCH TO goes back to after UNLIMITED
    , refused : Maybe ( Color, Int ) -- the colour a sixteenth was refused for, and how many times: its tray flashes
    , notice : Maybe String -- a door in that could not open what it was asked to; gone at the first edit
    , loading : Bool -- `?p=` is being read

    -- The engine's answer for the position on the board, and the line
    -- played out from it (analysis-play-it-out). Every edit clears `ask`.
    , ask : Asking
    , asks : Int -- every press is numbered: an answer for an earlier one is dropped
    , showing : Maybe Int -- the rank of the candidate whose play is on the board
    , shareNote : Maybe String -- "Link copied", for a moment after SHARE
    , shares : Int

    -- The line played out from the position (analysis-play-it-out). The
    -- step on the board lives in `setup`, `off` and `ask`; `lineNow` puts
    -- it back into the line.
    , line : Line
    , mode : Mode
    , moves : Moves -- the legal plays of the step on the board, in PLAY
    , path : List String -- the table's walk through them, as the puzzle page's
    , fetching : List String -- levels of a lazy tree on their way
    , swaps : Int
    , movesAsked : Int -- every fetch is numbered: a tree for an earlier step is dropped
    , save : Maybe SaveToSet.Model -- SAVE's sheet, while it is open
    }


{-| The board: being set up with the brushes, or played on.
-}
type Mode
    = SetUp
    | Play


{-| The line played out from the position the page was set up with: a
list, not a tree. `at` is the step on the board.
-}
type alias Line =
    { steps : List Step, at : Int }


{-| One position of the line, the engine's answer about it once asked, and
what was done there.
-}
type alias Step =
    { setup : Setup
    , answer : Maybe { answer : Analysis.Answer, cached : Bool }
    , chosen : Maybe Setup.Chosen
    }


{-| The legal plays of the step on the board, for the table in PLAY: none
asked yet, on their way, here (`puzzle` names the answered puzzle whose
tree it is, whose lazy levels come from its own page; `Nothing` is the
analysis board's own `moves`), or the sentence of a request that failed.
-}
type Moves
    = NoMoves
    | MovesAsked
    | MovesIn { tree : Puzzle.Tree, puzzle : Maybe String }
    | MovesFailed String


{-| What has been asked about the position on the board.

  - `Asking`: the press is out. `seconds` since it, the key once the server
    has named one (then it is polled), and whether a request is out now.
  - `Answered`: the engine's answer; `cached` when the POST answered at
    once (the position had been analyzed before).
  - `Refused`: why not, in the server's sentence.

-}
type Asking
    = NotAsked
    | Asking { seconds : Int, key : Maybe String, out : Bool }
    | Answered { answer : Analysis.Answer, cached : Bool }
    | Refused Refusal


{-| A press that came to nothing: the sentence, whether TRY AGAIN is
offered, and the seconds it is held back for (a 429's or a 503's wait).
-}
type alias Refusal =
    { message : String, retry : Bool, wait : Int }


{-| How long the page waits for an answer before it gives up asking.
-}
pollLimit : Int
pollLimit =
    90


tooLongMessage : String
tooLongMessage =
    "The engine is taking too long. Try again in a minute."


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
    | Tray Color -- a colour's borne-off checkers


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


init : Session -> String -> { xgid : Maybe String, puzzle : Maybe String } -> ( Model, Cmd Msg )
init session origin door =
    let
        base =
            { session = session
            , origin = origin
            , setup = Setup.opening
            , off = { white = 0, black = 0 }
            , brush = Paint White
            , press = Nothing
            , presses = 0
            , cubeHold = Board.noHold
            , spent = Nothing
            , rolling = False
            , lastRoll = Nothing
            , lastMatch = defaultMatch
            , refused = Nothing
            , notice = Nothing
            , loading = False
            , ask = NotAsked
            , asks = 0
            , showing = Nothing
            , shareNote = Nothing
            , shares = 0
            , line = { steps = [ { setup = Setup.opening, answer = Nothing, chosen = Nothing } ], at = 0 }
            , mode = SetUp
            , moves = NoMoves
            , path = []
            , fetching = []
            , swaps = 0
            , movesAsked = 0
            , save = Nothing
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
remembered incoming =
    let
        model =
            { incoming | setup = normalize incoming.setup, off = offFrom incoming.setup }
    in
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


{-| What the share sheet (or the clipboard) did with SHARE's link.
-}
subscriptions : Model -> Sub Msg
subscriptions _ =
    shareResult ShareReported


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
                case placeLine model of
                    Just place ->
                        Just place

                    Nothing ->
                        Setup.check model.setup


{-| "Place 3 more White checkers", "Place 1 more Black checker", "Place 3
more White and 2 more Black checkers": what is left to put on the board
or in a tray, or nothing once every checker is somewhere.
-}
placeLine : Model -> Maybe String
placeLine model =
    let
        left color =
            toPlace color ( model.setup, model.off )

        more n color =
            String.fromInt n ++ " more " ++ Setup.colorName color

        checkers n =
            if n == 1 then
                " checker"

            else
                " checkers"
    in
    case ( left White, left Black ) of
        ( 0, 0 ) ->
            Nothing

        ( w, 0 ) ->
            Just ("Place " ++ more w White ++ checkers w)

        ( 0, b ) ->
            Just ("Place " ++ more b Black ++ checkers b)

        ( w, b ) ->
            Just ("Place " ++ more w White ++ " and " ++ more b Black ++ " checkers")


{-| ANALYZE is enabled: every checker is on the board or borne off, and
the position can be asked as it stands (a roll picked for a move, the
cube and the match as `Setup.check` wants them). Only then is the setup
what the server will read: its off is fifteen less the board.
-}
analyzable : Model -> Bool
analyzable model =
    not model.loading && placeLine model == Nothing && Setup.check model.setup == Nothing


{-| The 21 rolls, high die first, as the sheet lays them out: one row per
high die, its doubles at the end.
-}
rolls : List (List ( Int, Int ))
rolls =
    List.range 1 6
        |> List.map (\high -> List.range 1 high |> List.map (\low -> ( high, low )))



-- THE LINE


{-| The line with the step on the board as it stands now: its setup and,
once answered, the engine's answer.
-}
lineNow : Model -> Line
lineNow model =
    let
        l =
            model.line

        answer =
            case model.ask of
                Answered a ->
                    Just a

                _ ->
                    Nothing
    in
    { l
        | steps =
            List.indexedMap
                (\i s ->
                    if i == l.at then
                        { s | setup = model.setup, answer = answer }

                    else
                        s
                )
                l.steps
    }


stepAt : Int -> List Step -> Maybe Step
stepAt i steps =
    steps |> List.drop i |> List.head


{-| The step on the board as the line holds it (what was chosen there).
-}
here : Model -> Maybe Step
here model =
    let
        l =
            lineNow model
    in
    stepAt l.at l.steps


{-| The position is complete: every checker on the board or borne off, as
the server reads a position. Only a complete position is played on.
-}
complete : Model -> Bool
complete model =
    not model.loading && placeLine model == Nothing


{-| The sentence the line ends in, when its last step's choice ended the
game: "Black passes. White wins 1 point.", "White has borne off."
-}
ending : Model -> Maybe String
ending model =
    case List.reverse (lineNow model).steps of
        last :: _ ->
            case last.chosen of
                Just chosen ->
                    case Setup.next chosen last.setup of
                        Err sentence ->
                            if sentence == "" then
                                Nothing

                            else
                                Just sentence

                        Ok _ ->
                            Nothing

                Nothing ->
                    Nothing

        [] ->
            Nothing


{-| The ending, while the board shows the step it came at.
-}
endingHere : Model -> Maybe String
endingHere model =
    let
        l =
            lineNow model
    in
    if l.at == List.length l.steps - 1 then
        ending model

    else
        Nothing


{-| One step as its plate in the strip reads: who, the roll, and what was
played -- "W 3-1 · 8/5 6/5", "B 6-2", "W to roll", "W doubles", "B takes",
"B passes".
-}
plate : Step -> String
plate step =
    let
        s =
            step.setup

        who =
            case s.toPlay of
                White ->
                    "W"

                Black ->
                    "B"

        roll ( a, b ) =
            String.fromInt a ++ "-" ++ String.fromInt b
    in
    who
        ++ " "
        ++ (case ( s.ask, step.chosen ) of
                ( Move (Just r), Just (Setup.Played p) ) ->
                    roll r
                        ++ " · "
                        ++ (if p.notation == "" then
                                "no play"

                            else
                                p.notation
                           )

                ( Move (Just r), _ ) ->
                    roll r

                ( Move Nothing, _ ) ->
                    "to roll"

                ( Double, Just Setup.Doubled ) ->
                    "doubles"

                ( Double, Just Setup.NoDouble ) ->
                    "no double"

                ( Double, _ ) ->
                    "double?"

                ( Take, Just Setup.Took ) ->
                    "takes"

                ( Take, Just Setup.Passed ) ->
                    "passes"

                ( Take, _ ) ->
                    "take?"
           )


{-| A walk through a move tree as it reads: "8/5 6/5", "24/18\*/13",
"6/off(2)", "bar/22"; "" for a walk of nothing. The points are the
mover's own, as the tree numbers them. One checker's steps are joined
(24/18 then 18/13 is 24/13, the stop written only where it hit) and the
same move twice is written once with its count, as the record writes a
turn (`backgammon/record.notation`). Formatting, not rules: the legal
plays are the tree's.
-}
notation : Puzzle.Tree -> List String -> String
notation tree path =
    let
        hitAt node =
            Dict.get node tree.nodes |> Maybe.andThen .moved |> Maybe.map .hit |> Maybe.withDefault False

        moves =
            Puzzle.played tree path
                |> Maybe.withDefault []
                |> List.map (\c -> { from = c.from, to = c.to, hit = hitAt c.node })

        endOf chain =
            chain.stops |> List.reverse |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault chain.from

        addStep ( i, m ) chains =
            case
                chains
                    |> List.filter (\c -> endOf c == m.from && m.from /= "off")
                    |> List.sortBy (\c -> negate c.last)
                    |> List.head
            of
                Just chain ->
                    List.map
                        (\c ->
                            if c == chain then
                                { c | stops = c.stops ++ [ ( m.to, m.hit ) ], last = i }

                            else
                                c
                        )
                        chains

                Nothing ->
                    chains ++ [ { from = m.from, stops = [ ( m.to, m.hit ) ], last = i } ]

        chains_ =
            List.foldl addStep [] (List.indexedMap Tuple.pair moves)

        keyOf chain =
            ( chain.from
            , chain.stops |> List.take (List.length chain.stops - 1) |> List.filter Tuple.second |> List.map Tuple.first
            , endOf chain
            )

        landsHit chain =
            chain.stops |> List.reverse |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault False

        groups =
            List.foldl
                (\chain gs ->
                    let
                        k =
                            keyOf chain
                    in
                    if List.any (\g -> g.key == k) gs then
                        List.map
                            (\g ->
                                if g.key == k then
                                    { g | hit = g.hit || landsHit chain, n = g.n + 1 }

                                else
                                    g
                            )
                            gs

                    else
                        gs ++ [ { key = k, hit = landsHit chain, n = 1 } ]
                )
                []
                chains_

        written g =
            let
                ( from, onTheWay, to ) =
                    g.key
            in
            from
                ++ String.concat (List.map (\loc -> "/" ++ loc ++ "*") onTheWay)
                ++ "/"
                ++ to
                ++ (if g.hit then
                        "*"

                    else
                        ""
                   )
                ++ (if g.n > 1 then
                        "(" ++ String.fromInt g.n ++ ")"

                    else
                        ""
                   )
    in
    groups |> List.map written |> String.join " "



-- PAINTING


{-| Each colour's checkers borne off. The page keeps them, because
`Setup` cannot: on the wire, and to the server, borne off is whatever is
not on the board, which only holds once every checker is placed. While a
position is being built a checker can also be **not placed** (taken off
the board, or never put on), and that is not borne off.
-}
type alias Off =
    { white : Int, black : Int }


offOf : Color -> Off -> Int
offOf color off =
    case color of
        White ->
            off.white

        Black ->
            off.black


withOff : Color -> Int -> Off -> Off
withOff color n off =
    case color of
        White ->
            { off | white = n }

        Black ->
            { off | black = n }


{-| Borne off as the wire has it: whatever of fifteen is not on the board.
What every door in (an id, a puzzle) reads, since neither has anything
not placed.
-}
offFrom : Setup -> Off
offFrom setup =
    { white = max 0 (Setup.offWhite setup), black = max 0 (Setup.offBlack setup) }


{-| A colour's checkers not placed yet: neither on the board nor borne off.
-}
toPlace : Color -> ( Setup, Off ) -> Int
toPlace color ( setup, off ) =
    max 0 (15 - onBoard color setup - offOf color off)


{-| What a press on `target` does with `brush`, or the colour whose tray
refuses it (`Err`, and the tray flashes): a sixteenth checker, a tray
with none to take back, none left to bear off.

On the board a checker comes from those not placed (or, with none, back
from the tray), and a checker taken off the board is not placed again,
not borne off. A tray is borne off on purpose: a tap bears one of the
colour's not-placed checkers off; the other button, or the x, takes one
back to be placed. The other button is the other colour's brush; with the
x, both buttons take one off.

-}
paint : Brush -> Button -> Target -> ( Setup, Off ) -> Result Color ( Setup, Off )
paint brush button target ( setup, off ) =
    let
        effective =
            case ( brush, button ) of
                ( Paint color, Secondary ) ->
                    Paint (Setup.other color)

                _ ->
                    brush

        -- one more of `color` on the board: from those not placed, or
        -- back from the tray
        taking color placed =
            if toPlace color ( setup, off ) > 0 then
                Ok ( placed, off )

            else if offOf color off > 0 then
                Ok ( placed, withOff color (offOf color off - 1) off )

            else
                Err color

        removed placed =
            Ok ( placed, off )
    in
    case target of
        Point p ->
            let
                n =
                    pointCount p setup

                set count =
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
                    removed (set (n - sign n))

                Paint color ->
                    if n /= 0 && colorOf n /= color then
                        -- painting over the other colour: one of theirs off
                        removed (set (n - sign n))

                    else
                        taking color (set (n + unit color))

        Bar barColor ->
            let
                n =
                    barCount barColor setup

                set count =
                    case barColor of
                        White ->
                            { setup | whiteBar = count }

                        Black ->
                            { setup | blackBar = count }
            in
            case effective of
                Erase ->
                    removed (set (max 0 (n - 1)))

                Paint color ->
                    if color /= barColor then
                        -- the other colour's half: painting over it
                        removed (set (max 0 (n - 1)))

                    else
                        taking color (set (n + 1))

        Tray color ->
            let
                n =
                    offOf color off
            in
            case ( brush, button ) of
                ( Paint _, Primary ) ->
                    if toPlace color ( setup, off ) > 0 then
                        Ok ( setup, withOff color (n + 1) off )

                    else
                        Err color

                _ ->
                    if n > 0 then
                        Ok ( setup, withOff color (n - 1) off )

                    else
                        Err color


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

        [ "off", "white" ] ->
            Just (Tray White)

        [ "off", "black" ] ->
            Just (Tray Black)

        _ ->
            Nothing


zoneId : String -> String
zoneId zone =
    case targetOf zone of
        Just (Point p) ->
            "an-pt-" ++ String.fromInt p

        Just (Bar color) ->
            "an-bar-" ++ Setup.colorId color

        Just (Tray color) ->
            "an-off-" ++ Setup.colorId color

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
    | PressedAnalyze
    | PressedRetry
    | GotAsk Int (Result Analysis.Refusal Analysis.Status)
    | GotStatus Int (Result Analysis.Refusal Analysis.Status)
    | Ticked Int
    | Show (Maybe Int)
    | PressedShare
    | ShareReported String
    | ShareFaded Int
    | GotPuzzle (Result Api.Error Puzzle.Puzzle)
    | PickedMode Mode
    | PressedPlayCandidate
    | Chose Setup.Chosen
    | CubeHold Board.Msg -- a cube button in PLAY: held, let go, or full
    | PressedRollForMe
    | RolledForMe ( Int, Int )
    | Walked Int
    | GotMoves Int (Result Api.Error Puzzle.Tree)
    | GotNode Int String (Result Api.Error Puzzle.Node)
    | BoardOut Puzzle.Out
    | PressedSave
    | SaveMsg SaveToSet.Msg
    | NoOp


{-| What the shell does for the page: nothing, or take the account the
save sheet just signed in.
-}
type Out
    = NoOut
    | SignedIn (Maybe Session.User)


{-| `update`, and what the shell hears of it: the save sheet's sign-in.
-}
updateWithOut : Msg -> Model -> ( Model, Cmd Msg, Out )
updateWithOut msg model =
    case msg of
        SaveMsg sub ->
            case model.save of
                Just sheet ->
                    let
                        ( next, cmd, out ) =
                            SaveToSet.update model.session sub sheet
                    in
                    case out of
                        SaveToSet.NoOut ->
                            ( { model | save = Just next }, Cmd.map SaveMsg cmd, NoOut )

                        SaveToSet.Close ->
                            ( { model | save = Nothing }, Cmd.none, NoOut )

                        SaveToSet.SignedIn user ->
                            ( { model | save = Just next }, Cmd.map SaveMsg cmd, SignedIn user )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        _ ->
            let
                ( next, cmd ) =
                    update msg model
            in
            ( next, cmd, NoOut )


{-| Every message, and then in PLAY the legal plays of the step on the
board asked for if nothing has asked yet; an incomplete position is set
up, never played on.
-}
update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    updateOne msg model |> withMoves


withMoves : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
withMoves ( model, cmd ) =
    if model.mode == Play && not (complete model) then
        ( { model | mode = SetUp }, cmd )

    else
        case ( model.mode, model.setup.ask, model.moves ) of
            ( Play, Move (Just _), NoMoves ) ->
                if Setup.check model.setup /= Nothing then
                    ( model, cmd )

                else
                    case model.ask of
                        Answered { answer } ->
                            case answer.puzzle.tree of
                                Just tree ->
                                    ( { model | moves = MovesIn { tree = tree, puzzle = Just answer.puzzle.id } }, cmd )

                                Nothing ->
                                    askMoves ( model, cmd )

                        _ ->
                            askMoves ( model, cmd )

            _ ->
                ( model, cmd )


{-| The roll's legal plays for a position nobody has analyzed: move
generation on the server, never the engine.
-}
askMoves : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
askMoves ( model, cmd ) =
    ( { model | moves = MovesAsked }
    , Cmd.batch [ cmd, Analysis.moves model.session model.setup (GotMoves model.movesAsked) ]
    )


updateOne : Msg -> Model -> ( Model, Cmd Msg )
updateOne msg model =
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
            ( edit
                (\s ->
                    case s.ask of
                        -- a roll to pick already: the sheet picks it
                        Move _ ->
                            s

                        _ ->
                            { s | ask = Move model.lastRoll }
                )
                { model | rolling = True }
            , Cmd.none
            )

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
                            |> normalize
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
                    -- it can always be turned off, and on only one away
                    if m.crawford || oneAway m then
                        { m | crawford = not m.crawford }

                    else
                        m
                )
                model
            , Cmd.none
            )

        PressedOpening ->
            ( editWith { white = 0, black = 0 }
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

        -- Every checker not placed: a clean start to build from.
        PressedClear ->
            ( editWith { white = 0, black = 0 } (\s -> { s | points = Setup.empty.points, whiteBar = 0, blackBar = 0 }) model
            , Cmd.none
            )

        PressedFlip ->
            ( editWith { white = model.off.black, black = model.off.white } Setup.flip model, Cmd.none )

        PressedAnalyze ->
            analyze model

        PressedRetry ->
            case model.ask of
                Refused r ->
                    if r.retry && r.wait <= 0 then
                        analyze model

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        GotAsk n result ->
            if n /= model.asks then
                ( model, Cmd.none )

            else
                case ( model.ask, result ) of
                    ( Asking a, Ok status ) ->
                        landed True a status model

                    ( Asking _, Err refusal ) ->
                        refused refusal model

                    _ ->
                        ( model, Cmd.none )

        GotStatus n result ->
            if n /= model.asks then
                ( model, Cmd.none )

            else
                case ( model.ask, result ) of
                    ( Asking a, Ok status ) ->
                        landed False a status model

                    ( Asking a, Err refusal ) ->
                        case refusal.error of
                            -- the server forgot the key (a restart): ask
                            -- again, which an answered key serves from its row
                            Api.ApiError e ->
                                if e.code == "not_found" then
                                    ( { model | ask = Asking { a | key = Nothing, out = True } }
                                    , Analysis.ask model.session model.setup (GotAsk model.asks)
                                    )

                                else
                                    refused refusal model

                            -- a poll lost on the way: the next tick asks again
                            _ ->
                                ( { model | ask = Asking { a | out = False } }, Cmd.none )

                    _ ->
                        ( model, Cmd.none )

        Ticked n ->
            if n /= model.asks then
                ( model, Cmd.none )

            else
                case model.ask of
                    Asking a ->
                        let
                            seconds =
                                a.seconds + 1
                        in
                        if seconds >= pollLimit then
                            ( { model | ask = Refused { message = tooLongMessage, retry = True, wait = 0 } }, Cmd.none )

                        else
                            case ( a.key, a.out ) of
                                ( Just key, False ) ->
                                    ( { model | ask = Asking { a | seconds = seconds, out = True } }
                                    , Cmd.batch [ Analysis.status model.session key (GotStatus n), tick n ]
                                    )

                                _ ->
                                    ( { model | ask = Asking { a | seconds = seconds } }, tick n )

                    Refused r ->
                        if r.wait > 0 then
                            ( { model | ask = Refused { r | wait = r.wait - 1 } }
                            , if r.wait > 1 then
                                tick n

                              else
                                Cmd.none
                            )

                        else
                            ( model, Cmd.none )

                    _ ->
                        ( model, Cmd.none )

        Show rank ->
            ( { model | showing = rank }, Cmd.none )

        -- SAVE: the sheet, for the puzzle the answer is. A guest's sign-in
        -- comes back to this position (`?xgid=`), so nothing is lost.
        PressedSave ->
            case model.ask of
                Answered { answer } ->
                    let
                        ( sheet, cmd ) =
                            SaveToSet.init model.session
                                { puzzleId = answer.puzzle.id
                                , next = Route.href (Route.analysisXgid model.setup)
                                }
                    in
                    ( { model | save = Just sheet }, Cmd.map SaveMsg cmd )

                _ ->
                    ( model, Cmd.none )

        SaveMsg _ ->
            let
                ( next, cmd, _ ) =
                    updateWithOut msg model
            in
            ( next, cmd )

        PressedShare ->
            case model.ask of
                Answered { answer } ->
                    ( model, shareInvite (model.origin ++ Route.href (Route.puzzle answer.puzzle.id)) )

                _ ->
                    ( model, Cmd.none )

        ShareReported result ->
            let
                n =
                    model.shares + 1
            in
            ( { model
                | shares = n
                , shareNote =
                    Just
                        (case result of
                            "copied" ->
                                "Link copied"

                            "shared" ->
                                "Shared"

                            _ ->
                                "Copy failed"
                        )
              }
            , Process.sleep 2000 |> Task.perform (\_ -> ShareFaded n)
            )

        ShareFaded n ->
            if n == model.shares then
                ( { model | shareNote = Nothing }, Cmd.none )

            else
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

        PickedMode mode ->
            if mode == Play && not (complete model) then
                ( model, Cmd.none )

            else
                ( { model | mode = mode, press = Nothing }, Cmd.none )

        PressedPlayCandidate ->
            case playable model of
                Just c ->
                    choose c model

                Nothing ->
                    ( model, Cmd.none )

        CubeHold boardMsg ->
            let
                ( hold, step ) =
                    Board.stepHold boardMsg model.cubeHold

                held =
                    { model | cubeHold = hold }
            in
            case step of
                Board.Commit action ->
                    case cubeChoice action of
                        Just chosen ->
                            update (Chose chosen) held

                        Nothing ->
                            ( held, Cmd.none )

                Board.Wait ms later ->
                    ( held, Process.sleep ms |> Task.perform (\_ -> CubeHold later) )

                Board.Idle ->
                    ( held, Cmd.none )

        Chose chosen ->
            if complete model && endingHere model == Nothing then
                choose chosen model

            else
                ( model, Cmd.none )

        PressedRollForMe ->
            ( model, Random.generate RolledForMe (Random.pair (Random.int 1 6) (Random.int 1 6)) )

        RolledForMe roll ->
            updateOne (PickedRoll roll) model

        Walked i ->
            walk i model

        GotMoves n result ->
            if n /= model.movesAsked then
                ( model, Cmd.none )

            else
                case result of
                    Ok tree ->
                        ( { model | moves = MovesIn { tree = tree, puzzle = Nothing } }, Cmd.none )

                    Err err ->
                        ( { model | moves = MovesFailed (Api.errorMessage err) }, Cmd.none )

        GotNode n node result ->
            if n /= model.movesAsked then
                ( model, Cmd.none )

            else
                let
                    left =
                        { model | fetching = List.filter ((/=) node) model.fetching }
                in
                case ( result, model.moves ) of
                    ( Ok fetched, MovesIn m ) ->
                        let
                            tree =
                                m.tree
                        in
                        ( { left | moves = MovesIn { m | tree = { tree | nodes = Dict.insert node fetched tree.nodes } } }, Cmd.none )

                    -- the board keeps the last position it holds, and UNDO
                    -- backs out of the step
                    _ ->
                        ( left, Cmd.none )

        BoardOut out ->
            board out model

        NoOp ->
            ( model, Cmd.none )


{-| What PLAY THIS plays: the candidate on the board, or with none shown
the best, as the board it leaves and how it reads.
-}
playable : Model -> Maybe Setup.Chosen
playable model =
    case model.ask of
        Answered { answer } ->
            let
                candidate =
                    case shownCandidate model of
                        Just c ->
                            Just c

                        Nothing ->
                            answer.reveal.top |> List.filter (\c -> c.rank == Just 1) |> List.head
            in
            candidate
                |> Maybe.andThen
                    (\c -> c.position |> Maybe.map (\b -> Setup.Played { notation = c.notation, board = b }))

        _ ->
            Nothing


{-| A choice at the step on the board. The same choice as before walks on
along the line as it was; a different one drops the steps after this one
and makes the next from the game's rules -- or, where the game is over,
ends the line here. Choosing is playing: the board is in PLAY after it.
-}
choose : Setup.Chosen -> Model -> ( Model, Cmd Msg )
choose chosen model =
    let
        l =
            lineNow model

        playing =
            { model | mode = Play, line = l }
    in
    case stepAt l.at l.steps of
        Nothing ->
            ( model, Cmd.none )

        Just this ->
            let
                same =
                    Maybe.map (Setup.sameChoice chosen) this.chosen == Just True

                kept =
                    List.take l.at l.steps ++ [ { this | chosen = Just chosen } ]
            in
            if same && l.at < List.length l.steps - 1 then
                walk (l.at + 1) playing

            else
                case Setup.next chosen this.setup of
                    Ok nextSetup ->
                        let
                            fresh =
                                { setup = nextSetup, answer = Nothing, chosen = Nothing }
                        in
                        ( toStep (l.at + 1) fresh { playing | line = { steps = kept ++ [ fresh ], at = l.at } }
                        , scrollTo (l.at + 1)
                        )

                    -- not an answer to this step's question: nothing chosen
                    Err "" ->
                        ( model, Cmd.none )

                    Err _ ->
                        ( { playing | line = { steps = kept, at = l.at } }, scrollTo l.at )


{-| To step `i` of the line, with no fetch: its position, its answer, and
what was chosen there.
-}
walk : Int -> Model -> ( Model, Cmd Msg )
walk i model =
    let
        l =
            lineNow model
    in
    case stepAt i l.steps of
        Just s ->
            if i == l.at then
                ( model, Cmd.none )

            else
                ( toStep i s { model | line = l }, scrollTo i )

        Nothing ->
            ( model, Cmd.none )


{-| Step `i` on the board. Whatever was being asked about the step before
is dropped (an ask already out lands nowhere; asked again, the server has
it); its answer is kept with it.
-}
toStep : Int -> Step -> Model -> Model
toStep i s model =
    let
        l =
            model.line
    in
    { model
        | line = { l | at = i }
        , setup = s.setup
        , off = offFrom s.setup
        , ask =
            case s.answer of
                Just a ->
                    Answered a

                Nothing ->
                    NotAsked
        , asks = model.asks + 1
        , showing = Nothing
        , notice = Nothing
        , shareNote = Nothing
        , rolling = False
        , press = Nothing
    }
        |> freshMoves


freshMoves : Model -> Model
freshMoves model =
    { model | moves = NoMoves, path = [], fetching = [], swaps = 0, movesAsked = model.movesAsked + 1 }


{-| The plate of step `i` in view: the strip scrolls sideways under the
arrows. After a moment, so a plate just added is on the page.
-}
scrollTo : Int -> Cmd Msg
scrollTo i =
    Process.sleep 30
        |> Task.andThen
            (\_ ->
                Task.map3
                    (\p c v -> v.viewport.x + (p.element.x - c.element.x) - (c.element.width - p.element.width) / 2)
                    (Dom.getElement ("an-plate-" ++ String.fromInt i))
                    (Dom.getElement "an-plates")
                    (Dom.getViewportOf "an-plates")
            )
        |> Task.andThen (\x -> Dom.setViewportOf "an-plates" (max 0 x) 0)
        |> Task.attempt (\_ -> NoOp)


{-| What the table asked for: a step (or two) along the tree, a step back,
the turn committed, the dice swapped -- as the puzzle page walks one. A
step to a node a lazy tree does not hold yet fetches that level.
-}
board : Puzzle.Out -> Model -> ( Model, Cmd Msg )
board out model =
    case ( out, model.moves ) of
        ( Puzzle.Stepped nodes, MovesIn m ) ->
            let
                missing =
                    if m.tree.lazy then
                        List.filter (\n -> not (Dict.member n m.tree.nodes) && not (List.member n model.fetching)) nodes

                    else
                        []

                fetch node =
                    case m.puzzle of
                        Just id ->
                            Api.get model.session ("/papi/puzzles/" ++ id ++ "/tree?node=" ++ node) (D.field "tree" Puzzle.nodeDecoder) (GotNode model.movesAsked node)

                        Nothing ->
                            Analysis.movesLevel model.session model.setup node (GotNode model.movesAsked node)
            in
            ( { model | path = model.path ++ nodes, fetching = model.fetching ++ missing }, Cmd.batch (List.map fetch missing) )

        ( Puzzle.Undo, _ ) ->
            ( { model | path = List.take (List.length model.path - 1) model.path }, Cmd.none )

        ( Puzzle.Play, MovesIn m ) ->
            case Puzzle.nodeAt m.tree model.path of
                Just node ->
                    if node.terminal && endingHere model == Nothing then
                        choose (Setup.Played { notation = notation m.tree model.path, board = node.board }) model

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ( Puzzle.Swapped, _ ) ->
            ( { model | swaps = model.swaps + 1 }, Cmd.none )

        _ ->
            ( model, Cmd.none )


{-| Every change to the position goes through here: the line's notice and
any answer about the position before are gone with it.
-}
edit : (Setup -> Setup) -> Model -> Model
edit change model =
    editWith model.off change model


{-| An edit that may also change what is borne off (a tray, CLEAR, FLIP):
a checker borne off or taken back changes the position as much as one
moved on the board.
-}
editWith : Off -> (Setup -> Setup) -> Model -> Model
editWith off change model =
    let
        setup =
            normalize (change model.setup)
    in
    if setup == model.setup && off == model.off then
        -- nothing changed (the turn already White, the roll already 3-1):
        -- the answer is still about the position on the board
        { model | notice = Nothing }

    else
        let
            l =
                lineNow model

            fresh =
                { setup = setup, answer = Nothing, chosen = Nothing }

            -- Only the roll or the cube question of this step: the line
            -- up to it stands, and what came after it is gone (a line, not
            -- a tree). Anything else is another position, and a fresh line
            -- starts from it.
            line_ =
                if { setup | ask = model.setup.ask } == model.setup && off == model.off then
                    { steps = List.take l.at l.steps ++ [ fresh ], at = l.at }

                else
                    { steps = [ fresh ], at = 0 }
        in
        freshMoves { model | setup = setup, off = off, notice = Nothing, ask = NotAsked, showing = Nothing, line = line_ }


{-| ANALYZE (or TRY AGAIN): ask about the position as it stands. Each
press is numbered, so whatever comes back for an earlier one is dropped.
-}
analyze : Model -> ( Model, Cmd Msg )
analyze model =
    if analyzable model then
        let
            n =
                model.asks + 1
        in
        ( { model | asks = n, ask = Asking { seconds = 0, key = Nothing, out = True }, showing = Nothing, shareNote = Nothing }
        , Cmd.batch [ Analysis.ask model.session model.setup (GotAsk n), tick n ]
        )

    else
        ( model, Cmd.none )


tick : Int -> Cmd Msg
tick n =
    Process.sleep 1000 |> Task.perform (\_ -> Ticked n)


{-| A status, from the POST (`fresh`) or a poll: an answer, a key to keep
asking about, or the engine's failure.
-}
landed : Bool -> { seconds : Int, key : Maybe String, out : Bool } -> Analysis.Status -> Model -> ( Model, Cmd Msg )
landed fresh asking status model =
    case status of
        Analysis.Done answer ->
            ( { model | ask = Answered { answer = answer, cached = fresh } }, Cmd.none )

        Analysis.Pending key ->
            ( { model | ask = Asking { asking | key = Just key, out = False } }, Cmd.none )

        Analysis.Failed message ->
            ( { model | ask = Refused { message = message, retry = True, wait = 0 } }, Cmd.none )


{-| A refusal, in the server's sentence. A roll that plays nothing, and a
position the server will not take, are not tried again; the rest are,
once the wait the server named has passed.
-}
refused : Analysis.Refusal -> Model -> ( Model, Cmd Msg )
refused refusal model =
    let
        code =
            Api.errorCode refusal.error

        wait =
            Maybe.withDefault 0 refusal.retryAfter
    in
    ( { model
        | ask =
            Refused
                { message = Api.errorMessage refusal.error
                , retry = not (List.member code [ "dances", "validation_failed" ])
                , wait = wait
                }
      }
    , if wait > 0 then
        tick model.asks

      else
        Cmd.none
    )


editMatch : (Match -> Match) -> Model -> Model
editMatch change =
    edit (\s -> { s | match = Maybe.map change s.match })


{-| The two settings the strip cannot show wrongly, made right on the way
in from every door (an id, a puzzle, MATCH TO coming back) and after every
edit: Crawford only stands while somebody is one away, and a cube at 1
sits in the middle.
-}
normalize : Setup -> Setup
normalize s =
    { s
        | match = Maybe.map (\m -> { m | crawford = m.crawford && oneAway m }) s.match
        , cubeOwner =
            if s.cubeValue == 1 then
                Nothing

            else
                s.cubeOwner
    }


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
    if model.showing /= Nothing then
        -- An engine's play is on the board, not the position being set up:
        -- a tap takes it back, as the dice do, rather than paint on a board
        -- that is not the one shown.
        { model | showing = Nothing }

    else
        paintAt button target model


paintAt : Button -> Target -> Model -> Model
paintAt button target model =
    case paint model.brush button target ( model.setup, model.off ) of
        Ok ( setup, off ) ->
            editWith off (\_ -> setup) model

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
            ( { model | presses = seq, spent = Nothing, press = Just { zone = zone, touch = touch, x = x, y = y, seq = seq, long = False } }
            , if touch then
                Process.sleep longPressMs |> Task.perform (\_ -> LongPressed seq)

              else
                Cmd.none
            )

        Board.Moved x y ->
            case model.press of
                Just p ->
                    if not p.long && (abs (x - p.x) > slop || abs (y - p.y) > slop) then
                        ( dropped p model, Cmd.none )

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
            case model.press of
                Just p ->
                    ( dropped p model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

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
                    if model.spent == Just zone then
                        -- the phone's right click for a press already dropped
                        ( { model | spent = Nothing }, Cmd.none )

                    else
                        ( pressed Secondary zone model, Cmd.none )


{-| A press let go of without acting: a finger's is remembered, so the
right click a phone sends for it late does not paint.
-}
dropped : Press -> Model -> Model
dropped p model =
    { model
        | press = Nothing
        , spent =
            if p.touch then
                Just p.zone

            else
                Nothing
    }



-- VIEW


view : Model -> Html Msg
view model =
    let
        shown =
            shownCandidate model
    in
    div
        [ classList
            [ ( "rp-page an-page paper", True )
            , ( flashClass model, model.refused /= Nothing )
            ]
        , id "analysis"

        -- The position as an XGID, for the browser smokes to read back
        -- (the page shows none): empty while a checker is not placed,
        -- since an id would count those as borne off.
        , attribute "data-xgid"
            (if toPlace White ( model.setup, model.off ) == 0 && toPlace Black ( model.setup, model.off ) == 0 then
                Xgid.encode model.setup

             else
                ""
            )
        ]
        [ div [ class "rp-head" ]
            [ span [ class "rp-tag pixel text-[7px] sm:text-[8px]" ] [ text "ANALYSIS" ]
            , viewModes model
            ]
        , div [ class "rp-main" ]
            [ div [ class "rp-stage" ]
                [ case model.mode of
                    SetUp ->
                        viewBrushes model

                    Play ->
                        viewPlayRow model
                , div
                    [ classList
                        [ ( "rp-board an-board", True )
                        , ( "is-playing", model.mode == Play )
                        , ( "is-proposed", shown /= Nothing )
                        , ( "dice-played", shown /= Nothing )
                        , ( "cube-chose-" ++ Maybe.withDefault "" (chosenCube model), model.mode == Play && chosenCube model /= Nothing )
                        ]
                    , id "an-board"
                    ]
                    [ viewBoard model
                    , case shown of
                        Just c ->
                            span [ class "rp-proposed an-proposed pixel text-[7px]", id "an-proposed" ]
                                [ text
                                    (if c.rank == Just 1 then
                                        "BEST PLAY"

                                     else
                                        "ENGINE'S #" ++ (c.rank |> Maybe.map String.fromInt |> Maybe.withDefault "")
                                    )
                                ]

                        Nothing ->
                            text ""
                    , case shown of
                        Just _ ->
                            -- Over the dice, as the replay's: a tap takes the
                            -- play back off the board.
                            button
                                [ type_ "button"
                                , class
                                    ("rp-dice-toggle "
                                        ++ (if model.setup.toPlay == viewer model then
                                                "is-right"

                                            else
                                                "is-left"
                                           )
                                    )
                                , id "an-dice-toggle"
                                , attribute "aria-label" "Take the play back: the position as it was set up"
                                , Html.Attributes.title "Back to the position"
                                , onClick (Show Nothing)
                                ]
                                []

                        Nothing ->
                            text ""
                    ]
                , viewLine model
                ]
            , div [ class "rp-side an-side" ]
                [ viewStrip model
                , viewQuick model
                , viewCheck model
                , viewAnalyze model

                -- The answer's place. Under everything else here, so
                -- whatever fills it moves nothing above it, and its slot
                -- keeps a height of its own (`.an-panel`'s min-height) so
                -- the page's height does not change when it fills or
                -- clears.
                , div [ class "an-panel", id "an-panel", attribute "aria-live" "polite" ] (viewPanel model)
                ]
            ]
        , if model.rolling then
            viewRollSheet model

          else
            text ""
        , case model.save of
            Just sheet ->
                Html.map SaveMsg (SaveToSet.view sheet)

            Nothing ->
                text ""
        ]


{-| Who sits at the bottom: White while the position is set up; in PLAY
the player acting, in their own colour, as at a table (the table can only
be played from the bottom).
-}
viewer : Model -> Color
viewer model =
    case model.mode of
        SetUp ->
            White

        Play ->
            model.setup.toPlay


scores : Model -> List ( String, Int )
scores model =
    case model.setup.match of
        Just m ->
            [ ( Setup.colorId White, m.white ), ( Setup.colorId Black, m.black ) ]

        Nothing ->
            []


{-| The board: the editor while setting up; in PLAY the puzzle page's
table on the roll's legal plays once they are here, else the position as
a picture. A candidate shown is a picture either way.
-}
viewBoard : Model -> Html Msg
viewBoard model =
    case ( model.mode, shownCandidate model, ( model.setup.ask, model.moves ) ) of
        ( SetUp, _, _ ) ->
            Board.viewEdit
                { still = still model
                , zoneId = zoneId
                , onEdit = Pointer
                , noop = NoOp
                }

        ( Play, Nothing, ( Move (Just roll), MovesIn m ) ) ->
            Html.map BoardOut (Puzzle.view (table model roll m.tree))

        -- A cube step is answered in the board's band, as at the table and
        -- on a cube puzzle: DOUBLE or ROLL on roll, TAKE or DROP doubled.
        ( Play, Nothing, ( Double, _ ) ) ->
            cubeBoard model False

        ( Play, Nothing, ( Take, _ ) ) ->
            cubeBoard model True

        ( Play, _, _ ) ->
            Board.viewStillTurn NoOp (still model)


{-| A cube step in PLAY on the table's slab, its answers in the band; a
step the line already ended at is a picture.
-}
cubeBoard : Model -> Bool -> Html Msg
cubeBoard model take =
    if endingHere model == Nothing then
        Html.map CubeHold (Board.viewCubeAsk { still = still model, take = take, hold = model.cubeHold })

    else
        Board.viewStillTurn NoOp (still model)


{-| The answer a cube step's band button is (DOUBLE, TAKE and DROP once
held, ROLL at a tap: `Board.stepHold`).
-}
cubeChoice : String -> Maybe Setup.Chosen
cubeChoice action =
    case action of
        "double" ->
            Just Setup.Doubled

        "roll" ->
            Just Setup.NoDouble

        "take" ->
            Just Setup.Took

        "drop" ->
            Just Setup.Passed

        _ ->
            Nothing


{-| The table's action a cube step's answer was, for the band to keep it
shown (`.cube-chose-*`).
-}
chosenCube : Model -> Maybe String
chosenCube model =
    case here model |> Maybe.andThen .chosen of
        Just Setup.Doubled ->
            Just "double"

        Just Setup.NoDouble ->
            Just "roll"

        Just Setup.Took ->
            Just "take"

        Just Setup.Passed ->
            Just "drop"

        _ ->
            Nothing


{-| The roll on the puzzle page's table: the mover's seat in their own
colour at the bottom, the tree as the server built it (from the mover's
side), the cube and the score as the setup has them.
-}
table : Model -> ( Int, Int ) -> Puzzle.Tree -> Puzzle.Table
table model ( a, b ) tree =
    let
        s =
            model.setup

        seat color =
            { id = Setup.colorId color, name = Setup.colorName color }

        emptySide =
            { points = List.repeat 24 0, bar = 0, off = 0 }
    in
    { question =
        { board =
            Dict.get tree.root tree.nodes
                |> Maybe.map .board
                |> Maybe.withDefault { white = emptySide, black = emptySide }
        , dice = [ a, b ]
        , cube =
            { value = s.cubeValue
            , owner =
                case s.cubeOwner of
                    Nothing ->
                        "center"

                    Just owner ->
                        if owner == s.toPlay then
                            "mover"

                        else
                            "opponent"
            }
        , score = Nothing
        , crawford = Maybe.map .crawford s.match == Just True
        , jacoby = s.match == Nothing
        }
    , tree = tree
    , path = model.path
    , mover = seat s.toPlay
    , opponent = seat (Setup.other s.toPlay)
    , scores = scores model
    , theme = theme model
    , swaps = model.swaps
    , key = model.movesAsked
    , moverColor = Setup.colorId s.toPlay
    }


{-| SET UP or PLAY, at the head's right end. PLAY waits for a complete
position.
-}
viewModes : Model -> Html Msg
viewModes model =
    let
        seg segId mode label enabled =
            button
                [ type_ "button"
                , id segId
                , classList [ ( "an-seg an-mode", True ), ( "is-on", model.mode == mode ) ]
                , attribute "aria-pressed" (boolString (model.mode == mode))
                , disabled (not enabled)
                , onClick (PickedMode mode)
                ]
                [ text label ]
    in
    div [ class "an-segs an-modes", id "an-modes" ]
        [ seg "an-mode-setup" SetUp "SET UP" True
        , seg "an-mode-play" Play "PLAY" (complete model)
        ]


{-| In PLAY, the row over the board (the brushes' own slot): what the step
on the board asks for -- a roll (ROLL FOR ME), the checkers moved on the
table, a cube answer in the board's band (DOUBLE or ROLL, TAKE or DROP,
`cubeBoard`) -- or the sentence the line ended in.
-}
viewPlayRow : Model -> Html Msg
viewPlayRow model =
    let
        -- a roll still to come: "Pick a roll" is what this row answers
        free actId label msg =
            button [ type_ "button", id actId, class "q-btn plain an-act pixel", onClick msg ] [ text label ]

        hint words =
            span [ class "an-hint an-play-hint", id "an-play-hint" ] [ text words ]
    in
    div [ class "an-brushes an-playrow", id "an-play-row" ]
        (case endingHere model of
            Just sentence ->
                [ span [ class "an-play-end", id "an-line-end" ] [ text sentence ] ]

            Nothing ->
                case model.setup.ask of
                    Move Nothing ->
                        -- The strip is SET UP's, so the row offers what a
                        -- player on roll can do: roll (at random or a roll
                        -- picked from the sheet), or double first where the
                        -- cube allows and the line did not just say no.
                        [ button [ type_ "button", id "an-roll-random", class "q-btn yellow an-act an-roll-random pixel", onClick PressedRollForMe ] [ text "ROLL FOR ME" ]
                        , free "an-roll-pick" "PICK A ROLL" OpenedRolls
                        , if mayDouble model then
                            free "an-roll-double" "DOUBLE?" PickedDouble

                          else
                            text ""
                        ]

                    Move (Just _) ->
                        [ hint
                            (case ( Setup.check model.setup, model.moves ) of
                                ( Just reason, _ ) ->
                                    reason

                                ( Nothing, MovesIn m ) ->
                                    case Dict.get m.tree.root m.tree.nodes of
                                        Just root ->
                                            if root.children == [] then
                                                "No legal play: PLAY passes the turn"

                                            else
                                                "Move the checkers, then PLAY"

                                        Nothing ->
                                            "Move the checkers, then PLAY"

                                ( Nothing, MovesFailed message ) ->
                                    message

                                _ ->
                                    "Finding the legal plays…"
                            )
                        ]

                    -- The answers are the board's band's, as at the table.
                    Double ->
                        [ hint "Double, or roll? Answer on the board" ]

                    Take ->
                        [ hint "Take, or drop? Answer on the board" ]
        )


{-| In PLAY, the player on roll may turn to the cube first: where the cube
lets them, and unless the step before was this very player saying NO
DOUBLE (the line would only go round).
-}
mayDouble : Model -> Bool
mayDouble model =
    let
        l =
            lineNow model

        saidNo =
            case stepAt (l.at - 1) l.steps of
                Just before ->
                    before.chosen == Just Setup.NoDouble

                Nothing ->
                    False
    in
    Setup.canDouble model.setup.toPlay model.setup && not saidNo


{-| The line under the board: the four arrows outside, a plate per step
between them, the one on the board marked. Always there, one plate or
twenty, at the same height; the plates scroll sideways.
-}
viewLine : Model -> Html Msg
viewLine model =
    let
        l =
            lineNow model

        last =
            List.length l.steps - 1

        to i =
            if i /= l.at && i >= 0 && i <= last then
                Just (Walked i)

            else
                Nothing

        plateButton i s =
            button
                [ type_ "button"
                , id ("an-plate-" ++ String.fromInt i)
                , classList [ ( "an-plate", True ), ( "is-on", i == l.at ) ]
                , attribute "aria-current" (boolString (i == l.at))
                , attribute "aria-label" (Setup.colorName s.setup.toPlay ++ String.dropLeft 1 (plate s))
                , onClick (Walked i)
                ]
                -- the colour as a checker, as the board draws it, in place
                -- of the plate's W or B
                [ span [ class ("an-chip " ++ Setup.colorId s.setup.toPlay), attribute "aria-hidden" "true" ] []
                , span [ attribute "aria-hidden" "true" ] [ text (String.dropLeft 2 (plate s)) ]
                ]
    in
    div [ class "an-line-wrap" ]
        [ Scrub.row { id = "an-line", stale = False }
            { first = ( "an-first", to 0 )
            , back = ( "an-prev", to (l.at - 1) )
            , forward = ( "an-next", to (l.at + 1) )
            , last = ( "an-last", to last )
            }
            [ div [ class "an-plates", id "an-plates" ] (List.indexedMap plateButton l.steps) ]
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
    , viewer = Setup.colorId (viewer model)
    , scores = scores model
    , cube = True
    , theme = theme model
    , key = 0
    , position = snapshot model
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
    , landed =
        case shownCandidate model of
            Just c ->
                -- the candidate's points are the mover's, counted as White's
                if setup.toPlay == White then
                    c.landed

                else
                    List.map (\p -> 25 - p) c.landed

            Nothing ->
                []
    , offer =
        case setup.ask of
            Take ->
                Just (Setup.colorId doubler)

            _ ->
                Nothing
    , accounts = Nothing
    }


{-| The candidate whose play is on the board, when one is.
-}
shownCandidate : Model -> Maybe Puzzle.Candidate
shownCandidate model =
    case ( model.showing, model.ask ) of
        ( Just rank, Answered { answer } ) ->
            answer.reveal.top
                |> List.filter (\c -> c.rank == Just rank && c.position /= Nothing)
                |> List.head

        _ ->
            Nothing


{-| The position on the board: the one set up, or the one a candidate
leaves. A candidate's board is the mover's, drawn as White (as every
puzzle is), so for Black to play it is turned back round.
-}
shownSetup : Model -> Setup
shownSetup model =
    let
        setup =
            model.setup
    in
    case shownCandidate model |> Maybe.andThen .position of
        Just b ->
            let
                asWhite =
                    { setup
                        | points = List.map2 (-) b.white.points b.black.points
                        , whiteBar = b.white.bar
                        , blackBar = b.black.bar
                    }

                placed =
                    if setup.toPlay == White then
                        asWhite

                    else
                        Setup.flip asWhite
            in
            { setup | points = placed.points, whiteBar = placed.whiteBar, blackBar = placed.blackBar }

        Nothing ->
            setup


{-| The board as the slab draws it, with the trays holding what the page
says is borne off rather than everything not on the board. A candidate's
play on the board is of a complete position, whose off is the wire's.
-}
snapshot : Model -> Board.Snapshot
snapshot model =
    let
        drawn =
            Setup.snapshot (shownSetup model)

        white =
            drawn.white

        black =
            drawn.black
    in
    if shownCandidate model /= Nothing then
        drawn

    else
        { drawn | white = { white | off = model.off.white }, black = { black | off = model.off.black } }


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

        -- A colour's checkers not placed yet, on its brush: the pool a tap
        -- paints from. Always there, hidden at none, so nothing moves.
        left color =
            let
                n =
                    toPlace color ( model.setup, model.off )
            in
            span
                [ classList [ ( "an-left", True ), ( "is-none", n == 0 ) ]
                , id ("an-left-" ++ Setup.colorId color)
                , attribute "aria-label" (String.fromInt n ++ " to place")
                ]
                [ text (String.fromInt n) ]

        -- "adds White" -> "White": the narrow phone's hint
        short words =
            String.replace "adds " "" words

        -- the whole hint, and the one a narrow phone has room for, both
        -- always on the page: CSS shows one
        hint kind ( long, narrow ) =
            span [ class ("an-hint " ++ kind) ]
                [ span [ class "an-hint-long" ] [ text long ]
                , span [ class "an-hint-short" ] [ text narrow ]
                ]
    in
    div [ class "an-brushes", id "an-brushes" ]
        [ brushButton "an-brush-white" (Paint White) "White checkers" [ span [ class "an-chip white" ] [], left White ]
        , brushButton "an-brush-black" (Paint Black) "Black checkers" [ span [ class "an-chip black" ] [], left Black ]
        , brushButton "an-brush-remove" Erase "Take checkers off" [ span [ class "an-x" ] [ text "✕" ] ]
        , hint "an-hint-touch"
            (if model.brush == Erase then
                ( "Tap takes one off", "Tap: one off" )

             else
                ( "Tap " ++ tap ++ " · hold " ++ other, "Tap: " ++ short tap ++ " · hold: " ++ short other )
            )
        , hint "an-hint-mouse"
            (if model.brush == Erase then
                ( "Click takes one off", "Click: one off" )

             else
                ( "Click " ++ tap ++ " · right-click " ++ other, "Click: " ++ short tap ++ " · right: " ++ short other )
            )
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

        -- A colour to play, drawn as the board draws it with its word; the
        -- one chosen is ringed and in bold, never a checker on an
        -- inverted tile, which reads as the other colour.
        who color =
            let
                on =
                    setup.toPlay == color
            in
            button
                [ type_ "button"
                , id ("an-turn-" ++ Setup.colorId color)
                , classList [ ( "an-who", True ), ( "is-on", on ) ]
                , attribute "aria-pressed" (boolString on)
                , attribute "aria-label" (Setup.colorName color ++ " to play")
                , onClick (PickedTurn color)
                ]
                [ span [ class ("an-chip " ++ Setup.colorId color) ] []
                , span [ class "an-who-word pixel" ] [ text (String.toUpper (Setup.colorName color)) ]
                ]

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
    -- A fieldset, so PLAY disables every control in it at once: the
    -- position is edited in SET UP only. Same boxes either way.
    Html.fieldset
        [ classList [ ( "an-strip", True ), ( "is-locked", model.mode == Play ) ]
        , id "an-strip"
        , disabled (model.mode == Play)
        ]
        [ div [ class "an-row" ]
            [ group "TO PLAY"
                [ div [ class "an-whos", id "an-turn", attribute "role" "group", attribute "aria-label" "To play" ]
                    [ who White, who Black ]
                ]
            , group "ASK"
                [ div [ class "an-segs", id "an-ask" ]
                    [ seg "an-dice" isMove OpenedRolls [ viewDice setup.ask model.lastRoll ]
                    , seg "an-ask-double" (setup.ask == Double) PickedDouble [ text "DOUBLE?" ]
                    , seg "an-ask-take" (setup.ask == Take) PickedTake [ text "TAKE?" ]
                    ]
                ]
            ]
        , div [ class "an-row" ]
            [ group "CUBE"
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
            , group "GAME"
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
            ]
        , div [ class "an-row" ]
            [ group "SCORE"
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
                        , disabled (not (inMatch && (oneAway m || m.crawford)))
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
        -- In PLAY the board is played, not set up: the quick starts wait
        -- for SET UP.
        locked =
            model.mode == Play

        quick quickId label msg =
            button [ type_ "button", id quickId, class "q-btn plain an-quick pixel", onClick msg ] [ text label ]
    in
    div [ class "an-quicks" ]
        [ Html.fieldset
            [ classList [ ( "an-quick-row", True ), ( "is-locked", locked ) ]
            , disabled locked
            ]
            [ quick "an-opening" "OPENING" PressedOpening
            , quick "an-clear" "CLEAR" PressedClear
            , quick "an-flip" "FLIP" PressedFlip
            ]
        ]


viewCheck : Model -> Html Msg
viewCheck model =
    Html.p [ class "an-check", id "an-check", attribute "aria-live" "polite" ]
        [ text (line model |> Maybe.withDefault "") ]


{-| ANALYZE, or while the press is out a plate of the same size counting
the seconds, with the thin bar the page loads with.
-}
viewAnalyze : Model -> Html Msg
viewAnalyze model =
    case model.ask of
        Asking a ->
            div [ class "an-analyze an-asking pixel", id "an-asking", attribute "role" "status" ]
                [ span [ class "an-asking-text" ] [ text ("ASKING THE ENGINE… " ++ String.fromInt a.seconds ++ " s") ]
                , span [ class "an-asking-track", attribute "aria-hidden" "true" ] [ span [ class "an-asking-fill" ] [] ]
                ]

        _ ->
            button
                [ type_ "button"
                , id "an-analyze"
                , class "q-btn yellow an-analyze pixel"
                , disabled (not (analyzable model))
                , onClick PressedAnalyze
                ]
                [ text "ANALYZE" ]


viewPanel : Model -> List (Html Msg)
viewPanel model =
    case model.ask of
        NotAsked ->
            [ Html.p [ class "an-panel-hint" ] [ text "The engine's answer lands here: its best plays with their chances, or its call on the cube." ] ]

        Asking _ ->
            [ Html.p [ class "an-panel-hint" ] [ text "Asking the engine at 4-ply. A few seconds for a roll, less for the cube." ] ]

        Refused r ->
            [ div [ class "an-refused", id "an-refused" ]
                [ Html.p [ class "an-refused-text", id "an-refused-text" ] [ text r.message ]
                , if r.retry then
                    button
                        [ type_ "button"
                        , id "an-retry"
                        , class "q-btn plain an-retry pixel"
                        , disabled (r.wait > 0)
                        , onClick PressedRetry
                        ]
                        [ text
                            (if r.wait > 0 then
                                "TRY AGAIN · " ++ waitLabel r.wait

                             else
                                "TRY AGAIN"
                            )
                        ]

                  else
                    text ""
                ]
            ]

        Answered { answer, cached } ->
            [ div [ class "rp-note an-answer", id "an-answer", attribute "data-kind" answer.puzzle.kind ]
                (viewAnswer model answer
                    ++ [ div [ class "an-foot" ]
                            [ span [ class "an-depth", id "an-depth" ] [ text (depthLine answer cached) ]
                            , span [ class "an-share-note", id "an-share-note" ] [ text (Maybe.withDefault "" model.shareNote) ]
                            ]

                       -- Two rows of fixed cells: PLAY THIS (or PLAY BEST,
                       -- or for the cube PLAY IT OUT) across the first; SAVE,
                       -- SHARE and OPEN AS PUZZLE under it (2 + 1 where three
                       -- do not fit).
                       , div [ class "an-actions", id "an-actions" ]
                            [ viewPlayAction model answer
                            , button [ type_ "button", id "an-save", class "q-btn plain an-action an-action-third pixel", onClick PressedSave ] [ text "SAVE" ]
                            , button [ type_ "button", id "an-share", class "q-btn plain an-action an-action-third pixel", onClick PressedShare ] [ text "SHARE" ]
                            , a
                                [ id "an-open-puzzle"
                                , class "q-btn plain an-action an-action-third an-action-last pixel"
                                , href (Route.href (Route.puzzle answer.puzzle.id))
                                , Html.Attributes.target "_blank"
                                , Html.Attributes.rel "noopener"
                                ]
                                [ text "OPEN AS PUZZLE" ]
                            ]
                       ]
                )
            ]


{-| The answer's door into the line. For a move, PLAY THIS: the candidate
on the board, or the best with none shown (PLAY BEST). For the cube, PLAY
IT OUT: the board into PLAY, where DOUBLE and TAKE are answered over it.
One cell, whatever it says.
-}
viewPlayAction : Model -> Analysis.Answer -> Html Msg
viewPlayAction model answer =
    let
        cell cellId label msg enabled =
            button
                [ type_ "button"
                , id cellId
                , class "q-btn yellow an-action an-action-wide pixel"
                , disabled (not enabled)
                , onClick msg
                ]
                [ text label ]

        open =
            endingHere model == Nothing
    in
    case answer.reveal.cube of
        Nothing ->
            cell "an-play-candidate"
                (if model.showing == Nothing then
                    "PLAY BEST"

                 else
                    "PLAY THIS"
                )
                PressedPlayCandidate
                (open && playable model /= Nothing)

        Just _ ->
            cell "an-play-out" "PLAY IT OUT" (PickedMode Play) (open && model.mode == SetUp)


{-| "42 s", "14 min".
-}
waitLabel : Int -> String
waitLabel seconds =
    if seconds < 60 then
        String.fromInt seconds ++ " s"

    else
        String.fromInt ((seconds + 59) // 60) ++ " min"


{-| The quiet line under an answer: how deep the engine looked, and
whether this press asked it or found the position analyzed already.
"4-ply · asked just now", "4-ply · already analyzed".
-}
depthLine : Analysis.Answer -> Bool -> String
depthLine answer cached =
    let
        when =
            if cached then
                "already analyzed"

            else
                "asked just now"

        level =
            answer.reveal.levels
                |> Maybe.map
                    (\l ->
                        if answer.reveal.cube == Nothing then
                            l.moves

                        else
                            l.cube
                    )
                |> Maybe.map plies
    in
    case level of
        Just depth ->
            depth ++ " · " ++ when

        Nothing ->
            String.toUpper (String.left 1 when) ++ String.dropLeft 1 when


{-| The engine's name for a depth, as a player reads it: "4ply" -> "4-ply".
-}
plies : String -> String
plies level =
    if String.endsWith "ply" level && not (String.endsWith "-ply" level) then
        String.dropRight 3 level ++ "-ply"

    else
        level


{-| The engine's answer: for a move, the best play in a sentence (or the
play on the board, against the best) over the candidate table; for a cube
question, the sentence, the three equities and the chances.
-}
viewAnswer : Model -> Analysis.Answer -> List (Html Msg)
viewAnswer model answer =
    let
        reveal =
            answer.reveal

        mover =
            model.setup.toPlay

        name =
            Setup.colorName mover

        otherName =
            Setup.colorName (Setup.other mover)
    in
    case ( reveal.cube, reveal.best ) of
        ( Just cube, _ ) ->
            let
                review =
                    { action = ""
                    , response = Nothing
                    , optimal = Puzzle.optimalOf answer.puzzle.kind cube
                    , noDouble = cube.noDouble
                    , doubleTake = cube.doubleTake
                    , doublePass = cube.doublePass
                    , probs = cube.probs
                    , doubler = { seat = 0, grade = "", equityLost = 0, mistake = Nothing }
                    , taker = Nothing
                    }

                -- The replay's sentence for the position, from the side
                -- being asked: the doubler, or for a take the taker.
                words =
                    case ( answer.puzzle.kind, review.optimal ) of
                        ( "take", _ ) ->
                            Words.answerWhy name review

                        ( _, Replay.NoDouble ) ->
                            Words.noDoubleWhy name otherName review

                        _ ->
                            Words.doubleWhy name otherName review

                -- What was asked, with its stakes, in the board's colours:
                -- "Black redoubles to 4. Take?"
                asked =
                    Words.cubeQuestion
                        { take = answer.puzzle.kind == "take"
                        , asked = name
                        , doubler = otherName
                        , value = model.setup.cubeValue
                        , owned = model.setup.cubeOwner /= Nothing
                        }
            in
            [ Html.p [ class "an-answer-ask", id "an-answer-ask" ] [ text asked ]
            , Words.inWords words
            , Words.cubeLine review
            , Words.cubeChances name review
            ]

        ( Nothing, Just best ) ->
            [ case shownCandidate model of
                Just c ->
                    if c.rank == Just 1 then
                        Words.bestInWords (Puzzle.asReplayCandidate best)

                    else
                        Words.candidateInWords (Puzzle.asReplayCandidate c) (Puzzle.asReplayCandidate best)

                Nothing ->
                    Words.bestInWords (Puzzle.asReplayCandidate best)
            , Candidates.view [ class "an-top", id "an-candidates" ]
                (reveal.top
                    |> List.map
                        (\c ->
                            let
                                on_ =
                                    c.rank /= Nothing && c.rank == model.showing
                            in
                            { rank = c.rank
                            , notation = c.notation
                            , equity = Maybe.withDefault 0 c.equity
                            , equityLost = c.equityLost
                            , probs = c.probs
                            , on = on_

                            -- the play chosen at this step of the line
                            , played =
                                case ( here model |> Maybe.andThen .chosen, c.position ) of
                                    ( Just (Setup.Played p), Just b ) ->
                                        p.board == b

                                    _ ->
                                        False
                            , badge = Nothing
                            , title =
                                if on_ then
                                    "Back to the position"

                                else
                                    "Show this play on the board"
                            , onTap =
                                if c.position == Nothing then
                                    Nothing

                                else if on_ then
                                    Just (Show Nothing)

                                else
                                    Just (Show c.rank)
                            , attrs = []
                            }
                        )
                )
            ]

        ( Nothing, Nothing ) ->
            [ Html.p [ class "rp-words" ] [ text "The engine had nothing to say about this one." ] ]


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


boolString : Bool -> String
boolString b =
    if b then
        "true"

    else
        "false"
