module SetupTest exposing (suite)

{-| The analysis board's set-up position: its wire shape (the one
`src/oskol/analysis/setup.gleam` reads), the line under the board, the
quick starts, and a puzzle opened on the board.
-}

import Expect
import Games.Backgammon.Puzzle as Puzzle
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)
import Json.Decode as D
import Json.Encode as E
import PuzzleApiFixtures
import SetupFuzz
import Test exposing (Test, describe, fuzz, test)


opening31 : Setup
opening31 =
    { opening | ask = Move (Just ( 3, 1 )) }


opening : Setup
opening =
    Setup.opening


{-| The opening with 3-1 to play, as the Gleam decoder's own test writes
it.
-}
opening31Json : String
opening31Json =
    "{\"points\":[-2,0,0,0,0,5,0,3,0,0,0,-5,5,0,0,0,-3,0,-5,0,0,0,0,2],\"white_bar\":0,\"black_bar\":0,\"to_play\":\"white\",\"ask\":\"move\",\"dice\":[3,1],\"cube\":{\"value\":1,\"owner\":\"center\"},\"match\":null}"


suite : Test
suite =
    describe "Setup"
        [ describe "the wire"
            [ test "the opening with 3-1, White to play, is the literal the server reads" <|
                \_ -> E.encode 0 (Setup.toJson opening31) |> Expect.equal opening31Json
            , test "no roll yet is a move with no dice" <|
                \_ ->
                    E.encode 0 (Setup.toJson opening)
                        |> Expect.equal (String.replace "[3,1]" "null" opening31Json)
            , test "a take in a match, Black owning the cube" <|
                \_ ->
                    E.encode 0 (Setup.toJson { opening | ask = Take, cubeValue = 2, cubeOwner = Just Black, match = Just { length = 7, white = 2, black = 4, crawford = False } })
                        |> String.contains "\"ask\":\"take\",\"dice\":null,\"cube\":{\"value\":2,\"owner\":\"black\"},\"match\":{\"length\":7,\"white\":2,\"black\":4,\"crawford\":false}"
                        |> Expect.equal True
            , test "the literal decodes to the opening with 3-1" <|
                \_ -> D.decodeString Setup.decoder opening31Json |> Expect.equal (Ok opening31)
            , fuzz SetupFuzz.validSetup "toJson and decoder round-trip" <|
                \setup ->
                    D.decodeValue Setup.decoder (Setup.toJson setup) |> Expect.equal (Ok setup)
            ]
        , describe "the quick starts"
            [ test "the opening has fifteen a side and nothing off" <|
                \_ -> ( Setup.offWhite opening, Setup.offBlack opening ) |> Expect.equal ( 0, 0 )
            , test "CLEAR leaves everything off" <|
                \_ -> ( Setup.offWhite Setup.empty, Setup.offBlack Setup.empty ) |> Expect.equal ( 15, 15 )
            , test "the opening flipped is the opening with Black to play" <|
                \_ -> Setup.flip opening31 |> Expect.equal { opening31 | toPlay = Black }
            , test "flip swaps the bars, the cube's owner and the score" <|
                \_ ->
                    Setup.flip { opening31 | whiteBar = 1, cubeValue = 2, cubeOwner = Just White, match = Just { length = 5, white = 3, black = 1, crawford = False } }
                        |> (\s -> ( ( s.whiteBar, s.blackBar ), s.cubeOwner, s.match ))
                        |> Expect.equal ( ( 0, 1 ), Just Black, Just { length = 5, white = 1, black = 3, crawford = False } )
            , fuzz SetupFuzz.validSetup "flip twice is where it started" <|
                \setup -> Setup.flip (Setup.flip setup) |> Expect.equal setup
            , fuzz SetupFuzz.validSetup "a flipped setup checks as the setup did" <|
                \setup -> Setup.check (Setup.flip setup) |> Expect.equal (Setup.check setup)
            ]
        , describe "check: the line under the board"
            [ test "the opening with a roll can be asked" <|
                \_ -> Setup.check opening31 |> Expect.equal Nothing
            , test "the opening with no roll yet" <|
                \_ -> Setup.check opening |> Expect.equal (Just "Pick a roll")
            , test "not a board" <|
                \_ -> Setup.check { opening31 | points = List.drop 1 opening31.points } |> Expect.equal (Just "A board has 24 points")
            , test "a point over fifteen" <|
                \_ -> Setup.check { opening31 | points = 16 :: List.drop 1 opening31.points } |> Expect.equal (Just Setup.countMessage)
            , test "a bar below none" <|
                \_ -> Setup.check { opening31 | blackBar = -1 } |> Expect.equal (Just "A point holds 0 to 15 checkers")
            , test "too many of a colour" <|
                \_ ->
                    Setup.check { opening31 | whiteBar = 2 }
                        |> Expect.equal (Just "White has 17 checkers; 15 is the most")
            , test "a colour missing" <|
                \_ ->
                    Setup.check { opening31 | points = List.map (max 0) opening31.points }
                        |> Expect.equal (Just "Put some Black checkers on the board")
            , test "an empty board asks for White first" <|
                \_ -> Setup.check Setup.empty |> Expect.equal (Just "Put some White checkers on the board")
            , test "a color missing while the other has all fifteen out is a board being set up" <|
                \_ ->
                    Setup.check { opening31 | points = List.map (min 0) opening31.points }
                        |> Expect.equal (Just "Put some White checkers on the board")
            , test "a color all borne off while the other has borne some off too is a finished race" <|
                \_ ->
                    Setup.check { opening31 | points = List.map (min 0) opening31.points |> List.map (\n -> if n == -2 then 0 else n) }
                        |> Expect.equal (Just "The game is over in this position")
            , test "and that comes after the roll: a finished race with no roll asks for the roll" <|
                \_ ->
                    Setup.check { opening | points = List.map (min 0) opening31.points |> List.map (\n -> if n == -2 then 0 else n) }
                        |> Expect.equal (Just "Pick a roll")
            , test "a die outside 1..6" <|
                \_ -> Setup.check { opening | ask = Move (Just ( 7, 1 )) } |> Expect.equal (Just Setup.dieMessage)
            , test "a cube that is not a power of two to 64" <|
                \_ -> Setup.check { opening31 | cubeValue = 3, cubeOwner = Just White } |> Expect.equal (Just Setup.cubeValueMessage)
            , test "an owned cube on 1" <|
                \_ -> Setup.check { opening31 | cubeOwner = Just White } |> Expect.equal (Just Setup.ownedAtOneMessage)
            , test "a centered cube on 2" <|
                \_ -> Setup.check { opening31 | cubeValue = 2 } |> Expect.equal (Just Setup.unownedMessage)
            , test "a match to 26" <|
                \_ -> Setup.check { opening31 | match = Just { length = 26, white = 0, black = 0, crawford = False } } |> Expect.equal (Just Setup.lengthMessage)
            , test "a score that has already won" <|
                \_ ->
                    Setup.check { opening31 | match = Just { length = 7, white = 7, black = 0, crawford = False } }
                        |> Expect.equal (Just "Each score is 0 to 6 in a match to 7")
            , test "Crawford with nobody one away" <|
                \_ -> Setup.check { opening31 | match = Just { length = 7, white = 5, black = 3, crawford = True } } |> Expect.equal (Just Setup.crawfordMessage)
            , test "Crawford at 1-away against 7-away" <|
                \_ -> Setup.check { opening31 | match = Just { length = 7, white = 0, black = 6, crawford = True } } |> Expect.equal Nothing
            , test "a double on the other side's cube" <|
                \_ ->
                    Setup.check { opening | ask = Double, cubeValue = 2, cubeOwner = Just Black }
                        |> Expect.equal (Just "No double is possible here: the cube is Black's")
            , test "a double in the Crawford game" <|
                \_ ->
                    Setup.check { opening | ask = Double, match = Just { length = 7, white = 0, black = 6, crawford = True } }
                        |> Expect.equal (Just "No double is possible here: this is the Crawford game")
            , test "a double on a dead cube" <|
                \_ ->
                    Setup.check { opening | ask = Double, cubeValue = 2, cubeOwner = Just White, match = Just { length = 5, white = 3, black = 0, crawford = False } }
                        |> Expect.equal (Just "No double is possible here: the cube already covers what White needs")
            , test "a take of a cube the taker owns" <|
                \_ ->
                    Setup.check { opening | ask = Take, cubeValue = 2, cubeOwner = Just White }
                        |> Expect.equal (Just "No double is possible here: the cube is White's")
            , test "a take of a redouble from Black's cube" <|
                \_ -> Setup.check { opening | ask = Take, cubeValue = 2, cubeOwner = Just Black } |> Expect.equal Nothing
            , test "a double in money play on a centered cube" <|
                \_ -> Setup.check { opening | ask = Double } |> Expect.equal Nothing
            ]
        , describe "fromQuestion: a puzzle as its page shows it"
            [ test "a checker play: White to play its roll, the solver's score" <|
                \_ ->
                    fromFixture "move"
                        |> Expect.equal
                            (Ok
                                { points = [ -2, -2, 0, 4, 4, 5, -1, 0, 0, 0, 0, 0, 2, 0, 0, 0, -3, -3, 0, -2, -2, 0, 0, 0 ]
                                , whiteBar = 0
                                , blackBar = 0
                                , toPlay = White
                                , ask = Move (Just ( 6, 4 ))
                                , cubeValue = 1
                                , cubeOwner = Nothing
                                , match = Just { length = 5, white = 2, black = 0, crawford = False }
                                }
                            )
            , test "a double: White's cube question, White owning 2" <|
                \_ ->
                    fromFixture "double"
                        |> Result.map (\s -> ( s.ask, s.toPlay, ( s.cubeValue, s.cubeOwner ) ))
                        |> Expect.equal (Ok ( Double, White, ( 2, Just White ) ))
            , test "a take: White asked, Black the doubler owning the cube before it, and the score from White's side" <|
                \_ ->
                    fromFixture "take"
                        |> Result.map (\s -> ( ( s.ask, s.toPlay ), ( s.cubeValue, s.cubeOwner ), s.match ))
                        |> Expect.equal (Ok ( ( Take, White ), ( 2, Just Black ), Just { length = 5, white = 0, black = 2, crawford = False } ))
            , test "every fixture opens as a position that can be asked" <|
                \_ ->
                    [ "move", "doubles", "double", "take" ]
                        |> List.map (fromFixture >> Result.map Setup.check)
                        |> Expect.equal (List.repeat 4 (Ok Nothing))
            , test "borne off comes back as the question had it" <|
                \_ ->
                    fromFixture "take"
                        |> Result.map (\s -> ( Setup.offWhite s, Setup.offBlack s ))
                        |> Expect.equal (Ok ( 0, 0 ))
            ]
        ]


fromFixture : String -> Result String Setup
fromFixture name =
    PuzzleApiFixtures.all
        |> List.filter (\( n, _ ) -> n == name)
        |> List.head
        |> Maybe.map Tuple.second
        |> Result.fromMaybe ("no fixture " ++ name)
        |> Result.andThen (D.decodeString Puzzle.decoder >> Result.mapError D.errorToString)
        |> Result.map (\puzzle -> Setup.fromQuestion puzzle.kind puzzle.question)
