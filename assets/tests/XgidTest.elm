module XgidTest exposing (suite)

{-| The XGID codec, pinned by vectors.

Where the vectors come from:

  - The opening position string, `-b----E-C---eE---c-e----B-`, is the one
    eXtreme Gammon writes and GNU Backgammon's bug list and xgid2anki's
    README quote (`XGID=-b----E-C---eE---c-e----B-:0:0:1:21:0:0:0:7:10`).
  - `XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10` is a position
    posted on backgammonforums.com ("How to post positions"): a match to 7
    at 6-4, Crawford.
  - `XGID=-b----E-C---eE---b-d-b--B-:0:0:1:46:0:0:3:0:10` is from
    bug-gnubg (2010-06): money play with Jacoby and beavers, the low die
    written first.
  - The field meanings -- including that with `D` the turn names the
    doubler and the cube is the cube before the double -- are gnubg 1.08's
    `SetXGID` (set.c) and `PositionFromXG` (positionid.c).

-}

import Expect
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)
import Games.Backgammon.Xgid as Xgid
import SetupFuzz
import Test exposing (Test, describe, fuzz, test)


openingPosition : String
openingPosition =
    "-b----E-C---eE---c-e----B-"


opening31 : Setup
opening31 =
    { opening | ask = Move (Just ( 3, 1 )) }


opening : Setup
opening =
    Setup.opening


suite : Test
suite =
    describe "Xgid"
        [ describe "encode"
            [ test "the opening, White to play 3-1, money with Jacoby" <|
                \_ ->
                    Xgid.encode opening31
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10"
            , test "Black to play: the turn is -1 and the position string is unchanged, always from X's side" <|
                \_ ->
                    Xgid.encode { opening31 | toPlay = Black }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:-1:31:0:0:1:0:10"
            , test "a roll is written high die first" <|
                \_ ->
                    Xgid.encode { opening | ask = Move (Just ( 1, 3 )) }
                        |> Expect.equal (Xgid.encode opening31)
            , test "a cube on 2 owned by Black" <|
                \_ ->
                    Xgid.encode { opening31 | cubeValue = 2, cubeOwner = Just Black }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:1:-1:1:31:0:0:1:0:10"
            , test "a cube on 8 owned by White" <|
                \_ ->
                    Xgid.encode { opening31 | cubeValue = 8, cubeOwner = Just White }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:3:1:1:31:0:0:1:0:10"
            , test "a match to 7 at 6-3, the Crawford game: scores X then O, flag 1, length 7" <|
                \_ ->
                    Xgid.encode { opening31 | match = Just { length = 7, white = 6, black = 3, crawford = True } }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:6:3:1:7:10"
            , test "a match that is not the Crawford game writes flag 0" <|
                \_ ->
                    Xgid.encode { opening31 | match = Just { length = 7, white = 5, black = 3, crawford = False } }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:5:3:0:7:10"
            , test "unlimited play is money with Jacoby: flags 1, length 0" <|
                \_ ->
                    Xgid.encode opening31
                        |> String.split ":"
                        |> List.drop 5
                        |> Expect.equal [ "0", "0", "1", "0", "10" ]
            , test "a cube question is dice 00" <|
                \_ ->
                    Xgid.encode { opening | ask = Double }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10"
            , test "a take is D, the turn naming the doubler, the cube as it was before the double" <|
                \_ ->
                    -- Black owns 2 and redoubles: White is asked to take 4.
                    Xgid.encode { opening | ask = Take, cubeValue = 2, cubeOwner = Just Black }
                        |> Expect.equal "XGID=-b----E-C---eE---c-e----B-:1:-1:-1:D:0:0:1:0:10"
            , test "checkers on the bar and borne off" <|
                \_ ->
                    Xgid.encode { opening31 | points = barAndOff.points, whiteBar = 2, blackBar = 1 }
                        |> Expect.equal "XGID=aC----B-------------b---dB:0:0:1:31:0:0:1:0:10"
            ]
        , describe "decode"
            [ test "a cube at 1 with an owner named is read as centered" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:1:1:31:0:0:1:0:10"
                        |> Expect.equal (Ok opening31)
            , test "the opening, White to play 3-1" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10"
                        |> Expect.equal (Ok opening31)
            , test "the dice in either order" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:1:13:0:0:1:0:10"
                        |> Expect.equal (Ok opening31)
            , test "without the XGID= prefix, and with whitespace around it" <|
                \_ ->
                    Xgid.decode "  -b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10\n"
                        |> Expect.equal (Ok opening31)
            , test "Black to play" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:-1:31:0:0:1:0:10"
                        |> Expect.equal (Ok { opening31 | toPlay = Black })
            , test "bug-gnubg's money position: Jacoby and beavers, 4-6 read as 6-4" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---b-d-b--B-:0:0:1:46:0:0:3:0:10"
                        |> Result.map (\s -> ( s.ask, s.match, s.toPlay ))
                        |> Expect.equal (Ok ( Move (Just ( 6, 4 )), Nothing, White ))
            , test "money play without Jacoby is read as Oskol's unlimited play" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:0:0:10"
                        |> Expect.equal (Ok opening31)
            , test "backgammonforums' match to 7 at 6-4, Crawford" <|
                \_ ->
                    Xgid.decode "XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10"
                        |> Expect.equal
                            (Ok
                                { points =
                                    [ 0, 1, 0, -2, 2, 2, 2, 2, 0, 0, 2, -2, 2, 0, 0, 0, 0, 0, -4, -2, -2, -3, 0, 2 ]
                                , whiteBar = 0
                                , blackBar = 0
                                , toPlay = White
                                , ask = Move (Just ( 3, 1 ))
                                , cubeValue = 1
                                , cubeOwner = Nothing
                                , match = Just { length = 7, white = 6, black = 4, crawford = True }
                                }
                            )
            , test "and it checks: nothing stops it being asked" <|
                \_ ->
                    Xgid.decode "XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10"
                        |> Result.map Setup.check
                        |> Expect.equal (Ok Nothing)
            , test "a cube on 2 owned by Black" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:1:-1:1:31:0:0:1:0:10"
                        |> Expect.equal (Ok { opening31 | cubeValue = 2, cubeOwner = Just Black })
            , test "a take: D, so the one asked is the other side from the turn" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:1:-1:-1:D:0:0:1:0:10"
                        |> Expect.equal (Ok { opening | ask = Take, cubeValue = 2, cubeOwner = Just Black })
            , test "00 where the player on roll could double is the cube question" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10"
                        |> Expect.equal (Ok { opening | ask = Double })
            , test "00 where they could not (Black owns the cube) is a roll still to pick" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:1:-1:1:00:0:0:1:0:10"
                        |> Expect.equal (Ok { opening | ask = Move Nothing, cubeValue = 2, cubeOwner = Just Black })
            , test "checkers on the bar and borne off" <|
                \_ ->
                    Xgid.decode "XGID=aC----B-------------b---dB:0:0:1:31:0:0:1:0:10"
                        |> Result.map (\s -> ( ( s.whiteBar, s.blackBar ), ( Setup.offWhite s, Setup.offBlack s ), s.points ))
                        |> Expect.equal (Ok ( ( 2, 1 ), ( 8, 8 ), barAndOff.points ))
            , test "fifteen on one point is O, each side" <|
                \_ ->
                    Xgid.decode "XGID=-O----------------------o-:0:0:1:31:0:0:1:0:10"
                        |> Result.map .points
                        |> Expect.equal (Ok (15 :: List.repeat 22 0 ++ [ -15 ]))
            , test "a match at 5-3 with the Crawford flag decodes, and check says why it cannot be asked" <|
                \_ ->
                    Xgid.decode "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:5:3:1:7:10"
                        |> Result.map Setup.check
                        |> Expect.equal (Ok (Just Setup.crawfordMessage))
            ]
        , describe "refuses, in one sentence"
            ([ ( "the opening one character short", "XGID=-b----E-C---eE---c-e----B:0:0:1:31:0:0:1:0:10" )
             , ( "a field missing", "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0" )
             , ( "a character outside the alphabet", "XGID=-b----E-C---eE---c-e----Q-:0:0:1:31:0:0:1:0:10" )
             , ( "sixteen checkers on a point: P is in the alphabet, sixteen is too many", "XGID=-b----E-C---eE---c-e----P-:0:0:1:31:0:0:1:0:10" )
             , ( "sixteen White checkers in all", "XGID=-b----E-C---eE---c-e----C-:0:0:1:31:0:0:1:0:10" )
             , ( "White on O's bar", "XGID=Ab----E-C---eE---c-e----A-:0:0:1:31:0:0:1:0:10" )
             , ( "Black on X's bar", "XGID=-b----E-C---eE---c-e----Aa:0:0:1:31:0:0:1:0:10" )
             , ( "a die of 7", "XGID=-b----E-C---eE---c-e----B-:0:0:1:71:0:0:1:0:10" )
             , ( "a die of 0 beside a real one", "XGID=-b----E-C---eE---c-e----B-:0:0:1:30:0:0:1:0:10" )
             , ( "a cube owner of 2", "XGID=-b----E-C---eE---c-e----B-:0:2:1:31:0:0:1:0:10" )
             , ( "a turn of 0", "XGID=-b----E-C---eE---c-e----B-:0:0:0:31:0:0:1:0:10" )
             , ( "a beaver (B), which Oskol does not model", "XGID=-b----E-C---eE---c-e----B-:1:-1:-1:B:0:0:3:0:10" )
             , ( "a raccoon (R)", "XGID=-b----E-C---eE---c-e----B-:2:1:1:R:0:0:3:0:10" )
             , ( "a cube past 64", "XGID=-b----E-C---eE---c-e----B-:7:1:1:31:0:0:1:0:10" )
             , ( "a match flag that is not 0 or 1", "XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:2:7:10" )
             , ( "a number that is not one", "XGID=-b----E-C---eE---c-e----B-:x:0:1:31:0:0:1:0:10" )
             , ( "nothing at all", "" )
             , ( "a GNU Backgammon id", "4HPwATDgc/ABMA:cAkAAAAAAAAA" )
             ]
                |> List.map
                    (\( name, id ) ->
                        test name <|
                            \_ -> Xgid.decode id |> Expect.equal (Err "That is not a position id")
                    )
            )
        , describe "round trip"
            [ fuzz SetupFuzz.validSetup "every setup check accepts comes back exactly" <|
                \setup ->
                    ( Setup.check setup, Xgid.decode (Xgid.encode setup) )
                        |> Expect.equal ( Nothing, Ok setup )
            , fuzz SetupFuzz.validSetup "and so does its flip" <|
                \setup ->
                    Xgid.decode (Xgid.encode (Setup.flip setup))
                        |> Expect.equal (Ok (Setup.flip setup))
            , fuzz SetupFuzz.validSetup "an id read back writes the same id" <|
                \setup ->
                    Xgid.decode (Xgid.encode setup)
                        |> Result.map Xgid.encode
                        |> Expect.equal (Ok (Xgid.encode setup))
            ]
        ]


{-| White: two on the bar, three on 1, two on 6, eight off. Black: one on
the bar, two on 20 and four on 24 (Black's own 5 and 1 points), eight off.
-}
barAndOff : { points : List Int }
barAndOff =
    { points =
        List.range 1 24
            |> List.map
                (\p ->
                    case p of
                        1 ->
                            3

                        6 ->
                            2

                        20 ->
                            -2

                        24 ->
                            -4

                        _ ->
                            0
                )
    }
