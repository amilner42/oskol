module Route exposing
    ( Route(..)
    , analysis
    , analysisPuzzle
    , analysisXgid
    , fromUrl
    , gameLanding
    , login
    , replayAt
    , href
    , invite
    , library
    , play
    , puzzle
    , practice
    , puzzles
    , replay
    )

{-| Client-side routes, mirroring the server's browser routes exactly:

    /            the game library
    /:slug       one game's start page (`?game=` an invite)
    /login/:token  the page a mailed sign-in link opens
    /puzzles     the practice home: what you have to practice, or one to try
    /practice/:slug  one deck's page: a tier of your mistakes or a set
    /puzzles/:id one puzzle: a position and its question (`?s=` a story
                 token: the same puzzle, with the sharer's story after
                 the attempt)
    /analysis    the analysis board: a position set up and asked about
                 (`?xgid=` a position id to open, `?p=` a puzzle to open as
                 its page shows it; bare, the opening position)
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

import Games.Backgammon.Setup exposing (Setup)
import Games.Backgammon.Xgid as Xgid
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
      -- a puzzle, by id, and ?s= (a share-with-my-story token)
    | Puzzle String (Maybe String)
      -- a deck's page, by its slug (very-bad, openings...)
    | Practice String
      -- the analysis board: ?xgid= (an XGID, `XGID=` and all), ?p= (a puzzle id)
    | Analysis (Maybe String) (Maybe String)
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
        , map Puzzle (s "puzzles" </> string <?> Query.string "s")
        -- And "practice": /practice/:slug is a deck, not a room.
        , map Practice (s "practice" </> string)
        -- And "analysis": before both catch-alls, or /analysis would be
        -- a game's start page.
        , map Analysis (s "analysis" <?> Query.string "xgid" <?> Query.string "p")
        , map Play (string </> string)
        , map Replay (string </> string </> s "replay" <?> Query.int "game" <?> Query.int "step")
        , map GameLanding (string <?> Query.string "game")
        ]


fromUrl : Url -> Maybe Route
fromUrl url =
    if url.path == "/sitemap.xml" || String.startsWith "/dev/" url.path then
        Nothing

    else if url.path == "/analysis" then
        Parser.parse parser { url | query = Maybe.map bareEquals url.query }

    else
        Parser.parse parser url


{-| An XGID typed or pasted into the address bar keeps its own `=`
(`?xgid=XGID=-b----E...`), and `Url.Parser.Query` drops any parameter with
a second one. Everything after a parameter's first `=` is its value, so it
is encoded before the parser reads it.
-}
bareEquals : String -> String
bareEquals rawQuery =
    rawQuery
        |> String.split "&"
        |> List.map
            (\param ->
                case String.split "=" param of
                    key :: ((_ :: _ :: _) as rest) ->
                        key ++ "=" ++ String.join "%3D" rest

                    _ ->
                        param
            )
        |> String.join "&"


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
is nothing for it to carry. (A story link carries `?s=`, and the server
mints those: the client only copies what it is handed.)
-}
puzzle : String -> Route
puzzle id =
    Puzzle id Nothing


{-| One deck's page, by its slug: "very-bad", "bad", "dubious",
"openings", "opening-replies".
-}
practice : String -> Route
practice slug =
    Practice slug


{-| The analysis board on the opening position.
-}
analysis : Route
analysis =
    Analysis Nothing Nothing


{-| The analysis board open on a position: what the replay links and a
pasted id opens. The URL carries the XGID, so it pastes anywhere.
-}
analysisXgid : Setup -> Route
analysisXgid setup =
    Analysis (Just (Xgid.encode setup)) Nothing


{-| The analysis board open on a puzzle, as its page shows it.
-}
analysisPuzzle : String -> Route
analysisPuzzle id =
    Analysis Nothing (Just id)


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

        Puzzle id share ->
            "/puzzles/" ++ id ++ query [ ( "s", share ) ]

        Practice slug ->
            "/practice/" ++ slug

        -- `query` percent-encodes the `=` and the `:`s of an XGID, and the
        -- parser decodes them again.
        Analysis xgid p ->
            "/analysis" ++ query [ ( "xgid", xgid ), ( "p", p ) ]

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
