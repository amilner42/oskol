module Api.Decks exposing
    ( Deck
    , Named
    , Standing
    , Session
    , deckDecoder
    , fetchList
    , fetchSession
    , join
    , listDecoder
    , named
    , sessionDecoder
    )

{-| The universal decks -- sets of positions offered to everyone, the
openings first -- as the practice home reads them:

  - `GET /papi/decks` every set on offer, with the caller's standing on
    each (an account's; `standing` is null for anybody else)
  - `GET /papi/decks/:id` what to play next: an account that added the
    set gets its queue, anybody else walks it in order, unsaved
  - `POST /papi/decks/:id/join` add it (an account's), then the same

Which sets exist and how they are practiced is the server's; this only
reads what it said.

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
