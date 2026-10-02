module Main exposing (main)

{-| SPA shell: routing, page dispatch, and the chrome the landing pages sit
in (`Ui.Shell` — the OSKOL wordmark, the JOIN GAME prompt, the footer).

Three routes, and they are the server's three routes:

    /            Page.GameLanding "backgammon" — the home page, the board
    /:slug       Page.GameLanding — the invite a shared link opens
    /login/:token  Page.Login — what a mailed sign-in link opens
    /puzzles     Page.Puzzles — the practice home
    /puzzles/:id   Page.Puzzle — one position and its question
    /:slug/:id   Page.Play — the game, unchanged
    /:slug/:id/replay   Page.Replay — a game played again, with its analysis

A practice run -- the puzzles a session works through, one ANOTHER at a
time -- is kept here (`run`, a `Run.Run`) and not in the puzzle page,
because it has to outlive the page: every `pushUrl` to the next puzzle
builds that page afresh. The pages that start a run (the practice home, a
finished game's result card at the table, the signed-in home) hand the
shell the list (`StartRun ids`, which opens the first) and the shell notes
where it was started from (`next`) and what it is of (`Run.Source`); the
puzzle page reports each verdict (`Answered`), which the run keeps as its
score, and says when it wants the next (`WantsNext`): the shell opens it.
When the ids run out it asks the run's queue again and goes on (a run
never ends because a page of twenty did); only an empty answer ends it,
with the score and the way on (`Page.Puzzle.endRun`, then KEEP GOING or
PRACTICE ANYWAY once the shell has read where the deck stands).

The JOIN GAME prompt lives here rather than in a page because it is chrome:
six characters in, and out comes that room's ordinary invite link, which is
the same flow a shared link takes. Nothing about the room is revealed beyond
"a live game answers to this code".

-}

import Api.Decks
import Api.PracticeDecks as PracticeDecks
import Api
import Api.Auth as Auth
import Api.Catalog as Catalog
import Browser exposing (Document)
import Browser.Events
import Browser.Navigation as Nav
import Html exposing (Html)
import Html.Attributes
import Json.Decode as D
import Api.Practice exposing (Today)
import Games.Backgammon.Puzzle exposing (Verdict(..))
import Page.GameLanding
import Page.Home
import Page.Login
import Page.Play
import Page.Puzzle
import Page.Practice
import Page.Puzzles
import Page.Replay
import Route exposing (Route)
import Run
import Session exposing (Session)
import Process
import Task
import Ui.Loading as Loading
import Ui.Mistakes as Mistakes
import Ui.Notebook as Notebook
import Ui.Shell as Shell
import Url exposing (Url)


main : Program D.Value Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }


type alias Model =
    { key : Nav.Key
    , origin : String
    , session : Session
    , route : Maybe Route
    , page : Page
    -- What the page a mailed sign-in link opened carried (JSON text), on
    -- that page alone. The server read the token; it wrote nothing.
    , loginFlags : Maybe String

    -- The browser's timezone (an IANA name, or ""), for the practice home
    -- to tell the deck once.
    , tz : String

    -- The practice run in progress, if any: the puzzle ids in order, which
    -- one is open, the verdict on each answered so far, and where it was
    -- started from. The practice home, a result card and the replay start
    -- one; a puzzle opened from a link has no next.
    , run : Maybe Run.Run

    -- The day's ring, as the page that started the run was told it, and
    -- as this shell has counted it since: one more with every card
    -- answered for the first time in this run. An account's only.
    , today : Maybe Today

    -- How many runs this session has started: each run is numbered, and
    -- the shell's requests for one carry its number, so an answer that
    -- lands after another run has started is dropped (`Run.current`).
    , runs : Int
    , joinOpen : Bool
    , joinCode : String
    , joinError : Maybe String

    -- `/` is two pages and cannot say which until `/papi/me` answers, so
    -- until then -- and for at least `Loading.minMs` from the page starting
    -- to load, so it never flickers -- `/` is the loading bar. `bootMs` is
    -- how long the page had been loading when the app booted, which the
    -- bar's animation picks up from.
    , bootMs : Float
    , meKnown : Bool
    , minShown : Bool

    -- The bar every page wears (`Page.GameLanding.navBar`): one model for
    -- the whole session, so its live games, its sign-in, CREATE GAME and
    -- the board picker are the same wherever it is drawn.
    , bar : Page.GameLanding.Model
    }


type Page
    = NotFound
    | Login Page.Login.Model
    | GameLanding Page.GameLanding.Model
    | Home Page.Home.Model
    | Play Page.Play.Model
    | Replay Page.Replay.Model
    | Puzzle Page.Puzzle.Model
    | Puzzles Page.Puzzles.Model
    | Practice Page.Practice.Model


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GameLandingMsg Page.GameLanding.Msg
    | HomeMsg Page.Home.Msg
    | LoginMsg Page.Login.Msg
    | PlayMsg Page.Play.Msg
    | ReplayMsg Page.Replay.Msg
    | PuzzleMsg Page.Puzzle.Msg
    | PuzzlesMsg Page.Puzzles.Msg
    | PracticeMsg Page.Practice.Msg
    | OpenedJoin
    | ClosedJoin
    | JoinCodeInput String
    | JoinSubmitted
    | GotJoinCode (Result Api.Error Catalog.CodeMatch)
    | GotMe (Result Api.Error Session.Me)
    | BarMsg Page.GameLanding.Msg
    | MinShown
    | MeGivenUp
      -- the run's queue, asked again once its ids ran out
    | GotRefetch Int (Result Api.Error (List String))
      -- where the run's deck stands, for the end card's way on
    | GotStanding Int (Result Api.Error PracticeDecks.Catalog)
      -- the run's deck as it stands now, for the card that says today's set is done
    | GotCelebration Int (Result Api.Error PracticeDecks.Page)
      -- what KEEP GOING or PRACTICE ANYWAY handed over
    | GotOnward Int Page.Puzzle.Way (Result Api.Error (List String))
    | NoOp


init : D.Value -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        session =
            D.decodeValue Session.decoder flags
                |> Result.withDefault Session.empty

        ( model, cmd ) =
            routeTo url
                { key = key
                , origin = origin url
                , session = session
                , route = Nothing
                , page = NotFound
                , loginFlags =
                    D.decodeValue (D.field "login" (D.nullable D.string)) flags
                        |> Result.withDefault Nothing
                , tz =
                    D.decodeValue (D.field "tz" D.string) flags
                        |> Result.withDefault ""
                , run = Nothing
                , today = Nothing
                , runs = 0
                , joinOpen = False
                , joinCode = ""
                , joinError = Nothing
                , bootMs = bootMs
                , meKnown = False
                , minShown = False
                , bar = bar
                }

        -- CREATE GAME's model (it opens on a friend, as the dialog always
        -- has); the live games come with every page (`routeTo`).
        ( bar, barCmd ) =
            Page.GameLanding.createOnly session "backgammon"

        bootMs =
            D.decodeValue (D.field "bootMs" D.float) flags
                |> Result.withDefault 0
    in
    -- Who this browser is beyond its guest cookie: the account on it, if
    -- any. Until this answers it is a guest.
    ( model
    , Cmd.batch
        [ cmd
        , Cmd.map BarMsg barCmd
        , Auth.fetchMe session GotMe
        , Process.sleep (max 0 (Loading.minMs - bootMs)) |> Task.perform (\_ -> MinShown)

        -- A `/papi/me` that never answers must not leave `/` loading for
        -- ever: past this, the page draws as the guest it would have been.
        , Process.sleep meGivenUpMs |> Task.perform (\_ -> MeGivenUp)
        ]
    )


meGivenUpMs : Float
meGivenUpMs =
    6000


{-| `/` while it is still the loading bar: `/papi/me` has not answered,
the bar has not been up for `Loading.minMs`, or the account's home is
still waiting for its one answer.
-}
booting : Model -> Bool
booting model =
    model.route
        == Just Route.Library
        && (not model.meKnown
                || not model.minShown
                || (case model.page of
                        Home pageModel ->
                            Page.Home.loading pageModel

                        _ ->
                            False
                   )
           )


{-| The session changed (signed in, logged out, `/papi/me` answered): the
shell keeps it, and so does the page on screen.
-}
withSession : Session -> Model -> Model
withSession session model =
    { model
        | session = session
        , bar = Page.GameLanding.withSession session model.bar
        , page =
            case model.page of
                GameLanding pageModel ->
                    GameLanding (Page.GameLanding.withSession session pageModel)

                Home pageModel ->
                    Home (Page.Home.withSession session pageModel)

                Play pageModel ->
                    Play (Page.Play.withSession session pageModel)

                Login pageModel ->
                    Login (Page.Login.withSession session pageModel)

                Puzzle pageModel ->
                    Puzzle (Page.Puzzle.withSession session pageModel)

                Puzzles pageModel ->
                    Puzzles (Page.Puzzles.withSession session pageModel)

                Practice pageModel ->
                    Practice (Page.Practice.withSession session pageModel)

                Replay pageModel ->
                    Replay (Page.Replay.withSession session pageModel)

                other ->
                    other
    }


{-| A sign-in just went through: take the account at its word now, and ask
`/papi/me` for the rest.
-}
signedIn : Maybe Session.User -> Model -> ( Model, Cmd Msg )
signedIn user model =
    let
        session =
            Session.withUser user model.session

        ( settled, cmd ) =
            settle (withSession session model)
    in
    ( settled, Cmd.batch [ cmd, Auth.fetchMe session GotMe ] )


{-| `/` is two pages -- the guest's board and the account's home -- and
which one it is is known only once `/papi/me` has answered, which is after
the first paint. So whenever the session moves (the answer lands, a
sign-in goes through, a log-out), the page at `/` is checked against it
and opened afresh if it is the wrong one of the two. A browser that is
really signed in therefore ends up on its own home with no reload, and one
that logs out is handed the guest home back.

Every other route draws the same page either way, so this touches only `/`.

-}
settle : Model -> ( Model, Cmd Msg )
settle model =
    case ( model.route, model.page, model.session.user ) of
        ( Just Route.Library, GameLanding pageModel, Just _ ) ->
            -- Not out from under an open sign-in: the win it ends on is
            -- the answer to what was just done, and CONTINUE from it is
            -- what clears the way here.
            if Page.GameLanding.signingIn pageModel || Page.GameLanding.signingIn model.bar then
                ( model, Cmd.none )

            else
                openHome model

        ( Just Route.Library, Home _, Nothing ) ->
            openHome model

        _ ->
            ( model, Cmd.none )


{-| `/`, as this session should see it.
-}
openHome : Model -> ( Model, Cmd Msg )
openHome model =
    case model.session.user of
        Just _ ->
            Page.Home.init model.session |> wrap model Home HomeMsg

        Nothing ->
            Page.GameLanding.init model.session "backgammon" Nothing
                |> landing model


{-| Scheme, host and port of the page we were served from: what an invite
link has to start with to be worth sending.
-}
origin : Url -> String
origin url =
    let
        scheme =
            case url.protocol of
                Url.Https ->
                    "https://"

                Url.Http ->
                    "http://"
    in
    scheme
        ++ url.host
        ++ (case url.port_ of
                Just number ->
                    ":" ++ String.fromInt number

                Nothing ->
                    ""
           )


{-| A new page: the bar closes whatever it had open and counts the live
games again, then the page opens.
-}
routeTo : Url -> Model -> ( Model, Cmd Msg )
routeTo url oldModel =
    let
        ( model, cmd ) =
            openRoute url { oldModel | bar = Page.GameLanding.closeBar oldModel.bar }
    in
    ( model, Cmd.batch [ cmd, Cmd.map BarMsg (Page.GameLanding.refreshGames model.bar) ] )


openRoute : Url -> Model -> ( Model, Cmd Msg )
openRoute url oldModel =
    let
        route =
            Route.fromUrl url

        model =
            { oldModel | route = route, joinOpen = False, joinError = Nothing, joinCode = "" }
    in
    case route of
        Nothing ->
            ( { model | page = NotFound }, Cmd.none )

        -- The home page is the backgammon page: Oskol is a backgammon site.
        -- A player with an account gets their own home there instead --
        -- their games, their form, their practice (`Page.Home`).
        Just Route.Library ->
            openHome model

        Just (Route.Login token) ->
            Page.Login.init model.session { token = token, flags = model.loginFlags }
                |> wrap model Login LoginMsg

        Just (Route.GameLanding slug gameId) ->
            Page.GameLanding.init model.session slug gameId
                |> landing model

        Just (Route.Play slug gameId) ->
            Page.Play.init model.session
                { origin = model.origin
                , slug = slug
                , gameId = gameId
                }
                |> wrap model Play PlayMsg

        Just Route.Puzzles ->
            Page.Puzzles.init model.session { tz = model.tz }
                |> wrap model Puzzles PuzzlesMsg

        Just (Route.Practice slug) ->
            Page.Practice.init model.session { tz = model.tz, slug = slug }
                |> wrap model Practice PracticeMsg

        Just (Route.Puzzle id share) ->
            let
                -- The run stays a run only while the puzzle opened is one
                -- of its own (NEXT, or back to the one before): a link to
                -- some other puzzle leaves it.
                run =
                    model.run
                        |> Maybe.andThen
                            (\r ->
                                indexOf id r.ids |> Maybe.map (\at -> { r | at = at })
                            )

                inRun =
                    run /= Nothing
            in
            Page.Puzzle.init model.session
                { id = id

                -- ANOTHER only where there really is another; I'M DONE
                -- wherever this is a run at all, which is what ends it.
                -- A run of a deck always has one: past the ids it holds
                -- it asks the deck again.
                , hasNext = Maybe.map Run.goesOn run |> Maybe.withDefault False
                , inRun = inRun

                -- Where this one sits in the session, and what happened at
                -- each one before it: the page draws the bar and the marks
                -- from this and adds its own answer to them.
                , progress = Maybe.map Run.progress run
                , tier = run |> Maybe.andThen Run.tier
                , deck = run |> Maybe.andThen Run.deck
                , today =
                    case run of
                        Just _ ->
                            model.today

                        -- Not a session: a puzzle from a link says nothing
                        -- about anybody's day.
                        Nothing ->
                            Nothing
                , origin = model.origin
                , share = share
                }
                |> wrap { model | run = run } Puzzle PuzzleMsg

        Just (Route.Replay slug gameId game step) ->
            case model.page of
                -- The same room's replay: the address bar moved (back,
                -- forward, the page's own writing), not the reader.
                Replay pageModel ->
                    if pageModel.slug == slug && pageModel.gameId == gameId then
                        Page.Replay.locate game step pageModel
                            |> wrap model Replay ReplayMsg

                    else
                        Page.Replay.init model.session
                            { slug = slug, gameId = gameId, game = game, step = step }
                            |> wrap model Replay ReplayMsg

                _ ->
                    Page.Replay.init model.session
                        { slug = slug, gameId = gameId, game = game, step = step }
                        |> wrap model Replay ReplayMsg


{-| Whatever that step did, `/` is then the page this session should be
looking at: a guest home whose sign-in has just finished becomes the
account's home here, with no reload and no second round trip.
-}
andSettle : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
andSettle ( model, cmd ) =
    settle model |> Tuple.mapSecond (\more -> Cmd.batch [ cmd, more ])


wrap : Model -> (pageModel -> Page) -> (pageMsg -> Msg) -> ( pageModel, Cmd pageMsg ) -> ( Model, Cmd Msg )
wrap model toPage toMsg ( pageModel, cmd ) =
    ( { model | page = toPage pageModel }, Cmd.map toMsg cmd )


indexOf : a -> List a -> Maybe Int
indexOf wanted items =
    items
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, item ) -> item == wanted)
        |> List.head
        |> Maybe.map Tuple.first


{-| A run of these puzzles, from the first, started from the page at
`next`, which was told where the day stands as it fetched them. A tier
names the queue the run asks again once these run out; none is a list
handed over whole (one game's mistakes), which ends at its last. An empty
list starts nothing.
-}
startRun : String -> List String -> Maybe Today -> Maybe String -> Model -> ( Model, Cmd Msg )
startRun next ids today tier model =
    startRunWith
        { ids = ids
        , next = next
        , source = tier |> Maybe.map Run.Band |> Maybe.withDefault Run.Fixed
        , anyway = False
        , deckToday = Nothing
        , slug = Nothing
        }
        today
        model


{-| A run as the page that started it described it: what it is of,
whether it is PRACTICE ANYWAY, and the deck's day for the ring.
-}
startRunWith : Run.Start -> Maybe Today -> Model -> ( Model, Cmd Msg )
startRunWith config today model =
    case Run.start config of
        Nothing ->
            ( model, Cmd.none )

        Just run ->
            ( { model | run = Just { run | gen = model.runs + 1 }, runs = model.runs + 1, today = today }
            , Nav.pushUrl model.key (Route.href (Route.puzzle (Maybe.withDefault "" (List.head config.ids))))
            )


{-| What the puzzle page asked of the shell, with the page already in
`model`. `AnsweredThen` is a choice applied on the way out of a run's
puzzle: the answer is kept first, so the end card's score is about what
the player settled on, and then the page goes on.
-}
puzzleOut : Page.Puzzle.Out -> Model -> ( Model, Cmd Msg )
puzzleOut out model =
    case out of
        Page.Puzzle.NoOut ->
            ( model, Cmd.none )

        Page.Puzzle.Answered given ->
            case model.run of
                Just run ->
                    let
                        ( answered, counts ) =
                            Run.answer given run

                        -- The answer that finishes today's set: the page
                        -- draws the card under the reveal, and the deck is
                        -- read for its grid and its lines. Once a run.
                        ( kept, done ) =
                            Run.celebrate counts answered

                        counted =
                            { model
                                | run = Just kept
                                , today =
                                    if counts then
                                        Maybe.map (\day -> { day | done = day.done + 1 }) model.today

                                    else
                                        model.today
                            }
                    in
                    case ( model.page, done ) of
                        ( Puzzle pageModel, True ) ->
                            let
                                ( celebrating, cmd ) =
                                    Page.Puzzle.celebrate
                                        { target = kept.deckToday |> Maybe.map .target |> Maybe.withDefault 0
                                        , answered = Run.answered kept
                                        }
                                        pageModel
                            in
                            ( { counted | page = Puzzle celebrating }
                            , Cmd.batch
                                [ Cmd.map PuzzleMsg cmd
                                , case kept.slug of
                                    Just slug ->
                                        PracticeDecks.fetchDeck model.session slug (GotCelebration kept.gen)

                                    Nothing ->
                                        Cmd.none
                                ]
                            )

                        ( Puzzle pageModel, False ) ->
                            ( { counted | page = Puzzle (Page.Puzzle.withAnswered (Run.answered kept) pageModel) }, Cmd.none )

                        _ ->
                            ( counted, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Page.Puzzle.AnsweredThen given onward ->
            let
                ( kept, first ) =
                    puzzleOut (Page.Puzzle.Answered given) model

                ( went, second ) =
                    puzzleOut onward kept
            in
            ( went, Cmd.batch [ first, second ] )

        -- ANOTHER: the next of the run, or, past the ids it holds, the
        -- front of its queue again.
        Page.Puzzle.WantsNext ->
            case model.run of
                Just run ->
                    case Run.nextId run of
                        Just next ->
                            ( model, Nav.pushUrl model.key (Route.href (Route.puzzle next)) )

                        Nothing ->
                            if Run.refetchable run then
                                ( model, Run.refetch model.session run (GotRefetch run.gen) )

                            else
                                endHere model

                Nothing ->
                    ( model, Cmd.none )

        -- I'M DONE: the page ends the run here, with the score of what
        -- was actually answered, and the way on.
        Page.Puzzle.WantsEnd ->
            endHere model

        Page.Puzzle.GoOn way ->
            case model.run of
                Just run ->
                    ( model
                    , case way of
                        Page.Puzzle.Continue _ ->
                            Run.refetch model.session run (GotOnward run.gen way)

                        Page.Puzzle.MoreNew _ ->
                            Run.keepGoing model.session run (GotOnward run.gen way)

                        Page.Puzzle.Anyway ->
                            Run.practiceAnyway model.session run (GotOnward run.gen way)

                        Page.Puzzle.NoWay ->
                            Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        Page.Puzzle.StartRun ids today tier ->
            startRun (Route.href Route.puzzles) ids today tier model

        Page.Puzzle.SignedIn user ->
            signedIn user model

        Page.Puzzle.Go path ->
            ( model, Nav.pushUrl model.key path )


{-| The run is over at the puzzle on screen: its score, and -- for an
account's run through a deck -- the way on, once the shell has read where
the deck stands.
-}
endHere : Model -> ( Model, Cmd Msg )
endHere model =
    case ( model.run, model.page ) of
        ( Just run, Puzzle pageModel ) ->
            let
                ( ended, cmd ) =
                    Page.Puzzle.endRun (Run.score run) (Run.answers run) run.next pageModel

                asks =
                    Run.offersWays run && model.session.user /= Nothing
            in
            if asks then
                ( { model | page = Puzzle (Page.Puzzle.offering Page.Puzzle.Asking ended) }
                , Cmd.batch [ Cmd.map PuzzleMsg cmd, PracticeDecks.fetchList model.session (GotStanding run.gen) ]
                )

            else
                ( { model | page = Puzzle ended }, Cmd.map PuzzleMsg cmd )

        _ ->
            ( model, Cmd.none )


{-| The way on, on the end card on screen.
-}
offer : Page.Puzzle.WayState -> Model -> Model
offer state model =
    case model.page of
        Puzzle pageModel ->
            { model | page = Puzzle (Page.Puzzle.offering state pageModel) }

        _ ->
            model


{-| The run took more ids (the queue asked again, KEEP GOING, PRACTICE
ANYWAY): on to the first it had not reached, or, when there is none, the
end of today's set.
-}
goOn : Run.Run -> Model -> Maybe ( Model, Cmd Msg )
goOn run model =
    Run.nextId run
        |> Maybe.map
            (\next ->
                ( { model | run = Just run }
                , Nav.pushUrl model.key (Route.href (Route.puzzle next))
                )
            )


{-| The game page asks for two things the shell owns: the URL to go to, and
the name to remember for the next form.
-}
landing : Model -> ( Page.GameLanding.Model, Cmd Page.GameLanding.Msg, Page.GameLanding.Out ) -> ( Model, Cmd Msg )
landing model =
    landingInto (\pageModel -> { model | page = GameLanding pageModel }) GameLandingMsg model


{-| The bar answers the shell exactly as the game page does: it is the same
model, kept as `bar` instead of as the page.
-}
barUpdate : Model -> ( Page.GameLanding.Model, Cmd Page.GameLanding.Msg, Page.GameLanding.Out ) -> ( Model, Cmd Msg )
barUpdate model =
    landingInto (\barModel -> { model | bar = barModel }) BarMsg model


landingInto :
    (Page.GameLanding.Model -> Model)
    -> (Page.GameLanding.Msg -> Msg)
    -> Model
    -> ( Page.GameLanding.Model, Cmd Page.GameLanding.Msg, Page.GameLanding.Out )
    -> ( Model, Cmd Msg )
landingInto store toMsg model ( pageModel, cmd, out ) =
    let
        withPage =
            store pageModel
    in
    case out of
        Page.GameLanding.NoOut ->
            ( withPage, Cmd.map toMsg cmd )

        Page.GameLanding.Redirect path ->
            ( withPage
            , Cmd.batch [ Cmd.map toMsg cmd, Nav.replaceUrl model.key path ]
            )

        -- Every page wears the board picked in the bar: the session carries
        -- it down to the page on screen (the guest home's demo board, the
        -- table, the replay), not only to the shell.
        Page.GameLanding.ChoseTheme name ->
            ( withSession (Session.withPref "backgammon_theme" name model.session) withPage
            , Cmd.batch
                [ Cmd.map toMsg cmd
                , Page.Play.storePref { key = "backgammon_theme", value = name }
                ]
            )

        Page.GameLanding.TookSeat seat ->
            ( { withPage | session = Session.withGuestName seat.name model.session }
            , Cmd.batch [ Cmd.map toMsg cmd, Nav.pushUrl model.key seat.path ]
            )

        Page.GameLanding.SignedIn result ->
            signedIn result.user withPage
                |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map toMsg cmd, more ])

        Page.GameLanding.SignedOut ->
            signedIn Nothing withPage
                |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map toMsg cmd, more ])

        Page.GameLanding.Go path ->
            ( withPage, Cmd.batch [ Cmd.map toMsg cmd, Nav.pushUrl model.key path ] )

        Page.GameLanding.OpenJoin ->
            ( { withPage | joinOpen = True, joinCode = "", joinError = Nothing }
            , Cmd.batch [ Cmd.map toMsg cmd, Notebook.focus NoOp Shell.joinCodeInputId ]
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.page ) of
        ( LinkClicked (Browser.Internal url), _ ) ->
            case Route.fromUrl url of
                Just _ ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Nothing ->
                    -- Same origin but not one of ours (the sitemap, the dev
                    -- dashboard): hand it to the server.
                    ( model, Nav.load (Url.toString url) )

        ( LinkClicked (Browser.External href), _ ) ->
            ( model, Nav.load href )

        ( UrlChanged url, _ ) ->
            routeTo url model

        ( BarMsg barMsg, _ ) ->
            Page.GameLanding.update barMsg model.bar
                |> barUpdate model
                |> andSettle

        ( GameLandingMsg pageMsg, GameLanding pageModel ) ->
            Page.GameLanding.update pageMsg pageModel
                |> landing model
                |> andSettle

        ( HomeMsg pageMsg, Home pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Home.update pageMsg pageModel

                withPage =
                    { model | page = Home newPageModel }

                more extra =
                    Cmd.batch [ Cmd.map HomeMsg cmd, extra ]
            in
            case out of
                Page.Home.NoOut ->
                    ( withPage, Cmd.map HomeMsg cmd )

                Page.Home.Go path ->
                    ( withPage, more (Nav.pushUrl model.key path) )

                Page.Home.StartRun ids today tier ->
                    startRun (Route.href Route.library) ids today tier withPage |> Tuple.mapSecond more

                -- This browser turns out to have no account (logged out
                -- here or in another tab): the guest home is what `/` is.
                Page.Home.SignedOut ->
                    signedIn Nothing withPage |> Tuple.mapSecond more

                Page.Home.OpenCreate ->
                    Page.GameLanding.update Page.GameLanding.Started withPage.bar
                        |> barUpdate withPage
                        |> Tuple.mapSecond more

        ( LoginMsg pageMsg, Login pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Login.update pageMsg pageModel

                withPage =
                    { model | page = Login newPageModel }
            in
            case out of
                Page.Login.SignedIn user ->
                    signedIn user withPage
                        |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map LoginMsg cmd, more ])

                Page.Login.NoOut ->
                    ( withPage, Cmd.map LoginMsg cmd )

        ( GotMe (Ok me), _ ) ->
            settle (withSession (Session.withMe me model.session) { model | meKnown = True })

        -- Nothing known beyond the cookie: a guest, signing in off.
        ( GotMe (Err _), _ ) ->
            ( { model | meKnown = True }, Cmd.none )

        ( MinShown, _ ) ->
            ( { model | minShown = True }, Cmd.none )

        ( MeGivenUp, _ ) ->
            ( { model | meKnown = True }, Cmd.none )

        ( PlayMsg pageMsg, Play pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Play.update pageMsg pageModel
            in
            case out of
                Page.Play.SignedIn user ->
                    signedIn user { model | page = Play newPageModel }
                        |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map PlayMsg cmd, more ])

                -- PRACTICE THIS GAME'S N MISTAKES: the run ends back at
                -- this table.
                Page.Play.StartRun ids today ->
                    startRun (Route.href (Route.play newPageModel.gameSlug newPageModel.gameId)) ids today Nothing { model | page = Play newPageModel }
                        |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map PlayMsg cmd, more ])

                _ ->
                    ( { model | page = Play newPageModel }
                    , Cmd.batch
                        [ Cmd.map PlayMsg cmd
                        , case out of
                            Page.Play.Navigate url ->
                                Nav.pushUrl model.key url

                            _ ->
                                Cmd.none
                        ]
                    )

        ( ReplayMsg pageMsg, Replay pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Replay.update pageMsg pageModel

                -- The address bar follows the game and the line on the
                -- board, once the record is in (before it the page has
                -- not chosen a game yet), so a reload and a shared link
                -- land on the same move.
                address =
                    if Page.Replay.url newPageModel /= Page.Replay.url pageModel && Page.Replay.settled newPageModel then
                        Nav.replaceUrl model.key (Page.Replay.url newPageModel)

                    else
                        Cmd.none
            in
            case out of
                Page.Replay.SignedIn user ->
                    signedIn user { model | page = Replay newPageModel }
                        |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map ReplayMsg cmd, more ])

                Page.Replay.NoOut ->
                    ( { model | page = Replay newPageModel }, Cmd.batch [ Cmd.map ReplayMsg cmd, address ] )

        ( PuzzleMsg pageMsg, Puzzle pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Puzzle.update pageMsg pageModel
            in
            puzzleOut out { model | page = Puzzle newPageModel }
                |> Tuple.mapSecond (\extra -> Cmd.batch [ Cmd.map PuzzleMsg cmd, extra ])

        ( PuzzlesMsg pageMsg, Puzzles pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Puzzles.update pageMsg pageModel

                withPage =
                    { model | page = Puzzles newPageModel }

                more extra =
                    Cmd.batch [ Cmd.map PuzzlesMsg cmd, extra ]
            in
            case out of
                Page.Puzzles.NoOut ->
                    ( withPage, Cmd.map PuzzlesMsg cmd )

                Page.Puzzles.StartRun ids today tier begun ->
                    startRunWith
                        { ids = ids
                        , next = Route.href Route.puzzles
                        , source = tier |> Maybe.map Run.Band |> Maybe.withDefault Run.Fixed
                        , anyway = begun.anyway
                        , deckToday = begun.deckToday
                        , slug = Just begun.slug
                        }
                        today
                        withPage
                        |> Tuple.mapSecond more

                Page.Puzzles.StartDeckRun ids today deck begun ->
                    startRunWith
                        { ids = ids
                        , next = Route.href Route.puzzles
                        , source = Run.InSet deck
                        , anyway = begun.anyway
                        , deckToday = begun.deckToday
                        , slug = Just begun.slug
                        }
                        today
                        withPage
                        |> Tuple.mapSecond more

                Page.Puzzles.Go path ->
                    ( withPage, more (Nav.pushUrl model.key path) )

                Page.Puzzles.SignedIn user ->
                    signedIn user withPage |> Tuple.mapSecond more

        -- A deck's own page: its runs come back to it.
        ( PracticeMsg pageMsg, Practice pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Practice.update pageMsg pageModel

                withPage =
                    { model | page = Practice newPageModel }

                more extra =
                    Cmd.batch [ Cmd.map PracticeMsg cmd, extra ]

                back =
                    Route.href (Route.practice newPageModel.slug)
            in
            case out of
                Page.Practice.NoOut ->
                    ( withPage, Cmd.map PracticeMsg cmd )

                Page.Practice.StartRun ids today tier begun ->
                    startRunWith
                        { ids = ids
                        , next = back
                        , source = tier |> Maybe.map Run.Band |> Maybe.withDefault Run.Fixed
                        , anyway = begun.anyway
                        , deckToday = begun.deckToday
                        , slug = Just begun.slug
                        }
                        today
                        withPage
                        |> Tuple.mapSecond more

                Page.Practice.StartDeckRun ids today deck begun ->
                    startRunWith
                        { ids = ids
                        , next = back
                        , source = Run.InSet deck
                        , anyway = begun.anyway
                        , deckToday = begun.deckToday
                        , slug = Just begun.slug
                        }
                        today
                        withPage
                        |> Tuple.mapSecond more

                Page.Practice.Go path ->
                    ( withPage, more (Nav.pushUrl model.key path) )

                Page.Practice.SignedIn user ->
                    signedIn user withPage |> Tuple.mapSecond more

        ( OpenedJoin, _ ) ->
            ( { model | joinOpen = True, joinCode = "", joinError = Nothing }
            , Notebook.focus NoOp Shell.joinCodeInputId
            )

        ( ClosedJoin, _ ) ->
            ( { model | joinOpen = False, joinCode = "", joinError = Nothing }, Cmd.none )

        ( JoinCodeInput raw, _ ) ->
            let
                code =
                    cleanCode raw
            in
            -- Auto-submit: the moment a sixth character lands, try the code.
            if String.length code == 6 then
                tryJoin { model | joinCode = code, joinError = Nothing }

            else
                ( { model | joinCode = code, joinError = Nothing }, Cmd.none )

        ( JoinSubmitted, _ ) ->
            if String.length model.joinCode == 6 then
                tryJoin model

            else
                ( { model | joinError = Just "Enter the 6-character game code" }, Cmd.none )

        -- The server says which code it read: what was typed may have had an
        -- O for a zero, and the room's name is the one it answers to.
        ( GotJoinCode (Ok match), _ ) ->
            ( { model | joinOpen = False }
            , Nav.pushUrl model.key (Route.href (Route.invite match.slug match.code))
            )

        ( GotJoinCode (Err _), _ ) ->
            ( { model | joinError = Just "No game with that code" }, Cmd.none )

        -- The queue asked again: on with what it had not put in front of
        -- the player yet, or, with nothing new, today's set is done. A
        -- failed ask ends the run where it is rather than leaving ANOTHER
        -- pressed for ever.
        ( GotRefetch gen result, Puzzle _ ) ->
            case ( Run.current gen model.run, result ) of
                ( Just run, Ok ids ) ->
                    let
                        more =
                            Run.refetched ids run
                    in
                    case goOn more model of
                        Just going ->
                            going

                        Nothing ->
                            -- A full page of the rotation, all of it
                            -- already answered: ask past it.
                            if Run.askAgain ids more then
                                ( { model | run = Just more }, Run.refetch model.session more (GotRefetch gen) )

                            else
                                endHere { model | run = Just more }

                ( Just _, Err _ ) ->
                    endHere model

                ( Nothing, _ ) ->
                    ( model, Cmd.none )

        ( GotStanding gen (Ok catalog), Puzzle _ ) ->
            case Run.current gen model.run of
                Just run ->
                    ( offer (Page.Puzzle.Offered (Run.way run catalog.decks))
                        { model | run = Just (Run.withStanding catalog.decks run) }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        -- The deck as it stands now: the card's grid and lines, and its
        -- way on (KEEP GOING, or PRACTICE ANYWAY once nothing is new).
        ( GotCelebration gen result, Puzzle pageModel ) ->
            case Run.current gen model.run of
                Just run ->
                    let
                        ( read, way ) =
                            case result of
                                Ok deckPage ->
                                    ( Just deckPage, Run.way run [ deckPage.deck ] )

                                Err _ ->
                                    ( Nothing, Page.Puzzle.NoWay )

                        ( celebrating, cmd ) =
                            Page.Puzzle.celebrationRead read pageModel
                    in
                    ( { model | page = Puzzle (Page.Puzzle.offering (Page.Puzzle.Offered way) celebrating) }
                    , Cmd.map PuzzleMsg cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        ( GotStanding gen (Err _), Puzzle _ ) ->
            if Run.current gen model.run /= Nothing then
                ( offer (Page.Puzzle.Offered Page.Puzzle.NoWay) model, Cmd.none )

            else
                ( model, Cmd.none )

        ( GotOnward gen way result, Puzzle _ ) ->
            case ( Run.current gen model.run, result ) of
                ( Just run, Ok ids ) ->
                    let
                        more =
                            case way of
                                Page.Puzzle.MoreNew _ ->
                                    Run.keptGoing ids run

                                Page.Puzzle.Anyway ->
                                    Run.anywayFetched ids run

                                _ ->
                                    Run.refetched ids run
                    in
                    case goOn more model of
                        Just going ->
                            going

                        Nothing ->
                            if Run.askAgain ids more then
                                ( { model | run = Just more }, Run.refetch model.session more (GotOnward gen way) )

                            else
                                ( offer (Page.Puzzle.Stopped Mistakes.everyOnePracticed) { model | run = Just more }, Cmd.none )

                ( Just _, Err err ) ->
                    ( offer (Page.Puzzle.Stopped (Api.errorMessage err)) model, Cmd.none )

                ( Nothing, _ ) ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


{-| What the code field keeps of what was typed: upper case, the four
characters the alphabet leaves out folded onto the ones they are mistaken
for (I and L are ones, O is a zero, U is a V), anything else that is not a
letter or a digit dropped, six at most. The server normalises again, so
this is only so the visitor sees the code they are really asking for.
-}
cleanCode : String -> String
cleanCode code =
    code
        |> String.toUpper
        |> String.map fold
        |> String.filter Char.isAlphaNum
        |> String.left 6


fold : Char -> Char
fold char =
    case char of
        'I' ->
            '1'

        'L' ->
            '1'

        'O' ->
            '0'

        'U' ->
            'V'

        other ->
            other


tryJoin : Model -> ( Model, Cmd Msg )
tryJoin model =
    ( model, Catalog.lookupCode model.session model.joinCode GotJoinCode )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ case model.page of
            Play pageModel ->
                Sub.map PlayMsg (Page.Play.subscriptions pageModel)

            Replay pageModel ->
                Sub.map ReplayMsg (Page.Replay.subscriptions pageModel)

            Puzzle pageModel ->
                Sub.map PuzzleMsg (Page.Puzzle.subscriptions pageModel)

            GameLanding pageModel ->
                Sub.map GameLandingMsg (Page.GameLanding.subscriptions pageModel)

            Home pageModel ->
                Sub.map HomeMsg (Page.Home.subscriptions pageModel)

            _ ->
                Sub.none
        , Sub.map BarMsg (Page.GameLanding.subscriptions model.bar)
        , if model.joinOpen then
            Browser.Events.onKeyDown (escape ClosedJoin)

          else
            Sub.none
        ]


escape : msg -> D.Decoder msg
escape msg =
    D.field "key" D.string
        |> D.andThen
            (\key ->
                if key == "Escape" then
                    D.succeed msg

                else
                    D.fail "ignored key"
            )



-- VIEW


view : Model -> Document Msg
view model =
    { title = title model ++ " · Oskol"
    , body =
        if booting model then
            [ Shell.bare (shellConfig model) [ Loading.view model.bootMs ] ]

        else
            page model :: List.map (Html.map BarMsg) (Page.GameLanding.barModals model.bar)
    }


{-| The bar, for a page that sits under it: in the frame its styles live
in (`.lh`), sticky at the top.
-}
barTop : Model -> List (Html Msg)
barTop model =
    [ Html.div
        [ Html.Attributes.class "lh lh-top"
        , Html.Attributes.id
            (case model.page of
                Home _ ->
                    "home-bar"

                _ ->
                    "site-bar"
            )
        ]
        (Page.GameLanding.navBar BarMsg model.bar)
    ]


page : Model -> Html Msg
page model =
    case model.page of
            Play pageModel ->
                if Page.Play.framed pageModel then
                    framed model [ Html.map PlayMsg (Page.Play.view pageModel) ]

                else
                    underBar model (Html.map PlayMsg (Page.Play.view pageModel))

            Replay pageModel ->
                underBar model (Html.map ReplayMsg (Page.Replay.view pageModel))

            Puzzle pageModel ->
                underBar model (Html.map PuzzleMsg (Page.Puzzle.view pageModel))

            Puzzles pageModel ->
                framed model [ Html.map PuzzlesMsg (Page.Puzzles.view pageModel) ]

            Practice pageModel ->
                framed model [ Html.map PracticeMsg (Page.Practice.view pageModel) ]

            Login pageModel ->
                framed model [ Html.map LoginMsg (Page.Login.view pageModel) ]

            Home pageModel ->
                -- Its own chrome under the bar: the shell brings the paper
                -- and the code prompt behind JOIN.
                Shell.bare (shellConfig model)
                    (barTop model ++ Page.Home.view HomeMsg pageModel)

            GameLanding pageModel ->
                if Page.GameLanding.isHome pageModel then
                    -- The home page is the board, edge to edge: its own chrome.
                    -- The bar goes inside its full-screen frame, as its first row.
                    Shell.bare (shellConfig model)
                        (Page.GameLanding.home (Page.GameLanding.navBar BarMsg model.bar) GameLandingMsg pageModel)

                else
                    framed model [ Html.map GameLandingMsg (Page.GameLanding.view pageModel) ]

            NotFound ->
                framed model [ notFound ]


{-| A page that is the whole screen (the table, the replay, a puzzle) under
the bar: it sizes itself to what the bar leaves (`--page-h` in app.css).
-}
underBar : Model -> Html Msg -> Html Msg
underBar model content =
    Html.div [] (barTop model ++ [ content ])


framed : Model -> List (Html Msg) -> Html Msg
framed model content =
    Shell.view (shellConfig model) (barTop model) content


shellConfig : Model -> Shell.Config Msg
shellConfig model =
    { joinOpen = model.joinOpen
    , joinCode = model.joinCode
    , joinError = model.joinError
    , onOpenJoin = OpenedJoin
    , onCloseJoin = ClosedJoin
    , onJoinCodeInput = JoinCodeInput
    , onJoinSubmit = JoinSubmitted
    }


notFound : Html Msg
notFound =
    Html.section
        [ Html.Attributes.class "mt-8 sm:mt-12 q-card p-5 sm:p-8", Html.Attributes.id "not-found" ]
        [ Html.p
            [ Html.Attributes.class "pixel q-eyebrow text-[9px] mb-3" ]
            [ Html.text "NOT FOUND" ]
        , Html.a
            [ Html.Attributes.href (Route.href Route.library)
            , Html.Attributes.class "inline-block font-semibold"
            , Notebook.style "color: var(--pen)"
            ]
            [ Html.text "Back to the library →" ]
        ]


title : Model -> String
title model =
    case model.page of
        GameLanding pageModel ->
            Page.GameLanding.title pageModel

        Play pageModel ->
            Page.Play.title pageModel

        Replay pageModel ->
            Page.Replay.title pageModel

        Puzzle pageModel ->
            Page.Puzzle.title pageModel

        Puzzles pageModel ->
            Page.Puzzles.title pageModel

        Practice pageModel ->
            Page.Practice.title pageModel

        Home pageModel ->
            Page.Home.title pageModel

        Login pageModel ->
            Page.Login.title pageModel

        NotFound ->
            "Not found"
