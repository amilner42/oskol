module Ui.LiveGames exposing (Clocks, ago, mmss, row, yoursFirst)

{-| One row per game a player can pick back up, drawn the same wherever the
list is shown: the guest home's LIVE GAMES dialog over the board
(`Page.GameLanding`) and the signed-in home's first section
(`Page.Home`).

There are two homes now, and a game waiting is the thing both of them open
with, so the row lives here rather than twice: who it is against, what and
how long ago underneath, and on the right whose move it is with the clocks
under that when there are any. The whole row is the link, so it carries no
message and no model -- only the two moments the clocks are read against.

-}

import Api.Catalog as Catalog exposing (MyGame)
import Html exposing (Html)
import Html.Attributes exposing (attribute, class, href, id)
import Ui.Notebook exposing (style)


{-| The two moments a running clock is charged between: when the list came
(`fetchedAt`) and now. Both are milliseconds since the epoch, and both zero
before the page has read a clock, which charges nothing.
-}
type alias Clocks =
    { fetchedAt : Int
    , now : Int
    }


{-| Your move first, then the rest in the order the server sent them
(newest activity first). A stable partition, so two games of yours keep
their order between themselves.

A game in the lobby is nobody's move: it sorts with "theirs" rather than
claiming the top of a list a player reads for what to do next.

-}
yoursFirst : List MyGame -> List MyGame
yoursFirst games =
    List.filter mine games ++ List.filter (\game -> not (mine game)) games


mine : MyGame -> Bool
mine game =
    game.yourMove && game.status /= "waiting"


row : Clocks -> MyGame -> Html msg
row clocks game =
    let
        opponent =
            case game.status of
                "waiting" ->
                    Nothing

                _ ->
                    game.opponent

        ( against, initial ) =
            case opponent of
                Just name ->
                    ( "vs " ++ name, String.left 1 (String.toUpper name) )

                Nothing ->
                    ( "Waiting for a player", "·" )

        ( status, tone ) =
            case opponent of
                Nothing ->
                    ( "Lobby", "lobby" )

                Just _ ->
                    if game.yourMove then
                        ( "Your move", "yours" )

                    else
                        ( "Their move", "theirs" )

        detail =
            game.format ++ " · " ++ ago game.idleS
    in
    Html.li []
        [ Html.a
            [ href game.path
            , id ("resume-" ++ game.id)
            , class ("resume-row flex items-center gap-3 px-3.5 py-3 " ++ tone)
            ]
            [ Html.span [ class "resume-avatar shrink-0 w-10 h-10 rounded-full inline-flex items-center justify-center text-[15px] font-semibold" ] [ Html.text initial ]
            , Html.span [ class "min-w-0 flex-1" ]
                [ Html.span [ class "block font-semibold text-[15px] leading-tight truncate", style "color: var(--ink)" ] [ Html.text against ]
                , Html.span [ class "block q-note text-[12px] leading-tight truncate mt-1" ] [ Html.text detail ]
                ]
            , Html.span [ class "shrink-0 flex flex-col items-end gap-1" ]
                (Html.span [ class ("resume-pill text-[11px] font-semibold leading-none px-2 py-1 rounded-full " ++ tone) ] [ Html.text status ]
                    :: (clockLine clocks game |> Maybe.map List.singleton |> Maybe.withDefault [])
                )
            , Html.span [ class "resume-chevron shrink-0 text-lg leading-none", attribute "aria-hidden" "true" ] [ Html.text "›" ]
            ]
        ]


{-| The two clocks, the running one counting down: mine then theirs. The
row holds the times as the room last read them and how long ago that was;
the running side is charged for that plus the seconds since the list
came, less the free time that was still on the move, so what shows is
what the table would. When the running one is mine it breathes, to say
so. Under no clock, nothing.
-}
clockLine : Clocks -> MyGame -> Maybe (Html msg)
clockLine clocks game =
    case game.time of
        Nothing ->
            Nothing

        Just time ->
            let
                elapsed =
                    time.ageS * 1000 + max 0 (clocks.now - clocks.fetchedAt)

                charged =
                    max 0 (elapsed - time.freeMs)

                left ms running =
                    if running then
                        max 0 (ms - charged)

                    else
                        ms

                mineLeft =
                    mmss (left time.mineMs (time.running == Catalog.Mine))

                theirs =
                    mmss (left time.theirsMs (time.running == Catalog.Theirs))
            in
            Just
                (Html.span [ class "resume-clock text-[12px] leading-none tabular-nums whitespace-nowrap" ]
                    [ Html.span
                        [ class
                            (if time.running == Catalog.Mine then
                                "clock-live"

                             else
                                "clock-mine"
                            )
                        ]
                        [ Html.text mineLeft ]
                    , Html.span [ class "clock-sep" ] [ Html.text " / " ]
                    , Html.span [ class "clock-theirs" ] [ Html.text theirs ]
                    ]
                )


mmss : Int -> String
mmss ms =
    let
        total =
            (ms + 999) // 1000
    in
    String.fromInt (total // 60) ++ ":" ++ String.padLeft 2 '0' (String.fromInt (modBy 60 total))


{-| How long ago, in the coarsest unit that is still honest.
-}
ago : Int -> String
ago seconds =
    if seconds < 60 then
        "just now"

    else if seconds < 3600 then
        String.fromInt (seconds // 60) ++ " min ago"

    else if seconds < 86400 then
        String.fromInt (seconds // 3600) ++ " h ago"

    else
        String.fromInt (seconds // 86400) ++ " d ago"
