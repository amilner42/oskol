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

A run started here comes back here (the shell's `next`), so I'M DONE and
a guest's sign-in at the end of a run land on this page again.

**Nothing moves.** Until the answer lands the page holds 320px; after
that, nothing above the fold changes size when a button is pressed (the
card's slots are fixed, as on the practice home).

-}

import Api
import Api.Decks as Decks
import Api.Practice as Practice
import Api.PracticeDecks as PracticeDecks exposing (Deck, Kind(..), Page)
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
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
    }


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

        ( Nothing, Set ) ->
            Stranger


here : Model -> String
here model =
    Route.href (Route.practice model.slug)



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        GotPage (Ok page) ->
            ( { model | page = Loaded page }, Cmd.none, NoOut )

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

        ( Set, Start ) ->
            Just (Decks.join model.session deck.id model.tz (GotSetRun deck which))

        ( Set, KeepGoing ) ->
            Just (PracticeDecks.keepGoingSet model.session deck.id (GotSetRun deck which))

        ( Set, PracticeAnyway ) ->
            Just (PracticeDecks.practiceAnywaySet model.session deck.id (GotSetRun deck which))

        ( Set, NoAction ) ->
            Nothing

        ( Set, _ ) ->
            Just (Decks.fetchSession model.session deck.id (GotSetRun deck which))

        ( Tier, _ ) ->
            Nothing


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
            [ Html.p [ class "dk-mark", Attr.attribute "aria-hidden" "true" ] [ Html.text deck.mark ]
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
        ]


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

                Set ->
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

                            Set ->
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

                    Set ->
                        [ open, Html.text DeckWords.signInRest ]
                )
