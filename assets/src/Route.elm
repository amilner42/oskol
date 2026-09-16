module Route exposing
    ( Route(..)
    , fromUrl
    , gameLanding
    , href
    , invite
    , library
    , play
    , replay
    )

{-| Client-side routes, mirroring the server's browser routes exactly:

    /            the game library
    /:slug       one game's start page (`?game=` an invite)
    /:slug/:id   a running game
    /:slug/:id/replay   a game played again, turn by turn, with its analysis
                        (`?game=` which game of the match)

No route carries a credential. Who a visitor is rides on their guest cookie,
which the browser sends on its own; a URL only ever says which room, and
what that room will show is the room's decision. Links minted before seat
tokens were dropped carry a `?t=`: no parser reads it, so it is ignored.

The query parameters that remain are part of the route because they decide
what a page shows, exactly as they did in the LiveView's `handle_params`.

-}

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), (<?>), Parser, map, oneOf, s, string, top)
import Url.Parser.Query as Query


type Route
    = Library
      -- slug, ?game= (a room code)
    | GameLanding String (Maybe String)
      -- slug, game id
    | Play String String
      -- slug, game id, ?game= (a game's number)
    | Replay String String (Maybe Int)


parser : Parser (Route -> a) a
parser =
    oneOf
        [ map Library top
        , map Play (string </> string)
        , map Replay (string </> string </> s "replay" <?> Query.int "game")
        , map GameLanding (string <?> Query.string "game")
        ]


fromUrl : Url -> Maybe Route
fromUrl url =
    if url.path == "/sitemap.xml" || String.startsWith "/dev/" url.path then
        Nothing

    else
        Parser.parse parser url


library : Route
library =
    Library


gameLanding : String -> Route
gameLanding slug =
    GameLanding slug Nothing


{-| The plain invite link for a room: what a creator sends their opponent.
-}
invite : String -> String -> Route
invite slug gameId =
    GameLanding slug (Just gameId)


play : String -> String -> Route
play slug gameId =
    Play slug gameId


href : Route -> String
href route =
    case route of
        Library ->
            "/"

        -- the backgammon page is the home page
        GameLanding "backgammon" Nothing ->
            "/"

        GameLanding slug game ->
            "/" ++ slug ++ query [ ( "game", game ) ]

        Play slug gameId ->
            "/" ++ slug ++ "/" ++ gameId

        Replay slug gameId game ->
            "/" ++ slug ++ "/" ++ gameId ++ "/replay" ++ query [ ( "game", Maybe.map String.fromInt game ) ]


{-| A game of a room played again. It opens for anyone with the link: a
replay is what both players and any spectator already saw.
-}
replay : String -> String -> Maybe Int -> Route
replay slug gameId game =
    Replay slug gameId game


query : List ( String, Maybe String ) -> String
query pairs =
    case
        pairs
            |> List.filterMap
                (\( key, value ) ->
                    Maybe.map (\v -> key ++ "=" ++ Url.percentEncode v) value
                )
    of
        [] ->
            ""

        parts ->
            "?" ++ String.join "&" parts
