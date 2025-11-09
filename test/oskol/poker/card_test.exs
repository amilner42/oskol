defmodule Oskol.Poker.CardTest do
  use ExUnit.Case, async: true

  alias Oskol.Poker.Card

  describe "new/2" do
    test "creates a card struct with rank and suit" do
      card = Card.new(7, :hearts)
      assert %Card{} = card
      assert card.rank == 7
      assert card.suit == :hearts
    end
  end

  describe "chip_value/1" do
    test "numbered cards 2-10 return face value" do
      for rank <- 2..10 do
        card = Card.new(rank, :spades)
        assert Card.chip_value(card) == rank
      end
    end

    test "chip value are correct for face cards" do
      assert Card.chip_value(Card.new(11, :hearts)) == 10
      assert Card.chip_value(Card.new(12, :hearts)) == 10
      assert Card.chip_value(Card.new(13, :hearts)) == 10
    end

    test "Ace (14) returns 11 chips" do
      assert Card.chip_value(Card.new(14, :spades)) == 11
    end
  end
end
