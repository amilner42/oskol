defmodule Oskol.Poker.SkillTreeTest do
  use ExUnit.Case, async: true

  alias Oskol.Poker.SkillTree

  describe "new/0" do
    test "creates skill tree struct with all hand types at level 1" do
      skill_tree = SkillTree.new()

      assert %SkillTree{} = skill_tree
      assert skill_tree.high_card == 1
      assert skill_tree.pair == 1
      assert skill_tree.two_pair == 1
      assert skill_tree.three_of_a_kind == 1
      assert skill_tree.straight == 1
      assert skill_tree.flush == 1
      assert skill_tree.full_house == 1
      assert skill_tree.four_of_a_kind == 1
      assert skill_tree.straight_flush == 1
    end
  end

  describe "upgrade/3" do
    test "upgrades all hand types independently by various amounts" do
      skill_tree =
        SkillTree.new()
        |> SkillTree.upgrade(:high_card, 2)
        |> SkillTree.upgrade(:pair, 1)
        |> SkillTree.upgrade(:pair, 2)
        |> SkillTree.upgrade(:pair, 3)
        |> SkillTree.upgrade(:two_pair, 2)
        |> SkillTree.upgrade(:three_of_a_kind, 4)
        |> SkillTree.upgrade(:straight, 1)
        |> SkillTree.upgrade(:flush, 3)
        |> SkillTree.upgrade(:full_house, 2)
        |> SkillTree.upgrade(:four_of_a_kind, 6)
        |> SkillTree.upgrade(:straight_flush, 10)

      assert %SkillTree{} = skill_tree

      assert skill_tree.high_card == 3
      assert skill_tree.pair == 7
      assert skill_tree.two_pair == 3
      assert skill_tree.three_of_a_kind == 5
      assert skill_tree.straight == 2
      assert skill_tree.flush == 4
      assert skill_tree.full_house == 3
      assert skill_tree.four_of_a_kind == 7
      assert skill_tree.straight_flush == 11
    end
  end
end
