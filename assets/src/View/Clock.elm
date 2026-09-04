module View.Clock exposing (view)

{-| A compact display of both players' clocks. Game-agnostic: it reads the
protocol clock and the names from the scene.
-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, classList)
import Protocol exposing (Clock, ClockPlayer)


view :
    { clock : Maybe Clock
    , playerId : String
    , receivedAt : Int
    , now : Int
    , nameOf : String -> String
    }
    -> Html msg
view { clock, playerId, receivedAt, now, nameOf } =
    case clock of
        Just c ->
            if c.enabled then
                let
                    ordered =
                        List.filter (\p -> p.id /= playerId) c.players
                            ++ List.filter (\p -> p.id == playerId) c.players
                in
                div [ class "flex flex-col gap-1 items-end font-mono text-xs select-none" ]
                    (List.map (viewPlayer playerId receivedAt now nameOf c.timedOut) ordered)

            else
                text ""

        Nothing ->
            text ""


viewPlayer : String -> Int -> Int -> (String -> String) -> Maybe String -> ClockPlayer -> Html msg
viewPlayer playerId receivedAt now nameOf timedOut player =
    let
        remaining =
            Protocol.remainingNow player receivedAt now

        expired =
            timedOut == Just player.id || remaining <= 0
    in
    div
        [ classList
            [ ( "px-2 py-1 flex items-center gap-2 border-2", True )
            , ( "bg-[color:var(--highlighter)] border-[color:var(--ink)] text-[color:var(--ink)]", player.running && not expired )
            , ( "bg-white border-[color:var(--pencil)] text-[color:var(--pencil)]", not player.running && not expired )
            , ( "bg-white border-[color:var(--red)] text-[color:var(--red)]", expired )
            ]
        ]
        [ span [ class "truncate max-w-[6rem]" ] [ text (nameOf player.id) ]
        , span [ class "tabular-nums font-bold" ]
            [ text
                (if expired then
                    "0:00"

                 else
                    Protocol.formatClock remaining
                )
            ]
        ]
