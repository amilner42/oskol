module Api.Decks exposing
    ( Deck
    , Named
    , OwnSet
    , Standing
    , Session
    , addPuzzle
    , createOwn
    , deckDecoder
    , deleteOwn
    , fetchList
    , fetchMine
    , fetchSession
    , join
    , listDecoder
    , mineDecoder
    , named
    , ownSetDecoder
    , removePuzzle
    , renameOwn
    , sessionDecoder
    )

{-| The universal decks -- sets of positions offered to everyone, the
openings first -- as the practice home reads them:

  - `GET /papi/decks` every set on offer, with the caller's standing on
    each (an account's; `standing` is null for anybody else)
  - `GET /papi/decks/:id` what to play next: an account that added the
    set gets its queue, anybody else walks it in order, unsaved
  - `POST /papi/decks/:id/join` add it (an account's), then the same

and an account's own sets, which it makes and fills itself:

  - `GET /papi/decks/mine?puzzle=<id>` its sets, oldest first, each saying
    whether it holds that puzzle (the save sheet's checks)
  - `POST /papi/decks/mine {name}` make one
  - `PATCH /papi/decks/:id {name}`, `DELETE /papi/decks/:id` rename and
    delete one
  - `POST /papi/decks/:id/puzzles {puzzle_id}` and
    `DELETE /papi/decks/:id/puzzles/:puzzle_id` put a position in and take
    it out

Which sets exist and how they are practiced is the server's; this only
reads what it said. To a player an own set is a "set", never a deck.

-}

import Api exposing (Error)
import Api.Practice as Practice
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session


{-| A set on offer.
-}
type alias Deck =
    { id : String
    , name : String
    , blurb : String
    , size : Int
    , standing : Maybe Standing
    }


{-| Where an account stands on a set: untouched, in progress, learned --
the three states a mistake has -- and what it has to do today. `total` is
0 until it is added.
-}
type alias Standing =
    { joined : Bool
    , total : Int
    , inProgress : Int
    , patched : Int
    , left : Int
    , due : Int
    , newLeft : Int
    }


{-| What a run through a set needs to say which set it is.
-}
type alias Named =
    { id : String
    , name : String
    }


named : Deck -> Named
named deck =
    { id = deck.id, name = deck.name }


{-| A session of one set.
-}
type alias Session =
    { deck : Deck
    , puzzles : List Practice.Entry
    , today : Maybe Practice.Today
    }


{-| One of an account's own sets, as the save sheet lists it: `holds` is
whether it holds the puzzle the sheet was opened for (False where the
list was not asked about one).
-}
type alias OwnSet =
    { id : String
    , name : String
    , size : Int
    , holds : Bool
    }


fetchList : Session.Session -> (Result Error (List Deck) -> msg) -> Cmd msg
fetchList session toMsg =
    Api.get session "/papi/decks" listDecoder toMsg


fetchSession : Session.Session -> String -> (Result Error Session -> msg) -> Cmd msg
fetchSession session id toMsg =
    Api.get session ("/papi/decks/" ++ id) sessionDecoder toMsg


{-| Add a set, telling the server where the browser is ("" when it could
not say), and answer its session.
-}
join : Session.Session -> String -> String -> (Result Error Session -> msg) -> Cmd msg
join session id tz toMsg =
    Api.post session
        ("/papi/decks/" ++ id ++ "/join")
        (E.object [ ( "tz", E.string tz ) ])
        sessionDecoder
        toMsg


listDecoder : Decoder (List Deck)
listDecoder =
    D.field "decks" (D.list deckDecoder)


sessionDecoder : Decoder Session
sessionDecoder =
    D.map3 Session
        (D.field "deck" deckDecoder)
        (D.field "puzzles" (D.list Practice.entryDecoder))
        (D.field "today" (D.nullable Practice.todayDecoder))


deckDecoder : Decoder Deck
deckDecoder =
    D.map5 Deck
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "blurb" D.string)
        (D.field "size" D.int)
        (D.field "standing" (D.nullable standingDecoder))


standingDecoder : Decoder Standing
standingDecoder =
    D.map7 Standing
        (D.field "joined" D.bool)
        (D.field "total" D.int)
        (D.field "in_progress" D.int)
        (D.field "patched" D.int)
        (D.field "left" D.int)
        (D.field "due" D.int)
        (D.field "new_left" D.int)



-- AN ACCOUNT'S OWN SETS


{-| The account's own sets, each saying whether it holds `puzzleId`.
-}
fetchMine : Session.Session -> String -> (Result Error (List OwnSet) -> msg) -> Cmd msg
fetchMine session puzzleId toMsg =
    Api.get session ("/papi/decks/mine?puzzle=" ++ puzzleId) mineDecoder toMsg


createOwn : Session.Session -> String -> (Result Error OwnSet -> msg) -> Cmd msg
createOwn session name toMsg =
    Api.post session
        "/papi/decks/mine"
        (E.object [ ( "name", E.string name ) ])
        (D.field "deck" ownSetDecoder)
        toMsg


renameOwn : Session.Session -> String -> String -> (Result Error OwnSet -> msg) -> Cmd msg
renameOwn session id name toMsg =
    Api.request session
        "PATCH"
        ("/papi/decks/" ++ id)
        (Just (E.object [ ( "name", E.string name ) ]))
        (D.field "deck" ownSetDecoder)
        toMsg


deleteOwn : Session.Session -> String -> (Result Error () -> msg) -> Cmd msg
deleteOwn session id toMsg =
    Api.request session "DELETE" ("/papi/decks/" ++ id) Nothing (D.succeed ()) toMsg


{-| Save a position into a set: the set as it is after (its size counts
the new one).
-}
addPuzzle : Session.Session -> String -> String -> (Result Error OwnSet -> msg) -> Cmd msg
addPuzzle session id puzzleId toMsg =
    Api.post session
        ("/papi/decks/" ++ id ++ "/puzzles")
        (E.object [ ( "puzzle_id", E.string puzzleId ) ])
        (D.field "deck" ownSetDecoder |> D.map (\set -> { set | holds = True }))
        toMsg


removePuzzle : Session.Session -> String -> String -> (Result Error OwnSet -> msg) -> Cmd msg
removePuzzle session id puzzleId toMsg =
    Api.request session
        "DELETE"
        ("/papi/decks/" ++ id ++ "/puzzles/" ++ puzzleId)
        Nothing
        (D.field "deck" ownSetDecoder)
        toMsg


mineDecoder : Decoder (List OwnSet)
mineDecoder =
    D.field "decks" (D.list ownSetDecoder)


ownSetDecoder : Decoder OwnSet
ownSetDecoder =
    D.map4 OwnSet
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "size" D.int)
        (D.map (Maybe.withDefault False) (D.maybe (D.field "holds" D.bool)))
