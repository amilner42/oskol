module Games.Backgammon.Xgid exposing (encode, decode, notAPositionId)

{-| eXtreme Gammon's position id, the one bgonline, Reddit, XG and GNU
Backgammon all read and write, in and out of a `Setup`.

    XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10
         position                   | | | |  | | | | max cube exponent
                                    | | | |  | | | match length (0: money)
                                    | | | |  | | rule flags
                                    | | | |  | O's score
                                    | | | |  X's score
                                    | | | dice
                                    | | turn
                                    | cube owner
                                    cube exponent

What each field means, as GNU Backgammon's importer reads it (`SetXGID`
in `set.c` and `PositionFromXG` in `positionid.c`, gnubg 1.08), which is
also what eXtreme Gammon writes:

  - **position**, 26 characters, always from X's side whoever is on roll:
    index 0 is O's bar, 1..24 are the points numbered for X (X moves
    24 -> 1), 25 is X's bar. `-` is empty, `A`..`P` one to sixteen of X's
    checkers, `a`..`p` O's. Only O can be on index 0 and only X on 25.
    Borne off is whatever is missing from fifteen.
  - **cube exponent**: the cube is 2 to this power. With a double offered
    (dice `D`) it is the cube as it stood before the double.
  - **cube owner**: 0 centred, 1 X, -1 O (before the double, with `D`).
  - **turn**: 1 X, -1 O: the player on roll -- and with `D`, the player
    who doubled, so the one to answer is the other side (gnubg:
    `fTurn = !fMove`).
  - **dice**: two digits for a roll to play (`63`; either order is read,
    the high die is written first); `00` the player on roll has not rolled
    yet (they may double); `D` a double offered, awaiting take or pass;
    `B` and `R` (beavered, raccooned) we do not model and refuse.
  - **scores**: X's, then O's -- points won, not points away. Money play
    writes 0 and 0, and we ignore them there.
  - **rule flags**: in a match, 1 is the Crawford game and 0 is not (gnubg
    refuses anything else); in money play bit 1 is Jacoby and bit 2
    beavers.
  - **match length**: 0 is money play.
  - **max cube exponent**: XG writes 10; gnubg ignores it (bar 0, cubeless
    play). So do we, and we always write 10.

Oskol's White is X (at the bottom, moving 24 -> 1: the same numbering)
and Black is O. Unlimited play is money with Jacoby, so it writes flags 1
and length 0, and reads any money id as Jacoby: the beaver bit and a
missing Jacoby bit are both read past, because Oskol plays neither
without Jacoby nor with beavers.

`Setup`'s ask maps onto the dice like this:

    Move (Just (a, b))   "ab", high die first, turn = toPlay
    Double               "00", turn = toPlay
    Take                 "D",  turn = the doubler, the other colour
    Move Nothing         "00" -- no roll picked yet; XG reads that as
                         "to roll", which is what it is

and `00` is read back as `Double` where the player on roll could double
and as `Move Nothing` where they could not (the other side owns the cube,
the Crawford game, a dead cube): to XG `00` only says nobody has rolled.

`decode (encode s) == s` for every setup `Setup.check` accepts.

-}

import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)


{-| The one sentence every refusal gives.
-}
notAPositionId : String
notAPositionId =
    "That is not a position id"


encode : Setup -> String
encode setup =
    let
        side color =
            case color of
                White ->
                    1

                Black ->
                    -1

        ( dice, turn ) =
            case setup.ask of
                Move (Just ( a, b )) ->
                    ( String.fromInt (max a b) ++ String.fromInt (min a b), setup.toPlay )

                Move Nothing ->
                    ( "00", setup.toPlay )

                Double ->
                    ( "00", setup.toPlay )

                Take ->
                    ( "D", Setup.other setup.toPlay )

        ( scores, flags, length ) =
            case setup.match of
                Just m ->
                    ( [ m.white, m.black ]
                    , if m.crawford then
                        1

                      else
                        0
                    , m.length
                    )

                Nothing ->
                    ( [ 0, 0 ], 1, 0 )
    in
    "XGID="
        ++ String.join ":"
            ([ position setup
             , String.fromInt (exponent setup.cubeValue)
             , String.fromInt (setup.cubeOwner |> Maybe.map side |> Maybe.withDefault 0)
             , String.fromInt (side turn)
             , dice
             ]
                ++ List.map String.fromInt scores
                ++ [ String.fromInt flags, String.fromInt length, "10" ]
            )


position : Setup -> String
position setup =
    let
        count n =
            if n > 0 then
                letter 'A' n

            else if n < 0 then
                letter 'a' (negate n)

            else
                "-"

        letter base n =
            String.fromChar (Char.fromCode (Char.toCode base + n - 1))
    in
    String.concat
        (count (negate setup.blackBar)
            :: List.map count setup.points
            ++ [ count setup.whiteBar ]
        )


exponent : Int -> Int
exponent value =
    if value <= 1 then
        0

    else
        1 + exponent (value // 2)


decode : String -> Result String Setup
decode raw =
    let
        trimmed =
            String.trim raw

        body =
            if String.startsWith "XGID=" trimmed then
                String.dropLeft 5 trimmed

            else
                trimmed
    in
    (case String.split ":" body of
        [ pos, cube, owner, turn, dice, scoreX, scoreO, flags, length, maxCube ] ->
            readPosition pos
                |> Maybe.andThen
                    (\board ->
                        Maybe.map4 (withDice dice board)
                            (readInt cube |> Maybe.andThen cubeOf)
                            (readInt owner |> Maybe.andThen sideOf)
                            (readInt turn |> Maybe.andThen sideOf |> Maybe.andThen identity)
                            (Maybe.map4 rulesOf (readInt scoreX) (readInt scoreO) (readInt flags) (readInt length)
                                |> Maybe.andThen identity
                            )
                    )
                |> Maybe.andThen identity
                -- The max cube field is read past (XG writes 10, gnubg
                -- ignores it), but it has to be a number.
                |> Maybe.andThen (\setup -> readInt maxCube |> Maybe.map (\_ -> setup))

        _ ->
            Nothing
    )
        |> Result.fromMaybe notAPositionId


type alias Board =
    { points : List Int, whiteBar : Int, blackBar : Int }


withDice :
    String
    -> Board
    -> Int
    -> Maybe Color
    -> Color
    -> Maybe Setup.Match
    -> Maybe Setup
withDice dice board cubeValue cubeOwner turn match =
    let
        base toPlay ask =
            { points = board.points
            , whiteBar = board.whiteBar
            , blackBar = board.blackBar
            , toPlay = toPlay
            , ask = ask
            , cubeValue = cubeValue

            -- A cube at 1 sits in the middle, whatever the owner field
            -- says: an id that names one is read as centered.
            , cubeOwner =
                if cubeValue == 1 then
                    Nothing

                else
                    cubeOwner
            , match = match
            }
    in
    case String.toList dice of
        [ 'D' ] ->
            Just (base (Setup.other turn) Take)

        [ '0', '0' ] ->
            let
                double =
                    base turn Double
            in
            if Setup.canDouble turn double then
                Just double

            else
                Just (base turn (Move Nothing))

        [ a, b ] ->
            Maybe.map2
                (\x y -> base turn (Move (Just ( max x y, min x y ))))
                (die a)
                (die b)

        _ ->
            Nothing


die : Char -> Maybe Int
die c =
    String.toInt (String.fromChar c)
        |> Maybe.andThen
            (\n ->
                if n >= 1 && n <= 6 then
                    Just n

                else
                    Nothing
            )


{-| An integer as XG writes one: an optional minus and digits, nothing
else (`String.toInt` alone would take "+1").
-}
readInt : String -> Maybe Int
readInt s =
    let
        digits =
            if String.startsWith "-" s then
                String.dropLeft 1 s

            else
                s
    in
    if digits /= "" && String.all Char.isDigit digits then
        String.toInt s

    else
        Nothing


cubeOf : Int -> Maybe Int
cubeOf e =
    -- The editor's cube runs 1 to 64.
    if e >= 0 && e <= 6 then
        Just (2 ^ e)

    else
        Nothing


{-| 1 is X (White), -1 is O (Black), 0 nobody.
-}
sideOf : Int -> Maybe (Maybe Color)
sideOf n =
    if n == 1 then
        Just (Just White)

    else if n == -1 then
        Just (Just Black)

    else if n == 0 then
        Just Nothing

    else
        Nothing


rulesOf : Int -> Int -> Int -> Int -> Maybe (Maybe Setup.Match)
rulesOf scoreX scoreO flags length =
    if length < 0 || scoreX < 0 || scoreO < 0 then
        Nothing

    else if length == 0 then
        -- Money: Jacoby and beavers in the flags, both read past.
        if flags >= 0 && flags <= 3 then
            Just Nothing

        else
            Nothing

    else
        case flags of
            0 ->
                Just (Just { length = length, white = scoreX, black = scoreO, crawford = False })

            1 ->
                Just (Just { length = length, white = scoreX, black = scoreO, crawford = True })

            _ ->
                Nothing


readPosition : String -> Maybe Board
readPosition pos =
    let
        chars =
            String.toList pos

        count c =
            let
                code =
                    Char.toCode c
            in
            if c == '-' then
                Just 0

            else if code >= Char.toCode 'A' && code <= Char.toCode 'P' then
                Just (code - Char.toCode 'A' + 1)

            else if code >= Char.toCode 'a' && code <= Char.toCode 'p' then
                Just (negate (code - Char.toCode 'a' + 1))

            else
                Nothing

        counts =
            List.filterMap count chars
    in
    if List.length chars /= 26 || List.length counts /= 26 then
        Nothing

    else
        case ( List.head counts, List.drop 25 counts ) of
            ( Just oBar, [ xBar ] ) ->
                let
                    points =
                        counts |> List.drop 1 |> List.take 24

                    white =
                        xBar + List.sum (List.map (max 0) points)

                    black =
                        negate oBar + List.sum (List.map (\n -> max 0 (negate n)) points)
                in
                if oBar > 0 || xBar < 0 || white > 15 || black > 15 then
                    Nothing

                else
                    Just { points = points, whiteBar = xBar, blackBar = negate oBar }

            _ ->
                Nothing
