module Decoders exposing (..)

{-| JSON decoders for converting server data to Elm types
-}

import Dict exposing (Dict)
import Json.Decode as D exposing (Decoder)
import Types exposing (..)



-- PLAYER VIEW DECODERS (New architecture from Gleam)


{-| Main decoder for PlayerView - dispatches based on "type" field
-}
playerViewDecoder : Decoder PlayerView
playerViewDecoder =
    D.field "type" D.string
        |> D.andThen playerViewByType


playerViewByType : String -> Decoder PlayerView
playerViewByType viewType =
    case viewType of
        "playing" ->
            D.map PlayingView playingDataDecoder

        "shop" ->
            D.map ShopView shopDataDecoder

        "game_over" ->
            D.map GameOverView gameOverDataDecoder

        "reconnect_needed" ->
            D.succeed ReconnectNeededView

        _ ->
            D.fail ("Unknown view type: " ++ viewType)


{-| Decoder for playing data
-}
playingDataDecoder : Decoder PlayingData
playingDataDecoder =
    D.succeed PlayingData
        |> andMap (D.field "your_name" D.string)
        |> andMap (D.field "your_hand" (D.list cardDecoder))
        |> andMap (D.field "your_draw_pile" (D.list cardDecoder))
        |> andMap (D.field "your_lives" D.int)
        |> andMap (D.field "your_hands_remaining" D.int)
        |> andMap (D.field "your_discards_remaining" D.int)
        |> andMap (D.field "your_current_score" D.int)
        |> andMap (D.field "your_locked_in_hand" (D.maybe (D.list cardDecoder)))
        |> andMap (D.field "your_face_down_card_ids" (D.list D.string))
        |> andMap (D.field "your_disabled_ranks" (D.list D.int))
        |> andMap (D.field "your_disabled_suits" (D.list suitDecoder))
        |> andMap (D.field "your_enhancements_disabled" D.bool)
        |> andMap (D.field "your_active_debuffs" (D.list handTypeDecoder))
        |> andMap (D.field "your_scrambled" D.bool)
        |> andMap (D.field "your_supply_chain_limited" D.bool)
        |> andMap (D.field "your_skill_tree" skillTreeDecoder)
        |> andMap (D.field "opponent_name" D.string)
        |> andMap (D.field "opponent_hand" (D.list cardDecoder))
        |> andMap (D.field "opponent_lives" D.int)
        |> andMap (D.field "opponent_hands_remaining" D.int)
        |> andMap (D.field "opponent_discards_remaining" D.int)
        |> andMap (D.field "opponent_current_score" D.int)
        |> andMap (D.field "opponent_locked_in_hand" (D.maybe (D.list cardDecoder)))
        |> andMap (D.field "opponent_face_down_card_ids" (D.list D.string))
        |> andMap (D.field "opponent_disabled_ranks" (D.list D.int))
        |> andMap (D.field "opponent_disabled_suits" (D.list suitDecoder))
        |> andMap (D.field "opponent_enhancements_disabled" D.bool)
        |> andMap (D.field "opponent_active_debuffs" (D.list handTypeDecoder))
        |> andMap (D.field "opponent_scrambled" D.bool)
        |> andMap (D.field "opponent_supply_chain_limited" D.bool)
        |> andMap (D.field "round_number" D.int)
        |> andMap (D.field "hands_per_round" D.int)
        |> andMap (D.field "discards_per_round" D.int)
        |> andMap (D.field "initial_lives" D.int)
        |> andMap (D.field "pending_animation" (D.maybe handResultAnimationDecoder))


{-| Decoder for game over data
-}
gameOverDataDecoder : Decoder GameOverData
gameOverDataDecoder =
    D.succeed GameOverData
        |> andMap (D.field "your_name" D.string)
        |> andMap (D.field "opponent_name" D.string)
        |> andMap (D.field "winner_name" D.string)
        |> andMap (D.field "you_won" D.bool)
        |> andMap (D.field "your_final_lives" D.int)
        |> andMap (D.field "opponent_final_lives" D.int)
        |> andMap (D.field "your_ready" D.bool)
        |> andMap (D.field "opponent_ready" D.bool)


{-| Decoder for shop view data
-}
shopDataDecoder : Decoder ShopData
shopDataDecoder =
    D.succeed ShopData
        |> andMap (D.field "shop_state" shopStateDecoder)
        |> andMap (D.field "available_cards" (D.list shopCardDecoder))
        |> andMap (D.field "your_player_id" D.string)
        |> andMap (D.field "your_name" D.string)
        |> andMap (D.field "your_lives" D.int)
        |> andMap (D.field "your_skill_tree" skillTreeDecoder)
        |> andMap (D.field "opponent_player_id" D.string)
        |> andMap (D.field "opponent_name" D.string)
        |> andMap (D.field "opponent_lives" D.int)
        |> andMap (D.field "opponent_skill_tree" skillTreeDecoder)
        |> andMap (D.field "current_round" D.int)
        |> andMap (D.field "total_rounds" D.int)
        |> andMap (D.field "initial_lives" D.int)



-- PLAYER STATE DECODERS


playerStateDecoder : Decoder PlayerState
playerStateDecoder =
    D.succeed PlayerState
        |> andMap (D.field "player_id" D.string)
        |> andMap (D.field "lives" D.int)
        |> andMap (D.field "card_piles" cardPilesDecoder)
        |> andMap (D.field "skill_tree" skillTreeDecoder)
        |> andMap (D.field "hands_remaining" D.int)
        |> andMap (D.field "discards_remaining" D.int)
        |> andMap (D.field "current_round_score" D.int)
        |> andMap (D.field "locked_in_hand" (D.maybe (D.list cardDecoder)))
        |> andMap (D.field "ready_for_next_round" D.bool)
        |> andMap (D.field "status" playerStatusDecoder)
        |> andMap (D.field "active_debuffs" (D.list handTypeDecoder))
        |> andMap (D.field "scrambled" D.bool)
        |> andMap (D.field "face_down_card_ids" (D.list D.string))
        |> andMap (D.field "disabled_ranks" (D.list D.int))
        |> andMap (D.field "disabled_suits" (D.list suitDecoder))
        |> andMap (D.field "enhancements_disabled" D.bool)
        |> andMap (D.field "supply_chain_limited" D.bool)


playerStatusDecoder : Decoder PlayerStatus
playerStatusDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "active" ->
                        D.succeed PlayerActive

                    "eliminated" ->
                        D.succeed PlayerEliminated

                    _ ->
                        D.fail ("Unknown player status: " ++ str)
            )


cardPilesDecoder : Decoder CardPiles
cardPilesDecoder =
    D.map3 CardPiles
        (D.field "hand_pile" (D.list cardDecoder))
        (D.field "draw_pile" (D.list cardDecoder))
        (D.field "discard_pile" (D.list cardDecoder))


handResultDecoder : Decoder HandResult
handResultDecoder =
    D.map7 HandResult
        (D.field "hand" (D.list cardDecoder))
        (D.field "hand_type" handTypeDecoder)
        (D.field "score" D.int)
        (D.field "score_breakdown" scoreBreakdownDecoder)
        (D.field "disabled_ranks" (D.list D.int))
        (D.field "disabled_suits" (D.list suitDecoder))
        (D.field "enhancements_disabled" D.bool)


scoreBreakdownDecoder : Decoder ScoreBreakdown
scoreBreakdownDecoder =
    D.map5 ScoreBreakdown
        (D.field "base_chips" D.int)
        (D.field "base_multiplier" D.int)
        (D.field "total_chips" D.int)
        (D.field "total_multiplier" D.int)
        (D.field "card_breakdowns" (D.list cardBreakdownDecoder))


cardBreakdownDecoder : Decoder CardBreakdown
cardBreakdownDecoder =
    D.map5 CardBreakdown
        (D.field "card" cardDecoder)
        (D.field "chip_value" D.int)
        (D.field "bonus_chips" D.int)
        (D.field "bonus_mult" D.int)
        (D.field "disabled" D.bool)


handResultAnimationDecoder : Decoder HandResultAnimation
handResultAnimationDecoder =
    D.succeed HandResultAnimation
        |> andMap (D.field "your_hand" (D.list cardDecoder))
        |> andMap (D.field "your_hand_type" D.string)
        |> andMap (D.field "your_score" D.int)
        |> andMap (D.field "your_breakdown" scoreBreakdownDecoder)
        |> andMap (D.field "your_hand_level" D.int)
        |> andMap (D.field "opponent_hand" (D.list cardDecoder))
        |> andMap (D.field "opponent_hand_type" D.string)
        |> andMap (D.field "opponent_score" D.int)
        |> andMap (D.field "opponent_breakdown" scoreBreakdownDecoder)
        |> andMap (D.field "opponent_hand_level" D.int)



-- CARD DECODERS


cardDecoder : Decoder Card
cardDecoder =
    D.map4 Card
        (D.field "id" D.string)
        (D.field "rank" rankDecoder)
        (D.field "suit" suitDecoder)
        (D.field "enhancement" (D.maybe enhancementDecoder))


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



-- SKILL TREE DECODER


skillTreeDecoder : Decoder SkillTree
skillTreeDecoder =
    D.succeed SkillTree
        |> andMap (D.field "high_card" D.int)
        |> andMap (D.field "pair" D.int)
        |> andMap (D.field "two_pair" D.int)
        |> andMap (D.field "three_of_a_kind" D.int)
        |> andMap (D.field "straight" D.int)
        |> andMap (D.field "flush" D.int)
        |> andMap (D.field "full_house" D.int)
        |> andMap (D.field "four_of_a_kind" D.int)
        |> andMap (D.field "straight_flush" D.int)



-- SHOP DECODERS


shopStateDecoder : Decoder ShopState
shopStateDecoder =
    D.succeed ShopState
        |> andMap (D.field "total_rounds" D.int)
        |> andMap (D.field "current_round" D.int)
        |> andMap (D.field "first_picker_id" D.string)
        |> andMap (D.field "second_picker_id" D.string)
        |> andMap (D.field "first_pick_made" D.bool)
        |> andMap (D.field "second_pick_made" D.bool)
        |> andMap (D.field "available_cards" (D.list shopCardDecoder))
        |> andMap (D.field "picked_card_ids" (D.list D.string))
        |> andMap (D.field "pending_deck_builder" (D.maybe pendingDeckBuilderDecoder))
        |> andMap (D.field "pending_plus_bomb" (D.maybe pendingPlusBombDecoder))
        |> andMap (D.field "destroy_phase_complete" D.bool)
        |> andMap (D.field "destroyer_id" (D.maybe D.string))
        |> andMap (D.field "destroys_allowed" D.int)
        |> andMap (D.field "destroyed_card_ids" (D.list D.string))


researchCardDecoder : Decoder ResearchCard
researchCardDecoder =
    D.index 0 D.string
        |> D.andThen
            (\cardType ->
                case cardType of
                    "LevelUp" ->
                        D.map LevelUpCard
                            (D.index 1 handTypeDecoder)

                    _ ->
                        D.fail ("Unknown research card type: " ++ cardType)
            )


counterCardDecoder : Decoder CounterCard
counterCardDecoder =
    D.index 0 D.string
        |> D.andThen
            (\cardType ->
                case cardType of
                    "Denial" ->
                        D.map DenialCard
                            (D.index 1 handTypeDecoder)

                    _ ->
                        D.fail ("Unknown counter card type: " ++ cardType)
            )


logisticsCardDecoder : Decoder LogisticsCard
logisticsCardDecoder =
    D.index 0 D.string
        |> D.andThen
            (\cardType ->
                case cardType of
                    "Fortify" ->
                        D.map2 FortifyCard
                            (D.index 1 D.int)
                            (D.index 2 D.int)

                    "Amplify" ->
                        D.map2 AmplifyCard
                            (D.index 1 D.int)
                            (D.index 2 D.int)

                    "SupplyDrop" ->
                        D.map SupplyDropCard
                            (D.index 1 D.int)

                    "Discharge" ->
                        D.map DischargeCard
                            (D.index 1 D.int)

                    "Camo" ->
                        D.map2 CamoCard
                            (D.index 1 suitDecoder)
                            (D.index 2 D.int)

                    "Promote" ->
                        D.map PromoteCard
                            (D.index 1 D.int)

                    _ ->
                        D.fail ("Unknown logistics card type: " ++ cardType)
            )


sabotageCardDecoder : Decoder SabotageCard
sabotageCardDecoder =
    D.index 0 D.string
        |> D.andThen
            (\cardType ->
                case cardType of
                    "Scrambler" ->
                        D.succeed ScramblerCard

                    "PlusBomb" ->
                        D.map PlusBombCard
                            (D.index 1 D.int)

                    "StaticField" ->
                        D.succeed StaticFieldCard

                    "SupplyChain" ->
                        D.succeed SupplyChainCard

                    _ ->
                        D.fail ("Unknown sabotage card type: " ++ cardType)
            )


cardKindDecoder : Decoder CardKind
cardKindDecoder =
    D.index 0 D.string
        |> D.andThen
            (\category ->
                case category of
                    "Research" ->
                        D.map Research (D.index 1 researchCardDecoder)

                    "Counter" ->
                        D.map Counter (D.index 1 counterCardDecoder)

                    "Logistics" ->
                        D.map Logistics (D.index 1 logisticsCardDecoder)

                    "Sabotage" ->
                        D.map Sabotage (D.index 1 sabotageCardDecoder)

                    _ ->
                        D.fail ("Unknown shop card category: " ++ category)
            )


shopCardDecoder : Decoder ShopCard
shopCardDecoder =
    D.map2 ShopCard
        (D.field "id" D.string)
        (D.field "kind" cardKindDecoder)


pendingDeckBuilderDecoder : Decoder PendingDeckBuilder
pendingDeckBuilderDecoder =
    D.map4 PendingDeckBuilder
        (D.field "player_id" D.string)
        (D.field "shop_card_id" D.string)
        (D.field "deck_builder_card" shopCardDecoder)
        (D.field "available_cards" (D.list cardDecoder))


pendingPlusBombDecoder : Decoder PendingPlusBomb
pendingPlusBombDecoder =
    D.map3 PendingPlusBomb
        (D.field "player_id" D.string)
        (D.field "shop_card_id" D.string)
        (D.field "available_cards" (D.list cardDecoder))



-- HELPER DECODERS


{-| Decode a dictionary with string keys
-}
dictDecoder : Decoder v -> Decoder (Dict String v)
dictDecoder valueDecoder =
    D.keyValuePairs valueDecoder
        |> D.map Dict.fromList


{-| Pipeline-style decoder helper
-}
andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    D.map2 (|>)


{-| Decoder for disconnected player info (from controller flags)
-}
disconnectedPlayerDecoder : Decoder DisconnectedPlayer
disconnectedPlayerDecoder =
    D.map2 DisconnectedPlayer
        (D.field "id" D.string)
        (D.field "name" D.string)
