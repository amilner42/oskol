module Page.Replay exposing
    ( Loadable(..)
    , Model
    , Msg(..)
    , Showing(..)
    , Tab(..)
    , init
    , keyDecoder
    , pollEveryMs
    , polling
    , subscriptions
    , title
    , update
    , view
    )

{-| `/:slug/:id/replay` — a room's games played again, one line of the
record at a time, with the analysis engine's verdicts on each.

The page reads two things and decides nothing about backgammon: the room's
whole record (`/record`, on the seat's token: every game, every line, the
position after every turn) and the engine's reviews (`/reviews`: per turn
the grade of the move played, the best move and the position it leaves,
the cube verdicts, the luck; per player the PR). Both are drawn as they
come. The server names which record line each verdict is about.

The replay is usable the moment the record arrives. Analysis takes a while
(a few minutes a game at 4-ply), so a game still being analysed says so, the
page asks again every few seconds while anything is pending, and the
grades fill in where the viewer is -- the game, the step and the move on
the board stay put. A game whose analysis failed offers to try again.

Stepping: the buttons under the board, the arrow keys (Home and End for
the first and last line), a swipe across the board, or a tap on a line of
the move list.

-}

import Api
import Browser.Dom
import Browser.Events
import Dict
import Games.Backgammon.Replay as Replay exposing (Annotation(..), Candidate, Entry(..), Game, GameReview, MoveReview(..), Record, Reviews, Status(..), TurnReview)
import Games.Backgammon.View as Board
import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled, href, id, style)
import Html.Events exposing (on, onClick)
import Json.Decode as D
import Json.Encode as E
import Process
import Route
import Session exposing (Session)
import Task
import Time
import Url



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


type Tab
    = MovesTab
    | SummaryTab


type alias Model =
    { session : Session
    , slug : String
    , gameId : String
    , token : Maybe String
    , wanted : Maybe Int -- the game the link asked for
    , record : Loadable Record
    , reviews : Maybe Reviews
    , reviewsError : Bool -- the last ask for the reviews did not get an answer
    , game : Int -- the game being replayed, by number
    , step : Int -- 0 is the start; n is the board after the game's nth line
    , showing : Showing
    , tab : Tab
    , touch : Maybe ( Float, Float ) -- where a touch on the board began
    , polls : Int -- asks made while something was pending
    , retrying : List Int -- games whose retry is on its way
    }


{-| How often a page with pending analysis asks again.
-}
pollEveryMs : Float
pollEveryMs =
    3000


{-| A page left open on an analysis that never lands stops asking after
this many (twenty minutes, as long as the server waits on the engine); a
reload starts again.
-}
maxPolls : Int
maxPolls =
    400


init :
    Session
    -> { slug : String, gameId : String, token : Maybe String, game : Maybe Int }
    -> ( Model, Cmd Msg )
init session config =
    let
        model =
            { session = session
            , slug = config.slug
            , gameId = config.gameId
            , token = config.token
            , wanted = config.game
            , record = Loading
            , reviews = Nothing
            , reviewsError = False
            , game = Maybe.withDefault 1 config.game
            , step = 0
            , showing = Played
            , tab = MovesTab
            , touch = Nothing
            , polls = 0
            , retrying = []
            }
    in
    case config.token of
        Just token ->
            ( model
            , Cmd.batch
                [ Api.get session (base model ++ "/record?t=" ++ Url.percentEncode token) Replay.recordDecoder GotRecord
                , fetchReviews model
                ]
            )

        Nothing ->
            ( { model | record = Unavailable "A replay opens from a player's own link to the game." }, Cmd.none )


base : Model -> String
base model =
    "/papi/games/" ++ model.slug ++ "/rooms/" ++ model.gameId


fetchReviews : Model -> Cmd Msg
fetchReviews model =
    Api.get model.session (base model ++ "/reviews") Replay.reviewsDecoder GotReviews


title : Model -> String
title model =
    case model.record of
        Loaded record ->
            "Replay · " ++ (record.players |> List.map .name |> String.join " vs ")

        _ ->
            "Replay"



-- UPDATE


type Msg
    = GotRecord (Result Api.Error Record)
    | GotReviews (Result Api.Error Reviews)
    | Poll
    | PickGame Int
    | GoTo Int
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
    | NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
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
            ( { model
                | record = Loaded record
                , game = chosen |> Maybe.map .number |> Maybe.withDefault 1
                , step = 0
              }
            , Cmd.none
            )

        GotRecord (Err err) ->
            ( { model | record = Unavailable (Api.errorMessage err) }, Cmd.none )

        GotReviews (Ok reviews) ->
            -- Replaced whole, whatever the viewer is looking at: the game,
            -- the step and the move on the board are the model's, not the
            -- review's, so nothing moves.
            ( { model | reviews = Just reviews, reviewsError = False, retrying = [] }, follow model.step )

        GotReviews (Err _) ->
            ( { model | reviewsError = True, retrying = [] }, Cmd.none )

        Poll ->
            ( { model | polls = model.polls + 1 }, fetchReviews model )

        PickGame number ->
            if number == model.game then
                ( model, Cmd.none )

            else
                ( { model | game = number, step = 0, showing = Played }, follow 0 )

        GoTo step ->
            goTo step model

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
            case model.token of
                Just token ->
                    ( { model | retrying = number :: model.retrying }
                    , Api.post model.session
                        (base model ++ "/reviews/retry")
                        (E.object [ ( "t", E.string token ), ( "game_number", E.int number ) ])
                        Replay.reviewsDecoder
                        GotReviews
                    )

                Nothing ->
                    ( model, Cmd.none )

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
        ( { model | step = clamped, showing = Played }, follow clamped )


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
    model.reviews |> Maybe.andThen (Replay.gameReview model.game)


{-| Ask again while some game's analysis is still on its way, or while the
reviews have not answered yet -- and never past `maxPolls`.
-}
polling : Model -> Bool
polling model =
    model.polls
        < maxPolls
        && (case model.reviews of
                Just reviews ->
                    Replay.wantsPolling reviews || model.reviewsError

                Nothing ->
                    model.reviewsError
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
        [ Html.a
            [ href (Route.href (Route.play model.slug model.gameId model.token))
            , class "rp-back pixel text-[8px]"
            , id "rp-back"
            , Html.Attributes.title "Back to the table"
            ]
            [ text "◀ TABLE" ]
        , span [ class "pixel text-[9px] sm:text-xs whitespace-nowrap" ] [ text "REPLAY" ]
        , case record of
            Just r ->
                span [ class "rp-tag pixel text-[7px] sm:text-[8px] truncate" ]
                    [ text (matchLabel r ++ " · " ++ (r.players |> List.map (.name >> String.toUpper) |> String.join " v ")) ]

            Nothing ->
                text ""
        ]


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
            proposed |> Maybe.andThen (Replay.stillForCandidate still) |> Maybe.withDefault still

        scores =
            scoresBefore record game

        board =
            Board.viewStill NoOp
                { players = record.players
                , viewer = record.you
                , scores = scores
                , cube = record.cube
                , theme = theme model
                , key = model.game * 1000 + model.step
                , position = shown.position
                , mover = shown.mover
                , dice = shown.dice
                , picked = shown.picked
                , landed = shown.landed
                , offer = shown.offer |> Maybe.map .from
                }
    in
    [ viewHead model (Just record)
    , viewPicker model record
    , div [ class "rp-main" ]
        [ div [ class "rp-stage" ]
            [ div
                [ classList [ ( "rp-board", True ), ( "is-proposed", proposed /= Nothing ) ]
                , id "rp-board"
                , on "touchstart" (touchAt TouchStarted)
                , on "touchend" (touchAt TouchEnded)
                ]
                [ board
                , case proposed of
                    Just c ->
                        span [ class "rp-proposed pixel text-[7px]" ] [ text ("ENGINE'S #" ++ String.fromInt c.rank ++ " · " ++ c.notation) ]

                    Nothing ->
                        text ""
                ]
            , viewControls model game
            ]
        , div [ class "rp-side" ]
            [ viewNote model record game
            , div [ class "rp-tabs" ]
                [ tabButton model MovesTab "MOVES"
                , tabButton model SummaryTab "ANALYSIS"
                ]
            , case model.tab of
                MovesTab ->
                    viewMoves model record game

                SummaryTab ->
                    viewSummary model record game
            ]
        ]
    ]


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


viewPicker : Model -> Record -> Html Msg
viewPicker model record =
    if List.length record.games <= 1 then
        text ""

    else
        div [ class "rp-games", id "rp-games" ]
            (record.games
                |> List.map
                    (\g ->
                        let
                            status =
                                model.reviews |> Maybe.andThen (Replay.gameReview g.number) |> Maybe.map .status

                            label =
                                case resultOf g of
                                    Just r ->
                                        Replay.playerNamed record r.winner ++ " +" ++ String.fromInt r.points ++ " · " ++ scoreText record r.scores

                                    Nothing ->
                                        "in play"
                        in
                        button
                            [ classList [ ( "rp-game", True ), ( "is-on", g.number == model.game ) ]
                            , attribute "data-game" (String.fromInt g.number)
                            , onClick (PickGame g.number)
                            ]
                            [ span [ class "pixel text-[7px]" ] [ text "G", span [ class "hidden sm:inline" ] [ text "AME " ], text (String.fromInt g.number) ]
                            , span [ class "rp-game-result" ] [ text label ]
                            , case status of
                                Just Pending ->
                                    span [ class "rp-dot pending", Html.Attributes.title "Being analysed" ] []

                                Just Failed ->
                                    span [ class "rp-dot failed", Html.Attributes.title "Analysis failed" ] []

                                _ ->
                                    text ""
                            ]
                    )
            )



-- THE CONTROLS


viewControls : Model -> Game -> Html Msg
viewControls model game =
    let
        last =
            Replay.lastStep game

        control label name msg off =
            button
                [ class "rp-step btn-arcade plain pixel"
                , id ("rp-" ++ name)
                , Html.Attributes.title name
                , attribute "aria-label" name
                , disabled off
                , onClick msg
                ]
                [ text label ]
    in
    div [ class "rp-controls" ]
        [ control "|◀" "first" First (model.step == 0)
        , control "◀" "prev" Prev (model.step == 0)
        , span [ class "rp-count pixel text-[8px]", id "rp-count" ]
            [ text
                (if model.step == 0 then
                    "START"

                 else
                    String.fromInt model.step ++ " / " ++ String.fromInt last
                )
            ]
        , control "▶" "next" Next (model.step >= last)
        , control "▶|" "last" Last (model.step >= last)
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
            case ( review, model.step ) of
                ( Just r, step ) ->
                    if step > 0 then
                        Replay.annotationsAt r (step - 1)

                    else
                        []

                _ ->
                    []

        what =
            case Replay.entryAt game model.step of
                Nothing ->
                    div [ class "rp-what" ] [ span [ class "font-bold" ] [ text ("Game " ++ String.fromInt game.number ++ ": the opening position") ] ]

                Just (TurnEntry t) ->
                    div [ class "rp-what" ]
                        [ swatch t.player
                        , span [ class "font-bold truncate" ] [ text (name t.player) ]
                        , span [ class "rp-dice" ] [ text (t.dice |> List.map String.fromInt |> String.join "") ]
                        , span [ class "rp-moves" ]
                            [ text
                                (if t.moves == [] then
                                    "(no play)"

                                 else
                                    String.join " " t.moves
                                )
                            ]
                        ]

                Just (DoubleEntry d) ->
                    div [ class "rp-what" ] [ swatch d.player, span [ class "font-bold" ] [ text (name d.player ++ " doubles to " ++ String.fromInt d.value) ] ]

                Just (TakeEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " takes") ] ]

                Just (DropEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " passes") ] ]

                Just (ResignEntry p) ->
                    div [ class "rp-what" ] [ swatch p, span [ class "font-bold" ] [ text (name p ++ " resigns") ] ]

                Just (ResultEntry r) ->
                    div [ class "rp-what" ]
                        [ swatch r.winner
                        , span [ class "font-bold" ] [ text (name r.winner ++ resultWords r.result ++ " · " ++ pointsText r.points) ]
                        , span [ class "ml-auto tabular-nums font-bold" ] [ text (scoreText record r.scores) ]
                        ]
    in
    div [ class "rp-note", id "rp-note" ]
        (what
            :: List.map (viewAnnotation model) notes
            ++ [ viewAnalysisState model game analysis ]
        )


viewAnnotation : Model -> Annotation -> Html Msg
viewAnnotation model note =
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
                                span [ class "rp-best" ]
                                    [ text "Best "
                                    , span [ class "font-bold" ] [ text m.best.notation ]
                                    , span [ class "rp-lost tabular-nums" ] [ text (" −" ++ Replay.formatEquity m.equityLost) ]
                                    ]
                            , luckOf turn
                            ]
                        , if m.forced || List.length m.top <= 1 then
                            text ""

                          else
                            viewCandidates model m
                        ]

        DoubleNote _ cube ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ gradeTag cube.doubler.grade
                    , span []
                        [ text
                            (case cube.doubler.mistake of
                                Just mistake ->
                                    Replay.mistakeLabel mistake

                                Nothing ->
                                    "Right to double"
                            )
                        ]
                    , lost cube.doubler.equityLost
                    ]
                , cubeLine cube
                ]

        AnswerNote _ cube verdict ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ gradeTag verdict.grade
                    , span []
                        [ text
                            (case ( verdict.mistake, cube.response ) of
                                ( Just mistake, _ ) ->
                                    Replay.mistakeLabel mistake

                                ( Nothing, Just "pass" ) ->
                                    "Right to pass"

                                ( Nothing, _ ) ->
                                    "Right to take"
                            )
                        ]
                    , lost verdict.equityLost
                    ]
                , cubeLine cube
                ]

        NoDoubleNote _ cube ->
            div [ class "rp-verdict-block" ]
                [ div [ class "rp-verdict" ]
                    [ gradeTag cube.doubler.grade
                    , span [] [ text ("Cube: " ++ (cube.doubler.mistake |> Maybe.map Replay.mistakeLabel |> Maybe.withDefault "no double")) ]
                    , lost cube.doubler.equityLost
                    ]
                , cubeLine cube
                ]


lost : Float -> Html msg
lost equity =
    if equity > 0 then
        span [ class "rp-lost tabular-nums" ] [ text ("−" ++ Replay.formatEquity equity) ]

    else
        text ""


{-| The engine's call on the cube and the three equities behind it.
-}
cubeLine : Replay.CubeReview -> Html msg
cubeLine cube =
    div [ class "rp-cube-line tabular-nums" ]
        [ text ("Engine: " ++ cube.optimal ++ " · ")
        , text ("ND " ++ signed cube.noDouble ++ " · D/T " ++ signed cube.doubleTake ++ " · D/P " ++ signed cube.doublePass)
        ]


signed : Float -> String
signed x =
    if x >= 0 then
        "+" ++ Replay.formatEquity x

    else
        "−" ++ Replay.formatEquity (abs x)


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
    div [ class "rp-top" ]
        (m.top
            |> List.map
                (\c ->
                    let
                        on_ =
                            case model.showing of
                                Proposed rank ->
                                    rank == c.rank

                                Played ->
                                    c.played
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
                            (if c.played then
                                "The move played"

                             else
                                "Show this move on the board"
                            )
                        ]
                        [ span [ class "rp-rank tabular-nums" ] [ text (String.fromInt c.rank ++ ".") ]
                        , span [ class "rp-cand-move" ] [ text c.notation ]
                        , if c.played then
                            span [ class "rp-played pixel text-[6px]" ] [ text "PLAYED" ]

                          else
                            text ""
                        , span [ class "rp-cand-lost tabular-nums" ]
                            [ text
                                (if c.equityLost > 0 then
                                    "−" ++ Replay.formatEquity c.equityLost

                                 else
                                    signed c.equity
                                )
                            ]
                        ]
                )
        )


gradeTag : String -> Html msg
gradeTag grade =
    span [ class ("rp-grade g-" ++ grade), attribute "data-grade" grade ] [ text (Replay.gradeLabel grade) ]


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

            else if model.reviews == Nothing then
                line "is-quiet" [ text "Loading the analysis…" ]

            else
                text ""

        Just g ->
            case ( g.status, g.review ) of
                ( Pending, _ ) ->
                    if model.polls >= maxPolls then
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
                            , disabled (List.member game.number model.retrying || model.token == Nothing)
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
                    review
                        |> Maybe.map (\r -> Replay.annotationsAt r index)
                        |> Maybe.withDefault []
                        |> List.filterMap
                            (\a ->
                                case a of
                                    DoubleNote _ c ->
                                        c.doubler.mistake |> Maybe.map (\_ -> listTag c.doubler.grade)

                                    AnswerNote _ _ v ->
                                        v.mistake |> Maybe.map (\_ -> listTag v.grade)

                                    NoDoubleNote _ c ->
                                        Just (listTag c.doubler.grade)

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
                (review.players
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
                                    , span [ class "font-bold truncate" ] [ text t.name ]
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
                                ]
                        )
                )
                    ++ [ case review.levels of
                            Just levels ->
                                div [ class "rp-level", id "rp-level" ] [ text ("Analysed at " ++ Replay.levelLabel levels) ]

                            Nothing ->
                                text ""
                       , div [ class "rp-explain" ]
                            [ text "PR (Performance Rating) is the equity a player gave up per decision they had to make, times 500: lower is better, and 0 is perfect play. Luck is what the dice gave, in the same units." ]
                       , viewAnalysisState model game analysis
                       ]

            Nothing ->
                [ viewAnalysisState model game analysis
                , div [ class "rp-explain" ] [ text "Each player's PR, errors and luck appear here once the game is analysed." ]
                ]
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
