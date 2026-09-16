module Main exposing (main)

{-| SPA shell: routing, page dispatch, and the chrome the landing pages sit
in (`Ui.Shell` — the OSKOL wordmark, the JOIN GAME prompt, the footer).

Three routes, and they are the server's three routes:

    /            Page.GameLanding "backgammon" — the home page, the board
    /:slug       Page.GameLanding — the invite a shared link opens
    /:slug/:id   Page.Play — the game, unchanged
    /:slug/:id/replay   Page.Replay — a game played again, with its analysis

The JOIN GAME prompt lives here rather than in a page because it is chrome:
six digits in, and out comes that room's ordinary invite link, which is the
same flow a shared link takes. Nothing about the room is revealed beyond
"a live game answers to this code".

-}

import Api
import Api.Catalog as Catalog
import Browser exposing (Document)
import Browser.Events
import Dict
import Browser.Navigation as Nav
import Html exposing (Html)
import Html.Attributes
import Json.Decode as D
import Page.GameLanding
import Page.Play
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
    , joinOpen : Bool
    , joinCode : String
    , joinError : Maybe String
    }


type Page
    = NotFound
    | GameLanding Page.GameLanding.Model
    | Play Page.Play.Model
    | Replay Page.Replay.Model


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GameLandingMsg Page.GameLanding.Msg
    | PlayMsg Page.Play.Msg
    | ReplayMsg Page.Replay.Msg
    | OpenedJoin
    | ClosedJoin
    | JoinCodeInput String
    | JoinSubmitted
    | GotJoinSlug (Result Api.Error String)
    | NoOp


init : D.Value -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        session =
            D.decodeValue Session.decoder flags
                |> Result.withDefault { csrf = "", guestName = Nothing, prefs = Dict.empty }
    in
    routeTo url
        { key = key
        , origin = origin url
        , session = session
        , route = Nothing
        , page = NotFound
        , joinOpen = False
        , joinCode = ""
        , joinError = Nothing
        }


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
        Just Route.Library ->
            Page.GameLanding.init model.session "backgammon" Nothing Nothing
                |> landing model

        Just (Route.GameLanding slug gameId token) ->
            Page.GameLanding.init model.session slug gameId token
                |> landing model

        Just (Route.Play slug gameId token) ->
            Page.Play.init model.session
                { origin = model.origin
                , slug = slug
                , gameId = gameId
                , seatToken = token
                }
                |> wrap model Play PlayMsg

        Just (Route.Replay slug gameId token game) ->
            Page.Replay.init model.session
                { slug = slug
                , gameId = gameId
                , token = token
                , game = game
                }
                |> wrap model Replay ReplayMsg


wrap : Model -> (pageModel -> Page) -> (pageMsg -> Msg) -> ( pageModel, Cmd pageMsg ) -> ( Model, Cmd Msg )
wrap model toPage toMsg ( pageModel, cmd ) =
    ( { model | page = toPage pageModel }, Cmd.map toMsg cmd )


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

        ( PlayMsg pageMsg, Play pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Play.update pageMsg pageModel
            in
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
            Page.Replay.update pageMsg pageModel
                |> wrap model Replay ReplayMsg

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
            -- Auto-submit: the moment a sixth digit lands, try the code.
            if String.length code == 6 then
                tryJoin { model | joinCode = code, joinError = Nothing }

            else
                ( { model | joinCode = code, joinError = Nothing }, Cmd.none )

        ( JoinSubmitted, _ ) ->
            if String.length model.joinCode == 6 then
                tryJoin model

            else
                ( { model | joinError = Just "Enter the 6-digit game code" }, Cmd.none )

        ( GotJoinSlug (Ok slug), _ ) ->
            ( { model | joinOpen = False }
            , Nav.pushUrl model.key (Route.href (Route.invite slug model.joinCode))
            )

        ( GotJoinSlug (Err _), _ ) ->
            ( { model | joinError = Just "No game with that code" }, Cmd.none )

        _ ->
            ( model, Cmd.none )


cleanCode : String -> String
cleanCode code =
    code |> String.filter Char.isDigit |> String.left 6


tryJoin : Model -> ( Model, Cmd Msg )
tryJoin model =
    ( model, Catalog.lookupCode model.session model.joinCode GotJoinSlug )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ case model.page of
            Play pageModel ->
                Sub.map PlayMsg (Page.Play.subscriptions pageModel)

            Replay pageModel ->
                Sub.map ReplayMsg (Page.Replay.subscriptions pageModel)

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

        NotFound ->
            "Not found"
