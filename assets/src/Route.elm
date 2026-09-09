module Route exposing
    ( Route(..)
    , fromUrl
    , gameLanding
    , href
    , invite
    , library
    , play
    )

{-| Client-side routes, mirroring the server's browser routes exactly:

    /            the game library
    /:slug       one game's start page (`?game=` an invite, `?t=` a seat token)
    /:slug/:id   a running game (`?t=` the seat token)

The query parameters are part of the route because they decide what a page
shows, exactly as they did in the LiveView's `handle_params`.

-}

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), (<?>), Parser, map, oneOf, string, top)
import Url.Parser.Query as Query


type Route
    = Library
      -- slug, ?game= (a room code), ?t= (a seat token)
    | GameLanding String (Maybe String) (Maybe String)
      -- slug, game id, ?t= (a seat token)
    | Play String String (Maybe String)


parser : Parser (Route -> a) a
parser =
    oneOf
        [ map Library top
        , map Play (string </> string <?> Query.string "t")
        , map GameLanding (string <?> Query.string "game" <?> Query.string "t")
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
    GameLanding slug Nothing Nothing


{-| The plain invite link for a room: what a creator sends their opponent.
-}
invite : String -> String -> Route
invite slug gameId =
    GameLanding slug (Just gameId) Nothing


play : String -> String -> Maybe String -> Route
play slug gameId token =
    Play slug gameId token


href : Route -> String
href route =
    case route of
        Library ->
            "/"

        GameLanding slug game token ->
            "/" ++ slug ++ query [ ( "game", game ), ( "t", token ) ]

        Play slug gameId token ->
            "/" ++ slug ++ "/" ++ gameId ++ query [ ( "t", token ) ]


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
