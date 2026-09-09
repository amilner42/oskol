module GameArtTest exposing (suite)

{-| The sprite decomposition, ported from the Elixir that used to do it at
compile time. The rectangles are merged for size, never for looks, so the
property that matters is that they paint exactly the grid: every non-blank
cell covered once, in its own colour, and no blank cell covered at all.
-}

import Expect
import GameArt exposing (Rect)
import Set
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "GameArt"
        [ decomposition
        , merging
        , frames
        , accents
        ]


decomposition : Test
decomposition =
    describe "rects paint the grid"
        (List.map paintsBack
            [ ( "a blank grid", [ "....", "...." ] )
            , ( "one cell", [ ".K.." ] )
            , ( "a solid block", [ "KKKK", "KKKK", "KKKK" ] )
            , ( "a checker", [ "KWKW", "WKWK", "KWKW" ] )
            , ( "runs that start and stop", [ "KK..WW", "..KK..", "WW..KK" ] )
            , ( "the default sprite", GameArt.framesFor "nothing-like-this" |> firstFrame )
            , ( "poker frame 1", GameArt.framesFor "poker" |> firstFrame )
            , ( "backgammon frame 1", GameArt.framesFor "backgammon" |> firstFrame )
            , ( "chess frame 1", GameArt.framesFor "chess" |> firstFrame )
            , ( "go frame 1", GameArt.framesFor "go" |> firstFrame )
            ]
        )


{-| Paint the rectangles back onto a blank grid and compare with the source.
-}
paintsBack : ( String, List String ) -> Test
paintsBack ( name, rows ) =
    test name <|
        \_ ->
            let
                painted =
                    GameArt.rects rows
                        |> List.concatMap
                            (\r ->
                                List.range r.x (r.x + r.w - 1)
                                    |> List.concatMap
                                        (\x ->
                                            List.range r.y (r.y + r.h - 1)
                                                |> List.map (\y -> ( ( x, y ), r.color ))
                                        )
                            )
            in
            Expect.all
                [ \_ ->
                    -- Nothing is painted twice: the rectangles do not overlap.
                    Expect.equal (List.length painted)
                        (Set.size (Set.fromList (List.map Tuple.first painted)))
                , \_ -> Expect.equal (List.sortBy key (expected rows)) (List.sortBy key painted)
                ]
                ()


{-| Every non-blank cell of the grid, as its own one-cell rectangle.
-}
expected : List String -> List ( ( Int, Int ), String )
expected rows =
    rows
        |> List.indexedMap
            (\y row ->
                String.toList row
                    |> List.indexedMap (\x char -> ( ( x, y ), char ))
                    |> List.filter (\( _, char ) -> char /= '.')
                    |> List.map (\( at, char ) -> ( at, colorOf char ))
            )
        |> List.concat


key : ( ( Int, Int ), String ) -> ( Int, Int, String )
key ( ( x, y ), color ) =
    ( y, x, color )


{-| The palette, read back out of `rects` on a one-cell grid: the module
keeps it private, and this is the only thing that needs it.
-}
colorOf : Char -> String
colorOf char =
    GameArt.rects [ String.fromChar char ]
        |> List.head
        |> Maybe.map .color
        |> Maybe.withDefault "?"


merging : Test
merging =
    describe "rects are as few as they can be"
        [ test "a solid block is one rectangle" <|
            \_ ->
                GameArt.rects [ "KKKK", "KKKK", "KKKK" ]
                    |> Expect.equal [ { x = 0, y = 0, w = 4, h = 3, color = colorOf 'K' } ]
        , test "equal neighbours merge along a row" <|
            \_ ->
                GameArt.rects [ "KKK" ]
                    |> List.length
                    |> Expect.equal 1
        , test "a run only merges down into an identical run" <|
            \_ ->
                GameArt.rects [ "KKK", "KK." ]
                    |> List.length
                    |> Expect.equal 2
        , test "different colours never merge" <|
            \_ ->
                GameArt.rects [ "KW" ] |> List.length |> Expect.equal 2
        , test "a blank grid draws nothing" <|
            \_ ->
                GameArt.rects [ "....", "...." ] |> Expect.equal []
        ]


frames : Test
frames =
    describe "the reels"
        [ test "every game in the library has more than one frame to cycle" <|
            \_ ->
                [ "poker", "backgammon", "chess", "go" ]
                    |> List.map (\slug -> ( slug, GameArt.frameCount slug > 1 ))
                    |> List.filter (Tuple.second >> not)
                    |> Expect.equal []
        , test "a game with no art of its own gets the generic sprite, which does not animate" <|
            \_ -> Expect.equal 1 (GameArt.frameCount "no-such-game")
        , test "every frame of a game is the same size as the first" <|
            \_ ->
                [ "poker", "backgammon", "chess", "go", "default" ]
                    |> List.filter (not << sameSize)
                    |> Expect.equal []
        ]


sameSize : String -> Bool
sameSize slug =
    case GameArt.framesFor slug of
        [] ->
            False

        first :: rest ->
            let
                shape rows =
                    ( List.length rows, List.map String.length rows )
            in
            List.all (\frame -> shape frame == shape first) rest


accents : Test
accents =
    describe "accents"
        [ test "each catalogue game has its own" <|
            \_ ->
                [ "poker", "backgammon", "chess", "go" ]
                    |> List.map GameArt.accent
                    |> Set.fromList
                    |> Set.size
                    |> Expect.equal 4
        , test "a game with none gets the neutral one" <|
            \_ -> Expect.equal "#6b6b78" (GameArt.accent "no-such-game")
        ]


firstFrame : List (List String) -> List String
firstFrame =
    List.head >> Maybe.withDefault []
