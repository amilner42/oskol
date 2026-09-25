module Page.Home exposing
    ( Model
    , Msg(..)
    , Out(..)
    , dateLine
    , init
    , prBand
    , resultLine
    , scoreLine
    , subscriptions
    , title
    , update
    , view
    , withSession
    )

{-| `/` for a player with an account: their games, their form, their
practice, their last games. One screen that says how they are doing and
what to do next.

A guest keeps the home they have -- the board and its four buttons
(`Page.GameLanding`) -- and `Main` picks between the two by the session,
re-picking when `/papi/me` lands, so a browser that turns out to be signed
in ends up here without a reload. The same thing happens the other way: an
answer that says `signed_in: false` (logged out in another tab) hands the
shell `SignedOut` and the guest home comes back.

Everything below the bar comes from one request (`Api.Home.fetch`):
nothing here wakes a room, replays a log or spends engine time, and MORE
is the only thing that asks the server again.

Two homes means two of everything unless it is deliberately shared, so:

  - **PLAY** is `Page.GameLanding`'s own dialog, on a model this page
    keeps for that (`GameLanding.createOnly`): the modes, the clocks, the
    summary and the seat it takes are that page's, not a second copy.
  - **JOIN** is the shell's code prompt (`Ui.Shell.quietJoinButton`),
    which `Main` owns, exactly as the board home's JOIN GAME is.
  - **the board picker** is `GameLanding.themePicker`, on the same model.
  - **a live game's row** is `Ui.LiveGames.row`, which the board home's
    LIVE GAMES dialog draws too.

Only PUZZLES is this page's own, and it is a route.

The three pictures are `Ui.Charts` and nothing else on the page is drawn:
white space, the notebook's type, and no card inside a card.

-}

import Api
import Api.Auth as Auth
import Api.Catalog as Catalog
import Api.Home as Home
import Api.Practice as Practice
import Browser.Events
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, href, id)
import Html.Events exposing (onClick)
import Json.Decode as D
import Page.GameLanding as GameLanding
import Route
import Session exposing (Session)
import Set exposing (Set)
import Task
import Time
import Ui.Charts as Charts
import Ui.Mistakes as Mistakes
import Ui.Identity as Identity
import Ui.LiveGames as LiveGames
import Ui.Notebook as Notebook exposing (style)
import Ui.Tiers



-- MODEL


type alias Model =
    { session : Session

    -- CREATE GAME's dialog and the board picker, which are
    -- `Page.GameLanding`'s: this page holds its model and forwards to its
    -- update rather than keeping a second copy of either.
    , create : GameLanding.Model
    , state : State
    , accountOpen : Bool
    , paging : Bool -- MORE is in flight
    , pageError : Maybe String
    , starting : Bool -- PRACTICE is in flight: the deck is being fetched
    , practiceNote : Maybe String
    , tier : Maybe String -- the tier of mistakes the player tapped, if they tapped one

    -- The rooms opened up to show their games. A room is a match, so this
    -- is a set and not one id: reading two matches is a thing to do.
    , expanded : Set String

    -- The reader's own zone and the year they are in, so a date is theirs
    -- and drops the year when it is this one. `Time.utc` until the task
    -- answers, which is one frame.
    , zone : Time.Zone
    , year : Int

    -- When the answer came, and now: what a running clock is charged
    -- between, exactly as the board home charges it.
    , fetchedAt : Int
    , now : Int
    }


type State
    = Loading
    | Ready Home.Home
    | Failed String


type Msg
    = GotHome (Result Api.Error Home.Answer)
    | PressedRetry
    | GotClock ( Time.Zone, Time.Posix )
    | Tick Time.Posix
    | ToggledAccount
    | PressedLogOut
    | LoggedOut (Result Api.Error ())
    | PressedPuzzles
    | PressedFixOne String
    | PickedTier String
    | GotBand String (Result Api.Error Practice.Practice)
    | PressedMore
    | GotMore (Result Api.Error Home.Page)
    | ToggledRoom String
    | CreateMsg GameLanding.Msg


{-| What this page needs the shell to do.
-}
type Out
    = NoOut
    | Go String
    | TookSeat { name : String, path : String }
    | ChoseTheme String
    | StartRun (List String) (Maybe Practice.Today) (Maybe String)
      -- The answer says this browser has no account: the guest home is the
      -- one it should be looking at.
    | SignedOut


init : Session -> ( Model, Cmd Msg )
init session =
    let
        ( create, createCmd ) =
            GameLanding.createOnly session "backgammon"
    in
    ( { session = session
      , create = create
      , state = Loading
      , accountOpen = False
      , paging = False
      , pageError = Nothing
      , starting = False
      , practiceNote = Nothing
      , tier = Nothing
      , expanded = Set.empty
      , zone = Time.utc
      , year = 0
      , fetchedAt = 0
      , now = 0
      }
    , Cmd.batch
        [ Home.fetch session GotHome
        , Cmd.map CreateMsg createCmd
        , Task.perform GotClock (Task.map2 Tuple.pair Time.here Time.now)
        ]
    )


withSession : Session -> Model -> Model
withSession session model =
    { model | session = session, create = GameLanding.withSession session model.create }


title : Model -> String
title _ =
    "Home"


{-| A clock ticks only while one is running in a live game; nothing else
on this page moves on its own. Escape closes the account menu.
-}
subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ case model.state of
            Ready home ->
                if List.any clockRunning home.live then
                    Time.every 1000 Tick

                else
                    Sub.none

            _ ->
                Sub.none
        , if model.accountOpen then
            Browser.Events.onKeyDown
                (D.field "key" D.string
                    |> D.andThen
                        (\key ->
                            if key == "Escape" then
                                D.succeed ToggledAccount

                            else
                                D.fail "ignored key"
                        )
                )

          else
            Sub.none
        ]


clockRunning : Catalog.MyGame -> Bool
clockRunning game =
    case game.time of
        Just time ->
            time.running /= Catalog.Nobody

        Nothing ->
            False



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Out )
update msg model =
    case msg of
        -- A browser with no account has no home of this kind. Say so
        -- upward rather than drawing an empty one: the shell puts the
        -- guest home back.
        GotHome (Ok Home.Guest) ->
            ( model, Cmd.none, SignedOut )

        GotHome (Ok (Home.Mine home)) ->
            ( { model | state = Ready home }
            , Task.perform Tick Time.now
            , NoOut
            )

        GotHome (Err err) ->
            ( { model | state = Failed (Api.errorMessage err) }, Cmd.none, NoOut )

        -- Asking again also forgets when the last answer's clocks were
        -- read: charging a running clock from an answer two minutes old
        -- would show a time the table never would.
        PressedRetry ->
            ( { model | state = Loading, fetchedAt = 0 }, Home.fetch model.session GotHome, NoOut )

        GotClock ( zone, posix ) ->
            ( { model | zone = zone, year = Time.toYear zone posix, now = Time.posixToMillis posix }
            , Cmd.none
            , NoOut
            )

        -- The first tick after the answer is also when the clocks start
        -- counting from, so the running one is charged from the moment the
        -- list was read and not from the epoch.
        Tick posix ->
            let
                at =
                    Time.posixToMillis posix
            in
            ( { model
                | now = at
                , fetchedAt =
                    if model.fetchedAt == 0 then
                        at

                    else
                        model.fetchedAt
              }
            , Cmd.none
            , NoOut
            )

        ToggledAccount ->
            ( { model | accountOpen = not model.accountOpen }, Cmd.none, NoOut )

        PressedLogOut ->
            ( { model | accountOpen = False }, Auth.logout model.session LoggedOut, NoOut )

        -- Logged out, or the attempt failed: either way this browser is to
        -- be treated as a guest until `/papi/me` says otherwise, which is
        -- what the shell asks next.
        LoggedOut _ ->
            ( model, Cmd.none, SignedOut )

        PressedPuzzles ->
            ( model, Cmd.none, Go (Route.href Route.puzzles) )

        -- FIX ONE starts a run the way the practice home does: that one
        -- tier's queue, and the run outlives this page, so the shell
        -- keeps it -- with the tier, so ANOTHER stays in it.
        PressedFixOne grade ->
            if model.starting then
                ( model, Cmd.none, NoOut )

            else
                ( { model | starting = True, practiceNote = Nothing }
                , Practice.fetchBand model.session grade (GotBand grade)
                , NoOut
                )

        -- Which tier the card is about. Every tier's numbers came with
        -- the page, so nothing is fetched.
        PickedTier grade ->
            ( { model | tier = Just grade, practiceNote = Nothing }, Cmd.none, NoOut )

        GotBand grade (Ok deck) ->
            case deck.puzzles of
                [] ->
                    ( { model | starting = False, practiceNote = Just nothingDueLine }, Cmd.none, NoOut )

                entries ->
                    ( { model | starting = False }
                    , Cmd.none
                    , StartRun (List.map .id entries) deck.today (Just grade)
                    )

        GotBand _ (Err err) ->
            ( { model | starting = False, practiceNote = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        PressedMore ->
            case ( model.state, model.paging ) of
                ( Ready home, False ) ->
                    if home.more then
                        ( { model | paging = True, pageError = Nothing }
                        , Home.graded model.session home.next GotMore
                        , NoOut
                        )

                    else
                        ( model, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        -- The next ten, appended. The server's own `more` and `next` come
        -- with them, so the button goes when the list is done rather than
        -- being guessed at from a count.
        GotMore (Ok page) ->
            case model.state of
                Ready home ->
                    ( { model
                        | paging = False
                        , state =
                            Ready
                                { home
                                    | recent = home.recent ++ page.rooms
                                    , more = page.more
                                    , next = page.next
                                }
                      }
                    , Cmd.none
                    , NoOut
                    )

                _ ->
                    ( { model | paging = False }, Cmd.none, NoOut )

        GotMore (Err err) ->
            ( { model | paging = False, pageError = Just (Api.errorMessage err) }, Cmd.none, NoOut )

        -- A match opens where it is, without moving anything above it and
        -- without asking the server: its games came down with it.
        ToggledRoom roomId ->
            ( { model
                | expanded =
                    if Set.member roomId model.expanded then
                        Set.remove roomId model.expanded

                    else
                        Set.insert roomId model.expanded
              }
            , Cmd.none
            , NoOut
            )

        CreateMsg createMsg ->
            let
                ( create, cmd, out ) =
                    GameLanding.update createMsg model.create
            in
            ( { model | create = create }
            , Cmd.map CreateMsg cmd
            , case out of
                GameLanding.TookSeat seat ->
                    TookSeat seat

                GameLanding.ChoseTheme name ->
                    ChoseTheme name

                GameLanding.Go path ->
                    Go path

                -- The rest cannot arrive from this model: it has no room
                -- to redirect to and opens no sign-in, because the page it
                -- is on is only ever drawn for an account. Spelled out
                -- rather than caught by a wildcard, so a new one of them
                -- has to be thought about here.
                GameLanding.NoOut ->
                    NoOut

                GameLanding.Redirect _ ->
                    NoOut

                GameLanding.SignedIn _ ->
                    NoOut

                GameLanding.SignedOut ->
                    SignedOut
            )


nothingDueLine : String
nothingDueLine =
    "Nothing to practise right now. The ones you get wrong come back on their day."



-- VIEW


{-| The page, and CREATE GAME's dialog over it. `join` is the shell's, as
it is for the board home.
-}
view : { join : Html msg, toMsg : Msg -> msg } -> Model -> List (Html msg)
view { join, toMsg } model =
    [ Html.div [ class "hm w-full max-w-5xl mx-auto px-4 sm:px-6 pb-12 sm:pb-16" ]
        [ bar join toMsg model
        , case model.state of
            -- Nothing rather than a spinner: the sections arrive together
            -- and land where they will stay, so there is nothing to jump.
            Loading ->
                Html.div [ id "home-loading", class "hm-skeleton", Attr.attribute "aria-hidden" "true" ] []

            Failed message ->
                Html.map toMsg (failed message)

            Ready home ->
                Html.map toMsg (sections model home)
        ]
    , Html.map (toMsg << CreateMsg) (GameLanding.createModal model.create)
    ]


{-| The bar: who this is, and the three things they can start. JOIN comes
in from the shell, which owns the code prompt, so this row mixes the
page's own messages with the shell's and maps each piece rather than the
whole.

On a phone the name and the board picker take the first line and the three
actions the second, three across; from `sm` up it is one line.

-}
bar : Html msg -> (Msg -> msg) -> Model -> Html msg
bar join toMsg model =
    Html.header [ id "home-bar", class "hm-bar pt-4 sm:pt-6 pb-8 sm:pb-10" ]
        [ Html.div [ class "flex items-center justify-between gap-3" ]
            [ Html.map toMsg (account model)
            , Html.map (toMsg << CreateMsg) (GameLanding.themePicker model.create)
            ]
        , Html.div [ class "mt-4 grid grid-cols-3 gap-2 sm:flex sm:gap-3" ]
            [ Html.map toMsg (playButton "home-play" "w-full sm:w-auto")
            , join
            , Html.map toMsg puzzlesButton
            ]
        ]


{-| The account this browser is signed into, and the one thing behind it.
The badge is the same one every name on the site carries (`Ui.Identity`).
-}
account : Model -> Html Msg
account model =
    Html.div [ class "relative min-w-0" ]
        [ Html.button
            [ Attr.type_ "button"
            , id "account-button"
            , class "hm-account flex items-center gap-1.5 min-w-0 px-1.5 py-1 -mx-1.5 rounded-lg"
            , Attr.attribute "aria-expanded"
                (if model.accountOpen then
                    "true"

                 else
                    "false"
                )
            , Attr.attribute "aria-haspopup" "menu"
            , onClick ToggledAccount
            ]
            [ Identity.badge True
            , Html.span
                [ class "font-bold text-[17px] sm:text-[19px] truncate", style "color: var(--ink)" ]
                [ Html.text (model.session.user |> Maybe.andThen .name |> Maybe.withDefault "Your account") ]
            , Html.span [ class "hero-chevron-down w-3.5 h-3.5 shrink-0 opacity-60", Attr.attribute "aria-hidden" "true" ] []
            ]
        , if model.accountOpen then
            Html.div [ id "account-menu", class "hm-account-menu", Attr.attribute "role" "menu" ]
                [ Html.button
                    [ Attr.type_ "button"
                    , id "logout"
                    , Attr.attribute "role" "menuitem"
                    , class "pixel text-[9px] px-3 py-2.5"
                    , onClick PressedLogOut
                    ]
                    [ Html.text "LOG OUT" ]
                ]

          else
            Html.text ""
        ]


puzzlesButton : Html Msg
puzzlesButton =
    Html.button
        [ Attr.type_ "button"
        , id "home-puzzles"
        , class "q-btn plain w-full sm:w-auto rounded-lg px-3 sm:px-7 py-2.5 text-[13px] sm:text-sm whitespace-nowrap"
        , onClick PressedPuzzles
        ]
        [ Html.text "PUZZLES" ]


failed : String -> Html Msg
failed message =
    Html.section [ id "home-failed", class "pt-10" ]
        [ Html.p [ class "text-base mb-4", style "color: var(--ink)" ] [ Html.text message ]
        , Html.button
            [ Attr.type_ "button"
            , id "home-retry"
            , class "q-btn plain rounded-lg px-5 py-2.5 text-sm"
            , onClick PressedRetry
            ]
            [ Html.text "RETRY" ]
        ]



-- THE SECTIONS


{-| Top to bottom: form, live games, practice, recent matches. The form
and the streak come first because they are the two hooks -- how you are
playing now, and how long you have kept showing up -- and they are what
the page is for. On a desktop the same four in two columns, which a
two-column grid in this order gives for nothing -- form and practice down
the left, live and recent down the right -- so a phone and a desktop read
the same page.
-}
sections : Model -> Home.Home -> Html Msg
sections model home =
    Html.div [ class "hm-cols grid gap-10 sm:gap-12 lg:grid-cols-2 lg:gap-x-14 items-start" ]
        [ form home
        , live model home
        , practice model home
        , recent model home
        ]


section : String -> String -> List (Html Msg) -> Html Msg
section elementId eyebrow content =
    Html.section [ id elementId, class "min-w-0" ]
        (Notebook.eyebrow eyebrow :: content)



-- LIVE GAMES


live : Model -> Home.Home -> Html Msg
live model home =
    section "home-live" "LIVE GAMES" <|
        case LiveGames.yoursFirst home.live of
            [] ->
                [ quiet "No games on. Play a friend from a link."
                , playButton "home-live-play" ""
                ]

            games ->
                [ Html.ul [ id "home-live-list", class "space-y-2" ]
                    (List.map (LiveGames.row { fetchedAt = model.fetchedAt, now = model.now }) games)
                ]



-- FORM


{-| Two numbers, the streak beside them and the line under them, then the
line drawn through every graded game. Under three graded games there is no
rating to print, so the sentence says what to do instead and there are no
numbers and no chart: a figure that swings from 3.0 to 14.0 teaches
nothing. The streak stands on its own and is shown either way, because a
player with two games can already be on their second day.
-}
form : Home.Home -> Html Msg
form home =
    section "home-form" "FORM" <|
        case ( home.form.recent, home.form.career ) of
            ( Just recentPr, Just careerPr ) ->
                [ Html.div [ class "flex items-end gap-8 sm:gap-10 mb-2" ]
                    [ figure "home-form-recent" "Recent (last 20)" recentPr "text-[40px] sm:text-[52px]"
                    , figure "home-form-career" "Career" careerPr "text-[24px] sm:text-[30px]"
                    , streak home.form.streak
                    ]
                , sentence home.form.sentence
                , Html.div [ class "mt-5 max-w-md" ]
                    [ Charts.prLine { games = List.map point home.form.series, window = 20 } ]
                ]

            _ ->
                [ case streakDays home.form.streak of
                    Nothing ->
                        Html.text ""

                    Just _ ->
                        Html.div [ class "flex items-end mb-2" ] [ streak home.form.streak ]
                , sentence home.form.sentence
                ]


{-| Days running, beside the two ratings and in the same quiet type. A
player with no streak is shown nothing at all: a zero is a scolding, and
this is a hook, not a scoreboard.
-}
streak : Int -> Html Msg
streak days =
    case streakDays days of
        Nothing ->
            Html.text ""

        Just n ->
            numberFigure "home-form-streak"
                "streak"
                "data-days"
                (String.fromInt n)
                (String.fromInt n
                    ++ (if n == 1 then
                            " day"

                        else
                            " days"
                       )
                )
                "text-[24px] sm:text-[30px]"


streakDays : Int -> Maybe Int
streakDays days =
    if days > 0 then
        Just days

    else
        Nothing


point : Home.Point -> { pr : Float, decisions : Int }
point p =
    { pr = p.pr, decisions = p.decisions }


figure : String -> String -> Float -> String -> Html Msg
figure elementId label value size =
    numberFigure elementId label "data-pr" (oneDecimal value) (oneDecimal value) size


{-| The same figure, printed as words and carrying the plain number for a
test to read: "3 days" over "streak".
-}
numberFigure : String -> String -> String -> String -> String -> String -> Html Msg
numberFigure elementId label attribute value shown size =
    Html.p [ id elementId, class "min-w-0" ]
        [ Html.span
            [ class ("block font-bold leading-none tabular-nums " ++ size)
            , style "color: var(--ink)"
            , Attr.attribute attribute value
            ]
            [ Html.text shown ]
        , Html.span [ class "block q-note text-[12px] mt-2" ] [ Html.text label ]
        ]


sentence : String -> Html Msg
sentence text =
    Html.p [ id "home-form-sentence", class "text-[15px] leading-snug", style "color: var(--ink)" ]
        [ Html.text text ]



-- PRACTICE


{-| One tier of your mistakes in front of you, the others quiet under
it, and the day's count. The same card the practice home shows
(`Ui.Tiers`), so the two pages are one product.

This used to be "N due" and a ladder of eight bars, then a sentence and
three bars and a ring, and for a day it also carried a rung chart, a
thirty-day strip and two lines of explanation under them. The question
is "what should I fix next?", and the answer is a mark, a number and a
button; everything under that answered a question nobody had asked.

-}
practice : Model -> Home.Home -> Html Msg
practice model home =
    section "home-practice" "PUZZLES" <|
        if home.practice.deck <= 0 then
            [ quiet "Your mistakes become puzzles here after your first graded game." ]

        else
            [ Html.div [ class "max-w-md" ]
                [ Ui.Tiers.view
                    { bands = home.practice.severity
                    , lead = home.practice.lead
                    , selected = model.tier
                    , patchedLevel = home.practice.patchedLevel
                    , busy = model.starting
                    , onFix = PressedFixOne
                    , onSelect = PickedTier
                    , prefix = "home"
                    }
                ]
            , case model.practiceNote of
                Just note ->
                    Html.p [ id "home-practice-note", class "q-note text-[13px] leading-snug mt-2" ] [ Html.text note ]

                Nothing ->
                    Html.text ""
            ]


-- RECENT MATCHES


{-| One line per **room**: a match, an unlimited session or a single game.
A match to seven was nine loose lines here once, saying nothing about the
match it was; now it is one line that says so and opens to show its games.
-}
recent : Model -> Home.Home -> Html Msg
recent model home =
    section "home-recent" "RECENT MATCHES" <|
        case home.recent of
            [] ->
                [ quiet "Your finished games appear here once the engine has graded them." ]

            rooms ->
                [ Html.ul [ id "home-recent-list", class "hm-games" ]
                    (List.map (recentRow model) rooms)
                , case model.pageError of
                    Just message ->
                        Html.p [ id "home-more-error", class "q-note text-[13px] mt-3" ] [ Html.text message ]

                    Nothing ->
                        Html.text ""
                , if home.more then
                    Html.button
                        [ Attr.type_ "button"
                        , id "home-more"
                        , class "q-btn plain rounded-lg px-5 py-2.5 text-[12px] mt-4"
                        , Attr.disabled model.paging
                        , onClick PressedMore
                        ]
                        [ Html.text
                            (if model.paging then
                                "LOADING\u{2026}"

                             else
                                "MORE"
                            )
                        ]

                  else
                    Html.text ""
                ]


{-| One room: who it was against, what was being played, how it stands,
the rating over the whole of it in its band's colour, and the day it
ended.

A room with more than one game opens in place -- a button, because it
moves nothing and goes nowhere -- and a room with one game is the link to
that game's replay, as every line here used to be.
-}
recentRow : Model -> Home.Room -> Html Msg
recentRow model room =
    let
        open =
            Set.member room.id model.expanded

        many =
            List.length room.games > 1
    in
    Html.li []
        (if many then
            Html.button
                [ Attr.type_ "button"
                , id ("home-room-" ++ room.id)
                , class "hm-game block w-full text-left py-2.5"
                , Attr.attribute "aria-expanded"
                    (if open then
                        "true"

                     else
                        "false"
                    )
                , onClick (ToggledRoom room.id)
                ]
                (rowLine model room many open)
                :: (if open then
                        [ roomGames room ]

                    else
                        []
                   )

         else
            [ Html.a
                [ href room.path
                , id ("home-room-" ++ room.id)
                , class "hm-game block py-2.5"
                ]
                (rowLine model room many open)
            ]
        )


{-| The line itself, and under it what was being played. The format goes
on its own line rather than into the row, so it has the whole width to
say "Match to 7 \u{00B7} 9 games" on a 320px screen instead of "Match \u{2026}".
-}
rowLine : Model -> Home.Room -> Bool -> Bool -> List (Html Msg)
rowLine model room many open =
    [ Html.span [ class "flex items-baseline gap-3" ]
        [ Html.span
            [ class "min-w-0 flex-1 font-semibold text-[15px] truncate"
            , style "color: var(--ink)"
            ]
            [ Html.text (Maybe.withDefault "\u{2014}" room.opponent) ]
        , Html.span [ class "q-note text-[13px] whitespace-nowrap" ] [ Html.text (scoreLine room) ]
        , Html.span
            [ class ("hm-pr tabular-nums text-[12px] font-bold " ++ prBand room.pr)
            , Attr.attribute "data-pr" (oneDecimal room.pr)
            ]
            [ Html.text (oneDecimal room.pr) ]
        , Html.span [ class "q-note text-[12px] whitespace-nowrap w-[4.6rem] text-right" ]
            [ Html.text (dateLine model.zone model.year room.endedAt) ]
        , if many then
            Html.span
                [ class
                    ("hero-chevron-down w-3 h-3 shrink-0 opacity-50 hm-caret"
                        ++ (if open then
                                " is-open"

                            else
                                ""
                           )
                    )
                , Attr.attribute "aria-hidden" "true"
                ]
                []

          else
            Html.text ""
        ]
    , Html.span [ class "block q-note text-[12px] truncate mt-0.5" ]
        [ Html.text (formatLine room) ]
    ]


{-| The games of a match, one level in: which game, how it went, and its
own rating. Each is the link to that game's replay.
-}
roomGames : Home.Room -> Html Msg
roomGames room =
    Html.ul
        [ id ("home-room-" ++ room.id ++ "-games")
        , class "hm-inner ml-1 pl-3 pb-1"
        ]
        (List.map (gameRow room) room.games)


gameRow : Home.Room -> Home.Game -> Html Msg
gameRow room game =
    Html.li []
        [ Html.a
            [ href game.path
            , id ("home-game-" ++ room.id ++ "-" ++ String.fromInt game.gameNumber)
            , class "hm-game flex items-baseline gap-3 py-2"
            ]
            [ Html.span
                [ class "min-w-0 flex-1 text-[13px]", style "color: var(--ink)" ]
                [ Html.text ("Game " ++ String.fromInt game.gameNumber) ]
            , Html.span [ class "q-note text-[12px] whitespace-nowrap" ]
                [ Html.text (resultLine game.result) ]
            , Html.span
                [ class ("hm-pr tabular-nums text-[11px] font-bold " ++ prBand game.pr)
                , Attr.attribute "data-pr" (oneDecimal game.pr)
                ]
                [ Html.text (oneDecimal game.pr) ]
            ]
        ]


{-| What was being played, and how much of it is here: "Match to 7 \u{00B7} 9
games", "Single game".
-}
formatLine : Home.Room -> String
formatLine room =
    case List.length room.games of
        1 ->
            room.format

        n ->
            room.format ++ " \u{00B7} " ++ String.fromInt n ++ " games"


{-| How the room stands, from this player's side: "won 7-4" for a match
that is over, "7-4" for one still being played or one nothing recorded a
winner for, and a finished single game's own result line as it has always
read ("won 2 \u{00B7} gammon").
-}
scoreLine : Home.Room -> String
scoreLine room =
    case ( room.over, room.games ) of
        ( True, [ only ] ) ->
            resultLine only.result

        _ ->
            let
                score =
                    String.fromInt room.score.yours ++ "-" ++ String.fromInt room.score.theirs
            in
            case ( room.over, room.won ) of
                ( True, Just True ) ->
                    "won " ++ score

                ( True, Just False ) ->
                    "lost " ++ score

                _ ->
                    score


{-| How the game went, for this seat: "won 2", "lost 1", and the kind
where it was more than a plain game.
-}
resultLine : Maybe Home.Result_ -> String
resultLine result =
    case result of
        -- No record row says how it ended: the game is still worth its
        -- rating, and the result column simply has nothing in it.
        Nothing ->
            "\u{2014}"

        Just outcome ->
            (if outcome.won then
                "won "

             else
                "lost "
            )
                ++ String.fromInt outcome.points
                ++ (case outcome.kind of
                        "gammon" ->
                            " \u{00B7} gammon"

                        "backgammon" ->
                            " \u{00B7} backgammon"

                        _ ->
                            ""
                   )


{-| A rating's band, in the grades' own colours (`app.css`): five and
under is the best move's green, ten and under the quiet teal, and above
that the red. Lower is better, so the test is which side of the band the
number falls on, not how big it is.
-}
prBand : Float -> String
prBand pr =
    if pr <= 5 then
        "g-best"

    else if pr <= 10 then
        "g-ok"

    else
        "g-very_bad"


{-| The day a game ended, in the reader's own zone. The year is dropped
while it is this one, which is every game anybody has.
-}
dateLine : Time.Zone -> Int -> Int -> String
dateLine zone year at =
    let
        posix =
            Time.millisToPosix at

        day =
            String.fromInt (Time.toDay zone posix)

        month =
            monthName (Time.toMonth zone posix)

        gameYear =
            Time.toYear zone posix
    in
    if gameYear == year || year == 0 then
        day ++ " " ++ month

    else
        day ++ " " ++ month ++ " " ++ String.fromInt gameYear


monthName : Time.Month -> String
monthName month =
    case month of
        Time.Jan ->
            "Jan"

        Time.Feb ->
            "Feb"

        Time.Mar ->
            "Mar"

        Time.Apr ->
            "Apr"

        Time.May ->
            "May"

        Time.Jun ->
            "Jun"

        Time.Jul ->
            "Jul"

        Time.Aug ->
            "Aug"

        Time.Sep ->
            "Sep"

        Time.Oct ->
            "Oct"

        Time.Nov ->
            "Nov"

        Time.Dec ->
            "Dec"


quiet : String -> Html Msg
quiet text =
    Html.p [ class "text-[15px] leading-snug mb-4", style "color: var(--ink)" ] [ Html.text text ]


{-| PLAY: `Page.GameLanding`'s own CREATE GAME, pressed through this
page's copy of its model, so the dialog behind it is that page's and not a
second one.
-}
playButton : String -> String -> Html Msg
playButton elementId extra =
    Html.button
        [ Attr.type_ "button"
        , id elementId
        , class ("q-btn rounded-lg px-3 sm:px-7 py-2.5 text-[13px] sm:text-sm whitespace-nowrap " ++ extra)
        , onClick (CreateMsg GameLanding.Started)
        ]
        [ Html.text "PLAY" ]


{-| One decimal, always, so "8" reads as "8.0" -- the way a PR is written
everywhere else on the site.
-}
oneDecimal : Float -> String
oneDecimal value =
    let
        n =
            round (abs value * 10)

        sign =
            if value < 0 && n /= 0 then
                "-"

            else
                ""
    in
    sign ++ String.fromInt (n // 10) ++ "." ++ String.fromInt (modBy 10 n)
