module Run exposing
    ( Run
    , Source(..)
    , Start
    , answer
    , answers
    , anywayFetched
    , deck
    , goesOn
    , idsDecoder
    , keepGoing
    , keptGoing
    , nextId
    , offersWays
    , practiseAnyway
    , progress
    , queueUrl
    , refetch
    , refetchable
    , refetched
    , score
    , start
    , tier
    , way
    , withStanding
    )

{-| A practice run: the puzzles a session works through, one ANOTHER at
a time, kept by the shell (`Main`) because it outlives every puzzle page
-- each `pushUrl` builds the next page afresh.

Everything here is pure, so the run is tested as the shell drives it
(`RunTest`): what the strip over the board is told, what an answer
counts for, and how a run goes on.

**A run never runs out.** The ids a page started it with are the front of
a queue, not its length: when they are used up the shell asks the same
queue again (`refetch`) and goes on with whatever it has not put in front
of the player yet. Only when that comes back empty is today's set done --
and even then the end card offers a way on (`way`): KEEP GOING (more of
the deck's pace), or PRACTICE ANYWAY once everything is started.

-}

import Api
import Api.Decks
import Api.PracticeDecks as PracticeDecks
import Json.Decode as D
import Json.Encode as E
import Page.Puzzle exposing (DeckToday, Way(..))
import Games.Backgammon.Puzzle exposing (Verdict(..))
import Session exposing (Session)


{-| What started the run, which is what says where more comes from.

  - `Band`: one tier of mistakes (`/papi/practice?band=`), an account's
    or a guest's own;
  - `InSet`: one of the universal sets (`/papi/decks/:id`);
  - `Fixed`: a list handed over whole (one finished game's mistakes):
    there is nothing to ask again, so the run ends at its last.

-}
type Source
    = Band String
    | InSet Api.Decks.Named
    | Fixed


type alias Run =
    { ids : List String
    , at : Int
    , answers : List ( String, Page.Puzzle.Answer ) -- by puzzle id; an answer given again replaces the first
    , next : String -- the page the run was started from: where a guest who signs in at its end goes on to
    , source : Source
    , anyway : Bool -- PRACTICE ANYWAY: every answer early, practice only, nothing moved
    , served : Int -- how much of the rotation PRACTICE ANYWAY has handed this run (its `from`)
    , deckToday : Maybe DeckToday -- the deck's ring: today's set, as the page that started the run read it
    }


{-| How a page starts a run: the ids it fetched, where it was, what the
run is of, and what it knew of the deck's day.
-}
type alias Start =
    { ids : List String
    , next : String
    , source : Source
    , anyway : Bool
    , deckToday : Maybe DeckToday
    }


{-| A run from its first id. Nothing for an empty list: there is nothing
to start.
-}
start : Start -> Maybe Run
start config =
    case config.ids of
        [] ->
            Nothing

        _ ->
            Just
                { ids = config.ids
                , at = 0
                , answers = []
                , next = config.next
                , source = config.source
                , anyway = config.anyway
                , served =
                    if config.anyway then
                        List.length config.ids

                    else
                        0
                , deckToday = config.deckToday
                }


tier : Run -> Maybe String
tier run =
    case run.source of
        Band band ->
            Just band

        _ ->
            Nothing


deck : Run -> Maybe Api.Decks.Named
deck run =
    case run.source of
        InSet named ->
            Just named

        _ ->
            Nothing


openId : Run -> Maybe String
openId run =
    run.ids |> List.drop run.at |> List.head


{-| The puzzle after the open one, among the ids the run holds.
-}
nextId : Run -> Maybe String
nextId run =
    run.ids |> List.drop (run.at + 1) |> List.head


{-| Can the run ask for more once its ids run out?
-}
refetchable : Run -> Bool
refetchable run =
    run.source /= Fixed


{-| Is there somewhere after this puzzle -- an id the run holds, or a
queue to ask again? This is what draws ANOTHER.
-}
goesOn : Run -> Bool
goesOn run =
    nextId run /= Nothing || refetchable run



-- ANSWERS


{-| The answer at the open puzzle, kept on the run, and whether the day
counts it: only the first answer at a puzzle in this run, and only one
that moved something (`Page.Puzzle.countsToday`). An answer given again
replaces the first rather than counting twice. The deck's ring counts it
with the day.
-}
answer : Page.Puzzle.Answer -> Run -> ( Run, Bool )
answer given run =
    case openId run of
        Just id ->
            let
                first =
                    not (List.any (\( other, _ ) -> other == id) run.answers)

                counts =
                    first && Page.Puzzle.countsToday run.anyway given.schedule
            in
            ( { run
                | answers = ( id, given ) :: List.filter (\( other, _ ) -> other /= id) run.answers
                , deckToday =
                    if counts then
                        Maybe.map (\day -> { day | done = day.done + 1 }) run.deckToday

                    else
                        run.deckToday
              }
            , counts
            )

        Nothing ->
            ( run, False )


{-| The run as the open puzzle's page reads it: which one it is, what
happened at each so far, the deck's ring, and whether it is practice
only.
-}
progress : Run -> Page.Puzzle.Progress
progress run =
    { at = run.at
    , marks = List.map (\id -> answerAt id run |> Maybe.map .verdict) run.ids
    , ring = run.deckToday
    , anyway = run.anyway
    }


answerAt : String -> Run -> Maybe Page.Puzzle.Answer
answerAt id run =
    run.answers |> List.filter (\( other, _ ) -> other == id) |> List.head |> Maybe.map Tuple.second


{-| What the run did, in the order it was worked: one entry per puzzle
it answered.
-}
answers : Run -> List Page.Puzzle.Answer
answers run =
    List.filterMap (\id -> answerAt id run) run.ids


{-| A pass is right and anything else is not, and the total is how many
were **answered** -- never the length of the list, which a run that goes
on for ever does not have.
-}
score : Run -> Page.Puzzle.Score
score run =
    let
        done =
            answers run
    in
    { right = List.length (List.filter (\given -> given.verdict == Pass) done)
    , total = List.length done
    }



-- GOING ON


{-| The ids in a session's answer, in its order.
-}
idsDecoder : D.Decoder (List String)
idsDecoder =
    D.field "puzzles" (D.list (D.field "id" D.string))


{-| Ask the run's queue again: the front of it, as the page that started
the run asked (a tier's `?band=`, a set's session), or, through PRACTICE
ANYWAY, the rotation past what this run has already been handed. Nothing
for a run with no queue behind it.
-}
refetch : Session -> Run -> (Result Api.Error (List String) -> msg) -> Cmd msg
refetch session run toMsg =
    case queueUrl run of
        Just path ->
            Api.get session path idsDecoder toMsg

        Nothing ->
            Cmd.none


{-| Where `refetch` asks: the run's queue, and through PRACTICE ANYWAY
how far into the rotation it has been.
-}
queueUrl : Run -> Maybe String
queueUrl run =
    queuePath run.anyway run.served run.source


queuePath : Bool -> Int -> Source -> Maybe String
queuePath anyway served source =
    let
        further =
            "all=1&from=" ++ String.fromInt served
    in
    case source of
        Band band ->
            Just
                ("/papi/practice?band="
                    ++ band
                    ++ (if anyway then
                            "&" ++ further

                        else
                            ""
                       )
                )

        InSet named ->
            Just
                ("/papi/decks/"
                    ++ named.id
                    ++ (if anyway then
                            "?" ++ further

                        else
                            ""
                       )
                )

        Fixed ->
            Nothing


{-| The ids the queue answered, added after the ones the run holds: only
those it has not put in front of the player already, so the same twenty
never come round again. Through PRACTICE ANYWAY the rotation handed over
is counted too, so the next ask starts past it.
-}
refetched : List String -> Run -> Run
refetched fetched run =
    { run
        | ids = run.ids ++ fresh fetched run
        , served =
            if run.anyway then
                run.served + List.length fetched

            else
                run.served
    }


fresh : List String -> Run -> List String
fresh fetched run =
    fetched
        |> List.filter (\id -> not (List.member id run.ids))
        |> dedupe


dedupe : List String -> List String
dedupe ids =
    List.foldl
        (\id kept ->
            if List.member id kept then
                kept

            else
                kept ++ [ id ]
        )
        []
        ids


{-| KEEP GOING once today's set is done: the deck's pace again of
mistakes never shown, started over the day's budget, and the session
after them.
-}
keepGoing : Session -> Run -> (Result Api.Error (List String) -> msg) -> Cmd msg
keepGoing session run toMsg =
    case run.source of
        Band band ->
            Api.post session "/papi/practice/more" (E.object [ ( "band", E.string band ) ]) idsDecoder toMsg

        InSet named ->
            Api.post session ("/papi/decks/" ++ named.id ++ "/more") (E.object []) idsDecoder toMsg

        Fixed ->
            Cmd.none


{-| What KEEP GOING started, on the run: the new ids after the ones it
holds, and today's set grown by as many -- the ring that read 3/3 reads
3/6.
-}
keptGoing : List String -> Run -> Run
keptGoing fetched run =
    let
        added =
            List.length (fresh fetched run)
    in
    refetched fetched
        { run | deckToday = Maybe.map (\day -> { day | target = day.target + added }) run.deckToday }


{-| PRACTICE ANYWAY from the end card: the rotation past what this run
has been handed of it (from its front, if it was not already through it).
-}
practiseAnyway : Session -> Run -> (Result Api.Error (List String) -> msg) -> Cmd msg
practiseAnyway session run toMsg =
    if run.anyway then
        refetch session run toMsg

    else
        refetch session { run | anyway = True, served = 0 } toMsg


{-| What PRACTICE ANYWAY handed over, on the run: from now on every
answer is early and practice only.
-}
anywayFetched : List String -> Run -> Run
anywayFetched fetched run =
    if run.anyway then
        refetched fetched run

    else
        refetched fetched { run | anyway = True, served = 0 }



-- THE WAY ON


{-| Does the end of this run offer a way on? A run through a deck does;
a run of one game's mistakes does not (the end card has the way back).
-}
offersWays : Run -> Bool
offersWays run =
    run.source /= Fixed


{-| The way on, from where the run's deck stands now:

  - work left today (I'M DONE was pressed with some still due, or new
    ones the day still allows): KEEP GOING goes on with it;
  - today's set done, some never shown: KEEP GOING starts the deck's
    pace of them;
  - everything started and nothing due: PRACTICE ANYWAY;
  - nothing in it, or a set not added: no way.

-}
way : Run -> List PracticeDecks.Deck -> Way
way run decks =
    case
        decks
            |> List.filter (\d -> Just d.id == deckId run)
            |> List.head
            |> Maybe.andThen
                (\d ->
                    if d.kind == PracticeDecks.Set && not d.joined then
                        Nothing

                    else
                        Maybe.map (Tuple.pair d) d.standing
                )
    of
        Nothing ->
            NoWay

        Just ( d, standing ) ->
            if standing.due + standing.newLeft > 0 then
                Continue { due = standing.due, newLeft = standing.newLeft }

            else if standing.untouched > 0 then
                MoreNew (clamp 1 standing.untouched (max 1 d.pace))

            else if standing.total > 0 then
                Anyway

            else
                NoWay


deckId : Run -> Maybe String
deckId run =
    case run.source of
        Band band ->
            Just band

        InSet named ->
            Just named.id

        Fixed ->
            Nothing


{-| The deck's day as the server has it now, for a run that is drawing
a ring: the end of a run reads where the deck stands, and that is fresher
than the count the run began with.
-}
withStanding : List PracticeDecks.Deck -> Run -> Run
withStanding decks run =
    case ( run.deckToday, decks |> List.filter (\d -> Just d.id == deckId run) |> List.head |> Maybe.andThen .standing ) of
        ( Just _, Just standing ) ->
            { run | deckToday = Just { done = standing.doneToday, target = standing.targetToday } }

        _ ->
            run
