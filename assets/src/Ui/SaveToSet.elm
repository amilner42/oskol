module Ui.SaveToSet exposing
    ( Line(..)
    , Model
    , Msg(..)
    , Out(..)
    , Sets(..)
    , init
    , update
    , view
    )

{-| SAVE: one position into a set of your own. The one sheet both doors
open -- the analysis board's answer (`#an-save`) and a puzzle's reveal
(`#pz-save`) -- with the puzzle's id.

    GET    /papi/decks/mine?puzzle=<id>        the sets, each with a check
    POST   /papi/decks/:id/puzzles {puzzle_id} a row ticked
    DELETE /papi/decks/:id/puzzles/:puzzle_id  a row unticked
    POST   /papi/decks/mine {name}             CREATE, then the add

  - **Your sets**, one row each, oldest first, with a check where the set
    holds this position already. A tap inks the check (or clears it) at
    once and the request follows; an error puts it back and says why.
  - **New set**: a name and CREATE, which makes the set and puts the
    position in it. The server's refusals ("Give it a name", "You already
    have a set called that") are said in the line.
  - **One line** of fixed height for what happened last: "Saved to
    Openings I like · 12 positions", or why not.

A guest reads "Sign in to keep this position." over the one sign-in
(`Ui.SignIn`); its `next` is the page's own address (the analysis board's
carries the position as `?xgid=`), so a mailed link lands back on it. Signed
in there and then, the shell is told (`SignedIn`) and the sheet goes on
to the sets.

It floats: a sheet from the bottom on a phone, a card in the middle on
anything wider, over a dimmed page that closes it. Opening it, ticking a
row, and every line it says move nothing on the page under it, and
nothing inside it either: the list keeps its height from loading to
loaded, the line its one line.

To a player these are sets; nothing here says deck or card.

-}

import Api
import Api.Decks as Decks exposing (OwnSet)
import Html exposing (Html)
import Html.Attributes as Attr exposing (attribute, class, id, type_)
import Html.Events exposing (onClick, onInput, onSubmit)
import Session exposing (Session)
import Ui.Decks as Words
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn


type Sets
    = Loading
    | Loaded (List OwnSet)
    | Failed String


{-| What the line under everything says: nothing yet, where the position
went (or came out of), or why not.
-}
type Line
    = Quiet
    | Said String
    | Refused String


type alias Model =
    { puzzleId : String
    , next : String -- where a sign-in comes back to: the page this was opened on
    , sets : Sets
    , name : String
    , creating : Bool
    , busy : List String -- the sets with a press on its way
    , line : Line
    , signIn : Maybe SignIn.Model
    }


type Msg
    = GotSets (Result Api.Error (List OwnSet))
    | Toggled String
    | GotSaved String (Result Api.Error OwnSet)
    | GotRemoved String (Result Api.Error OwnSet)
    | NameChanged String
    | SubmittedNew
    | GotCreated (Result Api.Error OwnSet)
    | SignInMsg SignIn.Msg
    | PressedClose
    | Focused


{-| What the page does about it: nothing, close the sheet, or tell the
shell the browser signed in.
-}
type Out
    = NoOut
    | Close
    | SignedIn (Maybe Session.User)


init : Session -> { puzzleId : String, next : String } -> ( Model, Cmd Msg )
init session config =
    let
        base =
            { puzzleId = config.puzzleId
            , next = config.next
            , sets = Loading
            , name = ""
            , creating = False
            , busy = []
            , line = Quiet
            , signIn = Nothing
            }
    in
    case session.user of
        Just _ ->
            ( base, Decks.fetchMine session config.puzzleId GotSets )

        Nothing ->
            let
                ( signIn, cmd ) =
                    SignIn.init { next = config.next, email = "" }
            in
            ( { base | signIn = Just signIn }, Cmd.map SignInMsg cmd )



-- UPDATE


update : Session -> Msg -> Model -> ( Model, Cmd Msg, Out )
update session msg model =
    case msg of
        GotSets (Ok sets) ->
            ( { model | sets = Loaded sets }, Cmd.none, NoOut )

        GotSets (Err err) ->
            ( { model | sets = Failed (Api.errorMessage err) }, Cmd.none, NoOut )

        Toggled setId ->
            case ( model.sets, List.member setId model.busy ) of
                ( Loaded sets, False ) ->
                    case List.filter (\s -> s.id == setId) sets |> List.head of
                        Just set ->
                            -- The check moves at once; the answer confirms it
                            -- or puts it back.
                            ( { model
                                | sets = Loaded (withHolds setId (not set.holds) sets)
                                , busy = setId :: model.busy
                              }
                            , if set.holds then
                                Decks.removePuzzle session setId model.puzzleId (GotRemoved setId)

                              else
                                Decks.addPuzzle session setId model.puzzleId (GotSaved setId)
                            , NoOut
                            )

                        Nothing ->
                            ( model, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        GotSaved setId (Ok set) ->
            ( landed setId { set | holds = True } (Said (Words.savedLine { name = set.name, size = set.size })) model
            , Cmd.none
            , NoOut
            )

        GotRemoved setId (Ok set) ->
            ( landed setId { set | holds = False } (Said (Words.removedLine { name = set.name, size = set.size })) model
            , Cmd.none
            , NoOut
            )

        GotSaved setId (Err err) ->
            ( undone setId False err model, Cmd.none, NoOut )

        GotRemoved setId (Err err) ->
            ( undone setId True err model, Cmd.none, NoOut )

        NameChanged name ->
            ( { model | name = name }, Cmd.none, NoOut )

        SubmittedNew ->
            if model.creating then
                ( model, Cmd.none, NoOut )

            else
                ( { model | creating = True, line = Quiet }
                , Decks.createOwn session model.name GotCreated
                , NoOut
                )

        GotCreated (Ok set) ->
            -- Made: it joins the list at the end, ticked, and the position
            -- goes in.
            let
                sets =
                    case model.sets of
                        Loaded known ->
                            known

                        _ ->
                            []
            in
            ( { model
                | sets = Loaded (sets ++ [ { set | holds = True } ])
                , name = ""
                , creating = False
                , busy = set.id :: model.busy
              }
            , Decks.addPuzzle session set.id model.puzzleId (GotSaved set.id)
            , NoOut
            )

        GotCreated (Err err) ->
            ( { model | creating = False, line = Refused (Api.errorMessage err) }
            , Notebook.focus Focused newNameId
            , NoOut
            )

        SignInMsg signInMsg ->
            case model.signIn of
                Just signIn ->
                    let
                        ( next, cmd, out ) =
                            SignIn.update session signInMsg signIn

                        updated =
                            { model | signIn = Just next }
                    in
                    case out of
                        SignIn.NoOut ->
                            ( updated, Cmd.map SignInMsg cmd, NoOut )

                        -- Signed in: the sets are this account's now. Ask
                        -- for them while the win is on screen, and tell the
                        -- shell.
                        SignIn.SignedIn result ->
                            ( updated
                            , Cmd.batch
                                [ Cmd.map SignInMsg cmd
                                , Decks.fetchMine session model.puzzleId GotSets
                                ]
                            , SignedIn result.user
                            )

                        -- CONTINUE: the sheet goes on to the sets.
                        SignIn.Continue _ ->
                            ( { updated | signIn = Nothing }, Cmd.none, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        PressedClose ->
            ( model, Cmd.none, Close )

        Focused ->
            ( model, Cmd.none, NoOut )


withHolds : String -> Bool -> List OwnSet -> List OwnSet
withHolds setId holds =
    List.map
        (\s ->
            if s.id == setId then
                { s | holds = holds }

            else
                s
        )


{-| A press came back: the set as the server has it now, and the line.
-}
landed : String -> OwnSet -> Line -> Model -> Model
landed setId set line model =
    { model
        | sets =
            case model.sets of
                Loaded sets ->
                    Loaded
                        (List.map
                            (\s ->
                                if s.id == setId then
                                    set

                                else
                                    s
                            )
                            sets
                        )

                other ->
                    other
        , busy = List.filter ((/=) setId) model.busy
        , line = line
    }


{-| A press refused: the check goes back to what it was, and the line says
why.
-}
undone : String -> Bool -> Api.Error -> Model -> Model
undone setId holds err model =
    { model
        | sets =
            case model.sets of
                Loaded sets ->
                    Loaded (withHolds setId holds sets)

                other ->
                    other
        , busy = List.filter ((/=) setId) model.busy
        , line = Refused (Api.errorMessage err)
    }



-- VIEW


newNameId : String
newNameId =
    "save-new-name"


view : Model -> Html Msg
view model =
    Html.div [ id "save-modal", class "save-layer" ]
        [ Html.div [ class "save-dim", onClick PressedClose, attribute "aria-hidden" "true" ] []
        , Html.div
            [ class "q-card sheet save-sheet"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" "Save to a set"
            ]
            (Html.div [ class "save-head" ]
                [ Html.h2 [ class "pixel q-eyebrow text-[9px]" ] [ Html.text "SAVE TO A SET" ]
                , Html.button
                    [ type_ "button"
                    , id "save-close"
                    , onClick PressedClose
                    , attribute "aria-label" "Close"
                    , class "q-note text-base px-2 py-1 -mr-2 hover:text-[color:var(--red)]"
                    ]
                    [ Html.text "✕" ]
                ]
                :: (case model.signIn of
                        Just signIn ->
                            [ Html.p [ class "save-signin-line", id "save-signin-line" ]
                                [ Html.text Words.saveSignInLine ]
                            , Html.map SignInMsg (SignIn.view signIn)
                            ]

                        Nothing ->
                            body model
                   )
            )
        ]


body : Model -> List (Html Msg)
body model =
    [ Html.p [ class "save-label" ] [ Html.text "Your sets" ]
    , Html.div [ class "save-sets", id "save-sets" ]
        (case model.sets of
            Loading ->
                [ Html.p [ class "save-quiet", id "save-loading" ] [ Html.text "Finding your sets…" ] ]

            Failed reason ->
                [ Html.p [ class "save-quiet", id "save-failed" ] [ Html.text reason ] ]

            Loaded [] ->
                [ Html.p [ class "save-quiet", id "save-empty" ]
                    [ Html.text "No sets yet. Name one below and this position goes in it." ]
                ]

            Loaded sets ->
                List.map (row model) sets
        )
    , Html.form [ class "save-new", id "save-new", onSubmit SubmittedNew ]
        [ Html.label [ class "save-label", Attr.for newNameId ] [ Html.text "New set" ]
        , Html.div [ class "save-new-row" ]
            [ Html.input
                [ type_ "text"
                , id newNameId
                , Attr.name "name"
                , Attr.value model.name
                , Attr.placeholder "Name a new set"
                , Attr.maxlength 60
                , attribute "autocomplete" "off"
                , class "q-field save-field"
                , onInput NameChanged
                ]
                []
            , Html.button
                [ type_ "submit"
                , id "save-create"
                , class "q-btn save-create pixel"
                , Attr.disabled model.creating
                ]
                [ Html.text "CREATE" ]
            ]
        ]
    , Html.p
        [ id "save-line"
        , class
            (case model.line of
                Refused _ ->
                    "save-line is-refused"

                _ ->
                    "save-line"
            )
        , attribute "aria-live" "polite"
        ]
        [ Html.text
            (case model.line of
                Quiet ->
                    ""

                Said words ->
                    words

                Refused words ->
                    words
            )
        ]
    ]


row : Model -> OwnSet -> Html Msg
row model set =
    Html.button
        [ type_ "button"
        , id ("save-set-" ++ set.id)
        , class
            (if set.holds then
                "save-set is-on"

             else
                "save-set"
            )
        , attribute "role" "checkbox"
        , attribute "aria-checked"
            (if set.holds then
                "true"

             else
                "false"
            )
        , attribute "aria-busy"
            (if List.member set.id model.busy then
                "true"

             else
                "false"
            )
        , onClick (Toggled set.id)
        ]
        [ Html.span [ class "save-check", attribute "aria-hidden" "true" ]
            [ Html.text
                (if set.holds then
                    "✓"

                 else
                    ""
                )
            ]
        , Html.span [ class "save-set-name" ] [ Html.text set.name ]
        , Html.span [ class "save-set-size" ] [ Html.text (Words.positions set.size) ]
        ]
