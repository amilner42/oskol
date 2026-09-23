module Page.Puzzles exposing
    ( Model
    , Msg(..)
    , Out(..)
    , State(..)
    , countsLine
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

  - an **account** with a deck: "12 due · 4 new today · 231 in your deck"
    and PRACTICE, which runs what the deck put first. Nothing due and
    nothing new is "Done for today", with KEEP GOING to start more.
  - a **guest** with games behind them: "23 mistakes from your 4 games",
    a line that nothing is saved until they sign in, and the same
    PRACTICE. The sign-in itself is asked at the end of the run, once
    they have felt it; a quiet line here opens it early for whoever
    wants it.
  - a **stranger**: two lines on what this is, and TRY ONE -- a random
    puzzle whose answer stands clear, or an honest line while the pool
    has none.

PRACTICE hands the shell the list (`StartRun`): the run outlives this
page, so it is the shell's (`Main.run`). Signed in, the page also sends
the browser's timezone once, so "due today" and "back tomorrow" are the
player's day and not UTC's.

-}

import Api
import Api.Practice as Practice exposing (Practice)
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Route
import Session exposing (Session)
import Ui.Notebook as Notebook
import Ui.SignIn as SignIn



-- MODEL


type alias Model =
    { session : Session
    , tz : String -- the browser's IANA zone, "" when it could not say
    , practice : Loadable
    , tzSent : Bool
    , busy : Busy
    , signIn : Maybe SignIn.Model -- the early sign-in, once opened
    , note : Maybe String -- what the last press came back with, when it was not a puzzle
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
    | KeepingGoing


{-| The three visitors, read off the server's answer.
-}
type State
    = Account Practice.Counts (List Practice.Entry)
    | Guest Practice.Mistakes (List Practice.Entry)
    | Stranger


type Msg
    = GotPractice (Result Api.Error Practice)
    | PressedPractice
    | PressedKeepGoing
    | GotMore (Result Api.Error Practice)
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
    | StartRun (List String)
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
                Account counts practice.puzzles

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

        PressedKeepGoing ->
            if model.busy == Idle then
                ( { model | busy = KeepingGoing, note = Nothing }, Practice.more model.session GotMore, NoOut )

            else
                ( model, Cmd.none, NoOut )

        GotMore (Ok practice) ->
            case practice.puzzles of
                [] ->
                    ( { model | busy = Idle, practice = Loaded practice, note = Just nothingMoreLine }
                    , Cmd.none
                    , NoOut
                    )

                _ ->
                    start practice { model | busy = Idle, practice = Loaded practice }

        GotMore (Err err) ->
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


{-| PRACTICE: the list the server put first, as a run. An empty list is
nothing to start, and the page already says so.
-}
start : Practice -> Model -> ( Model, Cmd Msg, Out )
start practice model =
    case practice.puzzles of
        [] ->
            ( model, Cmd.none, NoOut )

        entries ->
            ( model, Cmd.none, StartRun (List.map .id entries) )


nothingMoreLine : String
nothingMoreLine =
    "That's every puzzle in your deck for now. The ones you get wrong come back on their day."



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
        Account counts entries ->
            account model counts entries

        Guest mistakes entries ->
            guest model mistakes entries

        Stranger ->
            stranger model


{-| An account: what the deck holds, and PRACTICE; or, with nothing due
and nothing new, "Done for today" and KEEP GOING.
-}
account : Model -> Practice.Counts -> List Practice.Entry -> List (Html Msg)
account model counts entries =
    case entries of
        [] ->
            [ headline "Done for today."
            , Html.p [ id "hub-counts", class "text-base mb-5", Notebook.style "color: var(--ink)" ]
                [ Html.text (tomorrowLine counts) ]
            , Html.button
                [ Attr.type_ "button"
                , id "hub-keep-going"
                , class "q-btn plain w-full px-6 py-3.5 text-[15px]"
                , Attr.disabled (model.busy /= Idle)
                , onClick PressedKeepGoing
                ]
                [ Html.text
                    (if model.busy == KeepingGoing then
                        "STARTING…"

                     else
                        "KEEP GOING"
                    )
                ]
            , note model
            ]

        _ ->
            [ headline (countsLine counts)
            , practiceButton (List.length entries)
            ]


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


{-| "12 due · 4 new today · 231 in your deck".
-}
countsLine : Practice.Counts -> String
countsLine counts =
    String.join " · "
        [ String.fromInt counts.due ++ " due"
        , String.fromInt counts.newToday ++ " new today"
        , String.fromInt counts.deck ++ " in your deck"
        ]


{-| "4 new tomorrow · 231 in your deck", or only the deck when tomorrow
brings nothing new.
-}
tomorrowLine : Practice.Counts -> String
tomorrowLine counts =
    String.join " · "
        ((if counts.newTomorrow > 0 then
            [ String.fromInt counts.newTomorrow ++ " new tomorrow" ]

          else
            []
         )
            ++ [ String.fromInt counts.deck ++ " in your deck" ]
        )


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
