import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import poker/card.{type Card, type Rank}

/// Poker hand types
pub type HandType {
  HighCard
  Pair
  TwoPair
  ThreeOfAKind
  Straight
  Flush
  FullHouse
  FourOfAKind
  StraightFlush
}

/// Result of hand evaluation
pub type Evaluation {
  Evaluation(
    hand_type: HandType,
    played_cards: List(Card),
    scoring_cards: List(Card),
  )
}

/// Evaluates a poker hand (1-5 cards) and returns hand type and scoring cards
pub fn evaluate(hand: List(Card)) -> Evaluation {
  let hand_len = list.length(hand)

  // Check hands in order from best to worst
  case check_straight_flush(hand, hand_len) {
    Ok(scoring) -> Evaluation(StraightFlush, hand, scoring)
    Error(_) ->
      case check_four_of_a_kind(hand, hand_len) {
        Ok(scoring) -> Evaluation(FourOfAKind, hand, scoring)
        Error(_) ->
          case check_full_house(hand, hand_len) {
            Ok(scoring) -> Evaluation(FullHouse, hand, scoring)
            Error(_) ->
              case check_flush(hand, hand_len) {
                Ok(scoring) -> Evaluation(Flush, hand, scoring)
                Error(_) ->
                  case check_straight(hand, hand_len) {
                    Ok(scoring) -> Evaluation(Straight, hand, scoring)
                    Error(_) ->
                      case check_three_of_a_kind(hand, hand_len) {
                        Ok(scoring) -> Evaluation(ThreeOfAKind, hand, scoring)
                        Error(_) ->
                          case check_two_pair(hand, hand_len) {
                            Ok(scoring) -> Evaluation(TwoPair, hand, scoring)
                            Error(_) ->
                              case check_pair(hand, hand_len) {
                                Ok(scoring) -> Evaluation(Pair, hand, scoring)
                                Error(_) ->
                                  check_high_card(hand)
                                  |> Evaluation(HighCard, hand, _)
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

// Hand checking functions - return Ok(scoring_cards) or Error

fn check_straight_flush(
  hand: List(Card),
  hand_len: Int,
) -> Result(List(Card), Nil) {
  case hand_len == 5 && is_flush(hand) && is_straight(hand) {
    True -> Ok(hand)
    False -> Error(Nil)
  }
}

fn check_four_of_a_kind(
  hand: List(Card),
  hand_len: Int,
) -> Result(List(Card), Nil) {
  case hand_len >= 4 && has_min_count(hand, 4) {
    True -> Ok(get_cards_by_min_count(hand, 4))
    False -> Error(Nil)
  }
}

fn check_full_house(hand: List(Card), hand_len: Int) -> Result(List(Card), Nil) {
  case hand_len == 5 {
    True -> {
      let counts =
        rank_counts(hand) |> dict.values |> list.sort(by: int.compare)
      case counts == [2, 3] {
        True -> Ok(hand)
        False -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

fn check_flush(hand: List(Card), _hand_len: Int) -> Result(List(Card), Nil) {
  case is_flush(hand) {
    True -> Ok(hand)
    False -> Error(Nil)
  }
}

fn check_straight(hand: List(Card), _hand_len: Int) -> Result(List(Card), Nil) {
  case is_straight(hand) {
    True -> Ok(hand)
    False -> Error(Nil)
  }
}

fn check_three_of_a_kind(
  hand: List(Card),
  hand_len: Int,
) -> Result(List(Card), Nil) {
  case hand_len >= 3 && has_count(hand, 3) {
    True -> Ok(get_cards_by_count(hand, 3))
    False -> Error(Nil)
  }
}

fn check_two_pair(hand: List(Card), hand_len: Int) -> Result(List(Card), Nil) {
  case hand_len >= 4 {
    True -> {
      let pair_count =
        rank_counts(hand)
        |> dict.values
        |> list.filter(fn(c) { c == 2 })
        |> list.length
      case pair_count == 2 {
        True -> Ok(get_cards_by_count(hand, 2))
        False -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

fn check_pair(hand: List(Card), hand_len: Int) -> Result(List(Card), Nil) {
  case hand_len >= 2 && has_count(hand, 2) {
    True -> Ok(get_cards_by_count(hand, 2))
    False -> Error(Nil)
  }
}

fn check_high_card(hand: List(Card)) -> List(Card) {
  case
    list.reduce(hand, fn(max, c) {
      case card.rank_value(c.rank) > card.rank_value(max.rank) {
        True -> c
        False -> max
      }
    })
  {
    Ok(highest) -> [highest]
    Error(_) -> []
  }
}

// Helper functions

fn is_flush(hand: List(Card)) -> Bool {
  case list.length(hand) == 5 {
    False -> False
    True -> {
      let suits = list.map(hand, fn(c) { c.suit })
      let unique_suits = list.unique(suits)
      list.length(unique_suits) == 1
    }
  }
}

fn is_straight(hand: List(Card)) -> Bool {
  case list.length(hand) != 5 {
    True -> False
    False -> {
      let ranks =
        hand
        |> list.map(fn(c) { card.rank_value(c.rank) })
        |> list.sort(by: int.compare)

      // Check regular straight
      let regular_straight =
        ranks
        |> list.window_by_2
        |> list.all(fn(pair) {
          let #(a, b) = pair
          b - a == 1
        })

      // Check ace-low straight (A-2-3-4-5) - [2,3,4,5,14] as values
      let ace_low_straight = ranks == [2, 3, 4, 5, 14]

      regular_straight || ace_low_straight
    }
  }
}

fn has_count(hand: List(Card), count: Int) -> Bool {
  rank_counts(hand)
  |> dict.values
  |> list.any(fn(c) { c == count })
}

fn has_min_count(hand: List(Card), min_count: Int) -> Bool {
  rank_counts(hand)
  |> dict.values
  |> list.any(fn(c) { c >= min_count })
}

fn rank_counts(hand: List(Card)) -> Dict(Rank, Int) {
  list.fold(hand, dict.new(), fn(acc, c) {
    dict.upsert(acc, c.rank, fn(existing) {
      case existing {
        option.Some(count) -> count + 1
        option.None -> 1
      }
    })
  })
}

fn get_cards_by_count(hand: List(Card), count: Int) -> List(Card) {
  let counts = rank_counts(hand)
  list.filter(hand, fn(card) {
    case dict.get(counts, card.rank) {
      Ok(c) -> c == count
      Error(_) -> False
    }
  })
}

fn get_cards_by_min_count(hand: List(Card), min_count: Int) -> List(Card) {
  let counts = rank_counts(hand)
  list.filter(hand, fn(card) {
    case dict.get(counts, card.rank) {
      Ok(c) -> c >= min_count
      Error(_) -> False
    }
  })
}
