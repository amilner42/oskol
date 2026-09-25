module Ui.Tiers exposing (Config, shown, view)

{-| **One deck in front of you.**

The practice hub and the home's practice section both show the same
thing: one tier of your mistakes, named by the mark the replay already
draws beside every move -- `??` very bad, `?` bad, `?!` dubious -- with
the one number that matters, its own bar, and one button. The other
tiers sit under it as quiet rows you may tap.

It lives in one module because two pages showing two arrangements of the
same three numbers is how a product stops feeling like one product. The
words are all `Ui.Mistakes`; the bar is `Ui.Charts.patched`.

**Which tier is in front.** The worst tier the player has made a mistake
in at all, unless they tapped another. If that tier still has work today
the button is FIX ONE. If it has none -- nothing due, and the day's new
ones done -- the card says so warmly and offers the worst tier that does
have work (the server's `lead`) as its own button. When no tier has any
work, there is one warm line and nothing to press.

Nothing here decides what work is: the server sends each tier's `due`
and `newLeft`, already capped by the day's budget of new mistakes, and
`lead`. A page that worked it out for itself could disagree with the
queue it is about to be handed.

-}

import Api.Practice as Practice exposing (Band)
import Html exposing (Html)
import Html.Attributes as Attr exposing (class, id)
import Html.Events exposing (onClick)
import Ui.Charts as Charts
import Ui.Mistakes as Mistakes
import Ui.Notebook as Notebook


type alias Config msg =
    { bands : List Band

    -- The worst tier that still has work, as the server chose it.
    , lead : Maybe String

    -- The tier the player tapped, if they tapped one.
    , selected : Maybe String

    -- What "patched" means, said once under the card.
    , patchedLevel : Int

    -- A press already in flight: the button is disabled and says so.
    , busy : Bool
    , onFix : String -> msg
    , onSelect : String -> msg

    -- "hub" or "home": the two pages are never on screen together, but
    -- their tests name the same parts and a prefix keeps them apart.
    , prefix : String
    }


{-| The tier this card is about: what the player tapped, else the worst
one they have made a mistake in at all.

Deliberately **not** the server's `lead`. The lead is the worst tier with
work left; the card is the worst tier that exists, so a player whose very
bad moves are all in hand is told so, and only then offered the next tier
down. A tier with nothing in it is never shown, tapped or not.
-}
shown : Config msg -> Maybe Band
shown config =
    let
        real =
            List.filter (\band -> band.total > 0) config.bands
    in
    case config.selected |> Maybe.andThen (\grade -> find grade real) of
        Just band ->
            Just band

        Nothing ->
            List.head real


view : Config msg -> Html msg
view config =
    case shown config of
        -- No mistakes of any tier. The page has its own words for a
        -- player with nothing to fix yet.
        Nothing ->
            Html.text ""

        Just band ->
            Html.div [ id (config.prefix ++ "-tiers"), class "tier-deck" ]
                (card config band :: rows config band)



-- THE CARD


card : Config msg -> Band -> Html msg
card config band =
    Html.div
        [ id (config.prefix ++ "-tier"), class "tier-card", Attr.attribute "data-tier" band.grade ]
        (Html.div [ class "tier-head" ]
            [ Html.span [ class "tier-mark", Attr.attribute "aria-hidden" "true" ]
                [ Html.text (Mistakes.mark band.grade) ]
            , Html.div [ class "tier-head-words" ] (headWords config band)
            ]
            :: bar band
            :: action config band
        )


{-| The head: the tier's name, and then either the number left to fix or
the sentence that says there is nothing to.
-}
headWords : Config msg -> Band -> List (Html msg)
headWords config band =
    if Mistakes.hasWork band then
        [ Html.p [ class "tier-name" ] [ Html.text (Mistakes.tierName band.grade) ]
        , Html.p [ id (config.prefix ++ "-tier-left"), class "tier-left" ]
            [ Html.text (Mistakes.leftToFix band) ]
        , case Mistakes.patchedAside band of
            Just aside ->
                Html.p [ id (config.prefix ++ "-tier-patched"), class "tier-aside" ]
                    [ Html.text aside ]

            Nothing ->
                Html.text ""
        ]

    else
        [ Html.p [ class "tier-name" ] [ Html.text (Mistakes.tierName band.grade) ]
        , Html.p [ id (config.prefix ++ "-tier-good"), class "tier-good" ]
            [ Html.text
                (if List.any Mistakes.hasWork config.bands then
                    Mistakes.goodShapeLine band.grade

                 else
                    Mistakes.allClearLine
                )
            ]
        , Html.p [ id (config.prefix ++ "-tier-why"), class "tier-aside" ]
            [ Html.text (Mistakes.goodShapeWhy band) ]
        ]


bar : Band -> Html msg
bar band =
    Html.div [ class "tier-bar" ]
        [ Charts.patched
            { total = band.total
            , inProgress = band.inProgress
            , patched = band.patched
            , sentence = Mistakes.line band
            }
        ]


{-| One button, or none.

FIX ONE while this tier has work. When it has not, the worst tier that
does, by name -- and when no tier does, nothing at all: the warm line is
the whole of it, and a button under it would take the moment back.
-}
action : Config msg -> Band -> List (Html msg)
action config band =
    if Mistakes.hasWork band then
        [ Html.button
            [ Attr.type_ "button"
            , id (config.prefix ++ "-fix-one")
            , class "q-btn w-full px-6 py-3.5 text-[15px] mt-4"
            , Attr.disabled config.busy
            , onClick (config.onFix band.grade)
            ]
            [ Html.text
                (if config.busy then
                    "STARTING…"

                 else
                    "FIX ONE"
                )
            ]
        ]

    else
        case workingTier config band of
            Just next ->
                [ Html.button
                    [ Attr.type_ "button"
                    , id (config.prefix ++ "-tier-next")
                    , class "q-btn plain w-full px-6 py-3.5 text-[15px] mt-4"
                    , Attr.attribute "data-tier" next
                    , onClick (config.onSelect next)
                    ]
                    [ Html.text (Mistakes.nextTierLabel next) ]
                ]

            Nothing ->
                []


{-| The tier to offer instead of this one: the server's lead, unless it
is the tier already on the card.
-}
workingTier : Config msg -> Band -> Maybe String
workingTier config band =
    config.lead
        |> Maybe.andThen
            (\grade ->
                if grade == band.grade then
                    Nothing

                else
                    find grade config.bands |> Maybe.map .grade
            )



-- THE QUIET ROWS


{-| Every other tier the player has mistakes in, one quiet line each:
its mark, its name, and how many are left. Tappable, never pushed.

Nothing to press when no tier has any work: the rows are then a record
of where things stand, and the card above them has already said the
only thing there is to say.
-}
rows : Config msg -> Band -> List (Html msg)
rows config band =
    let
        others =
            config.bands
                |> List.filter (\other -> other.total > 0 && other.grade /= band.grade)
    in
    case others of
        [] ->
            []

        _ ->
            [ Html.div [ id (config.prefix ++ "-tier-rows"), class "tier-rows" ]
                (List.map (row config) others)
            ]


row : Config msg -> Band -> Html msg
row config band =
    let
        inside =
            [ Html.span [ class "tier-row-mark", Attr.attribute "aria-hidden" "true" ]
                [ Html.text (Mistakes.mark band.grade) ]
            , Html.span [ class "tier-row-name" ] [ Html.text (Mistakes.tierName band.grade) ]
            , Html.span [ class "tier-row-left" ]
                [ Html.text (String.fromInt (max 0 (band.total - max 0 band.patched)) ++ " left") ]
            ]
    in
    if List.any Mistakes.hasWork config.bands then
        Html.button
            [ Attr.type_ "button"
            , class "tier-row"
            , id (config.prefix ++ "-tier-row-" ++ band.grade)
            , Attr.attribute "data-tier" band.grade
            , onClick (config.onSelect band.grade)
            ]
            inside

    else
        Html.p
            [ class "tier-row is-quiet"
            , id (config.prefix ++ "-tier-row-" ++ band.grade)
            , Attr.attribute "data-tier" band.grade
            , Notebook.style "color: var(--pencil)"
            ]
            inside


find : String -> List Band -> Maybe Band
find grade bands =
    bands |> List.filter (\band -> band.grade == grade) |> List.head
