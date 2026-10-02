module Ui.Candidates exposing (Row, view, mark)

{-| The engine's candidate table: one row per play, in the replay's
columns -- the rank, the move with its mark (✓ ?! ? ??), the equity (or
what it gives up), and the chances (win, gam+, gam−).

One table in three places: the replay's note, a puzzle's reveal and the
analysis board's answer. Each page says what its rows are (which one is on
the board, which one was played, what a tap does) and this draws them the
same way: `.rp-top` with a `.rp-top-head`, each row a `button.rp-cand`
with `data-rank`.

-}

import Games.Backgammon.Replay as Replay
import Games.Backgammon.Words as Words
import Html exposing (Attribute, Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, classList, disabled)
import Html.Events exposing (onClick)


{-| One play in the table.

  - `rank` is the engine's (Nothing for a play it did not rank: "–").
  - `on`: its position is the one on the board.
  - `played`: the play that was made (underlined); `badge` a word after the
    move ("you").
  - `equity` is shown when the play gives up nothing, else what it gives up.
  - `onTap`: what a tap does, Nothing for a row that cannot be shown.
  - `attrs`: anything else a page hangs on its rows (`data-yours`).

-}
type alias Row msg =
    { rank : Maybe Int
    , notation : String
    , equity : Float
    , equityLost : Float
    , probs : Maybe Replay.Probs
    , on : Bool
    , played : Bool
    , badge : Maybe String
    , title : String
    , onTap : Maybe msg
    , attrs : List (Attribute msg)
    }


{-| The table, its rows in the order given. `attrs` go on the table
(an id, a page's own class).
-}
view : List (Attribute msg) -> List (Row msg) -> Html msg
view attrs rows =
    div (class "rp-top" :: attrs)
        (div [ class "rp-top-head" ]
            [ span [] []
            , span [] [ text "move" ]
            , span [ class "rp-col-eq" ] [ text "eq" ]
            , span [ class "rp-col", Html.Attributes.title "How often this move wins" ] [ text "win" ]
            , span [ class "rp-col", Html.Attributes.title "How often it wins a gammon" ] [ text "gam+" ]
            , span [ class "rp-col", Html.Attributes.title "How often it gets gammoned" ] [ text "gam−" ]
            ]
            :: List.map viewRow rows
        )


viewRow : Row msg -> Html msg
viewRow row =
    button
        ([ classList [ ( "rp-cand", True ), ( "is-on", row.on ), ( "is-played", row.played ) ]
         , attribute "data-rank" (row.rank |> Maybe.map String.fromInt |> Maybe.withDefault "")
         , disabled (row.onTap == Nothing)
         , Html.Attributes.title row.title
         ]
            ++ (case row.onTap of
                    Just msg ->
                        [ onClick msg ]

                    Nothing ->
                        []
               )
            ++ row.attrs
        )
        ([ span [ class "rp-rank tabular-nums" ]
            [ text (row.rank |> Maybe.map (\r -> String.fromInt r ++ ".") |> Maybe.withDefault "–") ]
         , span
            [ classList
                [ ( "rp-cand-move", True )

                -- a long notation (doubles, hits) steps the type down
                -- rather than taking a second line
                , ( "is-long", String.length row.notation > 10 )
                , ( "is-longer", String.length row.notation > 15 )
                ]
            ]
            [ text row.notation
            , mark row.equityLost
            , case row.badge of
                Just word ->
                    span [ class "pz-you" ] [ text word ]

                Nothing ->
                    text ""
            ]
         , span [ class "rp-cand-lost rp-col-eq tabular-nums" ]
            [ text
                (if row.equityLost > 0 then
                    "−" ++ Replay.formatEquity row.equityLost

                 else
                    Words.signed row.equity
                )
            ]
         ]
            ++ Words.chanceCells row.probs
        )


{-| The annotators' mark beside a play: how bad it is at a glance.
-}
mark : Float -> Html msg
mark equityLost =
    let
        grade =
            Words.gradeOf equityLost
    in
    case Words.gradeMark grade of
        "" ->
            text ""

        m ->
            span [ class ("rp-cand-grade g-" ++ grade), attribute "data-grade" grade ] [ text m ]
