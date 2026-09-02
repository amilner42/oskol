module Decoders exposing
    ( andMap
    , cardBreakdownDecoder
    , cardDecoder
    , cardFromToken
    , enhancementDecoder
    , handTypeDecoder
    , rankDecoder
    , scoreBreakdownDecoder
    , shopCardFromToken
    , shopKindDecoder
    , skillTreeDecoder
    , suitDecoder
    )

{-| Decoders for Tilt's domain types as they appear inside the protocol:
card tokens, shop card tokens, skill trees and score breakdowns.
-}

import Json.Decode as D exposing (Decoder)
import Protocol exposing (Token)
import Types exposing (..)



-- CARDS


{-| A card token: the token id is the card id; rank, suit and enhancement are props.
-}
cardFromToken : Token -> Maybe Card
cardFromToken token =
    case D.decodeValue (cardPropsDecoder token.id) token.props of
        Ok card ->
            Just card

        Err _ ->
            -- A face-down card carries no face at all (the server keeps it
            -- secret); it is still a card the holder can select by id.
            if token.faceUp then
                Nothing

            else
                Just (Card token.id Two Spades Nothing)


cardPropsDecoder : String -> Decoder Card
cardPropsDecoder id =
    D.map3 (Card id)
        (D.field "rank" rankDecoder)
        (D.field "suit" suitDecoder)
        (D.field "enhancement" (D.nullable enhancementDecoder))


cardDecoder : Decoder Card
cardDecoder =
    D.map4 Card
        (D.field "id" D.string)
        (D.field "rank" rankDecoder)
        (D.field "suit" suitDecoder)
        (D.field "enhancement" (D.nullable enhancementDecoder))


rankDecoder : Decoder Rank
rankDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "two" ->
                        D.succeed Two

                    "three" ->
                        D.succeed Three

                    "four" ->
                        D.succeed Four

                    "five" ->
                        D.succeed Five

                    "six" ->
                        D.succeed Six

                    "seven" ->
                        D.succeed Seven

                    "eight" ->
                        D.succeed Eight

                    "nine" ->
                        D.succeed Nine

                    "ten" ->
                        D.succeed Ten

                    "jack" ->
                        D.succeed Jack

                    "queen" ->
                        D.succeed Queen

                    "king" ->
                        D.succeed King

                    "ace" ->
                        D.succeed Ace

                    _ ->
                        D.fail ("Unknown rank: " ++ str)
            )


suitDecoder : Decoder Suit
suitDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "hearts" ->
                        D.succeed Hearts

                    "diamonds" ->
                        D.succeed Diamonds

                    "clubs" ->
                        D.succeed Clubs

                    "spades" ->
                        D.succeed Spades

                    _ ->
                        D.fail ("Unknown suit: " ++ str)
            )


enhancementDecoder : Decoder Enhancement
enhancementDecoder =
    D.field "type" D.string
        |> D.andThen
            (\enhType ->
                case enhType of
                    "bonus_chips" ->
                        D.map BonusChips (D.field "amount" D.int)

                    "bonus_mult" ->
                        D.map BonusMult (D.field "amount" D.int)

                    _ ->
                        D.fail ("Unknown enhancement type: " ++ enhType)
            )


handTypeDecoder : Decoder HandType
handTypeDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "high_card" ->
                        D.succeed HighCard

                    "pair" ->
                        D.succeed Pair

                    "two_pair" ->
                        D.succeed TwoPair

                    "three_of_a_kind" ->
                        D.succeed ThreeOfAKind

                    "straight" ->
                        D.succeed Straight

                    "flush" ->
                        D.succeed Flush

                    "full_house" ->
                        D.succeed FullHouse

                    "four_of_a_kind" ->
                        D.succeed FourOfAKind

                    "straight_flush" ->
                        D.succeed StraightFlush

                    _ ->
                        D.fail ("Unknown hand type: " ++ str)
            )



-- SKILL TREE


{-| Skill tree as an object keyed by hand type; missing keys default to level 1.
-}
skillTreeDecoder : Decoder SkillTree
skillTreeDecoder =
    let
        level key =
            D.oneOf [ D.field key D.int, D.succeed 1 ]
    in
    D.succeed SkillTree
        |> andMap (level "high_card")
        |> andMap (level "pair")
        |> andMap (level "two_pair")
        |> andMap (level "three_of_a_kind")
        |> andMap (level "straight")
        |> andMap (level "flush")
        |> andMap (level "full_house")
        |> andMap (level "four_of_a_kind")
        |> andMap (level "straight_flush")



-- SCORE BREAKDOWNS (from the hands_resolved event)


scoreBreakdownDecoder : Decoder ScoreBreakdown
scoreBreakdownDecoder =
    D.map5 ScoreBreakdown
        (D.field "base_chips" D.int)
        (D.field "base_multiplier" D.int)
        (D.field "total_chips" D.int)
        (D.field "total_multiplier" D.int)
        (D.field "cards" (D.list cardBreakdownDecoder))


cardBreakdownDecoder : Decoder CardBreakdown
cardBreakdownDecoder =
    D.map5 CardBreakdown
        (D.field "card" cardDecoder)
        (D.field "chip_value" D.int)
        (D.field "bonus_chips" D.int)
        (D.field "bonus_mult" D.int)
        (D.field "disabled" D.bool)



-- SHOP CARDS


shopCardFromToken : Token -> Maybe ShopCard
shopCardFromToken token =
    D.decodeValue (D.map (ShopCard token.id) (D.field "kind" shopKindDecoder)) token.props
        |> Result.toMaybe


shopKindDecoder : Decoder CardKind
shopKindDecoder =
    D.field "type" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "level_up" ->
                        D.map (Research << LevelUpCard) (D.field "hand_type" handTypeDecoder)

                    "denial" ->
                        D.map (Counter << DenialCard) (D.field "hand_type" handTypeDecoder)

                    "fortify" ->
                        D.map2 (\a m -> Logistics (FortifyCard a m)) (D.field "amount" D.int) (D.field "max_cards" D.int)

                    "amplify" ->
                        D.map2 (\a m -> Logistics (AmplifyCard a m)) (D.field "amount" D.int) (D.field "max_cards" D.int)

                    "supply_drop" ->
                        D.map (Logistics << SupplyDropCard) (D.field "max_cards" D.int)

                    "discharge" ->
                        D.map (Logistics << DischargeCard) (D.field "max_cards" D.int)

                    "camo" ->
                        D.map2 (\s m -> Logistics (CamoCard s m)) (D.field "suit" suitDecoder) (D.field "max_cards" D.int)

                    "promote" ->
                        D.map (Logistics << PromoteCard) (D.field "max_cards" D.int)

                    "scrambler" ->
                        D.succeed (Sabotage ScramblerCard)

                    "plus_bomb" ->
                        D.map (Sabotage << PlusBombCard) (D.field "max_cards" D.int)

                    "static_field" ->
                        D.succeed (Sabotage StaticFieldCard)

                    "supply_chain" ->
                        D.succeed (Sabotage SupplyChainCard)

                    _ ->
                        D.fail ("Unknown shop card kind: " ++ kind)
            )



-- HELPERS


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    D.map2 (|>)
