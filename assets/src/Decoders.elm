module Decoders exposing (..)

{-| JSON decoders for converting server data to Elm types
-}

import Dict exposing (Dict)
import Json.Decode as D exposing (Decoder)
import Types exposing (..)



-- GAME STATE DECODERS


gameStateDecoder : Decoder GameState
gameStateDecoder =
    D.succeed GameState
        |> andMap (D.field "round_number" D.int)
        |> andMap (D.field "player_names" (dictDecoder D.string))
        |> andMap (D.field "players" (dictDecoder playerStateDecoder))
        |> andMap (D.field "phase" gamePhaseDecoder)
        |> andMap (D.field "game_status" gameStatusDecoder)
        |> andMap (D.field "last_hand_results" (D.maybe (dictDecoder handResultDecoder)))
        |> andMap (D.field "round_hand_history" (D.list (dictDecoder handResultDecoder)))
        |> andMap (D.field "winner_id" (D.maybe D.string))
        |> andMap (D.field "last_round_winner_id" (D.maybe D.string))
        |> andMap (D.field "shop_state" (D.maybe shopStateDecoder))
        |> andMap (D.field "shop_rounds" D.int)
        |> andMap (D.field "initial_lives" D.int)
        |> andMap (D.field "hands_per_round" D.int)
        |> andMap (D.field "discards_per_round" D.int)


gamePhaseDecoder : Decoder GamePhase
gamePhaseDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "playing" ->
                        D.succeed Playing

                    "round_end" ->
                        D.succeed RoundEnd

                    _ ->
                        D.fail ("Unknown game phase: " ++ str)
            )


gameStatusDecoder : Decoder GameStatus
gameStatusDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "active" ->
                        D.succeed Active

                    "game_over" ->
                        D.succeed GameOver

                    _ ->
                        D.fail ("Unknown game status: " ++ str)
            )



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
    D.map6 ScoreBreakdown
        (D.field "base_chips" D.int)
        (D.field "base_multiplier" D.int)
        (D.field "total_chips" D.int)
        (D.field "total_multiplier" D.int)
        (D.field "total_score" D.int)
        (D.field "card_breakdowns" (D.list cardBreakdownDecoder))


cardBreakdownDecoder : Decoder CardBreakdown
cardBreakdownDecoder =
    D.map5 CardBreakdown
        (D.field "card" cardDecoder)
        (D.field "chip_value" D.int)
        (D.field "bonus_chips" D.int)
        (D.field "bonus_mult" D.int)
        (D.field "disabled" D.bool)



-- CARD DECODERS


cardDecoder : Decoder Card
cardDecoder =
    D.map4 Card
        (D.field "id" D.string)
        (D.field "rank" D.int)
        (D.field "suit" suitDecoder)
        (D.field "enhancement" (D.maybe enhancementDecoder))


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
        |> andMap (D.field "picked_card_indices" (D.list D.int))
        |> andMap (D.field "pending_deck_builder" (D.maybe pendingDeckBuilderDecoder))
        |> andMap (D.field "pending_plus_bomb" (D.maybe pendingPlusBombDecoder))
        |> andMap (D.field "destroy_phase_complete" D.bool)
        |> andMap (D.field "destroyer_id" (D.maybe D.string))
        |> andMap (D.field "destroys_allowed" D.int)
        |> andMap (D.field "destroyed_card_indices" (D.list D.int))


shopCardDecoder : Decoder ShopCard
shopCardDecoder =
    D.map6 ShopCard
        (D.field "type" shopCardTypeDecoder)
        (D.field "subtype" D.string)
        (D.field "name" D.string)
        (D.field "description" D.string)
        (D.field "cost" D.int)
        (D.field "metadata" (D.maybe shopCardMetadataDecoder))


shopCardTypeDecoder : Decoder ShopCardType
shopCardTypeDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "level_up" ->
                        D.succeed LevelUp

                    "denial" ->
                        D.succeed Denial

                    "sabotage" ->
                        D.succeed Sabotage

                    "deck_builder" ->
                        D.succeed DeckBuilder

                    _ ->
                        D.fail ("Unknown shop card type: " ++ str)
            )


shopCardMetadataDecoder : Decoder ShopCardMetadata
shopCardMetadataDecoder =
    D.map2 ShopCardMetadata
        (D.maybe (D.field "amount" D.int))
        (D.maybe (D.field "suit" suitDecoder))


pendingDeckBuilderDecoder : Decoder PendingDeckBuilder
pendingDeckBuilderDecoder =
    D.map4 PendingDeckBuilder
        (D.field "player_id" D.string)
        (D.field "shop_card_index" D.int)
        (D.field "deck_builder_card" shopCardDecoder)
        (D.field "available_cards" (D.list cardDecoder))


pendingPlusBombDecoder : Decoder PendingPlusBomb
pendingPlusBombDecoder =
    D.map3 PendingPlusBomb
        (D.field "player_id" D.string)
        (D.field "shop_card_index" D.int)
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
