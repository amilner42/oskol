port module Page.Puzzle exposing
    ( After(..)
    , Attempt(..)
    , Celebration
    , CelebrationDeck(..)
    , DeckToday
    , End
    , Loadable(..)
    , Model
    , Msg(..)
    , Answer
    , Out(..)
    , Progress
    , Score
    , Way(..)
    , WayState(..)
    , asksMemory
    , countsToday
    , dueDate
    , attemptBody
    , backIn
    , celebrate
    , celebrationRead
    , celebrationTiming
    , endRun
    , init
    , levelLine
    , levelLineFor
    , memoryLine
    , offering
    , masteredLine
    , preselected
    , runProgress
    , runScore
    , subscriptions
    , title
    , update
    , view
    , withAnswered
    , withSession
    )

{-| `/puzzles/:id` — one position and its question. The board, the dice,
the score and cube, and "White to play 6-4. What's your play?"; the
player plays the roll on the board as at the table and presses PLAY (or,
on a cube question, answers double or not, take or pass), and only then the reveal:
the verdict, their move against the best in the replay's own words, the
candidate table, and for a cube the engine's band on the same scale.

Nothing here decides anything about backgammon or about the answer. The
question and every legal way to play it come from `GET /papi/puzzles/:id`
(never the answer -- it is not in that response, and the page fetches
nothing else until PLAY); the verdict and the reveal come from the attempt.
A tree too big to send whole arrives `lazy`, and the page fetches each
level as the board reaches it.

For a signed-in player whose deck holds the card, the reveal carries where
it now stands ("Level 2 → 3 · back in 7 days") and the four choices that
override the grade. SOONER, GOT IT and KNEW IT **apply on tap**: the
tap sends it, the choice is drawn in force, and the fixed line under the
row says what it did; another tap replaces it (the server replaces the
review an override names, it never stacks one). NEVER cannot be undone,
so it alone asks first: its tap explains, and "YES, NEVER" sends it. For a
player who was in the game the puzzle came from,
either seat, `/mine` adds the memory line, asked for after the attempt and
never before. A guest sees neither, and loses nothing.

Sharing is two buttons after the reveal. SHARE copies the clean link. For
the player whose own mistake it was (the memory line says "you"), "Share
with my mistake" asks the server for a story link (`POST .../shares`) and
copies that: it opens as the same puzzle with `?s=`, and after the friend's
own attempt the reveal carries the `story` -- the sharer's name and move,
in the server's words -- which this page shows under the memory line. The
`?s=` the page was opened with rides on the attempt and nowhere else.

The page is opened from a link most of the time and is complete on its
own. NEXT appears only when the shell says there is somewhere after this
one: a practice run is the shell's (`Main`, `Run`), because it outlives
this page. The page reports each verdict (`Answered`) and asks for the
next (`WantsNext`); past the ids the run holds the shell asks the deck's
queue again, and only when that is empty -- or at I'M DONE -- does it
answer with the score (`endRun`), and the page ends the run here: "7 of
10 right", then for an account the way on (`offering`: KEEP GOING, or
PRACTICE ANYWAY once everything is started) and for a guest the sign-in,
in the one component, going on to wherever the run was started from (the
practice home, or the table a result card's PRACTICE was pressed at).

-}

import Api
import Api.Practice exposing (Today)
import Dict
import Games.Backgammon.Puzzle as Puzzle exposing (Candidate, Puzzle, Reveal, Schedule, Verdict(..))
import Games.Backgammon.Replay as Replay
import Games.Backgammon.View as Board
import Games.Backgammon.Words as Words exposing (chanceCells, cubeChances, cubeLine, gradeTag, signed)
import Html exposing (Html, a, button, div, h1, p, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, href, id, type_)
import Html.Events exposing (on, onClick, onFocus)
import Json.Decode as D
import Json.Encode as E
import Page.Play exposing (shareInvite, shareResult)
import Process
import Random
import Route
import Session exposing (Session)
import Task
import Time
import Svg
import Svg.Attributes as SvgA
import Ui.Charts as Charts
import Api.Decks
import Api.PracticeDecks as PracticeDecks
import Ui.Deck
import Ui.Decks as Decks
import Ui.Mistakes as Mistakes
import Ui.Shell
import Ui.SignIn as SignIn



-- MODEL


type Loadable a
    = Loading
    | Loaded a
    | Missing -- no such puzzle: the page's own 404
    | Unavailable String


{-| Where the answer stands: not made, on its way, revealed, or refused
(a 422 the board should never produce; the board stays so it can be
played again).
-}
type Attempt
    = NotYet
    | Sending
    | Revealed Reveal
    | Refused String


{-| Where this puzzle sits in the run the shell is keeping: which one it
is, and what happened at each one so far, in order. `Nothing` is a
puzzle opened from a link, which is not in a session and says nothing
about one.

The marks are the shell's (`Main.run`) at the moment the page opened;
this page adds its own as it is answered, which is the only one it can
change.
-}
type alias Progress =
    { at : Int
    , marks : List (Maybe Verdict)

    -- Today's set of the deck the run is of, as the shell has counted it:
    -- the ring over the board. Nothing for a run of one game's mistakes,
    -- which is no deck's.
    , ring : Maybe DeckToday

    -- The run was started from PRACTICE ANYWAY: every answer in it is
    -- early, practice only, and moves nothing -- the ring included.
    , anyway : Bool
    }


{-| One deck's day: how many it has had, out of today's set (what was
done, plus what is still due, plus the new ones the day still allows).
-}
type alias DeckToday =
    { done : Int
    , target : Int
    }


type alias Model =
    { session : Session
    , id : String
    , hasNext : Bool -- the run has another mistake after this one
    , inRun : Bool -- this page is part of a run, so I'M DONE can end it
    , progress : Maybe Progress -- where this one sits in a run, and the marks so far
    , tier : Maybe String -- the tier of mistakes this run is of, if it is of one
    , deck : Maybe Api.Decks.Named -- the set this run is of (the openings...), if it is of one
    , today : Maybe Today -- the day's count, as the run was handed it; an account's only
    , counted : Bool -- this page's own answer has been counted into the ring
    , origin : String -- scheme, host and port, for the link SHARE copies
    , puzzle : Loadable Puzzle
    , path : List String -- the nodes stepped to, oldest first
    , swaps : Int -- taps on the dice: which one a tap on a checker plays
    , fetching : List String -- nodes of a lazy tree on their way
    , band : Maybe Int -- the cube answer picked, before it is sent
    , key : String -- the attempt's idempotency key: one per page load, kept for a retry
    , playWhenKeyed : Bool -- PLAY was pressed before the key was minted
    , attempt : Attempt
    , showing : Maybe Int -- a candidate's rank on the board; Nothing is the move played
    , before : Bool -- the roll on the board it was thrown into: the move taken back, as the replay's dice do
    , outcome : Maybe String -- the override the player applied, once it went through
    , graded : Maybe Schedule -- the schedule the answer came back with, before any override
    , confirmingNever : Bool -- NEVER was tapped: its sentence and YES, NEVER are up
    , missedNote : Bool -- GOT IT after a miss was tapped: say why it is not a choice
    , applying : Maybe String -- the choice on its way to the server
    , outcomeError : Maybe String -- why the last override did not go through
    , thenOut : Maybe Out -- ANOTHER or I'M DONE, waiting on a choice still on its way
    , why : Maybe Puzzle.Why -- why this one is here, asked before the answer
    , memory : Maybe Puzzle.Memory
    , shareLabel : Maybe String
    , share : Maybe String -- the ?s= this page was opened with: a story token
    , storyLabel : Maybe String -- what "Share with my mistake" says right now
    , sharing : Sharing -- which button the share sheet's answer is for
    , now : Int -- client time (ms) when the reveal landed, for "back in 7 days"
    , ended : Maybe End -- the run is over: the score, and what comes after it
    , celebration : Maybe Celebration -- this answer finished today's set: the card that comes next
    , leaving : Bool -- ANOTHER was pressed and the shell is finding the next
    , zone : Time.Zone -- the reader's own, for the day an early answer is due
    }


{-| A run's score, as the shell counted it: a pass is right, anything else
is not.
-}
type alias Score =
    { right : Int
    , total : Int
    }


type alias End =
    { score : Score
    , answers : List Answer -- what the run did, one entry per mistake it answered
    , after : After
    , way : Maybe WayState -- the way on, for an account's run through a deck
    }


{-| The way on from the end of a run, once the shell has read where the
deck stands. A run is never the last word: today's set done, there is
always more to do.

  - `Continue`: the deck still has work today (I'M DONE was pressed with
    some left), so KEEP GOING simply goes on with it;
  - `MoreNew n`: today's set is done and there are mistakes never shown,
    so KEEP GOING starts `n` more (the deck's own pace);
  - `Anyway`: everything is started and nothing is due, so PRACTICE
    ANYWAY goes through them early, practice only;
  - `NoWay`: nothing to offer (a set not added, a deck with nothing in it).

-}
type Way
    = Continue { due : Int, newLeft : Int }
    | MoreNew Int
    | Anyway
    | NoWay


{-| Where the way on stands. Its band is laid out from the moment the
card is drawn, so the answer landing moves nothing.
-}
type WayState
    = Asking
    | Offered Way
    | Going Way
      -- the press found nothing more (every one of these practiced), or
      -- the server said why not
    | Stopped String


{-| The moment today's set is done, as the next card: the shell decides
it (`Run.celebrate`, once a run, on the counted answer that brings the
deck's ring to its target) and hands the page what it needs. The reveal
of that answer is an ordinary reveal whose ANOTHER is always there;
pressed, it puts this card where the next puzzle would be -- the board
gone -- and plays it.

  - `target`: today's set, now done -- "Today's 5 done.";
  - `answered`: the run's answers with their puzzles, oldest first, which
    the lines and the grid's stepping squares are counted from (kept up
    to date by the shell: a choice applied after the card is drawn
    changes what it says);
  - `deck`: the deck as the server has it now (its cells for the grid,
    what it cost, how much of a set is mastered), read once when the card
    appears;
  - `way`: KEEP GOING or PRACTICE ANYWAY, from where the deck stands;
  - `shown`: ANOTHER was pressed, and the card is on the page instead of
    the puzzle;
  - `ready`: the card is drawn -- once the deck is read, or failing that
    after a moment, so nothing waits on the network for long;
  - `playing`: the card is on the screen and its motion runs;
  - `settled`: its last keyframe has ended (`data-settled`).

-}
type alias Celebration =
    { target : Int
    , answered : List ( String, Answer )
    , deck : CelebrationDeck
    , way : WayState
    , shown : Bool
    , ready : Bool
    , playing : Bool
    , settled : Bool
    }


type CelebrationDeck
    = Reading
    | Read PracticeDecks.Page
    | Unread


{-| What the end screen offers under the score: a guest the sign-in; an
account the way back, and -- for a run through a deck -- the way on
(`End.way`). Never a wall: today's set done, KEEP GOING is one tap.
-}
type After
    = -- a guest: the sign-in, going on to where the run was started from
      AskSignIn SignIn.Model
      -- an account: the way back to the page the run was started from (the
      -- hub, a deck's page, the table, the replay), and the way on (`End.way`)
    | BackTo String


{-| The two share buttons report through one port, so the page remembers
which of them is waiting for the answer.
-}
type Sharing
    = CleanLink
    | StoryLink


type Msg
    = GotPuzzle (Result Api.Error Puzzle)
    | GotNode String (Result Api.Error Puzzle.Node)
    | GotKey String
    | BoardOut Puzzle.Out
    | PickedBand Int
    | Submit
    | GotReveal (Result Api.Error Reveal)
    | RevealedAt ( Time.Posix, Time.Zone )
    | Show (Maybe Int)
    | ToggleBefore
    | PressedDone
    | PressedOutcome String
    | FocusedOutcome String
    | ConfirmedNever
    | GotOutcome String (Result Api.Error (Maybe Schedule))
    | GotWhy (Result Api.Error Puzzle.Why)
    | GotMemory (Result Api.Error Puzzle.Memory)
    | Share
    | ShareStory
    | GotShare (Result Api.Error String)
    | ShareReported String
    | ShareLabelCleared
    | Next
    | PressedWay Way
    | EndSignInMsg SignIn.Msg
    | CelebrationWaited
    | CelebrationInView Bool
    | CelebrationEnded String
    | NoOp


{-| What one answer did, as the run keeps it: how it was graded, where
the mistake now stands (an account whose deck holds it; nothing for a
guest, and nothing for one put out of the deck), and how bad the mistake
was, so the end of the run can say what it mastered.
-}
type alias Answer =
    { verdict : Verdict
    , schedule : Maybe Schedule
    , grade : String
    }


{-| What the shell does for the page: nothing; keep this answer on the
run; go to the next puzzle of the run it is keeping (or, at the last,
hand back the score); start a run of these; take note of a sign-in; go
somewhere.
-}
type Out
    = NoOut
    | Answered Answer
      -- ANOTHER or I'M DONE pressed while a choice was on its way: keep
      -- the answer it settled on, then go
    | AnsweredThen Answer Out
    | WantsNext
    | WantsEnd
    | StartRun (List String) (Maybe Today) (Maybe String)
      -- KEEP GOING or PRACTICE ANYWAY, pressed on the end card: the shell
      -- owns the run, so it asks for more and goes on with it
    | GoOn Way
    | SignedIn (Maybe Session.User)
    | Go String


init :
    Session
    ->
        { id : String
        , hasNext : Bool
        , inRun : Bool
        , progress : Maybe Progress
        , tier : Maybe String
        , deck : Maybe Api.Decks.Named
        , today : Maybe Today
        , origin : String
        , share : Maybe String
        }
    -> ( Model, Cmd Msg )
init session config =
    ( { session = session
      , id = config.id
      , hasNext = config.hasNext
      , inRun = config.inRun
      , progress = config.progress
      , tier = config.tier
      , deck = config.deck
      , today = config.today
      , counted = False
      , origin = config.origin
      , puzzle = Loading
      , path = []
      , swaps = 0
      , fetching = []
      , band = Nothing
      , key = ""
      , playWhenKeyed = False
      , attempt = NotYet
      , showing = Nothing
      , before = False
      , outcome = Nothing
      , graded = Nothing
      , confirmingNever = False
      , missedNote = False
      , applying = Nothing
      , outcomeError = Nothing
      , thenOut = Nothing
      , why = Nothing
      , memory = Nothing
      , shareLabel = Nothing
      , share = config.share
      , storyLabel = Nothing
      , sharing = CleanLink
      , now = 0
      , ended = Nothing
      , celebration = Nothing
      , leaving = False
      , zone = Time.utc
      }
    , Cmd.batch
        [ Api.get session (base config.id) Puzzle.decoder GotPuzzle

        -- Why this position is in front of you, in a session: how bad the
        -- mistake was and whose game it came from. Nothing derived from
        -- the answer is in that reply, which is what lets it be asked
        -- before one. A puzzle opened from a link is not a session and
        -- asks nothing.
        , case ( config.progress, config.deck ) of
            ( Just _, Nothing ) ->
                Api.get session (base config.id ++ "/why") Puzzle.whyDecoder GotWhy

            _ ->
                Cmd.none

        -- The key is minted here and nowhere else: a retried POST reuses
        -- it, so the server sees one answer however many times it is sent.
        , Random.generate GotKey (Random.map (List.map hex >> String.concat) (Random.list 32 (Random.int 0 15)))
        ]
    )


hex : Int -> String
hex n =
    String.slice n (n + 1) "0123456789abcdef"


base : String -> String
base id =
    "/papi/puzzles/" ++ id


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


title : Model -> String
title model =
    case model.puzzle of
        Loaded p ->
            p.prompt

        Missing ->
            "No such puzzle"

        _ ->
            "Puzzle"


theme : Model -> String
theme model =
    Session.pref "backgammon_theme" model.session |> Maybe.withDefault Board.defaultTheme



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        GotPuzzle (Ok puzzle) ->
            stay { model | puzzle = Loaded puzzle } Cmd.none

        GotPuzzle (Err err) ->
            if Api.errorCode err == "not_found" then
                stay { model | puzzle = Missing } Cmd.none

            else
                stay { model | puzzle = Unavailable (Api.errorMessage err) } Cmd.none

        GotKey key ->
            let
                keyed =
                    { model | key = key, playWhenKeyed = False }
            in
            if model.playWhenKeyed then
                submit keyed

            else
                stay keyed Cmd.none

        BoardOut out ->
            case model.attempt of
                -- The answer is in: the board is a picture now.
                Revealed _ ->
                    stay model Cmd.none

                Sending ->
                    stay model Cmd.none

                _ ->
                    board out model

        PickedBand band ->
            case model.attempt of
                Revealed _ ->
                    stay model Cmd.none

                Sending ->
                    stay model Cmd.none

                _ ->
                    submit { model | band = Just band }

        Submit ->
            submit model

        GotReveal (Ok reveal) ->
            let
                revealed =
                    marked reveal
                        { model | attempt = Revealed reveal, graded = reveal.schedule, showing = Nothing, before = False }
            in
            ( revealed
            , Cmd.batch
                [ Task.perform RevealedAt (Task.map2 Tuple.pair Time.now Time.here)

                -- Only now: the memory line is a fact about the player
                -- and the game, and asking for it before the answer
                -- would put the move that was played within reach.
                --
                -- Never in a run through a set (the openings...): a set
                -- is the same position for everyone, and a game of yours
                -- that happened to reach it is not why it is in front of
                -- you. Games are named only where the puzzle is one of
                -- your mistakes, or opened on its own from a link.
                , if asksMemory model then
                    Api.get model.session (base model.id ++ "/mine") Puzzle.memoryDecoder GotMemory

                  else
                    Cmd.none
                ]
              -- The shell keeps the run's score, and what this answer did
              -- to the mistake, for the line at the end of the run.
            , Answered
                { verdict = reveal.verdict
                , schedule = reveal.schedule
                , grade = gradeOfMine model
                }
            )

        GotReveal (Err err) ->
            stay { model | attempt = Refused (Api.errorMessage err) } Cmd.none

        RevealedAt ( time, zone ) ->
            stay { model | now = Time.posixToMillis time, zone = zone } Cmd.none

        Show rank ->
            stay { model | showing = rank, before = False } Cmd.none

        -- The dice, tapped after the reveal: the move comes off the board and
        -- the roll sits on the position it was thrown into; tapped again, the
        -- move is back. A candidate on the board goes first.
        ToggleBefore ->
            stay { model | before = not model.before, showing = Nothing } Cmd.none

        -- SOONER, GOT IT and KNEW IT apply on the tap; the one already in
        -- force sends nothing. NEVER cannot be undone, so its tap only
        -- asks (its sentence, and YES, NEVER); tapping it again, or any
        -- other choice, takes the question back.
        PressedOutcome outcome ->
            let
                settled =
                    { model | confirmingNever = False, missedNote = False, outcomeError = Nothing }
            in
            if model.applying /= Nothing || model.outcome == Just "never" then
                stay model Cmd.none

            else if outcome == "got_it" && gotItBarred model then
                stay { settled | missedNote = True } Cmd.none

            else if outcome == "never" then
                stay { settled | confirmingNever = not model.confirmingNever } Cmd.none

            else if Just outcome == inForce model then
                stay settled Cmd.none

            else
                apply outcome settled

        -- GOT IT after a miss says why it is not a choice when it is
        -- reached by the keyboard too, not only by a tap.
        FocusedOutcome outcome ->
            if outcome == "got_it" && gotItBarred model then
                stay { model | missedNote = True } Cmd.none

            else
                stay model Cmd.none

        ConfirmedNever ->
            if model.confirmingNever && model.applying == Nothing then
                apply "never" { model | confirmingNever = False }

            else
                stay model Cmd.none

        GotOutcome outcome (Ok schedule) ->
            let
                ( settled, cmd, answered ) =
                    amended outcome
                        schedule
                        { model
                            | applying = Nothing
                            , outcomeError = Nothing
                            , outcome = Just outcome
                            , thenOut = Nothing
                            , attempt =
                                case ( model.attempt, schedule ) of
                                    ( Revealed reveal, Just s ) ->
                                        Revealed { reveal | schedule = Just s }

                                    ( other, _ ) ->
                                        other
                        }
            in
            -- ANOTHER or I'M DONE was waiting on this: the shell keeps the
            -- answer first, so the run's score is about what was settled on.
            case ( model.thenOut, answered ) of
                ( Just onward, Answered answer ) ->
                    ( settled, cmd, AnsweredThen answer onward )

                ( Just onward, _ ) ->
                    ( settled, cmd, onward )

                ( Nothing, _ ) ->
                    ( settled, cmd, answered )

        GotOutcome _ (Err err) ->
            -- A 409 (nothing to amend any more), a 422 or a lost
            -- connection: the line keeps saying what the server last said,
            -- the choice in force is the one before the tap, and why it
            -- changed nothing is said in the explanation's place. A run
            -- waiting on it stays here.
            stay { model | applying = Nothing, thenOut = Nothing, leaving = False, outcomeError = Just (Api.errorMessage err) } Cmd.none

        GotWhy (Ok why) ->
            stay { model | why = Just why } Cmd.none

        -- A 404 is the usual answer on a shared link: not a player of that
        -- game, so there is nothing to say about why it is here.
        GotWhy (Err _) ->
            stay model Cmd.none

        GotMemory (Ok memory) ->
            stay { model | memory = Just memory } Cmd.none

        -- A 404 is the usual answer: not a player of that game. Nothing to
        -- show, nothing to say.
        GotMemory (Err _) ->
            stay model Cmd.none

        GotNode node (Ok fetched) ->
            stay
                { model
                    | fetching = List.filter ((/=) node) model.fetching
                    , puzzle =
                        case model.puzzle of
                            Loaded p ->
                                Loaded { p | tree = Maybe.map (withNode node fetched) p.tree }

                            other ->
                                other
                }
                Cmd.none

        GotNode node (Err _) ->
            -- The step stays on the path, drawn as the last position the
            -- tree holds; UNDO is the way back.
            stay { model | fetching = List.filter ((/=) node) model.fetching } Cmd.none

        Share ->
            stay { model | sharing = CleanLink } (shareInvite (model.origin ++ Route.href (Route.puzzle model.id)))

        -- The story link is the server's to mint: only the seat that made
        -- the mistake gets one, and the page copies what it is handed.
        ShareStory ->
            stay { model | sharing = StoryLink, storyLabel = Just "…" }
                (Api.post model.session (base model.id ++ "/shares") (E.object []) (D.field "url" D.string) GotShare)

        GotShare (Ok url) ->
            stay model (shareInvite (model.origin ++ url))

        GotShare (Err _) ->
            stay { model | storyLabel = Just "Copy failed" }
                (Process.sleep 1500 |> Task.perform (\_ -> ShareLabelCleared))

        ShareReported result ->
            let
                label =
                    case result of
                        "copied" ->
                            Just "Copied"

                        "shared" ->
                            Just "Shared"

                        _ ->
                            Just "Copy failed"
            in
            stay
                (case model.sharing of
                    CleanLink ->
                        { model | shareLabel = label }

                    StoryLink ->
                        { model | storyLabel = label }
                )
                (Process.sleep 1500 |> Task.perform (\_ -> ShareLabelCleared))

        ShareLabelCleared ->
            stay { model | shareLabel = Nothing, storyLabel = Nothing } Cmd.none

        -- ANOTHER, and I'M DONE below: a choice still on its way is waited
        -- for. On the answer that finished today's set, ANOTHER is the
        -- celebration: the next card, in place of the next puzzle.
        Next ->
            case model.celebration of
                Just c ->
                    if c.shown then
                        stay model Cmd.none

                    else
                        let
                            shown =
                                { c | shown = True }
                        in
                        stay { model | celebration = Just shown, confirmingNever = False }
                            (if shown.ready then
                                celebrateCard celebrationId

                             else
                                Cmd.none
                            )

                Nothing ->
                    if model.leaving then
                        stay model Cmd.none

                    else
                        leave WantsNext { model | leaving = True }

        -- KEEP GOING or PRACTICE ANYWAY on the end card: the button says it
        -- is on its way, and the shell does the asking.
        PressedWay way ->
            let
                state =
                    case model.ended of
                        Just end ->
                            end.way

                        Nothing ->
                            Maybe.map .way model.celebration
            in
            case state of
                Just (Offered offered) ->
                    if offered == way && way /= NoWay then
                        ( offering (Going way) model, Cmd.none, GoOn way )

                    else
                        stay model Cmd.none

                _ ->
                    stay model Cmd.none

        -- The deck was slow to answer: draw the card with what the run
        -- knows rather than keep the moment waiting.
        CelebrationWaited ->
            case model.celebration of
                Just c ->
                    if c.ready then
                        stay model Cmd.none

                    else
                        ready { c | deck = Unread } model

                Nothing ->
                    stay model Cmd.none

        -- The card is on the screen: play it. With reduced motion there is
        -- nothing to play, and the final state is already drawn.
        CelebrationInView reduced ->
            case model.celebration of
                Just c ->
                    if c.playing then
                        stay model Cmd.none

                    else
                        stay { model | celebration = Just { c | playing = True, settled = c.settled || reduced } }
                            (if reduced then
                                Cmd.none

                             else
                                -- Belt and braces: a tab put in the background
                                -- mid-flight may never hear its last keyframe end.
                                Process.sleep (toFloat (celebrationTiming c).total + 1500) |> Task.perform (\_ -> CelebrationEnded settleName)
                            )

                Nothing ->
                    stay model Cmd.none

        CelebrationEnded name ->
            case model.celebration of
                Just c ->
                    if name == settleName && c.playing then
                        stay { model | celebration = Just { c | settled = True } } Cmd.none

                    else
                        stay model Cmd.none

                Nothing ->
                    stay model Cmd.none

        -- I'M DONE: the run stops here and the shell hands back the
        -- score, however few this was. One is a whole session.
        PressedDone ->
            leave WantsEnd model

        EndSignInMsg signInMsg ->
            case model.ended of
                Just { after } ->
                    case after of
                        AskSignIn signIn ->
                            let
                                ( next, cmd, out ) =
                                    SignIn.update model.session signInMsg signIn

                                updated =
                                    afterEnd (AskSignIn next) model
                            in
                            case out of
                                SignIn.NoOut ->
                                    stay updated (Cmd.map EndSignInMsg cmd)

                                SignIn.SignedIn result ->
                                    ( updated, Cmd.map EndSignInMsg cmd, SignedIn result.user )

                                -- CONTINUE: the practice home, with a deck now.
                                SignIn.Continue path ->
                                    ( updated, Cmd.none, Go path )

                        _ ->
                            stay model Cmd.none

                Nothing ->
                    stay model Cmd.none

        NoOp ->
            stay model Cmd.none


{-| The run is over, at this puzzle: the shell hands the page the score,
and where the run was started from (`next`), which is where a guest who
signs in here goes on to. An account is asked what its deck has left; a
guest is asked to sign in.
-}
endRun : Score -> List Answer -> String -> Model -> ( Model, Cmd Msg )
endRun score answers next model =
    case model.session.user of
        -- Nothing is asked of the server: what the run did is what the
        -- run knows, and the day's count came with it.
        Just _ ->
            ( { model | ended = Just { score = score, answers = answers, after = BackTo next, way = Nothing } }
            , Cmd.none
            )

        Nothing ->
            let
                ( signIn, cmd ) =
                    SignIn.init { next = next, email = "" }
            in
            ( { model | ended = Just { score = score, answers = answers, after = AskSignIn signIn, way = Nothing } }
            , Cmd.map EndSignInMsg cmd
            )


{-| The way on from the end card, as the shell has found it: asking
where the deck stands, what it offers, on its way, or stopped. Only an
account's end card has one; a guest's keeps the sign-in and nothing else.
-}
offering : WayState -> Model -> Model
offering state model =
    case model.ended of
        Just end ->
            case end.after of
                BackTo _ ->
                    { model | ended = Just { end | way = Just state } }

                AskSignIn _ ->
                    model

        -- The celebration's way on is the same press, on its own card.
        Nothing ->
            { model | celebration = Maybe.map (\c -> { c | way = state }) model.celebration }


{-| Today's set is done, on this answer: the card that ANOTHER brings up
next. The deck is read now (`celebrationRead`), while the reveal is
read; if it is slow, the card is drawn without it after a moment.
-}
celebrate : { target : Int, answered : List ( String, Answer ) } -> Model -> ( Model, Cmd Msg )
celebrate config model =
    case ( model.celebration, model.session.user ) of
        ( Nothing, Just _ ) ->
            ( { model
                | celebration =
                    Just
                        { target = config.target
                        , answered = config.answered
                        , deck = Reading
                        , way = Asking
                        , shown = False
                        , ready = False
                        , playing = False
                        , settled = False
                        }
              }
            , Process.sleep 1500 |> Task.perform (\_ -> CelebrationWaited)
            )

        -- Once on a page, and never for a guest: a guest has no day.
        _ ->
            ( model, Cmd.none )


{-| The deck, as the server has it now, for the card: its cells for the
grid and what the lines say. `Nothing` is a read that failed: the card
is drawn without the grid.
-}
celebrationRead : Maybe PracticeDecks.Page -> Model -> ( Model, Cmd Msg )
celebrationRead read model =
    case model.celebration of
        Just c ->
            if c.ready then
                -- Drawn already without it: keep what is on the screen.
                ( model, Cmd.none )

            else
                let
                    ( next, cmd, _ ) =
                        ready
                            { c
                                | deck =
                                    case read of
                                        Just page ->
                                            Read page

                                        Nothing ->
                                            Unread
                            }
                            model
                in
                ( next, cmd )

        Nothing ->
            ( model, Cmd.none )


{-| The card can be drawn. Played as soon as it is also on the page:
now, if ANOTHER has already been pressed, else when it is.
-}
ready : Celebration -> Model -> ( Model, Cmd Msg, Out )
ready c model =
    ( { model | celebration = Just { c | ready = True } }
    , if c.shown then
        celebrateCard celebrationId

      else
        Cmd.none
    , NoOut
    )


{-| What the run's answers are now, for the card's lines: a choice
applied after it appeared changes what the run did.
-}
withAnswered : List ( String, Answer ) -> Model -> Model
withAnswered answered model =
    { model | celebration = Maybe.map (\c -> { c | answered = answered }) model.celebration }


celebrationId : String
celebrationId =
    "pz-today-done"


settleName : String
settleName =
    "pz-cele-settle"


{-| Put the page back at its top, where the card is, and say when the
card is on the screen, and whether the reader asked for reduced motion.
-}
port celebrateCard : String -> Cmd msg


port celebrationInView : (Bool -> msg) -> Sub msg


afterEnd : After -> Model -> Model
afterEnd after model =
    { model | ended = Maybe.map (\end -> { end | after = after }) model.ended }


stay : Model -> Cmd Msg -> ( Model, Cmd Msg, Out )
stay model cmd =
    ( model, cmd, NoOut )


{-| The answer, on this page's own mark and on the day's ring. A puzzle
answered a second time (back, then PLAY again) replaces its mark and is
**not** counted again: only the first answer at a card is recorded, so
counting a retry would make the ring say more happened today than did.
-}
marked : Reveal -> Model -> Model
marked reveal model =
    case model.progress of
        Nothing ->
            model

        Just progress ->
            let
                counts =
                    markAt progress == Nothing && not model.counted && countsToday progress.anyway reveal.schedule

                up day =
                    if counts then
                        { day | done = day.done + 1 }

                    else
                        day
            in
            { model
                | progress =
                    Just
                        { progress
                            | marks = setAt progress.at (Just reveal.verdict) progress.marks
                            , ring = Maybe.map up progress.ring
                        }
                , counted = model.counted || counts
                , today = Maybe.map up model.today
            }


{-| Does this answer count toward the day -- the ring, and "3 practiced
today"? Only one the server moved the mistake for (`amendable`): that is
exactly what it counts the day by. Not one given early (PRACTICE ANYWAY,
or a second go), not one it could not grade (a self-grade is deferred,
and a deferral is not counted), and not one of a puzzle outside the
player's practice (nothing is written). Counting any of those here would
make the number go down when the server's own count next lands.
-}
countsToday : Bool -> Maybe Schedule -> Bool
countsToday anyway schedule =
    not anyway && (Maybe.map .amendable schedule |> Maybe.withDefault False)


{-| Send a choice. The four wait for the answer, so nothing is sent twice.
-}
apply : String -> Model -> ( Model, Cmd Msg, Out )
apply outcome model =
    ( { model | applying = Just outcome, outcomeError = Nothing }
    , Api.post model.session
        (base model.id ++ "/attempts/" ++ model.key ++ "/outcome")
        (E.object (( "outcome", E.string outcome ) :: deckField model))
        (D.field "schedule" (D.nullable Puzzle.scheduleDecoder))
        (GotOutcome outcome)
    , NoOut
    )


{-| ANOTHER or I'M DONE. A choice still on its way is waited for, so the
run keeps what it settled on; a NEVER never confirmed is simply dropped.
Otherwise the page goes at once.
-}
leave : Out -> Model -> ( Model, Cmd Msg, Out )
leave out model =
    if model.applying /= Nothing then
        ( { model | thenOut = Just out, confirmingNever = False }, Cmd.none, NoOut )

    else
        ( { model | confirmingNever = False }, Cmd.none, out )


{-| The choice that stands: the one applied, else the one the grade
stands for.
-}
inForce : Model -> Maybe String
inForce model =
    case ( model.outcome, model.attempt ) of
        ( Just outcome, _ ) ->
            Just outcome

        ( Nothing, Revealed reveal ) ->
            reveal.schedule |> Maybe.andThen (preselected reveal.verdict)

        _ ->
            Nothing


{-| GOT IT is not one of the choices after a miss: the server refuses
it, and the page draws it disabled in its own column.
-}
gotItBarred : Model -> Bool
gotItBarred model =
    case model.attempt of
        Revealed reveal ->
            reveal.verdict == Fail

        _ ->
            False


{-| The override the player pressed, once it went through: the shell is
told where the card stands now, so the end card's deck line is about
what they settled on and not about the engine's first word.

NEVER takes the card out of the deck, so it stands nowhere and counts
for nothing in that line -- whatever schedule the attempt still carries.
-}
amended : String -> Maybe Schedule -> Model -> ( Model, Cmd Msg, Out )
amended outcome schedule model =
    case model.attempt of
        Revealed reveal ->
            ( model
            , Cmd.none
            , Answered
                { verdict = reveal.verdict
                , schedule =
                    if outcome == "never" then
                        Nothing

                    else
                        schedule
                , grade = gradeOfMine model
                }
            )

        _ ->
            ( model, Cmd.none, NoOut )


{-| How bad this mistake was, where the player is one of the two who made
it. "" on a shared link, where the page is told nothing about whose
mistake it is.
-}
gradeOfMine : Model -> String
gradeOfMine model =
    model.why |> Maybe.map .grade |> Maybe.withDefault ""


markAt : Progress -> Maybe Verdict
markAt progress =
    progress.marks |> List.drop progress.at |> List.head |> Maybe.withDefault Nothing


setAt : Int -> a -> List a -> List a
setAt index value items =
    List.indexedMap
        (\i item ->
            if i == index then
                value

            else
                item
        )
        items


{-| What the board asked for: a step (or two), a step back, the turn
committed, the dice swapped. A step to a node the tree does not hold yet
is a level of a lazy tree, fetched now.
-}
board : Puzzle.Out -> Model -> ( Model, Cmd Msg, Out )
board out model =
    case out of
        Puzzle.Stepped nodes ->
            let
                missing =
                    case model.puzzle of
                        Loaded p ->
                            case p.tree of
                                Just tree ->
                                    if tree.lazy then
                                        nodes
                                            |> List.filter (\n -> not (Dict.member n tree.nodes) && not (List.member n model.fetching))

                                    else
                                        []

                                Nothing ->
                                    []

                        _ ->
                            []
            in
            stay { model | path = model.path ++ nodes, fetching = model.fetching ++ missing }
                (Cmd.batch (List.map (fetchNode model) missing))

        Puzzle.Undo ->
            stay { model | path = List.take (List.length model.path - 1) model.path } Cmd.none

        Puzzle.Play ->
            submit model

        Puzzle.Swapped ->
            stay { model | swaps = model.swaps + 1 } Cmd.none


fetchNode : Model -> String -> Cmd Msg
fetchNode model node =
    Api.get model.session (base model.id ++ "/tree?node=" ++ node) (D.field "tree" Puzzle.nodeDecoder) (GotNode node)


withNode : String -> Puzzle.Node -> Puzzle.Tree -> Puzzle.Tree
withNode node fetched tree =
    { tree | nodes = Dict.insert node fetched tree.nodes }


{-| The answer, sent. Nothing goes without the key -- a POST the server
cannot tell from its retry is one that could count twice -- so a PLAY
that lands before the key is minted waits for it, a few milliseconds.
-}
submit : Model -> ( Model, Cmd Msg, Out )
submit model =
    case attemptBody model of
        Nothing ->
            stay model Cmd.none

        Just body ->
            if model.key == "" then
                stay { model | playWhenKeyed = True } Cmd.none

            else
                stay { model | attempt = Sending }
                    (Api.post model.session (base model.id ++ "/attempts") body Puzzle.revealDecoder GotReveal)


{-| What `POST .../attempts` is sent: the moves of the path, in order, for a
checker play, or the band for a cube question; and the key. Nothing while
the turn is not complete (the board offers PLAY only on a terminal node,
so this is belt and braces) or no answer is picked.
-}
attemptBody : Model -> Maybe E.Value
attemptBody model =
    case model.puzzle of
        Loaded p ->
            case ( p.kind, p.tree, model.band ) of
                ( "move", Just tree, _ ) ->
                    case ( Puzzle.played tree model.path, Puzzle.nodeAt tree model.path ) of
                        ( Just moves, Just node ) ->
                            if node.terminal then
                                Just
                                    (E.object
                                        ([ ( "moves"
                                           , E.list
                                                (\m -> E.object [ ( "from", E.string m.from ), ( "to", E.string m.to ), ( "die", E.int m.die ) ])
                                                moves
                                           )
                                         , ( "key", E.string model.key )
                                         ]
                                            ++ shareField model
                                            ++ deckField model
                                        )
                                    )

                            else
                                Nothing

                        _ ->
                            Nothing

                ( "move", Nothing, _ ) ->
                    Nothing

                ( _, _, Just band ) ->
                    Just (E.object ([ ( "band", E.int band ), ( "key", E.string model.key ) ] ++ shareField model ++ deckField model))

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Does this page ask, after the reveal, whether the player was in a game
that reached this position (`/mine`: the memory line, and the button that
shares their own mistake)? Not in a run through a set: there the position
is the set's, the same for everyone, and no game of theirs is why it is in
front of them.
-}
asksMemory : Model -> Bool
asksMemory model =
    model.deck == Nothing


{-| The set this run is of, for the attempt and its override: the answer
counts on that set's ladder rather than the player's mistakes'.
-}
deckField : Model -> List ( String, E.Value )
deckField model =
    case model.deck of
        Just deck ->
            [ ( "deck", E.string deck.id ) ]

        Nothing ->
            []


{-| The story token the page was opened with, for the attempt: the story
it opens is on the reveal and nowhere earlier.
-}
shareField : Model -> List ( String, E.Value )
shareField model =
    case model.share of
        Just token ->
            [ ( "s", E.string token ) ]

        Nothing ->
            []


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ shareResult ShareReported
        , case model.celebration of
            Just c ->
                if c.playing || not c.shown then
                    Sub.none

                else
                    celebrationInView CelebrationInView

            Nothing ->
                Sub.none
        ]



-- VIEW


view : Model -> Html Msg
view model =
    let
        celebrating =
            model.ended == Nothing && (Maybe.map .shown model.celebration == Just True)
    in
    div
        [ classList
            [ ( "rp-page pz-page paper", True )
            , ( "has-run", model.progress /= Nothing )
            , ( "is-ended", model.ended /= Nothing )
            , ( "is-card", model.ended /= Nothing || celebrating )
            ]
        , id "puzzle"
        ]
        (case ( model.ended, model.puzzle ) of
            ( Just end, _ ) ->
                [ viewHead, viewEnd model end ]

            -- Today's set done: the next card, in place of the next
            -- puzzle. The board is gone, as it would be for a new one.
            ( Nothing, _ ) ->
                if celebrating then
                    [ viewHead, viewCelebration model ]

                else
                    viewLoadable model
        )


viewLoadable : Model -> List (Html Msg)
viewLoadable model =
    case model.puzzle of
        Loading ->
            [ viewHead, div [ class "rp-message pixel text-[9px]" ] [ text "LOADING THE PUZZLE…" ] ]

        Missing ->
            [ viewHead
            , div [ class "rp-message", id "pz-missing" ]
                [ span [ class "pixel text-[9px]" ] [ text "NO SUCH PUZZLE" ]
                , span [ class "text-sm", attribute "style" "color: var(--pencil)" ] [ text "That link does not open anything. It may have been typed wrong." ]
                , a [ href (Route.href Route.library), class "font-semibold", attribute "style" "color: var(--pen)" ] [ text "Back to the board →" ]
                , skip model
                ]
            ]

        Unavailable reason ->
            [ viewHead
            , div [ class "rp-message" ]
                [ span [ class "pixel text-[9px]" ] [ text "NO PUZZLE" ]
                , span [ class "text-sm", attribute "style" "color: var(--pencil)" ] [ text reason ]
                , skip model
                ]
            ]

        Loaded puzzle ->
            viewPuzzle model puzzle



-- THE END OF A RUN


{-| The score, and what comes after it: for an account what the deck has
left, for a guest the sign-in.
-}
viewEnd : Model -> End -> Html Msg
viewEnd model end =
    div [ class "pz-end mx-auto w-full max-w-md q-card sheet p-6 sm:p-8 mt-4", id "pz-end" ]
        (p [ class "pixel q-eyebrow text-[9px] mb-3" ] [ text "DONE" ]
            :: p [ id "pz-score", class "text-[24px] sm:text-[28px] font-bold leading-tight mb-4", attribute "style" "color: var(--ink)" ]
                [ text (runScoreIn model end.score) ]
            :: viewPracticeOnly model
            :: viewMastered model end.answers
            :: viewToday model
            :: viewWay model end
            :: viewAfter model end.after
        )


{-| A run through PRACTICE ANYWAY says, once more at its end, that none
of it moved anything: the score is real, the ladder did not hear of it.
-}
viewPracticeOnly : Model -> Html Msg
viewPracticeOnly model =
    if Maybe.map .anyway model.progress == Just True then
        p [ id "pz-practice-only", class "q-note text-[13px] mb-4" ] [ text Mistakes.practiceOnlyRun ]

    else
        text ""


{-| The way on, for an account's run through a deck: one button in a band
whose height is fixed from the moment the card is drawn -- the line over
it held to two lines, the button laid out even while the shell is still
asking where the deck stands -- so nothing moves when the answer lands
or the button is pressed.

KEEP GOING where the deck still has work today, or where today's set is
done and there are mistakes never shown (it starts the deck's pace of
them); PRACTICE ANYWAY where everything is started and nothing is due.
-}
viewWay : Model -> End -> Html Msg
viewWay model end =
    case end.way of
        Nothing ->
            text ""

        Just state ->
            let
                shown =
                    case state of
                        Asking ->
                            Nothing

                        Offered way ->
                            Just way

                        Going way ->
                            Just way

                        Stopped _ ->
                            Nothing

                going =
                    case state of
                        Going _ ->
                            True

                        _ ->
                            False

                line =
                    case state of
                        Stopped why ->
                            why

                        _ ->
                            Maybe.map (wayLine model) shown |> Maybe.withDefault ""

                ( buttonId, label, action ) =
                    case shown of
                        Just Anyway ->
                            ( "pz-anyway", "PRACTICE ANYWAY", "practice-anyway" )

                        Just (MoreNew _) ->
                            ( "pz-keep-going", "KEEP GOING", "keep-going" )

                        Just (Continue _) ->
                            ( "pz-keep-going", "KEEP GOING", "continue" )

                        _ ->
                            ( "pz-way-idle", "KEEP GOING", "" )

                offered =
                    case shown of
                        Just NoWay ->
                            False

                        Just _ ->
                            True

                        Nothing ->
                            False
            in
            div [ class "pz-way", id "pz-way", attribute "data-way" action ]
                [ p [ class "pz-way-line q-note text-[13px]", id "pz-way-line", attribute "aria-live" "polite" ] [ text line ]
                , button
                    [ classList [ ( "q-btn pz-action pz-way-go", True ), ( "is-idle", not offered ), ( "is-busy", going ) ]
                    , id buttonId
                    , attribute "data-action" action
                    , disabled (not offered || going)
                    , attribute "aria-busy"
                        (if going then
                            "true"

                         else
                            "false"
                        )
                    , onClick (Maybe.withDefault NoWay shown |> PressedWay)
                    ]
                    [ text label
                    , span [ class "hero-arrow-right w-4 h-4", attribute "aria-hidden" "true" ] []
                    ]
                ]


{-| The line over the way on, in the words of what the run was of.
-}
wayLine : Model -> Way -> String
wayLine model way =
    case way of
        Continue work ->
            Mistakes.workLine work

        MoreNew adds ->
            Mistakes.keepGoingLine
                { done = model.progress |> Maybe.andThen .ring |> Maybe.map .done |> Maybe.withDefault 0
                , adds = adds
                }

        Anyway ->
            Mistakes.scheduledLine

        NoWay ->
            ""


{-| The day, under the score: "3 practiced today". The same words the hub
and the session use, and the same plain count.
-}
viewToday : Model -> Html Msg
viewToday model =
    case model.today of
        Just today ->
            p [ id "pz-today", class "q-note text-[13px] mb-4" ]
                [ text (dayLine model today.done) ]

        Nothing ->
            text ""


{-| What the run mastered, under the score: "You mastered 2 very bad
moves." Nothing when it crossed nobody over the rung -- the score has
already said how it went -- and nothing for a guest, whose mistakes
nothing is keeping.
-}
viewMastered : Model -> List Answer -> Html Msg
viewMastered model answers =
    case masteredLineIn model answers of
        Just line ->
            p [ id "pz-patched", class "q-note text-[13px] leading-snug mb-4" ] [ text line ]

        Nothing ->
            text ""


{-| The sentence, from the answers the run collected: the grade of every
mistake whose schedule says this answer mastered it.
-}
masteredLine : List Answer -> Maybe String
masteredLine answers =
    crossed answers
        |> List.map .grade
        |> List.filter (\grade -> grade /= "")
        |> Mistakes.masteredRun


{-| The same, in the words of what the run was of: a set is made of no
mistake, so there is no band to count by, only how many were mastered.
-}
masteredLineIn : Model -> List Answer -> Maybe String
masteredLineIn model answers =
    case model.deck of
        Just _ ->
            Decks.masteredRun (List.length (crossed answers))

        Nothing ->
            masteredLine answers


{-| The answers whose schedule says this answer took them over the rung.
-}
crossed : List Answer -> List Answer
crossed answers =
    List.filter
        (\answer -> answer.schedule |> Maybe.map .patched |> Maybe.withDefault False)
        answers


{-| "7 of 10 right" -- or, for the run of one this page is built to
invite, a sentence that says so warmly.
-}
runScore : Score -> String
runScore score =
    Mistakes.runSummary score


{-| The score in the words of what the run was of: a set's, or mistakes'.
-}
runScoreIn : Model -> Score -> String
runScoreIn model score =
    case model.deck of
        Just _ ->
            Decks.runSummary score

        Nothing ->
            runScore score


{-| The day's count, in the words of what the run is of.
-}
dayLine : Model -> Int -> String
dayLine model done =
    case model.deck of
        Just _ ->
            Decks.doneToday done

        Nothing ->
            Mistakes.practicedToday done


viewAfter : Model -> After -> List (Html Msg)
viewAfter model after =
    case after of
        BackTo next ->
            [ a
                [ href next
                , id "pz-home"
                , class "inline-block font-semibold"
                , attribute "style" "color: var(--pen)"
                ]
                [ text
                    (Mistakes.backLine
                        { next = next
                        , name =
                            case model.deck of
                                Just deck ->
                                    Just deck.name

                                Nothing ->
                                    Maybe.map Mistakes.tierName model.tier
                        }
                    )
                ]
            ]

        AskSignIn signIn ->
            [ p [ id "pz-signin-ask", class "text-[16px] font-semibold leading-snug mb-4", attribute "style" "color: var(--ink)" ]
                [ text
                    (case model.deck of
                        Just _ ->
                            Decks.endSignIn

                        Nothing ->
                            "Sign in and we'll keep this: these come back until you stop making them."
                    )
                ]
            , Html.map EndSignInMsg (SignIn.view signIn)
            ]


{-| A puzzle of a run that did not load must not strand the run: NEXT is
still the way on, here as everywhere in a run.
-}
skip : Model -> Html Msg
skip model =
    if model.hasNext then
        button [ class "q-btn pz-action mt-2", id "pz-next", onClick Next ]
            [ text "ANOTHER", span [ class "hero-arrow-right w-4 h-4", attribute "aria-hidden" "true" ] [] ]

    else if model.inRun then
        button [ class "q-btn plain pz-action mt-2", id "pz-done", onClick PressedDone ]
            [ text "I'M DONE" ]

    else
        text ""


{-| Where this session is, above the board, in one row that never
changes height: the deck's mark (a tier) or name (a set), today's ring
for that deck with its count beside it, then a tile per answer so far --
18 pixels, a check on the green for right, a cross on the red for a
miss, a dash for one nothing could check -- the one on the board
outlined in ink. Under the row, one reserved line: the day's count, and
for a mistake why it is in front of you.

Only in a run, and only on the puzzle itself: a puzzle opened from a
link is not a session and says nothing about one.

**The tiles never wrap.** They sit in a strip that scrolls sideways and
opens at its newest end (`direction: rtl` on the strip, so the browser
starts it there with no script), so the twentieth answer leaves the
board exactly where the first did. **No "4 of 10"**: a run goes on
until I'M DONE, so there is no total to count against -- the ring is
today's set, which is a real one.

-}
viewProgress : Model -> Html Msg
viewProgress model =
    case model.progress of
        Nothing ->
            text ""

        Just progress ->
            div
                [ classList [ ( "pz-progress", True ), ( "has-why", model.deck == Nothing ), ( "is-anyway", progress.anyway ) ]
                , id "pz-progress"
                , attribute "role" "group"
                , attribute "aria-label" (runProgress model)
                ]
                [ div [ class "pz-strip", id "pz-strip" ]
                    [ span
                        [ classList [ ( "pz-strip-label", True ), ( "pixel", model.deck == Nothing ) ]
                        , class (runLabelClass model)
                        , id "pz-progress-label"
                        ]
                        [ text (runLabel model) ]
                    , viewRing progress
                    , div [ class "pz-tiles", id "pz-marks" ]
                        [ div [ class "pz-tiles-in" ]
                            (progress.marks
                                |> List.take (progress.at + 1)
                                |> List.indexedMap (runMark progress.at)
                            )
                        ]
                    ]
                , p [ class "pz-under", id "pz-under" ]
                    (span [ class "pz-progress-count", id "pz-progress-count" ] [ text (underLine model) ]
                        :: (case model.why of
                                Just why ->
                                    [ span [ class "pz-why-sep", attribute "aria-hidden" "true" ] [ text " · " ]
                                    , span [ class "pz-why", id "pz-why" ]
                                        [ text (Mistakes.whyLine { grade = why.grade, opponent = why.opponent }) ]
                                    ]

                                Nothing ->
                                    []
                           )
                    )
                ]


{-| Today's set for the run's deck: the ring at strip size, a check once
it is done, and "3/5" beside it in the pixel font, because at 28 pixels a
fraction inside the ring would be a smudge. Nothing for a run that is of
no deck (one game's mistakes).
-}
viewRing : Progress -> Html Msg
viewRing progress =
    case progress.ring of
        Just ring ->
            let
                -- A deck with nothing in today's set (PRACTICE ANYWAY,
                -- once everything is scheduled) has nothing left to do
                -- today: its ring is full, with no "0/0" beside it.
                empty =
                    ring.target <= 0

                drawn =
                    if empty then
                        { done = 1, target = 1 }

                    else
                        ring
            in
            span
                [ classList [ ( "pz-strip-ring", True ), ( "is-done", drawn.done >= drawn.target ) ]
                , id "pz-ring"
                , attribute "data-done" (String.fromInt ring.done)
                , attribute "data-target" (String.fromInt ring.target)
                ]
                [ Charts.ring { done = drawn.done, target = drawn.target, label = ringLabel ring }
                , span [ class "pz-ring-count pixel", id "pz-ring-count" ]
                    [ text
                        (if empty then
                            ""

                         else
                            String.fromInt ring.done ++ "/" ++ String.fromInt ring.target
                        )
                    ]
                ]

        Nothing ->
            text ""


ringLabel : DeckToday -> String
ringLabel ring =
    if ring.target <= 0 then
        "Nothing left to do today"

    else
        String.fromInt ring.done ++ " of today's " ++ String.fromInt ring.target ++ " done"


{-| What the run is of, at the head of the strip: the tier's mark (??),
or the set's name.
-}
runLabel : Model -> String
runLabel model =
    case model.deck of
        Just deck ->
            deck.name

        Nothing ->
            Maybe.map Mistakes.mark model.tier |> Maybe.withDefault ""


{-| A tier's mark at the head of the strip is in its grade's colour, as
on the hub and in the replay; a set's name is in ink.
-}
runLabelClass : Model -> String
runLabelClass model =
    case ( model.deck, model.tier ) of
        ( Nothing, Just tier ) ->
            Mistakes.markClass tier

        _ ->
            ""


{-| The reserved line's own words: the day's count -- or, in a run of
early answers, that it is practice only, since nothing in it moves the
day.
-}
underLine : Model -> String
underLine model =
    if Maybe.map .anyway model.progress == Just True then
        Mistakes.practiceOnlyTag

    else
        Maybe.map (\today -> dayLine model today.done) model.today |> Maybe.withDefault ""


{-| "?? · 3 of today's 5 done · 3 practiced today": the strip as one
sentence, for a reader who hears it rather than sees it. The mark alone
for a guest, who has no day counted.
-}
runProgress : Model -> String
runProgress model =
    [ Just (runLabel model)
    , Maybe.andThen .ring model.progress |> Maybe.map ringLabel
    , Just (underLine model)
    ]
        |> List.filterMap identity
        |> List.filter (\part -> part /= "")
        |> String.join " · "


{-| One tile per puzzle of the run reached so far, in order: a check on
the green for right, a cross on the red for a miss, a dash for an answer
nothing could check (and the legacy "close" of an attempt stored before
dubious became a miss). The one on the board is outlined in ink, answered
or not.
-}
runMark : Int -> Int -> Maybe Verdict -> Html Msg
runMark at index verdict =
    let
        name =
            case verdict of
                Just v ->
                    Puzzle.verdictName v

                Nothing ->
                    "blank"

        glyph =
            case verdict of
                Just Pass ->
                    "M4.6 9.4 L7.6 12.4 L13.4 5.8"

                Just Fail ->
                    "M5.6 5.6 L12.4 12.4 M12.4 5.6 L5.6 12.4"

                Just _ ->
                    "M5.5 9 L12.5 9"

                Nothing ->
                    ""
    in
    span
        [ classList [ ( "pz-mark", True ), ( "pz-tile", True ), ( "is-" ++ name, True ), ( "is-here", index == at ) ]
        , attribute "data-mark" name
        , attribute "aria-hidden" "true"
        ]
        [ if glyph == "" then
            text ""

          else
            Svg.svg [ SvgA.viewBox "0 0 18 18", SvgA.class "pz-tile-glyph" ]
                [ Svg.path [ SvgA.d glyph, SvgA.fill "none", SvgA.strokeWidth "2.4", SvgA.strokeLinecap "round", SvgA.strokeLinejoin "round" ] [] ]
        ]


viewHead : Html Msg
viewHead =
    -- The bird is the site's bar's, over the page.
    div [ class "rp-head" ]
        [ span [ class "rp-tag pixel text-[7px] sm:text-[8px]" ] [ text "PUZZLE" ]
        ]


mover : Puzzle.Seat
mover =
    { id = "white", name = "White" }


opponent : Puzzle.Seat
opponent =
    { id = "black", name = "Black" }


viewPuzzle : Model -> Puzzle -> List (Html Msg)
viewPuzzle model puzzle =
    let
        reveal =
            case model.attempt of
                Revealed r ->
                    Just r

                _ ->
                    Nothing

        -- A candidate on the board instead of the move played: the still
        -- board the replay draws, with the candidate's landings marked.
        proposed =
            case ( reveal, model.showing ) of
                ( Just r, Just rank ) ->
                    candidatesOf r |> List.filter (\c -> c.rank == Just rank) |> List.head

                _ ->
                    Nothing

        yoursGrade =
            reveal |> Maybe.andThen .yours |> Maybe.map (.equityLost >> Puzzle.gradeOf)

        -- The turn is committed: the board it left, as a picture, the
        -- checkers that moved marked as the table marks a played turn's.
        committed =
            case puzzle.tree of
                Just tree ->
                    let
                        position =
                            Puzzle.nodeAt tree model.path |> Maybe.map .board |> Maybe.withDefault puzzle.question.board

                        landed =
                            Puzzle.played tree model.path
                                |> Maybe.withDefault []
                                |> List.filterMap (.to >> String.toInt)
                    in
                    Board.viewStill NoOp (still model puzzle position landed)

                Nothing ->
                    Board.viewStill NoOp (still model puzzle puzzle.question.board [])

        boardHtml =
            case ( proposed |> Maybe.andThen .position, puzzle.tree, reveal ) of
                -- The move taken back: the roll on the board it was thrown
                -- into, nothing moved yet, as the replay's dice show it.
                ( Nothing, Just _, Just _ ) ->
                    if model.before then
                        Board.viewStill NoOp (still model puzzle puzzle.question.board [])

                    else
                        committed

                ( Just position, _, _ ) ->
                    Board.viewStill NoOp (still model puzzle position (Maybe.map .landed proposed |> Maybe.withDefault []))

                ( Nothing, Just tree, Nothing ) ->
                    Html.map BoardOut
                        (Puzzle.view
                            { question = puzzle.question
                            , tree = tree
                            , path = model.path
                            , mover = mover
                            , opponent = opponent
                            , scores = []
                            , theme = theme model
                            , swaps = model.swaps
                            , key = 1
                            }
                        )

                -- A cube question: the position, nothing to tap.
                ( Nothing, Nothing, _ ) ->
                    Board.viewStill NoOp (still model puzzle puzzle.question.board [])
    in
    [ viewHead
    , viewProgress model
    , div [ class "pz-ask" ]
        [ h1 [ class "pz-prompt", id "pz-prompt" ] [ text puzzle.prompt ]
        , p [ class "pz-score", id "pz-score" ] [ text (scoreLine puzzle) ]
        ]
    , div [ class "rp-main" ]
        [ div [ class "rp-stage" ]
            [ div
                [ classList
                    [ ( "rp-board pz-board", True )
                    , ( "is-proposed", proposed /= Nothing )
                    , ( "is-graded", proposed == Nothing && yoursGrade /= Nothing )
                    , ( "g-" ++ Maybe.withDefault "" yoursGrade, proposed == Nothing && yoursGrade /= Nothing )
                    , ( "dice-played", reveal /= Nothing && not model.before )
                    , ( "is-revealed", reveal /= Nothing )
                    ]
                , id "pz-board"
                ]
                [ boardHtml
                , viewDiceToggle model puzzle
                , case proposed of
                    Just c ->
                        span [ class "rp-proposed pixel text-[7px] inline-flex items-center gap-1.5" ]
                            [ span [ class "hero-trophy w-3.5 h-3.5", attribute "aria-hidden" "true" ] []
                            , text
                                (if c.rank == Just 1 then
                                    "BEST MOVE"

                                 else
                                    "ENGINE'S #" ++ String.fromInt (Maybe.withDefault 0 c.rank)
                                )
                            ]

                    Nothing ->
                        text ""
                ]
            , viewControls model puzzle
            ]
        , div [ class "rp-side" ]
            [ case model.attempt of
                Revealed r ->
                    viewReveal model puzzle r

                Refused reason ->
                    div [ class "rp-note pz-note", id "pz-refused" ]
                        [ p [ class "rp-words" ] [ text reason ]
                        , p [ class "rp-words", attribute "style" "color: var(--pencil)" ] [ text "Play the roll again and press PLAY." ]
                        ]

                Sending ->
                    div [ class "rp-note pz-note" ] [ span [ class "pixel text-[8px]" ] [ text "CHECKING…" ] ]

                NotYet ->
                    div [ class "rp-note pz-note pz-note-quiet" ]
                        [ p [ class "rp-words" ]
                            [ text
                                (case puzzle.kind of
                                    "move" ->
                                        "Play the roll on the board, then press PLAY."

                                    "take" ->
                                        "White has been doubled. Take, or pass?"

                                    _ ->
                                        "Would you turn the cube? Double, or not?"
                                )
                            ]
                        ]
            ]
        ]
    ]


{-| Over the dice, after the reveal, on a checker-play puzzle: tap to take
the move back and see the roll on the board it was thrown into; tap again
to see the move. The same door the replay's dice are, in the same place:
the mover is always at the bottom here, so the dice sit on the right.
-}
viewDiceToggle : Model -> Puzzle -> Html Msg
viewDiceToggle model puzzle =
    case ( model.attempt, puzzle.tree ) of
        ( Revealed _, Just _ ) ->
            button
                [ class "rp-dice-toggle is-right"
                , id "pz-dice-toggle"
                , attribute "aria-label"
                    (if model.before then
                        "Show the move"

                     else
                        "Take the move back: see the roll on the board it was thrown into"
                    )
                , Html.Attributes.title
                    (if model.before then
                        "Show the move"

                     else
                        "See the roll before the move"
                    )
                , onClick ToggleBefore
                ]
                []

        _ ->
            text ""


{-| The still board of a position: the question's cube and dice, the
mover at the bottom, with the given landings marked.
-}
still : Model -> Puzzle -> Puzzle.Board -> List Int -> Board.StillBoard
still model puzzle position landed =
    { players =
        [ { id = mover.id, name = mover.name, color = "white" }
        , { id = opponent.id, name = opponent.name, color = "black" }
        ]
    , viewer = mover.id
    , scores = []
    , cube = not puzzle.question.crawford
    , theme = theme model
    , key = 2
    , position = Puzzle.snapshot puzzle.question.cube mover opponent position
    , mover = Just mover.id
    , dice = puzzle.question.dice
    , landed = landed
    , offer = Nothing
    , accounts = Nothing
    }


{-| The score and the cube in one line under the question: what the head
says, in the page's own words.
-}
scoreLine : Puzzle -> String
scoreLine puzzle =
    let
        q =
            puzzle.question

        -- The picture's caption and the head's words: no score is
        -- unlimited play, one point each way a single game (a 1-point
        -- match is the same position) unless it is marked Crawford.
        score =
            case q.score of
                Nothing ->
                    if q.jacoby then
                        "Unlimited · Jacoby"

                    else
                        "Unlimited"

                Just s ->
                    if s.moverAway == 1 && s.opponentAway == 1 && not q.crawford then
                        "Single game"

                    else
                        "White "
                            ++ String.fromInt s.moverAway
                            ++ " away, Black "
                            ++ String.fromInt s.opponentAway
                            ++ " away"
                            ++ (if q.crawford then
                                    " · Crawford"

                                else
                                    ""
                               )

        cube =
            case q.cube.owner of
                "mover" ->
                    "cube " ++ String.fromInt q.cube.value ++ ", White's"

                "opponent" ->
                    "cube " ++ String.fromInt q.cube.value ++ ", Black's"

                _ ->
                    "cube centered"
    in
    score ++ " · " ++ cube


{-| Under the board: on a cube question, the two answers; after the
reveal, SHARE and NEXT. A checker play's UNDO and PLAY are the board's
own, in its centre band, exactly as at the table.
-}
viewControls : Model -> Puzzle -> Html Msg
viewControls model puzzle =
    let
        revealed =
            case model.attempt of
                Revealed _ ->
                    True

                _ ->
                    False

        sending =
            model.attempt == Sending
    in
    div [ class "rp-controls-wrap pz-controls flex flex-col items-center gap-2" ]
        [ if puzzle.kind /= "move" && not revealed then
            div [ class "pz-bands pz-answers", id "pz-bands" ]
                (Puzzle.answers puzzle.kind
                    |> List.map
                        (\( band, label ) ->
                            button
                                [ classList [ ( "pz-band", True ), ( "is-on", model.band == Just band ) ]
                                , id ("pz-band-" ++ bandId band)
                                , attribute "data-band" (String.fromInt band)
                                , disabled sending
                                , onClick (PickedBand band)
                                ]
                                [ text label ]
                        )
                )

          else
            text ""
        , if revealed then
            div [ class "pz-actions", id "pz-actions" ]
                -- One SHARE. For the player whose own mistake this was (the
                -- memory line said "you") it shares the link with their
                -- story, which is the one worth sending; for everyone else
                -- the clean link. The server refuses a story to anyone else
                -- anyway.
                ((if Maybe.map .who model.memory == Just "you" then
                    button [ class "q-btn plain pz-action", id "pz-share-story", onClick ShareStory ]
                        [ span [ class "hero-link w-4 h-4", attribute "aria-hidden" "true" ] []
                        , text (Maybe.withDefault "SHARE" model.storyLabel)
                        ]

                  else
                    button [ class "q-btn plain pz-action", id "pz-share", onClick Share ]
                        [ span [ class "hero-link w-4 h-4", attribute "aria-hidden" "true" ] []
                        , text (Maybe.withDefault "SHARE" model.shareLabel)
                        ]
                 )
                    -- A run is open-ended: after every reveal, one more
                    -- or stop. Stopping is a finished thing to have
                    -- done, so I'M DONE is always offered and never
                    -- reads as giving up.
                    -- On the answer that finished today's set ANOTHER is
                    -- there even past the run's last id: the celebration
                    -- is what comes next.
                    :: (if model.hasNext || model.celebration /= Nothing then
                            [ button
                                [ classList [ ( "q-btn pz-action", True ), ( "is-busy", model.leaving ) ]
                                , id "pz-next"
                                , attribute "aria-busy"
                                    (if model.leaving then
                                        "true"

                                     else
                                        "false"
                                    )
                                , onClick Next
                                ]
                                [ text "ANOTHER", span [ class "hero-arrow-right w-4 h-4", attribute "aria-hidden" "true" ] [] ]
                            ]

                        else
                            []
                       )
                    ++ (if model.inRun then
                            [ button [ class "q-btn plain pz-action", id "pz-done", onClick PressedDone ]
                                [ text "I'M DONE" ]
                            ]

                        else
                            []
                       )
                )

          else
            text ""
        ]


bandId : Int -> String
bandId band =
    if band < 0 then
        "minus" ++ String.fromInt (abs band)

    else
        String.fromInt band



-- THE REVEAL


{-| The top five and the move played, the latter appended when the engine
did not rank it among them, exactly as the replay lists a turn's.
-}
candidatesOf : Reveal -> List Candidate
candidatesOf reveal =
    case reveal.yours of
        Just yours ->
            if List.any (\c -> c.rank == yours.rank && yours.rank /= Nothing) reveal.top then
                reveal.top

            else
                reveal.top ++ [ yours ]

        Nothing ->
            reveal.top


viewReveal : Model -> Puzzle -> Reveal -> Html Msg
viewReveal model puzzle reveal =
    div [ class "rp-note pz-note", id "pz-reveal" ]
        -- The verdict is about the play made; a candidate on the board has
        -- its own grade at the head of the note, so the verdict steps aside
        -- rather than sit over a move it does not judge.
        ((case shownCandidate model reveal of
            Just _ ->
                text ""

            Nothing ->
                viewVerdict reveal
         )
            :: (case reveal.cube of
                    Just cube ->
                        viewCubeReveal model puzzle cube

                    Nothing ->
                        viewMoveReveal model reveal
               )
            ++ viewSchedule model reveal
            ++ viewMemory model
            ++ viewStory reveal
        )


{-| Right or a miss, and for a miss the band it fell in, in the replay's
own mark, name and colour: 0.02 or more given up is a mistake, so there is
no "close" (a `Hold` is only ever an attempt stored before that).
-}
viewVerdict : Reveal -> Html Msg
viewVerdict reveal =
    let
        mark =
            Words.gradeMark reveal.band

        ( word, sentence, band ) =
            case ( reveal.verdict, reveal.cost ) of
                ( Pass, Just cost ) ->
                    if cost > 0 then
                        ( "RIGHT", Words.nearlyBest, "" )

                    else
                        ( "RIGHT", "That is the play.", "" )

                ( Pass, Nothing ) ->
                    ( "RIGHT", "That is the play.", "" )

                ( Hold, _ ) ->
                    ( "CLOSE", "Not far off the best.", "" )

                ( Fail, Just cost ) ->
                    if mark == "" then
                        ( "NOT THIS TIME", "The best play is better.", "" )

                    else
                        ( mark ++ " " ++ String.toUpper (Mistakes.bandName reveal.band)
                        , Words.givesUp cost (reveal.schedule /= Nothing)
                        , reveal.band
                        )

                ( Fail, Nothing ) ->
                    ( "NOT THIS TIME", "The best play is better.", "" )

                ( Unknown, _ ) ->
                    ( "UNRANKED", "The engine did not rank this one.", "" )
    in
    div
        [ class ("pz-verdict is-" ++ Puzzle.verdictName reveal.verdict)
        , id "pz-verdict"
        , attribute "data-verdict" (Puzzle.verdictName reveal.verdict)
        , attribute "data-band" band
        ]
        [ span
            [ classList [ ( "pz-verdict-word pixel text-[9px]", True ), ( "g-" ++ band, band /= "" ) ] ]
            [ text word ]
        , span [ class "pz-verdict-why" ] [ text sentence ]
        ]


viewMoveReveal : Model -> Reveal -> List (Html Msg)
viewMoveReveal model reveal =
    case reveal.best of
        Nothing ->
            []

        Just best ->
            let
                bestWords =
                    "The best move here is " ++ best.notation ++ "."
            in
            [ case shownCandidate model reveal of
                -- A candidate on the board: the note is about it, not
                -- about the play just made.
                Just c ->
                    div []
                        [ div [ class "rp-verdict" ]
                            [ gradeTag (Words.gradeOf c.equityLost)
                            , if c.rank == Just 1 then
                                span [ attribute "style" "color: var(--pencil)" ] [ text "The engine's choice" ]

                              else
                                Words.lost c.equityLost
                            ]
                        , Words.candidateInWords (Puzzle.asReplayCandidate c) (Puzzle.asReplayCandidate best)
                        ]

                Nothing ->
                    case reveal.yours of
                        Just yours ->
                            Words.moveInWords "You"
                                { grade = Puzzle.gradeOf yours.equityLost
                                , played = Puzzle.asReplayCandidate yours
                                , best = Puzzle.asReplayCandidate best
                                }

                        Nothing ->
                            div [ class "rp-words" ] [ text ("Your play is outside the moves this review kept, so nothing is said about it. " ++ bestWords) ]
            , case ( shownCandidate model reveal, reveal.yours ) of
                ( Nothing, Just yours ) ->
                    if yours.notation == "" then
                        div [ class "rp-words", attribute "style" "color: var(--pencil)" ]
                            [ text ("Your play is outside the five the engine described: it costs " ++ Replay.formatEquity yours.equityLost ++ ". " ++ bestWords) ]

                    else
                        text ""

                _ ->
                    text ""
            , viewCandidates model reveal
            ]


{-| The annotators' mark beside a candidate: how bad it is at a glance.
-}
candidateMark : Float -> Html msg
candidateMark equityLost =
    let
        grade =
            Words.gradeOf equityLost
    in
    case Words.gradeMark grade of
        "" ->
            text ""

        mark ->
            span [ class ("rp-cand-grade g-" ++ grade), attribute "data-grade" grade ] [ text mark ]


{-| The candidate whose position is on the board, when one is.
-}
shownCandidate : Model -> Reveal -> Maybe Candidate
shownCandidate model reveal =
    case model.showing of
        Just rank ->
            candidatesOf reveal |> List.filter (\c -> c.rank == Just rank) |> List.head

        Nothing ->
            Nothing


{-| The replay's table: rank, move, equity (or what it gives up), the
chances. The move played is marked "you" and underlined, as the replay
underlines the move played; a row puts its move on the board and the
same row again (or the "you" row) brings yours back.
-}
viewCandidates : Model -> Reveal -> Html Msg
viewCandidates model reveal =
    let
        yoursRank =
            reveal.yours |> Maybe.andThen .rank

        rows =
            candidatesOf reveal
    in
    div [ class "rp-top pz-top", id "pz-candidates" ]
        (div [ class "rp-top-head" ]
            [ span [] []
            , span [] [ text "move" ]
            , span [ class "rp-col-eq" ] [ text "eq" ]
            , span [ class "rp-col", Html.Attributes.title "How often this move wins" ] [ text "win" ]
            , span [ class "rp-col", Html.Attributes.title "How often it wins a gammon" ] [ text "gam+" ]
            , span [ class "rp-col", Html.Attributes.title "How often it gets gammoned" ] [ text "gam−" ]
            ]
            :: List.map
                (\c ->
                    let
                        isYours =
                            c.rank /= Nothing && c.rank == yoursRank

                        on_ =
                            case model.showing of
                                Just rank ->
                                    c.rank == Just rank

                                Nothing ->
                                    isYours

                        rankText =
                            c.rank |> Maybe.map (\r -> String.fromInt r ++ ".") |> Maybe.withDefault "–"
                    in
                    button
                        [ classList [ ( "rp-cand", True ), ( "is-on", on_ ), ( "is-played", isYours ) ]
                        , attribute "data-rank" (c.rank |> Maybe.map String.fromInt |> Maybe.withDefault "")
                        , attribute "data-yours"
                            (if isYours then
                                "true"

                             else
                                "false"
                            )
                        , disabled (c.position == Nothing)
                        , onClick
                            (if isYours || (on_ && model.showing /= Nothing) then
                                Show Nothing

                             else
                                Show c.rank
                            )
                        , Html.Attributes.title
                            (if isYours then
                                "The move you played"

                             else
                                "Show this move on the board"
                            )
                        ]
                        ([ span [ class "rp-rank tabular-nums" ] [ text rankText ]
                         , span
                            [ classList
                                [ ( "rp-cand-move", True )
                                , ( "is-long", String.length c.notation > 10 )
                                , ( "is-longer", String.length c.notation > 15 )
                                ]
                            ]
                            [ text
                                (if c.notation == "" then
                                    "your play"

                                 else
                                    c.notation
                                )
                            , candidateMark c.equityLost
                            , if isYours then
                                span [ class "pz-you" ] [ text "you" ]

                              else
                                text ""
                            ]
                         , span [ class "rp-cand-lost rp-col-eq tabular-nums" ]
                            [ text
                                (if c.equityLost > 0 then
                                    "−" ++ Replay.formatEquity c.equityLost

                                 else
                                    signed (Maybe.withDefault 0 c.equity)
                                )
                            ]
                         ]
                            ++ chanceCells c.probs
                        )
                )
                rows
        )


{-| A cube question's reveal: the replay's sentence from the doubler's
side, the three equities with the engine's pick in ink, the chances it
judged on. Nothing else: the verdict line above already said which way.
-}
viewCubeReveal : Model -> Puzzle -> Puzzle.CubeReveal -> List (Html Msg)
viewCubeReveal model puzzle cube =
    let
        review =
            { action = ""
            , response = Nothing
            , optimal = Puzzle.optimalOf puzzle.kind cube
            , noDouble = cube.noDouble
            , doubleTake = cube.doubleTake
            , doublePass = cube.doublePass
            , probs = cube.probs
            , doubler = { seat = 0, grade = "", equityLost = 0, mistake = Nothing }
            , taker = Nothing
            }

        -- The replay's sentence for the position, from the side being
        -- asked, with nothing about what was done: nothing was.
        words =
            case ( puzzle.kind, review.optimal ) of
                ( "take", _ ) ->
                    Words.answerWhy "White" review

                ( _, Replay.NoDouble ) ->
                    Words.noDoubleWhy "White" "Black" review

                _ ->
                    Words.doubleWhy "White" "Black" review
    in
    [ Words.inWords words
    , cubeLine review
    , cubeChances "White" review
    ]


-- TODAY'S SET, DONE


{-| The moment today's set is done, as the card after the answer that did
it: ANOTHER on that reveal puts it where the next puzzle would be, the
board gone, centered on the page.

  - today's ring, large, its arc running from where it stood before this
    answer to full, then the check drawn in;
  - "Today's 5 done.", with the highlighter swept under it;
  - what the run did: "2 stepped up a level · 1 mastered";
  - the deck's grid, the squares this run moved stepping up a shade one
    after another, oldest first;
  - for a tier what mastering has won back, for a set how much of it is
    mastered;
  - "Keep going?", and the way on, KEEP GOING (or PRACTICE ANYWAY) beside
    I'M DONE, in one band whose height is fixed: never a wall.

The motion is all CSS, run once the card is on the screen
(`is-playing`); with reduced motion the final state is drawn at once.

-}
viewCelebration : Model -> Html Msg
viewCelebration model =
    case model.celebration of
        Nothing ->
            text ""

        Just c ->
            let
                timing =
                    celebrationTiming c

                ms n =
                    String.fromInt n ++ "ms"

                from =
                    if c.target <= 0 then
                        0

                    else
                        toFloat (100 * (c.target - 1)) / toFloat c.target

                counts =
                    stepCounts c.answered

                steps =
                    case model.deck of
                        Just _ ->
                            Decks.stepsLine { stepped = counts.stepped, mastered = counts.patched }

                        Nothing ->
                            Mistakes.stepsLine counts

                tail =
                    case c.deck of
                        Read page ->
                            case page.deck.kind of
                                PracticeDecks.Set ->
                                    page.deck.standing
                                        |> Maybe.map (\st -> Decks.masteredOf { mastered = st.patched, total = st.total })

                                PracticeDecks.Tier ->
                                    page.deck.cost
                                        |> Maybe.andThen
                                            (\cost ->
                                                if cost.lostPatched > 0 then
                                                    Mistakes.wonBackLine { pr = cost.pr, prPatched = cost.prPatched }

                                                else
                                                    Nothing
                                            )

                        _ ->
                            Nothing

                eyebrow =
                    case model.deck of
                        Just deck ->
                            deck.name

                        Nothing ->
                            Maybe.map Mistakes.tierName model.tier |> Maybe.withDefault ""
            in
            div
                [ classList
                    [ ( "pz-cele", True )
                    , ( "is-ready", c.ready )
                    , ( "is-playing", c.playing )
                    , ( "is-set", model.deck /= Nothing )
                    ]
                , id celebrationId
                , attribute "role" "status"
                , attribute "aria-live" "polite"
                , attribute "data-settled" (boolText c.settled)
                , attribute "data-playing" (boolText c.playing)
                , attribute "data-target" (String.fromInt c.target)
                , attribute "style"
                    ("--from:"
                        ++ String.fromFloat from
                        ++ ";--grid-at:"
                        ++ ms timing.gridAt
                        ++ ";--step:"
                        ++ ms timing.step
                        ++ ";--tail-at:"
                        ++ ms timing.tailAt
                    )
                , on "animationend" (D.map CelebrationEnded (D.field "animationName" D.string))
                ]
                [ div [ class "pz-cele-head" ]
                    [ span [ class "pz-cele-ring", id "pz-today-ring", attribute "data-cele-anchor" "true" ]
                        [ Charts.ring
                            { done = c.target
                            , target = c.target
                            , label = Mistakes.todayDone c.target
                            }
                        , span [ class "pz-cele-sparks", attribute "aria-hidden" "true" ]
                            (List.map (\i -> span [ class "pz-cele-spark", attribute "style" ("--n:" ++ String.fromInt i) ] []) (List.range 0 7))
                        ]
                    , div [ class "pz-cele-words" ]
                        [ p [ class "pz-cele-eyebrow pixel", id "pz-today-eyebrow" ] [ text (String.toUpper eyebrow) ]
                        , p [ class "pz-cele-title", id "pz-today-title" ]
                            [ span [ class "pz-cele-hl" ] [ text (Mistakes.todayDone c.target) ] ]
                        , p [ class "pz-cele-steps", id "pz-today-steps" ] [ text steps ]
                        ]
                    ]
                , viewCelebrationGrid model c
                , p [ class "pz-cele-tail", id "pz-today-tail" ]
                    [ text (Maybe.withDefault "" tail) ]
                , viewCelebrationWay model c
                ]


boolText : Bool -> String
boolText b =
    if b then
        "true"

    else
        "false"


{-| How many of this run's answers climbed a rung, and how many of those
mastered the position.
-}
stepCounts : List ( String, Answer ) -> { stepped : Int, patched : Int }
stepCounts answered =
    let
        schedules =
            List.filterMap (Tuple.second >> .schedule) answered
    in
    { stepped = List.length (List.filter (\sc -> sc.levelAfter > sc.levelBefore) schedules)
    , patched = List.length (List.filter .patched schedules)
    }


{-| The answers that step a square up, oldest first, with the shade the
square had before: a position never started was paper.
-}
stepping : List ( String, Answer ) -> List ( String, { level : Int, status : String } )
stepping answered =
    answered
        |> List.filterMap
            (\( id, given ) ->
                given.schedule
                    |> Maybe.andThen
                        (\sc ->
                            if sc.levelAfter > sc.levelBefore then
                                Just
                                    ( id
                                    , if sc.levelBefore <= 0 then
                                        { level = 0, status = "new" }

                                      else
                                        { level = sc.levelBefore, status = "active" }
                                    )

                            else
                                Nothing
                        )
            )


{-| When each part of the card moves, in milliseconds from the moment it
is on the screen: the ring (0.15 s to 0.75 s) and its check (to 1.05 s),
the grid's squares from 1 s, 120 ms apart -- closer when there are many,
so the whole sequence is never longer than about 0.7 s -- and last the
line under the grid, whose end is the card settling.
-}
celebrationTiming : Celebration -> { gridAt : Int, step : Int, tailAt : Int, total : Int }
celebrationTiming c =
    let
        n =
            List.length (stepping c.answered)

        gap =
            if n <= 1 then
                120

            else
                min 120 (720 // (n - 1))

        gridAt =
            1000

        gridEnd =
            if n <= 0 then
                gridAt

            else
                gridAt + (n - 1) * gap + 320

        tailAt =
            max 1150 (gridEnd - 120)
    in
    { gridAt = gridAt, step = gap, tailAt = tailAt, total = tailAt + 360 }


{-| The deck's grid, small, with this run's squares stepping up. Drawn
only once the deck is read: its box is a function of the deck's size,
which the read says.
-}
viewCelebrationGrid : Model -> Celebration -> Html Msg
viewCelebrationGrid model c =
    case c.deck of
        Read page ->
            let
                moving =
                    stepping c.answered

                order id =
                    moving
                        |> List.indexedMap (\k ( other, was ) -> ( k, other, was ))
                        |> List.filter (\( _, other, _ ) -> other == id)
                        |> List.head

                cells =
                    List.map
                        (\cell ->
                            let
                                now =
                                    { level = cell.level, status = cell.status }
                            in
                            case order cell.id of
                                Just ( k, _, was ) ->
                                    if was /= now then
                                        { level = cell.level, status = cell.status, from = Just was, order = k }

                                    else
                                        { level = cell.level, status = cell.status, from = Nothing, order = 0 }

                                Nothing ->
                                    { level = cell.level, status = cell.status, from = Nothing, order = 0 }
                        )
                        page.cells
            in
            div [ class "pz-cele-grid", id "pz-today-grid" ]
                [ Charts.gridStepping
                    { cells = cells
                    , columns = Ui.Deck.columns page.deck
                    , patchedLevel = page.patchedLevel
                    , sentence = Mistakes.stepsLine (stepCounts c.answered)
                    }
                ]

        _ ->
            text ""


{-| "Keep going?" over KEEP GOING (or PRACTICE ANYWAY) beside I'M DONE,
in a band whose height is fixed, with one quiet line under it saying
what the first does. The first button is laid out while the deck is read and hidden
where there is no way on; I'M DONE is always there.
-}
viewCelebrationWay : Model -> Celebration -> Html Msg
viewCelebrationWay model c =
    let
        shown =
            case c.way of
                Offered way ->
                    Just way

                Going way ->
                    Just way

                _ ->
                    Nothing

        going =
            case c.way of
                Going _ ->
                    True

                _ ->
                    False

        ( buttonId, label, action ) =
            case shown of
                Just Anyway ->
                    ( "pz-anyway", "PRACTICE ANYWAY", "practice-anyway" )

                Just (MoreNew _) ->
                    ( "pz-keep-going", "KEEP GOING", "keep-going" )

                Just (Continue _) ->
                    ( "pz-keep-going", "KEEP GOING", "continue" )

                _ ->
                    ( "pz-way-idle", "KEEP GOING", "" )

        offered =
            case shown of
                Just NoWay ->
                    False

                Just _ ->
                    True

                Nothing ->
                    False

        line =
            case c.way of
                Stopped why ->
                    why

                _ ->
                    case shown of
                        Just (MoreNew adds) ->
                            Mistakes.addsLine adds

                        Just Anyway ->
                            Mistakes.scheduledLine

                        Just (Continue work) ->
                            Mistakes.workLine work

                        _ ->
                            ""
    in
    div [ class "pz-cele-way", id "pz-today-way", attribute "data-way" action ]
        [ -- The question the card asks, laid out from the first frame and
          -- held back only where there is nothing to keep going with.
          p
            [ classList [ ( "pz-cele-ask", True ), ( "is-idle", shown == Just NoWay ) ]
            , id "pz-today-ask"
            ]
            [ text Mistakes.keepGoingAsk ]
        , div [ class "pz-cele-buttons" ]
            [ button
                [ classList [ ( "q-btn pz-action pz-cele-go", True ), ( "is-idle", not offered ), ( "is-busy", going ) ]
                , id buttonId
                , attribute "data-action" action
                , disabled (not offered || going)
                , attribute "aria-busy" (boolText going)
                , onClick (Maybe.withDefault NoWay shown |> PressedWay)
                ]
                [ text label
                , span [ class "hero-arrow-right w-4 h-4", attribute "aria-hidden" "true" ] []
                ]
            , button [ class "q-btn plain pz-action", id "pz-done", onClick PressedDone ]
                [ text "I'M DONE" ]
            ]
        , p [ class "pz-cele-way-line", id "pz-today-way-line" ] [ text line ]
        ]


{-| The level line and the four choices, for an account whose deck holds
the card. The graded choice is in force where the engine graded the play
and the player may amend it; nothing is where the player grades it; no
choices where there is nothing to say.

SOONER, GOT IT and KNEW IT **apply on tap**: the tapped one is filled at
once (pressed while it is on its way, the four disabled), and the fixed
line under the row says what it does; a refusal says why in that line
and the choice before the tap stands. NEVER alone asks first -- it
cannot be undone -- so its tap rings it, explains, and lays out YES,
NEVER; any other tap takes the question back. The line and the confirm's
slot are always laid out, so nothing under them moves when a choice is
tapped. GOT IT after a miss keeps its column, disabled, and says why
when tapped. Once NEVER has gone through the four stay where they are,
disabled.
-}
viewSchedule : Model -> Reveal -> List (Html Msg)
viewSchedule model reveal =
    case reveal.schedule of
        Nothing ->
            []

        Just schedule ->
            let
                -- The one on its way is drawn in force at once; a refusal
                -- puts back the one before it.
                chosen =
                    model.applying |> orElse (inForce model)

                offered =
                    schedule.amendable || schedule.selfGrade

                setAside =
                    model.outcome == Just "never"

                barred =
                    gotItBarred model

                line =
                    if setAside then
                        "Set aside: it will not come back."

                    else if not offered then
                        -- Answered before it was due (PRACTICE ANYWAY, or a
                        -- second go at one already answered today): the
                        -- ladder did not hear of it, and the line says so.
                        if schedule.due > model.now && model.now > 0 then
                            Mistakes.earlyLine (dueDate model.zone schedule.due)

                        else
                            Mistakes.earlyLineUndated

                    else
                        levelLineFor model.outcome model.now schedule

                -- What the choice does: NEVER while it asks, else the one
                -- in force. A refusal takes its place, so the reveal keeps
                -- its height whatever the server says.
                ( why, refused ) =
                    case model.outcomeError of
                        Just error ->
                            ( error, True )

                        Nothing ->
                            if model.missedNote then
                                ( Mistakes.missedNote, False )

                            else if setAside then
                                ( "", False )

                            else
                                ( (if model.confirmingNever then
                                    Just "never"

                                   else
                                    chosen
                                  )
                                    |> Maybe.map (outcomeWhy model reveal.verdict (Maybe.withDefault schedule model.graded))
                                    |> Maybe.withDefault ""
                                , False
                                )

                option outcome label =
                    let
                        isBarred =
                            outcome == "got_it" && barred

                        on =
                            chosen == Just outcome
                    in
                    button
                        ([ classList
                            [ ( "pz-outcome", True )
                            , ( "is-on", on )
                            , ( "is-busy", model.applying == Just outcome )
                            , ( "is-pending", outcome == "never" && model.confirmingNever )
                            , ( "is-barred", isBarred )
                            ]
                         , id ("pz-outcome-" ++ String.replace "_" "-" outcome)
                         , attribute "data-outcome" outcome
                         , attribute "aria-pressed"
                            (if on then
                                "true"

                             else
                                "false"
                            )
                         , attribute "aria-describedby" "pz-outcome-why"
                         , disabled (model.applying /= Nothing || setAside)
                         , onClick (PressedOutcome outcome)
                         ]
                            ++ (if isBarred then
                                    -- Not `disabled`: a disabled button
                                    -- hears no tap, and this one has to
                                    -- say why it is not a choice.
                                    [ attribute "aria-disabled" "true", onFocus (FocusedOutcome outcome) ]

                                else
                                    []
                               )
                        )
                        [ text label ]

                asking =
                    model.confirmingNever && not setAside
            in
            [ div
                [ classList
                    [ ( "pz-level", True )
                    , ( "is-patched", patchedNow model schedule )
                    ]
                , id "pz-level"
                ]
                ([ span [ class "pz-level-line", id "pz-level-line" ] [ text line ] ]
                    ++ (if offered then
                            [ div [ classList [ ( "pz-outcomes", True ), ( "is-closed", setAside ) ], id "pz-outcomes" ]
                                [ option "sooner" "SOONER"
                                , option "got_it" "GOT IT"
                                , option "knew_it" "KNEW IT"
                                , option "never" "NEVER"
                                ]
                            , p
                                [ classList [ ( "pz-outcome-why", True ), ( "pz-outcome-error", refused ) ]
                                , id
                                    (if refused then
                                        "pz-outcome-error"

                                     else
                                        "pz-outcome-why"
                                    )
                                , attribute "aria-live" "polite"
                                ]
                                [ text why ]
                            , div [ class "pz-confirm-slot" ]
                                [ button
                                    [ class "q-btn plain pz-action pz-confirm"
                                    , id "pz-never-yes"
                                    , classList [ ( "is-idle", not asking ) ]
                                    , disabled (not asking || model.applying /= Nothing)
                                    , onClick ConfirmedNever
                                    ]
                                    [ text Mistakes.neverConfirm ]
                                ]
                            ]

                        else
                            case model.outcomeError of
                                Just error ->
                                    [ span [ class "pz-outcome-error", id "pz-outcome-error" ] [ text error ] ]

                                Nothing ->
                                    []
                       )
                )
            ]


{-| What a choice would do to this mistake, said before it is done. Read
off the schedule the answer first came back with, so it says the same
thing whatever has been applied since.
-}
outcomeWhy : Model -> Verdict -> Schedule -> String -> String
outcomeWhy model verdict graded outcome =
    case outcome of
        "sooner" ->
            Mistakes.soonerWhy graded.levelBefore

        "got_it" ->
            if verdict == Fail then
                Mistakes.missedNote

            else if verdict == Pass && graded.amendable then
                Mistakes.gotItGraded (levelLine model.now graded)

            else
                -- Nothing checked the answer: it counts, and the level holds
                -- for as long as the server's ladder says that level waits.
                case graded.heldDays of
                    Just days ->
                        Mistakes.gotItUnchecked graded.levelAfter (backIn 0 (days * 86400000))

                    Nothing ->
                        Mistakes.gotItHolds graded.levelAfter

        "knew_it" ->
            Mistakes.knewItWhy

        "never" ->
            Mistakes.neverWhy

        _ ->
            ""


orElse : Maybe a -> Maybe a -> Maybe a
orElse fallback first =
    case first of
        Just _ ->
            first

        Nothing ->
            fallback


{-| The button the engine's grade stands for, where it graded the play and
the player may amend it: a miss goes back to the start, as SOONER does;
anything else is as graded, GOT IT. Nothing where the player grades it
themselves, and nothing where there is nothing to amend.
-}
preselected : Verdict -> Schedule -> Maybe String
preselected verdict schedule =
    if schedule.amendable then
        case verdict of
            Fail ->
                Just "sooner"

            _ ->
                Just "got_it"

    else
        Nothing


{-| "Level 2 → 3 · back in 7 days". A level that did not move is named
once. An attempt that did not count is kept out of this line by
`viewSchedule`: its existing schedule must not look like a review result.
-}
levelLine : Int -> Schedule -> String
levelLine now schedule =
    levelLineFor Nothing now schedule


{-| The level line after the choice that stands. KNEW IT puts the
mistake at the top in one step, so the line says it is marked known and
when it comes back -- never "seven right in a row", which nobody
answered. Everything else is the plain line.
-}
levelLineFor : Maybe String -> Int -> Schedule -> String
levelLineFor outcome now schedule =
    if outcome == Just "knew_it" then
        Mistakes.knownLine (backIn now schedule.due)

    else if schedule.patched then
        -- The moment the whole thing exists for: this mistake is one the
        -- player has stopped making. Said plainly, in the same type as
        -- everything else.
        Mistakes.milestone schedule.levelAfter ++ " — " ++ backIn now schedule.due

    else
        let
            levels =
                if schedule.levelBefore == schedule.levelAfter then
                    "Level " ++ String.fromInt schedule.levelAfter

                else
                    "Level " ++ String.fromInt schedule.levelBefore ++ " → " ++ String.fromInt schedule.levelAfter
        in
        levels ++ " · " ++ backIn now schedule.due


{-| Whether the line being drawn is the milestone, for the one flourish
it gets: the best-move green. Not while the player has overridden the
grade to something else.
-}
patchedNow : Model -> Schedule -> Bool
patchedNow model schedule =
    schedule.patched && model.outcome /= Just "never"


{-| The day an early answer's mistake is due, in the reader's own zone:
"9 Oct".
-}
dueDate : Time.Zone -> Int -> String
dueDate zone due =
    let
        posix =
            Time.millisToPosix due

        month =
            case Time.toMonth zone posix of
                Time.Jan ->
                    "Jan"

                Time.Feb ->
                    "Feb"

                Time.Mar ->
                    "Mar"

                Time.Apr ->
                    "Apr"

                Time.May ->
                    "May"

                Time.Jun ->
                    "Jun"

                Time.Jul ->
                    "Jul"

                Time.Aug ->
                    "Aug"

                Time.Sep ->
                    "Sep"

                Time.Oct ->
                    "Oct"

                Time.Nov ->
                    "Nov"

                Time.Dec ->
                    "Dec"
    in
    String.fromInt (Time.toDay zone posix) ++ " " ++ month


{-| When the card is due again, in days from now: "back tomorrow", "back
in 7 days", "back in a year". Whole days, rounded, so the seconds between
the answer and the reading do not turn tomorrow into today.
-}
backIn : Int -> Int -> String
backIn now due =
    let
        days =
            round (toFloat (due - now) / 86400000)
    in
    if days <= 1 then
        "back tomorrow"

    else if days >= 360 then
        "back in a year"

    else
        "back in " ++ String.fromInt days ++ " days"



-- THE MEMORY LINE


viewMemory : Model -> List (Html Msg)
viewMemory model =
    case model.memory of
        Nothing ->
            []

        Just memory ->
            [ div [ class "pz-memory", id "pz-memory" ]
                [ span [] [ text (memoryLine memory ++ " ") ]
                , a [ href memory.replay, class "pz-memory-link", id "pz-memory-link" ] [ text "See it in the replay →" ]
                ]
            ]


{-| The story a share-with-my-story link told, in the server's own words:
"Arie played 24/23 13/11 (a bad move) and lost 2 points." Only on the
reveal, and only where the page was opened with the token.
-}
viewStory : Reveal -> List (Html Msg)
viewStory reveal =
    case reveal.story of
        Nothing ->
            []

        Just story ->
            [ div [ class "pz-memory pz-story", id "pz-story" ] [ text story.line ] ]


{-| "From your game vs Charlie, 12 Sep. You played 24/23 13/11 (a bad
move) and lost 2 points." -- or "Charlie played ... and you won 2
points." when it was their mistake.
-}
memoryLine : Puzzle.Memory -> String
memoryLine memory =
    let
        mine =
            memory.who == "you"

        who =
            if mine then
                "You"

            else
                memory.who

        grade =
            case memory.grade of
                "doubtful" ->
                    "a dubious move"

                "bad" ->
                    "a bad move"

                "very_bad" ->
                    "a very bad move"

                other ->
                    other

        ending =
            case memory.result of
                Just r ->
                    (if mine then
                        " and "

                     else
                        " and you "
                    )
                        ++ (if r.won then
                                "won "

                            else
                                "lost "
                           )
                        ++ String.fromInt r.points
                        ++ (if r.points == 1 then
                                " point"

                            else
                                " points"
                           )

                Nothing ->
                    ""

        game =
            if memory.opponent == "" then
                "From your game, "

            else
                "From your game vs " ++ memory.opponent ++ ", "
    in
    game ++ dayOf memory.date ++ ". " ++ who ++ " played " ++ memory.played ++ " (" ++ grade ++ ")" ++ ending ++ "."


{-| "2026-09-12" as "12 Sep".
-}
dayOf : String -> String
dayOf iso =
    case String.split "-" iso of
        [ _, month, day ] ->
            let
                monthName =
                    case month of
                        "01" ->
                            "Jan"

                        "02" ->
                            "Feb"

                        "03" ->
                            "Mar"

                        "04" ->
                            "Apr"

                        "05" ->
                            "May"

                        "06" ->
                            "Jun"

                        "07" ->
                            "Jul"

                        "08" ->
                            "Aug"

                        "09" ->
                            "Sep"

                        "10" ->
                            "Oct"

                        "11" ->
                            "Nov"

                        _ ->
                            "Dec"
            in
            (String.toInt day |> Maybe.map String.fromInt |> Maybe.withDefault day) ++ " " ++ monthName

        _ ->
            iso
