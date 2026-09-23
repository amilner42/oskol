module Page.Replay exposing
    ( Loadable(..)
    , Model
    , Msg(..)
    , Out(..)
    , Showing(..)
    , Tab(..)
    , init
    , keyDecoder
    , maxPolls
    , pollEveryMs
    , polling
    , subscriptions
    , title
    , update
    , view
    , locate
    , settled
    , url
    )

{-| `/:slug/:id/replay` — a room's games played again, one line of the
record at a time, with the analysis engine's verdicts on each.

The page reads and decides nothing about backgammon. It asks for the room's
whole record (`/record`: every game, every line, the position after every
turn), for the index of the analysis (`/reviews`: per game a status and a
turn count, a few hundred bytes) and then for the analysis of the one game
being read (`/reviews/<n>`: per turn the grade of the move played, the best
move and the position it leaves, the cube verdicts, the luck; per player
the PR). Switching to another game fetches that game's analysis if it is
not already in hand, and nothing is fetched twice. All of it is drawn as it
comes. The server names which record line each verdict is about.

The replay is usable the moment the record arrives. Analysis takes a while
(a few minutes a game at 4-ply), so a game still being analysed says so, the
page asks the index again every few seconds while anything is pending, and
the grades fill in where the viewer is -- the game, the step and the move on
the board stay put. A game whose analysis failed offers to try again.

Stepping: the buttons under the board, the arrow keys (Home and End for
the first and last line), a swipe across the board, or a tap on a line of
the move list.

A reader who holds a seat here is offered PRACTICE THIS GAME'S N MISTAKES
on the analysis of each game whose review is done: the page asks
`/puzzles?game=n` for that game's mistakes, the seat's own, as the game is
switched to, and the shell runs them (`StartRun`) and brings the reader
back to this page at the end.

-}

import Api
import Api.Practice as Practice
import Browser.Dom
import Browser.Events
import Dict
import Games.Backgammon.Replay as Replay exposing (Annotation(..), Candidate, Entry(..), Game, GameAnalysis, GameReview, Index, MoveReview(..), Record, Review, Status(..), TurnReview)
import Games.Backgammon.View as Board
import Games.Backgammon.Words exposing (answerInWords, chanceCells, cubeChances, cubeLine, doubleInWords, gradeTag, inWords, lost, moveInWords, noDoubleInWords, signed, verdictTag)
import Api.Catalog as Catalog
import Page.Play exposing (storePref)
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, href, id, style)
import Html.Events exposing (on, onClick)
import Json.Decode as D
import Json.Encode as E
import Process
import Route
import Session exposing (Session)
import Svg
import Svg.Attributes as SvgAttr
import Task
import Time
import Ui.Scrub
import Ui.Shell



-- MODEL


type Loadable a
    = Loading
    | Loaded a
    | Unavailable String


{-| What the board shows at the current step: the move that was played, or
one the engine proposes (by its rank among the top moves).
-}
type Showing
    = Played
    | Proposed Int
    | Before -- the roll on the position it was thrown into, the move not yet made


{-| The two sides of a turn's verdict: the move played, and the cube that
could have been turned before the roll.
-}
type NoteTab
    = MoveTab
    | CubeTab


type Tab
    = MovesTab
    | SummaryTab


type alias Model =
    { session : Session
    , slug : String
    , gameId : String
    , wanted : Maybe Int -- the game the link asked for
    , wantedStep : Maybe Int -- and the line of it
    , record : Loadable Record
    , index : Maybe Index -- what the server says of each game's analysis
    , analyses : Dict.Dict Int Review -- the games whose analysis has been fetched
    , fetching : List Int -- games whose analysis is on its way
    , analysisErrors : List Int -- games whose analysis did not arrive
    , reviewsError : Bool -- the last ask for the index did not get an answer
    , failures : Int -- asks that came back with nothing
    , asking : Bool -- an ask for the index is out; a second would only double the work
    , game : Int -- the game being replayed, by number
    , step : Int -- 0 is the start; n is the board after the game's nth line
    , showing : Showing
    , noteTab : Maybe NoteTab -- which side of the turn's verdict is open; Nothing until the step decides
    , tab : Tab
    , touch : Maybe ( Float, Float ) -- where a touch on the board began
    , polls : Int -- asks made while something was pending
    , retrying : List Int -- games whose retry is on its way
    , flipped : Bool -- the board is turned around: the other player is at the bottom
    , matchOpen : Bool -- the match panel (the games, to pick one) is open over the board
    , themesOpen : Bool -- the board picker's list is showing
    , gamePrs : Dict.Dict Int (List ( String, Float )) -- each graded game's PRs by seat, from /ratings
    , matchPrs : Dict.Dict String Float -- each seat's PR over the match so far
    , mistakes : Dict.Dict Int (List String) -- each graded game's mistakes for the reader's seat, by number: what PRACTICE runs
    , mistakeAsks : Dict.Dict Int Int -- asks made for a game's mistakes still unanswered (they land a moment after the grade)
    }


{-| How often a page with pending analysis asks again. What it asks for is
the index: a few hundred bytes read from rows, with no replay behind it, so
this can be a normal cadence rather than the slow drum it had to be while
every ask rebuilt a whole match.
-}
pollEveryMs : Float
pollEveryMs =
    4000


{-| A page left open on an analysis that never lands stops asking after
this many (about twenty minutes, as long as the server waits on the
engine); a reload starts again.
-}
maxPolls : Int
maxPolls =
    300


{-| How many answers may fail before the page stops asking. A failing ask
is the one case where asking again is actively harmful: the answer is
expensive to build, so a page that retries a failing server is helping to
keep it down. It says so and waits for a reload instead.
-}
maxFailures : Int
maxFailures =
    2


init :
    Session
    -> { slug : String, gameId : String, game : Maybe Int, step : Maybe Int }
    -> ( Model, Cmd Msg )
init session config =
    let
        model =
            { session = session
            , slug = config.slug
            , gameId = config.gameId
            , wanted = config.game
            , wantedStep = config.step
            , record = Loading
            , index = Nothing
            , analyses = Dict.empty
            , fetching = []
            , analysisErrors = []
            , reviewsError = False
            , failures = 0
            , asking = True
            , game = Maybe.withDefault 1 config.game
            , step = 0
            , showing = Played
            , noteTab = Nothing
            , tab = SummaryTab
            , touch = Nothing
            , polls = 0
            , retrying = []
            , flipped = False
            , matchOpen = False
            , themesOpen = False
            , gamePrs = Dict.empty
            , matchPrs = Dict.empty
            , mistakes = Dict.empty
            , mistakeAsks = Dict.empty
            }
    in
    ( model
    , Cmd.batch
        [ Api.get session (base model ++ "/record") Replay.recordDecoder GotRecord
        , fetchIndex model
        , Catalog.fetchRatings session config.slug config.gameId GotRatings
        ]
    )


base : Model -> String
base model =
    "/papi/games/" ++ model.slug ++ "/rooms/" ++ model.gameId


{-| The analysis opens to anyone the record does.

The index is the cheap half: a line per game, and what polling watches.
-}
fetchIndex : Model -> Cmd Msg
fetchIndex model =
    Api.get model.session (base model ++ "/reviews") Replay.indexDecoder GotIndex


{-| One game's analysis: the big answer, asked for only when it is the game
being read and is not already in hand.
-}
fetchAnalysis : Model -> Int -> Cmd Msg
fetchAnalysis model number =
    Api.get model.session
        (base model ++ "/reviews/" ++ String.fromInt number)
        Replay.analysisDecoder
        (GotAnalysis number)


{-| Ask for the analysis of the game being read, if the index says there is
one, it is not already held, and nothing is already asking for it. A game
fetched once is kept for the session: a finished game's analysis never
changes.
-}
wantAnalysis : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
wantAnalysis ( model, cmd ) =
    let
        number =
            model.game

        status =
            model.index |> Maybe.andThen (Replay.indexEntry number) |> Maybe.map .status
    in
    if
        (status == Just Done)
            && not (Dict.member number model.analyses)
            && not (List.member number model.fetching)
            && not (List.member number model.analysisErrors)
    then
        ( { model | fetching = number :: model.fetching }
        , Cmd.batch [ cmd, fetchAnalysis model number ]
        )
            |> wantMistakes

    else
        wantMistakes ( model, cmd )


{-| Ask for the mistakes of the game being read, if its review is done, the
reader holds a seat here (a stranger would be told 404) and they are not
in hand or on their way. Written a moment after the grade, so an ask may
be told to come back (`GotMistakes`).
-}
wantMistakes : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
wantMistakes ( model, cmd ) =
    let
        number =
            model.game

        status =
            model.index |> Maybe.andThen (Replay.indexEntry number) |> Maybe.map .status
    in
    if
        (status == Just Done)
            && seated model
            && not (Dict.member number model.mistakes)
            && not (Dict.member number model.mistakeAsks)
    then
        ( { model | mistakeAsks = Dict.insert number 1 model.mistakeAsks }
        , Cmd.batch [ cmd, Practice.gameMistakes model.session model.slug model.gameId number (GotMistakes number) ]
        )

    else
        ( model, cmd )


{-| How long the page waits between asks for a game whose puzzles are still
being written, and how many it makes before it stops: a minute in all.
-}
mistakesRetryMs : Float
mistakesRetryMs =
    3000


maxMistakeAsks : Int
maxMistakeAsks =
    20


title : Model -> String
title model =
    case model.record of
        Loaded record ->
            "Replay · " ++ (record.players |> List.map (.id >> Replay.playerNamed record) |> String.join " vs ")

        _ ->
            "Replay"



-- UPDATE


type Msg
    = GotRecord (Result Api.Error Record)
    | GotIndex (Result Api.Error Index)
    | GotAnalysis Int (Result Api.Error GameAnalysis)
    | Poll
    | PickGame Int
    | GoTo Int
    | PickNote NoteTab
    | First
    | Prev
    | Next
    | Last
    | Show Showing
    | PickTab Tab
    | TouchStarted ( Float, Float )
    | TouchEnded ( Float, Float )
    | Retry Int
    | Follow Int -- keep this step's line in view, if it is still the current one
    | Flipped -- turn the board around
    | ToggleMatch -- open or close the match panel
    | ToggleThemes -- open or close the board picker
    | PickTheme String -- this reader's board colours: display only
    | GotRatings (Result Api.Error Catalog.Ratings)
    | AskMistakes Int
    | GotMistakes Int (Result Api.Error Practice.Practice)
    | PracticeGame Int -- PRACTICE THIS GAME'S N MISTAKES
    | NoOp


{-| What the shell does for the page: nothing, or run these puzzles and
bring the reader back here at the end.
-}
type Out
    = NoOut
    | StartRun (List String)


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        PracticeGame number ->
            case Dict.get number model.mistakes of
                Just ids ->
                    ( model, Cmd.none, StartRun ids )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        _ ->
            let
                ( next, cmd ) =
                    advance msg model
            in
            ( next, cmd, NoOut )


{-| Every message but the one the shell acts on.
-}
advance : Msg -> Model -> ( Model, Cmd Msg )
advance msg model =
    case msg of
        PracticeGame _ ->
            ( model, Cmd.none )

        AskMistakes number ->
            case Dict.get number model.mistakeAsks of
                Just asks ->
                    if asks < maxMistakeAsks then
                        ( { model | mistakeAsks = Dict.insert number (asks + 1) model.mistakeAsks }
                        , Practice.gameMistakes model.session model.slug model.gameId number (GotMistakes number)
                        )

                    else
                        ( { model | mistakeAsks = Dict.remove number model.mistakeAsks }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        GotMistakes number (Ok practice) ->
            ( { model
                | mistakes = Dict.insert number (List.map .id practice.puzzles) model.mistakes
                , mistakeAsks = Dict.remove number model.mistakeAsks
              }
            , Cmd.none
            )

        GotMistakes number (Err err) ->
            if Practice.stillWriting err then
                -- The grade is in and the puzzles are on their way: a
                -- moment, then again (bounded by `maxMistakeAsks`).
                ( model, Process.sleep mistakesRetryMs |> Task.perform (\_ -> AskMistakes number) )

            else
                -- No seat here after all, or a network slip: no button.
                ( { model | mistakeAsks = Dict.remove number model.mistakeAsks }, Cmd.none )

        Flipped ->
            ( { model | flipped = not model.flipped }, Cmd.none )

        ToggleMatch ->
            ( { model | matchOpen = not model.matchOpen }, Cmd.none )

        ToggleThemes ->
            ( { model | themesOpen = not model.themesOpen }, Cmd.none )

        -- The board changes at once; this browser keeps it, and the guest's
        -- row keeps it for their other browsers.
        PickTheme name ->
            ( { model | themesOpen = False, session = Session.withPref "backgammon_theme" name model.session }
            , Cmd.batch
                [ storePref { key = "backgammon_theme", value = name }
                , Catalog.savePref model.session "backgammon_theme" name (always NoOp)
                ]
            )

        GotRatings (Ok ratings) ->
            ( { model | gamePrs = ratings.games, matchPrs = ratings.prs }, Cmd.none )

        GotRatings (Err _) ->
            ( model, Cmd.none )

        GotRecord (Ok record) ->
            let
                -- the game the link named, else the last one that was
                -- finished (what a player just played), else the last
                finished =
                    record.games |> List.filter (\g -> endsInResult g) |> List.reverse |> List.head

                chosen =
                    case model.wanted |> Maybe.andThen (\n -> Replay.findGame n record) of
                        Just g ->
                            Just g

                        Nothing ->
                            case finished of
                                Just g ->
                                    Just g

                                Nothing ->
                                    record.games |> List.reverse |> List.head
            in
            let
                -- The line the link asked for, if it named one this game has.
                step =
                    case ( model.wantedStep, chosen ) of
                        ( Just wanted, Just g ) ->
                            clamp 0 (Replay.lastStep g) wanted

                        _ ->
                            0
            in
            wantAnalysis
                ( arrive step
                    { model
                        | record = Loaded record
                        , game = chosen |> Maybe.map .number |> Maybe.withDefault 1
                    }
                , if step > 0 then
                    follow step

                  else
                    Cmd.none
                )

        GotRecord (Err err) ->
            ( { model | record = Unavailable (Api.errorMessage err) }, Cmd.none )

        GotIndex (Ok index) ->
            -- Replaced whole, whatever the viewer is looking at: the game,
            -- the step and the move on the board are the model's, not the
            -- index's, so nothing moves.
            wantAnalysis
                ( { model | index = Just index, reviewsError = False, failures = 0, asking = False, retrying = [] }
                , follow model.step
                )

        GotIndex (Err _) ->
            ( { model | reviewsError = True, failures = model.failures + 1, asking = False, retrying = [] }, Cmd.none )

        GotAnalysis number (Ok analysis) ->
            -- Kept for the session: the game is over, so its analysis will
            -- not change. Nothing about where the viewer is moves, except
            -- that a step waiting on it now learns which side to open on.
            let
                stored =
                    { model
                        | analyses =
                            case analysis.review of
                                Just review ->
                                    Dict.insert number review model.analyses

                                Nothing ->
                                    model.analyses
                        , fetching = List.filter (\n -> n /= number) model.fetching
                    }
            in
            ( if number == model.game && model.noteTab == Nothing && model.showing == Played then
                arrive model.step stored

              else
                stored
            , follow model.step
            )

        GotAnalysis number (Err _) ->
            -- Not asked for again on its own: this answer is the expensive
            -- one, and a page that retries it is part of what is wrong.
            ( { model
                | fetching = List.filter (\n -> n /= number) model.fetching
                , analysisErrors = number :: model.analysisErrors
              }
            , Cmd.none
            )

        Poll ->
            -- Never two asks at once: the answer takes the server real work
            -- to build, and a page that overlaps its own asks multiplies it.
            if model.asking then
                ( model, Cmd.none )

            else
                ( { model | polls = model.polls + 1, asking = True }, fetchIndex model )

        PickGame number ->
            if number == model.game then
                ( model, Cmd.none )

            else
                wantAnalysis ( { model | matchOpen = False, game = number, step = 0, showing = Played, noteTab = Nothing }, follow 0 )

        GoTo step ->
            goTo step model

        -- The cube tab is about the position before the roll, so the dice
        -- come off the board with it; the move tab puts the move back.
        PickNote tab ->
            ( { model
                | noteTab = Just tab
                , showing =
                    case tab of
                        CubeTab ->
                            Before

                        MoveTab ->
                            Played
              }
            , Cmd.none
            )

        First ->
            goTo 0 model

        Prev ->
            goTo (model.step - 1) model

        Next ->
            goTo (model.step + 1) model

        Last ->
            goTo (currentGame model |> Maybe.map Replay.lastStep |> Maybe.withDefault 0) model

        Show showing ->
            ( { model | showing = showing }, follow model.step )

        PickTab tab ->
            ( { model | tab = tab }, if tab == MovesTab then follow model.step else Cmd.none )

        TouchStarted point ->
            ( { model | touch = Just point }, Cmd.none )

        TouchEnded ( x, y ) ->
            case model.touch of
                Just ( x0, y0 ) ->
                    let
                        dx =
                            x - x0

                        dy =
                            y - y0

                        swiped =
                            { model | touch = Nothing }
                    in
                    -- a deliberate sideways swipe: far enough, and more
                    -- across than down (a scroll is not a step)
                    if abs dx > 40 && abs dx > 1.5 * abs dy then
                        if dx < 0 then
                            goTo (model.step + 1) swiped

                        else
                            goTo (model.step - 1) swiped

                    else
                        ( swiped, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Retry number ->
            -- Only a player may spend engine time, and the server decides
            -- that from the guest cookie this request carries; the button
            -- is only offered to one (`seated`).
            ( { model
                | retrying = number :: model.retrying
                , analysisErrors = List.filter (\n -> n /= number) model.analysisErrors
              }
            , Api.post model.session
                (base model ++ "/reviews/retry")
                (E.object [ ( "game_number", E.int number ) ])
                Replay.indexDecoder
                GotIndex
            )

        Follow step ->
            if step == model.step then
                ( model, followNow step )

            else
                ( model, Cmd.none )

        NoOp ->
            ( model, Cmd.none )


endsInResult : Game -> Bool
endsInResult game =
    case List.reverse game.entries of
        (ResultEntry _) :: _ ->
            True

        _ ->
            False


{-| Move to a step of the current game, kept within it; the move on the
board goes back to the one played.
-}
goTo : Int -> Model -> ( Model, Cmd Msg )
goTo step model =
    let
        last =
            currentGame model |> Maybe.map Replay.lastStep |> Maybe.withDefault 0

        clamped =
            clamp 0 last step
    in
    if clamped == model.step then
        ( model, Cmd.none )

    else
        ( arrive clamped model, follow clamped )


{-| Land on a step: the move on the board, and the note open on the move,
unless the cube was this turn's mistake, in which case the note opens on
the cube and the board shows the position it was about.
-}
arrive : Int -> Model -> Model
arrive step model =
    let
        placed =
            { model | step = step, showing = Played, noteTab = Nothing }

        tab =
            defaultNoteTab placed
    in
    case tab of
        Just CubeTab ->
            { placed | noteTab = tab, showing = Before }

        _ ->
            { placed | noteTab = tab }


{-| The engine's verdicts on one line of the current game. A game played
without the cube has no cube to have turned, whatever the engine graded,
so its cube verdicts are dropped here, once, for every reader.
-}
notesAt : Model -> Int -> List Annotation
notesAt model index =
    let
        withCube =
            case model.record of
                Loaded record ->
                    record.cube

                _ ->
                    True
    in
    currentReview model
        |> Maybe.andThen .review
        |> Maybe.map (\r -> Replay.annotationsAt r index)
        |> Maybe.withDefault []
        |> List.filter
            (\n ->
                case n of
                    NoDoubleNote _ _ ->
                        withCube

                    _ ->
                        True
            )


{-| Which side a turn's note should open on: the cube when it cost more
than the move, else the move. Nothing before the analysis is in.
-}
defaultNoteTab : Model -> Maybe NoteTab
defaultNoteTab model =
    let
        notes =
            notesAt model (model.step - 1)

        cost pick =
            notes |> List.filterMap pick |> List.head |> Maybe.withDefault 0

        cubeCost =
            cost
                (\n ->
                    case n of
                        NoDoubleNote _ c ->
                            Just c.doubler.equityLost

                        _ ->
                            Nothing
                )

        moveCost =
            cost
                (\n ->
                    case n of
                        MoveNote _ (Moved m) ->
                            Just m.equityLost

                        _ ->
                            Nothing
                )
    in
    if model.step > 0 && notes /= [] then
        if cubeCost > 0 && cubeCost > moveCost then
            Just CubeTab

        else
            Just MoveTab

    else
        Nothing


{-| Whether the record is in, so the game on the page is the page's choice
and not the default it opens with.
-}
settled : Model -> Bool
settled model =
    case model.record of
        Loaded _ ->
            True

        _ ->
            False


{-| Where the page is, as a link: the game and the line on the board. Main
keeps the address bar on it, so a reload and a shared link land here.
-}
url : Model -> String
url model =
    Route.href (Route.replayAt model.slug model.gameId model.game model.step)


{-| The address bar moved on its own (back, forward, a link typed) to a
game and a line of this same room: go there without starting over. A game
the record does not have is left alone.
-}
locate : Maybe Int -> Maybe Int -> Model -> ( Model, Cmd Msg )
locate game step model =
    let
        number =
            Maybe.withDefault model.game game

        ( switched, cmd ) =
            if number == model.game then
                ( model, Cmd.none )

            else
                case model.record of
                    Loaded record ->
                        case Replay.findGame number record of
                            Just _ ->
                                wantAnalysis ( { model | matchOpen = False, game = number, step = 0, showing = Played, noteTab = Nothing }, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    _ ->
                        ( model, Cmd.none )

        ( placed, cmd2 ) =
            goTo (Maybe.withDefault 0 step) switched
    in
    ( placed, Cmd.batch [ cmd, cmd2 ] )


{-| Keep the current line of the move list in view, once the steps have
stopped for a moment: measuring takes a few frames, and two measurements
under way at once would read each other's scrolling.
-}
follow : Int -> Cmd Msg
follow step =
    Process.sleep 120 |> Task.perform (\_ -> Follow step)


followNow : Int -> Cmd Msg
followNow step =
    Browser.Dom.getElement (lineId step)
        |> Task.andThen
            (\line ->
                Browser.Dom.getElement "rp-list"
                    |> Task.andThen
                        (\list ->
                            Browser.Dom.getViewportOf "rp-list"
                                |> Task.andThen
                                    (\vp ->
                                        let
                                            top =
                                                vp.viewport.y + line.element.y - list.element.y

                                            bottom =
                                                top + line.element.height

                                            visible =
                                                top >= vp.viewport.y && bottom <= vp.viewport.y + vp.viewport.height
                                        in
                                        if visible then
                                            Task.succeed ()

                                        else
                                            Browser.Dom.setViewportOf "rp-list" 0 (top - vp.viewport.height / 3)
                                    )
                        )
            )
        |> Task.attempt (\_ -> NoOp)


lineId : Int -> String
lineId step =
    "rp-line-" ++ String.fromInt step


currentGame : Model -> Maybe Game
currentGame model =
    case model.record of
        Loaded record ->
            Replay.findGame model.game record

        _ ->
            Nothing


currentReview : Model -> Maybe GameReview
currentReview model =
    model.index |> Maybe.andThen (\index -> Replay.gameReview model.game index model.analyses)


{-| Whether this reader holds one of the room's seats, which the server
decides from the guest cookie the request carried -- never from the link,
which anyone may have been sent. Only a player's own visit puts the
analysis engine to work, so only a player is told an analysis is on its
way, and only a player may ask for a failed one again.
-}
seated : Model -> Bool
seated model =
    case model.record of
        Loaded record ->
            record.seated

        _ ->
            False


{-| Ask again only while some game's analysis is genuinely on its way --
never because an ask failed. Building this answer is expensive, so a page
that retries a struggling server is part of what is wrong with it: after
`maxFailures` it stops and says to reload. Never past `maxPolls` either.
-}
polling : Model -> Bool
polling model =
    model.polls
        < maxPolls
        && model.failures
        < maxFailures
        && seated model
        && (case model.index of
                Just index ->
                    Replay.wantsPolling index

                Nothing ->
                    False
           )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Browser.Events.onKeyDown keyDecoder
        , if polling model then
            Time.every pollEveryMs (\_ -> Poll)

          else
            Sub.none
        ]


{-| The keys that step: the arrows one line, Home and End to the ends.
-}
keyDecoder : D.Decoder Msg
keyDecoder =
    D.field "key" D.string |> D.andThen keyMsg


keyMsg : String -> D.Decoder Msg
keyMsg key =
    case key of
        "ArrowRight" ->
            D.succeed Next

        "ArrowLeft" ->
            D.succeed Prev

        "Home" ->
            D.succeed First

        "End" ->
            D.succeed Last

        _ ->
            D.fail "not a step"



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "rp-page paper", id "replay" ]
        (case model.record of
            Loading ->
                [ viewHead model Nothing, div [ class "rp-message pixel text-[9px]" ] [ text "LOADING THE GAME…" ] ]

            Unavailable reason ->
                [ viewHead model Nothing
                , div [ class "rp-message" ]
                    [ span [ class "pixel text-[9px]" ] [ text "NO REPLAY" ]
                    , span [ class "text-sm", style "color" "var(--pencil)" ] [ text reason ]
                    ]
                ]

            Loaded record ->
                case Replay.findGame model.game record of
                    Just game ->
                        viewReplay model record game

                    Nothing ->
                        [ viewHead model (Just record)
                        , div [ class "rp-message pixel text-[9px]" ] [ text "NO GAMES PLAYED YET" ]
                        ]
        )


{-| Whose side is at the bottom of the board: the seat the link carries (or
the first seat when it carries none), turned around by the flip control.
-}
facing : Model -> Record -> String
facing model record =
    if model.flipped then
        record.players
            |> List.map .id
            |> List.filter (\id -> id /= record.you)
            |> List.head
            |> Maybe.withDefault record.you

    else
        record.you


viewHead : Model -> Maybe Record -> Html Msg
viewHead model record =
    let
        matchLabel r =
            if r.target <= 0 then
                "UNLIMITED"

            else if r.target == 1 then
                "SINGLE GAME"

            else
                "MATCH TO " ++ String.fromInt r.target
    in
    div [ class "rp-head" ]
        [ Ui.Shell.mark
        , case record of
            Just r ->
                span [ class "rp-tag pixel text-[7px] sm:text-[8px] truncate" ]
                    [ text (matchLabel r ++ " · " ++ (r.players |> List.map (.id >> Replay.playerNamed r >> String.toUpper) |> String.join " v ")) ]

            Nothing ->
                text ""
        , viewThemePicker model
        ]


{-| The board picker, as the table and the home page draw it: the chip of
the board you are looking at and a chevron that turns; the list beneath.
-}
viewThemePicker : Model -> Html Msg
viewThemePicker model =
    let
        current =
            theme model
    in
    div [ class "bg-themes rp-themes shrink-0" ]
        [ button
            [ class "flex items-center gap-1 px-1 py-0.5"
            , id "bg-theme-button"
            , attribute "aria-expanded"
                (if model.themesOpen then
                    "true"

                 else
                    "false"
                )
            , Html.Attributes.title "Board colours"
            , onClick ToggleThemes
            ]
            [ span [ class ("bg-theme-chip " ++ Board.themeClass current) ] [ Board.themeBoard ]
            , span [ class "bg-theme-chevron hero-chevron-down w-3.5 h-3.5", attribute "aria-hidden" "true" ] []
            ]
        , if model.themesOpen then
            div [ class "bg-theme-list", id "bg-theme-list" ]
                (List.map
                    (\( key, name ) ->
                        button
                            [ classList [ ( "bg-theme-option", True ), ( "on", key == current ) ]
                            , attribute "data-theme-option" key
                            , Html.Attributes.title name
                            , onClick (PickTheme key)
                            ]
                            [ span [ class ("bg-theme-chip " ++ Board.themeClass key) ] [ Board.themeBoard ]
                            , span [ class "bg-theme-name" ] [ text name ]
                            ]
                    )
                    Board.themes
                )

          else
            text ""
        ]


nameOf : Record -> String -> String
nameOf record id =
    Replay.playerNamed record id


viewReplay : Model -> Record -> Game -> List (Html Msg)
viewReplay model record game =
    let
        still =
            Replay.stillAt record game model.step

        review =
            currentReview model |> Maybe.andThen .review

        proposed =
            case ( model.showing, review, Replay.entryAt game model.step ) of
                ( Proposed rank, Just r, Just (TurnEntry _) ) ->
                    Replay.moveAt r (model.step - 1)
                        |> Maybe.andThen
                            (\( _, move ) ->
                                case move of
                                    Moved m ->
                                        m.top |> List.filter (\c -> c.rank == rank) |> List.head

                                    Danced ->
                                        Nothing
                            )

                _ ->
                    Nothing

        shown =
            case ( model.showing, Replay.entryAt game model.step ) of
                ( Before, Just (TurnEntry _) ) ->
                    -- the board the roll was thrown into: last step's position, this
                    -- turn's dice and mover, nothing landed yet
                    let
                        previous =
                            Replay.stillAt record game (model.step - 1)
                    in
                    { still | position = previous.position, landed = [] }

                _ ->
                    proposed |> Maybe.andThen (Replay.stillForCandidate still) |> Maybe.withDefault still

        -- The played move's grade, while it is the one on the board: the
        -- board wears its colour and a tab names it, so stepping through a
        -- game says at a glance which moves were good and which cost.
        playedGrade =
            case ( model.showing, review, Replay.entryAt game model.step ) of
                ( Played, Just r, Just (TurnEntry _) ) ->
                    Replay.moveAt r (model.step - 1)
                        |> Maybe.andThen
                            (\( _, move ) ->
                                case move of
                                    Moved m ->
                                        Just m.grade

                                    Danced ->
                                        Nothing
                            )

                _ ->
                    Nothing

        scores =
            scoresBefore record game

        board =
            Board.viewStill NoOp
                { players =
                    List.map
                        (\p -> { p | name = Replay.playerNamed record p.id })
                        record.players
                , viewer = facing model record
                , scores = scores
                , cube = record.cube
                , theme = theme model
                , key = model.game * 1000 + model.step
                , position = shown.position
                , mover = shown.mover
                , dice = shown.dice
                , landed = shown.landed
                , offer = shown.offer |> Maybe.map .from
                , accounts = Just record.accounts
                }
    in
    [ viewHead model (Just record)
    , if model.matchOpen then
        viewMatchSheet model record

      else
        text ""
    , div [ class "rp-main" ]
        [ div [ class "rp-stage" ]
            [ div
                [ classList
                    [ ( "rp-board", True )
                    , ( "is-proposed", proposed /= Nothing )
                    , ( "is-graded", playedGrade /= Nothing )
                    , ( "dice-played", model.showing /= Before && Replay.entryAt game model.step /= Nothing )
                    , ( "g-" ++ Maybe.withDefault "" playedGrade, playedGrade /= Nothing )
                    ]
                , id "rp-board"
                , on "touchstart" (touchAt TouchStarted)
                , on "touchend" (touchAt TouchEnded)
                ]
                [ board
                , case proposed of
                    Just c ->
                        span [ class "rp-proposed pixel text-[7px] inline-flex items-center gap-1.5" ]
                            [ span [ class "hero-trophy w-3.5 h-3.5", attribute "aria-hidden" "true" ] []
                            , text
                                (if c.rank == 1 then
                                    "BEST MOVE"

                                 else
                                    "ENGINE'S #" ++ String.fromInt c.rank
                                )
                            ]

                    Nothing ->
                        case playedGrade of
                            Just grade ->
                                span [ class ("rp-proposed rp-graded pixel text-[7px] g-" ++ grade), attribute "data-grade" grade ]
                                    [ text (String.toUpper (Replay.gradeLabel grade) ++ " " ++ gradeMark grade) ]

                            Nothing ->
                                text ""
                , viewBestMoveToggle model record game still
                , viewDiceToggle model record game still
                ]
            , viewControls model record game
            ]
        , div [ class "rp-side" ]
            [ viewNote model record game
            , div [ class "rp-panel" ]
                [ div [ class "rp-tabs" ]
                    [ tabButton model SummaryTab "ANALYSIS"
                    , tabButton model MovesTab "MOVES"
                    ]
                , case model.tab of
                    MovesTab ->
                        viewMoves model record game

                    SummaryTab ->
                        viewSummary model record game
                ]
            ]
        ]
    ]


{-| In the band, on the half opposite the dice: the door between the
move played and the engine's best. "SHOW BEST MOVE" while the played move
is up and it was not the best; "SEE MOVE PLAYED" while the best is up;
nothing when the two are one, since the board's green edge already says
so. For either player: a review is a walk through the game.
-}
viewBestMoveToggle : Model -> Record -> Game -> { a | mover : Maybe String } -> Html Msg
viewBestMoveToggle model record game still =
    let
        move =
            currentReview model
                |> Maybe.andThen .review
                |> Maybe.andThen
                    (\r ->
                        if model.step > 0 then
                            Replay.moveAt r (model.step - 1) |> Maybe.map Tuple.second

                        else
                            Nothing
                    )

        -- the dice sit on the mover's side; this goes on the other
        side =
            if still.mover == Just (facing model record) then
                "is-left"

            else
                "is-right"
    in
    case ( Replay.entryAt game model.step, move ) of
        ( Just (TurnEntry _), Just (Moved m) ) ->
            let
                bestIsPlayed =
                    m.played.rank == m.best.rank

                showBest =
                    button [ class "rp-best-toggle btn-arcade sky pixel text-[8px] px-3 py-2", id "rp-best-toggle", onClick (Show (Proposed m.best.rank)) ] [ text "SHOW BEST MOVE" ]

                seePlayed =
                    button [ class "rp-best-toggle btn-arcade plain pixel text-[8px] px-3 py-2", id "rp-best-toggle", onClick (Show Played) ] [ text "SEE MOVE PLAYED" ]
            in
            case model.showing of
                -- the move taken back: the best move is the door; the dice
                -- bring the played one back
                Before ->
                    if bestIsPlayed then
                        text ""

                    else
                        div [ class ("rp-best-toggle-wrap " ++ side) ] [ showBest ]

                -- a best move needs no door: the board's green edge says it
                Played ->
                    if bestIsPlayed then
                        text ""

                    else
                        div [ class ("rp-best-toggle-wrap " ++ side) ] [ showBest ]

                Proposed _ ->
                    div [ class ("rp-best-toggle-wrap " ++ side) ] [ seePlayed ]

        _ ->
            text ""


{-| Over the dice: a tap rewinds the move, so the roll sits on the board
it was thrown into and you can think it through; a second tap plays it
again. The dice are dimmed while the move is on the board.
-}
viewDiceToggle : Model -> Record -> Game -> { a | mover : Maybe String } -> Html Msg
viewDiceToggle model record game still =
    let
        -- the dice sit on the mover's side
        side =
            if still.mover == Just (facing model record) then
                "is-right"

            else
                "is-left"
    in
    case Replay.entryAt game model.step of
        Just (TurnEntry _) ->
            button
                [ class ("rp-dice-toggle " ++ side)
                , id "rp-dice-toggle"
                , attribute "aria-label"
                    (if model.showing == Before then
                        "Show the move played"

                     else
                        "Take the move back: see the roll on the board it was thrown into"
                    )
                , Html.Attributes.title
                    (if model.showing == Before then
                        "Show the move played"

                     else
                        "See the roll before the move"
                    )
                , onClick
                    (if model.showing == Before then
                        Show Played

                     else
                        Show Before
                    )
                ]
                []

        _ ->
            text ""


{-| The annotators' mark for a grade: a tick, nothing, ?!, ?, ??.
-}
gradeMark : String -> String
gradeMark grade =
    case grade of
        "best" ->
            "✓"

        "doubtful" ->
            "?!"

        "bad" ->
            "?"

        "very_bad" ->
            "??"

        _ ->
            ""


touchAt : (( Float, Float ) -> Msg) -> D.Decoder Msg
touchAt toMsg =
    D.field "changedTouches"
        (D.field "0"
            (D.map2 (\x y -> toMsg ( x, y ))
                (D.field "clientX" D.float)
                (D.field "clientY" D.float)
            )
        )


theme : Model -> String
theme model =
    Dict.get "backgammon_theme" model.session.prefs |> Maybe.withDefault Board.defaultTheme


{-| The match score as the game began: the result of the game before it, or
nothing yet.
-}
scoresBefore : Record -> Game -> List ( String, Int )
scoresBefore record game =
    record.games
        |> List.filter (\g -> g.number < game.number)
        |> List.filterMap resultOf
        |> List.reverse
        |> List.head
        |> Maybe.map .scores
        |> Maybe.withDefault []


resultOf : Game -> Maybe { number : Int, winner : String, result : String, points : Int, scores : List ( String, Int ) }
resultOf game =
    case List.reverse game.entries of
        (ResultEntry r) :: _ ->
            Just r

        _ ->
            Nothing


scoreText : Record -> List ( String, Int ) -> String
scoreText record scores =
    record.players
        |> List.map (\p -> scores |> List.filter (\( id, _ ) -> id == p.id) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault 0)
        |> List.map String.fromInt
        |> String.join "–"



-- THE GAME PICKER


{-| The match panel, as the table draws it: a column per player with their
points and match PR (a trophy by the better one), then the games newest
first, a green +N for the winner and a trophy by the better PR of each
game. Here a row is a door: it puts that game on the board.
-}
viewMatchSheet : Model -> Record -> Html Msg
viewMatchSheet model record =
    let
        heading =
            if record.target <= 0 then
                "UNLIMITED"

            else
                "MATCH TO " ++ String.fromInt record.target

        results =
            record.games |> List.filterMap resultOf

        finalScores =
            results |> List.reverse |> List.head |> Maybe.map .scores |> Maybe.withDefault []

        scoreOf id =
            finalScores |> List.filter (\( p, _ ) -> p == id) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault 0

        bestMatchPr =
            Dict.toList model.matchPrs |> List.sortBy Tuple.second |> List.head |> Maybe.map Tuple.first

        column player =
            div [ class "bg-match-col" ]
                [ span [ class "bg-match-col-name truncate" ] [ text (Replay.playerNamed record player.id) ]
                , span [ class "bg-match-col-score pixel tabular-nums" ] [ text (String.fromInt (scoreOf player.id)) ]
                , span [ class "bg-match-col-pr tabular-nums inline-flex items-center gap-1" ]
                    [ if bestMatchPr == Just player.id && Dict.size model.matchPrs > 1 then
                        span [ class "hero-trophy w-3.5 h-3.5", Html.Attributes.title "The better match PR" ] []

                      else
                        text ""
                    , text
                        (case Dict.get player.id model.matchPrs of
                            Just pr ->
                                "PR " ++ Replay.formatPr pr

                            Nothing ->
                                "PR …"
                        )
                    ]
                ]

        -- The game in play, if the match is still going: the record's last
        -- game while it has no result, else the one about to begin. A door
        -- to the table, where it is.
        matchOver =
            record.target > 0 && List.any (\( _, points ) -> points >= record.target) finalScores

        lastGame =
            record.games |> List.reverse |> List.head

        liveNumber =
            case lastGame of
                Just g ->
                    if resultOf g == Nothing then
                        Just g.number

                    else if matchOver then
                        Nothing

                    else
                        Just (g.number + 1)

                Nothing ->
                    Just 1

        liveRow =
            case liveNumber of
                Just n ->
                    [ Html.a
                        [ class "bg-match-row rp-match-row is-live"
                        , id "rp-match-live"
                        , href (Route.href (Route.play model.slug model.gameId))
                        , Html.Attributes.title "The game in play, at the table"
                        ]
                        [ span [ class "bg-match-n pixel text-[7px]" ] [ text ("G" ++ String.fromInt n) ]
                        , span [ class "bg-match-live font-bold flex-1 text-center" ] [ text "In play" ]
                        , span [ class "bg-match-analysis inline-flex items-center", attribute "aria-hidden" "true" ] [ span [ class "hero-play w-4 h-4" ] [] ]
                        ]
                    ]

                Nothing ->
                    []

        row g =
            let
                prs =
                    Dict.get g.number model.gamePrs |> Maybe.withDefault []

                best =
                    prs |> List.sortBy Tuple.second |> List.head |> Maybe.map Tuple.first

                result =
                    resultOf g

                cell player =
                    let
                        won =
                            Maybe.map .winner result == Just player.id

                        played_best =
                            best == Just player.id && List.length prs > 1
                    in
                    div [ classList [ ( "bg-match-cell", True ), ( "win", won ), ( "best", played_best ) ] ]
                        [ case result of
                            Just r ->
                                if won then
                                    span [ class "bg-match-points pixel", Html.Attributes.title r.result ] [ text ("+" ++ String.fromInt r.points) ]

                                else
                                    text ""

                            Nothing ->
                                text ""
                        , span [ class "bg-match-pr tabular-nums inline-flex items-center gap-1" ]
                            [ if played_best then
                                span [ class "hero-trophy w-3.5 h-3.5", Html.Attributes.title "The better PR this game" ] []

                              else
                                text ""
                            , text
                                (prs
                                    |> List.filter (\( id_, _ ) -> id_ == player.id)
                                    |> List.head
                                    |> Maybe.map (Tuple.second >> Replay.formatPr)
                                    |> Maybe.withDefault "…"
                                )
                            ]
                        ]
            in
            button
                [ classList [ ( "bg-match-row rp-match-row", True ), ( "is-on", g.number == model.game ), ( "is-live", result == Nothing ) ]
                , attribute "data-game" (String.fromInt g.number)
                , onClick (PickGame g.number)
                ]
                [ span [ class "bg-match-n pixel text-[7px]" ] [ text ("G" ++ String.fromInt g.number) ]
                , if result == Nothing then
                    span [ class "bg-match-live font-bold flex-1 text-center" ] [ text "In play" ]

                  else
                    div [ class "bg-match-cells" ] (List.map cell record.players)
                , span [ class "bg-match-analysis inline-flex items-center justify-center", attribute "aria-hidden" "true" ]
                    [ if g.number == model.game then
                        -- the game on the board
                        span [ class "bg-match-here" ] []

                      else
                        span [ class "hero-magnifying-glass w-4 h-4" ] []
                    ]
                ]
    in
    div [ class "fixed inset-0 z-40 flex items-end sm:items-center justify-center p-3", id "bg-match-sheet" ]
        [ div [ class "absolute inset-0", style "background" "rgba(35, 36, 58, 0.55)", onClick ToggleMatch ] []
        , div [ class "bg-match relative w-full max-w-md flex flex-col min-h-0" ]
            [ div [ class "bg-match-head" ]
                [ span [ class "pixel text-[8px]", style "color" "var(--pencil)" ] [ text heading ]
                , button [ class "bg-match-close", id "bg-match-close", attribute "aria-label" "Close", onClick ToggleMatch ] [ text "✕" ]
                ]
            , div [ class "bg-match-cols bg-match-row" ]
                [ span [ class "bg-match-n" ] []
                , div [ class "bg-match-cells" ] (List.map column record.players)
                , span [ class "bg-match-analysis-gap" ] []
                ]
            , div [ class "bg-match-list" ] (liveRow ++ (record.games |> List.filter (\g -> resultOf g /= Nothing) |> List.reverse |> List.map row))
            ]
        ]



-- THE CONTROLS


viewControls : Model -> Record -> Game -> Html Msg
viewControls model record game =
    let
        last =
            Replay.lastStep game

        unless off msg =
            if off then
                Nothing

            else
                Just msg
    in
    -- The step and the last step ride on the row for the smokes to read;
    -- the page itself says nothing about them.
    div [ class "rp-controls-wrap flex flex-col items-center gap-1", attribute "data-step" (String.fromInt model.step), attribute "data-last" (String.fromInt last) ]
        [ Ui.Scrub.row { id = "rp-controls", stale = False }
            { first = ( "rp-first", unless (model.step == 0) First )
            , back = ( "rp-prev", unless (model.step == 0) Prev )
            , forward = ( "rp-next", unless (model.step >= last) Next )
            , last = ( "rp-last", unless (model.step >= last) Last )
            }
            ((if List.length record.games > 1 then
                [ Ui.Scrub.plate { id = "rp-match", label = "The match: pick a game", icon = "hero-bars-3", onPress = Just ToggleMatch } ]

              else
                []
             )
                ++ [ Ui.Scrub.plate
                        { id = "rp-flip"
                        , label = "Turn the board around (" ++ (nameOf record (facing model record) |> String.toUpper) ++ " at the bottom)"
                        , icon = "hero-arrows-up-down"
                        , onPress = Just Flipped
                        }
                   ]
            )
        ]



-- THE NOTE: WHAT THIS STEP WAS, AND WHAT THE ENGINE THINKS OF IT


viewNote : Model -> Record -> Game -> Html Msg
viewNote model record game =
    let
        name =
            Replay.playerNamed record

        swatch id_ =
            div [ class ("swatch " ++ colorOf record id_) ] []

        analysis =
            currentReview model

        review =
            analysis |> Maybe.andThen .review

        notes =
            if model.step > 0 then
                notesAt model (model.step - 1)

            else
                []

        what =
            case Replay.entryAt game model.step of
                -- The start: the game's name alone, large, in the middle of
                -- the note's box.
                Nothing ->
                    div [ class "rp-what rp-what-start" ] [ span [ class "pixel text-base sm:text-lg" ] [ text ("GAME " ++ String.fromInt game.number) ] ]

                -- A turn: the tabs are the top of the note, and the board
                -- says whose roll and what was played; nothing to repeat.
                Just (TurnEntry _) ->
                    text ""

                Just (DoubleEntry d) ->
                    div [ class "rp-what" ] [ swatch d.player, span [ class "font-bold" ] [ text (name d.player ++ " doubles to " ++ String.fromInt d.value) ] ]

                Just (TakeEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " takes") ] ]

                Just (DropEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " passes") ] ]

                Just (ResignEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " resigns") ] ]

                -- The end: who won and by how much, large and centred like
                -- the start, the score it leaves beneath.
                Just (ResultEntry r) ->
                    div [ class "rp-what rp-what-start" ]
                        [ span [ class "pixel text-base sm:text-lg" ] [ text (String.toUpper (name r.winner) ++ " WINS +" ++ String.fromInt r.points) ] ]
    in
    div [ class "rp-note", id "rp-note" ]
        (what
            :: viewNotes model record game notes
            ++ [ viewAnalysisState model game analysis ]
        )


{-| A step's verdicts. One is simply shown; two (the cube that could have
been turned, and the move played) are tabs, open on the one that was a
mistake, else on the move.
-}
viewNotes : Model -> Record -> Game -> List Annotation -> List (Html Msg)
viewNotes model record game notes =
    case ( Replay.entryAt game model.step, notes ) of
        ( _, [] ) ->
            []

        -- A turn: the move on the left, the cube on the right, always both,
        -- as the panel below has its two tabs.
        ( Just (TurnEntry t), _ ) ->
            let
                open =
                    model.noteTab |> Maybe.withDefault MoveTab

                moveNote =
                    notes
                        |> List.filter
                            (\n ->
                                case n of
                                    MoveNote _ _ ->
                                        True

                                    _ ->
                                        False
                            )
                        |> List.head

                cubeNote =
                    notes
                        |> List.filter
                            (\n ->
                                case n of
                                    NoDoubleNote _ _ ->
                                        True

                                    _ ->
                                        False
                            )
                        |> List.head

                tab which label =
                    button
                        [ classList [ ( "rp-note-tab pixel text-[8px]", True ), ( "is-on", which == open ) ]
                        , id
                            (case which of
                                MoveTab ->
                                    "rp-note-move"

                                CubeTab ->
                                    "rp-note-cube"
                            )
                        , onClick (PickNote which)
                        ]
                        [ text label ]
            in
            [ div [ class "rp-note-tabs", id "rp-note-tabs" ]
                [ tab MoveTab "MOVE", tab CubeTab "CUBE" ]
            , case open of
                MoveTab ->
                    moveNote |> Maybe.map (viewAnnotation model record) |> Maybe.withDefault (text "")

                CubeTab ->
                    case cubeNote of
                        Just n ->
                            viewAnnotation model record n

                        Nothing ->
                            div [ class "rp-words rp-no-cube" ] [ text (noCubeReason model record game t.player) ]
            ]

        -- A double, a take, a pass: the one verdict it is.
        ( _, one :: _ ) ->
            [ viewAnnotation model record one ]


{-| Why there was no double to consider before this roll.
-}
noCubeReason : Model -> Record -> Game -> String -> String
noCubeReason model record game mover =
    let
        before =
            Replay.stillAt record game (model.step - 1)

        opp =
            record.players
                |> List.filter (\p -> p.id /= mover)
                |> List.head
                |> Maybe.map (.id >> Replay.playerNamed record)
                |> Maybe.withDefault "The other side"
    in
    if not record.cube then
        "This game is played without the cube."

    else if model.step == 1 then
        "Nobody can double before the opening roll: the dice decide who moves first."

    else if before.position.cube.owner /= Nothing && before.position.cube.owner /= Just mover then
        opp ++ " holds the cube at " ++ String.fromInt before.position.cube.value ++ ": only they can turn it."

    else
        "No double could be offered here."


viewAnnotation : Model -> Record -> Annotation -> Html Msg
viewAnnotation model record note =
    let
        name =
            Replay.playerNamed record

        other id_ =
            record.players
                |> List.filter (\p -> p.id /= id_)
                |> List.head
                |> Maybe.map (.id >> Replay.playerNamed record)
                |> Maybe.withDefault "the other side"
    in
    case note of
        MoveNote turn move ->
            case move of
                Danced ->
                    div [ class "rp-verdict" ] [ span [ style "color" "var(--pencil)" ] [ text "No legal move: nothing to grade." ], luckOf turn ]

                Moved m ->
                    div [ class "rp-verdict-block" ]
                        [ div [ class "rp-verdict" ]
                            [ gradeTag m.grade
                            , if m.forced then
                                span [ style "color" "var(--pencil)" ] [ text "Forced" ]

                              else if m.grade == "best" then
                                span [ style "color" "var(--pencil)" ] [ text "The engine's choice" ]

                              else
                                lost m.equityLost
                            , luckOf turn
                            ]
                        , if m.forced then
                            text ""

                          else
                            moveInWords (name turn.player) m
                        , if m.forced || List.length m.top <= 1 then
                            text ""

                          else
                            viewCandidates model m
                        ]

        DoubleNote turn cube ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ verdictTag cube.doubler
                    , span []
                        [ text
                            (case cube.doubler.mistake of
                                Just mistake ->
                                    Replay.mistakeLabel mistake

                                Nothing ->
                                    "Double"
                            )
                        ]
                    , lost cube.doubler.equityLost
                    ]
                , inWords (doubleInWords (name turn.player) (other turn.player) cube)
                , cubeChances (name turn.player) cube
                , cubeLine cube
                ]

        AnswerNote turn cube verdict ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ verdictTag verdict
                    , span []
                        [ text
                            (case ( verdict.mistake, cube.response ) of
                                ( Just mistake, _ ) ->
                                    Replay.mistakeLabel mistake

                                ( Nothing, Just Replay.Pass ) ->
                                    "Pass"

                                ( Nothing, _ ) ->
                                    "Take"
                            )
                        ]
                    , lost verdict.equityLost
                    ]
                , inWords (answerInWords (other turn.player) cube verdict)
                , cubeChances (name turn.player) cube
                , cubeLine cube
                ]

        NoDoubleNote turn cube ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ verdictTag cube.doubler
                    , span []
                        [ text
                            (case cube.doubler.mistake of
                                Just mistake ->
                                    Replay.mistakeLabel mistake

                                Nothing ->
                                    "No double"
                            )
                        ]
                    , lost cube.doubler.equityLost
                    ]
                , inWords (noDoubleInWords (name turn.player) (other turn.player) cube)
                , cubeChances (name turn.player) cube
                , cubeLine cube
                ]


{-| The roll's luck, quietly: how much the dice gave (or took) against an
average roll, in equity.
-}
luckOf : TurnReview -> Html msg
luckOf turn =
    case turn.luck of
        Just luck ->
            span [ class "rp-luck tabular-nums", Html.Attributes.title "Luck: what this roll was worth against an average one" ]
                [ text ("luck " ++ Replay.formatLuck luck) ]

        Nothing ->
            text ""


{-| The engine's top moves: tap one to see the position it leaves; the
played move is marked. The first is the engine's best.
-}
viewCandidates : Model -> { a | top : List Candidate, played : Candidate } -> Html Msg
viewCandidates model m =
    let
        -- Five lines: the engine's top five, or, when the move played was
        -- not among them, its top four and then the move played.
        shown =
            if List.length m.top > 5 then
                List.take 4 m.top ++ List.filter .played (List.drop 4 m.top)

            else
                m.top
    in
    div [ class "rp-top" ]
        (div [ class "rp-top-head" ]
            [ span [] []
            , span [] [ text "move" ]
            , span [ class "rp-col-eq" ] [ text "eq" ]
            , span [ class "rp-col", Html.Attributes.title "How often this move wins" ] [ text "win" ]
            , span [ class "rp-col", Html.Attributes.title "How often it wins a gammon" ] [ text "gam+" ]
            , span [ class "rp-col", Html.Attributes.title "How often it gets gammoned" ] [ text "gam−" ]
            ]
            :: (shown
                    |> List.map
                (\c ->
                    let
                        on_ =
                            case model.showing of
                                Proposed rank ->
                                    rank == c.rank

                                Played ->
                                    c.played

                                Before ->
                                    False
                    in
                    button
                        [ classList [ ( "rp-cand", True ), ( "is-on", on_ ), ( "is-played", c.played ) ]
                        , attribute "data-rank" (String.fromInt c.rank)
                        , disabled (c.position == Nothing && not c.played)
                        , onClick
                            (if c.played then
                                Show Played

                             else if on_ then
                                Show Played

                             else
                                Show (Proposed c.rank)
                            )
                        , Html.Attributes.title
                            ((if c.played then
                                "The move played"

                              else
                                "Show this move on the board"
                             )
                                ++ (case c.probs of
                                        Just p ->
                                            " · backgammons " ++ Replay.formatPercent p.backgammonWin ++ " for, " ++ Replay.formatPercent p.backgammonLoss ++ " against"

                                        Nothing ->
                                            ""
                                   )
                            )
                        ]
                        ([ span [ class "rp-rank tabular-nums" ] [ text (String.fromInt c.rank ++ ".") ]
                         , span
                            [ classList
                                [ ( "rp-cand-move", True )

                                -- a long notation (doubles, hits) steps the
                                -- type down rather than taking a second line
                                , ( "is-long", String.length c.notation > 10 )
                                , ( "is-longer", String.length c.notation > 15 )
                                ]
                            ]
                            [ text c.notation ]
                         , span [ class "rp-cand-lost rp-col-eq tabular-nums" ]
                            [ text
                                (if c.equityLost > 0 then
                                    "−" ++ Replay.formatEquity c.equityLost

                                 else
                                    signed c.equity
                                )
                            ]
                         ]
                            ++ chanceCells c.probs
                        )
                )
           )
        )


{-| Where this game's analysis stands, when it is not simply done.
-}
viewAnalysisState : Model -> Game -> Maybe GameReview -> Html Msg
viewAnalysisState model game analysis =
    let
        line cls content =
            div [ class ("rp-state " ++ cls), id "rp-analysis-state" ] content
    in
    case analysis of
        Nothing ->
            if model.reviewsError then
                line "is-quiet" [ text "The analysis is out of reach right now; trying again." ]

            else if model.index == Nothing then
                line "is-quiet" [ text "Loading the analysis…" ]

            else
                text ""

        Just g ->
            case ( g.status, g.review ) of
                ( Pending, _ ) ->
                    if not (seated model) then
                        -- Nobody started this one: an analysis is engine
                        -- time, and only a player's own visit spends it.
                        line "is-quiet" [ text ("Game " ++ String.fromInt game.number ++ " has not been analysed yet.") ]

                    else if model.polls >= maxPolls then
                        line "is-quiet" [ text "Still being analysed. Reload the page to check again." ]

                    else
                        line "is-pending"
                            [ span [] [ text ("Analysing game " ++ String.fromInt game.number ++ " at 4-ply… this can take a few minutes") ]
                            , span [ class "rp-progress" ] [ span [] [] ]
                            ]

                ( Failed, _ ) ->
                    line "is-failed"
                        [ span [] [ text ("The analysis of game " ++ String.fromInt game.number ++ " failed.") ]
                        , button
                            [ class "btn-arcade plain compact pixel text-[7px] px-2 py-1"
                            , id "rp-retry"
                            , disabled (List.member game.number model.retrying || not (seated model))
                            , onClick (Retry game.number)
                            ]
                            [ text
                                (if List.member game.number model.retrying then
                                    "ASKING…"

                                 else
                                    "TRY AGAIN"
                                )
                            ]
                        ]

                ( Empty, _ ) ->
                    line "is-quiet" [ text "Nothing to analyse: no turn was completed." ]

                ( Playing, _ ) ->
                    line "is-quiet" [ text "This game is still being played; it is analysed when it ends." ]

                ( Done, Nothing ) ->
                    if List.member game.number model.analysisErrors then
                        line "is-quiet" [ text "The analysis is out of reach right now; reload the page to try again." ]

                    else
                        line "is-quiet" [ text "Loading the analysis…" ]

                _ ->
                    text ""



-- THE MOVE LIST


viewMoves : Model -> Record -> Game -> Html Msg
viewMoves model record game =
    let
        review =
            currentReview model |> Maybe.andThen .review

        line step content =
            div
                [ classList [ ( "rp-line", True ), ( "is-on", step == model.step ) ]
                , id (lineId step)
                , onClick (GoTo step)
                ]
                content

        entryLine index entry =
            let
                step =
                    index + 1

                tag =
                    review
                        |> Maybe.andThen (\r -> Replay.moveAt r index)
                        |> Maybe.andThen
                            (\( _, move ) ->
                                case move of
                                    Moved m ->
                                        if m.forced then
                                            Nothing

                                        else
                                            Just (listTag m.grade)

                                    Danced ->
                                        Nothing
                            )
                        |> Maybe.withDefault (text "")

                cubeTag =
                    notesAt model index
                        |> List.filterMap
                            (\a ->
                                case a of
                                    DoubleNote _ c ->
                                        c.doubler.mistake |> Maybe.map (\_ -> listTag c.doubler.grade)

                                    AnswerNote _ _ v ->
                                        v.mistake |> Maybe.map (\_ -> listTag v.grade)

                                    NoDoubleNote _ c ->
                                        c.doubler.mistake |> Maybe.map (\_ -> listTag c.doubler.grade)

                                    MoveNote _ _ ->
                                        Nothing
                            )
            in
            case entry of
                TurnEntry t ->
                    line step
                        ([ div [ class ("swatch " ++ colorOf record t.player) ] []
                         , span [ class "rp-dice" ] [ text (t.dice |> List.map String.fromInt |> String.join "") ]
                         , span [ class "rp-moves" ]
                            [ text
                                (if t.moves == [] then
                                    "(no play)"

                                 else
                                    String.join " " t.moves
                                )
                            ]
                         , tag
                         ]
                            ++ cubeTag
                        )

                DoubleEntry d ->
                    line step ([ div [ class ("swatch " ++ colorOf record d.player) ] [], span [ class "rp-moves italic" ] [ text ("Doubles to " ++ String.fromInt d.value) ] ] ++ cubeTag)

                TakeEntry p ->
                    line step ([ div [ class ("swatch " ++ colorOf record p) ] [], span [ class "rp-moves italic" ] [ text "Takes" ] ] ++ cubeTag)

                DropEntry p ->
                    line step ([ div [ class ("swatch " ++ colorOf record p) ] [], span [ class "rp-moves italic" ] [ text "Passes" ] ] ++ cubeTag)

                ResignEntry p ->
                    line step [ div [ class ("swatch " ++ colorOf record p) ] [], span [ class "rp-moves italic" ] [ text "Resigns" ] ]

                ResultEntry r ->
                    line step
                        [ span [ class "rp-moves font-bold" ] [ text (Replay.playerNamed record r.winner ++ resultWords r.result ++ " · " ++ pointsText r.points) ]
                        , span [ class "tabular-nums font-bold" ] [ text (scoreText record r.scores) ]
                        ]
    in
    div [ class "rp-list", id "rp-list" ]
        (line 0 [ span [ class "rp-moves", style "color" "var(--pencil)" ] [ text "Start" ] ]
            :: List.indexedMap entryLine game.entries
        )


{-| A grade as the list marks it: the symbols annotators use, `?!` for
doubtful, `?` for bad, `??` for very bad; a best or fine move is unmarked
beyond a tick.
-}
listTag : String -> Html msg
listTag grade =
    span [ class ("rp-mark g-" ++ grade), attribute "data-grade" grade, Html.Attributes.title (Replay.gradeLabel grade) ]
        [ text
            (case grade of
                "best" ->
                    "✓"

                "ok" ->
                    "·"

                "doubtful" ->
                    "?!"

                "bad" ->
                    "?"

                "very_bad" ->
                    "??"

                _ ->
                    ""
            )
        ]



-- THE SUMMARY


viewSummary : Model -> Record -> Game -> Html Msg
viewSummary model record game =
    let
        analysis =
            currentReview model
    in
    div [ class "rp-summary", id "rp-summary" ]
        (case analysis |> Maybe.andThen .review of
            Just review ->
                viewPractice model game
                    :: (review.players
                    |> List.map
                        (\t ->
                            let
                                count name =
                                    t.grades |> List.filter (\( g, _ ) -> g == name) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault 0

                                cubeErrors =
                                    t.mistakes |> List.map Tuple.second |> List.sum
                            in
                            div [ class "rp-player" ]
                                [ div [ class "rp-player-head" ]
                                    [ div [ class ("swatch " ++ t.color) ] []
                                    , span [ class "font-bold truncate" ]
                                        -- a report built before the seat's
                                        -- account was named keeps that name;
                                        -- the record has the current one
                                        [ text (Replay.playerNamed record t.playerId) ]
                                    , span [ class "rp-pr tabular-nums", Html.Attributes.title "Performance Rating" ]
                                        [ span [ class "pixel text-[7px]" ] [ text "PR " ], text (Replay.formatPr t.pr) ]
                                    ]
                                , div [ class "rp-counts tabular-nums" ]
                                    [ countChip "doubtful" "Doubtful" (count "doubtful")
                                    , countChip "bad" "Bad" (count "bad")
                                    , countChip "very_bad" "Very bad" (count "very_bad")
                                    , span [ class "rp-count-chip" ] [ text ("Cube errors " ++ String.fromInt cubeErrors) ]
                                    ]
                                , div [ class "rp-counts tabular-nums", style "color" "var(--pencil)" ]
                                    [ text
                                        (String.fromInt t.moveDecisions
                                            ++ " moves, "
                                            ++ String.fromInt t.cubeDecisions
                                            ++ " cube decisions · luck "
                                            ++ Replay.formatLuck t.luck
                                        )
                                    ]
                                , viewMistakes model review t
                                ]
                        )
                   )

            -- where the analysis stands is the note's to say, above the tabs
            Nothing ->
                [ div [ class "rp-explain" ] [ text "Each player's PR, errors and luck appear here once the game is analysed." ] ]
        )


{-| PRACTICE THIS GAME'S N MISTAKES, for a reader who holds a seat here,
once this game's mistakes are counted (`wantMistakes`): the door to a run
of them. Nothing for a stranger, nothing while they are on their way, and
nothing for a game with none -- each player's list already says so.
-}
viewPractice : Model -> Game -> Html Msg
viewPractice model game =
    case Dict.get game.number model.mistakes of
        Just [] ->
            text ""

        Just ids ->
            div [ class "rp-practice" ]
                [ button
                    [ class "btn-arcade compact pixel text-[7px] px-3 py-2 yellow w-full"
                    , id "practice-game"
                    , attribute "data-game" (String.fromInt game.number)
                    , attribute "data-count" (String.fromInt (List.length ids))
                    , onClick (PracticeGame game.number)
                    ]
                    [ text
                        ("PRACTICE THIS GAME'S "
                            ++ String.fromInt (List.length ids)
                            ++ (if List.length ids == 1 then
                                    " MISTAKE"

                                else
                                    " MISTAKES"
                               )
                        )
                    ]
                ]

        Nothing ->
            text ""


{-| What cost this player: every doubtful, bad and very bad move and every
cube error, worst first, each a door that puts the step on the board.
-}
viewMistakes : Model -> Review -> Replay.Totals -> Html Msg
viewMistakes model review totals =
    let
        withCube =
            case model.record of
                Loaded record ->
                    record.cube

                _ ->
                    True

        graded grade =
            List.member grade [ "doubtful", "bad", "very_bad" ]

        dice t =
            case t.dice of
                Just ( a, b ) ->
                    String.fromInt a ++ String.fromInt b

                Nothing ->
                    ""

        moveRows =
            review.turns
                |> List.filterMap
                    (\t ->
                        case ( t.player == totals.playerId, t.move, t.entry ) of
                            ( True, Just (Moved m), Just entry ) ->
                                if graded m.grade then
                                    Just { step = entry + 1, turn = t.number, what = dice t ++ ": " ++ m.played.notation, grade = m.grade, lost = m.equityLost }

                                else
                                    Nothing

                            _ ->
                                Nothing
                    )

        cubeRows =
            (if withCube then
                review.turns

             else
                []
            )
                |> List.concatMap
                    (\t ->
                        case t.cube of
                            Just c ->
                                List.filterMap identity
                                    [ if c.doubler.seat == totals.seat && c.doubler.mistake /= Nothing && graded c.doubler.grade then
                                        -- a double has its own line; a missed double is
                                        -- marked on the move that was played instead
                                        (case t.doubleEntry of
                                            Just e ->
                                                Just e

                                            Nothing ->
                                                t.entry
                                        )
                                            |> Maybe.map (\e -> { step = e + 1, turn = t.number, what = Replay.mistakeLabel (Maybe.withDefault "" c.doubler.mistake), grade = c.doubler.grade, lost = c.doubler.equityLost })

                                      else
                                        Nothing
                                    , case c.taker of
                                        Just taker ->
                                            if taker.seat == totals.seat && taker.mistake /= Nothing && graded taker.grade then
                                                t.answerEntry
                                                    |> Maybe.map (\e -> { step = e + 1, turn = t.number, what = Replay.mistakeLabel (Maybe.withDefault "" taker.mistake), grade = taker.grade, lost = taker.equityLost })

                                            else
                                                Nothing

                                        Nothing ->
                                            Nothing
                                    ]

                            Nothing ->
                                []
                    )

        rows =
            (moveRows ++ cubeRows) |> List.sortBy (\r -> negate r.lost)
    in
    if rows == [] then
        div [ class "rp-mistakes-none" ] [ text "No mistakes worth a mark." ]

    else
        div [ class "rp-mistakes", attribute "data-player" totals.playerId ]
            (rows
                |> List.map
                    (\r ->
                        button
                            [ classList [ ( "rp-mistake", True ), ( "is-on", model.step == r.step ) ]
                            , attribute "data-step" (String.fromInt r.step)
                            , onClick (GoTo r.step)
                            ]
                            [ listTag r.grade
                            , span [ class "rp-mistake-turn pixel text-[7px]" ] [ text ("T" ++ String.fromInt r.turn) ]
                            , span [ class "rp-mistake-what truncate" ] [ text r.what ]
                            , span [ class "rp-lost tabular-nums" ] [ text ("−" ++ Replay.formatEquity r.lost) ]
                            ]
                    )
            )


countChip : String -> String -> Int -> Html msg
countChip grade label n =
    span [ classList [ ( "rp-count-chip", True ), ( "g-" ++ grade, n > 0 ) ] ] [ text (label ++ " " ++ String.fromInt n) ]


tabButton : Model -> Tab -> String -> Html Msg
tabButton model tab label =
    button
        [ classList [ ( "rp-tab pixel text-[8px]", True ), ( "is-on", model.tab == tab ) ]
        , onClick (PickTab tab)
        ]
        [ text label ]



-- WORDS


colorOf : Record -> String -> String
colorOf record id_ =
    record.players |> List.filter (\p -> p.id == id_) |> List.head |> Maybe.map .color |> Maybe.withDefault "white"


resultWords : String -> String
resultWords result =
    case result of
        "gammon" ->
            " wins a gammon"

        "backgammon" ->
            " wins a backgammon"

        _ ->
            " wins"


pointsText : Int -> String
pointsText points =
    if points == 1 then
        "1 pt"

    else
        String.fromInt points ++ " pts"
