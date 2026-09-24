module Api.Home exposing
    ( Answer(..)
    , Form
    , Game
    , Home
    , Page
    , Point
    , Practice
    , Result_
    , Room
    , Score
    , answerDecoder
    , fetch
    , graded
    , pageDecoder
    )

{-| The signed-in home's own answer, and the page of graded games under it.

    GET /papi/me/home                    everything the page draws
    GET /papi/me/games/graded?before=    the next ten recent rooms

The home is **one** request by design (`src/oskol/handlers/home.gleam`):
the live games, the form, the practice deck and the first ten recent
rooms arrive together, from rows, with no room woken and no engine time
spent. MORE is the only thing that asks again.

The recent list is one entry per **room** -- a match, an unlimited
session or a single game -- with the games of it the engine has graded
inside, because a match to seven is one thing a player remembers playing
and not nine loose lines.

A browser with no account is told exactly that -- `{ok: true, signed_in:
false}` and nothing else -- so the answer is a choice of two, not a record
full of holes: `Guest` means the home this page draws is not this
browser's, and the shell puts the guest home back.

The decoders are strict about what the page prints and lax about what it
does not: a rating that came as null is `Nothing` and never zero, since a
zero PR is a flawless player rather than an unrated one.

-}

import Api exposing (Error)
import Api.Catalog as Catalog exposing (MyGame)
import Api.Practice as Practice
import Json.Decode as D exposing (Decoder)
import Session exposing (Session)


{-| Who the server says is asking.
-}
type Answer
    = Guest
    | Mine Home


type alias Home =
    { live : List MyGame
    , form : Form
    , practice : Practice
    , recent : List Room
    , more : Bool
    , next : Maybe String
    }


{-| The two numbers, the streak beside them and the line under them.
`recent` and `career` are `Nothing` until there are three graded games
(the server's floor, not this page's), and `sentence` says so in words
either way. `series` is **oldest first**: the order the line is drawn in.

`streak` is consecutive days this player was here -- a puzzle answered or
a game of theirs finished -- in their own local day. Zero is a player with
no streak, and the page prints nothing rather than a zero.
-}
type alias Form =
    { games : Int
    , recent : Maybe Float
    , career : Maybe Float
    , streak : Int
    , sentence : String
    , series : List Point
    }


{-| One graded game on the line. The chart needs the rating and the
decisions behind it, and nothing else: a window's own PR is weighted by
decisions, so a nine-decision game cannot weigh like an eighty-nine
decision one (`Ui.Charts.rolling`).
-}
type alias Point =
    { pr : Float
    , decisions : Int
    }


{-| The deck: what is due, how big it is, the cards at each of the eight
levels, whether each of the last thirty days was practised (oldest
first), where today stands against the day's work, and the mistakes
counted by how bad they were with how many of each are patched.
-}
type alias Practice =
    { due : Int
    , deck : Int
    , ladder : List Int
    , days : List Bool
    , today : Practice.Today
    , severity : List Practice.Band
    , patchedLevel : Int
    }


{-| One room as the recent list shows it: a match, an unlimited session
or a single game.

`score` is this account's points first, added up over the games the
engine has graded, so a room half-graded shows the half it knows.
`won` is not read off that score but off the room's own row: it is
`Nothing` while the room is still being played, and `Nothing` rather
than a guess where nothing recorded a winner. `pr` is the rating over
the whole room, decision-weighted, so it is *not* the mean of the games'
own ratings. `path` is the replay of the first graded game of it, which
is where a single-game row goes straight to.
-}
type alias Room =
    { id : String
    , slug : String
    , format : String
    , opponent : Maybe String
    , score : Score
    , over : Bool
    , won : Maybe Bool
    , pr : Float
    , decisions : Int
    , endedAt : Int
    , path : String
    , games : List Game
    }


type alias Score =
    { yours : Int
    , theirs : Int
    }


{-| One graded game inside a room. The room names the opponent, so a game
says only which game it was, how it went, what it was rated and where its
replay is.
-}
type alias Game =
    { gameNumber : Int
    , path : String
    , result : Maybe Result_
    , pr : Float
    , endedAt : Int
    }


{-| How a game ended for this seat. `kind` is the engine's word for it
(`single`, `gammon`, `backgammon`).
-}
type alias Result_ =
    { won : Bool
    , points : Int
    , kind : String
    }


{-| A page of recent rooms, after the first ten.
-}
type alias Page =
    { rooms : List Room
    , more : Bool
    , next : Maybe String
    }


fetch : Session -> (Result Error Answer -> msg) -> Cmd msg
fetch session toMsg =
    Api.get session "/papi/me/home" answerDecoder toMsg


{-| The next ten, from the `next` of the answer before. A marker the
server cannot read is a refusal, not a silent first page, so nothing here
invents one: `before` is passed on exactly as it came.
-}
graded : Session -> Maybe String -> (Result Error Page -> msg) -> Cmd msg
graded session before toMsg =
    Api.get session
        ("/papi/me/games/graded"
            ++ (case before of
                    Just cursor ->
                        "?before=" ++ cursor

                    Nothing ->
                        ""
               )
        )
        pageDecoder
        toMsg


answerDecoder : Decoder Answer
answerDecoder =
    D.oneOf [ D.field "signed_in" D.bool, D.succeed False ]
        |> D.andThen
            (\signedIn ->
                if signedIn then
                    D.map Mine homeDecoder

                else
                    D.succeed Guest
            )


homeDecoder : Decoder Home
homeDecoder =
    D.map6 Home
        (optional "live" [] (D.list Catalog.myGameDecoder))
        (D.field "form" formDecoder)
        (D.field "practice" practiceDecoder)
        (optional "recent" [] (D.list roomDecoder))
        (optional "more" False D.bool)
        (optional "next" Nothing (D.nullable D.string))


pageDecoder : Decoder Page
pageDecoder =
    D.map3 Page
        (optional "rooms" [] (D.list roomDecoder))
        (optional "more" False D.bool)
        (optional "next" Nothing (D.nullable D.string))


{-| A key that may be missing (an older answer, a guest's page of nothing)
but that is read strictly once it is there. A malformed list has to fail
the answer: quietly turning it into an empty one would draw a player with
games as a player with none, which is the same page as a bug.
-}
optional : String -> a -> Decoder a -> Decoder a
optional key fallback decoder =
    D.maybe (D.field key D.value)
        |> D.andThen
            (\present ->
                case present of
                    Nothing ->
                        D.succeed fallback

                    Just _ ->
                        D.field key decoder
            )


formDecoder : Decoder Form
formDecoder =
    D.map6 Form
        (D.field "games" D.int)
        (D.field "recent" (D.nullable D.float))
        (D.field "career" (D.nullable D.float))
        (optional "streak" 0 D.int)
        (D.field "sentence" D.string)
        (optional "series" [] (D.list pointDecoder))


pointDecoder : Decoder Point
pointDecoder =
    D.map2 Point
        (D.field "pr" D.float)
        (D.field "decisions" D.int)


practiceDecoder : Decoder Practice
practiceDecoder =
    D.map7 Practice
        (D.field "due" D.int)
        (D.field "deck" D.int)
        (optional "ladder" [] (D.list D.int))
        (optional "days" [] (D.list D.bool))
        -- The same objects `/papi/practice` carries, and the same
        -- decoders: an answer from before the ring existed reads as a day
        -- with nothing in it rather than failing the whole page.
        (optional "today" { done = 0, target = 0 } Practice.todayDecoder)
        (optional "severity" [] (D.list Practice.bandDecoder))
        (optional "patched_level" 0 D.int)


roomDecoder : Decoder Room
roomDecoder =
    D.map8 Room
        (D.field "id" D.string)
        (D.field "slug" D.string)
        (D.field "format" D.string)
        (D.field "opponent" (D.nullable D.string))
        (D.field "score" scoreDecoder)
        (D.field "over" D.bool)
        (D.field "won" (D.nullable D.bool))
        (D.field "pr" D.float)
        |> andMap (D.field "decisions" D.int)
        |> andMap (D.field "ended_at" D.int)
        |> andMap (D.field "path" D.string)
        |> andMap (D.field "games" (D.list gameDecoder))


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    D.map2 (|>)


scoreDecoder : Decoder Score
scoreDecoder =
    D.map2 Score
        (D.field "yours" D.int)
        (D.field "theirs" D.int)


gameDecoder : Decoder Game
gameDecoder =
    D.map5 Game
        (D.field "game_number" D.int)
        (D.field "path" D.string)
        (D.field "result" (D.nullable resultDecoder))
        (D.field "pr" D.float)
        (D.field "ended_at" D.int)


resultDecoder : Decoder Result_
resultDecoder =
    D.map3 Result_
        (D.field "won" D.bool)
        (D.field "points" D.int)
        (D.field "kind" D.string)
