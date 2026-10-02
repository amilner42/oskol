module Api.PracticeDecks exposing
    ( Catalog
    , Cell
    , Cost
    , CostAll
    , Deck
    , Kind(..)
    , Member
    , Mistakes
    , Page
    , Standing
    , catalogDecoder
    , deckDecoder
    , fetchDeck
    , fetchList
    , isOwn
    , isSet
    , named
    , pageDecoder
    , practiceAnyway
    , practiceAnywaySet
    , keepGoing
    , keepGoingSet
    )

{-| The five decks a player practices -- the three tiers of their own
mistakes and the two universal sets -- in the one shape the server gives
all five:

    GET /papi/practice/decks         {decks, lead, today, streak,
                                      patched_level, cost_all, mistakes}
    GET /papi/practice/decks/:slug   {deck, cells, days, patched_level,
                                      members}

and the two presses that only make sense of a deck in front of you:

    POST /papi/practice/more {band}  KEEP GOING through a tier: the pace
                                     again of new mistakes, then its session
    POST /papi/decks/:id/more        the same through a set
    GET  ...?all=1                   PRACTICE ANYWAY, once nothing is due

The decoders are **strict about the counts** -- a malformed number is an
error, never a zero the page then prints -- and lax about what the page
does not read: a key it has no use for is ignored, and the two this module
added after the list first shipped (`pace`, `blurb`) default when absent.

-}

import Api exposing (Error)
import Api.Decks as Decks
import Api.Practice as Practice
import Games.Backgammon.Puzzle as Puzzle
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Session



-- TYPES


{-| The list: every deck on offer, which one to put in front, and the
caller's day.

  - `lead` is the server's choice of deck id: the worst tier with work,
    else a set with work, else the worst tier there is. Null when nothing
    is the caller's.
  - `today` is an account's answers in its own day, across every deck;
    `Nothing` for anybody else.
  - `streak` is days running (0 for anybody without an account).
  - `costAll` is what every mistake costs in PR, once there are graded
    games enough; `Nothing` otherwise.
  - `mistakes` is a guest's own: how many, from how many games.

-}
type alias Catalog =
    { decks : List Deck
    , lead : Maybe String
    , today : Maybe Int
    , streak : Int
    , patchedLevel : Int
    , costAll : Maybe CostAll
    , mistakes : Maybe Mistakes
    }


{-| A tier of the player's own mistakes, one of the universal sets, or a
set the account made itself (`"own"`: after the five, practiced as a set
is, with a page of its own and MANAGE).
-}
type Kind
    = Tier
    | Set
    | Own


{-| One deck. `id` is what the wire's presses speak (a band like
"very_bad", or a set's id); `slug` its page's URL segment. `mark` is the
replay's own mark for a tier (`??`), empty for a set. `size` is how many
positions it has for this caller: a tier's mistakes (an account's, a
guest's own, a stranger's none) or a set's. `pace` is how many new ones
KEEP GOING adds.
-}
type alias Deck =
    { id : String
    , slug : String
    , kind : Kind
    , name : String
    , mark : String
    , blurb : String
    , size : Int
    , pace : Int
    , joined : Bool
    , standing : Maybe Standing
    , cost : Maybe Cost
    }


{-| Where an account stands on one deck. The three states -- `untouched`,
`inProgress`, `patched` -- add up to `total`; `levels` is how many sit on
each rung of the ladder, lowest first. Today's set is `targetToday`
(what has been done, plus what is still due, plus the new ones the day
still allows) and the ring is `doneToday` over it.
-}
type alias Standing =
    { total : Int
    , untouched : Int
    , inProgress : Int
    , patched : Int
    , due : Int
    , newLeft : Int
    , doneToday : Int
    , targetToday : Int
    , levels : List Int
    }


{-| What one tier of mistakes cost, over the account's graded games:
`lost` the equity they gave up, `lostPatched` the part of it in the ones
since patched, and the PR three ways -- as it is, without the tier, and
with only the patched ones taken out.
-}
type alias Cost =
    { games : Int
    , lost : Float
    , lostPatched : Float
    , pr : Float
    , prWithout : Float
    , prPatched : Float
    }


type alias CostAll =
    { pr : Float
    , prWithout : Float
    , prPatched : Float
    }


type alias Mistakes =
    { puzzles : Int
    , games : Int
    }


{-| One deck's page: the deck, a cell per position for the mastery grid
(in the deck's own order), and whether each of the last thirty days had
practice in it.
-}
type alias Page =
    { deck : Deck
    , cells : List Cell
    , days : List Bool
    , patchedLevel : Int
    , members : Maybe (List Member)
    }


{-| A position in an own set, for its page's MANAGE: the prompt, the rung
its card stands on (0 for one never answered), and the question as its
puzzle page shows it, for the small board (Nothing where the server could
not read one).
-}
type alias Member =
    { id : String
    , kind : String
    , prompt : String
    , position : Int
    , level : Int
    , question : Maybe Puzzle.Question
    }


type alias Cell =
    { id : String
    , level : Int
    , due : Int -- Unix milliseconds: when it is next due
    , status : String
    , position : Maybe Int
    , band : String
    }


{-| One of the universal sets (not an account's own).
-}
isSet : Deck -> Bool
isSet deck =
    deck.kind == Set


isOwn : Deck -> Bool
isOwn deck =
    deck.kind == Own


{-| What a run through a set needs to say which set it is.
-}
named : Deck -> Decks.Named
named deck =
    { id = deck.id, name = deck.name }



-- REQUESTS


fetchList : Session.Session -> (Result Error Catalog -> msg) -> Cmd msg
fetchList session toMsg =
    Api.get session "/papi/practice/decks" catalogDecoder toMsg


fetchDeck : Session.Session -> String -> (Result Error Page -> msg) -> Cmd msg
fetchDeck session slug toMsg =
    Api.get session ("/papi/practice/decks/" ++ slug) pageDecoder toMsg


{-| KEEP GOING through one tier: the pace again of mistakes never shown,
put in front over the day's budget, and the tier's session after it.
-}
keepGoing : Session.Session -> String -> (Result Error Practice.Practice -> msg) -> Cmd msg
keepGoing session band toMsg =
    Api.post session
        "/papi/practice/more"
        (E.object [ ( "band", E.string band ) ])
        Practice.practiceDecoder
        toMsg


keepGoingSet : Session.Session -> String -> (Result Error Decks.Session -> msg) -> Cmd msg
keepGoingSet session id toMsg =
    Api.post session ("/papi/decks/" ++ id ++ "/more") (E.object []) Decks.sessionDecoder toMsg


{-| PRACTICE ANYWAY through one tier: everything is started and nothing
is due, so the server answers the ones in rotation, soonest due first,
and nothing an answer does moves them.
-}
practiceAnyway : Session.Session -> String -> (Result Error Practice.Practice -> msg) -> Cmd msg
practiceAnyway session band toMsg =
    Api.get session ("/papi/practice?band=" ++ band ++ "&all=1") Practice.practiceDecoder toMsg


practiceAnywaySet : Session.Session -> String -> (Result Error Decks.Session -> msg) -> Cmd msg
practiceAnywaySet session id toMsg =
    Api.get session ("/papi/decks/" ++ id ++ "?all=1") Decks.sessionDecoder toMsg



-- DECODERS


catalogDecoder : Decoder Catalog
catalogDecoder =
    D.map7 Catalog
        (D.field "decks" (D.list deckDecoder))
        (D.field "lead" (D.nullable D.string))
        (D.field "today" (D.nullable (D.field "done" D.int)))
        (D.field "streak" D.int)
        (D.field "patched_level" D.int)
        (optional "cost_all" costAllDecoder)
        (optional "mistakes" mistakesDecoder)


deckDecoder : Decoder Deck
deckDecoder =
    D.succeed Deck
        |> and (D.field "id" D.string)
        |> and (D.field "slug" D.string)
        |> and (D.field "kind" kindDecoder)
        |> and (D.field "name" D.string)
        |> and (D.field "mark" D.string)
        |> and (D.map (Maybe.withDefault "") (optional "blurb" D.string))
        |> and (D.field "size" D.int)
        |> and (D.map (Maybe.withDefault 0) (optional "pace" D.int))
        |> and (D.field "joined" D.bool)
        |> and (D.field "standing" (D.nullable standingDecoder))
        |> and (optional "cost" costDecoder)


{-| A kind this client has never heard of is an error rather than a guess:
a sixth kind of deck is a page change, not a default.
-}
kindDecoder : Decoder Kind
kindDecoder =
    D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "mistakes" ->
                        D.succeed Tier

                    "set" ->
                        D.succeed Set

                    "own" ->
                        D.succeed Own

                    other ->
                        D.fail ("not a kind of deck: " ++ other)
            )


standingDecoder : Decoder Standing
standingDecoder =
    D.succeed Standing
        |> and (D.field "total" D.int)
        |> and (D.field "untouched" D.int)
        |> and (D.field "in_progress" D.int)
        |> and (D.field "patched" D.int)
        |> and (D.field "due" D.int)
        |> and (D.field "new_left" D.int)
        |> and (D.field "done_today" D.int)
        |> and (D.field "target_today" D.int)
        |> and (D.field "levels" (D.list D.int))


costDecoder : Decoder Cost
costDecoder =
    D.map6 Cost
        (D.field "games" D.int)
        (D.field "lost" D.float)
        (D.field "lost_patched" D.float)
        (D.field "pr" D.float)
        (D.field "pr_without" D.float)
        (D.field "pr_patched" D.float)


costAllDecoder : Decoder CostAll
costAllDecoder =
    D.map3 CostAll
        (D.field "pr" D.float)
        (D.field "pr_without" D.float)
        (D.field "pr_patched" D.float)


mistakesDecoder : Decoder Mistakes
mistakesDecoder =
    D.map2 Mistakes
        (D.field "puzzles" D.int)
        (D.field "games" D.int)


pageDecoder : Decoder Page
pageDecoder =
    D.map5 Page
        (D.field "deck" deckDecoder)
        (D.field "cells" (D.list cellDecoder))
        (D.field "days" (D.list D.bool))
        (D.field "patched_level" D.int)
        (optional "members" (D.list memberDecoder))


memberDecoder : Decoder Member
memberDecoder =
    D.map6 Member
        (D.field "id" D.string)
        (D.field "kind" D.string)
        (D.field "prompt" D.string)
        (D.field "position" D.int)
        (D.field "level" D.int)
        (optional "question" Puzzle.questionDecoder)


cellDecoder : Decoder Cell
cellDecoder =
    D.map6 Cell
        (D.field "id" D.string)
        (D.field "level" D.int)
        (D.field "due" D.int)
        (D.field "status" D.string)
        (D.field "position" (D.nullable D.int))
        (D.field "band" D.string)


and : Decoder a -> Decoder (a -> b) -> Decoder b
and =
    D.map2 (|>)


{-| A key that may be absent or null, decoded strictly when it is there.
-}
optional : String -> Decoder a -> Decoder (Maybe a)
optional key decoder =
    D.maybe (D.field key D.value)
        |> D.andThen
            (\present ->
                case present of
                    Nothing ->
                        D.succeed Nothing

                    Just _ ->
                        D.field key (D.nullable decoder)
            )
