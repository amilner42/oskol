defmodule Oskol.Game.CardPilesTest do
  use ExUnit.Case, async: true

  alias Oskol.Game.CardPiles

  describe "new/1" do
    test "creates CardPiles with 52 cards in draw pile and empty hand/discard piles" do
      piles = CardPiles.new(shuffle: false)
      assert length(piles.draw_pile) == 52
      assert piles.hand_pile == []
      assert piles.discard_pile == []
    end

    test "unshuffled decks have identical draw piles" do
      piles1 = CardPiles.new(shuffle: false)
      piles2 = CardPiles.new(shuffle: false)
      assert piles1.draw_pile == piles2.draw_pile
    end

    test "draw pile contains all 52 unique cards (4 suits × 13 ranks)" do
      piles = CardPiles.new(shuffle: true)

      # Should have exactly 52 unique cards
      assert length(Enum.uniq(piles.draw_pile)) == 52

      # Each of the 4 suits should have exactly 13 cards
      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        suit_cards = Enum.filter(piles.draw_pile, &(&1.suit == suit))
        assert length(suit_cards) == 13
      end

      # Each of the 13 ranks (2-14) should appear exactly 4 times (once per suit)
      for rank <- 2..14 do
        rank_cards = Enum.filter(piles.draw_pile, &(&1.rank == rank))
        assert length(rank_cards) == 4
      end
    end

    test "shuffle parameter controls draw pile order" do
      unshuffled = CardPiles.new(shuffle: false)
      shuffled = CardPiles.new(shuffle: true)

      assert unshuffled.draw_pile != shuffled.draw_pile
    end
  end

  describe "draw_cards/2" do
    test "moves cards from draw pile to hand pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 5)

      assert length(piles.hand_pile) == 5
      assert length(piles.draw_pile) == 47
      assert piles.discard_pile == []
    end

    test "draws cards from front of draw pile" do
      piles = CardPiles.new(shuffle: false)
      first_three = Enum.take(piles.draw_pile, 3)

      piles = CardPiles.draw_cards(piles, 3)

      assert piles.hand_pile == first_three
    end

    test "drawing 0 cards leaves piles unchanged" do
      piles = CardPiles.new(shuffle: false)
      original_draw = piles.draw_pile

      piles = CardPiles.draw_cards(piles, 0)

      assert piles.hand_pile == []
      assert piles.draw_pile == original_draw
    end

    test "multiple draws accumulate in hand pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 3)
      piles = CardPiles.draw_cards(piles, 2)

      assert length(piles.hand_pile) == 5
      assert length(piles.draw_pile) == 47
    end

    test "auto-shuffles discard into draw when draw pile empty" do
      piles = CardPiles.new(shuffle: false)

      # Draw all cards
      piles = CardPiles.draw_cards(piles, 52)
      assert length(piles.draw_pile) == 0
      assert length(piles.hand_pile) == 52

      # Discard some cards
      cards_to_discard = Enum.take(piles.hand_pile, 10)
      piles = CardPiles.discard_cards(piles, cards_to_discard)
      assert length(piles.discard_pile) == 10

      # Draw again - should shuffle discard into draw
      piles = CardPiles.draw_cards(piles, 5)
      # 42 + 5 new draws
      assert length(piles.hand_pile) == 47
      # 10 from discard - 5 drawn
      assert length(piles.draw_pile) == 5
      assert length(piles.discard_pile) == 0
    end
  end

  describe "discard_cards/2" do
    test "moves cards from hand pile to discard pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 8)

      cards_to_discard = Enum.take(piles.hand_pile, 3)
      piles = CardPiles.discard_cards(piles, cards_to_discard)

      assert length(piles.hand_pile) == 5
      assert length(piles.discard_pile) == 3
      assert length(piles.draw_pile) == 44
    end

    test "discarded cards are in discard pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 5)

      cards_to_discard = Enum.take(piles.hand_pile, 2)
      piles = CardPiles.discard_cards(piles, cards_to_discard)

      for card <- cards_to_discard do
        assert card in piles.discard_pile
        refute card in piles.hand_pile
      end
    end

    test "discarding empty list leaves piles unchanged" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 5)
      original_hand_pile = piles.hand_pile

      piles = CardPiles.discard_cards(piles, [])

      assert piles.hand_pile == original_hand_pile
      assert piles.discard_pile == []
    end
  end

  describe "replace_cards/2" do
    test "discards and draws same number of cards" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 8)

      cards_to_replace = Enum.take(piles.hand_pile, 3)
      piles = CardPiles.replace_cards(piles, cards_to_replace)

      assert length(piles.hand_pile) == 8
      assert length(piles.discard_pile) == 3
      assert length(piles.draw_pile) == 41
    end

    test "replaced cards are not in new hand pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 8)

      cards_to_replace = Enum.take(piles.hand_pile, 3)
      piles = CardPiles.replace_cards(piles, cards_to_replace)

      for card <- cards_to_replace do
        refute card in piles.hand_pile
        assert card in piles.discard_pile
      end
    end

    test "replacing 0 cards works" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 5)
      original_hand_pile = piles.hand_pile

      piles = CardPiles.replace_cards(piles, [])

      assert piles.hand_pile == original_hand_pile
      assert piles.discard_pile == []
    end
  end

  describe "shuffle_discard_into_draw/1" do
    test "moves all discard pile cards to draw pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 10)

      cards_to_discard = Enum.take(piles.hand_pile, 5)
      piles = CardPiles.discard_cards(piles, cards_to_discard)

      piles = CardPiles.shuffle_discard_into_draw(piles)

      assert piles.discard_pile == []
      # 42 + 5 from discard
      assert length(piles.draw_pile) == 47
    end

    test "shuffles the discard pile" do
      piles = CardPiles.new(shuffle: false)
      piles = CardPiles.draw_cards(piles, 20)

      cards_to_discard = Enum.take(piles.hand_pile, 10)
      piles = CardPiles.discard_cards(piles, cards_to_discard)

      original_discard = piles.discard_pile
      piles = CardPiles.shuffle_discard_into_draw(piles)

      # The cards should be in draw pile but likely in different order
      sorted_discard = Enum.sort_by(original_discard, fn c -> {c.rank, c.suit} end)

      sorted_new_draw =
        Enum.sort_by(Enum.take(piles.draw_pile, -10), fn c -> {c.rank, c.suit} end)

      assert sorted_discard == sorted_new_draw
    end

    test "works with empty discard pile" do
      piles = CardPiles.new(shuffle: false)
      original_draw = piles.draw_pile

      piles = CardPiles.shuffle_discard_into_draw(piles)

      assert piles.draw_pile == original_draw
      assert piles.discard_pile == []
    end
  end
end
