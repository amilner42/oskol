module Main exposing (main)

{-| SPA shell: routing, page dispatch, and the chrome the landing pages sit
in (`Ui.Shell` — the OSKOL plate, the JOIN GAME prompt, the footer).

Three routes, and they are the server's three routes:

    /            Page.Library
    /:slug       Page.GameLanding
    /:slug/:id   Page.Play — the game, unchanged

The JOIN GAME prompt lives here rather than in a page because it is chrome:
six digits in, and out comes that room's ordinary invite link, which is the
same flow a shared link takes. Nothing about the room is revealed beyond
"a live game answers to this code".

-}

import Api
import Api.Catalog as Catalog
import Browser exposing (Document)
import Browser.Events
import Browser.Navigation as Nav
import Html exposing (Html)
import Html.Attributes
import Json.Decode as D
import Page.GameLanding
import Page.Library
import Page.Play
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
    | Library Page.Library.Model
    | GameLanding Page.GameLanding.Model
    | Play Page.Play.Model


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | LibraryMsg Page.Library.Msg
    | GameLandingMsg Page.GameLanding.Msg
    | PlayMsg Page.Play.Msg
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
                |> Result.withDefault { csrf = "", guestName = Nothing }
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

        Just Route.Library ->
            Page.Library.init model.session
                |> wrap model Library LibraryMsg

        Just (Route.GameLanding slug gameId token) ->
            Page.GameLanding.init model.session slug gameId token
                |> landing model

        Just (Route.Play slug gameId token) ->
            Page.Play.init
                { origin = model.origin
                , slug = slug
                , gameId = gameId
                , seatToken = token
                }
                |> wrap model Play PlayMsg


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

        ( LibraryMsg pageMsg, Library pageModel ) ->
            Page.Library.update pageMsg pageModel
                |> wrap model Library LibraryMsg

        ( GameLandingMsg pageMsg, GameLanding pageModel ) ->
            Page.GameLanding.update pageMsg pageModel
                |> landing model

        ( PlayMsg pageMsg, Play pageModel ) ->
            let
                ( newPageModel, cmd, out ) =
                    Page.Play.update pageMsg pageModel
            in
            ( { model | page = Play newPageModel }
            , Cmd.batch
                [ Cmd.map PlayMsg cmd
                , case out of
                    Page.Play.Navigate url ->
                        Nav.pushUrl model.key url

                    Page.Play.NoOut ->
                        Cmd.none
                ]
            )

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

            Library pageModel ->
                framed model [ Html.map LibraryMsg (Page.Library.view pageModel) ]

            GameLanding pageModel ->
                framed model [ Html.map GameLandingMsg (Page.GameLanding.view pageModel) ]

            NotFound ->
                framed model [ notFound ]
        ]
    }


framed : Model -> List (Html Msg) -> Html Msg
framed model content =
    Shell.view
        { joinOpen = model.joinOpen
        , joinCode = model.joinCode
        , joinError = model.joinError
        , onOpenJoin = OpenedJoin
        , onCloseJoin = ClosedJoin
        , onJoinCodeInput = JoinCodeInput
        , onJoinSubmit = JoinSubmitted
        }
        content


notFound : Html Msg
notFound =
    Html.section [ Html.Attributes.class "mt-8 sm:mt-12 pix p-4 sm:p-8", Html.Attributes.id "not-found" ]
        [ Html.p
            [ Html.Attributes.class "pixel text-[10px] mb-3", Notebook.style "color: var(--red)" ]
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
        Library _ ->
            Page.Library.title

        GameLanding pageModel ->
            Page.GameLanding.title pageModel

        Play pageModel ->
            Page.Play.title pageModel

        NotFound ->
            "Not found"
