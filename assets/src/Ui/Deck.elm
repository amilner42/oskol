module Ui.Deck exposing
    ( Action(..)
    , CardConfig
    , RowConfig
    , Size(..)
    , Who(..)
    , action
    , actionLabel
    , card
    , cells
    , costLines
    , left
    , row
    )

{-| One deck in front of you, and the others as rows: the card and the
row the practice home draws, and that a deck's own page will draw too.

A deck is one of five -- a tier of the player's own mistakes (`??`, `?`,
`?!`) or a universal set (the openings, the replies to them) -- in the
one shape the server gives all five (`Api.PracticeDecks`). The card is:

  - **the head**: the mark big (a tier) or the name big (a set), what it
    is under it in the eyebrow style, and to the right today's ring
    ("3/5", a check once today's set is done);
  - **the mastery grid**: a square per position, coloured by its rung,
    so a deck's size and how much of it is learnt are one picture, and
    the square an answer lit is the thing that changed;
  - **the state line**, which is the grid's legend in words: "12 patched
    · 20 in progress · 12 to start · of 44";
  - for a tier, **what it cost**: "These cost you 11.3 points over 11
    games. Without them your PR would be 4.8, not 8.3.";
  - **one button**, never absent where there is anything to practise:
    FIX ONE while today has work, KEEP GOING once today's set is done
    and something is still unstarted, PRACTICE ANYWAY once everything
    is, START / PRACTICE / TRY on a set; and under it one quiet line for
    the state it is in.

**Nothing moves.** The button's label changes inside a slot of fixed
height; the quiet line under it holds two lines whatever it says; the
grid's box is a function of the deck's size alone, and the ring's box is
fixed while only its arc moves.

The words are `Ui.Mistakes`' and `Ui.Decks`'; nothing here says card,
deck or flashcard to a player.

-}

import Api.PracticeDecks as PracticeDecks exposing (Deck, Kind(..), Standing)
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Ui.Charts as Charts
import Ui.Decks as Decks
import Ui.Mistakes as Mistakes


{-| Who is looking: an account keeps what it does, a guest has games
behind them and nothing kept, a stranger has neither.
-}
type Who
    = Account
    | Guest
    | Stranger


{-| The one thing the card's button does. `NoAction` is a deck with
nothing of the visitor's in it (a stranger's tier): it is never put in
front.
-}
type Action
    = FixOne
    | Practice
    | KeepGoing
    | PracticeAnyway
    | Start
    | Try
    | NoAction


{-| The button a deck offers this visitor, decided from the deck's own
standing and nothing else:

  - an account's tier: FIX ONE while it has something due or new today;
    once today's set is done, KEEP GOING while anything is unstarted,
    then PRACTICE ANYWAY;
  - an account's set: START until it is added, then the same three, with
    PRACTICE where a tier says FIX ONE;
  - a guest's tier with mistakes in it: PRACTICE (nothing is kept);
  - a set for a guest or a stranger: TRY.

-}
action : Who -> Deck -> Action
action who deck =
    case ( who, deck.kind ) of
        ( Account, Tier ) ->
            case deck.standing of
                Just standing ->
                    if standing.total <= 0 then
                        NoAction

                    else
                        onwards FixOne standing

                Nothing ->
                    NoAction

        ( Account, Set ) ->
            case deck.standing of
                Just standing ->
                    if deck.joined && standing.total > 0 then
                        onwards Practice standing

                    else
                        Start

                Nothing ->
                    Start

        ( Guest, Tier ) ->
            if deck.size > 0 then
                Practice

            else
                NoAction

        ( _, Set ) ->
            Try

        ( Stranger, Tier ) ->
            NoAction


{-| Today's work first, then more of the pace, then practice that moves
nothing. Never nothing: there is always a way to keep practising.
-}
onwards : Action -> Standing -> Action
onwards working standing =
    if standing.due > 0 || standing.newLeft > 0 then
        working

    else if standing.untouched > 0 then
        KeepGoing

    else
        PracticeAnyway


actionLabel : Action -> String
actionLabel which =
    case which of
        FixOne ->
            "FIX ONE"

        Practice ->
            "PRACTICE"

        KeepGoing ->
            "KEEP GOING"

        PracticeAnyway ->
            "PRACTICE ANYWAY"

        Start ->
            "START"

        Try ->
            "TRY"

        NoAction ->
            ""


actionName : Action -> String
actionName which =
    case which of
        FixOne ->
            "fix-one"

        Practice ->
            "practice"

        KeepGoing ->
            "keep-going"

        PracticeAnyway ->
            "practice-anyway"

        Start ->
            "start"

        Try ->
            "try"

        NoAction ->
            "none"



-- THE CARD


type alias CardConfig msg =
    { who : Who
    , deck : Deck
    , patchedLevel : Int
    , busy : Bool -- a press is on its way: the button waits
    , pressed : Bool -- and it is this card's
    , note : Maybe String -- what the last press came back with, said where the quiet line is
    , onPress : Action -> msg
    , prefix : String
    , open : Maybe String -- the deck's own page, linked from the head (the hub's card)
    , squares : Maybe (List { level : Int, status : String }) -- each position as it stands, in the deck's order (a deck's page)
    , size : Size
    }


{-| The card on the practice home, or at the size of a deck's own page:
there the grid is wider, the ring bigger, the grid has its legend under
it, and what the tier cost is said in a block of its own below the card.
-}
type Size
    = OnHub
    | OnPage


card : CardConfig msg -> Html msg
card config =
    let
        deck =
            config.deck

        which =
            action config.who deck
    in
    Html.div
        [ id (config.prefix ++ "-card")
        , class
            (case config.size of
                OnHub ->
                    "dk-card"

                OnPage ->
                    "dk-card is-page"
            )
        , Attr.attribute "data-deck" deck.id
        , Attr.attribute "data-kind" (kindName deck)
        , Attr.attribute "data-action" (actionName which)
        ]
        [ head config
        , Html.div [ class "dk-grid", id (config.prefix ++ "-grid") ]
            [ Charts.grid
                { cells = squaresOf config
                , columns = columns deck
                , patchedLevel = config.patchedLevel
                , sentence = stateSentence config.who deck
                }
            ]
        , case config.size of
            OnPage ->
                legend config

            OnHub ->
                Html.text ""
        , stateLine config deck
        , case config.size of
            OnHub ->
                costLines config deck

            OnPage ->
                Html.text ""
        , Html.div [ class "dk-action" ]
            [ Html.button
                [ Attr.type_ "button"
                , id (config.prefix ++ "-go")
                , class ("q-btn dk-go is-" ++ actionName which)
                , Attr.attribute "data-action" (actionName which)
                , Attr.disabled (config.busy || which == NoAction)
                , onClick (config.onPress which)
                ]
                [ Html.text
                    (if config.pressed then
                        "STARTING…"

                     else
                        actionLabel which
                    )
                ]
            ]
        , Html.p [ id (config.prefix ++ "-quiet"), class "dk-quiet" ]
            [ Html.text (Maybe.withDefault (quietLine config.who which deck) config.note) ]
        ]


kindName : Deck -> String
kindName deck =
    case deck.kind of
        Tier ->
            "mistakes"

        Set ->
            "set"


head : CardConfig msg -> Html msg
head config =
    let
        deck =
            config.deck
    in
    Html.div [ class "dk-head" ]
        [ Html.div [ class "dk-title" ]
            (case deck.kind of
                Tier ->
                    [ Html.p [ class "dk-mark", Attr.attribute "aria-hidden" "true" ] [ Html.text deck.mark ]
                    , nameRow config [ Html.h2 [ class "dk-name", id (config.prefix ++ "-name") ] [ Html.text deck.name ] ]
                    ]

                Set ->
                    [ Html.h2 [ class "dk-setname", id (config.prefix ++ "-name") ] [ Html.text deck.name ]
                    , nameRow config [ Html.p [ class "dk-name" ] [ Html.text (Decks.sizeEyebrow deck.size) ] ]
                    ]
            )
        , case deck.standing of
            Just standing ->
                if config.who == Account && (deck.kind == Tier || deck.joined) then
                    Html.div [ class "dk-today", id (config.prefix ++ "-today") ]
                        [ Charts.ring
                            { done = standing.doneToday
                            , target = standing.targetToday
                            , label = ringSentence standing
                            }
                        , Html.p [ class "dk-today-word" ] [ Html.text "today" ]
                        ]

                else
                    Html.text ""

            Nothing ->
                Html.text ""
        ]


{-| The eyebrow under the mark or the name, with OPEN beside it where the
card links to the deck's own page. The link sits on the eyebrow's own
line and is no taller than it, so the head is the same height with it
or without it.
-}
nameRow : CardConfig msg -> List (Html msg) -> Html msg
nameRow config name =
    case config.open of
        Just path ->
            Html.div [ class "dk-name-row" ]
                (name
                    ++ [ Html.a
                            [ Attr.href path
                            , id (config.prefix ++ "-open")
                            , class "dk-open"
                            , Attr.attribute "aria-label" ("Open " ++ config.deck.name)
                            ]
                            [ Html.text "OPEN", Html.span [ class "dk-open-chev", Attr.attribute "aria-hidden" "true" ] [ Html.text "›" ] ]
                       ]
                )

        Nothing ->
            Html.div [ class "dk-name-row" ] name


{-| Under the grid on a deck's page: what each colour means, square by
square -- the grid's own paints, in the order a position climbs them.
-}
legend : CardConfig msg -> Html msg
legend config =
    let
        top =
            case config.deck.kind of
                Tier ->
                    Mistakes.legendTop

                Set ->
                    Decks.legendTop

        swatch ( state, words ) =
            Html.span [ class ("dk-key is-" ++ state) ]
                [ Html.span [ class ("dk-swatch is-" ++ state), Attr.attribute "aria-hidden" "true" ] []
                , Html.text words
                ]
    in
    Html.p [ class "dk-legend", id (config.prefix ++ "-legend") ]
        (List.map swatch (Mistakes.legendParts top))


{-| The squares the grid draws: each position as it stands where the
caller has them (a deck's page), else worked out from the counts.
-}
squaresOf : CardConfig msg -> List { level : Int, status : String }
squaresOf config =
    case config.squares of
        Just (first :: rest) ->
            first :: rest

        _ ->
            cells config.deck


{-| The ring in words, for the `<title>` a hover shows.
-}
ringSentence : Standing -> String
ringSentence standing =
    if standing.targetToday <= 0 then
        "Nothing set for today."

    else
        String.fromInt standing.doneToday ++ " of today's " ++ String.fromInt standing.targetToday ++ " done."


{-| The grid's squares. An account's are drawn from its standing, in the
order that reads as progress (patched first, then the yellows, then
what is still to start); anybody else's deck is all paper, one square
per position, which is its size.
-}
cells : Deck -> List { level : Int, status : String }
cells deck =
    case deck.standing of
        Just standing ->
            if standing.total > 0 then
                Charts.gridFromCounts
                    { levels = standing.levels
                    , untouched = standing.untouched
                    , total = standing.total
                    }

            else
                List.repeat (max 0 deck.size) { level = 0, status = "new" }

        Nothing ->
            List.repeat (max 0 deck.size) { level = 0, status = "new" }


{-| A tier's columns are worked out from its count. A set's are its own
shape: the fifteen openings in a row, the replies 21 rolls to a row (a
row per opening).
-}
columns : Deck -> Maybe Int
columns deck =
    case deck.kind of
        Tier ->
            Nothing

        Set ->
            if deck.size >= 21 then
                Just 21

            else
                Just (max 1 deck.size)


counts : Deck -> Maybe { total : Int, untouched : Int, inProgress : Int, patched : Int }
counts deck =
    deck.standing
        |> Maybe.andThen
            (\standing ->
                if standing.total > 0 then
                    Just
                        { total = standing.total
                        , untouched = standing.untouched
                        , inProgress = standing.inProgress
                        , patched = standing.patched
                        }

                else
                    Nothing
            )


stateSentence : Who -> Deck -> String
stateSentence who deck =
    case ( counts deck, deck.kind ) of
        ( Just c, Tier ) ->
            Mistakes.stateLine c

        ( Just c, Set ) ->
            Decks.stateLine c

        ( Nothing, Tier ) ->
            if who == Guest then
                Mistakes.guestStateLine deck.size deck.id

            else
                Mistakes.rowLeft 0

        ( Nothing, Set ) ->
            Decks.sizeLine deck.size


{-| The state line, with the grid's own colour beside each part, so the
line is the grid's legend. Read out as the one sentence.
-}
stateLine : CardConfig msg -> Deck -> Html msg
stateLine config deck =
    let
        parts =
            case ( counts deck, deck.kind ) of
                ( Just c, Tier ) ->
                    Mistakes.stateParts c

                ( Just c, Set ) ->
                    Decks.stateParts c

                _ ->
                    [ ( "plain", stateSentence config.who deck ) ]

        part ( state, words ) =
            Html.span [ class ("dk-part is-" ++ state) ]
                [ if state == "total" || state == "plain" then
                    Html.text ""

                  else
                    Html.span [ class ("dk-swatch is-" ++ state), Attr.attribute "aria-hidden" "true" ] []
                , Html.text words
                ]
    in
    Html.p
        [ id (config.prefix ++ "-state")
        , class "dk-state"
        , Attr.attribute "aria-label" (stateSentence config.who deck)
        ]
        (List.map part parts)


{-| A tier's cost, once there are graded games behind it: the line, and
what patching has won back of it when that is anything. A set has no
cost, and a tier with none counted says nothing rather than a zero.
-}
costLines : CardConfig msg -> Deck -> Html msg
costLines config deck =
    case deck.cost of
        Just cost ->
            if cost.games > 0 then
                Html.div [ class "dk-cost", id (config.prefix ++ "-cost") ]
                    [ Html.p [ class "dk-cost-line" ]
                        [ Html.text
                            (Mistakes.costLine
                                { games = cost.games
                                , pr = cost.pr
                                , prWithout = cost.prWithout
                                }
                            )
                        ]
                    , if cost.lostPatched > 0 then
                        case Mistakes.wonBackLine { pr = cost.pr, prPatched = cost.prPatched } of
                            Just won ->
                                Html.p [ class "dk-won", id (config.prefix ++ "-won") ] [ Html.text won ]

                            Nothing ->
                                Html.text ""

                      else
                        Html.text ""
                    ]

            else
                Html.text ""

        Nothing ->
            Html.text ""


{-| The quiet line under the button: what state the deck is in, said for
the button that is there.
-}
quietLine : Who -> Action -> Deck -> String
quietLine who which deck =
    let
        standing =
            Maybe.withDefault zero deck.standing
    in
    case which of
        FixOne ->
            Mistakes.workLine { due = standing.due, newLeft = standing.newLeft }

        Practice ->
            if who == Guest then
                Mistakes.guestPracticeLine

            else
                Mistakes.workLine { due = standing.due, newLeft = standing.newLeft }

        KeepGoing ->
            Mistakes.keepGoingLine
                { done = standing.doneToday
                , adds = min (max 0 deck.pace) standing.untouched
                }

        PracticeAnyway ->
            Mistakes.scheduledLine

        Start ->
            Decks.startLine deck.pace

        Try ->
            Decks.tryLine

        NoAction ->
            ""


zero : Standing
zero =
    { total = 0
    , untouched = 0
    , inProgress = 0
    , patched = 0
    , due = 0
    , newLeft = 0
    , doneToday = 0
    , targetToday = 0
    , levels = []
    }



-- THE ROWS


type alias RowConfig msg =
    { who : Who
    , deck : Deck
    , onPick : String -> msg
    , prefix : String
    }


{-| A deck that is not in front: its mark (or the blank of one), its
name, today's ring at row size, how many are left, and a chevron.
Tapping it puts it in front. A tier with nothing of the visitor's in it
is a quiet line and nothing to tap.
-}
row : RowConfig msg -> Html msg
row config =
    let
        deck =
            config.deck

        tappable =
            action config.who deck /= NoAction

        ring =
            case deck.standing of
                Just standing ->
                    if config.who == Account && standing.targetToday > 0 then
                        Charts.miniRing
                            { done = standing.doneToday
                            , target = standing.targetToday
                            , label = ringSentence standing
                            }

                    else
                        Html.text ""

                Nothing ->
                    Html.text ""

        inside =
            [ Html.span [ class "dk-row-mark", Attr.attribute "aria-hidden" "true" ] [ Html.text deck.mark ]
            , Html.span [ class "dk-row-name" ] [ Html.text deck.name ]
            , Html.span [ class "dk-row-ring" ] [ ring ]
            , Html.span [ class "dk-row-left" ] [ Html.text (left config.who deck) ]
            , Html.span [ class "dk-row-chev", Attr.attribute "aria-hidden" "true" ]
                [ Html.text
                    (if tappable then
                        "›"

                     else
                        ""
                    )
                ]
            ]

        common =
            [ id (config.prefix ++ "-row-" ++ deck.id)
            , Attr.attribute "data-deck" deck.id
            ]
    in
    if tappable then
        Html.button
            (Attr.type_ "button" :: class "dk-row" :: onClick (config.onPick deck.id) :: common)
            inside

    else
        Html.p (class "dk-row is-quiet" :: common) inside


{-| A row's number: what is still to fix or to learn. A tier's is
everything not patched; a set's the same once added, else its size; a
guest's tier its count.
-}
left : Who -> Deck -> String
left who deck =
    case ( deck.kind, deck.standing ) of
        ( Tier, Just standing ) ->
            Mistakes.rowLeft (standing.total - standing.patched)

        ( Tier, Nothing ) ->
            if who == Guest then
                Mistakes.rowLeft deck.size

            else
                Mistakes.rowLeft 0

        ( Set, Just standing ) ->
            if deck.joined && standing.total > 0 then
                Decks.rowLeft (standing.total - standing.patched)

            else
                Decks.rowLeft deck.size

        ( Set, Nothing ) ->
            Decks.rowLeft deck.size
