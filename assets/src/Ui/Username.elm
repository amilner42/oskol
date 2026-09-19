module Ui.Username exposing (Model, Msg, init, update, view)

{-| The username a new account was given, on the win, with the way to
change it: "You'll show up as arie1 · Change". The account shows up by this
name everywhere, never by its email.

Shown only for an account this sign-in made; a returning account already
has the name it chose.

-}

import Api
import Api.Auth as Auth
import Html exposing (Html)
import Html.Attributes exposing (attribute, class, id, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Session exposing (Session, User)
import Ui.Notebook as Notebook exposing (style)


type alias Model =
    { name : String
    , editing : Bool
    , draft : String
    , saving : Bool
    , error : Maybe String
    }


type Msg
    = PressedChange
    | DraftChanged String
    | Submitted
    | PressedCancel
    | Saved (Result Api.Error User)
    | Focused


{-| Nothing to show unless this sign-in made the account and named it.
-}
init : Auth.SignedIn -> Maybe Model
init signedIn =
    case ( signedIn.new, signedIn.user |> Maybe.andThen .name ) of
        ( True, Just name ) ->
            Just { name = name, editing = False, draft = name, saving = False, error = Nothing }

        _ ->
            Nothing


fieldId : String
fieldId =
    "username-field"


{-| The account after a rename, so the page can show the new name at once.
-}
update : Session -> Msg -> Model -> ( Model, Cmd Msg, Maybe User )
update session msg model =
    case msg of
        PressedChange ->
            ( { model | editing = True, draft = model.name, error = Nothing }
            , Notebook.focus Focused fieldId
            , Nothing
            )

        DraftChanged draft ->
            ( { model | draft = draft, error = Nothing }, Cmd.none, Nothing )

        Submitted ->
            if String.trim model.draft == model.name then
                ( { model | editing = False }, Cmd.none, Nothing )

            else if model.saving then
                ( model, Cmd.none, Nothing )

            else
                ( { model | saving = True, error = Nothing }
                , Auth.rename session (String.trim model.draft) Saved
                , Nothing
                )

        PressedCancel ->
            ( { model | editing = False, error = Nothing }, Cmd.none, Nothing )

        Saved (Ok user) ->
            ( { model
                | name = Maybe.withDefault model.name user.name
                , editing = False
                , saving = False
              }
            , Cmd.none
            , Just user
            )

        Saved (Err error) ->
            ( { model | saving = False, error = Just (Api.errorMessage error) }
            , Notebook.focus Focused fieldId
            , Nothing
            )

        Focused ->
            ( model, Cmd.none, Nothing )


view : Model -> Html Msg
view model =
    if model.editing then
        Html.form [ id "username-form", onSubmit Submitted, class "w-full flex flex-col gap-2" ]
            [ Html.label [ class "q-note text-[13px]", Html.Attributes.for fieldId ] [ Html.text "Your username" ]
            , Html.div [ class "flex gap-2" ]
                [ Html.input
                    [ id fieldId
                    , type_ "text"
                    , value model.draft
                    , onInput DraftChanged
                    , Html.Attributes.maxlength 24
                    , attribute "autocomplete" "username"
                    , attribute "autocapitalize" "off"
                    , attribute "spellcheck" "false"
                    , class "q-field flex-1 min-w-0 px-3 py-2 text-[15px]"
                    ]
                    []
                , Html.button
                    [ type_ "submit"
                    , id "username-save"
                    , class "q-btn px-4 py-2 text-[14px]"
                    , Html.Attributes.disabled model.saving
                    ]
                    [ Html.text "Save" ]
                ]
            , case model.error of
                Just error ->
                    Html.p [ id "username-error", class "text-[13px] font-semibold", style "color: var(--red)" ] [ Html.text error ]

                Nothing ->
                    Html.text ""
            , Html.button
                [ type_ "button", class "q-note text-[13px] underline self-center", onClick PressedCancel ]
                [ Html.text "Keep " , Html.span [ class "font-semibold" ] [ Html.text model.name ] ]
            ]

    else
        Html.p [ id "username-line", class "text-[14px] leading-snug", style "color: var(--ink)" ]
            [ Html.text "You'll show up as "
            , Html.span [ id "username-name", class "font-bold" ] [ Html.text model.name ]
            , Html.text " · "
            , Html.button
                [ type_ "button", id "username-change", class "underline font-semibold", onClick PressedChange ]
                [ Html.text "Change" ]
            ]
