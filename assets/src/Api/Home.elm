module Api.Home exposing
    ( Answer(..)
    , Form
    , Game
    , Home
    , Page
    , Point
    , Practice
    , Result_
    , answerDecoder
    , fetch
    , graded
    , pageDecoder
    )

{-| The signed-in home's own answer, and the page of graded games under it.

    GET /papi/me/home                    everything the page draws
    GET /papi/me/games/graded?before=    the next ten graded games

The home is **one** request by design (`src/oskol/handlers/home.gleam`):
the live games, the form, the practice deck and the first ten graded games
arrive together, from rows, with no room woken and no engine time spent.
MORE is the only thing that asks again.

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
    , recent : List Game
    , more : Bool
    , next : Maybe String
    }


{-| The two numbers and the line under them. `recent` and `career` are
`Nothing` until there are three graded games (the server's floor, not
this page's), and `sentence` says so in words either way. `series` is
**oldest first**: the order the line is drawn in.
-}
type alias Form =
    { games : Int
    , recent : Maybe Float
    , career : Maybe Float
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
levels, and whether each of the last thirty days was practised (oldest
first).
-}
type alias Practice =
    { due : Int
    , deck : Int
    , ladder : List Int
    , days : List Bool
    }


{-| One graded game as the list shows it. `path` is its replay.
-}
type alias Game =
    { gameId : String
    , gameNumber : Int
    , slug : String
    , path : String
    , opponent : Maybe String
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


{-| A page of graded games, after the first ten.
-}
type alias Page =
    { games : List Game
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
        (optional "recent" [] (D.list gameDecoder))
        (optional "more" False D.bool)
        (optional "next" Nothing (D.nullable D.string))


pageDecoder : Decoder Page
pageDecoder =
    D.map3 Page
        (optional "games" [] (D.list gameDecoder))
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
    D.map5 Form
        (D.field "games" D.int)
        (D.field "recent" (D.nullable D.float))
        (D.field "career" (D.nullable D.float))
        (D.field "sentence" D.string)
        (optional "series" [] (D.list pointDecoder))


pointDecoder : Decoder Point
pointDecoder =
    D.map2 Point
        (D.field "pr" D.float)
        (D.field "decisions" D.int)


practiceDecoder : Decoder Practice
practiceDecoder =
    D.map4 Practice
        (D.field "due" D.int)
        (D.field "deck" D.int)
        (optional "ladder" [] (D.list D.int))
        (optional "days" [] (D.list D.bool))


gameDecoder : Decoder Game
gameDecoder =
    D.map8 Game
        (D.field "game_id" D.string)
        (D.field "game_number" D.int)
        (D.field "slug" D.string)
        (D.field "path" D.string)
        (D.field "opponent" (D.nullable D.string))
        (D.field "result" (D.nullable resultDecoder))
        (D.field "pr" D.float)
        (D.field "ended_at" D.int)


resultDecoder : Decoder Result_
resultDecoder =
    D.map3 Result_
        (D.field "won" D.bool)
        (D.field "points" D.int)
        (D.field "kind" D.string)
