module SetupFuzz exposing (validSetup)

{-| Setups `Setup.check` accepts, for the property tests: up to fifteen
checkers a side scattered over the points and the bar (a point keeps the
colour that reached it first), a roll or a cube question that can be
asked, a cube that makes sense, and unlimited play or a match with a
legal score and Crawford only where somebody is one away.
-}

import Fuzz exposing (Fuzzer)
import Games.Backgammon.Setup as Setup exposing (Ask(..), Color(..), Setup)


validSetup : Fuzzer Setup
validSetup =
    Fuzz.map5 build
        placements
        (Fuzz.oneOfValues [ White, Black ])
        askFuzzer
        cubeFuzzer
        matchFuzzer


{-| Where each side's checkers go: 0..23 a point, 24 the bar.
-}
placements : Fuzzer ( List Int, List Int )
placements =
    Fuzz.pair
        (Fuzz.listOfLengthBetween 1 15 (Fuzz.intRange 0 24))
        (Fuzz.listOfLengthBetween 1 15 (Fuzz.intRange 0 24))


askFuzzer : Fuzzer Ask
askFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 (\a b -> Move (Just ( max a b, min a b ))) (Fuzz.intRange 1 6) (Fuzz.intRange 1 6)
        , Fuzz.constant Double
        , Fuzz.constant Take
        ]


cubeFuzzer : Fuzzer ( Int, Maybe Color )
cubeFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant ( 1, Nothing )
        , Fuzz.map2 Tuple.pair
            (Fuzz.oneOfValues [ 2, 4, 8, 16, 32, 64 ])
            (Fuzz.oneOfValues [ Just White, Just Black ])
        ]


matchFuzzer : Fuzzer (Maybe Setup.Match)
matchFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Nothing
        , Fuzz.intRange 1 25
            |> Fuzz.andThen
                (\length ->
                    Fuzz.map3
                        (\white black crawford ->
                            Just
                                { length = length
                                , white = white
                                , black = black
                                , crawford = crawford && (white == length - 1 || black == length - 1)
                                }
                        )
                        (Fuzz.intRange 0 (length - 1))
                        (Fuzz.intRange 0 (length - 1))
                        Fuzz.bool
                )
        ]


build : ( List Int, List Int ) -> Color -> Ask -> ( Int, Maybe Color ) -> Maybe Setup.Match -> Setup
build ( whites, blacks ) toPlay ask ( cubeValue, cubeOwner ) match =
    let
        place sign at ( counts, bar ) =
            if at == 24 then
                ( counts, bar + 1 )

            else
                ( List.indexedMap
                    (\i n ->
                        if i == at && n * sign >= 0 then
                            n + sign

                        else
                            n
                    )
                    counts
                , bar
                )

        ( afterWhite, whiteBar ) =
            List.foldl (place 1) ( List.repeat 24 0, 0 ) whites

        ( points, blackBar ) =
            List.foldl (place -1) ( afterWhite, 0 ) blacks

        -- Every black checker may have landed on a white point: put one on
        -- the bar so Black is still on the board.
        blackBarAtLeastOne =
            if blackBar == 0 && List.all (\n -> n >= 0) points then
                1

            else
                blackBar

        setup =
            { points = points
            , whiteBar = whiteBar
            , blackBar = blackBarAtLeastOne
            , toPlay = toPlay
            , ask = ask
            , cubeValue = cubeValue
            , cubeOwner = cubeOwner
            , match = match
            }
    in
    -- A cube question nobody could ask becomes a roll to play.
    case ask of
        Double ->
            if Setup.canDouble toPlay setup then
                setup

            else
                { setup | ask = Move (Just ( 3, 1 )) }

        Take ->
            if Setup.canDouble (Setup.other toPlay) setup then
                setup

            else
                { setup | ask = Move (Just ( 6, 5 )) }

        Move _ ->
            setup
