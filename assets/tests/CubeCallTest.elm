module CubeCallTest exposing (suite)

{-| The cube call has one rule and two homes: the server's
(`oskol/puzzles.cube_call`, which writes every stored answer and rendered
report) and the client's (`Replay.cubeCall`, which reads the call off the
equities on every page, old reports included). `CubeCallFixtures` is the
server's own verdict on equities at, above and below each line; the Elm
twin has to agree with every one of them.
-}

import CubeCallFixtures
import Expect
import Games.Backgammon.Replay as Replay exposing (Optimal(..))
import Json.Decode as D
import Test exposing (Test, describe, test)


type alias Case =
    { noDouble : Float
    , doubleTake : Float
    , doublePass : Float
    , call : String
    , tooGood : Bool
    , takes : Bool
    }


caseDecoder : D.Decoder Case
caseDecoder =
    D.map6 Case
        (D.field "no_double" D.float)
        (D.field "double_take" D.float)
        (D.field "double_pass" D.float)
        (D.field "call" D.string)
        (D.field "too_good" D.bool)
        (D.field "takes" D.bool)


name : Optimal -> String
name call =
    case call of
        NoDouble ->
            "no_double"

        DoubleTake ->
            "double_take"

        DoublePass ->
            "double_pass"

        OtherCall word ->
            word


suite : Test
suite =
    describe "the cube call, as the server makes it"
        (test "there are cases to check" (\_ -> CubeCallFixtures.all |> List.isEmpty |> Expect.equal False)
            :: List.map
                (\( label, json ) ->
                    test label <|
                        \_ ->
                            case D.decodeString caseDecoder json of
                                Ok c ->
                                    ( name (Replay.cubeCall c.noDouble c.doubleTake c.doublePass)
                                    , Replay.tooGood c.noDouble c.doublePass
                                    , Replay.takes c.doubleTake c.doublePass
                                    )
                                        |> Expect.equal ( c.call, c.tooGood, c.takes )

                                Err e ->
                                    Expect.fail (D.errorToString e)
                )
                CubeCallFixtures.all
        )
