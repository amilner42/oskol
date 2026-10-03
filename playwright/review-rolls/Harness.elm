module Harness exposing (main)

{-| `Ui.Rolls` on its own, for the review screenshots.

The component is pure and has no page yet: the replay's ROLLS tab is
`rolls-replay` and the analysis board's SHOW ROLLS is `rolls-board`. So that
this ticket's drawing can be looked at before either of them is built, this
puts the real `Ui.Rolls.view` in a mock-up of the panel it will land in --
`.rp-page` / `.rp-side` / `.rp-panel`, the real classes, with a ROLLS tab
beside the three the replay already has -- and wires the toggles to real
messages, so a screenshot is of the shipped component and not of a drawing
of it.

**This is review scaffolding and nothing else.** It is not in
`assets/elm.json`, nothing in the app imports it, and it is compiled only
by `test.js`. When the ROLLS tab lands, the screenshots move onto the real
page (`review-analysis`) and this goes away.

Two screens: the opening position, whose numbers are in `RollsTest.elm`, and
a made-up grid that walks the whole fixed scale, so every colour the ramp
can make -- and the contrast of the dice and the numbers on each of them --
can be checked in one picture. The second is a swatch sheet, not a position.

-}

import Browser
import Games.Backgammon.Rolls as Rolls exposing (Grid)
import Html exposing (Html, button, div, h1, p, span, text)
import Html.Attributes exposing (attribute, class, classList, id)
import Html.Events exposing (onClick)
import Json.Decode as D
import Ui.Rolls as Rolls_


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = \msg model -> ( update msg model, Cmd.none )
        , view = view
        , subscriptions = always Sub.none
        }


type Screen
    = Opening
    | Scale


type alias Model =
    { screen : Screen
    , theme : String
    , drawing : Rolls_.Drawing
    , numbers : Bool
    , moves : Bool
    , outlined : Maybe ( Int, Int )
    , tapped : Maybe ( Int, Int )
    , opening : Grid
    }


type Msg
    = Pick Rolls_.Drawing
    | Numbers
    | Moves
    | Tap ( Int, Int )
    | Screen Screen
    | Theme String


init : String -> ( Model, Cmd Msg )
init fixture =
    ( { screen = Opening
      , theme = "midnight"
      , drawing = Rolls_.Map
      , numbers = False
      , moves = False
      , outlined = Just ( 5, 6 )
      , tapped = Nothing
      , opening =
            D.decodeString Rolls.decoder fixture
                |> Result.withDefault { level = "?", equity = 0, cells = [] }
      }
    , Cmd.none
    )


update : Msg -> Model -> Model
update msg model =
    case msg of
        Pick drawing ->
            { model | drawing = drawing }

        Numbers ->
            { model | numbers = not model.numbers }

        Moves ->
            { model | moves = not model.moves }

        Tap dice ->
            { model | tapped = Just dice }

        Screen screen ->
            { model | screen = screen }

        Theme theme ->
            { model | theme = theme }



-- THE SCALE SHEET


{-| Twenty-one rolls walking the whole fixed scale, +1 down to -1 and past
both ends, so one picture shows every colour the ramp can make and the dice
and the numbers on each of them. The two values either side of 0.72 are
there on purpose: that is where the text turns from black to white, and it
is the worst contrast anywhere on the scale (4.54:1). Made up: a swatch
sheet, not a position.
-}
scale : Grid
scale =
    let
        values =
            [ 1.4, 1, 0.85, 0.75, 0.7, 0.6 ]
                ++ [ 0.5, 0.4, 0.3, 0.2, 0.1, 0.02, 0, -0.02, -0.1, -0.25, -0.45, -0.65, -0.75, -1, -1.6 ]
    in
    { level = "3ply"
    , equity = 0
    , cells =
        List.map2
            (\dice value ->
                { dice = dice
                , weight = Rolls.weightOf dice
                , value = value
                , sign = Rolls.signOf value
                , best = "24/18(2) 13/7(2)"
                }
            )
            Rolls.allRolls
            values
    }



-- THE PANEL IT LANDS IN


view : Model -> Html Msg
view model =
    let
        grid =
            case model.screen of
                Opening ->
                    model.opening

                Scale ->
                    scale
    in
    div [ class ("rp-page paper bg-theme-" ++ model.theme), id "harness" ]
        [ div [ class "rp-head" ]
            [ h1 [ class "pixel text-[10px]" ] [ text "ROLLS · Ui.Rolls review harness" ] ]
        , div [ class "rl-harness-switch" ]
            [ pick (model.screen == Opening) "screen-opening" "THE OPENING" (Screen Opening)
            , pick (model.screen == Scale) "screen-scale" "THE WHOLE SCALE" (Screen Scale)
            , pick (model.theme == "midnight") "theme-midnight" "MIDNIGHT" (Theme "midnight")
            , pick (model.theme == "sand") "theme-sand" "SAND" (Theme "sand")
            ]
        , div [ class "rp-main" ]
            [ p [ class "rl-harness-note" ]
                [ text "The board sits here; the panel below is what the screenshots are of." ]
            , div [ class "rp-side" ]
                [ div [ class "rp-panel", id "rp-panel" ]
                    [ div [ class "rp-tabs", id "rp-tabs" ]
                        [ tab False "OVERVIEW"
                        , tab False "MOVE"
                        , tab False "CUBE"
                        , tab True "ROLLS"
                        ]
                    , div [ class "rp-note" ]
                        [ Rolls_.view
                            { drawing = model.drawing
                            , onDrawing = Pick
                            , numbers = model.numbers
                            , onNumbers = Numbers
                            , moves = model.moves
                            , onMoves = Moves
                            , outlined =
                                case model.screen of
                                    Opening ->
                                        model.outlined

                                    Scale ->
                                        Nothing
                            , tapped = model.tapped
                            , onTap = Tap
                            , mover = "Arie"
                            , words = Rolls_.equity
                            , attrs = [ id "rolls" ]
                            }
                            grid
                        ]
                    ]
                ]
            ]
        ]


tab : Bool -> String -> Html Msg
tab on label =
    button [ classList [ ( "rp-tab pixel text-[8px]", True ), ( "is-on", on ) ] ] [ text label ]


pick : Bool -> String -> String -> Msg -> Html Msg
pick on id_ label msg =
    button
        [ classList [ ( "rl-harness-btn pixel text-[8px]", True ), ( "is-on", on ) ]
        , id id_
        , attribute "aria-pressed"
            (if on then
                "true"

             else
                "false"
            )
        , onClick msg
        ]
        [ span [] [ text label ] ]
