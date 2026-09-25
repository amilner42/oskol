module Page.Puzzles exposing
    ( Model
    , Msg(..)
    , Out(..)
    , State(..)
    , init
    , mistakesLine
    , state
    , title
    , update
    , view
    , withSession
    )

{-| `/puzzles` -- the practice home. One page for three visitors, because
`GET /papi/practice` is one answer for three callers:

  - an **account** with mistakes: one tier of them, named by the mark
    the replay draws -- `??`, `?`, `?!` -- with "31 left to fix", its
    own bar and one button, FIX ONE. The other tiers are quiet rows
    under it. A tier with nothing due and no new ones left today says
    so warmly and offers the next tier down instead (`Ui.Tiers`).
  - a **guest** with games behind them: "23 mistakes from your 4 games",
    a line that nothing is saved until they sign in, and the same
    PRACTICE. The sign-in itself is asked at the end of the run, once
    they have felt it; a quiet line here opens it early for whoever
    wants it.
  - a **stranger**: two lines on what this is, and TRY ONE -- a random
    puzzle whose answer stands clear, or an honest line while the pool
    has none.

FIX ONE asks for that tier's own queue (`GET /papi/practice?band=`) and
hands the shell the list (`StartRun`): the run outlives this page, so it
is the shell's (`Main.run`), and it carries the tier so ANOTHER stays in
it. Signed in, the page also sends the browser's timezone once, so "due
today" and "back tomorrow" are the player's day and not UTC's.

-}

import Api
import Api.Practice as Practice exposing (Practice)
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Route
import Session exposing (Session)
import Ui.Mistakes as Mistakes
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn
import Ui.Tiers



-- MODEL


type alias Model =
    { session : Session
    , tz : String -- the browser's IANA zone, "" when it could not say
    , practice : Loadable
    , tzSent : Bool
    , busy : Busy
    , signIn : Maybe SignIn.Model -- the early sign-in, once opened
    , note : Maybe String -- what the last press came back with, when it was not a puzzle
    , tier : Maybe String -- the tier the player tapped, if they tapped one
    }


type Loadable
    = Loading
    | Loaded Practice
    | Unavailable String


{-| Which press is in flight, so it cannot be pressed twice.
-}
type Busy
    = Idle
    | Trying
    | Fixing


{-| The three visitors, read off the server's answer.
-}
type State
    = Account Practice (List Practice.Entry)
    | Guest Practice.Mistakes (List Practice.Entry)
    | Stranger


type Msg
    = GotPractice (Result Api.Error Practice)
    | PressedPractice
    | PressedFixOne String
    | PickedTier String
    | GotBand String (Result Api.Error Practice)
    | PressedTryOne
    | GotRandom (Result Api.Error Practice.Random)
    | TimezoneSent (Result Api.Error ())
    | OpenedSignIn
    | SignInMsg SignIn.Msg
    | NoOp


{-| What the shell does for the page: start a run of these puzzles, go
somewhere, or take note of a sign-in.
-}
type Out
    = NoOut
    | StartRun (List String) (Maybe Practice.Today) (Maybe String)
    | Go String
    | SignedIn (Maybe Session.User)


init : Session -> { tz : String } -> ( Model, Cmd Msg )
init session config =
    ( { session = session
      , tz = config.tz
      , practice = Loading
      , tzSent = False
      , busy = Idle
      , signIn = Nothing
      , note = Nothing
      , tier = Nothing
      }
    , Practice.fetch session GotPractice
    )


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session }


title : Model -> String
title _ =
    "Puzzles"


{-| Who the server said this visitor is. An account with an empty deck
has nothing of its own yet, so it is offered what a stranger is.
-}
state : Practice -> State
state practice =
    case ( practice.counts, practice.mistakes ) of
        ( Just counts, _ ) ->
            if counts.deck > 0 then
                Account practice practice.puzzles

            else
                Stranger

        ( Nothing, Just mistakes ) ->
            if mistakes.puzzles > 0 then
                Guest mistakes practice.puzzles

            else
                Stranger

        ( Nothing, Nothing ) ->
            Stranger



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        GotPractice (Ok practice) ->
            -- The day is the player's, not UTC's: told once per visit, and
            -- only where there is a deck to keep it on. Marked sent as it
            -- goes, so a refetch racing the answer cannot send it twice.
            if practice.counts /= Nothing && model.tz /= "" && not model.tzSent then
                ( { model | practice = Loaded practice, tzSent = True }
                , Practice.sendTimezone model.session model.tz TimezoneSent
                , NoOut
                )

            else
                ( { model | practice = Loaded practice }, Cmd.none, NoOut )

        GotPractice (Err err) ->
            ( { model | practice = Unavailable (Api.errorMessage err) }, Cmd.none, NoOut )

        TimezoneSent _ ->
            -- Sent is sent; a refusal (a zone the server does not know)
            -- leaves the deck on the day it had, which is nothing to say.
            ( model, Cmd.none, NoOut )

        PressedPractice ->
            case model.practice of
                Loaded practice ->
                    start practice model

                _ ->
                    ( model, Cmd.none, NoOut )

        -- FIX ONE: that tier's own queue, then a run of it. The hub is
        -- fetched without a tier, so its `puzzles` are the whole deck's
        -- front and are not what this tier's run is made of.
        PressedFixOne grade ->
            if model.busy == Idle then
                ( { model | busy = Fixing, note = Nothing }
                , Practice.fetchBand model.session grade (GotBand grade)
                , NoOut
                )

            else
                ( model, Cmd.none, NoOut )

        GotBand grade (Ok practice) ->
            case practice.puzzles of
                -- The tier said it had work and the queue came back
                -- empty: something was answered between the two calls.
                -- The page says so and shows the fresh answer.
                [] ->
                    ( { model | busy = Idle, practice = Loaded practice, note = Just nothingMoreLine }
                    , Cmd.none
                    , NoOut
                    )

                entries ->
                    ( { model | busy = Idle }
                    , Cmd.none
                    , StartRun (List.map .id entries) practice.today (Just grade)
                    )

        GotBand _ (Err err) ->
            ( { model | busy = Idle, note = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        -- A quiet row, or the offer under a tier in good shape: which
        -- tier the card is about. Nothing is fetched -- every tier's
        -- numbers came with the page.
        PickedTier grade ->
            ( { model | tier = Just grade, note = Nothing }, Cmd.none, NoOut )

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

                        -- Signed in: the deck is being filled from the games
                        -- that came along. Ask again, and tell the shell.
                        SignIn.SignedIn result ->
                            ( updated
                            , Cmd.batch [ Cmd.map SignInMsg cmd, Practice.fetch model.session GotPractice ]
                            , SignedIn result.user
                            )

                        SignIn.Continue path ->
                            ( { updated | signIn = Nothing }, Cmd.none, Go path )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        NoOp ->
            ( model, Cmd.none, NoOut )


{-| PRACTICE: the list the server put first, as a run. A guest's whole
pile of mistakes, which is not a tier of anything. An empty list is
nothing to start, and the page already says so.
-}
start : Practice -> Model -> ( Model, Cmd Msg, Out )
start practice model =
    case practice.puzzles of
        [] ->
            ( model, Cmd.none, NoOut )

        entries ->
            ( model, Cmd.none, StartRun (List.map .id entries) practice.today Nothing )


nothingMoreLine : String
nothingMoreLine =
    "That's every mistake of yours for now. The ones you get wrong come back on their day."



-- VIEW


view : Model -> Html Msg
view model =
    Html.section
        [ class "mt-8 sm:mt-12 mx-auto max-w-md q-card sheet p-6 sm:p-8", id "puzzles-hub" ]
        (Notebook.eyebrow "PUZZLES"
            :: (case model.practice of
                    Loading ->
                        [ Html.p [ class "pixel text-[9px]", Notebook.style "color: var(--pencil)" ] [ Html.text "LOADING…" ] ]

                    Unavailable reason ->
                        [ line reason ]

                    Loaded practice ->
                        body model (state practice)
               )
        )


body : Model -> State -> List (Html Msg)
body model visitor =
    case visitor of
        Account practice entries ->
            account model practice entries

        Guest mistakes entries ->
            guest model mistakes entries

        Stranger ->
            stranger model


{-| An account: one tier of their mistakes, the others quiet under it,
and the day's count.

One thing to do, on purpose. The head was "You have made 61 very bad
moves. You are fixing 30 and have patched 12.", three bars and FIX 10
TODAY -- true, and too much to read before you have fixed anything. The
card is a mark, a number and a button; the rest is a row each.

-}
account : Model -> Practice.Practice -> List Practice.Entry -> List (Html Msg)
account model practice entries =
    let
        tiers =
            { bands = practice.severity
            , lead = practice.lead
            , selected = model.tier
            , patchedLevel = practice.patchedLevel
            , busy = model.busy /= Idle
            , onFix = PressedFixOne
            , onSelect = PickedTier
            , prefix = "hub"
            }
    in
    case Ui.Tiers.shown tiers of
        Just _ ->
            [ Ui.Tiers.view tiers
            , Html.p [ id "hub-today", class "q-note text-[13px] mt-4" ]
                [ Html.text (todayLine practice) ]
            , note model
            ]

        -- A deck with cards in it and no band behind any of them: an old
        -- row, or a game whose sources went. There is nothing to put a
        -- tier's name to, so the deck is offered whole rather than as a
        -- card with nothing on it.
        Nothing ->
            [ headline (deckLine practice)
            , practiceButton (List.length entries)
            , Html.p [ id "hub-today", class "q-note text-[13px] mt-4" ]
                [ Html.text (todayLine practice) ]
            , note model
            ]


{-| "231 of your mistakes": the fallback head, for a deck no band can be
read off.
-}
deckLine : Practice.Practice -> String
deckLine practice =
    String.fromInt (Maybe.withDefault 0 (Maybe.map .deck practice.counts))
        ++ " of your mistakes"


{-| Under the card, in the quiet type: "3 fixed today". A count and
nothing else -- there is no day's target any more, so there is nothing
to be behind on.
-}
todayLine : Practice.Practice -> String
todayLine practice =
    case practice.today of
        Just today ->
            Mistakes.fixedToday today.done

        Nothing ->
            ""


{-| A guest with games behind them: what is theirs, that it is not kept
yet, and PRACTICE. The sign-in is asked at the end of the run; the line
here is for whoever wants it now.
-}
guest : Model -> Practice.Mistakes -> List Practice.Entry -> List (Html Msg)
guest model mistakes entries =
    [ headline (mistakesLine mistakes)
    , Html.p [ id "hub-unsaved", class "q-note text-[13px] leading-snug mb-5" ]
        [ Html.text "Your progress is not saved until you sign in." ]
    , practiceButton (List.length entries)
    , signInLine model
    ]


{-| A stranger: what this is, and one to try.
-}
stranger : Model -> List (Html Msg)
stranger model =
    [ headline "Practice your own mistakes."
    , Html.p [ id "hub-about", class "text-base mb-5", Notebook.style "color: var(--ink)" ]
        [ Html.text "Every mistake the engine finds in your games becomes a puzzle here, and comes back until you stop making it. Practice them, and share any puzzle with a link." ]
    , Html.button
        [ Attr.type_ "button"
        , id "hub-try-one"
        , class "q-btn w-full px-6 py-3.5 text-[15px]"
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
    , if model.session.user == Nothing then
        signInLine model

      else
        Html.text ""
    ]


practiceButton : Int -> Html Msg
practiceButton count =
    Html.button
        [ Attr.type_ "button"
        , id "hub-practice"
        , class "q-btn w-full px-6 py-3.5 text-[15px]"
        , Attr.disabled (count == 0)
        , onClick PressedPractice
        ]
        [ Html.text "PRACTICE" ]


{-| "23 mistakes from your 4 games".
-}
mistakesLine : Practice.Mistakes -> String
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


{-| The quiet way into signing in before the run asks: one line, and the
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
            Html.p [ class "q-note text-[13px] leading-snug text-center mt-5" ]
                [ Html.text "Signed in, these come back until you stop making them. "
                , Html.button
                    [ Attr.type_ "button", id "hub-signin-open", class "signin-link", onClick OpenedSignIn ]
                    [ Html.text "Sign in" ]
                ]


note : Model -> Html Msg
note model =
    case model.note of
        Just text ->
            Html.p [ id "hub-note", class "q-note text-[13px] leading-snug text-center mt-3" ] [ Html.text text ]

        Nothing ->
            Html.text ""


headline : String -> Html msg
headline text =
    Html.p [ id "hub-headline", class "text-[20px] sm:text-[22px] font-bold leading-snug mb-2", Notebook.style "color: var(--ink)" ]
        [ Html.text text ]


line : String -> Html msg
line text =
    Html.p [ class "text-base mb-4", Notebook.style "color: var(--ink)" ] [ Html.text text ]
