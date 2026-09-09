defmodule Oskol.Gleam.Caps.Copy do
  @moduledoc "Real IO for src/oskol/caps/copy.gleam. Keep field order in lockstep."

  alias Oskol.GameKit
  alias OskolWeb.GameCopy

  def build do
    {:copy_caps, &site/0, &for_game/1}
  end

  defp site do
    site = GameCopy.site()
    {:site, site.title, site.description}
  end

  defp for_game(slug) do
    {:ok, info} = GameKit.game_info(slug)
    copy = GameCopy.for_game(info)

    {:copy, copy.title, copy.description, copy.intro, copy.rules, copy.faq}
  end
end
