module Page.Puzzle exposing
    ( After(..)
    , Attempt(..)
    , End
    , Loadable(..)
    , Model
    , Msg(..)
    , Answer
    , Out(..)
    , Progress
    , Score
    , attemptBody
    , backIn
    , endRun
    , init
    , levelLine
    , memoryLine
    , patchedLine
    , preselected
    , runProgress
    , runScore
    , subscriptions
    , title
    , update
    , view
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
it now stands ("Level 2 → 3 · back in 7 days") and the four buttons that
override the grade. For a player who was in the game the puzzle came from,
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
one: a practice run is the shell's (`Main`), because it outlives this
page. The page reports each verdict (`Answered`) and asks for the next
(`WantsNext`); at the run's last puzzle the shell answers with the score
(`endRun`) and the page ends the run here: "7 of 10 right", then for an
account what the deck has left ("Done for today. 4 new tomorrow." and
KEEP GOING) and for a guest the sign-in, in the one component, going on
to wherever the run was started from (the practice home, or the table a
result card's PRACTICE was pressed at).

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
import Html.Events exposing (onClick)
import Json.Decode as D
import Json.Encode as E
import Page.Play exposing (shareInvite, shareResult)
import Process
import Random
import Route
import Session exposing (Session)
import Task
import Time
import Ui.Charts as Charts
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
    }


type alias Model =
    { session : Session
    , id : String
    , hasNext : Bool -- the run has another mistake after this one
    , inRun : Bool -- this page is part of a run, so I'M DONE can end it
    , progress : Maybe Progress -- where this one sits in a run, and the marks so far
    , tier : Maybe String -- the tier of mistakes this run is of, if it is of one
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
    , outcome : Maybe String -- the override the player pressed, once it went through
    , outcomeSending : Bool
    , outcomeError : Maybe String -- why the last override did not go through
    , why : Maybe Puzzle.Why -- why this one is here, asked before the answer
    , memory : Maybe Puzzle.Memory
    , shareLabel : Maybe String
    , share : Maybe String -- the ?s= this page was opened with: a story token
    , storyLabel : Maybe String -- what "Share with my mistake" says right now
    , sharing : Sharing -- which button the share sheet's answer is for
    , now : Int -- client time (ms) when the reveal landed, for "back in 7 days"
    , ended : Maybe End -- the run is over: the score, and what comes after it
    }


{-| A run's score, as the shell counted it: a pass is right, a hold is
close, anything else is neither.
-}
type alias Score =
    { right : Int
    , close : Int
    , total : Int
    }


type alias End =
    { score : Score
    , answers : List Answer -- what the run did, one entry per mistake it answered
    , after : After
    }


{-| What the end screen offers under the score.

**Nothing to press but the way back.** A run ends because the player
pressed I'M DONE, or because the tier ran out: either way they have
said they are finished, and a card that answered with "2 more to go" or
a fresh quota would take the moment back. The hub is where the next
tier is chosen.
-}
type After
    = -- a guest: the sign-in, going on to where the run was started from
      AskSignIn SignIn.Model
      -- an account: the way back to the hub, and nothing else
    | BackToPuzzles


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
    | RevealedAt Time.Posix
    | Show (Maybe Int)
    | ToggleBefore
    | PressedDone
    | PressedOutcome String
    | GotOutcome String (Result Api.Error (Maybe Schedule))
    | GotWhy (Result Api.Error Puzzle.Why)
    | GotMemory (Result Api.Error Puzzle.Memory)
    | Share
    | ShareStory
    | GotShare (Result Api.Error String)
    | ShareReported String
    | ShareLabelCleared
    | Next
    | EndSignInMsg SignIn.Msg
    | NoOp


{-| What one answer did, as the run keeps it: how it was graded, where
the mistake now stands (an account whose deck holds it; nothing for a
guest, and nothing for one put out of the deck), and how bad the mistake
was, so the end of the run can say what it patched.
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
    | WantsNext
    | WantsEnd
    | StartRun (List String) (Maybe Today) (Maybe String)
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
      , outcomeSending = False
      , outcomeError = Nothing
      , why = Nothing
      , memory = Nothing
      , shareLabel = Nothing
      , share = config.share
      , storyLabel = Nothing
      , sharing = CleanLink
      , now = 0
      , ended = Nothing
      }
    , Cmd.batch
        [ Api.get session (base config.id) Puzzle.decoder GotPuzzle

        -- Why this position is in front of you, in a session: how bad the
        -- mistake was and whose game it came from. Nothing derived from
        -- the answer is in that reply, which is what lets it be asked
        -- before one. A puzzle opened from a link is not a session and
        -- asks nothing.
        , case config.progress of
            Just _ ->
                Api.get session (base config.id ++ "/why") Puzzle.whyDecoder GotWhy

            Nothing ->
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
                    marked reveal.verdict
                        { model | attempt = Revealed reveal, showing = Nothing, before = False }
            in
            ( revealed
            , Cmd.batch
                [ Task.perform RevealedAt Time.now

                -- Only now: the memory line is a fact about the player
                -- and the game, and asking for it before the answer
                -- would put the move that was played within reach.
                , Api.get model.session (base model.id ++ "/mine") Puzzle.memoryDecoder GotMemory
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

        RevealedAt time ->
            stay { model | now = Time.posixToMillis time } Cmd.none

        Show rank ->
            stay { model | showing = rank, before = False } Cmd.none

        -- The dice, tapped after the reveal: the move comes off the board and
        -- the roll sits on the position it was thrown into; tapped again, the
        -- move is back. A candidate on the board goes first.
        ToggleBefore ->
            stay { model | before = not model.before, showing = Nothing } Cmd.none

        PressedOutcome outcome ->
            if model.outcomeSending then
                stay model Cmd.none

            else
                stay { model | outcomeSending = True, outcomeError = Nothing }
                    (Api.post model.session
                        (base model.id ++ "/attempts/" ++ model.key ++ "/outcome")
                        (E.object [ ( "outcome", E.string outcome ) ])
                        (D.field "schedule" (D.nullable Puzzle.scheduleDecoder))
                        (GotOutcome outcome)
                    )

        GotOutcome outcome (Ok schedule) ->
            amended outcome
                schedule
                { model
                    | outcomeSending = False
                    , outcomeError = Nothing
                    , outcome = Just outcome
                    , attempt =
                        case ( model.attempt, schedule ) of
                            ( Revealed reveal, Just s ) ->
                                Revealed { reveal | schedule = Just s }

                            ( other, _ ) ->
                                other
                }

        GotOutcome _ (Err err) ->
            -- A 409 (nothing to amend any more) or a lost connection: the
            -- line keeps saying what the server last said, and why the
            -- press changed nothing is said under it.
            stay { model | outcomeSending = False, outcomeError = Just (Api.errorMessage err) } Cmd.none

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

        Next ->
            ( model, Cmd.none, WantsNext )

        -- I'M DONE: the run stops here and the shell hands back the
        -- score, however few this was. One is a whole session.
        PressedDone ->
            ( model, Cmd.none, WantsEnd )

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
            ( { model | ended = Just { score = score, answers = answers, after = BackToPuzzles } }
            , Cmd.none
            )

        Nothing ->
            let
                ( signIn, cmd ) =
                    SignIn.init { next = next, email = "" }
            in
            ( { model | ended = Just { score = score, answers = answers, after = AskSignIn signIn } }
            , Cmd.map EndSignInMsg cmd
            )


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
marked : Verdict -> Model -> Model
marked verdict model =
    case model.progress of
        Nothing ->
            model

        Just progress ->
            let
                first =
                    markAt progress == Nothing
            in
            { model
                | progress = Just { progress | marks = setAt progress.at (Just verdict) progress.marks }
                , counted = model.counted || first
                , today =
                    if first && not model.counted then
                        Maybe.map (\today -> { today | done = today.done + 1 }) model.today

                    else
                        model.today
            }


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
                                        )
                                    )

                            else
                                Nothing

                        _ ->
                            Nothing

                ( "move", Nothing, _ ) ->
                    Nothing

                ( _, _, Just band ) ->
                    Just (E.object ([ ( "band", E.int band ), ( "key", E.string model.key ) ] ++ shareField model))

                _ ->
                    Nothing

        _ ->
            Nothing


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
subscriptions _ =
    shareResult ShareReported



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "rp-page pz-page paper", id "puzzle" ]
        (case ( model.ended, model.puzzle ) of
            ( Just end, _ ) ->
                [ viewHead, viewEnd model end ]

            ( Nothing, Loading ) ->
                [ viewHead, div [ class "rp-message pixel text-[9px]" ] [ text "LOADING THE PUZZLE…" ] ]

            ( Nothing, Missing ) ->
                [ viewHead
                , div [ class "rp-message", id "pz-missing" ]
                    [ span [ class "pixel text-[9px]" ] [ text "NO SUCH PUZZLE" ]
                    , span [ class "text-sm", attribute "style" "color: var(--pencil)" ] [ text "That link does not open anything. It may have been typed wrong." ]
                    , a [ href (Route.href Route.library), class "font-semibold", attribute "style" "color: var(--pen)" ] [ text "Back to the board →" ]
                    , skip model
                    ]
                ]

            ( Nothing, Unavailable reason ) ->
                [ viewHead
                , div [ class "rp-message" ]
                    [ span [ class "pixel text-[9px]" ] [ text "NO PUZZLE" ]
                    , span [ class "text-sm", attribute "style" "color: var(--pencil)" ] [ text reason ]
                    , skip model
                    ]
                ]

            ( Nothing, Loaded puzzle ) ->
                viewPuzzle model puzzle
        )



-- THE END OF A RUN


{-| The score, and what comes after it: for an account what the deck has
left, for a guest the sign-in.
-}
viewEnd : Model -> End -> Html Msg
viewEnd model end =
    div [ class "pz-end mx-auto w-full max-w-md q-card sheet p-6 sm:p-8 mt-4", id "pz-end" ]
        (p [ class "pixel q-eyebrow text-[9px] mb-3" ] [ text "DONE" ]
            :: p [ id "pz-score", class "text-[24px] sm:text-[28px] font-bold leading-tight mb-1", attribute "style" "color: var(--ink)" ]
                [ text (runScore end.score) ]
            :: closeLine end.score
            :: viewPatched end.answers
            :: viewToday model
            :: viewAfter model end.after
        )


{-| The day, under the score: "3 fixed today". The same words the hub
and the session use, and the same plain count.
-}
viewToday : Model -> Html Msg
viewToday model =
    case model.today of
        Just today ->
            p [ id "pz-today", class "q-note text-[13px] mb-4" ]
                [ text (Mistakes.fixedToday today.done) ]

        Nothing ->
            text ""


{-| What the run patched, under the score: "You patched 2 very bad
moves." Nothing when it crossed nobody over the rung -- the score has
already said how it went -- and nothing for a guest, whose mistakes
nothing is keeping.
-}
viewPatched : List Answer -> Html Msg
viewPatched answers =
    case patchedLine answers of
        Just line ->
            p [ id "pz-patched", class "q-note text-[13px] leading-snug mb-4" ] [ text line ]

        Nothing ->
            text ""


{-| The sentence, from the answers the run collected: the grade of every
mistake whose schedule says this answer patched it.
-}
patchedLine : List Answer -> Maybe String
patchedLine answers =
    answers
        |> List.filterMap
            (\answer ->
                case answer.schedule of
                    Just schedule ->
                        if schedule.patched && answer.grade /= "" then
                            Just answer.grade

                        else
                            Nothing

                    Nothing ->
                        Nothing
            )
        |> Mistakes.patchedRun


{-| "7 of 10 right" -- or, for the run of one this page is built to
invite, a sentence that says so warmly.
-}
runScore : Score -> String
runScore score =
    Mistakes.runSummary score


closeLine : Score -> Html Msg
closeLine score =
    if score.close > 0 && score.total > 1 then
        p [ id "pz-close", class "q-note text-[13px] mb-4" ]
            [ text (String.fromInt score.close ++ " close") ]

    else
        p [ class "mb-4" ] []


viewAfter : Model -> After -> List (Html Msg)
viewAfter _ after =
    case after of
        BackToPuzzles ->
            [ a
                [ href (Route.href Route.puzzles)
                , id "pz-home"
                , class "inline-block font-semibold"
                , attribute "style" "color: var(--pen)"
                ]
                [ text "Back to puzzles →" ]
            ]

        AskSignIn signIn ->
            [ p [ id "pz-signin-ask", class "text-[16px] font-semibold leading-snug mb-4", attribute "style" "color: var(--ink)" ]
                [ text "Sign in and we'll keep this: these come back until you stop making them." ]
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


{-| Where this session is, above the board: the tier's mark, the day's
count, the marks so far, and why this position is here.

Only in a run, and only on the puzzle itself: a puzzle opened from a
link is not a session and says nothing about one.

**No bar, and no "4 of 10".** A run has no length -- it goes on until
I'M DONE -- so a counter out of a total would promise a finish line
that does not exist. What is drawn instead is what has actually
happened: how many were fixed today, and a mark for each one answered
so far.

-}
viewProgress : Model -> Html Msg
viewProgress model =
    case model.progress of
        Nothing ->
            text ""

        Just progress ->
            div [ class "pz-progress", id "pz-progress" ]
                [ div [ class "pz-progress-bar" ]
                    [ p [ class "pz-progress-count pixel text-[8px]", id "pz-progress-count" ]
                        [ text (runProgress model) ]
                    , div [ class "pz-marks", id "pz-marks" ]
                        (progress.marks
                            |> List.take (progress.at + 1)
                            |> List.indexedMap (runMark progress.at)
                        )
                    , viewWhy model
                    ]
                ]


{-| Why this position is in front of you: "A very bad move, from your
game vs Charlie". Only for the player who was in the game it came from --
on a shared link the server says nothing, and neither does this.

It is the mistake's severity and whose game it was, and nothing else: it
is drawn before the answer, so nothing that could hint at one is in it.
-}
viewWhy : Model -> Html Msg
viewWhy model =
    case model.why of
        Just why ->
            p [ class "pz-why", id "pz-why" ]
                [ text (Mistakes.whyLine { grade = why.grade, opponent = why.opponent }) ]

        Nothing ->
            text ""


{-| "?? · 3 fixed today": which tier this run is of, and what the day
has had. The mark alone for a guest, who has no day counted; the count
alone for a run of one game's mistakes, which is not a tier.
-}
runProgress : Model -> String
runProgress model =
    [ Maybe.map Mistakes.mark model.tier
    , Maybe.map (\today -> Mistakes.fixedToday today.done) model.today
    ]
        |> List.filterMap identity
        |> List.filter (\part -> part /= "")
        |> String.join " · "


{-| One mark per puzzle of the run, in order, in the verdict's own
colours: right, close, missed, or not answered yet. The one being played
is named so the player can see where they are.
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
    in
    span
        [ classList [ ( "pz-mark", True ), ( "is-" ++ name, True ), ( "is-here", index == at ) ]
        , attribute "data-mark" name
        , attribute "aria-hidden" "true"
        ]
        []


viewHead : Html Msg
viewHead =
    div [ class "rp-head" ]
        [ Ui.Shell.mark
        , span [ class "rp-tag pixel text-[7px] sm:text-[8px]" ] [ text "PUZZLE" ]
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
                    "cube centred"
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
                    :: (if model.hasNext then
                            [ button [ class "q-btn pz-action", id "pz-next", onClick Next ]
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


viewVerdict : Reveal -> Html Msg
viewVerdict reveal =
    let
        ( word, sentence ) =
            case reveal.verdict of
                Pass ->
                    ( "RIGHT", "That is the play." )

                Hold ->
                    ( "CLOSE", "Not far off the best." )

                Fail ->
                    ( "NOT THIS TIME", "The best play is better." )

                Unknown ->
                    ( "UNRANKED", "The engine did not rank this one." )
    in
    div [ class ("pz-verdict is-" ++ Puzzle.verdictName reveal.verdict), id "pz-verdict", attribute "data-verdict" (Puzzle.verdictName reveal.verdict) ]
        [ span [ class "pz-verdict-word pixel text-[9px]" ] [ text word ]
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


{-| The level line and the four buttons, for an account whose deck holds
the card. The graded button is preselected where the engine graded the
play and the player may amend it; nothing is where the player grades it;
no buttons where there is nothing to say. NEVER puts the card aside.
-}
viewSchedule : Model -> Reveal -> List (Html Msg)
viewSchedule model reveal =
    case reveal.schedule of
        Nothing ->
            []

        Just schedule ->
            let
                chosen =
                    case model.outcome of
                        Just outcome ->
                            Just outcome

                        Nothing ->
                            preselected reveal.verdict schedule

                offered =
                    (schedule.amendable || schedule.selfGrade) && model.outcome /= Just "never"

                line =
                    if model.outcome == Just "never" then
                        "Set aside: it will not come back."

                    else if not schedule.amendable && not schedule.selfGrade then
                        "Already scheduled."

                    else
                        levelLine model.now schedule

                option outcome label =
                    button
                        [ classList [ ( "pz-outcome", True ), ( "is-on", chosen == Just outcome ) ]
                        , id ("pz-outcome-" ++ String.replace "_" "-" outcome)
                        , attribute "data-outcome" outcome
                        , attribute "aria-pressed"
                            (if chosen == Just outcome then
                                "true"

                             else
                                "false"
                            )
                        , disabled model.outcomeSending
                        , onClick (PressedOutcome outcome)
                        ]
                        [ text label ]
            in
            [ div
                [ classList
                    [ ( "pz-level", True )
                    , ( "is-patched", patchedNow model schedule )
                    ]
                , id "pz-level"
                ]
                [ span [ class "pz-level-line", id "pz-level-line" ] [ text line ]
                , if offered then
                    div [ class "pz-outcomes", id "pz-outcomes" ]
                        [ option "sooner" "SOONER"
                        , option "got_it" "GOT IT"
                        , option "knew_it" "KNEW IT"
                        , option "never" "NEVER"
                        ]

                  else
                    text ""
                , case model.outcomeError of
                    Just why ->
                        span [ class "pz-outcome-error", id "pz-outcome-error" ] [ text why ]

                    Nothing ->
                        text ""
                ]
            ]


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
    if schedule.patched then
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
