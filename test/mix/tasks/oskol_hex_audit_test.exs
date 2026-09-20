defmodule Mix.Tasks.Oskol.HexAuditTest do
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
    fetcher = fn _repo, _name, _etag -> {:error, :nxdomain} end

    assert_raise Mix.Error, ~r/signed Hex registry fetch for bandit failed/, fn ->
      Mix.Tasks.Oskol.HexAudit.fetch_advisories!([package], fetcher)
    end
  end

  test "medium advisories do not become high/critical blockers" do
    packages = [%{app: :example, name: "example", version: "1.0.0", repo: "hexpm"}]

    lookup = fn _package ->
      [%{id: "CVE-EXAMPLE", aliases: [], severity: :SEVERITY_MEDIUM, cvss_score: 6.9}]
    end

    assert HexAudit.blocking_findings(packages, lookup) == []
  end

  test "compiler-only roots and their private dependencies are outside the runtime graph" do
    runtime_child = %Mix.Dep{app: :runtime_child}
    compiler_child = %Mix.Dep{app: :compiler_child}

    deps = [
      %Mix.Dep{app: :runtime_root, top_level: true, deps: [runtime_child]},
      %Mix.Dep{
        app: :compiler_root,
        top_level: true,
        opts: [runtime: false],
        deps: [compiler_child]
      },
      %Mix.Dep{app: :test_root, top_level: true, opts: [only: :test]}
    ]

    assert HexAudit.runtime_apps(deps) == MapSet.new([:runtime_root, :runtime_child])
  end
end
