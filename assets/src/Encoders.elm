module Encoders exposing
    ( encodeDiscard
    , encodePlayHand
    , encodeRequestRematch
    , encodeShopDestroy
    , encodeShopFinishDestroy
    , encodeShopPick
    , encodeShopSelect
    )

{-| Tilt actions, encoded with the generic protocol envelope.
Select params are always arrays of token ids.
-}

import Json.Encode as E
import Protocol


encodePlayHand : List String -> E.Value
encodePlayHand cardIds =
    Protocol.encodeAction "play_hand" [ ( "cards", E.list E.string cardIds ) ]


encodeDiscard : List String -> E.Value
encodeDiscard cardIds =
    Protocol.encodeAction "discard" [ ( "cards", E.list E.string cardIds ) ]


encodeShopPick : String -> E.Value
encodeShopPick cardId =
    Protocol.encodeAction "shop_pick" [ ( "card", E.list E.string [ cardId ] ) ]


encodeShopSelect : List String -> E.Value
encodeShopSelect cardIds =
    Protocol.encodeAction "shop_select" [ ( "cards", E.list E.string cardIds ) ]


encodeShopDestroy : String -> E.Value
encodeShopDestroy cardId =
    Protocol.encodeAction "shop_destroy" [ ( "card", E.list E.string [ cardId ] ) ]


encodeShopFinishDestroy : E.Value
encodeShopFinishDestroy =
    Protocol.encodeAction "shop_finish_destroy" []


encodeRequestRematch : E.Value
encodeRequestRematch =
    Protocol.encodeRematch
