//// JSON encoding for Tilt's domain types. Shared by the scene projection and
//// the events so the client sees one shape everywhere.

import gleam/int
import gleam/json.{type Json}
import gleam/option.{None, Some}
import tilt/poker/card.{type Card, type Enhancement, type Rank, type Suit}
import tilt/poker/hand.{type HandType}
import tilt/poker/score.{type ScoreResult}
import tilt/shop/card as shop_card

pub fn rank_to_string(rank: Rank) -> String {
  case rank {
    card.Two -> "two"
    card.Three -> "three"
    card.Four -> "four"
    card.Five -> "five"
    card.Six -> "six"
    card.Seven -> "seven"
    card.Eight -> "eight"
    card.Nine -> "nine"
    card.Ten -> "ten"
    card.Jack -> "jack"
    card.Queen -> "queen"
    card.King -> "king"
    card.Ace -> "ace"
  }
}

pub fn suit_to_string(suit: Suit) -> String {
  case suit {
    card.Hearts -> "hearts"
    card.Diamonds -> "diamonds"
    card.Clubs -> "clubs"
    card.Spades -> "spades"
  }
}

pub fn hand_type_to_string(hand_type: HandType) -> String {
  case hand_type {
    hand.HighCard -> "high_card"
    hand.Pair -> "pair"
    hand.TwoPair -> "two_pair"
    hand.ThreeOfAKind -> "three_of_a_kind"
    hand.Straight -> "straight"
    hand.Flush -> "flush"
    hand.FullHouse -> "full_house"
    hand.FourOfAKind -> "four_of_a_kind"
    hand.StraightFlush -> "straight_flush"
  }
}

pub fn enhancement_to_json(enhancement: Enhancement) -> Json {
  case enhancement {
    card.BonusChips(amount) ->
      json.object([
        #("type", json.string("bonus_chips")),
        #("amount", json.int(amount)),
      ])
    card.BonusMult(amount) ->
      json.object([
        #("type", json.string("bonus_mult")),
        #("amount", json.int(amount)),
      ])
  }
}

pub fn card_fields(c: Card) -> List(#(String, Json)) {
  [
    #("id", json.string(c.id)),
    #("rank", json.string(rank_to_string(c.rank))),
    #("suit", json.string(suit_to_string(c.suit))),
    #("enhancement", case c.enhancement {
      Some(e) -> enhancement_to_json(e)
      None -> json.null()
    }),
  ]
}

pub fn card_to_json(c: Card) -> Json {
  json.object(card_fields(c))
}

pub fn cards_to_json(cards: List(Card)) -> Json {
  json.array(cards, card_to_json)
}

pub fn shop_kind_to_json(kind: shop_card.CardKind) -> Json {
  case kind {
    shop_card.Research(shop_card.LevelUp(ht)) ->
      json.object([
        #("type", json.string("level_up")),
        #("hand_type", json.string(hand_type_to_string(ht))),
      ])
    shop_card.Counter(shop_card.Denial(ht)) ->
      json.object([
        #("type", json.string("denial")),
        #("hand_type", json.string(hand_type_to_string(ht))),
      ])
    shop_card.Logistics(l) ->
      case l {
        shop_card.Fortify(amount, max) ->
          json.object([
            #("type", json.string("fortify")),
            #("amount", json.int(amount)),
            #("max_cards", json.int(max)),
          ])
        shop_card.Amplify(amount, max) ->
          json.object([
            #("type", json.string("amplify")),
            #("amount", json.int(amount)),
            #("max_cards", json.int(max)),
          ])
        shop_card.SupplyDrop(max) ->
          json.object([
            #("type", json.string("supply_drop")),
            #("max_cards", json.int(max)),
          ])
        shop_card.Discharge(max) ->
          json.object([
            #("type", json.string("discharge")),
            #("max_cards", json.int(max)),
          ])
        shop_card.Camo(suit, max) ->
          json.object([
            #("type", json.string("camo")),
            #("suit", json.string(suit_to_string(suit))),
            #("max_cards", json.int(max)),
          ])
        shop_card.Promote(max) ->
          json.object([
            #("type", json.string("promote")),
            #("max_cards", json.int(max)),
          ])
      }
    shop_card.Sabotage(s) ->
      case s {
        shop_card.Scrambler ->
          json.object([#("type", json.string("scrambler"))])
        shop_card.PlusBomb(max) ->
          json.object([
            #("type", json.string("plus_bomb")),
            #("max_cards", json.int(max)),
          ])
        shop_card.StaticField ->
          json.object([#("type", json.string("static_field"))])
        shop_card.SupplyChain ->
          json.object([#("type", json.string("supply_chain"))])
      }
  }
}

/// Props for a shop card token. Picked/destroyed flags are added by the scene.
pub fn shop_card_fields(c: shop_card.ShopCard) -> List(#(String, Json)) {
  [
    #("name", json.string(shop_card.name(c))),
    #("description", json.string(shop_card.description(c))),
    #("category", json.string(shop_card.category(c))),
    #("kind", shop_kind_to_json(c.kind)),
    #("max_selection", json.int(shop_card.max_selection(c))),
    #("requires_selection", json.bool(shop_card.requires_selection(c))),
  ]
}

pub fn shop_card_to_json(c: shop_card.ShopCard) -> Json {
  json.object([#("id", json.string(c.id)), ..shop_card_fields(c)])
}

pub fn score_to_json(result: ScoreResult) -> Json {
  json.object([
    #("hand_type", json.string(hand_type_to_string(result.hand_type))),
    #("base_chips", json.int(result.base_chips)),
    #("base_multiplier", json.int(result.base_multiplier)),
    #("total_chips", json.int(result.total_chips)),
    #("total_multiplier", json.int(result.total_multiplier)),
    #("total_score", json.int(result.total_score)),
    #(
      "cards",
      json.array(result.card_breakdowns, fn(b) {
        json.object([
          #("card", card_to_json(b.card)),
          #("chip_value", json.int(b.chip_value)),
          #("bonus_chips", json.int(b.bonus_chips)),
          #("bonus_mult", json.int(b.bonus_mult)),
          #("disabled", json.bool(b.disabled)),
        ])
      }),
    ),
  ])
}

pub fn int_list(values: List(Int)) -> Json {
  json.array(values, json.int)
}

pub fn strings(values: List(String)) -> Json {
  json.array(values, json.string)
}

pub fn int_string(n: Int) -> String {
  int.to_string(n)
}
