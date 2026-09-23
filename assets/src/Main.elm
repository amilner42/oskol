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

A practice run -- the puzzles a session works through, one NEXT at a
time -- is kept here (`run`) and not in the puzzle page, because it has to
outlive the page: every `pushUrl` to the next puzzle builds that page
afresh. The pages that start a run (the practice home, a finished game's
result card at the table, the replay) hand the shell the list (`StartRun
ids`, which opens the first) and the shell notes where it was started
from (`next`); the puzzle page reports each verdict (`Answered`), which
the run keeps as its score, and says when it wants the next
(`WantsNext`): the shell opens it, or, at the last, hands the page the
score and the way back (`Page.Puzzle.endRun`) and the page ends the run
on its own screen.

The JOIN GAME prompt lives here rather than in a page because it is chrome:
six characters in, and out comes that room's ordinary invite link, which is
the same flow a shared link takes. Nothing about the room is revealed beyond
"a live game answers to this code".

-}

import Api
import Api.Auth as Auth
import Api.Catalog as Catalog
import Browser exposing (Document)
import Browser.Events
import Browser.Navigation as Nav
import Html exposing (Html)
import Html.Attributes
import Json.Decode as D
import Games.Backgammon.Puzzle exposing (Verdict(..))
import Page.GameLanding
import Page.Home
import Page.Login
import Page.Play
import Page.Puzzle
import Page.Puzzles
import Page.Replay
import Route exposing (Route)
import Session exposing (Session)
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
    , run : Maybe Run
    , joinOpen : Bool
    , joinCode : String
    , joinError : Maybe String
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


type alias Run =
    { ids : List String
    , at : Int
    , verdicts : List ( String, Verdict ) -- by puzzle id; an answer given again replaces the first
    , next : String -- the page the run was started from: where a guest who signs in at its end goes on to
    }


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
    | OpenedJoin
    | ClosedJoin
    | JoinCodeInput String
    | JoinSubmitted
    | GotJoinCode (Result Api.Error Catalog.CodeMatch)
    | GotMe (Result Api.Error Session.Me)
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
                , joinOpen = False
                , joinCode = ""
                , joinError = Nothing
                }
    in
    -- Who this browser is beyond its guest cookie: the account on it, if
    -- any. Until this answers it is a guest.
    ( model, Cmd.batch [ cmd, Auth.fetchMe session GotMe ] )


{-| The session changed (signed in, logged out, `/papi/me` answered): the
shell keeps it, and so does the page on screen.
-}
withSession : Session -> Model -> Model
withSession session model =
    { model
        | session = session
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
            if Page.GameLanding.signingIn pageModel then
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


routeTo : Url -> Model -> ( Model, Cmd Msg )
routeTo url oldModel =
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
            in
            Page.Puzzle.init model.session
                { id = id

                -- In a run there is always somewhere after this one: the
                -- next puzzle, or the run's end.
                , hasNext = run /= Nothing
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


{-| The puzzle after the open one, if the run has one.
-}
nextInRun : Maybe Run -> Maybe String
nextInRun run =
    run |> Maybe.andThen (\r -> r.ids |> List.drop (r.at + 1) |> List.head)


{-| A run of these puzzles, from the first, started from the page at
`next`. An empty list starts nothing.
-}
startRun : String -> List String -> Model -> ( Model, Cmd Msg )
startRun next ids model =
    case ids of
        [] ->
            ( model, Cmd.none )

        first :: _ ->
            ( { model | run = Just { ids = ids, at = 0, verdicts = [], next = next } }
            , Nav.pushUrl model.key (Route.href (Route.puzzle first))
            )


{-| The verdict on the open puzzle, kept on the run. Answering the same
puzzle again (back, then PLAY) replaces the first verdict rather than
counting twice.
-}
answered : Verdict -> Run -> Run
answered verdict run =
    case run.ids |> List.drop run.at |> List.head of
        Just id ->
            { run | verdicts = ( id, verdict ) :: List.filter (\( other, _ ) -> other /= id) run.verdicts }

        Nothing ->
            run


{-| A pass is right, a hold is close, a miss or an unknown is neither;
the total is the run's length, answered or not.
-}
score : Run -> Page.Puzzle.Score
score run =
    let
        count verdict =
            run.verdicts |> List.filter (\( _, v ) -> v == verdict) |> List.length
    in
    { right = count Pass, close = count Hold, total = List.length run.ids }


{-| The game page asks for two things the shell owns: the URL to go to, and
the name to remember for the next form.
-}
landing : Model -> ( Page.GameLanding.Model, Cmd Page.GameLanding.Msg, Page.GameLanding.Out ) -> ( Model, Cmd Msg )
landing model ( pageModel, cmd, out ) =
    let
        withPage =
            { model | page = GameLanding pageModel }
    in
    case out of
        Page.GameLanding.NoOut ->
            ( withPage, Cmd.map GameLandingMsg cmd )

        Page.GameLanding.Redirect path ->
            ( withPage
            , Cmd.batch [ Cmd.map GameLandingMsg cmd, Nav.replaceUrl model.key path ]
            )

        Page.GameLanding.ChoseTheme name ->
            ( { withPage | session = Session.withPref "backgammon_theme" name model.session }
            , Cmd.batch
                [ Cmd.map GameLandingMsg cmd
                , Page.Play.storePref { key = "backgammon_theme", value = name }
                ]
            )

        Page.GameLanding.TookSeat seat ->
            ( { withPage | session = Session.withGuestName seat.name model.session }
            , Cmd.batch [ Cmd.map GameLandingMsg cmd, Nav.pushUrl model.key seat.path ]
            )

        Page.GameLanding.SignedIn result ->
            signedIn result.user withPage
                |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map GameLandingMsg cmd, more ])

        Page.GameLanding.SignedOut ->
            signedIn Nothing withPage
                |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map GameLandingMsg cmd, more ])

        Page.GameLanding.Go path ->
            ( withPage, Cmd.batch [ Cmd.map GameLandingMsg cmd, Nav.pushUrl model.key path ] )


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

                Page.Home.TookSeat seat ->
                    ( { withPage | session = Session.withGuestName seat.name model.session }
                    , more (Nav.pushUrl model.key seat.path)
                    )

                Page.Home.ChoseTheme name ->
                    ( { withPage | session = Session.withPref "backgammon_theme" name model.session }
                    , more (Page.Play.storePref { key = "backgammon_theme", value = name })
                    )

                Page.Home.StartRun ids ->
                    startRun (Route.href Route.library) ids withPage |> Tuple.mapSecond more

                -- This browser turns out to have no account (logged out
                -- here or in another tab): the guest home is what `/` is.
                Page.Home.SignedOut ->
                    signedIn Nothing withPage |> Tuple.mapSecond more

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
            settle (withSession (Session.withMe me model.session) model)

        -- Nothing known beyond the cookie: a guest, signing in off.
        ( GotMe (Err _), _ ) ->
            ( model, Cmd.none )

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
                Page.Play.StartRun ids ->
                    startRun (Route.href (Route.play newPageModel.gameSlug newPageModel.gameId)) ids { model | page = Play newPageModel }
                        |> Tuple.mapSecond (\more -> Cmd.batch [ Cmd.map PlayMsg cmd, more ])

                _ ->
                    ( { model
                        | page = Play newPageModel
                        , session =
                            case out of
                                Page.Play.Remember key value ->
                                    Session.withPref key value model.session

                                _ ->
                                    model.session
                      }
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

                withPage =
                    { model | page = Puzzle newPageModel }

                more extra =
                    Cmd.batch [ Cmd.map PuzzleMsg cmd, extra ]
            in
            case out of
                Page.Puzzle.NoOut ->
                    ( withPage, Cmd.map PuzzleMsg cmd )

                Page.Puzzle.Answered verdict ->
                    ( { withPage | run = Maybe.map (answered verdict) model.run }, Cmd.map PuzzleMsg cmd )

                Page.Puzzle.WantsNext ->
                    case ( nextInRun model.run, model.run ) of
                        ( Just next, _ ) ->
                            ( withPage, more (Nav.pushUrl model.key (Route.href (Route.puzzle next))) )

                        -- The last of the run: the page ends it, with the score.
                        ( Nothing, Just run ) ->
                            Page.Puzzle.endRun (score run) run.next newPageModel
                                |> wrap model Puzzle PuzzleMsg
                                |> Tuple.mapSecond more

                        ( Nothing, Nothing ) ->
                            ( withPage, Cmd.map PuzzleMsg cmd )

                Page.Puzzle.StartRun ids ->
                    startRun (Route.href Route.puzzles) ids withPage |> Tuple.mapSecond more

                Page.Puzzle.SignedIn user ->
                    signedIn user withPage |> Tuple.mapSecond more

                Page.Puzzle.Go path ->
                    ( withPage, more (Nav.pushUrl model.key path) )

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

                Page.Puzzles.StartRun ids ->
                    startRun (Route.href Route.puzzles) ids withPage |> Tuple.mapSecond more

                Page.Puzzles.Go path ->
                    ( withPage, more (Nav.pushUrl model.key path) )

                Page.Puzzles.SignedIn user ->
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
        [ case model.page of
            Play pageModel ->
                if Page.Play.framed pageModel then
                    framed model [ Html.map PlayMsg (Page.Play.view pageModel) ]

                else
                    Html.map PlayMsg (Page.Play.view pageModel)

            Replay pageModel ->
                Html.map ReplayMsg (Page.Replay.view pageModel)

            Puzzle pageModel ->
                Html.map PuzzleMsg (Page.Puzzle.view pageModel)

            Puzzles pageModel ->
                framed model [ Html.map PuzzlesMsg (Page.Puzzles.view pageModel) ]

            Login pageModel ->
                framed model [ Html.map LoginMsg (Page.Login.view pageModel) ]

            Home pageModel ->
                -- Its own chrome, like the board home: the page draws its
                -- own bar, and the shell brings the paper and the code
                -- prompt behind JOIN.
                Shell.bare (shellConfig model)
                    (Page.Home.view
                        { join = Shell.quietJoinButton (shellConfig model), toMsg = HomeMsg }
                        pageModel
                    )

            GameLanding pageModel ->
                if Page.GameLanding.isHome pageModel then
                    -- The home page is the board, edge to edge: its own chrome.
                    Shell.bare (shellConfig model)
                        (Page.GameLanding.home
                            { join = Shell.joinButton (shellConfig model), toMsg = GameLandingMsg }
                            pageModel
                        )

                else
                    framed model [ Html.map GameLandingMsg (Page.GameLanding.view pageModel) ]

            NotFound ->
                framed model [ notFound ]
        ]
    }


framed : Model -> List (Html Msg) -> Html Msg
framed model content =
    Shell.view (shellConfig model) content


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

        Home pageModel ->
            Page.Home.title pageModel

        Login pageModel ->
            Page.Login.title pageModel

        NotFound ->
            "Not found"
