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
            [ ( "px-2 py-1 rounded-md flex items-center gap-2 bg-black/40 border", True )
            , ( "border-yellow-400 text-white", player.running && not expired )
            , ( "border-white/10 text-gray-400", not player.running && not expired )
            , ( "border-red-500 text-red-300", expired )
            , ( "text-blue-300", player.id == playerId && not expired )
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
