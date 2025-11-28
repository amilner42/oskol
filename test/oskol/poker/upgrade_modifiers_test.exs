defmodule Oskol.Poker.UpgradeModifiersTest do
  use ExUnit.Case, async: true

  alias Oskol.Poker.UpgradeModifiers

  describe "new/0" do
    test "creates modifiers with default values" do
      mods = UpgradeModifiers.new()

      assert mods.straight_needs_only_4 == false
      assert mods.flush_needs_only_4 == false
      assert mods.straight_flush_needs_only_4 == false
      assert mods.straight_can_hop == false
      assert mods.straight_flush_can_hop == false
    end
  end

  describe "five_card_hands_need_only_4/0" do
    test "enables all three 5-card hand modifiers" do
      mods = UpgradeModifiers.five_card_hands_need_only_4()

      assert mods.straight_needs_only_4 == true
      assert mods.flush_needs_only_4 == true
      assert mods.straight_flush_needs_only_4 == true
    end

    test "does not affect hopping modifiers" do
      mods = UpgradeModifiers.five_card_hands_need_only_4()

      assert mods.straight_can_hop == false
      assert mods.straight_flush_can_hop == false
    end
  end

  describe "straights_can_hop/0" do
    test "enables both hopping modifiers" do
      mods = UpgradeModifiers.straights_can_hop()

      assert mods.straight_can_hop == true
      assert mods.straight_flush_can_hop == true
    end

    test "does not affect needs_only_4 modifiers" do
      mods = UpgradeModifiers.straights_can_hop()

      assert mods.straight_needs_only_4 == false
      assert mods.flush_needs_only_4 == false
      assert mods.straight_flush_needs_only_4 == false
    end
  end

  describe "struct instantiation" do
    test "can create custom combinations" do
      mods = %UpgradeModifiers{
        straight_needs_only_4: true,
        straight_can_hop: true
      }

      assert mods.straight_needs_only_4 == true
      assert mods.straight_can_hop == true
      assert mods.flush_needs_only_4 == false
    end

    test "can combine helper functions with updates" do
      mods =
        UpgradeModifiers.five_card_hands_need_only_4()
        |> Map.put(:straight_can_hop, true)

      assert mods.straight_needs_only_4 == true
      assert mods.flush_needs_only_4 == true
      assert mods.straight_flush_needs_only_4 == true
      assert mods.straight_can_hop == true
    end
  end
end
