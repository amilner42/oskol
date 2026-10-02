module Page.Practice exposing
    ( Model
    , Msg(..)
    , Out(..)
    , init
    , ladder
    , nextInDays
    , title
    , update
    , view
    , visitorOf
    , withSession
    )

{-| `/practice/<slug>` -- one deck's own page, read from one answer
(`GET /papi/practice/decks/:slug`).

A deck is one of five: a tier of the player's own mistakes
(`/practice/very-bad`, `/bad`, `/dubious`) or a universal set
(`/practice/openings`, `/opening-replies`). The practice home can hold one
card and four rows; this is where a deck's whole picture fits:

  - **the card at page size** (`Ui.Deck.card` with `OnPage`): the mark or
    the name, today's ring at 64px, the mastery grid as wide as the page
    with a square per position in the deck's own order, its legend ("to
    learn · level 1 · 2 · 3 · mastered", for a set as for a tier), the state
    line, and the one button with its line -- the practice home's own
    state machine (TRAIN / KEEP GOING / PRACTICE ANYWAY /
    START / TRY);
  - **where they stand**: the ladder in words ("8 at level 1, 5 at level
    2, 3 at level 3.") and what is due ("12 due now · 3 new today", or
    "Nothing due. Next due tomorrow.");
  - **the last thirty days**, a square a day, and how many had practice;
  - for a tier with graded games behind it, **what it cost** in PR, and
    what patching has won back of it, in the green.

A guest on a tier page reads their count, every square paper, PRACTICE
and the sign-in line; a stranger on one reads one line and the way back.
Anybody on a set they have not added gets its size, the grid all paper,
and START (an account) or TRY (anybody else, with "Sign in to keep your
place in these.").

**An account's own set** (`/practice/<id>`, its owner's only; anybody
else gets the same 404 as a set that is not there) is the same card --
OPEN ANALYSIS in the button's slot while there is nothing in it -- and
**MANAGE** under it: the name, renamed in place (`PATCH /papi/decks/:id`);
its positions as a list, each a small still board of the question, the
prompt, where it stands ("to learn", "level 2", "mastered") and an x that
takes it out (`DELETE /papi/decks/:id/puzzles/:pid`); and DELETE SET,
which asks once in place ("Delete Openings I like? ...", YES, DELETE) and
then goes back to `/puzzles`.

A run started here comes back here (the shell's `next`), so I'M DONE and
a guest's sign-in at the end of a run land on this page again.

**Nothing moves.** Until the answer lands the page holds 320px; after
that, nothing above the fold changes size when a button is pressed (the
card's slots are fixed, as on the practice home).

-}

import Api
import Api.Decks as Decks
import Api.Practice as Practice
import Api.PracticeDecks as PracticeDecks exposing (Deck, Kind(..), Member, Page)
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..))
import Games.Backgammon.View as Board
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick, onInput, onSubmit)
import Route
import Session exposing (Session)
import Task
import Time
import Ui.Charts as Charts
import Ui.Deck as Deck exposing (Action(..), Who(..))
import Ui.Decks as DeckWords
import Ui.Mistakes as Mistakes
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn



-- MODEL


type alias Model =
    { session : Session
    , tz : String -- the browser's IANA zone, "" when it could not say: START sends it
    , slug : String
    , page : Loadable
    , busy : Bool
    , signIn : Maybe SignIn.Model
    , note : Maybe String -- what the last press came back with, when it was not a run
    , now : Maybe Time.Posix -- for "next due in 3 days"
    , manage : Manage
    }


{-| MANAGE, on an own set's page: the name being typed, the presses on
their way, and the delete's confirm.
-}
type alias Manage =
    { name : String
    , renaming : Bool
    , removing : List String -- the positions on their way out
    , confirming : Bool -- DELETE SET was pressed: the confirm is up
    , deleting : Bool
    , line : Maybe String -- why the last press did not go through, or "Renamed."
    }


noManage : Manage
noManage =
    { name = "", renaming = False, removing = [], confirming = False, deleting = False, line = Nothing }


type Loadable
    = Loading
    | Loaded Page
    | Unavailable String


type Msg
    = GotPage (Result Api.Error Page)
    | GotNow Time.Posix
    | Pressed Deck Action
    | GotTierRun Deck Action (Result Api.Error Practice.Practice)
    | GotSetRun Deck Action (Result Api.Error Decks.Session)
    | OpenedSignIn
    | SignInMsg SignIn.Msg
    | RenameInput String
    | SubmittedRename
    | GotRenamed (Result Api.Error Decks.OwnSet)
    | PressedRemove String
    | GotRemoved String (Result Api.Error Decks.OwnSet)
    | PressedDelete
    | CancelledDelete
    | ConfirmedDelete
    | GotDeleted (Result Api.Error ())
    | NoOp


{-| What the shell does for the page: the practice home's own, so a run
started here is the same run. The shell starts it with this page as
where it comes back to.
-}
type Out
    = NoOut
    | StartRun (List String) (Maybe Practice.Today) (Maybe String) Deck.Begun
    | StartDeckRun (List String) (Maybe Practice.Today) Decks.Named Deck.Begun
    | Go String
    | SignedIn (Maybe Session.User)


init : Session -> { tz : String, slug : String } -> ( Model, Cmd Msg )
init session config =
    ( { session = session
      , tz = config.tz
      , slug = config.slug
      , page = Loading
      , busy = False
      , signIn = Nothing
      , note = Nothing
      , now = Nothing
      , manage = noManage
      }
    , Cmd.batch
        [ PracticeDecks.fetchDeck session config.slug GotPage
        , Task.perform GotNow Time.now
        ]
    )


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


title : Model -> String
title model =
    case model.page of
        Loaded page ->
            page.deck.name ++ " · Practice"

        _ ->
            "Practice"


{-| Who is looking, read off the answer: an account has a standing on
every deck; anybody else is a guest where the tier holds mistakes of
theirs, and a stranger where it does not (on a set the two are one).
-}
visitorOf : Page -> Who
visitorOf page =
    case ( page.deck.standing, page.deck.kind ) of
        ( Just _, _ ) ->
            Account

        ( Nothing, Tier ) ->
            if page.deck.size > 0 then
                Guest

            else
                Stranger

        ( Nothing, _ ) ->
            Stranger


here : Model -> String
here model =
    Route.href (Route.practice model.slug)



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        GotPage (Ok page) ->
            let
                manage =
                    model.manage
            in
            ( { model
                | page = Loaded page
                , manage =
                    -- The name field starts as the name, and follows a
                    -- refetch unless the player is typing in it.
                    if manage.name == "" || not (isLoaded model.page) then
                        { manage | name = page.deck.name }

                    else
                        manage
              }
            , Cmd.none
            , NoOut
            )

        GotPage (Err err) ->
            case model.page of
                -- A refetch that failed leaves the page it had.
                Loaded _ ->
                    ( model, Cmd.none, NoOut )

                _ ->
                    ( { model | page = Unavailable (Api.errorMessage err) }, Cmd.none, NoOut )

        GotNow now ->
            ( { model | now = Just now }, Cmd.none, NoOut )

        Pressed deck which ->
            if model.busy then
                ( model, Cmd.none, NoOut )

            else
                case request model deck which of
                    Just cmd ->
                        ( { model | busy = True, note = Nothing }, cmd, NoOut )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        GotTierRun deck which (Ok practice) ->
            case practice.puzzles of
                -- Answered between the two calls (another tab): say so,
                -- and ask for the page again.
                [] ->
                    ( { model | busy = False, note = Just nothingMoreLine }
                    , PracticeDecks.fetchDeck model.session model.slug GotPage
                    , NoOut
                    )

                entries ->
                    ( { model | busy = False }
                    , Cmd.none
                    , StartRun (List.map .id entries) practice.today (Just deck.id) (Deck.begun deck which (List.length entries))
                    )

        GotSetRun deck which (Ok session) ->
            case session.puzzles of
                [] ->
                    ( { model | busy = False, note = Just nothingMoreLine }
                    , PracticeDecks.fetchDeck model.session model.slug GotPage
                    , NoOut
                    )

                entries ->
                    ( { model | busy = False }
                    , Cmd.none
                    , StartDeckRun (List.map .id entries) session.today (PracticeDecks.named deck) (Deck.begun deck which (List.length entries))
                    )

        GotTierRun _ _ (Err err) ->
            ( { model | busy = False, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        GotSetRun _ _ (Err err) ->
            ( { model | busy = False, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        OpenedSignIn ->
            case model.signIn of
                Nothing ->
                    let
                        ( signIn, cmd ) =
                            SignIn.init { next = here model, email = "" }
                    in
                    ( { model | signIn = Just signIn }, Cmd.map SignInMsg cmd, NoOut )

                Just _ ->
                    ( model, Cmd.none, NoOut )

        SignInMsg signInMsg ->
            case model.signIn of
                Just signIn ->
                    let
                        ( next, cmd, out ) =
                            SignIn.update model.session signInMsg signIn

                        updated =
                            { model | signIn = Just next }
                    in
                    case out of
                        SignIn.NoOut ->
                            ( updated, Cmd.map SignInMsg cmd, NoOut )

                        -- Signed in: the games that came along are filling
                        -- the mistakes. Ask again, and tell the shell.
                        SignIn.SignedIn result ->
                            ( updated
                            , Cmd.batch
                                [ Cmd.map SignInMsg cmd
                                , PracticeDecks.fetchDeck model.session model.slug GotPage
                                ]
                            , SignedIn result.user
                            )

                        SignIn.Continue path ->
                            ( { updated | signIn = Nothing }, Cmd.none, Go path )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        RenameInput name ->
            withManage (\m -> { m | name = name, line = Nothing }) model

        SubmittedRename ->
            case model.page of
                Loaded page ->
                    if model.manage.renaming || String.trim model.manage.name == page.deck.name then
                        ( model, Cmd.none, NoOut )

                    else
                        let
                            ( next, _, _ ) =
                                withManage (\m -> { m | renaming = True, line = Nothing }) model
                        in
                        ( next, Decks.renameOwn model.session page.deck.id model.manage.name GotRenamed, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        GotRenamed (Ok set) ->
            let
                ( next, _, _ ) =
                    withManage (\m -> { m | renaming = False, name = set.name, line = Just "Renamed." }) model
            in
            ( { next | page = mapPage (\page -> { page | deck = renamed set.name page.deck }) next.page }, Cmd.none, NoOut )

        GotRenamed (Err err) ->
            withManage (\m -> { m | renaming = False, line = Just (Api.errorMessage err) }) model

        PressedRemove puzzleId ->
            case model.page of
                Loaded page ->
                    if List.member puzzleId model.manage.removing then
                        ( model, Cmd.none, NoOut )

                    else
                        let
                            ( next, _, _ ) =
                                withManage (\m -> { m | removing = puzzleId :: m.removing, line = Nothing }) model
                        in
                        ( next, Decks.removePuzzle model.session page.deck.id puzzleId (GotRemoved puzzleId), NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        -- Out: the row goes, and the page is read again for the card's
        -- numbers (its grid, its ring, its state line).
        GotRemoved puzzleId (Ok _) ->
            let
                ( next, _, _ ) =
                    withManage (\m -> { m | removing = List.filter ((/=) puzzleId) m.removing }) model
            in
            ( { next | page = mapPage (withoutMember puzzleId) next.page }
            , PracticeDecks.fetchDeck model.session model.slug GotPage
            , NoOut
            )

        GotRemoved puzzleId (Err err) ->
            withManage (\m -> { m | removing = List.filter ((/=) puzzleId) m.removing, line = Just (Api.errorMessage err) }) model

        PressedDelete ->
            withManage (\m -> { m | confirming = True, line = Nothing }) model

        CancelledDelete ->
            withManage (\m -> { m | confirming = False }) model

        ConfirmedDelete ->
            case model.page of
                Loaded page ->
                    if model.manage.deleting then
                        ( model, Cmd.none, NoOut )

                    else
                        let
                            ( next, _, _ ) =
                                withManage (\m -> { m | deleting = True }) model
                        in
                        ( next, Decks.deleteOwn model.session page.deck.id GotDeleted, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        -- Gone: back to the practice home, where it no longer is.
        GotDeleted (Ok ()) ->
            ( model, Cmd.none, Go (Route.href Route.puzzles) )

        GotDeleted (Err err) ->
            withManage (\m -> { m | deleting = False, confirming = False, line = Just (Api.errorMessage err) }) model

        NoOp ->
            ( model, Cmd.none, NoOut )


withManage : (Manage -> Manage) -> Model -> ( Model, Cmd Msg, Out )
withManage f model =
    ( { model | manage = f model.manage }, Cmd.none, NoOut )


isLoaded : Loadable -> Bool
isLoaded loadable =
    case loadable of
        Loaded _ ->
            True

        _ ->
            False


mapPage : (Page -> Page) -> Loadable -> Loadable
mapPage f loadable =
    case loadable of
        Loaded page ->
            Loaded (f page)

        other ->
            other


renamed : String -> Deck -> Deck
renamed name deck =
    { deck | name = name }


withoutMember : String -> Page -> Page
withoutMember puzzleId page =
    { page | members = Maybe.map (List.filter (\m -> m.id /= puzzleId)) page.members }


{-| What each button asks the server for: the practice home's own
requests, so the same press is the same run from either page.
-}
request : Model -> Deck -> Action -> Maybe (Cmd Msg)
request model deck which =
    case ( deck.kind, which ) of
        ( Tier, FixOne ) ->
            Just (Practice.fetchBand model.session deck.id (GotTierRun deck which))

        ( Tier, Practice ) ->
            Just (Practice.fetchBand model.session deck.id (GotTierRun deck which))

        ( Tier, KeepGoing ) ->
            Just (PracticeDecks.keepGoing model.session deck.id (GotTierRun deck which))

        ( Tier, PracticeAnyway ) ->
            Just (PracticeDecks.practiceAnyway model.session deck.id (GotTierRun deck which))

        ( Tier, _ ) ->
            Nothing

        -- A set, the universal ones and an account's own alike.
        ( _, Start ) ->
            Just (Decks.join model.session deck.id model.tz (GotSetRun deck which))

        ( _, KeepGoing ) ->
            Just (PracticeDecks.keepGoingSet model.session deck.id (GotSetRun deck which))

        ( _, PracticeAnyway ) ->
            Just (PracticeDecks.practiceAnywaySet model.session deck.id (GotSetRun deck which))

        ( _, NoAction ) ->
            Nothing

        -- A link, not a press.
        ( _, OpenAnalysis ) ->
            Nothing

        ( _, _ ) ->
            Just (Decks.fetchSession model.session deck.id (GotSetRun deck which))


nothingMoreLine : String
nothingMoreLine =
    "That's every one of these for now. The ones you get wrong come back on their day."



-- READING THE CELLS


{-| How many started positions sit on each rung, lowest first: what the
ladder in words is said from. A position never shown, or one put away,
is on no rung.
-}
ladder : Page -> List Int
ladder page =
    let
        started =
            List.filter (\cell -> cell.status == "active") page.cells
    in
    List.range 0 7
        |> List.map (\rung -> List.length (List.filter (\cell -> cell.level == rung) started))


{-| When the next position in rotation comes due, in whole days from
`now` (at least one: a position due already is today's work, which the
due line says first). Nothing in rotation, nothing to say.
-}
nextInDays : Time.Posix -> Page -> Maybe Int
nextInDays now page =
    let
        nowMs =
            Time.posixToMillis now
    in
    page.cells
        |> List.filter (\cell -> cell.status == "active")
        |> List.map .due
        |> List.minimum
        |> Maybe.map (\due -> max 1 (ceiling (toFloat (due - nowMs) / 86400000)))



-- VIEW


view : Model -> Html Msg
view model =
    Html.section
        [ class "pz-hub dp-page mx-auto q-card sheet", id "practice-page" ]
        (Html.a [ Attr.href (Route.href Route.puzzles), class "dp-back", id "practice-back" ]
            [ Html.span [ Attr.attribute "aria-hidden" "true" ] [ Html.text "←" ], Html.text "Puzzles" ]
            :: Notebook.eyebrow "PRACTICE"
            :: (case model.page of
                    Loading ->
                        [ Html.div [ class "dp-loading", id "practice-loading" ] [] ]

                    Unavailable reason ->
                        [ Html.p [ class "pz-hub-line", id "practice-unavailable" ] [ Html.text reason ] ]

                    Loaded page ->
                        body model page
               )
        )


body : Model -> Page -> List (Html Msg)
body model page =
    let
        deck =
            page.deck

        who =
            visitorOf page
    in
    if deck.kind == Tier && Deck.action who deck == NoAction then
        -- Nothing of theirs here: a stranger, or an account with no
        -- mistake of this kind yet. One line and the way back.
        [ Html.div [ class "dp-empty", id "practice-empty" ]
            [ Html.p [ class ("dk-mark " ++ Mistakes.markClass deck.id), Attr.attribute "aria-hidden" "true" ] [ Html.text deck.mark ]
            , Html.h2 [ class "dk-name" ] [ Html.text deck.name ]
            , Html.p [ class "pz-hub-line dp-empty-line", id "practice-empty-line" ]
                [ Html.text
                    (if who == Account then
                        Mistakes.emptyTierLine deck.id

                     else
                        Mistakes.strangerTierLine
                    )
                ]
            , Html.a
                [ Attr.href (Route.href Route.puzzles), class "q-btn dk-go dp-way-back", id "practice-way-back" ]
                [ Html.text "BACK TO PUZZLES" ]
            ]
        ]

    else
        [ if who == Guest then
            Html.p [ class "pz-hub-line dp-unsaved", id "practice-unsaved" ] [ Html.text Mistakes.unsavedLine ]

          else
            Html.text ""
        , Deck.card
            { who = who
            , deck = deck
            , patchedLevel = page.patchedLevel
            , busy = model.busy
            , pressed = model.busy
            , note = model.note
            , onPress = Pressed deck
            , prefix = "practice"
            , open = Nothing
            , squares = Just (List.map (\cell -> { level = cell.level, status = cell.status }) page.cells)
            , size = Deck.OnPage
            }
        , if who == Account && (deck.kind == Tier || deck.joined) then
            details model page

          else
            Html.text ""
        , if who == Account then
            Html.text ""

          else
            signInLine model deck
        , case ( deck.kind, page.members ) of
            ( Own, Just members ) ->
                viewManage model page members

            _ ->
                Html.text ""
        ]


{-| MANAGE, under an own set's card: the name, the positions, DELETE SET.
-}
viewManage : Model -> Page -> List Member -> Html Msg
viewManage model page members =
    let
        manage =
            model.manage

        started id =
            page.cells
                |> List.filter (\cell -> cell.id == id)
                |> List.any (\cell -> cell.status == "active")
    in
    Html.section [ class "dp-manage", id "practice-manage" ]
        [ Html.h3 [ class "dp-head" ] [ Html.text "Manage" ]
        , Html.form [ class "dp-rename", id "practice-rename-form", onSubmit SubmittedRename ]
            [ Html.label [ class "sr-only", Attr.for "practice-rename" ] [ Html.text "The set's name" ]
            , Html.input
                [ Attr.type_ "text"
                , id "practice-rename"
                , Attr.value manage.name
                , Attr.maxlength 60
                , Attr.attribute "autocomplete" "off"
                , class "q-field dp-rename-field"
                , onInput RenameInput
                ]
                []
            , Html.button
                [ Attr.type_ "submit"
                , id "practice-rename-save"
                , class "q-btn plain dp-rename-save pixel"
                , Attr.disabled (manage.renaming || String.trim manage.name == page.deck.name)
                ]
                [ Html.text "RENAME" ]
            ]
        , Html.p [ class "dp-manage-line", id "practice-manage-line", Attr.attribute "aria-live" "polite" ]
            [ Html.text (Maybe.withDefault "" manage.line) ]
        , if List.isEmpty members then
            Html.p [ class "dp-members-empty", id "practice-members-empty" ] [ Html.text DeckWords.emptyOwnLine ]

          else
            Html.ul [ class "dp-members", id "practice-members" ]
                (List.map
                    (\member ->
                        viewMember model
                            { member = member
                            , word =
                                DeckWords.levelWord
                                    { level = member.level
                                    , started = started member.id
                                    , patchedLevel = page.patchedLevel
                                    }
                            , removing = List.member member.id manage.removing
                            }
                    )
                    members
                )
        , Html.div [ class "dp-delete", id "practice-delete-slot" ]
            (if manage.confirming then
                [ Html.p [ class "dp-delete-question", id "practice-delete-question" ]
                    [ Html.text (DeckWords.deleteQuestion page.deck.name) ]
                , Html.div [ class "dp-delete-row" ]
                    [ Html.button
                        [ Attr.type_ "button"
                        , id "practice-delete-yes"
                        , class "q-btn dp-delete-yes pixel"
                        , Attr.disabled manage.deleting
                        , onClick ConfirmedDelete
                        ]
                        [ Html.text "YES, DELETE" ]
                    , Html.button
                        [ Attr.type_ "button"
                        , id "practice-delete-no"
                        , class "q-btn plain dp-delete-no pixel"
                        , onClick CancelledDelete
                        ]
                        [ Html.text "KEEP IT" ]
                    ]
                ]

             else
                [ Html.button
                    [ Attr.type_ "button"
                    , id "practice-delete"
                    , class "q-btn plain dp-delete-btn pixel"
                    , onClick PressedDelete
                    ]
                    [ Html.text "DELETE SET" ]
                ]
            )
        ]


viewMember : Model -> { member : Member, word : String, removing : Bool } -> Html Msg
viewMember model row =
    let
        member =
            row.member
    in
    Html.li [ class "dp-member", id ("practice-member-" ++ member.id), Attr.attribute "data-puzzle" member.id ]
        [ Html.a
            [ Attr.href (Route.href (Route.puzzle member.id))
            , class "dp-member-open"
            , Attr.attribute "aria-label" ("Open this puzzle: " ++ member.prompt)
            ]
            [ Html.span [ class "dp-member-board", Attr.attribute "aria-hidden" "true" ]
                [ case member.question of
                    Just question ->
                        Board.viewStill NoOp (stillOf model member.kind question)

                    Nothing ->
                        Html.text ""
                ]
            , Html.span [ class "dp-member-text" ]
                [ Html.span [ class "dp-member-prompt" ] [ Html.text member.prompt ]
                , Html.span [ class "dp-member-level" ] [ Html.text row.word ]
                ]
            ]
        , Html.button
            [ Attr.type_ "button"
            , id ("practice-remove-" ++ member.id)
            , class "dp-member-remove"
            , Attr.disabled row.removing
            , Attr.attribute "aria-label" "Take this position out of the set"
            , Attr.title "Take it out"
            , onClick (PressedRemove member.id)
            ]
            [ Html.text "✕" ]
        ]


{-| A position as its puzzle page shows it, as a still board: White, the
one asked, at the bottom.
-}
stillOf : Model -> String -> Puzzle.Question -> Board.StillBoard
stillOf model kind question =
    let
        setup =
            Setup.fromQuestion kind question
    in
    { players =
        [ { id = Setup.colorId White, name = "", color = "white" }
        , { id = Setup.colorId Black, name = "", color = "black" }
        ]
    , viewer = Setup.colorId White
    , scores = []
    , cube = True
    , theme = Session.pref "backgammon_theme" model.session |> Maybe.withDefault Board.defaultTheme
    , key = 0
    , position = Setup.snapshot setup
    , mover = Just (Setup.colorId White)
    , dice =
        case setup.ask of
            Move (Just ( a, b )) ->
                [ a, b ]

            _ ->
                []
    , landed = []
    , offer =
        case setup.ask of
            Take ->
                Just (Setup.colorId Black)

            _ ->
                Nothing
    , accounts = Nothing
    }


{-| Under the card, for a deck the player has: where its positions
stand, the month, and -- for a tier -- what it cost.
-}
details : Model -> Page -> Html Msg
details model page =
    let
        deck =
            page.deck

        standing =
            deck.standing

        ladderWords =
            (case deck.kind of
                Tier ->
                    Mistakes.ladderLine

                _ ->
                    DeckWords.ladderLine
            )
                { patchedLevel = page.patchedLevel, started = ladder page }

        due =
            Mistakes.dueLine
                { due = standing |> Maybe.map .due |> Maybe.withDefault 0
                , newLeft = standing |> Maybe.map .newLeft |> Maybe.withDefault 0
                , nextInDays = model.now |> Maybe.andThen (\now -> nextInDays now page)
                }
    in
    Html.div [ class "dp-details", id "practice-details" ]
        [ Html.div [ class "dp-block", id "practice-standing" ]
            [ Html.h3 [ class "dp-head" ] [ Html.text "Where they stand" ]
            , Html.p [ class "dp-ladder", id "practice-ladder" ]
                [ Html.text
                    (if ladderWords == "" then
                        "Nothing started yet."

                     else
                        ladderWords
                    )
                ]
            , Html.p [ class "dp-due", id "practice-due" ] [ Html.text due ]
            ]
        , Html.div [ class "dp-block", id "practice-month" ]
            [ Html.h3 [ class "dp-head" ] [ Html.text "The last 30 days" ]
            , Html.div [ class "dp-days" ] [ Charts.days page.days ]
            , Html.p [ class "dp-days-line", id "practice-days-line" ] [ Html.text (Charts.daysSentence (lastThirty page.days)) ]
            ]
        , case deck.cost of
            Just cost ->
                if cost.games > 0 then
                    Html.div [ class "dp-block dp-cost-block", id "practice-cost-block" ]
                        [ Html.h3 [ class "dp-head" ] [ Html.text "What they cost" ]
                        , Deck.costLines
                            { who = Account
                            , deck = deck
                            , patchedLevel = page.patchedLevel
                            , busy = False
                            , pressed = False
                            , note = Nothing
                            , onPress = Pressed deck
                            , prefix = "practice"
                            , open = Nothing
                            , squares = Nothing
                            , size = Deck.OnPage
                            }
                            deck
                        ]

                else
                    Html.text ""

            Nothing ->
                Html.text ""
        ]


lastThirty : List Bool -> List Bool
lastThirty marks =
    let
        padded =
            List.repeat 30 False ++ marks
    in
    List.drop (List.length padded - 30) padded


{-| For anybody without an account: one line, and the one component when
pressed. Coming back from it lands on this page.
-}
signInLine : Model -> Deck -> Html Msg
signInLine model deck =
    case model.signIn of
        Just signIn ->
            Html.div [ id "practice-signin", class "pitch mt-6 pt-5" ]
                [ Html.p [ class "q-note text-[13px] leading-snug text-center mb-3" ]
                    [ Html.text
                        (case deck.kind of
                            Tier ->
                                "Sign in and we'll keep this: these come back until you stop making them."

                            _ ->
                                DeckWords.endSignIn
                        )
                    ]
                , Html.map SignInMsg (SignIn.view signIn)
                ]

        Nothing ->
            let
                open =
                    Html.button
                        [ Attr.type_ "button", id "practice-signin-open", class "signin-link", onClick OpenedSignIn ]
                        [ Html.text "Sign in" ]
            in
            Html.p [ class "pz-hub-signin q-note", id "practice-signin-line" ]
                (case deck.kind of
                    Tier ->
                        [ Html.text "Signed in, these come back until you stop making them. ", open ]

                    _ ->
                        [ open, Html.text DeckWords.signInRest ]
                )
