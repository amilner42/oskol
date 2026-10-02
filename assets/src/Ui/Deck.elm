module Ui.Deck exposing
    ( Action(..)
    , Begun
    , CardConfig
    , RowConfig
    , Size(..)
    , Who(..)
    , action
    , actionLabel
    , begun
    , card
    , cells
    , columns
    , costLines
    , left
    , row
    )

{-| A deck as an open drawer (the card) or a closed one (the row): what
the practice home draws, and the card a deck's own page draws too.

A deck is one of five -- a tier of the player's own mistakes (`??`, `?`,
`?!`) or a universal set (the openings, the replies to them) -- or a set
an account made itself, in the one shape the server gives them all
(`Api.PracticeDecks`). Card and row both start with the deck's icon: a
tier's mark in the replay's colour for its grade, a set's dice, an own
set's bookmark. The card is:

  - **the head**: the icon, the tier's name (or the set's name big with
    its size in the eyebrow style under it), and to the right today's
    ring ("3/5", a check once today's set is done);
  - **the mastery grid**: a square per position, coloured by its rung,
    so a deck's size and how much of it is learnt are one picture, and
    the square an answer lit is the thing that changed;
  - **the state line**, which is the grid's legend in words: "12 mastered
    · 20 learning · 12 to learn · of 44";
  - for a tier, **what it cost**: "These cost you 11.3 points over 11
    games. Without them your PR would be 4.8, not 8.3.";
  - **one button**, never absent where there is anything to practice:
    TRAIN while today has work, KEEP GOING once today's set is done
    and something is still unstarted, PRACTICE ANYWAY once everything
    is, START / TRAIN / TRY on a set, OPEN ANALYSIS on an own set with nothing in
    it yet (a link to the board positions are saved from); and under it
    one quiet line for the state it is in.

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
import Svg
import Svg.Attributes as SvgAttr
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


{-| What a run is told of the deck it was started from, whether the hub
or the deck's own page started it: its day, for the ring over the board
(today's set grown by what KEEP GOING just started), and whether it is
PRACTICE ANYWAY -- every answer early, practice only.
-}
type alias Begun =
    { deckToday : Maybe { done : Int, target : Int }
    , anyway : Bool
    , slug : String
    }


begun : Deck -> Action -> Int -> Begun
begun deck which started =
    { deckToday =
        deck.standing
            |> Maybe.map
                (\standing ->
                    { done = standing.doneToday
                    , target =
                        if which == KeepGoing then
                            standing.targetToday + started

                        else
                            standing.targetToday
                    }
                )
    , anyway = which == PracticeAnyway
    , slug = deck.slug
    }


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
    | OpenAnalysis
    | NoAction


{-| The button a deck offers this visitor, decided from the deck's own
standing and nothing else:

  - an account's tier: TRAIN (`FixOne`) while it has something due or new today;
    once today's set is done, KEEP GOING while anything is unstarted,
    then PRACTICE ANYWAY;
  - an account's set: START until it is added, then the same three, with
    TRAIN (`Practice`) where a tier has `FixOne`;
  - a guest's tier with mistakes in it: TRAIN (`Practice`; nothing is kept);
  - a set for a guest or a stranger: TRY;
  - an account's own set: the same three as a set it added, and OPEN
    ANALYSIS while there is nothing in it (an own set is only ever its
    owner's, so nobody else is offered anything).

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

        ( Account, Own ) ->
            case deck.standing of
                Just standing ->
                    if standing.total > 0 then
                        onwards Practice standing

                    else
                        OpenAnalysis

                Nothing ->
                    OpenAnalysis

        ( _, Own ) ->
            NoAction


{-| Today's work first, then more of the pace, then practice that moves
nothing. Never nothing: there is always a way to keep practicing.
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
            "TRAIN"

        Practice ->
            "TRAIN"

        KeepGoing ->
            "KEEP GOING"

        PracticeAnyway ->
            "PRACTICE ANYWAY"

        Start ->
            "START"

        Try ->
            "TRY"

        OpenAnalysis ->
            "OPEN ANALYSIS"

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

        OpenAnalysis ->
            "open-analysis"

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
            [ if which == OpenAnalysis then
                -- Nothing in it yet: the button's slot is the way to the
                -- board a position is saved from.
                Html.a
                    [ Attr.href "/analysis"
                    , id (config.prefix ++ "-open-analysis")
                    , class ("q-btn dk-go is-" ++ actionName which)
                    , Attr.attribute "data-action" (actionName which)
                    ]
                    [ Html.text (actionLabel which) ]

              else
                Html.button
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

        Own ->
            "own"


head : CardConfig msg -> Html msg
head config =
    let
        deck =
            config.deck
    in
    Html.div [ class "dk-head" ]
        [ Html.div [ class "dk-head-id" ]
            [ icon Large deck
            , Html.div [ class "dk-title" ]
                (case deck.kind of
                    Tier ->
                        [ Html.h2 [ class "dk-name is-tier", id (config.prefix ++ "-name") ] [ Html.text deck.name ]
                        , nameRow config []
                        ]

                    _ ->
                        [ Html.h2 [ class "dk-setname", id (config.prefix ++ "-name") ] [ Html.text deck.name ]
                        , nameRow config [ Html.p [ class "dk-name" ] [ Html.text (Decks.sizeEyebrow deck.size) ] ]
                        ]
                )
            ]
        , case deck.standing of
            Just standing ->
                if config.who == Account && (deck.kind == Tier || deck.joined) && not (deck.kind == Own && standing.total <= 0) then
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


type IconSize
    = Small
    | Large


{-| What a deck is, at a glance, in a small tinted tile: a tier's own
mark in the replay's colour for that grade (`Mistakes.markClass`), on a
wash of the same colour; a set's die (two for the replies) on a neutral
paper, which is no grade's. A row's is the row's height less its
padding; the card's is the head's.
-}
icon : IconSize -> Deck -> Html msg
icon size deck =
    let
        sizeClass =
            case size of
                Small ->
                    "is-small"

                Large ->
                    "is-large"
    in
    case deck.kind of
        Tier ->
            Html.span
                [ class ("dk-icon " ++ sizeClass ++ " is-" ++ deck.id)
                , Attr.attribute "data-band" deck.id
                , Attr.attribute "aria-hidden" "true"
                ]
                [ Html.span [ class ("dk-mark " ++ Mistakes.markClass deck.id) ] [ Html.text deck.mark ] ]

        Set ->
            Html.span
                [ class ("dk-icon " ++ sizeClass ++ " is-set")
                , Attr.attribute "aria-hidden" "true"
                ]
                [ dice deck ]

        Own ->
            Html.span
                [ class ("dk-icon " ++ sizeClass ++ " is-own")
                , Attr.attribute "aria-hidden" "true"
                ]
                [ bookmark ]


{-| An own set's icon: a bookmark, the thing a position saved for later
is kept with.
-}
bookmark : Html msg
bookmark =
    Svg.svg [ SvgAttr.viewBox "0 0 28 28", SvgAttr.class "dk-dice" ]
        [ Svg.path
            [ SvgAttr.d "M8.5 4.5 h11 a1.5 1.5 0 0 1 1.5 1.5 v17.5 l-7 -4.6 l-7 4.6 v-17.5 a1.5 1.5 0 0 1 1.5 -1.5 z"
            , SvgAttr.fill "#fff"
            , SvgAttr.stroke "currentColor"
            , SvgAttr.strokeWidth "1.8"
            , SvgAttr.strokeLinejoin "round"
            ]
            []
        ]


{-| One die for the openings (a roll, and that is the whole position),
two for the replies (a roll after a roll).
-}
dice : Deck -> Html msg
dice deck =
    let
        die x y pips =
            Svg.g []
                (Svg.rect
                    [ SvgAttr.x (String.fromFloat x)
                    , SvgAttr.y (String.fromFloat y)
                    , SvgAttr.width "16"
                    , SvgAttr.height "16"
                    , SvgAttr.rx "3.5"
                    , SvgAttr.fill "#fff"
                    , SvgAttr.stroke "currentColor"
                    , SvgAttr.strokeWidth "1.6"
                    ]
                    []
                    :: List.map
                        (\( px, py ) ->
                            Svg.circle
                                [ SvgAttr.cx (String.fromFloat (x + px))
                                , SvgAttr.cy (String.fromFloat (y + py))
                                , SvgAttr.r "1.6"
                                , SvgAttr.fill "currentColor"
                                ]
                                []
                        )
                        pips
                )

        five =
            [ ( 4.5, 4.5 ), ( 11.5, 4.5 ), ( 8, 8 ), ( 4.5, 11.5 ), ( 11.5, 11.5 ) ]

        three =
            [ ( 4.5, 4.5 ), ( 8, 8 ), ( 11.5, 11.5 ) ]
    in
    Svg.svg [ SvgAttr.viewBox "0 0 28 28", SvgAttr.class "dk-dice" ]
        (if deck.id == "openings" then
            [ die 6 6 five ]

         else
            [ die 2 9 three, die 10 3 five ]
        )


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

                _ ->
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
order that reads as progress (mastered first, then the yellows, then
what is still to learn); anybody else's deck is all paper, one square
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

        -- Whatever the player saved into it, in no shape of its own.
        Own ->
            Nothing


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

        ( Just c, _ ) ->
            Decks.stateLine c

        ( Nothing, Tier ) ->
            if who == Guest then
                Mistakes.guestStateLine deck.size deck.id

            else
                Mistakes.rowLeft 0

        ( Nothing, Set ) ->
            Decks.sizeLine deck.size

        ( Nothing, Own ) ->
            if deck.size <= 0 then
                "No positions yet"

            else
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

                ( Just c, _ ) ->
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

        OpenAnalysis ->
            Decks.emptyOwnLine

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


{-| A deck whose drawer is closed: its icon, its name, today's ring at
row size, how many are left, and a chevron. Tapping it opens it where it
is (`aria-controls` names its slot). A tier with nothing of the
visitor's in it is a quiet line and nothing to tap.
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
            [ Html.span [ class "dk-row-mark" ] [ icon Small deck ]
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
        -- A closed drawer: pressed, its own slot opens to the card.
        Html.button
            (Attr.type_ "button"
                :: class "dk-row"
                :: Attr.attribute "aria-expanded" "false"
                :: Attr.attribute "aria-controls" (config.prefix ++ "-slot-" ++ deck.id)
                :: onClick (config.onPick deck.id)
                :: common
            )
            inside

    else
        Html.p (class "dk-row is-quiet" :: common) inside


{-| A row's number: what is still to master. A tier's is
everything not mastered; a set's the same once added, else its size; a
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

        ( Own, Just standing ) ->
            if standing.total > 0 then
                Decks.rowLeft (standing.total - standing.patched)

            else
                "Empty"

        ( Own, Nothing ) ->
            if deck.size > 0 then
                Decks.rowLeft deck.size

            else
                "Empty"
