module Route exposing
    ( Route(..)
    , fromUrl
    , gameLanding
    , login
    , replayAt
    , href
    , invite
    , library
    , play
    , puzzle
    , puzzles
    , replay
    )

{-| Client-side routes, mirroring the server's browser routes exactly:

    /            the game library
    /:slug       one game's start page (`?game=` an invite)
    /login/:token  the page a mailed sign-in link opens
    /puzzles     the practice home: what you have to practice, or one to try
    /puzzles/:id one puzzle: a position and its question
    /:slug/:id   a running game
    /:slug/:id/replay   a game played again, turn by turn, with its analysis
                        (`?game=` which game of the match, `?step=` the line
                        of its record on the board: the page keeps it current,
                        so a reload and a shared link land on the same move)

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
      -- the token a mailed sign-in link carried
    | Login String
      -- slug, ?game= (a room code)
    | GameLanding String (Maybe String)
      -- the practice home
    | Puzzles
      -- a puzzle, by id
    | Puzzle String
      -- slug, game id
    | Play String String
      -- slug, game id, ?game= (a game's number), ?step= (a line of its record)
    | Replay String String (Maybe Int) (Maybe Int)


parser : Parser (Route -> a) a
parser =
    oneOf
        [ map Library top
        -- Before Play: "login" is a reserved word, not a game slug, exactly
        -- as the server's router has it.
        , map Login (s "login" </> string)
        -- Likewise "puzzles": before Play, or /puzzles/:id would be a
        -- room of a game called puzzles.
        , map Puzzles (s "puzzles")
        , map Puzzle (s "puzzles" </> string)
        , map Play (string </> string)
        , map Replay (string </> string </> s "replay" <?> Query.int "game" <?> Query.int "step")
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


{-| The page a mailed sign-in link opens.
-}
login : String -> Route
login token =
    Login token


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


{-| One puzzle's page. The link is plain: a puzzle names nobody, so there
is nothing for it to carry.
-}
puzzle : String -> Route
puzzle id =
    Puzzle id


{-| The practice home.
-}
puzzles : Route
puzzles =
    Puzzles


href : Route -> String
href route =
    case route of
        Library ->
            "/"

        Login token ->
            "/login/" ++ token

        -- the backgammon page is the home page
        GameLanding "backgammon" Nothing ->
            "/"

        GameLanding slug game ->
            "/" ++ slug ++ query [ ( "game", game ) ]

        Puzzles ->
            "/puzzles"

        Puzzle id ->
            "/puzzles/" ++ id

        Play slug gameId ->
            "/" ++ slug ++ "/" ++ gameId

        Replay slug gameId game step ->
            "/" ++ slug ++ "/" ++ gameId ++ "/replay" ++ query [ ( "game", Maybe.map String.fromInt game ), ( "step", Maybe.map String.fromInt step ) ]


{-| A game of a room played again. It opens for anyone with the link: a
replay is what both players and any spectator already saw.
-}
replay : String -> String -> Maybe Int -> Route
replay slug gameId game =
    Replay slug gameId game Nothing


{-| A replay open on one line of one game: what the page writes as the
reader steps, and what a shared link carries.
-}
replayAt : String -> String -> Int -> Int -> Route
replayAt slug gameId game step =
    Replay slug
        gameId
        (Just game)
        (if step > 0 then
            Just step

         else
            Nothing
        )


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
