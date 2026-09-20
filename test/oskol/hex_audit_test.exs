defmodule Oskol.HexAuditTest do
  use ExUnit.Case, async: true

  Code.require_file("scripts/hex_audit.ex")

  alias Oskol.HexAudit

  test "a high advisory in a shipped package fails the fixture" do
    package = %{app: :bandit, name: "bandit", version: "1.8.0", repo: "hexpm"}

    advisory = %{
      id: "EEF-CVE-2026-39803",
      aliases: ["CVE-2026-39803", "GHSA-9q9q-324x-93r2"],
      severity: :SEVERITY_HIGH,
      cvss_score: 8.7,
      summary: "chunked body reader ignores the configured length cap",
      html_url: "https://osv.dev/vulnerability/EEF-CVE-2026-39803"
    }

    signed_record =
      {:ok,
       {200, %{},
        %{
          releases: [%{version: "1.8.0", advisory_indexes: [0]}],
          advisories: [advisory]
        }}}

    assert {:ok, [^advisory]} = HexAudit.registry_advisories(package, signed_record)

    assert [%{package: %{name: "bandit"}}] =
             HexAudit.blocking_findings([package], fn ^package -> [advisory] end)
  end

  test "a signed registry fetch failure makes the audit fail" do
    package = %{app: :bandit, name: "bandit", version: "1.12.5", repo: "hexpm"}
    calls = :atomics.new(1, [])

    fetcher = fn _repo, _name, _etag ->
      :atomics.add(calls, 1, 1)
      {:error, :nxdomain}
    end

    assert_raise Mix.Error, ~r/signed Hex registry fetch for bandit failed/, fn ->
      HexAudit.fetch_advisories!([package], fetcher)
    end

    assert :atomics.get(calls, 1) == 3
  end

  test "a transient signed registry failure is retried and can recover" do
    package = %{app: :bandit, name: "bandit", version: "1.12.5", repo: "hexpm"}
    calls = :atomics.new(1, [])

    fetcher = fn _repo, _name, _etag ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> {:ok, {429, %{"retry-after" => "1"}, %{}}}
        2 -> {:error, :timeout}
        3 -> {:ok, {200, %{}, %{releases: [%{version: "1.12.5"}], advisories: []}}}
      end
    end

    assert %{{"hexpm", "bandit", "1.12.5"} => []} =
             HexAudit.fetch_advisories!([package], fetcher)

    assert :atomics.get(calls, 1) == 3
  end

  test "a non-retryable registry response fails immediately" do
    package = %{app: :bandit, name: "bandit", version: "1.12.5", repo: "hexpm"}
    calls = :atomics.new(1, [])

    fetcher = fn _repo, _name, _etag ->
      :atomics.add(calls, 1, 1)
      {:ok, {404, %{}, %{}}}
    end

    assert_raise Mix.Error, ~r/returned HTTP 404/, fn ->
      HexAudit.fetch_advisories!([package], fetcher)
    end

    assert :atomics.get(calls, 1) == 1
  end

  test "medium advisories do not become high/critical blockers" do
    packages = [%{app: :example, name: "example", version: "1.0.0", repo: "hexpm"}]

    lookup = fn _package ->
      [%{id: "CVE-EXAMPLE", aliases: [], severity: :SEVERITY_MEDIUM, cvss_score: 6.9}]
    end

    assert HexAudit.blocking_findings(packages, lookup) == []
  end

  test "the same CVE affecting two packages reports both packages" do
    packages = [
      %{app: :first, name: "first", version: "1.0.0", repo: "hexpm"},
      %{app: :second, name: "second", version: "2.0.0", repo: "hexpm"}
    ]

    advisory = %{id: "CVE-SHARED", aliases: [], severity: :SEVERITY_HIGH}

    assert [%{package: %{name: "first"}}, %{package: %{name: "second"}}] =
             HexAudit.blocking_findings(packages, fn _package -> [advisory] end)
  end

  test "malformed advisory indexes fail closed" do
    package = %{app: :bandit, name: "bandit", version: "1.12.5", repo: "hexpm"}

    signed_record =
      {:ok,
       {200, %{},
        %{
          releases: [%{version: "1.12.5", advisory_indexes: [1]}],
          advisories: [%{id: "CVE-ONLY-INDEX-ZERO"}]
        }}}

    assert {:error, message} = HexAudit.registry_advisories(package, signed_record)
    assert message =~ "malformed advisory indexes"
  end

  test "the flat Mix graph follows runtime roots and excludes compiler-only roots" do
    runtime_child_from_root = %Mix.Dep{app: :runtime_child}
    compiler_child_from_root = %Mix.Dep{app: :compiler_child}

    deps = [
      # Mix returns one flat node per app. Child structs nested under a root
      # are shallow; the child's own edges live on its flat node.
      %Mix.Dep{app: :runtime_root, top_level: true, deps: [runtime_child_from_root]},
      %Mix.Dep{app: :runtime_child, deps: [%Mix.Dep{app: :runtime_grandchild}]},
      %Mix.Dep{app: :runtime_grandchild},
      %Mix.Dep{
        app: :compiler_root,
        top_level: true,
        opts: [runtime: false],
        deps: [compiler_child_from_root]
      },
      %Mix.Dep{app: :compiler_child},
      %Mix.Dep{app: :test_root, top_level: true, opts: [only: :test]}
    ]

    assert HexAudit.runtime_apps(deps) ==
             MapSet.new([:runtime_root, :runtime_child, :runtime_grandchild])
  end

  test "the real project audit includes Finch's shipped transitive packages" do
    runtime_apps = HexAudit.runtime_apps(Mix.Dep.load_and_cache())

    assert MapSet.subset?(MapSet.new([:finch, :mint, :nimble_pool]), runtime_apps)
    refute MapSet.member?(runtime_apps, :gleeunit)
  end

  test "a missing flat dependency node fails the runtime graph closed" do
    deps = [
      %Mix.Dep{app: :runtime_root, top_level: true, deps: [%Mix.Dep{app: :missing_child}]}
    ]

    assert_raise Mix.Error, ~r/runtime dependency missing_child is absent/, fn ->
      HexAudit.runtime_apps(deps)
    end
  end
end
