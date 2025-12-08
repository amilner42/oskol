module Encoders exposing (..)

{-| JSON encoders for sending actions to the server
-}

import Json.Encode as E
import Types exposing (..)



-- ACTION ENCODERS


{-| Encode a lock-in hand action
-}
encodeLockInHand : List Card -> E.Value
encodeLockInHand cards =
    E.object
        [ ( "action", E.string "lock_in_hand" )
        , ( "cards", E.list encodeCard cards )
        ]


{-| Encode a discard cards action
-}
encodeDiscardCards : List Card -> E.Value
encodeDiscardCards cards =
    E.object
        [ ( "action", E.string "discard_cards" )
        , ( "cards", E.list encodeCard cards )
        ]


{-| Encode a make shop pick action
-}
encodeMakeShopPick : Int -> E.Value
encodeMakeShopPick cardIndex =
    E.object
        [ ( "action", E.string "make_shop_pick" )
        , ( "card_index", E.int cardIndex )
        ]


{-| Encode a confirm deck builder pick action
-}
encodeConfirmDeckBuilder : Int -> E.Value
encodeConfirmDeckBuilder cardIndex =
    E.object
        [ ( "action", E.string "confirm_deck_builder_pick" )
        , ( "card_index", E.int cardIndex )
        ]


{-| Encode a complete deck builder selection action
-}
encodeCompleteDeckBuilderSelection : List String -> E.Value
encodeCompleteDeckBuilderSelection cardIds =
    E.object
        [ ( "action", E.string "complete_deck_builder_selection" )
        , ( "card_ids", E.list E.string cardIds )
        ]


{-| Encode a skip deck builder selection action
-}
encodeSkipDeckBuilderSelection : E.Value
encodeSkipDeckBuilderSelection =
    E.object
        [ ( "action", E.string "skip_deck_builder_selection" )
        ]


{-| Encode a confirm plus bomb pick action
-}
encodeConfirmPlusBomb : Int -> E.Value
encodeConfirmPlusBomb cardIndex =
    E.object
        [ ( "action", E.string "confirm_plus_bomb_pick" )
        , ( "card_index", E.int cardIndex )
        ]


{-| Encode a complete plus bomb selection action
-}
encodeCompletePlusBombSelection : String -> E.Value
encodeCompletePlusBombSelection cardId =
    E.object
        [ ( "action", E.string "complete_plus_bomb_selection" )
        , ( "card_id", E.string cardId )
        ]


{-| Encode a destroy shop card action
-}
encodeDestroyShopCard : Int -> E.Value
encodeDestroyShopCard cardIndex =
    E.object
        [ ( "action", E.string "destroy_shop_card" )
        , ( "card_index", E.int cardIndex )
        ]


{-| Encode a complete destroy phase action
-}
encodeCompleteDestroyPhase : E.Value
encodeCompleteDestroyPhase =
    E.object
        [ ( "action", E.string "complete_destroy_phase" )
        ]


{-| Encode a ready for next round action
-}
encodeReadyForNextRound : E.Value
encodeReadyForNextRound =
    E.object
        [ ( "action", E.string "ready_for_next_round" )
        ]


encodeRequestRematch : E.Value
encodeRequestRematch =
    E.object
        [ ( "action", E.string "request_rematch" )
        ]



-- HELPER ENCODERS


{-| Encode a card
-}
encodeCard : Card -> E.Value
encodeCard card =
    E.object
        [ ( "id", E.string card.id )
        , ( "rank", E.int card.rank )
        , ( "suit", encodeSuit card.suit )
        , ( "enhancement", encodeMaybeEnhancement card.enhancement )
        ]


{-| Encode a suit
-}
encodeSuit : Suit -> E.Value
encodeSuit suit =
    case suit of
        Hearts ->
            E.string "hearts"

        Diamonds ->
            E.string "diamonds"

        Clubs ->
            E.string "clubs"

        Spades ->
            E.string "spades"


{-| Encode an optional enhancement
-}
encodeMaybeEnhancement : Maybe Enhancement -> E.Value
encodeMaybeEnhancement maybeEnhancement =
    case maybeEnhancement of
        Just enhancement ->
            encodeEnhancement enhancement

        Nothing ->
            E.null


{-| Encode an enhancement
-}
encodeEnhancement : Enhancement -> E.Value
encodeEnhancement enhancement =
    case enhancement of
        BonusChips amount ->
            E.object
                [ ( "type", E.string "bonus_chips" )
                , ( "amount", E.int amount )
                ]

        BonusMult amount ->
            E.object
                [ ( "type", E.string "bonus_mult" )
                , ( "amount", E.int amount )
                ]
