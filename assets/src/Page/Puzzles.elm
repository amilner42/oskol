module Page.Puzzles exposing
    ( Begun
    , Model
    , Msg(..)
    , Out(..)
    , Visitor(..)
    , front
    , init
    , title
    , update
    , view
    , visitor
    , withSession
    )

{-| `/puzzles` -- the practice home: five decks, one in front and four
behind it, read from one answer (`GET /papi/practice/decks`).

The five are the three tiers of the player's own mistakes (`??` very bad,
`?` bad, `?!` dubious) and the two universal sets (the openings, the
replies to them). Each is drawn the one way (`Ui.Deck`): in front, a card
with its mastery grid -- a square per position, coloured by its rung --
today's ring, its state in words, what it cost, and one button; behind,
a row each with its ring and how many are left, tapped to come in front.

Three visitors, one page:

  - an **account**: how long they have kept at it and what today has come
    to, what their mistakes cost them in PR, then the deck the server
    leads with (the worst tier with work, else a set with work, else the
    worst tier there is) -- or the one they tapped -- and the other four.
    A fresh account with no mistakes yet has the openings in front.
  - a **guest** with games behind them: "23 mistakes from your 4 games",
    that nothing is kept until they sign in, their worst tier in front
    with PRACTICE, the rest as rows (a set says TRY), and the sign-in line.
  - a **stranger**: what this is, TRY ONE, and the five as rows -- their
    tiers quiet (nothing of theirs yet), the sets to try.

Every press starts a run the shell owns (`StartRun` with the tier,
`StartDeckRun` with the set) and comes back here when it ends. KEEP GOING
asks for the deck's pace again and runs it; PRACTICE ANYWAY asks for what
is in rotation, soonest due first.

-}

import Api
import Api.Decks as Decks
import Api.Practice as Practice
import Api.PracticeDecks as PracticeDecks exposing (Catalog, Deck, Kind(..))
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Route
import Session exposing (Session)
import Svg
import Svg.Attributes as SvgA
import Ui.Charts as Charts
import Ui.Deck as Deck exposing (Action(..), Who(..))
import Ui.Mistakes as Mistakes
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn



-- MODEL


type alias Model =
    { session : Session
    , tz : String -- the browser's IANA zone, "" when it could not say
    , catalog : Loadable
    , tzSent : Bool
    , busy : Busy
    , signIn : Maybe SignIn.Model -- the early sign-in, once opened
    , note : Maybe String -- what the last press came back with, when it was not a run
    , picked : Maybe String -- the deck the player tapped into the front, if they did
    , layout : Layout -- EXPERIMENT (local only): how the five decks are laid out
    , gridsOpen : List String -- EXPERIMENT: the cards whose grid is shown (Cards layout)
    }


{-| EXPERIMENT, local only: three ways to lay out the five decks, to be
compared in the browser before one is chosen.
-}
type Layout
    = Promote
    | Drawers
    | Cards


type Loadable
    = Loading
    | Loaded Catalog
    | Unavailable String


{-| Which press is in flight, so it cannot be pressed twice.
-}
type Busy
    = Idle
    | Trying
    | Starting String -- a deck's button, by deck id


{-| The three visitors, read off the server's answer: an account has a
day, a guest has mistakes of their own, a stranger has neither.
-}
type Visitor
    = AnAccount
    | AGuest PracticeDecks.Mistakes
    | AStranger


type Msg
    = GotCatalog (Result Api.Error Catalog)
    | PickedDeck String
    | PickedLayout Layout
    | ToggledGrid String
    | Pressed Deck Action
    | GotTierRun Deck Action (Result Api.Error Practice.Practice)
    | GotSetRun Deck Action (Result Api.Error Decks.Session)
    | PressedTryOne
    | GotRandom (Result Api.Error Practice.Random)
    | TimezoneSent (Result Api.Error ())
    | OpenedSignIn
    | SignInMsg SignIn.Msg


{-| What the shell does for the page: start a run of these puzzles, go
somewhere, or take note of a sign-in.
-}
type Out
    = NoOut
    | StartRun (List String) (Maybe Practice.Today) (Maybe String) Begun
    | StartDeckRun (List String) (Maybe Practice.Today) Decks.Named Begun
    | Go String
    | SignedIn (Maybe Session.User)


{-| What the run is told of the deck it was started from (`Ui.Deck.begun`).
-}
type alias Begun =
    Deck.Begun


init : Session -> { tz : String } -> ( Model, Cmd Msg )
init session config =
    ( { session = session
      , tz = config.tz
      , catalog = Loading
      , tzSent = False
      , busy = Idle
      , signIn = Nothing
      , note = Nothing
      , picked = Nothing
      , layout = Cards
      , gridsOpen = []
      }
    , PracticeDecks.fetchList session GotCatalog
    )


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


title : Model -> String
title _ =
    "Puzzles"


visitor : Catalog -> Visitor
visitor catalog =
    case ( catalog.today, catalog.mistakes ) of
        ( Just _, _ ) ->
            AnAccount

        ( Nothing, Just mistakes ) ->
            if mistakes.puzzles > 0 then
                AGuest mistakes

            else
                AStranger

        ( Nothing, Nothing ) ->
            AStranger


who : Visitor -> Who
who v =
    case v of
        AnAccount ->
            Account

        AGuest _ ->
            Guest

        AStranger ->
            Stranger


{-| The deck in front: the one the player tapped, while it is still one
that can be; else the server's lead; else, for an account with nothing
of its own yet, the first set -- so there is always a button that starts
practice. A stranger has nothing in front until they tap a set.
-}
front : Maybe String -> Catalog -> Maybe Deck
front picked catalog =
    let
        v =
            visitor catalog

        frontable deck =
            Deck.action (who v) deck /= NoAction

        byId id =
            catalog.decks |> List.filter (\deck -> deck.id == id && frontable deck) |> List.head

        fallback =
            case v of
                AnAccount ->
                    catalog.decks |> List.filter PracticeDecks.isSet |> List.head

                AGuest _ ->
                    catalog.decks |> List.filter (\deck -> deck.kind == Tier && deck.size > 0) |> List.head

                AStranger ->
                    Nothing
    in
    case Maybe.andThen byId picked of
        Just deck ->
            Just deck

        Nothing ->
            case Maybe.andThen byId catalog.lead of
                Just deck ->
                    Just deck

                Nothing ->
                    if v == AStranger then
                        Nothing

                    else
                        fallback



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        GotCatalog (Ok catalog) ->
            -- The day is the player's, not UTC's: told once per visit, and
            -- only where there is an account to keep it on. Marked sent as
            -- it goes, so a refetch racing the answer cannot send it twice.
            if catalog.today /= Nothing && model.tz /= "" && not model.tzSent then
                ( { model | catalog = Loaded catalog, tzSent = True }
                , Practice.sendTimezone model.session model.tz TimezoneSent
                , NoOut
                )

            else
                ( { model | catalog = Loaded catalog }, Cmd.none, NoOut )

        GotCatalog (Err err) ->
            case model.catalog of
                -- A refetch that failed leaves the page it had.
                Loaded _ ->
                    ( model, Cmd.none, NoOut )

                _ ->
                    ( { model | catalog = Unavailable (Api.errorMessage err) }, Cmd.none, NoOut )

        TimezoneSent _ ->
            ( model, Cmd.none, NoOut )

        -- A row: that deck comes in front. Nothing is fetched -- every
        -- deck's numbers came with the page.
        PickedLayout layout ->
            ( { model | layout = layout }, Cmd.none, NoOut )

        ToggledGrid id ->
            ( { model
                | gridsOpen =
                    if List.member id model.gridsOpen then
                        List.filter ((/=) id) model.gridsOpen

                    else
                        id :: model.gridsOpen
              }
            , Cmd.none
            , NoOut
            )

        PickedDeck id ->
            ( { model | picked = Just id, note = Nothing }, Cmd.none, NoOut )

        Pressed deck which ->
            if model.busy /= Idle then
                ( model, Cmd.none, NoOut )

            else
                case request model deck which of
                    Just cmd ->
                        ( { model | busy = Starting deck.id, note = Nothing }, cmd, NoOut )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        GotTierRun deck which (Ok practice) ->
            case practice.puzzles of
                -- The deck said it had something and the queue came back
                -- empty: it was answered between the two calls (another
                -- tab). Say so, and ask for the page again.
                [] ->
                    ( { model | busy = Idle, note = Just nothingMoreLine }
                    , PracticeDecks.fetchList model.session GotCatalog
                    , NoOut
                    )

                entries ->
                    ( { model | busy = Idle }
                    , Cmd.none
                    , StartRun (List.map .id entries) practice.today (Just deck.id) (Deck.begun deck which (List.length entries))
                    )

        GotSetRun deck which (Ok session) ->
            case session.puzzles of
                [] ->
                    ( { model | busy = Idle, note = Just nothingMoreLine }
                    , PracticeDecks.fetchList model.session GotCatalog
                    , NoOut
                    )

                entries ->
                    ( { model | busy = Idle }
                    , Cmd.none
                    , StartDeckRun (List.map .id entries) session.today (PracticeDecks.named deck) (Deck.begun deck which (List.length entries))
                    )

        GotTierRun _ _ (Err err) ->
            ( { model | busy = Idle, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        GotSetRun _ _ (Err err) ->
            ( { model | busy = Idle, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        PressedTryOne ->
            if model.busy == Idle then
                ( { model | busy = Trying, note = Nothing }, Practice.random model.session GotRandom, NoOut )

            else
                ( model, Cmd.none, NoOut )

        GotRandom (Ok puzzle) ->
            ( { model | busy = Idle }, Cmd.none, Go (Route.href (Route.puzzle puzzle.id)) )

        -- A 404 is the pool having nothing to offer yet, and says so in a
        -- sentence; anything else is shown as it came.
        GotRandom (Err err) ->
            ( { model | busy = Idle, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        OpenedSignIn ->
            case model.signIn of
                Nothing ->
                    let
                        ( signIn, cmd ) =
                            SignIn.init { next = Route.href Route.puzzles, email = "" }
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

                        -- Signed in: the mistakes are being filled from the
                        -- games that came along. Ask again, and tell the shell.
                        SignIn.SignedIn result ->
                            ( updated
                            , Cmd.batch
                                [ Cmd.map SignInMsg cmd
                                , PracticeDecks.fetchList model.session GotCatalog
                                ]
                            , SignedIn result.user
                            )

                        SignIn.Continue path ->
                            ( { updated | signIn = Nothing }, Cmd.none, Go path )

                Nothing ->
                    ( model, Cmd.none, NoOut )


{-| What each button asks the server for. Every answer is a run's list;
a tier's is a session of that tier, a set's the set's session.
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

        ( Set, _ ) ->
            if which == NoAction then
                Nothing

            else
                Just (Decks.fetchSession model.session deck.id (GotSetRun deck which))

        ( Tier, _ ) ->
            Nothing


nothingMoreLine : String
nothingMoreLine =
    "That's every one of these for now. The ones you get wrong come back on their day."



-- VIEW


view : Model -> Html Msg
view model =
    case ( model.layout, model.catalog ) of
        ( Cards, Loaded catalog ) ->
            Html.section [ class "pz-cards mx-auto", id "puzzles-hub" ]
                (Html.div [ class "pz-cards-head" ]
                    (Notebook.eyebrow "PUZZLES" :: layoutSwitch model :: headLines model catalog (visitor catalog) (front model.picked catalog))
                    :: [ Html.div [ class "pz-cards-grid", id "hub-cards" ]
                            (List.map (compactCard model catalog) catalog.decks)
                       , case visitor catalog of
                            AnAccount ->
                                Html.text ""

                            _ ->
                                Html.div [ class "pz-cards-head" ] [ signInLine model ]
                       ]
                )

        _ ->
            viewSheet model


viewSheet : Model -> Html Msg
viewSheet model =
    Html.section
        [ class "pz-hub mx-auto q-card sheet", id "puzzles-hub" ]
        (Notebook.eyebrow "PUZZLES"
            :: (case model.catalog of
                    Loading ->
                        [ Html.div [ class "pz-hub-loading", id "hub-loading" ] [] ]

                    Unavailable reason ->
                        [ Html.p [ class "pz-hub-line", id "hub-unavailable" ] [ Html.text reason ] ]

                    Loaded catalog ->
                        body model catalog
               )
        )


body : Model -> Catalog -> List (Html Msg)
body model catalog =
    layoutSwitch model
        :: (case model.layout of
                Promote ->
                    bodyPromote model catalog

                Drawers ->
                    bodyDrawers model catalog

                Cards ->
                    bodyDrawers model catalog
           )


{-| EXPERIMENT, local only: the switch between the three layouts.
-}
layoutSwitch : Model -> Html Msg
layoutSwitch model =
    let
        option layout label =
            Html.button
                [ Attr.type_ "button"
                , class
                    (if model.layout == layout then
                        "q-btn px-3 py-1 text-[12px]"

                     else
                        "px-3 py-1 text-[12px] underline"
                    )
                , onClick (PickedLayout layout)
                ]
                [ Html.text label ]
    in
    Html.div [ class "flex gap-2 items-center mb-4 text-[12px]", id "hub-layout-switch" ]
        [ Html.span [] [ Html.text "Layout (local test):" ]
        , option Promote "Now"
        , option Drawers "Drawers"
        , option Cards "Cards"
        ]


cardFor : Model -> Catalog -> Visitor -> String -> Deck -> Html Msg
cardFor model catalog v prefix deck =
    Deck.card
        { who = who v
        , deck = deck
        , patchedLevel = catalog.patchedLevel
        , busy = model.busy /= Idle
        , pressed = model.busy == Starting deck.id
        , onPress = Pressed deck
        , prefix = prefix
        , note =
            if model.busy == Starting deck.id || Maybe.map .id (front model.picked catalog) == Just deck.id then
                model.note

            else
                Nothing
        , open = Just (Route.href (Route.practice deck.slug))
        , squares = Nothing
        , size = Deck.OnHub
        }


{-| EXPERIMENT: the five decks in their own order, always. The open one
is drawn as its card where it sits; the rest are rows. Tapping a row opens
it in place and closes the one that was open; nothing changes order.
-}
bodyDrawers : Model -> Catalog -> List (Html Msg)
bodyDrawers model catalog =
    let
        v =
            visitor catalog

        open =
            front model.picked catalog |> Maybe.map .id

        drawer deck =
            if Just deck.id == open then
                Html.div [ class "my-3" ] [ cardFor model catalog v "hub" deck ]

            else
                Deck.row { who = who v, deck = deck, onPick = PickedDeck, prefix = "hub" }
    in
    headLines model catalog v (front model.picked catalog)
        ++ [ Html.div [ class "dk-rows", id "hub-rows" ] (List.map drawer catalog.decks)
           , case v of
                AnAccount ->
                    Html.text ""

                _ ->
                    signInLine model
           ]


{-| EXPERIMENT: every deck's card, one after another, in their own order.
-}
bodyCards : Model -> Catalog -> List (Html Msg)
bodyCards model catalog =
    let
        v =
            visitor catalog
    in
    headLines model catalog v (front model.picked catalog)
        ++ List.map (\deck -> Html.div [ class "mb-5" ] [ cardFor model catalog v ("hub-" ++ deck.id) deck ]) catalog.decks
        ++ [ case v of
                AnAccount ->
                    Html.text ""

                _ ->
                    signInLine model
           ]


bodyPromote : Model -> Catalog -> List (Html Msg)
bodyPromote model catalog =
    let
        v =
            visitor catalog

        inFront =
            front model.picked catalog

        rows =
            catalog.decks
                |> List.filter (\deck -> Just deck.id /= Maybe.map .id inFront)
                |> List.map (\deck -> Deck.row { who = who v, deck = deck, onPick = PickedDeck, prefix = "hub" })
    in
    headLines model catalog v inFront
        ++ [ case inFront of
                Just deck ->
                    Deck.card
                        { who = who v
                        , deck = deck
                        , patchedLevel = catalog.patchedLevel
                        , busy = model.busy /= Idle
                        , pressed = model.busy == Starting deck.id
                        , onPress = Pressed deck
                        , prefix = "hub"
                        , note = model.note
                        , open = Just (Route.href (Route.practice deck.slug))
                        , squares = Nothing
                        , size = Deck.OnHub
                        }

                Nothing ->
                    Html.text ""
           , if List.isEmpty rows then
                Html.text ""

             else
                Html.div [ class "dk-rows", id "hub-rows" ] rows
           , case v of
                AnAccount ->
                    Html.text ""

                _ ->
                    signInLine model
           ]


{-| What is said over the card, for each visitor.
-}
headLines : Model -> Catalog -> Visitor -> Maybe Deck -> List (Html Msg)
headLines model catalog v inFront =
    case v of
        AnAccount ->
            [ Html.p [ class "pz-hub-day", id "hub-day" ]
                [ Html.text
                    (Mistakes.dayStreakLine
                        { streak = catalog.streak
                        , done = Maybe.withDefault 0 catalog.today
                        }
                    )
                ]
            , case catalog.costAll of
                Just cost ->
                    let
                        ( first, second ) =
                            Mistakes.costHeadline cost
                    in
                    -- Two lines held whether or not the second has
                    -- anything to say, so the day it first does, nothing
                    -- under it moves.
                    Html.div [ class "pz-hub-cost", id "hub-cost-all" ]
                        [ Html.p [ class "pz-hub-cost-line" ] [ Html.text first ]
                        , case second of
                            Just won ->
                                Html.p [ class "pz-hub-won", id "hub-won-all" ] [ Html.text won ]

                            Nothing ->
                                Html.text ""
                        ]

                Nothing ->
                    Html.text ""
            , if List.all (\deck -> deck.kind /= Tier || deck.size == 0) catalog.decks then
                Html.p [ class "pz-hub-line", id "hub-fresh" ] [ Html.text Mistakes.freshLine ]

              else
                Html.text ""
            , if inFront == Nothing then
                tryOne model

              else
                Html.text ""
            ]

        AGuest mistakes ->
            [ Html.p [ class "pz-hub-headline", id "hub-headline" ] [ Html.text (mistakesLine mistakes) ]
            , Html.p [ class "pz-hub-line", id "hub-unsaved" ] [ Html.text Mistakes.unsavedLine ]
            ]

        AStranger ->
            [ Html.p [ class "pz-hub-headline", id "hub-headline" ] [ Html.text "Practice your own mistakes." ]
            , Html.p [ class "pz-hub-line", id "hub-about" ]
                [ Html.text "Every mistake the engine finds in your games becomes a puzzle here, and comes back until you stop making it. Or start on the openings now." ]
            , tryOne model
            ]


tryOne : Model -> Html Msg
tryOne model =
    Html.div [ class "pz-hub-try" ]
        [ Html.button
            [ Attr.type_ "button"
            , id "hub-try-one"
            , class "q-btn dk-go"
            , Attr.disabled (model.busy /= Idle)
            , onClick PressedTryOne
            ]
            [ Html.text
                (if model.busy == Trying then
                    "FINDING ONE…"

                 else
                    "TRY ONE"
                )
            ]
        , note model
        ]


{-| "23 mistakes from your 4 games".
-}
mistakesLine : PracticeDecks.Mistakes -> String
mistakesLine mistakes =
    plural mistakes.puzzles "mistake" ++ " from your " ++ plural mistakes.games "game"


plural : Int -> String -> String
plural n word =
    String.fromInt n
        ++ " "
        ++ (if n == 1 then
                word

            else
                word ++ "s"
           )


{-| The quiet way into signing in before a run asks: one line, and the
one component when pressed.
-}
signInLine : Model -> Html Msg
signInLine model =
    case model.signIn of
        Just signIn ->
            Html.div [ id "hub-signin", class "pitch mt-6 pt-5" ]
                [ Html.p [ class "q-note text-[13px] leading-snug text-center mb-3" ]
                    [ Html.text "Sign in and we'll keep this: these come back until you stop making them." ]
                , Html.map SignInMsg (SignIn.view signIn)
                ]

        Nothing ->
            Html.p [ class "pz-hub-signin q-note" ]
                [ Html.text "Signed in, these come back until you stop making them. "
                , Html.button
                    [ Attr.type_ "button", id "hub-signin-open", class "signin-link", onClick OpenedSignIn ]
                    [ Html.text "Sign in" ]
                ]


note : Model -> Html Msg
note model =
    case model.note of
        Just text ->
            Html.p [ id "hub-note", class "dk-quiet" ] [ Html.text text ]

        Nothing ->
            Html.p [ class "dk-quiet" ] []


{-| EXPERIMENT: one deck as a card of its own on the paper: a soft accent
border, an icon, the name and what is left, today's ring, the mastered /
learning bar, what the mistakes cost, and TRAIN. The grid is behind
"Show grid", opened in place.
-}
compactCard : Model -> Catalog -> Deck -> Html Msg
compactCard model catalog deck =
    let
        v =
            visitor catalog

        which =
            Deck.action (who v) deck

        gridOpen =
            List.member deck.id model.gridsOpen

        accent =
            accentOf deck.id

        countLine =
            case deck.standing of
                Just standing ->
                    String.fromInt (max 0 (standing.total - standing.patched)) ++ " left to master"

                Nothing ->
                    String.fromInt deck.size
                        ++ (if PracticeDecks.isSet deck then
                                " positions"

                            else
                                " to master"
                           )

        bar =
            case deck.standing of
                Just standing ->
                    if standing.total > 0 then
                        Html.div [ class "pz-cc-bar" ]
                            [ Html.div [ class "pz-cc-track", Attr.attribute "aria-hidden" "true" ]
                                [ Html.span [ class "is-mastered", Attr.attribute "style" ("width:" ++ pct standing.patched standing.total) ] []
                                , Html.span [ class "is-learning", Attr.attribute "style" ("width:" ++ pct standing.inProgress standing.total) ] []
                                ]
                            , Html.p [ class "pz-cc-state" ]
                                [ Html.span [ class "pz-cc-dot is-mastered" ] []
                                , Html.text (String.fromInt standing.patched ++ " mastered")
                                , Html.span [ class "pz-cc-dot is-learning" ] []
                                , Html.text (String.fromInt standing.inProgress ++ " learning")
                                , Html.span [ class "pz-cc-of" ] [ Html.text ("of " ++ String.fromInt standing.total) ]
                                ]
                            ]

                    else
                        Html.text ""

                Nothing ->
                    Html.text ""

        ring =
            case deck.standing of
                Just standing ->
                    if standing.targetToday > 0 then
                        Html.div [ class "pz-cc-ring" ]
                            [ Charts.miniRing
                                { done = standing.doneToday
                                , target = standing.targetToday
                                , label = String.fromInt standing.doneToday ++ " of " ++ String.fromInt standing.targetToday ++ " today"
                                }
                            , Html.span [] [ Html.text (String.fromInt standing.doneToday ++ "/" ++ String.fromInt standing.targetToday) ]
                            ]

                    else
                        Html.text ""

                Nothing ->
                    Html.text ""

        config =
            { who = who v
            , deck = deck
            , patchedLevel = catalog.patchedLevel
            , busy = model.busy /= Idle
            , pressed = model.busy == Starting deck.id
            , onPress = Pressed deck
            , prefix = "hub-" ++ deck.id
            , note = Nothing
            , open = Nothing
            , squares = Nothing
            , size = Deck.OnHub
            }
    in
    Html.article
        [ class "pz-cc"
        , id ("hub-cc-" ++ deck.id)
        , Attr.attribute "style" ("--accent:" ++ accent.line ++ ";--accent-soft:" ++ accent.soft)
        ]
        [ Html.div [ class "pz-cc-head" ]
            [ Html.div [ class "pz-cc-icon" ] [ iconOf deck ]
            , Html.div [ class "pz-cc-title" ]
                [ Html.a [ class "pz-cc-name", Attr.href (Route.href (Route.practice deck.slug)) ] [ Html.text deck.name ]
                , Html.p [ class "pz-cc-count" ] [ Html.text countLine ]
                ]
            , ring
            ]
        , bar
        , if deck.kind == Tier && who v == Deck.Account then
            Html.div [ class "pz-cc-cost" ] [ Deck.costLines config deck ]

          else
            Html.text ""
        , if gridOpen then
            Html.div [ class "pz-cc-grid" ]
                [ Charts.grid
                    { cells = Deck.cells deck
                    , columns = Deck.columns deck
                    , patchedLevel = catalog.patchedLevel
                    , sentence = deck.name
                    }
                ]

          else
            Html.text ""
        , Html.div [ class "pz-cc-foot" ]
            [ if which == Deck.NoAction then
                Html.text ""

              else
                Html.button
                    [ Attr.type_ "button"
                    , class "q-btn pz-cc-train"
                    , id ("hub-cc-" ++ deck.id ++ "-go")
                    , Attr.disabled (model.busy /= Idle)
                    , onClick (Pressed deck which)
                    ]
                    [ Html.text
                        (if model.busy == Starting deck.id then
                            "STARTING…"

                         else
                            Deck.actionLabel which
                        )
                    ]
            , if deck.standing == Nothing && deck.size == 0 then
                Html.text ""

              else
                Html.button
                    [ Attr.type_ "button"
                    , class "pz-cc-toggle"
                    , id ("hub-cc-" ++ deck.id ++ "-grid")
                    , onClick (ToggledGrid deck.id)
                    , Attr.attribute "aria-expanded"
                        (if gridOpen then
                            "true"

                         else
                            "false"
                        )
                    ]
                    [ Html.text
                        (if gridOpen then
                            "Hide grid ▴"

                         else
                            "Show grid ▾"
                        )
                    ]
            ]
        ]


{-| EXPERIMENT: each deck's soft colour, for its border and its icon.
-}
accentOf : String -> { line : String, soft : String }
accentOf id =
    case id of
        "very_bad" ->
            { line = "#e7a9a4", soft = "#fbecea" }

        "bad" ->
            { line = "#efbf8f", soft = "#fdf1e4" }

        "doubtful" ->
            { line = "#e3cf7f", soft = "#fbf6e0" }

        "openings" ->
            { line = "#9fc3e3", soft = "#e9f2fa" }

        _ ->
            { line = "#bcb2e3", soft = "#f0edfa" }


{-| EXPERIMENT: the mistake's own mark for a tier; a die for the openings,
two for the replies.
-}
iconOf : Deck -> Html Msg
iconOf deck =
    case deck.kind of
        Tier ->
            Html.span [ class "pz-cc-mark" ] [ Html.text deck.mark ]

        _ ->
            let
                die x y pips =
                    Svg.g []
                        (Svg.rect [ SvgA.x (String.fromFloat x), SvgA.y (String.fromFloat y), SvgA.width "16", SvgA.height "16", SvgA.rx "3.5", SvgA.fill "#fff", SvgA.stroke "#23243a", SvgA.strokeWidth "1.6" ] []
                            :: List.map (\( px, py ) -> Svg.circle [ SvgA.cx (String.fromFloat (x + px)), SvgA.cy (String.fromFloat (y + py)), SvgA.r "1.6", SvgA.fill "#23243a" ] []) pips
                        )

                five =
                    [ ( 4.5, 4.5 ), ( 11.5, 4.5 ), ( 8, 8 ), ( 4.5, 11.5 ), ( 11.5, 11.5 ) ]

                three =
                    [ ( 4.5, 4.5 ), ( 8, 8 ), ( 11.5, 11.5 ) ]
            in
            Svg.svg [ SvgA.viewBox "0 0 28 28", SvgA.width "28", SvgA.height "28", Attr.attribute "aria-hidden" "true" ]
                (if deck.id == "openings" then
                    [ die 6 6 five ]

                 else
                    [ die 2 9 three, die 10 3 five ]
                )


pct : Int -> Int -> String
pct n total =
    if total <= 0 then
        "0%"

    else
        String.fromFloat (100 * toFloat (max 0 n) / toFloat total) ++ "%"
